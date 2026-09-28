# ad-powershell-toolkit

PowerShell toolkit for Active Directory operations: bulk user provisioning, health reporting, and GPO backup — all scriptable, loggable, and -WhatIf safe.

## Result

| Task | Manual | With scripts |
|---|---|---|
| Create 100 users | ~2 hours | 49 seconds |
| AD health check | ad-hoc, no standard output | HTML report in 3 s, schedulable |
| GPO backup | manual export, no manifest | all GPOs + manifest.csv, auto-rotation |

See [`sample-data/output-sample.txt`](sample-data/output-sample.txt) for full console output.

## Scripts

| Script | What it does |
|---|---|
| `New-BulkUsers.ps1` | Create AD users from CSV; assigns groups, sets manager, logs results |
| `Get-ADHealthReport.ps1` | Generate HTML health report; schedulable via `-Register` |
| `Backup-GPOs.ps1` | Backup all GPOs with manifest; auto-delete sessions older than N days |

## Requirements

- Windows Server 2019/2022 or Windows 10/11 with RSAT
- PowerShell 5.1+
- ActiveDirectory module (`RSAT-AD-PowerShell`)
- GroupPolicy module (`GPMC`) — for `Get-ADHealthReport.ps1` and `Backup-GPOs.ps1`
- Domain admin or delegated permissions

## Quick start

```powershell
# 1. Bulk-create users from CSV (dry run first)
.\New-BulkUsers.ps1 -CsvPath .\sample-data\users-sample.csv -WhatIf

# 2. Run for real
.\New-BulkUsers.ps1 -CsvPath .\sample-data\users-sample.csv

# 3. Generate health report and open in browser
.\Get-ADHealthReport.ps1 -Open

# 4. Schedule weekly report (every Monday 07:00)
.\Get-ADHealthReport.ps1 -Register

# 5. Backup all GPOs, keep 30 days
.\Backup-GPOs.ps1 -BackupRoot D:\GPO-Backups -KeepDays 30
```

## CSV format

```csv
FirstName,LastName,Department,Title,OU,Manager,Groups
Ivan,Petrov,IT,SysAdmin,"OU=IT,OU=Staff,DC=contoso,DC=local",a.sidorov,IT-Staff;VPN-Users
```

- **OU** — DistinguishedName of target OU. Falls back to `CN=Users` if empty.
- **Manager** — SamAccountName of manager. Skipped with a warning if not found.
- **Groups** — Semicolon-separated group names. Groups not found are warned, not fatal.

See [`sample-data/users-sample.csv`](sample-data/users-sample.csv) for a 10-user example.

## Health report sections

- Summary cards (enabled/disabled users, locked, inactive, password-never-expires)
- Password policy table
- Domain controller list
- Locked accounts
- Inactive users (configurable threshold, default 90 days)
- Password never expires
- Passwords not changed in 180+ days
- Empty groups
- Accounts created in last 30 days

## GPO backup layout

```
gpo-backups/
└── GPO-Backup-20240923_082500/
    ├── manifest.csv          # GPO name, GUID, backup ID, status
    ├── {GUID-1}/             # Backup-GPO output per GPO
    ├── {GUID-2}/
    └── ...
```

## Repository layout

```
ad-powershell-toolkit/
├── New-BulkUsers.ps1
├── Get-ADHealthReport.ps1
├── Backup-GPOs.ps1
└── sample-data/
    ├── users-sample.csv      # 10 users, 3 departments
    └── output-sample.txt     # Console output examples
```

## Tested on

| Environment | Version |
|---|---|
| Windows Server | 2019, 2022 |
| PowerShell | 5.1 |
| AD forest / domain functional level | 2016 |
