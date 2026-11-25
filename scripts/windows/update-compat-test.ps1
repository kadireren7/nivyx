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
function Fetch($url) { return "$(& curl.exe -sS -o NUL -w '%{http_code}' --max-time 20 $url 2>&1)" }
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
Start-Sleep -Seconds 3
$confHash = (Get-FileHash $Conf).Hash
Pass "$oldVersion installed, manual rule added"

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
Start-Sleep -Seconds 5   # nivyx.cmd is swapped in after the updater exits
$v = Version-Of
if ($v -ne $newVersion) { Die "version after the old updater: $v (expected $newVersion)" }
Pass "$oldVersion -> $newVersion through the old updater"

Step 'after the update: state, commands, networking'
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'service not running' }
if ((Get-FileHash $Conf).Hash -ne $confHash) { Die 'the manual config was modified' }
$nv = Join-Path $InstDir 'nivyx.cmd'
$out = (& $nv strategy example.com 2>&1 | Out-String)
if ($out -notmatch 'Manual rule') { Die "manual rule lost: $out" }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "HTTPS -> '$c'" }
& $nv doctor | Out-Host
if ($LASTEXITCODE -ne 0) { Die 'doctor reported a failure after the update' }
$out = (& $nv repair 2>&1 | Out-String)
if ($out -notmatch 'nothing else wrong') { Die "repair found something wrong after the update: $out" }
Pass 'config kept, manual rule applies, HTTPS, doctor and repair fine'

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
