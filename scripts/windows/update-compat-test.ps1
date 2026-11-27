#Requires -Version 5.1
<#
  v2.4.1 changed the package layout and names, so the `nivyx update` of an
  older release (v2.2.x ... v2.4.0) cannot install it: users move over once
  with Install Nivyx.cmd. This checks that such an old updater, offered the
  candidate, refuses it and changes nothing: same version, service running,
  HTTPS fine. CI: windows-latest, Administrator. Uninstalls at the end.

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
$InstDir    = Join-Path $env:ProgramFiles 'dpi-proxy'
$DataDir    = Join-Path $env:ProgramData 'dpi-proxy'
$StatusFile = Join-Path $DataDir 'transparent.status'
$LogFile    = Join-Path $DataDir 'dpi-proxy.log'

function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }
function Die($m) {
    Write-Host "FAIL: $m" -ForegroundColor Red
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 40 }
    exit 1
}
function Fetch($url) { return "$(& curl.exe -sS -o NUL -w '%{http_code}' --max-time 20 $url 2>&1)" }
function Version-Of { return ((& (Join-Path $InstDir 'nivyx.cmd') version 2>&1 | Out-String).Trim() -replace '^Nivyx\s+', '') }

& powershell -ExecutionPolicy Bypass -File (Join-Path $OldPackage 'install.ps1')
if ($LASTEXITCODE -ne 0) { Die "old install.ps1 exited $LASTEXITCODE" }
$old = Version-Of
Pass "old release installed ($old)"

$mock = Join-Path $env:TEMP "nivyx-compat-$PID"
New-Item -ItemType Directory -Force -Path $mock | Out-Null
$zip = Join-Path $mock 'nivyx-windows-x86_64.zip'
if ($NewZip) { Copy-Item $NewZip $zip }
else {
    $stage = Join-Path $mock 'stage\nivyx-windows-x86_64'
    Copy-Item $NewPackage $stage -Recurse
    Compress-Archive -Path $stage -DestinationPath $zip -Force
}
$port = 18766
$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
Set-Content -Encoding ASCII (Join-Path $mock 'SHA256SUMS') "$hash  nivyx-windows-x86_64.zip"
$ver = ((& (Join-Path $NewPackage 'files\nivyx-engine.exe') --version 2>&1 | Out-String).Trim() -replace '^nivyx-engine\s+', '')
@{ tag_name = "v$ver"; prerelease = $false; assets = @(
    @{ name = 'nivyx-windows-x86_64.zip'; browser_download_url = "http://127.0.0.1:$port/nivyx-windows-x86_64.zip" },
    @{ name = 'SHA256SUMS'; browser_download_url = "http://127.0.0.1:$port/SHA256SUMS" }) } |
    ConvertTo-Json -Depth 5 | Set-Content -Encoding ASCII (Join-Path $mock 'latest.json')
$httpd = Start-Process -PassThru -WindowStyle Hidden python -ArgumentList '-m', 'http.server', "$port", '--bind', '127.0.0.1' -WorkingDirectory $mock
foreach ($i in 1..20) {
    try { Invoke-WebRequest -Uri "http://127.0.0.1:$port/latest.json" -UseBasicParsing -TimeoutSec 3 | Out-Null; break } catch { Start-Sleep -Seconds 1 }
}
$env:NIVYX_RELEASE_API = "http://127.0.0.1:$port/latest.json"
$out = (& (Join-Path $InstDir 'nivyx.cmd') update 2>&1 | Out-String)
$rc = $LASTEXITCODE
Write-Host $out
Remove-Item Env:\NIVYX_RELEASE_API
Stop-Process -Id $httpd.Id -Force -ErrorAction SilentlyContinue
Remove-Item $mock -Recurse -Force -ErrorAction SilentlyContinue

if ($rc -eq 0) { Die "the old updater reported success installing $ver" }
if ($out -notmatch 'nothing was installed') { Die 'the old updater did not say that nothing was installed' }
if ((Version-Of) -ne $old) { Die 'the installed version changed' }
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'the old service is not running any more' }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "HTTPS after the refused update -> '$c'" }
Pass "the $old updater refused $ver and changed nothing (HTTPS $c)"

& powershell -ExecutionPolicy Bypass -File (Join-Path $OldPackage 'uninstall.ps1') -Purge | Out-Null
Write-Host "`nWINDOWS OLD UPDATER ($old) REFUSES THE CANDIDATE SAFELY: PASSED" -ForegroundColor Green
