#Requires -Version 5.1
<#
  An install made by an older release must be able to move to the
  candidate through that release's OWN `nivyx update`: the old updater
  only accepts a package laid out the way it expects (dpi-proxy.exe,
  WinDivert.dll and nivyx-impl.ps1 at the top of nivyx-windows-x86_64,
  "dpi-proxy <version>" from --version). CI: windows-latest,
  Administrator, real WinDivert. Uninstalls at the end.

    powershell -ExecutionPolicy Bypass -File update-compat-test.ps1 `
        -OldPackage <dir> -NewPackage <dir> [-NewZip <zip>]

  -NewZip: the exact archive that would be published (release workflow);
  without it the candidate folder is zipped here.
#>
param(
    [Parameter(Mandatory = $true)][string]$OldPackage,
    [Parameter(Mandatory = $true)][string]$NewPackage,
    [string]$NewZip
)

$ErrorActionPreference = 'Stop'
$DataDir    = Join-Path $env:ProgramData 'dpi-proxy'
$StatusFile = Join-Path $DataDir 'transparent.status'
$LogFile    = Join-Path $DataDir 'dpi-proxy.log'
$InstDir    = Join-Path $env:ProgramFiles 'dpi-proxy'
$Conf       = Join-Path $DataDir 'strategy.conf'
$script:step = 0

function Step($m) { $script:step++; Write-Host "`n=== [$script:step] $m" }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }
function Die($m) {
    Write-Host "FAIL: $m" -ForegroundColor Red
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 60 }
    if (Test-Path $StatusFile) { Get-Content $StatusFile }
    exit 1
}
function Field($name) {
    $m = Select-String -Path $StatusFile -Pattern "^${name}: (.*)$" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value } else { return '' }
}
# ---- OpenSSL configuration loading (see src/tlsclient.c) -------------------
# A harmless but unmistakable configuration: if it is applied, no algorithm
# can be fetched (fips=yes, no FIPS provider), TLS setup fails and the
# engine logs "DNS-over-HTTPS unavailable".
$HostileCnf = @('openssl_conf = nivyx_test', '[nivyx_test]', 'alg_section = nivyx_alg',
    '[nivyx_alg]', 'default_properties = fips=yes')
function Log-Since([int]$n) {
    $all = @(Get-Content $LogFile -ErrorAction SilentlyContinue)
    if ($all.Count -le $n) { return @() }
    return $all[$n..($all.Count - 1)]
}
# Does the installed engine apply an OpenSSL configuration (1) named by
# OPENSSL_CONF in the service environment, (2) found at one of the places a
# MinGW OpenSSL may look by default (relative to the exe, or the drive root),
# (3) found as etc\ssl\openssl.cnf below its working directory when run by
# hand? Returns which ones applied; leaves the service running.
function Service-AppliesConfig([scriptblock]$plant, [scriptblock]$unplant) {
    $n = @(Get-Content $LogFile -ErrorAction SilentlyContinue).Count
    & $plant
    Restart-Service dpi-proxy
    $null = Wait-Ready
    foreach ($i in 1..40) { if ((Log-Since $n) -match 'transparent mode: TCP/443|DNS-over-HTTPS unavailable') { break }; Start-Sleep -Milliseconds 250 }
    $applied = [bool]((Log-Since $n) -match 'DNS-over-HTTPS unavailable')
    & $unplant
    return $applied
}
function Test-LoadsOpenSslConfig {
    $dir = Join-Path $env:TEMP ('nivyx-cnf-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'etc\ssl') | Out-Null
    $cnf = Join-Path $dir 'etc\ssl\openssl.cnf'
    Set-Content -Encoding ASCII $cnf $HostileCnf
    $res = [ordered]@{}
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\dpi-proxy'
    $res.env = Service-AppliesConfig {
        New-ItemProperty -Path $key -Name Environment -PropertyType MultiString -Value @("OPENSSL_CONF=$cnf") -Force | Out-Null
    } { Remove-ItemProperty -Path $key -Name Environment }
    # default locations, each tried alone (only if nothing is there already)
    $places = [ordered]@{
        exedir  = Join-Path $InstDir 'etc\ssl'
        exeup   = Join-Path (Split-Path $InstDir -Parent) 'etc\ssl'
        mingw64 = Join-Path ($env:SystemDrive + '\') 'mingw64\etc\ssl'
    }
    foreach ($k in $places.Keys) {
        $d = $places[$k]
        if (Test-Path (Join-Path $d 'openssl.cnf')) { $res[$k] = 'skipped (exists)'; continue }
        $made = -not (Test-Path $d)
        $res[$k] = Service-AppliesConfig {
            New-Item -ItemType Directory -Force -Path $d | Out-Null
            Copy-Item $cnf (Join-Path $d 'openssl.cnf')
        } { Remove-Item (Join-Path $d 'openssl.cnf') -Force; if ($made) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }
    }
    # by hand, below the working directory
    Stop-Service dpi-proxy
    $n = @(Get-Content $LogFile -ErrorAction SilentlyContinue).Count
    $p = Start-Process -FilePath (Join-Path $InstDir 'dpi-proxy.exe') -ArgumentList '--mode', 'transparent' `
        -WorkingDirectory $dir -PassThru -WindowStyle Hidden
    foreach ($i in 1..60) {
        Start-Sleep -Milliseconds 250
        if ((Log-Since $n) -match 'transparent mode: TCP/443|DNS-over-HTTPS unavailable|cannot ') { break }
    }
    $res.cwd = [bool]((Log-Since $n) -match 'DNS-over-HTTPS unavailable')
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue   # fail-open: interception ends with it
    Start-Sleep -Milliseconds 500
    Start-Service dpi-proxy
    $null = Wait-Ready
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ('OpenSSL config applied: ' + (($res.Keys | ForEach-Object { "$_=$($res[$_])" }) -join ', '))
    return $res
}
# any of the places applied it
function Any-Applied($r) { return [bool](@($r.Values | Where-Object { $_ -eq $true }).Count) }
function Any-File-Applied($r) { return [bool](@('exedir', 'exeup', 'mingw64', 'cwd' | Where-Object { $r[$_] -eq $true }).Count) }
function Fetch($url) { return "$(& curl.exe -sS -o NUL -w '%{http_code}' --max-time 20 $url 2>&1)" }
# Ready = the service runs and the engine it started reported "running"
# (the status file carries that process's pid). Bounded: 30 s.
function Wait-Ready {
    foreach ($i in 1..60) {
        $w = Get-CimInstance Win32_Service -Filter "Name='dpi-proxy'" -ErrorAction SilentlyContinue
        if ($w -and $w.State -eq 'Running' -and $w.ProcessId -and (Test-Path $StatusFile) -and
            (Select-String -Path $StatusFile -Pattern "^pid: $($w.ProcessId)$" -Quiet) -and
            (Select-String -Path $StatusFile -Pattern '^engine: running' -Quiet)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}
# the next heartbeat rewrite of the status file (every 10 s); bounded: 25 s
function Wait-Heartbeat {
    $u0 = Field updated
    foreach ($i in 1..50) { Start-Sleep -Milliseconds 500; if ((Field updated) -ne $u0) { return } }
}
# What a failed HTTPS check through the engine looked like: the engine's
# own reason, a direct probe that does not go through Nivyx (only TCP 443
# and DNS are intercepted), and the engine's local port range.
function Https-Evidence([string]$url) {
    Write-Host '--- HTTPS failure evidence ---'
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 15 | Where-Object { $_ -match '\[fail\]|\[verify\]|cannot' } | ForEach-Object { Write-Host "engine: $_" } }
    $h = ([uri]$url).Host
    Write-Host "direct http://$h/ (not intercepted): $(& curl.exe -sS -o NUL -w '%{http_code}' --max-time 10 "http://$h/" 2>&1)"
    $own = @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -ge 45000 -and $_.LocalPort -le 45999 })
    Write-Host "engine ports 45000-45999 in use: $($own.Count) ($(@($own | Where-Object State -eq 'TimeWait').Count) in TIME_WAIT)"
    Write-Host "service: $((Get-Service dpi-proxy -ErrorAction SilentlyContinue).Status)"
}
function Check-Https([string]$url, [string]$what) {
    $c = Fetch $url
    if ($c -notmatch '^[23]\d\d$') { Https-Evidence $url; Die "$what -> '$c'" }
    return $c
}
function Version-Of { return ((& (Join-Path $InstDir 'nivyx.cmd') version 2>&1 | Out-String).Trim() -replace '^Nivyx\s+', '') }

$newVersion = ((& (Join-Path $NewPackage 'dpi-proxy.exe') --version 2>&1 | Out-String).Trim() -replace '^dpi-proxy\s+', '')
$oldVersion = ((& (Join-Path $OldPackage 'dpi-proxy.exe') --version 2>&1 | Out-String).Trim() -replace '^dpi-proxy\s+', '')
if (-not ([version]$newVersion -gt [version]$oldVersion)) {
    Die "candidate $newVersion is not newer than ${oldVersion}: the old updater would (rightly) refuse it; bump VERSION"
}

Step "install the real $oldVersion package"
& powershell -ExecutionPolicy Bypass -File (Join-Path $OldPackage 'install.ps1')
if ($LASTEXITCODE -ne 0) { Die "$oldVersion install.ps1 exited $LASTEXITCODE" }
Add-Content $Conf "`n[domains]`nexample.com = tlsrec"
Restart-Service dpi-proxy
if (-not (Wait-Ready)) { Die "$oldVersion not ready after restart" }
$confHash = (Get-FileHash $Conf).Hash
Pass "$oldVersion installed, manual rule added"

Step "control: the $oldVersion engine applies OpenSSL configuration files (fixed in the candidate)"
$r = Test-LoadsOpenSslConfig
if (-not ($r.env -and (Any-File-Applied $r))) {
    Die "the $oldVersion engine applied neither OPENSSL_CONF nor a configuration file at any place tried: the check below would prove nothing"
}
Pass "$oldVersion applies OPENSSL_CONF and a configuration file (see the line above for where)"

Step "serve the candidate $newVersion as the latest release"
$mock = Join-Path $env:TEMP "nivyx-compat-$PID"
New-Item -ItemType Directory -Force -Path $mock | Out-Null
$zip = Join-Path $mock 'nivyx-windows-x86_64.zip'
if ($NewZip) { Copy-Item $NewZip $zip }
else {
    $pk = Join-Path $mock 'nivyx-windows-x86_64'
    Copy-Item $NewPackage $pk -Recurse
    Compress-Archive -Path $pk -DestinationPath $zip
    Remove-Item $pk -Recurse -Force
}
$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
Set-Content -Encoding ASCII (Join-Path $mock 'SHA256SUMS') "$hash  nivyx-windows-x86_64.zip"
$port = 18767
@{ tag_name = "v$newVersion"; prerelease = $false; assets = @(
    @{ name = 'nivyx-windows-x86_64.zip'; browser_download_url = "http://127.0.0.1:$port/nivyx-windows-x86_64.zip" },
    @{ name = 'SHA256SUMS'; browser_download_url = "http://127.0.0.1:$port/SHA256SUMS" }) } |
    ConvertTo-Json -Depth 5 | Set-Content -Encoding ASCII (Join-Path $mock 'latest.json')
$httpd = Start-Process -PassThru -WindowStyle Hidden python -ArgumentList '-m', 'http.server', "$port", '--bind', '127.0.0.1' -WorkingDirectory $mock
$up = $false
foreach ($i in 1..20) {
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$port/latest.json" -UseBasicParsing -TimeoutSec 3 | Out-Null; $up = $true; break } catch { Start-Sleep -Seconds 1 }
}
if (-not $up) { Die 'mock release server not reachable' }
$env:NIVYX_RELEASE_API = "http://127.0.0.1:$port/latest.json"
Pass "serving $zip"

Step "the $oldVersion updater installs the candidate"
# As on a user's machine: Windows PowerShell with its own module path, not
# the one inherited from this PowerShell 7 session (the old updaters use
# Expand-Archive, which then loads a module Windows PowerShell cannot run).
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
$out = (& (Join-Path $InstDir 'nivyx.cmd') update 2>&1 | Out-String); Write-Host $out
$rc = $LASTEXITCODE
Remove-Item Env:\NIVYX_RELEASE_API
Stop-Process -Id $httpd.Id -Force -ErrorAction SilentlyContinue
if ($rc -ne 0 -or $out -notmatch 'Health check passed') { Die "the $oldVersion updater did not accept the candidate package (exit $rc)" }
# nivyx.cmd is swapped in by a helper a few seconds after the updater exits
foreach ($i in 1..30) { $v = Version-Of; if ($v -eq $newVersion) { break }; Start-Sleep -Milliseconds 500 }
if ($v -ne $newVersion) { Die "version after the old updater: $v (expected $newVersion)" }
Pass "$oldVersion -> $newVersion through the old updater"

Step 'after the update: state, commands, networking'
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'service not running' }
if ((Get-FileHash $Conf).Hash -ne $confHash) { Die 'the manual config was modified' }
$nv = Join-Path $InstDir 'nivyx.cmd'
$out = (& $nv strategy example.com 2>&1 | Out-String)
if ($out -notmatch 'Manual rule') { Die "manual rule lost: $out" }
$c = Check-Https 'https://example.com/' 'HTTPS after the update'
& $nv doctor | Out-Host
if ($LASTEXITCODE -ne 0) { Die 'doctor reported a failure after the update' }
$out = (& $nv repair 2>&1 | Out-String)
if ($out -notmatch 'nothing else wrong') { Die "repair found something wrong after the update: $out" }
Pass 'config kept, manual rule applies, HTTPS, doctor and repair fine'

Step "the updated engine never applies an OpenSSL configuration file"
$r = Test-LoadsOpenSslConfig
if (Any-Applied $r) { Die 'after the update the engine still applies an OpenSSL configuration' }
Pass 'no OpenSSL configuration is read any more (OPENSSL_CONF, default locations, working directory)'

Step 'uninstall'
& powershell -ExecutionPolicy Bypass -File (Join-Path $NewPackage 'uninstall.ps1') -Purge
Start-Sleep -Seconds 3
if (Get-Service dpi-proxy -ErrorAction SilentlyContinue) { Die 'service still present' }
if (Test-Path $InstDir) { Die "$InstDir still present" }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "after uninstall -> '$c'" }
Remove-Item $mock -Recurse -Force -ErrorAction SilentlyContinue
Pass "uninstalled; HTTPS $c"

Write-Host "`nWINDOWS UPDATE COMPAT $oldVersion (its own updater) -> ${newVersion}: ALL CHECKS PASSED" -ForegroundColor Green
