#Requires -Version 5.1
<#
  The updater's release-signature check on a real install (CI:
  windows-latest, Administrator, real WinDivert), with temporary test keys
  (scripts/signed-release-cases.sh): an unsigned, unverifiable, modified,
  wrongly signed, substituted or old release is refused and changes nothing
  (same engine, CLI, service process, configuration); a correctly signed one
  installs and keeps settings and learned state. Also checked: with no key
  configured (the state until the maintainer sets up signing) an update
  works as before. Uninstalls at the end.

    powershell -ExecutionPolicy Bypass -File update-signature-test.ps1 `
        -Package <candidate dir> -Cases <signed-release-cases.sh output>
#>
param(
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string]$Cases
)

$ErrorActionPreference = 'Stop'
$DataDir    = Join-Path $env:ProgramData 'dpi-proxy'
$StatusFile = Join-Path $DataDir 'transparent.status'
$LogFile    = Join-Path $DataDir 'dpi-proxy.log'
$InstDir    = Join-Path $env:ProgramFiles 'dpi-proxy'
$Conf       = Join-Path $DataDir 'strategy.conf'
$Decisions  = Join-Path $DataDir 'tp-decisions.conf'
$Planted    = 'nivyx-signature-test.invalid 0123456789abcdef 4 tlsrec original'
$Cases      = (Resolve-Path $Cases).Path
$script:step = 0

function Step($m) { $script:step++; Write-Host "`n=== [$script:step] $m" }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }
function Die($m) {
    Write-Host "FAIL: $m" -ForegroundColor Red
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 60 }
    exit 1
}
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
function Fetch($url) { return "$(& curl.exe -sS -o NUL -w '%{http_code}' --max-time 20 $url 2>&1)" }
function Version-Of { return ((& (Join-Path $InstDir 'nivyx.cmd') version 2>&1 | Out-String).Trim() -replace '^Nivyx\s+', '') }
function Hash($p) { return (Get-FileHash -Algorithm SHA256 $p).Hash }
function Snapshot {
    $svcPid = (Get-CimInstance Win32_Service -Filter "Name='dpi-proxy'").ProcessId
    return "$(Hash (Join-Path $InstDir 'dpi-proxy.exe')) $(Hash (Join-Path $InstDir 'nivyx-impl.ps1')) $svcPid $(Hash $Conf)"
}
function Install-Candidate {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $Package 'install.ps1') | Out-Host
    if ($LASTEXITCODE -ne 0) { Die "install.ps1 exited $LASTEXITCODE" }
    if (-not (Wait-Ready)) { Die 'not ready after install' }
}
function No-Leftovers([string]$what) {
    if (@(Get-ChildItem $env:TEMP -Directory -Filter 'nivyx-update-*' -ErrorAction SilentlyContinue).Count) { Die "${what}: a download folder was left behind" }
    if (@(Get-ChildItem $DataDir -Directory -Filter 'update-rollback-*' -ErrorAction SilentlyContinue).Count) { Die "${what}: a rollback folder was left behind" }
}
$port = 18770
function Serve([string]$case) {
    $d = Join-Path $Cases $case
    $assets = @(Get-ChildItem $d -File | Where-Object { $_.Name -notin 'tag', 'expect' } | ForEach-Object {
        @{ name = $_.Name; browser_download_url = "http://127.0.0.1:$port/$case/$($_.Name)" } })
    $tag = (Get-Content (Join-Path $d 'tag')).Trim()
    @{ tag_name = "v$tag"; prerelease = $false; assets = $assets } | ConvertTo-Json -Depth 5 |
        Set-Content -Encoding ASCII (Join-Path $Cases 'latest.json')
}
function Run-Update([string]$case, [string]$keys) {
    Serve $case
    $env:NIVYX_RELEASE_API = "http://127.0.0.1:$port/latest.json"
    if ($keys) { $env:NIVYX_TEST_RELEASE_KEYS = $keys } else { Remove-Item Env:\NIVYX_TEST_RELEASE_KEYS -ErrorAction SilentlyContinue }
    $script:out = (& (Join-Path $InstDir 'nivyx.cmd') update 2>&1 | Out-String)
    $script:rc = $LASTEXITCODE
    Remove-Item Env:\NIVYX_RELEASE_API, Env:\NIVYX_TEST_RELEASE_KEYS -ErrorAction SilentlyContinue
    $script:out -split "`r?`n" | ForEach-Object { Write-Host "    | $_" }
}
# nivyx.cmd is swapped in by a helper a few seconds after the updater exits
function Wait-Version([string]$want) {
    foreach ($i in 1..30) { if ((Version-Of) -eq $want) { return $true }; Start-Sleep -Milliseconds 500 }
    return $false
}

# As on a user's machine: Windows PowerShell with its own module path
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')

Step 'install the candidate, add a manual rule and a learned decision'
Install-Candidate
$base = Version-Of
Stop-Service dpi-proxy
Add-Content $Conf "`n[domains]`nexample.com = tlsrec"
Add-Content $Decisions "$Planted $([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
Start-Service dpi-proxy
if (-not (Wait-Ready)) { Die 'not ready after planting state' }
$confHash = Hash $Conf
Pass "candidate $base installed"

$httpd = Start-Process -PassThru -WindowStyle Hidden python -ArgumentList '-m', 'http.server', "$port", '--bind', '127.0.0.1' -WorkingDirectory $Cases
$up = $false
foreach ($i in 1..20) {
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$port/valid/tag" -UseBasicParsing -TimeoutSec 3 | Out-Null; $up = $true; break } catch { Start-Sleep -Seconds 1 }
}
if (-not $up) { Die 'mock release server not reachable' }

Step 'no release key configured (as shipped until signing is set up): unchanged behaviour'
Run-Update 'unsigned' ''
if ($rc -ne 0 -or $out -notmatch 'Health check passed') { Die "update failed without a configured key (exit $rc)" }
if ($out -notmatch 'release signatures are not checked yet') { Die 'no notice that signatures are not checked' }
if (-not (Wait-Version '99.0.0')) { Die "99.0.0 not installed: $(Version-Of)" }
Pass 'installed with the SHA256SUMS check alone, and says so'
Install-Candidate
if ((Version-Of) -ne $base) { Die "reinstall of $base gave $(Version-Of)" }
if ((Hash $Conf) -ne $confHash) { Die 'reinstall changed the config' }

Step 'signature enforced (test key): every bad release is refused and changes nothing'
$keys = Join-Path $Cases 'trusted-keys'
foreach ($c in 'unsigned', 'no-signature', 'modified-manifest', 'modified-package', 'wrong-key', 'substituted-manifest', 'old-release') {
    $expect = (Get-Content (Join-Path $Cases "$c\expect")).Trim()
    $before = Snapshot
    Write-Host "--- $c (expect: $expect)"
    Run-Update $c $keys
    if ($expect.StartsWith('refuse:')) {
        $text = $expect.Substring(7)
        if ($rc -eq 0) { Die "${c}: not refused" }
        if (-not $out.Contains($text)) { Die "${c}: refused, but not with '$text'" }
        if ($out -notmatch 'nothing was installed') { Die "${c}: no 'nothing was installed'" }
        if ($out -match 'Installing; restarting') { Die "${c}: the updater went on to install" }
    } elseif ($expect -eq 'up-to-date') {
        if ($rc -ne 0 -or $out -notmatch 'up to date') { Die "${c}: an old release was not ignored" }
    }
    if ((Snapshot) -ne $before) { Die "${c}: engine, CLI, service process or config changed" }
    No-Leftovers $c
    Pass "${c}: $expect; engine, CLI, service process and config unchanged"
}

Step 'a correctly signed release installs'
Run-Update 'valid' $keys
if ($rc -ne 0) { Die "the valid release was refused (exit $rc)" }
if ($out -notmatch 'Release signature verified') { Die 'no signature verification reported' }
if (-not (Wait-Version '99.0.0')) { Die "version after the update: $(Version-Of)" }
if (-not (Wait-Ready)) { Die 'not ready after the update' }
if ((Hash $Conf) -ne $confHash) { Die 'the config changed' }
$o = (& (Join-Path $InstDir 'nivyx.cmd') strategy example.com 2>&1 | Out-String)
if ($o -notmatch 'Manual rule') { Die "manual rule lost: $o" }
Stop-Service dpi-proxy   # writes the decisions out
if (-not (Select-String -Path $Decisions -Pattern ([regex]::Escape($Planted)) -Quiet)) { Die 'the learned decision did not survive the update' }
Start-Service dpi-proxy
if (-not (Wait-Ready)) { Die 'not ready after restart' }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "HTTPS after the update -> '$c'" }
No-Leftovers 'valid'
Pass "99.0.0 installed: signature verified; config, manual rule and learned decision kept; HTTPS $c"

Stop-Process -Id $httpd.Id -Force -ErrorAction SilentlyContinue
Step 'uninstall'
& powershell -ExecutionPolicy Bypass -File (Join-Path $Package 'uninstall.ps1') -Purge | Out-Host
if (Get-Service dpi-proxy -ErrorAction SilentlyContinue) { Die 'service still present after uninstall' }
Write-Host "`nWINDOWS UPDATE SIGNATURE TEST: ALL CHECKS PASSED" -ForegroundColor Green
