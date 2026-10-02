#Requires -Version 5.1
<#
  End-to-end test of Windows transparent mode on a real machine
  (CI: GitHub's windows-latest runner, Administrator). Installs from
  a packaged folder, then checks the whole lifecycle. Exits non-zero
  on the first failure. Never run it on a machine whose dpi-proxy
  installation you want to keep: it uninstalls at the end.

    powershell -ExecutionPolicy Bypass -File e2e-test.ps1 -Package <dir>
#>
param([Parameter(Mandatory = $true)][string]$Package)

$ErrorActionPreference = 'Stop'
$DataDir    = Join-Path $env:ProgramData 'dpi-proxy'
$StatusFile = Join-Path $DataDir 'transparent.status'
$LogFile    = Join-Path $DataDir 'dpi-proxy.log'
$InstDir    = Join-Path $env:ProgramFiles 'dpi-proxy'
$script:step = 0

function Step($m) { $script:step++; Write-Host "`n=== [$script:step] $m" }
function Pass($m) { Write-Host "PASS: $m" -ForegroundColor Green }
function Die($m) {
    Write-Host "FAIL: $m" -ForegroundColor Red
    if (Test-Path $LogFile) { Write-Host '--- service log ---'; Get-Content $LogFile -Tail 60 }
    if (Test-Path $StatusFile) { Write-Host '--- status ---'; Get-Content $StatusFile }
    exit 1
}
function Field($name) {
    $m = Select-String -Path $StatusFile -Pattern "^${name}: (.*)$" | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value } else { return '' }
}
# the status file is rewritten every 10 s (heartbeat)
function Wait-Status { Start-Sleep -Seconds 11 }
function Fetch($url) {
    $out = & curl.exe -sS -o NUL -w '%{http_code}' --max-time 20 $url 2>&1
    return "$out"
}

Step 'install'
& powershell -ExecutionPolicy Bypass -File (Join-Path $Package 'install.ps1')
if ($LASTEXITCODE -ne 0) { Die "install.ps1 exited $LASTEXITCODE" }
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'service not running' }
Pass 'installed; service running; installer health check (DNS + HTTPS through it) passed'

Step 'normal HTTPS works and is intercepted'
foreach ($u in 'https://example.com/', 'https://www.wikipedia.org/', 'https://github.com/') {
    $c = Fetch $u
    if ($c -notmatch '^[23]\d\d$') { Die "$u -> '$c'" }
}
Wait-Status
if ([int](Field flows) -lt 3) { Die "expected >= 3 intercepted flows, status says $(Field flows)" }
if ([int](Field failures) -ne 0) { Die "failures: $(Field failures)" }
Pass "3 sites OK; flows=$(Field flows) direct=$(Field direct) failures=0"

Step 'DNS goes through the forwarder (DoH)'
Clear-DnsClientCache
Resolve-DnsName "dpi-e2e-$(Get-Random).example.org" -ErrorAction SilentlyContinue | Out-Null
Resolve-DnsName example.net -Type A -ErrorAction Stop | Out-Null
Wait-Status
if ((Field dns_intercept) -ne 'doh') { Die "dns_intercept: $(Field dns_intercept)" }
if ([int](Field dns_queries) -lt 1) { Die 'no DNS query reached the forwarder' }
Pass "dns_intercept=doh dns_queries=$(Field dns_queries) dns_failures=$(Field dns_failures)"

Step 'no redirect loop: the service''s own connections are not intercepted'
$before = [int](Field flows)
1..5 | ForEach-Object { Fetch 'https://example.com/' | Out-Null }
Wait-Status
$delta = [int](Field flows) - $before
# background traffic on the machine may add a few; a loop adds hundreds
if ($delta -lt 5 -or $delta -gt 60) { Die "5 requests made $delta intercepted flows (loop?)" }
Pass "5 requests -> $delta flows"

Step 'bypass path: forced tlsrec rule for example.com'
Add-Content -Encoding ASCII (Join-Path $DataDir 'strategy.conf') "`n[domains]`nexample.com = tlsrec"
Restart-Service dpi-proxy
Start-Sleep -Seconds 3
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "example.com with tlsrec -> '$c'" }
Wait-Status
if ([int](Field bypassed) -lt 1) { Die "bypassed=$(Field bypassed); the TLSREC path was not used" }
Pass "example.com via tlsrec: HTTP $c; bypassed=$(Field bypassed)"

Step 'restart keeps working'
Restart-Service dpi-proxy
Start-Sleep -Seconds 3
$c = Fetch 'https://www.wikipedia.org/'
if ($c -notmatch '^[23]\d\d$') { Die "after restart -> '$c'" }
Pass "after restart: HTTP $c"

Step 'stop = ordinary networking'
Stop-Service dpi-proxy
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "with service stopped -> '$c'" }
Resolve-DnsName example.com -Type A -ErrorAction Stop | Out-Null
Pass "stopped: HTTPS $c, DNS OK"

Step 'crash = fail-open, then automatic restart'
Start-Service dpi-proxy
Start-Sleep -Seconds 3
Stop-Process -Name dpi-proxy -Force
Start-Sleep -Milliseconds 500
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "right after a crash -> '$c' (not fail-open)" }
$back = $false
foreach ($i in 1..30) { Start-Sleep -Seconds 1; if ((Get-Service dpi-proxy).Status -eq 'Running') { $back = $true; break } }
if (-not $back) { Die 'service was not restarted after the crash' }
Start-Sleep -Seconds 3
$c2 = Fetch 'https://example.com/'
if ($c2 -notmatch '^[23]\d\d$') { Die "after automatic restart -> '$c2'" }
Pass "killed: HTTPS still $c; restarted automatically; HTTPS $c2"

Step 'nivyx commands'
$nivyxCmd = Join-Path $InstDir 'nivyx.cmd'
# as a user would: a new PowerShell (fresh machine PATH), plain command
# name, under the default client execution policy (Restricted)
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$out = (& powershell -NoProfile -ExecutionPolicy Restricted -Command 'nivyx status --verbose' 2>&1 | Out-String)
Write-Host $out
if ($LASTEXITCODE -ne 0 -or $out -notmatch 'engine:\s+running' -or $out -notmatch 'bypassed:') {
    Die 'nivyx status --verbose (by name, Restricted policy) did not report a running engine'
}
$out = (& powershell -NoProfile -ExecutionPolicy Restricted -Command 'nivyx status' 2>&1 | Out-String)
Write-Host $out
if ($out -notmatch 'Service: Running' -or $out -notmatch 'Protection: Active') {
    Die 'nivyx status (default, short form) did not report Running/Active'
}
$out = (& powershell -NoProfile -ExecutionPolicy Restricted -Command "Set-Location '$Package'; .\nivyx status" 2>&1 | Out-String)
if ($out -notmatch 'Service: Running') { Die '.\nivyx status from the package folder failed' }
$out = (& $nivyxCmd diagnose example.com 2>&1 | Out-String)
Write-Host $out
if ($LASTEXITCODE -ne 0 -or $out -notmatch 'Result: Success \(HTTP \d+' -or $out -notmatch 'Poisoning suspected' -or $out -notmatch '(?m)^Decision') { Die 'nivyx diagnose failed' }
$out = (& $nivyxCmd diagnose example.com --verbose 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $out -notmatch '(?m)^Detail') { Die 'nivyx diagnose --verbose did not print the detail section' }
$out = (& $nivyxCmd logs 5 2>&1 | Out-String)
Write-Host $out
if ($LASTEXITCODE -ne 0 -or $out -notmatch 'transparent mode:') { Die 'nivyx logs failed' }
$out = (& $nivyxCmd version 2>&1 | Out-String)
Write-Host $out
if ($LASTEXITCODE -ne 0 -or -not $out.Trim()) { Die 'nivyx version printed nothing' }
Pass 'nivyx status/diagnose/logs/version report correctly'

Step 'nivyx doctor'
$out = (& $nivyxCmd doctor 2>&1 | Out-String)
Write-Host $out
if ($LASTEXITCODE -ne 0) { Die "nivyx doctor reported a failure while the service is healthy:`n$out" }
Pass 'doctor: no failures'

Step 'nivyx support-bundle (redaction)'
$bundle = Join-Path $env:TEMP "dpi-e2e-support-$PID.zip"
& $nivyxCmd support-bundle $bundle
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $bundle)) { Die 'support-bundle failed to produce an archive' }
$bdir = Join-Path $env:TEMP "dpi-e2e-support-$PID"
Expand-Archive -Path $bundle -DestinationPath $bdir -Force
if (-not (Test-Path (Join-Path $bdir 'version.txt'))) { Die 'support-bundle archive missing version.txt' }
$leaked = Get-ChildItem $bdir -Recurse -File | Select-String -SimpleMatch $env:USERPROFILE
if ($leaked) { Die "support-bundle leaked `$env:USERPROFILE into the archive" }
$dnsSummary = Join-Path $bdir 'dns-history-summary.txt'
if ((Test-Path $dnsSummary) -and -not (Select-String -Path $dnsSummary -SimpleMatch 'raw per-domain/per-IP records are not included')) {
    Die 'support-bundle included raw DNS decision history instead of a summary'
}
Remove-Item $bundle, $bdir -Recurse -Force -ErrorAction SilentlyContinue
Pass 'support-bundle archive redacted correctly'

Step 'nivyx output'
$nivyx = Join-Path $InstDir 'nivyx.cmd'
$out = (& powershell -NoProfile -ExecutionPolicy Restricted -Command 'nivyx status' 2>&1 | Out-String)
Write-Host $out
if ($LASTEXITCODE -ne 0 -or $out -notmatch '^Nivyx ' -or $out -notmatch 'Service: Running') {
    Die 'nivyx status (by name, Restricted policy) did not report Nivyx/Running'
}
$out = (& $nivyx --help 2>&1 | Out-String)
Write-Host $out
if ($LASTEXITCODE -ne 0 -or $out -notmatch 'nivyx') { Die 'nivyx --help failed' }
$env:NO_COLOR = '1'
$out = (& $nivyx status 2>&1 | Out-String)
Remove-Item Env:\NO_COLOR
if ($out -match "`e\[") { Die 'NO_COLOR=1 but nivyx emitted a color escape code' }
Pass 'nivyx status/--help ran; NO_COLOR honored'

Step 'one public command: no legacy wrappers installed'
foreach ($old in 'dpictl.cmd', 'dpi-proxy-ctl.cmd', 'dpictl-impl.ps1') {
    if (Test-Path (Join-Path $InstDir $old)) { Die "$old is still installed" }
}
if (-not (Test-Path (Join-Path $InstDir 'nivyx-impl.ps1'))) { Die 'nivyx-impl.ps1 missing' }
Pass 'only nivyx.cmd is installed'

Step 'stats, config, help (v2.2 commands)'
$nv = Join-Path $InstDir 'nivyx.cmd'
$out = (& $nv help 2>&1 | Out-String)
if ($out -notmatch 'update \[--check\]') { Die 'help does not list update' }
foreach ($cmdName in (Get-Content (Join-Path $PSScriptRoot '..\commands.txt'))) {
    if (-not $cmdName) { continue }
    $h = (& $nv help $cmdName 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not $h.Trim()) { Die "nivyx help $cmdName failed" }
}
$out = (& $nv help config 2>&1 | Out-String)
if ($out -notmatch 'config show') { Die 'help config failed' }
$out = (& $nv stats 2>&1 | Out-String); Write-Host $out
if ($out -notmatch 'Connections:') { Die 'stats printed no connection counters' }
if ($out -match 'example\.com') { Die 'stats leaked a host name' }
$out = (& $nv config path 2>&1 | Out-String)
if ($out -notmatch 'strategy\.conf') { Die 'config path' }
& $nv config check | Out-Host
if ($LASTEXITCODE -ne 0) { Die 'config check failed on the installed config' }
$conf = Join-Path $DataDir 'strategy.conf'
Copy-Item $conf (Join-Path $env:TEMP 'nivyx-conf.orig') -Force
$out = (& $nv config set e2e-config-test.example tlsrec 2>&1 | Out-String)
if ($out -notmatch 'Set e2e-config-test.example') { Die "config set: $out" }
if (-not (Select-String -Path $conf -Pattern '^e2e-config-test\.example = tlsrec' -Quiet)) { Die 'config set did not write the rule' }
if (-not (Test-Path "$conf.bak")) { Die 'config set kept no backup' }
& $nv config unset e2e-config-test.example | Out-Null
if (Select-String -Path $conf -Pattern 'e2e-config-test' -Quiet) { Die 'config unset left the rule' }
Add-Content $conf 'this is not valid'
& $nv config check | Out-Null
if ($LASTEXITCODE -eq 0) { Die 'config check missed a broken line' }
Copy-Item (Join-Path $env:TEMP 'nivyx-conf.orig') $conf -Force
Pass 'stats/config/help behave; manual config preserved'

Step 'repair: nothing wrong, then stopped service + stale status, then missing firewall rule'
$out = (& $nv repair 2>&1 | Out-String); Write-Host $out
if ($LASTEXITCODE -ne 0 -or $out -notmatch 'nothing else wrong') { Die 'repair on a healthy install reported something' }
Stop-Service dpi-proxy -Force
Set-Content $StatusFile 'engine: running'
Get-NetFirewallRule -Name dpi-proxy -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Set-Service dpi-proxy -StartupType Manual
$out = (& $nv repair 2>&1 | Out-String); Write-Host $out
if ($out -notmatch 'fixed') { Die 'repair fixed nothing' }
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'repair did not start the service' }
if (-not (Get-NetFirewallRule -Name dpi-proxy -ErrorAction SilentlyContinue)) { Die 'repair did not recreate the firewall rule' }
if ((Get-CimInstance Win32_Service -Filter "Name='dpi-proxy'").StartMode -ne 'Auto') { Die 'repair did not restore automatic start' }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "after repair -> '$c'" }
Pass "service, firewall rule and startup type restored; HTTPS $c"

Step 'update: check, bad checksum, broken release (rollback), good release'
$mock = Join-Path $env:TEMP "nivyx-mock-$PID"
New-Item -ItemType Directory -Force -Path $mock | Out-Null
$port = 18765
$current = ((& $nv version 2>&1 | Out-String).Trim() -replace '^Nivyx\s+', '')
# an engine that claims to be 9.9.9: the real one with the version string patched
$bytes = [IO.File]::ReadAllBytes((Join-Path $InstDir 'dpi-proxy.exe'))
$from = [Text.Encoding]::ASCII.GetBytes('2.2.0'); $to = [Text.Encoding]::ASCII.GetBytes('9.9.9')
$patched = 0
for ($i = 0; $i -le $bytes.Length - 5; $i++) {
    if ($bytes[$i] -eq $from[0] -and $bytes[$i+1] -eq $from[1] -and $bytes[$i+2] -eq $from[2] -and $bytes[$i+3] -eq $from[3] -and $bytes[$i+4] -eq $from[4]) {
        for ($k = 0; $k -lt 5; $k++) { $bytes[$i+$k] = $to[$k] }
        $patched++
    }
}
if ($patched -eq 0) { Die 'no version string found to patch in dpi-proxy.exe' }
$goodExe = Join-Path $mock 'engine-good.exe'
[IO.File]::WriteAllBytes($goodExe, $bytes)
if (((& $goodExe --version 2>&1 | Out-String)) -notmatch '9\.9\.9') { Die "could not build the 9.9.9 test engine: $(& $goodExe --version)" }

function New-MockRelease([string]$mode) {
    # $mode: good | badsum | brokendriver
    $pk = Join-Path $mock 'nivyx-windows-x86_64'
    Remove-Item $pk, (Join-Path $mock 'nivyx-windows-x86_64.zip'), (Join-Path $mock 'SHA256SUMS') -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item $Package $pk -Recurse
    Copy-Item $goodExe (Join-Path $pk 'dpi-proxy.exe') -Force
    if ($mode -eq 'brokendriver') { Set-Content -Encoding ASCII (Join-Path $pk 'WinDivert64.sys') 'not a driver' }
    $zip = Join-Path $mock 'nivyx-windows-x86_64.zip'
    Compress-Archive -Path $pk -DestinationPath $zip -Force
    $hash = if ($mode -eq 'badsum') { '0' * 64 } else { (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower() }
    Set-Content -Encoding ASCII (Join-Path $mock 'SHA256SUMS') "$hash  nivyx-windows-x86_64.zip"
    $json = @{ tag_name = 'v9.9.9'; prerelease = $false; assets = @(
        @{ name = 'nivyx-windows-x86_64.zip'; browser_download_url = "http://127.0.0.1:$port/nivyx-windows-x86_64.zip" },
        @{ name = 'SHA256SUMS'; browser_download_url = "http://127.0.0.1:$port/SHA256SUMS" }) } | ConvertTo-Json -Depth 5
    Set-Content -Encoding ASCII (Join-Path $mock 'latest.json') $json
}
$httpd = Start-Process -PassThru -WindowStyle Hidden python -ArgumentList '-m', 'http.server', "$port", '--bind', '127.0.0.1' -WorkingDirectory $mock
Start-Sleep -Seconds 2
$env:NIVYX_RELEASE_API = "http://127.0.0.1:$port/latest.json"

New-MockRelease 'good'
$out = (& $nv update --check 2>&1 | Out-String); Write-Host $out
if ($out -notmatch 'Update available') { Die 'update --check did not report the newer release' }
if (((& $nv version 2>&1 | Out-String).Trim() -replace '^Nivyx\s+', '') -ne $current) { Die 'update --check changed the installed version' }

New-MockRelease 'badsum'
$out = (& $nv update 2>&1 | Out-String); Write-Host $out
if ($LASTEXITCODE -eq 0) { Die 'update accepted a wrong checksum' }
if ($out -notmatch 'SHA-256 mismatch') { Die 'no checksum diagnostic' }
if (((& $nv version 2>&1 | Out-String).Trim() -replace '^Nivyx\s+', '') -ne $current) { Die 'bad checksum still changed the install' }
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'service down after a rejected update' }

New-MockRelease 'brokendriver'
$out = (& $nv update 2>&1 | Out-String); Write-Host $out
if ($LASTEXITCODE -eq 0) { Die 'update kept a release whose service cannot run' }
if ($out -notmatch 'rolled back') { Die "no rollback message: $out" }
if (((& $nv version 2>&1 | Out-String).Trim() -replace '^Nivyx\s+', '') -ne $current) { Die 'broken release was not rolled back' }
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'service down after rollback' }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "after rollback -> '$c'" }

$cfgBefore = (Get-FileHash $conf).Hash
New-MockRelease 'good'
$out = (& $nv update 2>&1 | Out-String); Write-Host $out
if ($LASTEXITCODE -ne 0) { Die 'a good update failed' }
Start-Sleep -Seconds 5   # nivyx.cmd is swapped in after the updater exits
$ver = ((& $nv version 2>&1 | Out-String).Trim() -replace '^Nivyx\s+', '')
if ($ver -ne '9.9.9') { Die "version after update: $ver" }
if ((Get-FileHash $conf).Hash -ne $cfgBefore) { Die 'update changed the config' }
if ((Get-Service dpi-proxy).Status -ne 'Running') { Die 'service down after update' }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "after update -> '$c'" }
Remove-Item Env:\NIVYX_RELEASE_API
Stop-Process -Id $httpd.Id -Force -ErrorAction SilentlyContinue
Remove-Item $mock -Recurse -Force -ErrorAction SilentlyContinue
Pass "check ok; bad checksum rejected; broken release rolled back; good release installed ($current -> 9.9.9), config kept"

Step 'size and resource use'
$exe = Join-Path $InstDir 'dpi-proxy.exe'
Get-Item $exe | Select-Object Name, Length | Format-Table | Out-String | Write-Host
$t0 = Get-Date
Restart-Service dpi-proxy
$ok = $false
foreach ($i in 1..40) {
    Start-Sleep -Milliseconds 250
    if ((Select-String -Path $StatusFile -Pattern '^engine: running' -Quiet -ErrorAction SilentlyContinue)) { $ok = $true; break }
}
$t1 = Get-Date
if (-not $ok) { Die 'did not report running after restart (resource-use step)' }
Write-Host ("startup time: {0:N2}s (restart issued -> engine: running)" -f ($t1 - $t0).TotalSeconds)
$proc = Get-Process -Name dpi-proxy
Write-Host ("daemon: {0} thread(s), working set {1:N1} MB, CPU time {2}" -f $proc.Threads.Count, ($proc.WorkingSet64 / 1MB), $proc.TotalProcessorTime)
foreach ($u in 'https://example.com/', 'https://www.wikipedia.org/', 'https://github.com/') {
    1..3 | ForEach-Object -Parallel { & curl.exe -sS -o NUL --max-time 20 $using:u } -ThrottleLimit 9
}
$proc.Refresh()
Write-Host ("daemon under load: working set {0:N1} MB, CPU time {1}" -f ($proc.WorkingSet64 / 1MB), $proc.TotalProcessorTime)
& curl.exe -sS -o NUL --max-time 60 -w 'throughput: %{size_download} bytes in %{time_total}s (%{speed_download} B/s)\n' 'https://speed.cloudflare.com/__down?bytes=50000000'
Pass 'measured'

Step 'uninstall cleans only our own state'
# as documented: the uninstall.ps1 from the extracted package folder
& powershell -ExecutionPolicy Bypass -File (Join-Path $Package 'uninstall.ps1') -Purge
Start-Sleep -Seconds 3
if (Get-Service dpi-proxy -ErrorAction SilentlyContinue) { Die 'service still present' }
if (Get-NetFirewallRule -Name dpi-proxy -ErrorAction SilentlyContinue) { Die 'firewall rule still present' }
if (Test-Path $InstDir) { Die "$InstDir still present" }
if (Test-Path $DataDir) { Die "$DataDir still present after -Purge" }
if (([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') -contains $InstDir) { Die 'PATH entry still present' }
$c = Fetch 'https://example.com/'
if ($c -notmatch '^[23]\d\d$') { Die "after uninstall -> '$c'" }
Pass "uninstalled; HTTPS $c"

Write-Host "`nALL WINDOWS E2E CHECKS PASSED" -ForegroundColor Green
