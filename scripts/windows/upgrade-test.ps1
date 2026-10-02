#Requires -Version 5.1
<#
  Upgrade regression test on a real Windows machine (CI: windows-latest,
  Administrator): the real v2.1.0 package is installed, then the candidate
  package is installed over it, exactly as a user would. Uninstalls at the
  end.

    powershell -ExecutionPolicy Bypass -File upgrade-test.ps1 -OldPackage <dir> -NewPackage <dir>
#>
param(
    [Parameter(Mandatory = $true)][string]$OldPackage,
    [Parameter(Mandatory = $true)][string]$NewPackage
)

$ErrorActionPreference = 'Stop'
$DataDir    = Join-Path $env:ProgramData 'dpi-proxy'
$StatusFile = Join-Path $DataDir 'transparent.status'
$LogFile    = Join-Path $DataDir 'dpi-proxy.log'
$InstDir    = Join-Path $env:ProgramFiles 'dpi-proxy'
$Conf       = Join-Path $DataDir 'strategy.conf'
$Decisions  = Join-Path $DataDir 'tp-decisions.conf'
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
    $m = Select-String -Path $StatusFile -Pattern "^${name}: (.*)$" | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value } else { return '' }
}
function Fetch($url) { return "$(& curl.exe -sS -o NUL -w '%{http_code}' --max-time 20 $url 2>&1)" }
function Version-Of { return ((& (Join-Path $InstDir 'nivyx.cmd') version 2>&1 | Out-String).Trim() -replace '^Nivyx\s+', '') }

Step 'install the real v2.1.0 package'
& powershell -ExecutionPolicy Bypass -File (Join-Path $OldPackage 'install.ps1')
if ($LASTEXITCODE -ne 0) { Die "v2.1.0 install.ps1 exited $LASTEXITCODE" }
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'v2.1.0 service not running' }
foreach ($old in 'dpictl.cmd', 'dpi-proxy-ctl.cmd', 'dpictl-impl.ps1') {
    if (-not (Test-Path (Join-Path $InstDir $old))) { Die "the v2.1.0 layout lacks $old; wrong baseline?" }
}
$oldVersion = Version-Of
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "v2.1.0 HTTPS -> '$c'" }
Pass "v2.1.0 installed (version $oldVersion), legacy wrappers present, HTTPS $c"

Step 'user state that must survive'
Add-Content $Conf "`n[domains]`nexample.com = tlsrec"
Restart-Service dpi-proxy
Start-Sleep -Seconds 4
1..3 | ForEach-Object { Fetch 'https://example.com/' | Out-Null }
Start-Sleep -Seconds 11
$confHash = (Get-FileHash $Conf).Hash
$decisionsBefore = 0
if (Test-Path $Decisions) { $decisionsBefore = @(Get-Content $Decisions | Where-Object { -not $_.StartsWith('#') }).Count }
Pass "rule written ($decisionsBefore decisions on record)"

Step 'upgrade: install the candidate package over it'
& powershell -ExecutionPolicy Bypass -File (Join-Path $NewPackage 'install.ps1')
if ($LASTEXITCODE -ne 0) { Die "candidate install.ps1 exited $LASTEXITCODE over v2.1.0" }
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'service not running after the upgrade' }

Step 'after the upgrade'
$newVersion = Version-Of
if ($newVersion -eq $oldVersion) { Die "version did not change ($newVersion)" }
foreach ($old in 'dpictl.cmd', 'dpi-proxy-ctl.cmd', 'dpictl-impl.ps1') {
    if (Test-Path (Join-Path $InstDir $old)) { Die "legacy file $old was not removed" }
}
if (-not (Test-Path (Join-Path $InstDir 'nivyx-impl.ps1'))) { Die 'nivyx-impl.ps1 missing' }
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$out = (& powershell -NoProfile -ExecutionPolicy Restricted -Command 'nivyx status' 2>&1 | Out-String)
Write-Host $out
if ($out -notmatch 'Service: Running') { Die 'nivyx status (by name) did not report Running' }
if ((Get-FileHash $Conf).Hash -ne $confHash) { Die 'the manual config was modified by the upgrade' }
if ($decisionsBefore -gt 0 -and -not (Test-Path $Decisions)) { Die 'learned decisions were lost' }
$out = (& (Join-Path $InstDir 'nivyx.cmd') strategy example.com 2>&1 | Out-String)
if ($out -notmatch 'Manual rule') { Die "the manual rule no longer applies: $out" }
Pass "version $oldVersion -> $newVersion; legacy wrappers gone; config and state intact"

Step 'DNS, HTTPS, bypass, restart, doctor, repair after the upgrade'
Start-Sleep -Seconds 11
if ((Field dns_intercept) -ne 'doh') { Die "dns_intercept: $(Field dns_intercept)" }
Clear-DnsClientCache
Resolve-DnsName example.net -Type A -ErrorAction Stop | Out-Null
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "HTTPS through the manual tlsrec rule -> '$c'" }
$c = Fetch 'https://www.wikipedia.org/'
if ($c -notmatch '^[23]\d\d$') { Die "HTTPS -> '$c'" }
$nv = Join-Path $InstDir 'nivyx.cmd'
& $nv restart | Out-Null
Start-Sleep -Seconds 3
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'not running after nivyx restart' }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "HTTPS after restart -> '$c'" }
& $nv doctor | Out-Host
if ($LASTEXITCODE -ne 0) { Die 'doctor reported a failure' }
$out = (& $nv repair 2>&1 | Out-String)
if ($out -notmatch 'nothing else wrong') { Die "repair found something wrong right after an upgrade: $out" }
Pass 'DNS over DoH, HTTPS, bypass rule, restart, doctor and repair all fine'

Step 'uninstall removes everything of ours'
& powershell -ExecutionPolicy Bypass -File (Join-Path $NewPackage 'uninstall.ps1') -Purge
Start-Sleep -Seconds 3
if (Get-Service dpi-proxy -ErrorAction SilentlyContinue) { Die 'service still present' }
if (Get-NetFirewallRule -Name dpi-proxy -ErrorAction SilentlyContinue) { Die 'firewall rule still present' }
if (Test-Path $InstDir) { Die "$InstDir still present" }
if (Test-Path $DataDir) { Die "$DataDir still present after -Purge" }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "after uninstall -> '$c'" }
Pass "uninstalled; HTTPS $c"

Write-Host "`nWINDOWS UPGRADE v2.1.0 -> candidate: ALL CHECKS PASSED" -ForegroundColor Green
