#Requires -Modules GroupPolicy
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Backs up all Group Policy Objects with timestamp, manifest, and auto-rotation.

.DESCRIPTION
    Exports every GPO to a timestamped subfolder under BackupRoot.
    Writes a manifest CSV listing every GPO backed up.
    Removes sessions older than KeepDays to prevent disk fill.

.PARAMETER BackupRoot
    Root directory for backups. Each run creates a subfolder named
    GPO-Backup-<timestamp>.

.PARAMETER KeepDays
    Remove backup sessions older than this many days.
    Default: 30. Set to 0 to disable rotation.

.PARAMETER WhatIf
    Preview — show what would be backed up / deleted, make no changes.

.EXAMPLE
    .\Backup-GPOs.ps1

.EXAMPLE
    .\Backup-GPOs.ps1 -BackupRoot D:\GPO-Backups -KeepDays 60

.EXAMPLE
    .\Backup-GPOs.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param (
    [string]$BackupRoot = '.\gpo-backups',
    [int]   $KeepDays   = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$sessionDir = Join-Path $BackupRoot "GPO-Backup-$timestamp"
$manifestPath = Join-Path $sessionDir 'manifest.csv'

Write-Host "[INFO] Session: $sessionDir" -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($sessionDir, 'Create backup directory')) {
    New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
}

# ── Get all GPOs ───────────────────────────────────────────────────────────────
$gpos = Get-GPO -All | Sort-Object DisplayName
Write-Host "[INFO] Found $($gpos.Count) GPOs" -ForegroundColor Cyan

$sw       = [System.Diagnostics.Stopwatch]::StartNew()
$manifest = [System.Collections.Generic.List[PSObject]]::new()
$success  = 0
$failed   = 0

foreach ($gpo in $gpos) {
    $entry = [PSCustomObject]@{
        DisplayName = $gpo.DisplayName
        GpoId       = $gpo.Id.ToString()
        Status      = ''
        BackupId    = ''
        Error       = ''
        Timestamp   = $timestamp
    }

    try {
        if ($PSCmdlet.ShouldProcess($gpo.DisplayName, 'Backup GPO')) {
            $backup = Backup-GPO -Guid $gpo.Id -Path $sessionDir -ErrorAction Stop
            $entry.BackupId = $backup.Id.ToString()
            $entry.Status   = 'OK'
            $success++
            Write-Host "  [OK] $($gpo.DisplayName)" -ForegroundColor Green
        } else {
            $entry.Status = 'WhatIf'
        }
    } catch {
        $entry.Status = 'FAILED'
        $entry.Error  = $_.Exception.Message
        $failed++
        Write-Host "  [FAIL] $($gpo.DisplayName): $_" -ForegroundColor Red
    }

    $manifest.Add($entry)
}

# ── Write manifest ─────────────────────────────────────────────────────────────
if ($PSCmdlet.ShouldProcess($manifestPath, 'Write manifest')) {
    $manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
    Write-Host "[INFO] Manifest: $manifestPath" -ForegroundColor Cyan
}

# ── Rotate old backups ─────────────────────────────────────────────────────────
if ($KeepDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    $oldSessions = Get-ChildItem -Path $BackupRoot -Directory |
        Where-Object { $_.Name -like 'GPO-Backup-*' -and $_.CreationTime -lt $cutoff }

    if ($oldSessions) {
        Write-Host "[INFO] Rotating $($oldSessions.Count) session(s) older than $KeepDays days" -ForegroundColor Yellow
        foreach ($old in $oldSessions) {
            if ($PSCmdlet.ShouldProcess($old.FullName, 'Delete old backup session')) {
                Remove-Item -Path $old.FullName -Recurse -Force
                Write-Host "  [DEL] $($old.Name)" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host "[INFO] No sessions to rotate" -ForegroundColor Gray
    }
}

$sw.Stop()

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '============================================' -ForegroundColor Cyan
Write-Host " GPO Backup complete"
Write-Host " Total   : $($gpos.Count)"
Write-Host " Success : $success" -ForegroundColor Green
Write-Host " Failed  : $failed"  -ForegroundColor $(if ($failed) { 'Red' } else { 'Gray' })
Write-Host " Time    : $($sw.Elapsed.TotalSeconds.ToString('F1')) seconds"
Write-Host " Session : $sessionDir"
Write-Host '============================================' -ForegroundColor Cyan
