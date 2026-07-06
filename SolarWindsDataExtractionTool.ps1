#Requires -Version 5.1
<#
.SYNOPSIS
    SolarWinds Data Extraction Tool - GUI front end that extracts node data from
    SolarWinds (SWIS) and writes a PRTG-ready import CSV.

.DESCRIPTION
    A self-contained WinForms application. It collects the SolarWinds server,
    username, password, a CSV output folder and a log folder, then runs the
    extraction (the same SWQL + CSV logic as build_prtg_import.ps1) on a
    background runspace so the window stays responsive. All progress and errors
    stream into the Output Log box and are also written to a timestamped log
    file in the chosen Log Folder.

    Compile to a single .exe with PS2EXE (see the bottom of this file).

    Runtime requirements on the target Windows machine:
      * Windows PowerShell 5.1 (built in) and .NET Framework (built in)
      * SwisPowerShell module:  Install-Module SwisPowerShell

    NOTE: the output CSV contains SNMP community strings in plaintext. Treat the
    output folder as sensitive. Credentials are held in memory only for the run
    and are never written to the CSV or the log.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --------------------------------------------------------------------------- #
# CONFIG
# --------------------------------------------------------------------------- #
$AppTitle        = 'SolarWinds Data Extraction Tool'
$AppSubtitle     = 'For PRTG Device Onboarding Tool'
$OutputFileName  = 'testdevices.csv'   # written into the chosen CSV output folder
$IfIndexPadWidth = 3                   # zero-pad ifIndexes to 3 digits ("016")

# Mutable plumbing shared across event handlers (script scope).
$script:ps        = $null
$script:rs        = $null
$script:handle    = $null
$script:logWriter = $null
$script:running   = $false

# Thread-safe channel between the worker runspace and the UI timer.
$sync       = [hashtable]::Synchronized(@{})
$sync.Queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$sync.Done  = $false
$sync.WarningCount = 0
$sync.Cancelled    = $false

# --------------------------------------------------------------------------- #
# EXTRACTION WORKER  (runs on a background runspace; self-contained)
# --------------------------------------------------------------------------- #
$ExtractionWorker = {
    param($sync)

    function Write-Log { param($m) $sync.Queue.Enqueue(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m)) }

    function Format-CsvField {
        param($Value)
        if ($null -eq $Value -or $Value -is [System.DBNull]) { return '' }
        $s = [string]$Value
        if ($s -match '[|,"\r\n]') { return '"' + ($s -replace '"', '""') + '"' }
        return $s
    }

    function Get-PrimaryGroups {
        param($Rows)
        $bestCid = @{}; $names = @{}
        foreach ($r in $Rows) {
            $nid = [string]$r.NodeID; $cid = [int]$r.ContainerID
            if (-not $bestCid.ContainsKey($nid) -or $cid -lt $bestCid[$nid]) {
                $bestCid[$nid] = $cid; $names[$nid] = [string]$r.GroupName
            }
        }
        return $names
    }

    function Get-TrafficInterfaces {
        param($Rows, [int]$PadWidth)
        $byNode = @{}
        foreach ($r in $Rows) {
            $nid = [string]$r.NodeID
            if (-not $byNode.ContainsKey($nid)) { $byNode[$nid] = [System.Collections.Generic.List[int]]::new() }
            $byNode[$nid].Add([int]$r.IfIndex)
        }
        $out = @{}
        foreach ($nid in $byNode.Keys) {
            $idxs = $byNode[$nid] | Sort-Object
            if ($PadWidth -gt 0) { $parts = $idxs | ForEach-Object { ([string]$_).PadLeft($PadWidth, '0') } }
            else                 { $parts = $idxs | ForEach-Object { [string]$_ } }
            $out[$nid] = ($parts -join '|')
        }
        return $out
    }

    try {
        $server    = $sync.Server
        $cred      = $sync.Credential
        $outFolder = $sync.OutputFolder
        $pad       = $sync.PadWidth
        $outFile   = Join-Path $outFolder $sync.OutputFileName

        $nodeQuery = @'
SELECT n.NodeID AS NodeID, n.Caption AS Name, n.DNS AS Host,
CASE
WHEN n.ObjectSubType = 'SNMP' THEN 'ping|snmptraffic|snmpcpu|snmpmemory'
WHEN n.ObjectSubType = 'WMI' THEN 'ping|wmicpuload|wmimemory|wmilogicaldisk'
WHEN n.ObjectSubType = 'ICMP' THEN 'ping'
ELSE 'ping' END AS Sensors,
n.ObjectSubType AS CredentialType,
n.Community AS Community,
'' AS WMIUser,
'' AS WMIPassword,
CASE
WHEN n.SNMPVersion = 1 THEN 'v1'
WHEN n.SNMPVersion = 2 THEN 'v2c'
WHEN n.SNMPVersion = 3 THEN 'v3'
ELSE '' END AS SNMPVersion,
ISNULL(c.Description, 'Other') AS CategoryName
FROM Orion.Nodes AS n
LEFT JOIN Orion.NodeCategories AS c ON c.CategoryID = n.Category
WHERE n.Unmanaged = false
'@

        $ifaceQuery = @'
SELECT i.NodeID AS NodeID, i.InterfaceIndex AS IfIndex
FROM Orion.NPM.Interfaces AS i
WHERE i.Unmanaged = false AND i.InterfaceIndex > 0
AND i.InterfaceIndex < 2147483647 AND i.ObjectSubType = 'SNMP'
'@

        $groupQuery = @'
SELECT cm.MemberPrimaryID AS NodeID, g.ContainerID AS ContainerID, g.Name AS GroupName
FROM Orion.ContainerMembers AS cm
INNER JOIN Orion.Groups AS g ON g.ContainerID = cm.ContainerID
WHERE cm.MemberEntityType = 'Orion.Nodes'
'@

        $FinalColumns = @(
            'Name','Host','Group','Sensors','CredentialType',
            'Community','WMIUser','WMIPassword','SNMPVersion','TrafficInterfaces'
        )

        if (-not (Get-Module -ListAvailable -Name SwisPowerShell)) {
            throw "SwisPowerShell module is not installed. Run:  Install-Module SwisPowerShell"
        }
        Write-Log "Importing SwisPowerShell module ..."
        Import-Module SwisPowerShell -ErrorAction Stop

        Write-Log "Connecting to SolarWinds (SWIS) at $server ..."
        $swis = Connect-Swis -Hostname $server -Credential $cred -ErrorAction Stop

        Write-Log "Querying nodes ..."
        $nodes = @(Get-SwisData $swis $nodeQuery)
        Write-Log ("  {0} managed node(s)" -f $nodes.Count)

        Write-Log "Querying managed interfaces ..."
        $ifaces  = @(Get-SwisData $swis $ifaceQuery)
        $traffic = Get-TrafficInterfaces -Rows $ifaces -PadWidth $pad
        Write-Log ("  interfaces rolled up for {0} node(s)" -f $traffic.Count)

        Write-Log "Querying group memberships ..."
        $grps   = @(Get-SwisData $swis $groupQuery)
        $groups = Get-PrimaryGroups -Rows $grps
        Write-Log ("  primary group resolved for {0} node(s)" -f $groups.Count)

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append((($FinalColumns) -join ',') + "`r`n")
        $warnings = New-Object System.Collections.Generic.List[string]
        foreach ($n in $nodes) {
            $nid = [string]$n.NodeID
            $row = @{}
            foreach ($col in $FinalColumns) { $row[$col] = $n.$col }
            $row['Group']             = if ($groups.ContainsKey($nid))  { $groups[$nid] }  else { $n.CategoryName }
            $row['TrafficInterfaces'] = if ($traffic.ContainsKey($nid)) { $traffic[$nid] } else { '' }
            if ([string]::IsNullOrWhiteSpace([string]$row['Host'])) {
                $warnings.Add(("Node '{0}' has no DNS Host; row written with an empty Host." -f $row['Name']))
            }
            $line = ($FinalColumns | ForEach-Object { Format-CsvField $row[$_] }) -join ','
            [void]$sb.Append($line + "`r`n")
        }
        if ($nodes.Count -eq 0) { $warnings.Add('No managed nodes were returned by SolarWinds.') }

        if (-not (Test-Path $outFolder)) { New-Item -ItemType Directory -Path $outFolder -Force | Out-Null }
        $utf8Bom = [System.Text.UTF8Encoding]::new($true)
        [System.IO.File]::WriteAllText($outFile, $sb.ToString(), $utf8Bom)

        Write-Log ("Wrote {0} row(s) -> {1}" -f $nodes.Count, $outFile)

        $bar = ('=' * 50)
        Write-Log $bar
        if ($warnings.Count -gt 0) {
            Write-Log ("SUMMARY: Completed with {0} warning(s)" -f $warnings.Count)
            Write-Log $bar
            for ($i = 0; $i -lt $warnings.Count; $i++) {
                Write-Log ("   [{0}] {1}" -f ($i + 1), $warnings[$i])
            }
        } else {
            Write-Log "SUMMARY: Completed successfully with no warnings"
        }
        Write-Log $bar
        Write-Log ("--- Script finished at {0} ---" -f (Get-Date -Format 'MM/dd/yyyy HH:mm:ss'))
        $sync.WarningCount = $warnings.Count
        $sync.Success = $true
    }
    catch {
        Write-Log ("ERROR: {0}" -f $_.Exception.Message)
        $bar = ('=' * 50)
        Write-Log $bar
        Write-Log "SUMMARY: Failed - see the error above"
        Write-Log $bar
        Write-Log ("--- Script finished at {0} ---" -f (Get-Date -Format 'MM/dd/yyyy HH:mm:ss'))
        $sync.Success = $false
    }
    finally {
        $sync.Done = $true
    }
}

# --------------------------------------------------------------------------- #
# UI
# --------------------------------------------------------------------------- #
$navy   = [System.Drawing.Color]::FromArgb(31, 58, 95)
$blue   = [System.Drawing.Color]::FromArgb(0, 120, 215)
$red    = [System.Drawing.Color]::FromArgb(196, 43, 43)
$darkBg = [System.Drawing.Color]::FromArgb(24, 24, 24)
$liteFg = [System.Drawing.Color]::FromArgb(222, 222, 222)

$form = New-Object System.Windows.Forms.Form
$form.Text            = $AppTitle
$form.ClientSize      = New-Object System.Drawing.Size(640, 590)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false

# Header band
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size     = New-Object System.Drawing.Size(640, 70)
$header.BackColor = $navy
$form.Controls.Add($header)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = $AppTitle
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location  = New-Object System.Drawing.Point(16, 10)
$lblTitle.AutoSize  = $true
$header.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text      = $AppSubtitle
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(180, 200, 225)
$lblSub.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
$lblSub.Location  = New-Object System.Drawing.Point(18, 43)
$lblSub.AutoSize  = $true
$header.Controls.Add($lblSub)

function New-Label {
    param($Text, $Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point(18, ($Y + 3))
    $l.Size = New-Object System.Drawing.Size(130, 20)
    $form.Controls.Add($l)
    return $l
}
function New-TextBox {
    param($Y, [int]$Width = 380, [switch]$Password)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(150, $Y)
    $t.Size = New-Object System.Drawing.Size($Width, 24)
    if ($Password) { $t.UseSystemPasswordChar = $true }
    $form.Controls.Add($t)
    return $t
}
function New-BrowseButton {
    param($Y, $Target)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = 'Browse'
    $b.Location = New-Object System.Drawing.Point(538, ($Y - 1))
    $b.Size = New-Object System.Drawing.Size(84, 26)
    $b.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $Target.Text = $dlg.SelectedPath }
    }.GetNewClosure())
    $form.Controls.Add($b)
    return $b
}

[void](New-Label 'SolarWinds Server:' 88);   $txtServer    = New-TextBox 85
[void](New-Label 'Username:' 120);            $txtUser      = New-TextBox 117
[void](New-Label 'Password:' 152);            $txtPass      = New-TextBox 149 -Password
[void](New-Label 'CSV Output Folder:' 184);   $txtCsv       = New-TextBox 181; [void](New-BrowseButton 181 $txtCsv)
[void](New-Label 'Log Folder:' 216);          $txtLogFolder = New-TextBox 213; [void](New-BrowseButton 213 $txtLogFolder)

[void](New-Label 'Output Log:' 250)
$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location   = New-Object System.Drawing.Point(18, 272)
$txtOutput.Size       = New-Object System.Drawing.Size(604, 248)
$txtOutput.Multiline  = $true
$txtOutput.ReadOnly    = $true
$txtOutput.ScrollBars  = 'Vertical'
$txtOutput.BackColor   = $darkBg
$txtOutput.ForeColor   = $liteFg
$txtOutput.Font        = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtOutput)

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text      = 'Run Data Extraction'
$btnRun.Location  = New-Object System.Drawing.Point(18, 535)
$btnRun.Size      = New-Object System.Drawing.Size(170, 34)
$btnRun.BackColor = $blue
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = 'Flat'
$form.Controls.Add($btnRun)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text      = 'Cancel'
$btnCancel.Location  = New-Object System.Drawing.Point(200, 535)
$btnCancel.Size      = New-Object System.Drawing.Size(120, 34)
$btnCancel.BackColor = $red
$btnCancel.ForeColor = [System.Drawing.Color]::White
$btnCancel.FlatStyle = 'Flat'
$btnCancel.Enabled   = $false
$form.Controls.Add($btnCancel)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(335, 540)
$lblStatus.Size     = New-Object System.Drawing.Size(290, 40)
$lblStatus.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
$lblStatus.Text     = ''
$form.Controls.Add($lblStatus)

# --------------------------------------------------------------------------- #
# Behaviour
# --------------------------------------------------------------------------- #
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    $line = $null
    while ($sync.Queue.TryDequeue([ref]$line)) {
        $txtOutput.AppendText($line + "`r`n")
        if ($script:logWriter) { $script:logWriter.WriteLine($line); $script:logWriter.Flush() }
    }
    if ($sync.Done -and $script:running) {
        $script:running = $false
        try { $script:ps.EndInvoke($script:handle) }
        catch { $txtOutput.AppendText(('[{0}] ERROR: {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message) + "`r`n") }
        if ($script:ps) { $script:ps.Dispose(); $script:ps = $null }
        if ($script:rs) { $script:rs.Close();   $script:rs = $null }
        if ($script:logWriter) { $script:logWriter.Dispose(); $script:logWriter = $null }

        if ($sync.Cancelled) {
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
            $lblStatus.Text = 'Cancelled - see log for details'
        } elseif (-not $sync.Success) {
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(196, 43, 43)
            $lblStatus.Text = 'Failed - see log for details'
        } elseif ([int]$sync.WarningCount -gt 0) {
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(200, 120, 0)
            $lblStatus.Text = ("Completed with {0} warning(s) - See log for details" -f $sync.WarningCount)
        } else {
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 140, 0)
            $lblStatus.Text = 'Completed successfully'
        }

        $btnRun.Enabled = $true
        $btnCancel.Enabled = $false
        $timer.Stop()
    }
})

$btnRun.Add_Click({
    $errs = @()
    if ([string]::IsNullOrWhiteSpace($txtServer.Text))    { $errs += 'SolarWinds Server is required.' }
    if ([string]::IsNullOrWhiteSpace($txtUser.Text))      { $errs += 'Username is required.' }
    if ([string]::IsNullOrWhiteSpace($txtPass.Text))      { $errs += 'Password is required.' }
    if ([string]::IsNullOrWhiteSpace($txtCsv.Text))       { $errs += 'CSV Output Folder is required.' }
    if ([string]::IsNullOrWhiteSpace($txtLogFolder.Text)) { $errs += 'Log Folder is required.' }
    if ($errs.Count -gt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(($errs -join "`r`n"), 'Missing information',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    try {
        if (-not (Test-Path $txtCsv.Text))       { New-Item -ItemType Directory -Path $txtCsv.Text -Force | Out-Null }
        if (-not (Test-Path $txtLogFolder.Text)) { New-Item -ItemType Directory -Path $txtLogFolder.Text -Force | Out-Null }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Could not create folder: $($_.Exception.Message)", 'Folder error',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    $secure = ConvertTo-SecureString $txtPass.Text -AsPlainText -Force
    $cred   = New-Object System.Management.Automation.PSCredential($txtUser.Text.Trim(), $secure)

    $logPath = Join-Path $txtLogFolder.Text ('SWExtraction_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $script:logWriter = New-Object System.IO.StreamWriter($logPath, $false, [System.Text.UTF8Encoding]::new($true))
    $script:logWriter.WriteLine("Log file: $logPath"); $script:logWriter.Flush()

    $sync.Server         = $txtServer.Text.Trim()
    $sync.Credential     = $cred
    $sync.OutputFolder   = $txtCsv.Text.Trim()
    $sync.OutputFileName = $OutputFileName
    $sync.PadWidth       = $IfIndexPadWidth
    $sync.Success        = $false
    $sync.Done           = $false
    $sync.WarningCount   = 0
    $sync.Cancelled      = $false
    $tmp = $null; while ($sync.Queue.TryDequeue([ref]$tmp)) { }

    $lblStatus.Text = ''
    $txtOutput.Clear()
    $txtOutput.AppendText(('[{0}] Starting data extraction ...' -f (Get-Date -Format 'HH:mm:ss')) + "`r`n")

    $script:rs = [runspacefactory]::CreateRunspace()
    $script:rs.ApartmentState = 'STA'
    $script:rs.ThreadOptions  = 'ReuseThread'
    $script:rs.Open()
    $script:ps = [powershell]::Create()
    $script:ps.Runspace = $script:rs
    [void]$script:ps.AddScript($ExtractionWorker.ToString()).AddArgument($sync)
    $script:handle  = $script:ps.BeginInvoke()
    $script:running = $true

    $btnRun.Enabled    = $false
    $btnCancel.Enabled = $true
    $timer.Start()
})

$btnCancel.Add_Click({
    if ($script:running -and $script:ps) {
        try { $script:ps.Stop() } catch { }
        $sync.Cancelled = $true
        $sync.Queue.Enqueue(('[{0}] Cancelled by user.' -f (Get-Date -Format 'HH:mm:ss')))
        $sync.Done = $true
    }
    $btnCancel.Enabled = $false
})

$form.Add_FormClosing({
    if ($script:running -and $script:ps) { try { $script:ps.Stop() } catch { } }
    if ($script:rs) { try { $script:rs.Close() } catch { } }
    if ($script:logWriter) { try { $script:logWriter.Dispose() } catch { } }
    $timer.Stop()
})

[void]$form.ShowDialog()

# --------------------------------------------------------------------------- #
# BUILD INTO A SINGLE .EXE  (run once on a Windows box with internet access):
#
#   Install-Module ps2exe -Scope CurrentUser
#   Invoke-PS2EXE -InputFile  .\SolarWindsDataExtractionTool.ps1 `
#                 -OutputFile .\SolarWindsDataExtractionTool.exe `
#                 -NoConsole -STA `
#                 -Title   'SolarWinds Data Extraction Tool' `
#                 -Product 'SolarWinds Data Extraction Tool' `
#                 -Version '1.0.0.0'
#
# The resulting .exe needs the SwisPowerShell module installed on the machine
# where it runs:  Install-Module SwisPowerShell
# --------------------------------------------------------------------------- #
