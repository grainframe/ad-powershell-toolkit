#Requires -Modules ActiveDirectory, GroupPolicy
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Generates an HTML health report for an Active Directory domain.

.DESCRIPTION
    Collects: user statistics, inactive accounts, password policy issues,
    locked accounts, empty groups, and DC replication status.
    Outputs a single self-contained HTML file.
    Run with -Register to install a weekly Scheduled Task.

.PARAMETER OutputPath
    Path for the HTML report.
    Default: .\reports\ad-health-<timestamp>.html

.PARAMETER InactiveDays
    Accounts with no login for this many days are flagged as inactive.
    Default: 90

.PARAMETER Register
    Install a weekly Scheduled Task that runs this report every Monday at 07:00.

.PARAMETER Open
    Open the report in the default browser after generation.

.EXAMPLE
    .\Get-ADHealthReport.ps1

.EXAMPLE
    .\Get-ADHealthReport.ps1 -InactiveDays 60 -Open

.EXAMPLE
    .\Get-ADHealthReport.ps1 -Register
#>
[CmdletBinding()]
param (
    [string]$OutputPath   = ".\reports\ad-health-$(Get-Date -Format 'yyyyMMdd_HHmmss').html",
    [int]   $InactiveDays = 90,
    [switch]$Register,
    [switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Scheduled Task registration ────────────────────────────────────────────────
if ($Register) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                   -Argument "-NonInteractive -NoProfile -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '07:00'
    $settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -WakeToRun

    Register-ScheduledTask -TaskName 'AD-HealthReport-Weekly' `
        -Action $action -Trigger $trigger -Settings $settings `
        -Description 'Weekly AD health report — ad-powershell-toolkit' `
        -RunLevel Highest -Force | Out-Null

    Write-Host "[OK] Scheduled task registered: AD-HealthReport-Weekly (every Monday 07:00)" -ForegroundColor Green
    return
}

# ── Collect data ───────────────────────────────────────────────────────────────
Write-Host "Collecting AD data..." -ForegroundColor Cyan

$domain      = Get-ADDomain
$cutoffDate  = (Get-Date).AddDays(-$InactiveDays)
$reportDate  = Get-Date -Format 'yyyy-MM-dd HH:mm'
$sw          = [System.Diagnostics.Stopwatch]::StartNew()

# All users (exclude built-ins)
$allUsers = Get-ADUser -Filter { ObjectClass -eq 'user' } `
    -Properties LastLogonDate, PasswordNeverExpires, PasswordLastSet,
                LockedOut, Enabled, Department, Title, WhenCreated |
    Where-Object { $_.DistinguishedName -notlike '*CN=Builtin*' }

$enabledUsers   = $allUsers | Where-Object { $_.Enabled }
$disabledUsers  = $allUsers | Where-Object { -not $_.Enabled }

# Inactive (enabled but no logon in X days)
$inactiveUsers  = $enabledUsers | Where-Object {
    $_.LastLogonDate -lt $cutoffDate -or -not $_.LastLogonDate
}

# Password never expires
$pwdNoExpire    = $enabledUsers | Where-Object { $_.PasswordNeverExpires }

# Locked out
$lockedUsers    = $enabledUsers | Where-Object { $_.LockedOut }

# Password not changed in 180+ days (enabled)
$stalePwd       = $enabledUsers | Where-Object {
    $_.PasswordLastSet -lt (Get-Date).AddDays(-180) -or -not $_.PasswordLastSet
}

# Accounts created last 30 days
$recentUsers    = $allUsers | Where-Object { $_.WhenCreated -gt (Get-Date).AddDays(-30) }

# Empty groups
$emptyGroups    = Get-ADGroup -Filter * -Properties Members |
                  Where-Object { $_.Members.Count -eq 0 }

# DC replication status
$dcs = Get-ADDomainController -Filter * | Select-Object Name, OperatingSystem,
       IsGlobalCatalog, IsReadOnly,
       @{ N='Site'; E={ $_.Site } }

# Password policy
$pwdPolicy = Get-ADDefaultDomainPasswordPolicy

$sw.Stop()
Write-Host "Data collected in $($sw.Elapsed.TotalSeconds.ToString('F1'))s" -ForegroundColor Green

# ── Build HTML ────────────────────────────────────────────────────────────────

function ConvertTo-HtmlTable {
    param([object[]]$Data, [string[]]$Properties)
    if (-not $Data -or $Data.Count -eq 0) { return '<p><em>None</em></p>' }
    $header = ($Properties | ForEach-Object { "<th>$_</th>" }) -join ''
    $rows   = $Data | ForEach-Object {
        $obj = $_
        $cells = $Properties | ForEach-Object { "<td>$($obj.$_)</td>" }
        "<tr>$($cells -join '')</tr>"
    }
    return "<table><thead><tr>$header</tr></thead><tbody>$($rows -join '')</tbody></table>"
}

$inactiveTable = ConvertTo-HtmlTable -Data (
    $inactiveUsers | Select-Object Name, SamAccountName, Department,
        @{ N='LastLogon'; E={ if ($_.LastLogonDate) { $_.LastLogonDate.ToString('yyyy-MM-dd') } else { 'Never' } } } |
    Sort-Object LastLogon
) -Properties Name, SamAccountName, Department, LastLogon

$lockedTable = ConvertTo-HtmlTable -Data (
    $lockedUsers | Select-Object Name, SamAccountName, Department
) -Properties Name, SamAccountName, Department

$pwdNoExpireTable = ConvertTo-HtmlTable -Data (
    $pwdNoExpire | Select-Object Name, SamAccountName, Department, Title |
    Sort-Object Department
) -Properties Name, SamAccountName, Department, Title

$stalePwdTable = ConvertTo-HtmlTable -Data (
    $stalePwd | Select-Object Name, SamAccountName,
        @{ N='PasswordLastSet'; E={ if ($_.PasswordLastSet) { $_.PasswordLastSet.ToString('yyyy-MM-dd') } else { 'Never' } } } |
    Sort-Object PasswordLastSet
) -Properties Name, SamAccountName, PasswordLastSet

$dcTable = ConvertTo-HtmlTable -Data ($dcs | Sort-Object Name) `
    -Properties Name, OperatingSystem, Site, IsGlobalCatalog, IsReadOnly

$emptyGroupTable = ConvertTo-HtmlTable -Data (
    $emptyGroups | Select-Object Name, GroupScope, GroupCategory | Sort-Object Name
) -Properties Name, GroupScope, GroupCategory

$recentTable = ConvertTo-HtmlTable -Data (
    $recentUsers | Select-Object Name, SamAccountName, Department,
        @{ N='Created'; E={ $_.WhenCreated.ToString('yyyy-MM-dd') } } |
    Sort-Object Created -Descending
) -Properties Name, SamAccountName, Department, Created

$statusColor  = if ($lockedUsers.Count -gt 0 -or $inactiveUsers.Count -gt 10) { '#e74c3c' } else { '#27ae60' }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>AD Health Report — $($domain.DNSRoot)</title>
<style>
  body      { font-family: Segoe UI, Arial, sans-serif; font-size: 14px; background: #f4f6f8; color: #2c3e50; margin: 0; }
  .wrap     { max-width: 1100px; margin: 0 auto; padding: 24px; }
  h1        { background: #2c3e50; color: #fff; margin: 0; padding: 20px 24px; border-radius: 6px 6px 0 0; }
  h2        { color: #2c3e50; border-left: 4px solid #3498db; padding-left: 10px; margin-top: 32px; }
  .meta     { background: #fff; padding: 12px 24px; margin-bottom: 24px; border-radius: 0 0 6px 6px;
              box-shadow: 0 1px 4px rgba(0,0,0,.1); font-size: 13px; color: #7f8c8d; }
  .cards    { display: flex; gap: 16px; flex-wrap: wrap; margin: 20px 0; }
  .card     { background: #fff; border-radius: 6px; padding: 16px 20px; min-width: 160px;
              box-shadow: 0 1px 4px rgba(0,0,0,.1); flex: 1; }
  .card .n  { font-size: 36px; font-weight: 700; }
  .card .l  { font-size: 12px; color: #7f8c8d; margin-top: 4px; }
  .ok       { color: #27ae60; }
  .warn     { color: #e67e22; }
  .crit     { color: #e74c3c; }
  table     { width: 100%; border-collapse: collapse; background: #fff;
              border-radius: 6px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,.1); margin-bottom: 8px; }
  th        { background: #2c3e50; color: #fff; padding: 10px 12px; text-align: left; font-size: 13px; }
  td        { padding: 8px 12px; border-bottom: 1px solid #ecf0f1; font-size: 13px; }
  tr:last-child td { border-bottom: none; }
  tr:nth-child(even) td { background: #fafbfc; }
  .section  { background: #fff; border-radius: 6px; padding: 20px 24px;
              box-shadow: 0 1px 4px rgba(0,0,0,.1); margin-bottom: 20px; }
  .badge    { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 12px; font-weight: 600; }
  .badge-ok   { background: #d5f5e3; color: #1e8449; }
  .badge-warn { background: #fef9e7; color: #b7950b; }
  .badge-crit { background: #fadbd8; color: #c0392b; }
  em        { color: #7f8c8d; }
</style>
</head>
<body>
<div class="wrap">
<h1>🖥 Active Directory Health Report</h1>
<div class="meta">
  Domain: <strong>$($domain.DNSRoot)</strong> &nbsp;|&nbsp;
  Forest: <strong>$($domain.Forest)</strong> &nbsp;|&nbsp;
  Generated: <strong>$reportDate</strong> &nbsp;|&nbsp;
  Inactive threshold: <strong>$InactiveDays days</strong>
</div>

<div class="cards">
  <div class="card"><div class="n ok">$($enabledUsers.Count)</div><div class="l">Enabled users</div></div>
  <div class="card"><div class="n">$($disabledUsers.Count)</div><div class="l">Disabled users</div></div>
  <div class="card"><div class="n $(if ($inactiveUsers.Count -gt 10) { 'warn' } else { 'ok' })">$($inactiveUsers.Count)</div><div class="l">Inactive $InactiveDays+ days</div></div>
  <div class="card"><div class="n $(if ($lockedUsers.Count -gt 0) { 'crit' } else { 'ok' })">$($lockedUsers.Count)</div><div class="l">Locked out</div></div>
  <div class="card"><div class="n $(if ($pwdNoExpire.Count -gt 5) { 'warn' } else { 'ok' })">$($pwdNoExpire.Count)</div><div class="l">Password never expires</div></div>
  <div class="card"><div class="n">$($emptyGroups.Count)</div><div class="l">Empty groups</div></div>
  <div class="card"><div class="n">$($dcs.Count)</div><div class="l">Domain controllers</div></div>
  <div class="card"><div class="n ok">$($recentUsers.Count)</div><div class="l">New accounts (30d)</div></div>
</div>

<div class="section">
<h2>Password Policy</h2>
<table>
<thead><tr><th>Setting</th><th>Value</th></tr></thead>
<tbody>
<tr><td>Minimum length</td><td>$($pwdPolicy.MinPasswordLength)</td></tr>
<tr><td>Maximum age</td><td>$($pwdPolicy.MaxPasswordAge.Days) days</td></tr>
<tr><td>Minimum age</td><td>$($pwdPolicy.MinPasswordAge.Days) days</td></tr>
<tr><td>Complexity required</td><td>$($pwdPolicy.ComplexityEnabled)</td></tr>
<tr><td>Lockout threshold</td><td>$($pwdPolicy.LockoutThreshold) attempts</td></tr>
<tr><td>Lockout duration</td><td>$($pwdPolicy.LockoutDuration.TotalMinutes) min</td></tr>
<tr><td>History</td><td>$($pwdPolicy.PasswordHistoryCount) passwords</td></tr>
</tbody>
</table>
</div>

<div class="section">
<h2>Domain Controllers ($($dcs.Count))</h2>
$dcTable
</div>

<div class="section">
<h2>Locked Accounts
  <span class="badge $(if ($lockedUsers.Count -gt 0) { 'badge-crit' } else { 'badge-ok' })">$($lockedUsers.Count)</span>
</h2>
$lockedTable
</div>

<div class="section">
<h2>Inactive Users ($InactiveDays+ days, enabled only)
  <span class="badge $(if ($inactiveUsers.Count -gt 10) { 'badge-warn' } else { 'badge-ok' })">$($inactiveUsers.Count)</span>
</h2>
$inactiveTable
</div>

<div class="section">
<h2>Password Never Expires
  <span class="badge $(if ($pwdNoExpire.Count -gt 0) { 'badge-warn' } else { 'badge-ok' })">$($pwdNoExpire.Count)</span>
</h2>
$pwdNoExpireTable
</div>

<div class="section">
<h2>Password Not Changed in 180+ Days
  <span class="badge $(if ($stalePwd.Count -gt 0) { 'badge-warn' } else { 'badge-ok' })">$($stalePwd.Count)</span>
</h2>
$stalePwdTable
</div>

<div class="section">
<h2>Empty Groups
  <span class="badge badge-warn">$($emptyGroups.Count)</span>
</h2>
$emptyGroupTable
</div>

<div class="section">
<h2>Accounts Created in Last 30 Days
  <span class="badge badge-ok">$($recentUsers.Count)</span>
</h2>
$recentTable
</div>

</div></body></html>
"@

# ── Write report ───────────────────────────────────────────────────────────────
$reportDir = Split-Path $OutputPath -Parent
if ($reportDir -and -not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

$html | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "[OK] Report saved: $OutputPath" -ForegroundColor Green

if ($Open) {
    Start-Process $OutputPath
}

Write-Host ''
Write-Host '============================================' -ForegroundColor Cyan
Write-Host " AD Health Report"
Write-Host " Domain  : $($domain.DNSRoot)"
Write-Host " Users   : $($enabledUsers.Count) enabled, $($disabledUsers.Count) disabled"
Write-Host " Locked  : $($lockedUsers.Count)"
Write-Host " Inactive: $($inactiveUsers.Count) (>${InactiveDays}d)"
Write-Host " Report  : $OutputPath"
Write-Host '============================================' -ForegroundColor Cyan
