#Requires -Version 5.1
<#
.SYNOPSIS
  Removes everything install.ps1 installed: the "nivyx" service,
  %ProgramFiles%\Nivyx, its firewall rule and PATH entry, and the
  WinDivert driver service if no other program is using it. Leftovers of
  v2.4.0 and earlier ("dpi-proxy") are removed too.
  %ProgramData%\Nivyx (manual rules, learned decisions, log) is kept
  unless -Purge is given. Needs an elevated PowerShell.
#>
[CmdletBinding()]
param([switch]$Purge)

$ErrorActionPreference = 'Continue'
$Service = 'nivyx'
$InstDir = Join-Path $env:ProgramFiles 'Nivyx'
$DataDir = Join-Path $env:ProgramData 'Nivyx'
$OldService = 'dpi-proxy'
$OldInstDir = Join-Path $env:ProgramFiles 'dpi-proxy'
$OldDataDir = Join-Path $env:ProgramData 'dpi-proxy'

function Log($m) { Write-Host "[uninstall] $m" }

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[uninstall] ERROR: needs an elevated (Administrator) PowerShell.' -ForegroundColor Red
    exit 1
}

# One install/update/repair/uninstall at a time: a machine-wide named
# mutex, released by Windows when its holder exits or crashes.
function Enter-AdminLock([string]$who) {
    $script:AdminLock = New-Object System.Threading.Mutex($false, 'Global\NivyxAdminLock')
    $got = $false
    try { $got = $script:AdminLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) {
        Write-Host "${who}another Nivyx install, update, repair or uninstall is running; try again when it has finished"
        exit 1
    }
}
Enter-AdminLock '[uninstall] ERROR: '

foreach ($s in $Service, $OldService) {
    if (Get-Service $s -ErrorAction SilentlyContinue) {
        Log "stopping and removing the service $s"
        Stop-Service $s -Force -ErrorAction SilentlyContinue
        & sc.exe delete $s | Out-Null
    }
    Get-NetFirewallRule -Name $s -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}
$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$kept = ($path -split ';') | Where-Object { $_ -and $_ -ne $InstDir -and $_ -ne $OldInstDir }
[Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'Machine')

# The WinDivert driver is shared by every WinDivert-based program; only
# unload it if nothing else is using it (otherwise Windows removes it at
# the next reboot, once no program loads it any more).
$other = Get-Process -Name goodbyedpi, winws -ErrorAction SilentlyContinue
if (-not $other -and (Get-Service WinDivert -ErrorAction SilentlyContinue)) {
    Log 'unloading the WinDivert driver'
    & sc.exe stop WinDivert | Out-Null
    & sc.exe delete WinDivert | Out-Null
} elseif ($other) {
    Log 'another WinDivert program is running; leaving the driver loaded'
}

foreach ($d in $InstDir, $OldInstDir) {
    if (-not (Test-Path $d)) { continue }
    Log "removing $d"
    # this script may be running from there: remove everything else first
    Get-ChildItem $d | Where-Object { $_.FullName -ne $PSCommandPath } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    if ($PSCommandPath -and $PSCommandPath.StartsWith($d)) {
        Start-Process -WindowStyle Hidden cmd.exe "/c timeout /t 2 >nul & rmdir /s /q `"$d`""
    } else {
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($Purge) {
    foreach ($d in $DataDir, $OldDataDir) {
        if (Test-Path $d) { Log "removing $d"; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    foreach ($d in $DataDir, $OldDataDir) {
        if (Test-Path $d) { Log "kept $d (manual rules, learned decisions, log); -Purge removes it" }
    }
}
Log 'done; networking is back to normal'
