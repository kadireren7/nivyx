#Requires -Version 5.1
<#
.SYNOPSIS
  Installs Nivyx transparent mode on Windows as the "dpi-proxy"
  service: after this, HTTPS and DNS from every application go through
  the automatic DPI bypass, with no proxy or DNS settings anywhere.

.DESCRIPTION
  Run from the unpacked release folder, in an elevated PowerShell:
      powershell -ExecutionPolicy Bypass -File .\install.ps1

  Installs (and scripts\windows\uninstall.ps1 removes exactly that):
    %ProgramFiles%\dpi-proxy\   dpi-proxy.exe, WinDivert.dll,
                                WinDivert64.sys, WinDivert-LICENSE.txt,
                                nivyx.cmd, nivyx-impl.ps1, nivyx-completion.ps1,
                                uninstall.ps1
    %ProgramData%\dpi-proxy\    strategy.conf (kept on reinstall),
                                learned decisions, status, log
    service "dpi-proxy"         automatic start, restart on failure
    firewall rule "dpi-proxy"   inbound allow for dpi-proxy.exe only
    machine PATH                + %ProgramFiles%\dpi-proxy

  WinDivert (https://reqrypt.org/windivert.html) is a third-party,
  signed packet-capture driver (LGPLv3/GPLv2) that dpi-proxy uses to
  redirect this machine's own outgoing HTTPS/DNS to itself. Windows
  loads it when the service starts. Some antivirus products flag it
  as "riskware" because DPI-bypass tools use it; it is the unmodified
  official build (see WinDivert-LICENSE.txt).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Service   = 'dpi-proxy'
$InstDir   = Join-Path $env:ProgramFiles 'dpi-proxy'
$DataDir   = Join-Path $env:ProgramData 'dpi-proxy'
$StatusFile = Join-Path $DataDir 'transparent.status'
$Src       = $PSScriptRoot

function Log($m) { Write-Host "[install] $m" }
function Fail($m) { Write-Host "[install] ERROR: $m" -ForegroundColor Red }

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'this installer sets up a system service and needs an elevated (Administrator) PowerShell.'
    exit 1
}

# One install/update/repair/uninstall at a time (install.ps1, uninstall.ps1,
# nivyx update and repair share it): a machine-wide named mutex. Windows
# releases it when its holder exits, also when the holder crashes.
function Enter-AdminLock([string]$who) {
    $script:AdminLock = New-Object System.Threading.Mutex($false, 'Global\NivyxAdminLock')
    $got = $false
    try { $got = $script:AdminLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) {
        Write-Host "${who}another Nivyx install, update, repair or uninstall is running; try again when it has finished"
        exit 1
    }
}
Enter-AdminLock '[install] ERROR: '

# Files come from the release folder (next to this script) or, in a
# source checkout, from the repository root.
$need = 'dpi-proxy.exe', 'WinDivert.dll', 'WinDivert64.sys'
$from = $Src
if (-not (Test-Path (Join-Path $from 'dpi-proxy.exe'))) {
    $from = Resolve-Path (Join-Path $Src '..\..')
}
foreach ($f in $need) {
    if (-not (Test-Path (Join-Path $from $f))) {
        Fail "missing $f (looked in $Src and $from)"
        exit 2
    }
}

Log '[1/6] Third-party component notice'
Write-Host '  Nivyx uses the WinDivert driver (signed, LGPLv3/GPLv2,'
Write-Host '  https://reqrypt.org/windivert.html) to redirect this machine''s own'
Write-Host '  outgoing HTTPS and DNS to the local Nivyx service. It does not'
Write-Host '  decrypt anything and does not send traffic to any remote server.'

# An upgrade backs up the installed program folder first: if the new
# version fails, the previous one is put back and started again.
$hadService = [bool](Get-Service $Service -ErrorAction SilentlyContinue)
$backup = $null
if ($hadService -and (Test-Path (Join-Path $InstDir 'dpi-proxy.exe'))) {
    $backup = Join-Path $env:ProgramData ('nivyx-install-backup-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $backup | Out-Null
        Copy-Item (Join-Path $InstDir '*') $backup -Recurse -Force -ErrorAction Stop
    } catch {
        Fail "cannot back up the current installation ($($_.Exception.Message)); nothing was changed"
        Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
        exit 2
    }
}

function Stop-WinDivertDriver {
    $wd = Get-Service WinDivert -ErrorAction SilentlyContinue
    if ($wd -and $wd.Status -ne 'Stopped' -and
        -not (Get-Process -Name goodbyedpi, winws -ErrorAction SilentlyContinue)) {
        & sc.exe stop WinDivert | Out-Null
        foreach ($i in 1..20) {
            if ((Get-Service WinDivert -ErrorAction SilentlyContinue).Status -eq 'Stopped') { break }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Register-NivyxService {
    # New-Service, not sc.exe: PowerShell would mangle the quoted path
    New-Service -Name $Service -BinaryPathName "`"$(Join-Path $InstDir 'dpi-proxy.exe')`" --service" `
        -StartupType Automatic -DisplayName 'dpi-proxy (automatic DPI bypass)' `
        -Description 'Redirects outgoing HTTPS and DNS to a local DPI-bypass proxy (WinDivert). Stopping it restores ordinary networking.' | Out-Null
    & sc.exe failure $Service reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null
}

# engine: running, written by the process the service manager started
function Wait-EngineRunning([int]$halfSeconds) {
    foreach ($i in 1..$halfSeconds) {
        Start-Sleep -Milliseconds 500
        $w = Get-CimInstance Win32_Service -Filter "Name='$Service'" -ErrorAction SilentlyContinue
        if ($w -and $w.State -eq 'Running' -and $w.ProcessId -and (Test-Path $StatusFile) -and
            (Select-String -Path $StatusFile -Pattern '^engine: running' -Quiet) -and
            (Select-String -Path $StatusFile -Pattern "^pid: $($w.ProcessId)$" -Quiet)) { return $true }
    }
    return $false
}

$installed = $false
try {
    Log '[2/6] Stopping a previous installation (if any)...'
    if (Get-Service $Service -ErrorAction SilentlyContinue) {
        Stop-Service $Service -Force -ErrorAction SilentlyContinue
        & sc.exe delete $Service | Out-Null
        Start-Sleep -Seconds 1
    }
    # The WinDivert driver stays loaded after our service stops and keeps
    # WinDivert64.sys locked, which would make an upgrade fail halfway.
    # Unload it unless another WinDivert-based tool is using it.
    Stop-WinDivertDriver

    Log "[3/6] Installing files to $InstDir ..."
    New-Item -ItemType Directory -Force -Path $InstDir, $DataDir | Out-Null
    # Files identical to what is already installed are not rewritten (the
    # unmodified WinDivert files never change between releases, and a copy
    # over a still-loaded driver would fail).
    function Get-Sha256Of([string]$path) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $fs = [System.IO.File]::OpenRead($path)
        try { return [BitConverter]::ToString($sha.ComputeHash($fs)) } finally { $fs.Dispose(); $sha.Dispose() }
    }
    foreach ($f in $need) {
        # (not $src/$dst: PowerShell names are case-insensitive and $Src is the script folder)
        $fromFile = Join-Path $from $f
        $toFile = Join-Path $InstDir $f
        if ((Test-Path $toFile) -and ((Get-Sha256Of $fromFile) -eq (Get-Sha256Of $toFile))) { continue }
        Copy-Item $fromFile $InstDir -Force
    }
    foreach ($f in 'WinDivert-LICENSE.txt') {
        if (Test-Path (Join-Path $from $f)) { Copy-Item (Join-Path $from $f) $InstDir -Force }
    }
    foreach ($f in 'nivyx-impl.ps1', 'nivyx.cmd', 'uninstall.ps1', 'Uninstall Nivyx.cmd') {
        $p = Join-Path $Src $f
        if (-not (Test-Path $p)) { $p = Join-Path $from "scripts\windows\$f" }
        Copy-Item $p $InstDir -Force
    }
    # optional PowerShell tab completion (package: nivyx-completion.ps1; source tree: scripts\completions\nivyx.ps1)
    foreach ($c in (Join-Path $Src 'nivyx-completion.ps1'), (Join-Path $from 'scripts\completions\nivyx.ps1')) {
        if (Test-Path $c) { Copy-Item $c (Join-Path $InstDir 'nivyx-completion.ps1') -Force; break }
    }
    # Upgrade from v2.1 or earlier: the old command wrappers lived in our
    # own install folder; nothing outside it is touched.
    foreach ($old in 'dpictl.cmd', 'dpi-proxy-ctl.cmd', 'dpictl-impl.ps1') {
        $p = Join-Path $InstDir $old
        if (Test-Path $p) { Remove-Item $p -Force; Log "  removed legacy command file $old (use: nivyx)" }
    }
    $conf = Join-Path $DataDir 'strategy.conf'
    if (-not (Test-Path $conf)) {
        @(
            '# dpi-proxy manual rules. Transparent mode needs none: known-blocked'
            '# hosts (Discord and a few others, built in) get the bypass straight'
            '# away; any other host is tried directly first and learns a bypass only'
            '# if it needs one. Stream strategies: pass | tlsrec | tlsrec-split'
            '#'
            '# [domains]'
            '# example.com = tlsrec'
            'default = pass'
        ) | Set-Content -Encoding ASCII $conf
    }

    Log '[4/6] Firewall rule and PATH...'
    $exe = Join-Path $InstDir 'dpi-proxy.exe'
    # Redirected connections arrive at the service as inbound traffic;
    # the service itself refuses anything it did not redirect.
    Get-NetFirewallRule -Name $Service -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -Name $Service -DisplayName 'dpi-proxy (redirected local traffic)' `
        -Direction Inbound -Program $exe -Action Allow -Profile Any | Out-Null
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($path -split ';') -notcontains $InstDir) {
        [Environment]::SetEnvironmentVariable('Path', "$path;$InstDir", 'Machine')
    }

    Log '[5/6] Creating and starting the service...'
    Register-NivyxService
    Remove-Item $StatusFile -ErrorAction SilentlyContinue
    Start-Service $Service

    Log '[6/6] Checking health...'
    $ok = Wait-EngineRunning 40
    if (-not $ok) { throw "the engine did not report running within 20 s (service: $((Get-Service $Service).Status))" }
    $enginePid = (Get-CimInstance Win32_Service -Filter "Name='$Service'").ProcessId
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    try { Resolve-DnsName example.com -Type A -ErrorAction Stop | Out-Null }
    catch { throw "name resolution through the service failed: $_" }
    try { Invoke-WebRequest -Uri 'https://example.com/' -UseBasicParsing -TimeoutSec 20 | Out-Null }
    catch { throw "HTTPS check through the service failed: $_" }
    # Fail-open means these checks would also pass with the engine gone
    # (traffic then goes out directly): they only prove the engine if the
    # same engine process is still running afterwards.
    $after = Get-CimInstance Win32_Service -Filter "Name='$Service'"
    if ($after.State -ne 'Running' -or $after.ProcessId -ne $enginePid) {
        throw 'the engine stopped during the DNS/HTTPS check'
    }
    $installed = $true
}
catch {
    Fail "$_"
    $log = Join-Path $DataDir 'dpi-proxy.log'
    if (Test-Path $log) {
        Write-Host "[install] last lines of ${log}:"
        Get-Content $log -Tail 15 | ForEach-Object { Write-Host "    $_" }
    }
    Fail 'stopping and removing the service (fail-open: networking returns to normal)'
    Stop-Service $Service -Force -ErrorAction SilentlyContinue
    & sc.exe delete $Service 2>$null | Out-Null
    if ($backup) {
        Fail 'putting the previous version back'
        $restored = $false
        try {
            Start-Sleep -Seconds 1
            Stop-WinDivertDriver
            Copy-Item (Join-Path $backup '*') $InstDir -Recurse -Force -ErrorAction Stop
            Register-NivyxService
            Remove-Item $StatusFile -ErrorAction SilentlyContinue
            Start-Service $Service
            $restored = Wait-EngineRunning 40
        } catch { Fail "restoring failed: $($_.Exception.Message)" }
        if ($restored) {
            Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
            Fail 'the previous version is back and running; nothing else was changed'
        } else {
            Fail "could not start the previous version again; its files are kept in $backup"
            Fail 'networking works normally (fail-open); run nivyx repair, or install a working version'
            exit 5
        }
    }
    exit 4
}
if ($backup) { Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue }

$other = Get-Process -Name goodbyedpi, winws -ErrorAction SilentlyContinue
Write-Host ''
Log 'Done. Nivyx is running and starts automatically at boot.'
Write-Host '  HTTPS and DNS from all applications now go through the automatic'
Write-Host '  bypass; no browser/app proxy settings and no DNS changes are needed.'
Write-Host ''
Write-Host '  Status:     .\nivyx status      (in a new window: nivyx status)'
Write-Host '  Doctor:     nivyx doctor'
Write-Host '  Logs:       nivyx logs'
Write-Host '  Stop:       nivyx stop          (networking keeps working, unbypassed)'
Write-Host "  Uninstall:  powershell -ExecutionPolicy Bypass -File `"$InstDir\uninstall.ps1`""
if ($other) {
    Write-Host ''
    Write-Host '  WARNING: another WinDivert-based DPI tool is running' -ForegroundColor Yellow
    Write-Host "  ($(($other | Select-Object -Expand Name -Unique) -join ', ')); stop it, the two will interfere." -ForegroundColor Yellow
}
