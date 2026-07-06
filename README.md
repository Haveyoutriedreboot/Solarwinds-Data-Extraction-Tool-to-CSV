[SolarWindsDataExractionTool-README.md](https://github.com/user-attachments/files/29719048/SolarWindsDataExractionTool-README.md)
# Solarwinds-Data-Extraction-Tool-to-CSV
Data extraction tool from Solarwinds into a CSV format compatible with the Onboarding Tool into PRTG

*For PRTG Device Onboarding Tool*

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
