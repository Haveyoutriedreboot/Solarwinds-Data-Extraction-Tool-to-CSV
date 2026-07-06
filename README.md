*For PRTG Device Onboarding Tool*
# SolarWinds Data Extraction Tool

A PowerShell GUI tool that connects to a SolarWinds Orion instance via SWIS (SolarWinds Information Service) and automatically generates a PRTG-ready device import CSV. Instead of manually building a CSV from scratch, this tool queries SolarWinds for all managed nodes, their credential types, SNMP community strings, SNMP versions, managed interfaces, and group memberships, then writes everything into the correct format for the [PRTG Device Onboarding Tool](https://github.com/your-username/prtg-onboarding-tool).

This tool is the first step in a two-tool workflow for migrating or replicating your SolarWinds monitored environment into PRTG. Run this tool to extract the data, then hand the generated CSV to the PRTG Onboarding Tool to create everything in PRTG automatically.

## What is included in this repository

Both the PowerShell source (`SolarWindsDataExtractionTool.ps1`) and the compiled executable (`SolarWindsDataExtractionTool.exe`) are published here.

The `.exe` is provided for convenience so anyone can run it immediately without worrying about execution policy or compiling steps.

The `.ps1` source is published alongside it so the tool is never a black box. If you want to inspect what it does, adjust the SWQL queries, change which fields are extracted, or add support for additional SolarWinds object types, you can edit the script directly and compile your own `.exe`. Instructions for compiling are included below.

## What it extracts from SolarWinds

The tool runs three SWQL queries against your Orion instance.

The nodes query pulls every managed node with its name, DNS hostname, credential type (SNMP, WMI, or ICMP), SNMP community string, SNMP version, and auto-assigns sensor types based on the node type. SNMP nodes get ping, SNMP Traffic, SNMP CPU, and SNMP Memory. WMI nodes get ping, WMI CPU Load, WMI Memory, and WMI Volume. ICMP nodes get ping only.

The interfaces query pulls all managed SNMP interfaces with valid ifIndex values, filtering out non-SNMP interfaces and the placeholder value 2147483647 that some SolarWinds versions insert.

The group memberships query pulls which SolarWinds groups each node belongs to, using the lowest ContainerID to pick the primary group per node.

## Requirements

### SwisPowerShell module

This is the only additional requirement. Install it before running the tool:

```powershell
Install-Module SwisPowerShell -Scope CurrentUser -Force
```

### PowerShell

Windows PowerShell 5.1 or newer. Check your version with:

```powershell
$PSVersionTable.PSVersion
```

### Execution policy

If running the .ps1 directly rather than the .exe, you may need to adjust execution policy:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Unblocking downloaded files

Files downloaded from GitHub are flagged by Windows as coming from the internet. Unblock them before running:

```powershell
Unblock-File -Path ".\SolarWindsDataExtractionTool.ps1"
Unblock-File -Path ".\SolarWindsDataExtractionTool.exe"
```

Or right click the file, choose Properties, and check the Unblock box at the bottom of the General tab.

### SolarWinds account permissions

The SolarWinds account used to connect needs read access to:

- Orion.Nodes
- Orion.NodeCategories
- Orion.NPM.Interfaces
- Orion.ContainerMembers
- Orion.Groups

A read-only Orion account is sufficient. No write access is required.

### Network access

The machine running the tool needs network access to the SolarWinds Orion server on the SWIS port, which is 17774 for Orion 2023.1 and newer, or 17778 for older versions. The SwisPowerShell module handles the endpoint automatically.

## Installation

1. Download `SolarWindsDataExtractionTool.ps1` and `SolarWindsDataExtractionTool.exe` from this repository
2. Unblock both files (see above)
3. Run the .exe directly, or run the .ps1 with:

```powershell
.\SolarWindsDataExtractionTool.ps1
```

## Using the tool

Fill in the five fields and click Run Data Extraction.

| Field | Description |
|---|---|
| SolarWinds Server | Hostname or IP of your Orion server |
| Username | SolarWinds username |
| Password | SolarWinds password |
| CSV Output Folder | Folder where the generated CSV will be saved |
| Log Folder | Folder where the log file will be saved |

The tool will connect to SolarWinds, run the three queries, build the CSV, and save it as `testdevices.csv` in your chosen output folder. A timestamped log file is saved to your chosen log folder.

The Cancel button stops the extraction safely at the next checkpoint.

The status bar at the bottom shows green for a clean run, amber if there were warnings (such as nodes with no DNS hostname), and red if the run failed.

## CSV output format

```csv
Name,Host,Group,Sensors,CredentialType,Community,WMIUser,WMIPassword,SNMPVersion,TrafficInterfaces
Router-01,router01.domain.local,Network Devices,"ping|snmptraffic|snmpcpu|snmpmemory",SNMP,public,,,v2c,"001|003|016"
Server-01,server01.domain.local,Windows Servers,"ping|wmicpuload|wmimemory|wmilogicaldisk",WMI,,,,,
```

This CSV is designed to be fed directly into the [PRTG Device Onboarding Tool](https://github.com/your-username/prtg-onboarding-tool). The PRTG tool automatically corrects legacy sensor type names (such as wmicpuload and wmilogicaldisk) at runtime via its built-in translation table, so the CSV does not need to be manually edited for those.

## Building the .exe yourself

```powershell
Install-Module ps2exe -Scope CurrentUser -Force

Invoke-PS2EXE -InputFile  ".\SolarWindsDataExtractionTool.ps1" `
              -OutputFile ".\SolarWindsDataExtractionTool.exe" `
              -NoConsole -STA `
              -Title   "SolarWinds Data Extraction Tool" `
              -Product "SolarWinds Data Extraction Tool" `
              -Version "1.0.0.0"
```

## Security notes

- SNMP community strings are written to the CSV output file in plain text. Treat the CSV output folder as sensitive and do not commit real device CSVs to a public repository.
- WMI credentials are intentionally not extracted. SolarWinds stores them encrypted and they cannot be read via SWIS. You will need to add WMI credentials to the CSV manually, or set them at the group level in PRTG after onboarding.
- The SolarWinds password is held in memory only for the duration of the run and is never written to the CSV or the log file.

## Related tool

This tool is designed to work alongside the [PRTG Device Onboarding Tool](https://github.com/your-username/prtg-onboarding-tool). See the combined workflow documentation below.

## License

This project is licensed under the MIT License. See the LICENSE file for details.

This tool depends on [SwisPowerShell](https://github.com/solarwinds/OrionSDK), which has its own license terms. Check that repository for details.

A small Windows application that connects to a SolarWinds Orion server, extracts
the monitored node inventory, and writes a CSV that the PRTG (lordmilko/PrtgAPI)
Device Onboarding Tool can import. It replaces the manual step of building that
import file by hand.

---

## What it does

When you run an extraction, the tool queries SolarWinds (via the SWIS API) for:

- **Nodes** — name, host, monitoring method, SNMP community/version, and category.
- **Managed interfaces** — the SNMP interface indexes to create traffic sensors for.
- **Group memberships** — the SolarWinds group each node belongs to.

It then writes a single file, `testdevices.csv`, into the folder you choose. Each
row is one device, formatted exactly as the PRTG onboarding tool expects.

---

## Prerequisites

Everything below must be in place on the machine where you run the tool. Running
it directly on the SolarWinds Orion server is the simplest option, because the
SWIS service is then local.

- **Windows** — Windows Server 2016 or later, or Windows 10/11.
- **Windows PowerShell 5.1** — built into Windows; nothing to install.
- **.NET Framework 4.x** — built into Windows; nothing to install.
- **SwisPowerShell module** — the only extra component. Install it once (see below).
- **A SolarWinds Orion account** with permission to run API/SWIS queries. A local
  Orion administrator account works. Some Active Directory-only accounts do not
  have SWIS access; if in doubt, use a local Orion account.
- **Network access** from this machine to the Orion server on **TCP 17777** (the
  SWIS endpoint the tool uses). If there is a firewall between the two machines,
  this port must be open.

### Installing the SwisPowerShell module

Open PowerShell **as Administrator** and run:

```powershell
Install-Module SwisPowerShell
```

If prompted to trust the PowerShell Gallery, answer yes. If the machine has no
internet access, install the module on a connected machine with
`Save-Module SwisPowerShell -Path C:\Temp`, copy the folder to the offline
machine's module path, or ask your administrator to deploy it.

You can confirm it is installed with:

```powershell
Get-Module -ListAvailable SwisPowerShell
```

The tool checks for this module on startup and will tell you in the Output Log if
it is missing.

---

## How to use it

1. **Launch** `SolarWindsDataExtractionTool.exe`.
2. Fill in the fields:

| Field | What to enter |
|-------|---------------|
| SolarWinds Server | Hostname or IP of your Orion server (e.g. `WIN22NETMON01` or `10.1.1.230`). Use `localhost` if you are running the tool on the Orion server itself. |
| Username | A SolarWinds Orion account with API/query rights. |
| Password | That account's password (masked as you type). |
| CSV Output Folder | The folder where `testdevices.csv` will be written. Use **Browse** to pick it. |
| Log Folder | The folder where a run log file will be written. Use **Browse** to pick it. |

3. Click **Run Data Extraction**. The window stays responsive while it works, and
   progress appears live in the **Output Log**.
4. Watch the status line next to the buttons when it finishes:
   - **Completed successfully** (green) — clean run.
   - **Completed with N warning(s)** (orange) — finished, but review the warnings.
   - **Failed** (red) — the run stopped on an error; the Output Log shows the cause.
   - **Cancelled** (gray) — you stopped it with **Cancel**.
5. Hand the resulting `testdevices.csv` to the PRTG Device Onboarding Tool.

**Cancel** stops an in-progress run at any time.

---

## What you get

### The CSV file

The tool writes `testdevices.csv` into your chosen CSV Output Folder. **Each run
overwrites the previous file**, which is normal — you regenerate the import file
whenever the SolarWinds inventory changes.

The columns are:

| Column | Meaning |
|--------|---------|
| Name | Node display name from SolarWinds. |
| Host | The node's DNS name. |
| Group | The node's primary SolarWinds group; if the node is in no group, its category (e.g. Server, Network) is used instead. |
| Sensors | A pipe-delimited baseline sensor set chosen by monitoring method (SNMP nodes get ping + SNMP traffic/CPU/memory; ICMP/other get ping). |
| CredentialType | How SolarWinds polls the node (SNMP, WMI, ICMP, Agent). |
| Community | The SNMP v1/v2c community string (SNMP nodes only). |
| WMIUser / WMIPassword | Always blank — see the note below. |
| SNMPVersion | v1, v2c, or v3. |
| TrafficInterfaces | Pipe-delimited SNMP interface indexes for traffic sensors (SNMP nodes only). |

### The log file

Each run also writes a timestamped log (for example
`SWExtraction_20260622_125702.log`) into your Log Folder. It contains the same
messages shown in the Output Log, so you have a permanent record of every run.

---

## Things to know

- **WMI and SNMPv3 credentials are not exported.** SolarWinds stores WMI
  usernames/passwords encrypted, so they cannot be read back out — `WMIUser` and
  `WMIPassword` are always blank. Likewise, SNMPv3 authentication details are not
  part of this CSV format. You will supply those in PRTG after import.
- **The CSV contains SNMP community strings in plaintext.** Treat the output
  folder as sensitive and keep it access-controlled.
- **Credentials are used in memory only.** The username and password you type are
  used to connect for that run and are never written to the CSV or the log file.
- **Non-SNMP "interfaces" are filtered out.** SolarWinds objects such as the NTA
  "Local NetFlow Source" (which carry a placeholder interface index) are excluded,
  so only real SNMP interfaces end up in `TrafficInterfaces`.

---

## Troubleshooting

| Symptom in the Output Log | Likely cause and fix |
|---------------------------|----------------------|
| "SwisPowerShell module is not installed" | Install it: `Install-Module SwisPowerShell` (see Prerequisites). |
| A connection or logon error when connecting to SWIS | Wrong server address, wrong username/password, or the account lacks SWIS/API rights. Try a local Orion admin account. |
| Connects but returns 0 managed nodes | The account may lack view rights to the nodes, or there genuinely are no managed nodes. |
| "Node 'X' has no DNS Host" warnings | Those nodes have no DNS name in SolarWinds. They are still written, but with an empty Host; add DNS in SolarWinds or fix the host in the CSV before import. |
| The window can't reach the server at all | Check network/firewall access to the Orion server on TCP 17777. |

If a run fails, the exact error and the line it failed on appear in both the
Output Log and the saved log file — keep that handy if you need support.

---

## At a glance

- **You install once:** the `SwisPowerShell` module.
- **You provide each run:** SolarWinds server, username, password, an output
  folder, and a log folder.
- **You get:** `testdevices.csv` ready for the PRTG Device Onboarding Tool, plus a
  log file of the run.
