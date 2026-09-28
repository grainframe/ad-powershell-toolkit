#Requires -Modules ActiveDirectory
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bulk-creates Active Directory users from a CSV file.

.DESCRIPTION
    Reads a CSV, generates unique usernames, creates AD accounts with full
    attribute set, assigns group memberships, and writes a result log.
    Supports -WhatIf for dry-run preview before making changes.

.PARAMETER CsvPath
    Path to input CSV. Required columns:
    FirstName, LastName, Department, Title, OU, Manager, Groups
    Groups column: semicolon-separated group names (e.g. "IT-Staff;VPN-Users")

.PARAMETER DefaultPassword
    Initial password for all created accounts.
    Users are forced to change it on first logon.

.PARAMETER LogPath
    Path for the result CSV log.
    Default: .\logs\bulk-users-<timestamp>.csv

.EXAMPLE
    .\New-BulkUsers.ps1 -CsvPath .\sample-data\users-sample.csv

.EXAMPLE
    .\New-BulkUsers.ps1 -CsvPath .\users.csv -DefaultPassword 'TempP@ss1!' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param (
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$DefaultPassword = 'Welcome1!',

    [string]$LogPath = ".\logs\bulk-users-$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ────────────────────────────────────────────────────────────────────

function Write-Status {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) {
        'OK'   { 'Green'  }
        'FAIL' { 'Red'    }
        'WARN' { 'Yellow' }
        default { 'Cyan'  }
    }
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
}

# Generate a unique SamAccountName: first-initial + lastname, lowercase.
# Falls back to adding index suffixes on collision.
function Get-UniqueUsername {
    param([string]$First, [string]$Last)

    # Strip non-ASCII letters (basic; extend with transliteration as needed)
    $f = ($First -replace '[^a-zA-Z]', '').ToLower()
    $l = ($Last  -replace '[^a-zA-Z]', '').ToLower()

    $candidates = @(
        "$($f[0])$l"
        "$($f.Substring(0, [Math]::Min(2, $f.Length)))$l"
        "$f.$l"
        "$f$l"
    )

    foreach ($c in $candidates) {
        if ($c.Length -gt 20) { $c = $c.Substring(0, 20) }
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$c'" -ErrorAction SilentlyContinue)) {
            return $c
        }
    }

    # Last resort: append random suffix
    for ($i = 1; $i -le 999; $i++) {
        $c = "$($f[0])$l$i"
        if ($c.Length -gt 20) { $c = $c.Substring(0, 17) + $i }
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$c'" -ErrorAction SilentlyContinue)) {
            return $c
        }
    }

    throw "Cannot generate a unique username for $First $Last after 999 attempts."
}

# ── Main ───────────────────────────────────────────────────────────────────────

$domain     = Get-ADDomain
$domainDN   = $domain.DistinguishedName
$domainFQDN = $domain.DNSRoot

$securePass = ConvertTo-SecureString $DefaultPassword -AsPlainText -Force

$users = Import-Csv -Path $CsvPath
Write-Status "Loaded $($users.Count) users from $CsvPath"

# Ensure log directory exists
$logDir = Split-Path $LogPath -Parent
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$results = [System.Collections.Generic.List[PSObject]]::new()

$sw       = [System.Diagnostics.Stopwatch]::StartNew()
$created  = 0
$skipped  = 0
$failed   = 0

foreach ($row in $users) {
    $result = [PSCustomObject]@{
        Row        = $users.IndexOf($row) + 1
        FirstName  = $row.FirstName
        LastName   = $row.LastName
        Username   = ''
        Email      = ''
        Status     = ''
        Error      = ''
    }

    try {
        # Resolve OU — use row value or fall back to default Users container
        $targetOU = if ($row.OU) { $row.OU } else { "CN=Users,$domainDN" }

        # Validate OU exists
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$targetOU'" -ErrorAction SilentlyContinue) -and
            -not (Get-ADObject -Filter "DistinguishedName -eq '$targetOU'" -ErrorAction SilentlyContinue)) {
            throw "OU not found: $targetOU"
        }

        $username = Get-UniqueUsername -First $row.FirstName -Last $row.LastName
        $email    = "$username@$domainFQDN"
        $upn      = $email

        $result.Username = $username
        $result.Email    = $email

        # Skip if user already exists
        if (Get-ADUser -Filter "SamAccountName -eq '$username'" -ErrorAction SilentlyContinue) {
            Write-Status "SKIP: $username already exists" 'WARN'
            $result.Status = 'Skipped - already exists'
            $skipped++
            continue
        }

        $newUserParams = @{
            SamAccountName        = $username
            UserPrincipalName     = $upn
            Name                  = "$($row.FirstName) $($row.LastName)"
            GivenName             = $row.FirstName
            Surname               = $row.LastName
            DisplayName           = "$($row.FirstName) $($row.LastName)"
            EmailAddress          = $email
            Department            = $row.Department
            Title                 = $row.Title
            Path                  = $targetOU
            AccountPassword       = $securePass
            ChangePasswordAtLogon = $true
            Enabled               = $true
        }

        # Resolve manager DN if provided
        if ($row.Manager) {
            $mgr = Get-ADUser -Filter "SamAccountName -eq '$($row.Manager)'" -ErrorAction SilentlyContinue
            if ($mgr) { $newUserParams['Manager'] = $mgr.DistinguishedName }
            else { Write-Status "Manager '$($row.Manager)' not found — skipped" 'WARN' }
        }

        if ($PSCmdlet.ShouldProcess($username, 'Create AD user')) {
            New-ADUser @newUserParams

            # Assign groups
            if ($row.Groups) {
                foreach ($groupName in ($row.Groups -split ';')) {
                    $groupName = $groupName.Trim()
                    if (-not $groupName) { continue }
                    $grp = Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue
                    if ($grp) {
                        Add-ADGroupMember -Identity $grp -Members $username
                    } else {
                        Write-Status "Group '$groupName' not found for $username" 'WARN'
                    }
                }
            }

            Write-Status "Created: $username ($($row.FirstName) $($row.LastName))" 'OK'
            $result.Status = 'Created'
            $created++
        } else {
            $result.Status = 'WhatIf'
        }

    } catch {
        Write-Status "FAIL: $($row.FirstName) $($row.LastName) — $_" 'FAIL'
        $result.Status = 'Failed'
        $result.Error  = $_.Exception.Message
        $failed++
    }

    $results.Add($result)
}

$sw.Stop()

# ── Write log ─────────────────────────────────────────────────────────────────
$results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
Write-Status "Log saved: $LogPath"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '============================================' -ForegroundColor Cyan
Write-Host " Bulk user creation complete"
Write-Host " Total   : $($users.Count)"
Write-Host " Created : $created" -ForegroundColor Green
Write-Host " Skipped : $skipped" -ForegroundColor Yellow
Write-Host " Failed  : $failed"  -ForegroundColor $(if ($failed) { 'Red' } else { 'Gray' })
Write-Host " Time    : $($sw.Elapsed.TotalSeconds.ToString('F1')) seconds"
Write-Host '============================================' -ForegroundColor Cyan
