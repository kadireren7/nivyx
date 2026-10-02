#Requires -Version 5.1
<#
.SYNOPSIS
  nivyx for Windows: the same commands as on Linux and macOS.
    nivyx status [--verbose] | start | stop | restart | reload | logs [N]
    nivyx diagnose HOST [--verbose] | doctor | stats | support-bundle [FILE]
    nivyx config show|path|check|set|unset | repair | update [--check] | version
  start/stop/restart/reload/repair/update need an elevated terminal.

  This one script is the whole implementation; nivyx.cmd calls into it.
  Internal identifiers (the "dpi-proxy"
  Windows service name, install/data folders, dpi-proxy.exe) are kept
  unchanged from pre-rebrand installs — only user-facing output and
  command names change here.
#>
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Arg,
    [Parameter(Position = 2)][string]$Arg2,
    [Parameter(Position = 3)][string]$Arg3
)

$Service    = 'dpi-proxy'
$InstDir    = Join-Path $env:ProgramFiles 'dpi-proxy'
$DataDir    = Join-Path $env:ProgramData 'dpi-proxy'
$StatusFile = Join-Path $DataDir 'transparent.status'
$LogFile    = Join-Path $DataDir 'dpi-proxy.log'
$Exe        = Join-Path $InstDir 'dpi-proxy.exe'
$StrategyConf = Join-Path $DataDir 'strategy.conf'
$DecisionsFile = Join-Path $DataDir 'tp-decisions.conf'

# Color: skip -ForegroundColor when NO_COLOR is set (https://no-color.org).
# Write-Host colors are console-native (not ANSI), so piped/redirected
# output never carries color regardless; this only affects interactive use.
$UseColor = -not $env:NO_COLOR
function WriteColor([string]$Text, [string]$ColorName) {
    if ($UseColor -and $ColorName) { Write-Host $Text -ForegroundColor $ColorName }
    else { Write-Host $Text }
}

function Field($name) {
    if (-not (Test-Path $StatusFile)) { return '' }
    $m = Select-String -Path $StatusFile -Pattern "^${name}: (.*)$" | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value } else { return '' }
}

function Is-Elevated {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VersionString {
    if (Test-Path $Exe) {
        $out = & $Exe --version 2>$null
        if ($out -match 'dpi-proxy (.+)') { return $Matches[1] }
    }
    return $null
}

function Show-StatusShort {
    $ver = Get-VersionString
    if ($ver) { WriteColor "Nivyx $ver" Cyan } else { WriteColor 'Nivyx (version unknown - dpi-proxy.exe not found)' Cyan }
    $svc = Get-Service $Service -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host 'Service: Not installed'
        Write-Host 'Protection: Inactive'
        Write-Host 'DNS: N/A'
        Write-Host 'Mode: N/A'
        Write-Host 'Bypassed: 0'
        Write-Host 'Failures: 0'
        return
    }
    if ($svc.Status -eq 'Running') { WriteColor 'Service: Running' Green } else { WriteColor "Service: $($svc.Status)" Yellow }
    if ($svc.Status -ne 'Running' -or -not (Test-Path $StatusFile)) {
        Write-Host 'Protection: Inactive'
        Write-Host 'DNS: N/A'
        Write-Host 'Mode: N/A'
        Write-Host 'Bypassed: 0'
        Write-Host 'Failures: 0'
        return
    }
    $engine = Field engine
    if ($engine -eq 'running') { WriteColor 'Protection: Active' Green } else { WriteColor 'Protection: Starting' Yellow }
    $fails = Field dns_failures
    switch (Field dns_intercept) {
        'doh' {
            if (-not $fails -or $fails -eq '0') { WriteColor 'DNS: Healthy' Green }
            else { WriteColor "DNS: Degraded ($fails failure(s))" Yellow }
        }
        'off' { Write-Host 'DNS: Not intercepted' }
        default { WriteColor 'DNS: Unknown' Yellow }
    }
    $mode = Field mode
    if ($mode) { Write-Host ("Mode: " + $mode.Substring(0,1).ToUpper() + $mode.Substring(1)) } else { Write-Host 'Mode: Unknown' }
    Write-Host "Bypassed: $(Field bypassed)"
    Write-Host "Failures: $(Field failures)"
}

function Show-StatusVerbose {
    $svc = Get-Service $Service -ErrorAction SilentlyContinue
    $state = if ($svc) { $svc.Status.ToString().ToLower() } else { 'not installed' }
    Write-Host "service:   $Service ($state)"
    if (-not $svc -or $svc.Status -ne 'Running' -or -not (Test-Path $StatusFile)) {
        Write-Host 'engine:    not running - HTTPS and DNS go out directly, untouched'
        return
    }
    Write-Host "engine:    $(Field engine) ($(Field interception))"
    Write-Host "mode:      $(Field mode)"
    Write-Host "dns:       $(Field dns) resolvers; interception: $(Field dns_intercept) ($(Field dns_queries) queries, $(Field dns_failures) failed)"
    Write-Host "network:   $(Field network)"
    Write-Host "flows:     $(Field flows) total, $(Field active) active"
    Write-Host "direct:    $(Field direct)"
    Write-Host "bypassed:  $(Field bypassed)"
    Write-Host "passthru:  $(Field passthrough) (no hostname / manual pass / cooldown)"
    Write-Host "failures:  $(Field failures)"
    Write-Host "verified:  $(Field verified_ok) ok, $(Field verified_bad) rejected"
    Write-Host "learned:   $(Field decisions) decision(s); last: $(Field last_learned)"
    $c = Field conflict
    if ($c -and $c -ne 'none') { WriteColor "CONFLICT:  $c - stop the other tool" Yellow }
}

function Format-Duration([long]$t) {
    if ($t -lt 0) { $t = 0 }
    $d = [math]::Floor($t / 86400); $h = [math]::Floor(($t % 86400) / 3600); $m = [math]::Floor(($t % 3600) / 60)
    if ($d -gt 0) { return "${d}d ${h}h" }
    if ($h -gt 0) { return "${h}h ${m}m" }
    if ($m -gt 0) { return "${m}m" }
    return "${t}s"
}

# null/private/loopback answers: a resolver should never return those for
# a public site, so seeing one suggests DNS tampering.
function Test-BogusIp([string]$ip) {
    return ($ip -match '^(0\.|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)')
}

# Source / strategy / TTL of what applies to the domain. Manual rules
# always win; then a learned decision for this network; else automatic.
function Show-DecisionBlock([string]$domain) {
    $rule = $null
    if (Test-Path $StrategyConf) {
        $inD = $false
        foreach ($line in (Get-Content $StrategyConf)) {
            $l = $line.Trim()
            if ($l -match '^\[') { $inD = ($l -ieq '[domains]'); continue }
            if ($inD -and $l -match '^([^=\s#;]+)\s*=\s*(\S+)') {
                if ($Matches[1] -ieq $domain) { $rule = $Matches[2] }
            }
        }
    }
    if ($rule) {
        Write-Host "  Source: Manual rule ($StrategyConf)"
        Write-Host "  Strategy: $rule"
        Write-Host '  TTL: none (manual rules do not expire)'
        return
    }
    $fp = Field network
    if ($fp -and (Test-Path $DecisionsFile)) {
        $learned = $null
        foreach ($line in (Get-Content $DecisionsFile)) {
            if ($line.StartsWith('#')) { continue }
            $f = $line -split '\s+'
            if ($f.Count -ge 6 -and $f[0] -ieq $domain -and $f[1] -eq $fp) { $learned = $f }
        }
        if ($learned) {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $left = 86400 - ($now - [long]$learned[5])
            Write-Host '  Source: Learned (this network)'
            Write-Host "  Strategy: $($learned[3]) (IPv$($learned[2]))"
            Write-Host "  TTL: $(Format-Duration $left)"
            Write-Host '  Direct connection: failed earlier on this network, so the bypass is applied'
            return
        }
    }
    Write-Host '  Source: Automatic'
    Write-Host '  Strategy: direct (nothing learned; connected without bypass so far)'
}

# Layered, read-only look at what happens for the domain: DNS, HTTPS, the
# decision Nivyx holds. -Verbose-style detail via --verbose.
function Show-Diagnose($domain, [bool]$verbose) {
    if (-not $domain) { Write-Host 'usage: nivyx diagnose HOST [--verbose]'; exit 1 }
    $sys = @(Resolve-DnsName $domain -Type A -DnsOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress } | Sort-Object -Unique)
    $trusted = @()
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $j = Invoke-RestMethod -Uri "https://cloudflare-dns.com/dns-query?name=$domain&type=A" `
            -Headers @{ accept = 'application/dns-json' } -TimeoutSec 8 -UseBasicParsing
        $trusted = @($j.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data } | Sort-Object -Unique)
    } catch { }
    $resolver = 'system resolver'
    if ((Field dns_intercept) -eq 'doh') { $resolver = 'DoH (answered by Nivyx)' }
    $anyBogus = $false; $overlap = $false
    foreach ($ip in $sys) {
        if (Test-BogusIp $ip) { $anyBogus = $true }
        if ($trusted -contains $ip) { $overlap = $true }
    }
    $poison = 'No'
    if ($sys.Count -eq 0) { $poison = 'Unknown (no answer)' }
    elseif ($anyBogus) { $poison = 'Yes (private/null address returned)' }
    elseif ($trusted.Count -eq 0) { $poison = 'Not checked (no trusted answer)' }
    elseif (-not $overlap) { $poison = 'Possible (answers differ; normal for CDNs)' }

    WriteColor $domain Cyan
    Write-Host ''
    Write-Host 'DNS'
    Write-Host "  Resolver: $resolver"
    $addr = if ($sys.Count -gt 0) { $sys -join ' ' } else { 'none' }
    Write-Host "  Address: $addr"
    Write-Host "  Poisoning suspected: $poison"
    Write-Host ''
    Write-Host 'HTTPS'
    $code = $null; $failMsg = $null
    try {
        $r = Invoke-WebRequest -Uri "https://$domain/" -Method Head -UseBasicParsing -TimeoutSec 15
        $code = $r.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode.value__ }
        else { $failMsg = $_.Exception.Message }
    }
    if ($code) { WriteColor "  Result: Success (HTTP $code, certificate verified by Windows)" Green }
    else { WriteColor "  Result: Failed ($failMsg)" Red }
    Write-Host ''
    Write-Host 'Decision'
    Show-DecisionBlock $domain
    if ($verbose) {
        Write-Host ''
        Write-Host 'Detail'
        Write-Host "  Network fingerprint: $(Field network)"
        Write-Host "  System DNS answers:  $addr"
        Write-Host "  Trusted DNS answers: $(if ($trusted.Count -gt 0) { $trusted -join ' ' } else { 'none' })"
        if (Test-Path $LogFile) {
            Write-Host '  Recent log lines mentioning it:'
            Select-String -Path $LogFile -SimpleMatch " $domain" | Select-Object -Last 5 |
                ForEach-Object { Write-Host "    $($_.Line)" }
        }
    }
}

function Show-Stats {
    if (-not (Test-Path $StatusFile)) { Write-Host 'Nivyx is not running; no statistics.'; return }
    $started = Field started
    $up = 0
    if ($started -match '^\d+$') { $up = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$started }
    WriteColor "Nivyx $(Get-VersionString) statistics (local only)" Cyan
    Write-Host "Uptime:        $(Format-Duration $up)"
    Write-Host "Connections:   $(Field flows) intercepted, $(Field active) active now"
    Write-Host "  direct:      $(Field direct)"
    Write-Host "  bypassed:    $(Field bypassed)"
    Write-Host "  passthrough: $(Field passthrough)"
    Write-Host "  failures:    $(Field failures)"
    Write-Host "DNS:           $(Field dns_queries) queries, $(Field dns_failures) failed ($(Field dns_intercept))"
    Write-Host "Verification:  $(Field verified_ok) ok, $(Field verified_bad) rejected"
    Write-Host "Strategy cache: $(Field decisions) learned decision(s)"
    if (Test-Path $DecisionsFile) {
        $byStrategy = @{}; $byFamily = @{}
        foreach ($line in (Get-Content $DecisionsFile)) {
            if ($line.StartsWith('#')) { continue }
            $f = $line -split '\s+'
            if ($f.Count -lt 6) { continue }
            $byStrategy[$f[3]] = 1 + [int]$byStrategy[$f[3]]
            $byFamily[$f[2]] = 1 + [int]$byFamily[$f[2]]
        }
        foreach ($k in ($byStrategy.Keys | Sort-Object)) { Write-Host "  strategy ${k}: $($byStrategy[$k])" }
        foreach ($k in ($byFamily.Keys | Sort-Object)) { Write-Host "  IPv${k}: $($byFamily[$k])" }
    }
    Write-Host "Network:       $(Field network) (fingerprint)"
}

# ---- config ----------------------------------------------------------------

$ValidNames = 'pass','split','disorder','fake','fragment','tlsrec','tlsrec-split'
function Test-Chain([string]$v) {
    $parts = $v.ToLower().Split('+')
    if ($parts.Count -lt 1 -or $parts.Count -gt 2) { return $false }
    foreach ($p in $parts) { if ($ValidNames -notcontains $p) { return $false } }
    if ($parts.Count -eq 2 -and -not (($parts[0] -eq 'fake' -and $parts[1] -eq 'split') -or ($parts[0] -eq 'split' -and $parts[1] -eq 'fake'))) { return $false }
    return $true
}

# Returns the list of problems; mirrors the engine's own parser, which
# skips a bad line and keeps running.
function Get-ConfigProblems {
    $probs = @()
    $n = 0; $inD = $false
    foreach ($raw in (Get-Content $StrategyConf)) {
        $n++
        $l = $raw.Trim()
        if ($l -eq '' -or $l -match '^[#;]') { continue }
        if ($l -match '^\[') {
            $inD = ($l -ieq '[domains]')
            if (-not $inD) { $probs += "line ${n}: unknown section (only [domains] exists)" }
            continue
        }
        $i = $l.IndexOf('=')
        if ($i -lt 0) { $probs += "line ${n}: not a valid `"key = value`" line"; continue }
        $k = $l.Substring(0, $i).Trim(); $v = $l.Substring($i + 1).Trim()
        if ($k -eq '') { $probs += "line ${n}: empty key"; continue }
        if (-not $inD -and $k -ieq 'fake_ttl') {
            if ($v -notmatch '^\d+$' -or [int]$v -lt 1 -or [int]$v -gt 255) { $probs += "line ${n}: invalid fake_ttl (expected 1-255)" }
            continue
        }
        if (-not $inD -and $k -ieq 'default') {
            if (-not (Test-Chain $v) -or $v.Contains('+')) { $probs += "line ${n}: unknown strategy name `"$v`"" }
            continue
        }
        if ($inD) {
            if (-not (Test-Chain $v)) { $probs += "line ${n}: unknown strategy `"$v`" for $k" }
            continue
        }
        $probs += "line ${n}: key outside [domains] other than default/fake_ttl: $k"
    }
    return $probs
}

function Invoke-ConfigCheck {
    if (-not (Test-Path $StrategyConf)) { Write-Host "No config file at $StrategyConf (defaults apply)."; return $true }
    $probs = @(Get-ConfigProblems)
    if ($probs.Count -gt 0) {
        Write-Host "$StrategyConf has problems (the engine skips these lines and keeps running):"
        foreach ($p in $probs) { Write-Host "  $p" }
        return $false
    }
    Write-Host "${StrategyConf}: OK"
    return $true
}

function Set-ConfigRule([string]$domain, [string]$strat) {
    if (-not $domain -or -not $strat) { Write-Host 'usage: nivyx config set DOMAIN pass|tlsrec|tlsrec-split'; exit 1 }
    if ($domain -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') { Write-Host "nivyx: not a valid domain: $domain"; exit 1 }
    if ($strat -notin 'pass', 'tlsrec', 'tlsrec-split') { Write-Host 'nivyx: strategy must be pass, tlsrec or tlsrec-split'; exit 1 }
    if (-not (Is-Elevated)) { Write-Host "nivyx: changing $StrategyConf needs an elevated (Administrator) terminal"; exit 1 }
    if (-not (Test-Path $StrategyConf)) { Set-Content -Encoding ASCII $StrategyConf 'default = pass' }
    Copy-Item $StrategyConf "$StrategyConf.bak" -Force
    $lines = @(Get-Content $StrategyConf)
    $out = New-Object System.Collections.Generic.List[string]
    $exists = $false; $inD = $false
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -match '^\[') { $inD = ($t -ieq '[domains]') }
        if ($inD -and $t -match '^([^=\s#;]+)\s*=' -and $Matches[1] -ieq $domain) { $exists = $true }
    }
    $done = $false; $inD = $false
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -match '^\[') { $inD = ($t -ieq '[domains]') }
        if ($exists -and $inD -and -not $done -and $t -match '^([^=\s#;]+)\s*=' -and $Matches[1] -ieq $domain) {
            $out.Add("$domain = $strat"); $done = $true; continue
        }
        $out.Add($l)
        if (-not $exists -and -not $done -and $t -ieq '[domains]') { $out.Add("$domain = $strat"); $done = $true }
    }
    if (-not $done) { $out.Add(''); $out.Add('[domains]'); $out.Add("$domain = $strat") }
    Set-Content -Encoding ASCII $StrategyConf $out
    Write-Host "Set $domain = $strat in $StrategyConf (previous file kept as $StrategyConf.bak)."
    if (-not (Invoke-ConfigCheck)) { Write-Host 'Warning: the file has other problems (see above); your change was still applied.' }
    Write-Host 'Apply it with: nivyx reload   (or nivyx restart)'
}

function Remove-ConfigRule([string]$domain) {
    if (-not $domain) { Write-Host 'usage: nivyx config unset DOMAIN'; exit 1 }
    if (-not (Is-Elevated)) { Write-Host "nivyx: changing $StrategyConf needs an elevated (Administrator) terminal"; exit 1 }
    if (-not (Test-Path $StrategyConf)) { Write-Host 'No config file; nothing to remove.'; return }
    Copy-Item $StrategyConf "$StrategyConf.bak" -Force
    $out = New-Object System.Collections.Generic.List[string]
    $inD = $false
    foreach ($l in (Get-Content $StrategyConf)) {
        $t = $l.Trim()
        if ($t -match '^\[') { $inD = ($t -ieq '[domains]') }
        if ($inD -and $t -match '^([^=\s#;]+)\s*=' -and $Matches[1] -ieq $domain) { continue }
        $out.Add($l)
    }
    Set-Content -Encoding ASCII $StrategyConf $out
    Write-Host "Removed the rule for $domain (previous file kept as $StrategyConf.bak). Apply it with: nivyx restart"
}

function Invoke-Config([string]$sub, [string]$a, [string]$b) {
    if (-not $sub) { $sub = 'show' }
    switch ($sub) {
        'show' {
            if (Test-Path $StrategyConf) { Write-Host "# $StrategyConf"; Get-Content $StrategyConf }
            else { Write-Host "No config file at $StrategyConf (defaults apply)." }
        }
        'path'  { Write-Host $StrategyConf }
        'check' { if (-not (Invoke-ConfigCheck)) { exit 1 } }
        'set'   { Set-ConfigRule $a $b }
        'unset' { Remove-ConfigRule $a }
        default { Write-Host "nivyx: unknown config command: $sub (show | path | check | set | unset)"; exit 1 }
    }
}

# ---- repair -----------------------------------------------------------------
# Explicit and mutating, unlike doctor. Touches only Nivyx-owned state: our
# service, our firewall rule, our PATH entry, our files, and the WinDivert
# driver service only when no other WinDivert tool runs. Never edits your
# rules or other software.

$script:Repaired = 0
$script:Unrepairable = 0
function Fixed($m) { $script:Repaired++; WriteColor "[fixed] $m" Green }
function Okay($m) { Write-Host "[ ok  ] $m" }
function Cannot($m) { $script:Unrepairable++; WriteColor "[ !!  ] $m" Red }

function Wait-Healthy([int]$seconds) {
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
        # the status file must come from the CURRENT service process
        $svcPid = (Get-CimInstance Win32_Service -Filter "Name='$Service'" -ErrorAction SilentlyContinue).ProcessId
        if ((Get-Service $Service -ErrorAction SilentlyContinue).Status -eq 'Running' -and $svcPid -and
            (Test-Path $StatusFile) -and (Select-String -Path $StatusFile -Pattern '^engine: running' -Quiet) -and
            (Field pid) -eq "$svcPid") { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Invoke-Repair {
    if (-not (Is-Elevated)) { Write-Host 'nivyx: repair needs an elevated (Administrator) terminal'; exit 1 }
    Write-Host 'nivyx repair: checking Nivyx-owned state'
    Write-Host ''
    $svc = Get-Service $Service -ErrorAction SilentlyContinue
    if (-not $svc) {
        Cannot "service $Service is not installed; re-run Install Nivyx.cmd from the Nivyx folder"
        exit 1
    }
    Okay "service $Service is installed"
    if (Test-Path $Exe) { Okay "engine $Exe" } else { Cannot "engine $Exe is missing; re-run Install Nivyx.cmd" }
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null; Fixed "created missing data folder $DataDir" }

    if (Test-Path $StrategyConf) {
        if (@(Get-ConfigProblems).Count -eq 0) { Okay 'config syntax' }
        else { Cannot 'config has syntax problems; your rules are not rewritten. See: nivyx config check' }
    } else {
        Set-Content -Encoding ASCII $StrategyConf 'default = pass'
        Fixed "recreated missing $StrategyConf with defaults"
    }

    if ((Test-Path $DecisionsFile) -and (Get-Item $DecisionsFile).Length -gt 0) {
        $all = @(Get-Content $DecisionsFile)
        $good = @($all | Where-Object { $_.StartsWith('#') -or (($_ -split '\s+').Count -eq 6) })
        $bad = $all.Count - $good.Count
        if ($bad -gt 0) {
            Stop-Service $Service -Force -ErrorAction SilentlyContinue
            Copy-Item $DecisionsFile "$DecisionsFile.bak" -Force
            Set-Content -Encoding ASCII $DecisionsFile $good
            Fixed "removed $bad damaged line(s) from the learned-decision file (backup: $DecisionsFile.bak)"
        } else { Okay 'learned-decision file' }
    }

    $svc = Get-Service $Service
    if ($svc.Status -ne 'Running') {
        if ((Test-Path $StatusFile) -and (Field engine) -eq 'running') {
            Remove-Item $StatusFile -Force; Fixed "removed stale status file ($StatusFile)"
        }
        $wd = Get-Service WinDivert -ErrorAction SilentlyContinue
        $otherTool = Get-Process -Name goodbyedpi, winws -ErrorAction SilentlyContinue
        if ($wd -and $wd.Status -eq 'Running' -and -not $otherTool) {
            & sc.exe stop WinDivert | Out-Null
            Fixed 'unloaded the WinDivert driver left behind (no other WinDivert tool is running)'
        } else { Okay 'no stale WinDivert state' }
    }

    $wmi = Get-CimInstance Win32_Service -Filter "Name='$Service'" -ErrorAction SilentlyContinue
    if ($wmi -and $wmi.StartMode -ne 'Auto') {
        Set-Service $Service -StartupType Automatic; Fixed 'set the service to start automatically at boot'
    } else { Okay 'service starts automatically' }

    if (-not (Get-NetFirewallRule -Name $Service -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $Service -DisplayName 'dpi-proxy (redirected local traffic)' `
            -Direction Inbound -Program $Exe -Action Allow -Profile Any | Out-Null
        Fixed 'recreated the inbound firewall rule for dpi-proxy.exe (ours only)'
    } else { Okay 'firewall rule present' }

    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($path -split ';') -notcontains $InstDir) {
        [Environment]::SetEnvironmentVariable('Path', "$path;$InstDir", 'Machine')
        Fixed "added $InstDir to the machine PATH"
    } else { Okay 'PATH entry present' }

    if ((Get-Service $Service).Status -ne 'Running') {
        try { Start-Service $Service; Fixed "started $Service" } catch { Cannot "could not start ${Service}: $($_.Exception.Message)" }
    } else { Okay 'service is running' }
    if (Wait-Healthy 20) { Okay 'engine reports running' } else { Cannot "engine did not report running within 20s; see: nivyx logs" }
    Write-Host ''
    if ($script:Unrepairable -gt 0) {
        Write-Host "Repair finished with $($script:Unrepairable) problem(s) it cannot fix alone ($($script:Repaired) fixed)."
        exit 1
    }
    Write-Host "Repair finished: $($script:Repaired) fixed, nothing else wrong."
}

# ---- update -----------------------------------------------------------------
# Only on explicit request. Official GitHub releases; SHA-256 verified against
# SHA256SUMS before anything is installed; config and learned state untouched;
# a failed health check restores the previous version.
# NIVYX_RELEASE_API overrides the endpoint (test suite only; announced).

# .NET instead of Get-FileHash: that cmdlet failed to load when Windows
# PowerShell was started from pwsh (inherited PSModulePath) in CI.
function Get-Sha256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLower() }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Test-NewerVersion([string]$latest, [string]$current) {
    try { return ([version]$latest -gt [version]$current) } catch { return $false }
}

function Test-UpdateHealthy {
    if (-not (Wait-Healthy 30)) { return $false }
    try {
        $r = Invoke-WebRequest -Uri 'https://example.com/' -Method Head -UseBasicParsing -TimeoutSec 15
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
    } catch { return $false }
}

function Invoke-Update([bool]$checkOnly) {
    $ErrorActionPreference = 'Stop'
    $api = 'https://api.github.com/repos/kadireren7/nivyx/releases/latest'
    $official = 'https://github.com/kadireren7/nivyx/releases/download/'
    if ($env:NIVYX_RELEASE_API) { $api = $env:NIVYX_RELEASE_API; Write-Host "note: using update source $api" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $current = Get-VersionString
    try {
        $rel = Invoke-RestMethod -Uri $api -UseBasicParsing -TimeoutSec 20 `
            -Headers @{ 'User-Agent' = 'nivyx-update'; Accept = 'application/vnd.github+json' }
    } catch { Write-Host "nivyx: could not reach the release server ($api); check your connection"; exit 1 }
    $latest = ($rel.tag_name -replace '^v', '')
    if ($latest -notmatch '^\d+(\.\d+)*$') { Write-Host 'nivyx: no stable release found'; exit 1 }
    Write-Host "Current: $current"
    Write-Host "Latest:  $latest"
    if (-not (Test-NewerVersion $latest $current)) { Write-Host 'Nivyx is up to date.'; return }
    Write-Host 'Update available.'
    if ($checkOnly) { Write-Host 'Run (elevated): nivyx update'; return }
    if (-not (Is-Elevated)) { Write-Host 'nivyx: updating needs an elevated (Administrator) terminal'; exit 1 }

    $assetName = 'nivyx-windows-x86_64.zip'
    $asset = $rel.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    $sums = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
    if (-not $asset -or -not $sums) { Write-Host "nivyx: release $latest has no $assetName and/or SHA256SUMS"; exit 1 }
    if (-not $env:NIVYX_RELEASE_API) {
        foreach ($u in $asset.browser_download_url, $sums.browser_download_url) {
            if (-not $u.StartsWith($official)) { Write-Host 'nivyx: refusing a download URL outside the official repository'; exit 1 }
        }
    }

    $work = Join-Path $env:TEMP ("nivyx-update-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
        Write-Host "Downloading $assetName ..."
        $zip = Join-Path $work $assetName
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 300
        $sumFile = Join-Path $work 'SHA256SUMS'
        Invoke-WebRequest -Uri $sums.browser_download_url -OutFile $sumFile -UseBasicParsing -TimeoutSec 60
        $want = $null
        foreach ($l in (Get-Content $sumFile)) {
            if ($l -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $Matches[2].Trim() -eq $assetName) { $want = $Matches[1].ToLower() }
        }
        $got = (Get-Sha256 $zip)
        if (-not $want -or $want -ne $got) {
            Write-Host "nivyx: SHA-256 mismatch for $assetName (expected $(if ($want) { $want } else { '<none listed>' }), got $got); nothing was installed"
            exit 1
        }
        Write-Host 'SHA-256 verified.'

        Expand-Archive -Path $zip -DestinationPath $work -Force
        $pkg = Join-Path $work 'nivyx-windows-x86_64'
        $newExe = Join-Path $pkg 'dpi-proxy.exe'
        if (-not (Test-Path $newExe) -or -not (Test-Path (Join-Path $pkg 'nivyx-impl.ps1'))) {
            Write-Host 'nivyx: unexpected package layout; nothing was installed'; exit 1
        }
        if (-not ((& $newExe --capabilities 2>$null) -match '^transparent_mode: supported')) {
            Write-Host 'nivyx: the downloaded engine does not run here; nothing was installed'; exit 1
        }
        if (-not ((& $newExe --version 2>$null) -match "dpi-proxy $([regex]::Escape($latest))$")) {
            Write-Host "nivyx: the downloaded engine is not version $latest; nothing was installed"; exit 1
        }

        # back up what changes, then swap with the service stopped
        $bak = Join-Path $DataDir 'rollback'
        if (Test-Path $bak) { Remove-Item $bak -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $bak | Out-Null
        $files = 'dpi-proxy.exe', 'nivyx-impl.ps1', 'uninstall.ps1', 'nivyx-completion.ps1'
        foreach ($f in $files + 'WinDivert.dll', 'WinDivert64.sys') {
            $p = Join-Path $InstDir $f
            if (Test-Path $p) { Copy-Item $p $bak -Force }
        }
        Write-Host 'Installing; restarting the service ...'
        Stop-Service $Service -Force -ErrorAction SilentlyContinue
        $changedDriver = $false
        foreach ($f in 'WinDivert.dll', 'WinDivert64.sys') {
            $np = Join-Path $pkg $f; $op = Join-Path $InstDir $f
            if ((Test-Path $np) -and (-not (Test-Path $op) -or (Get-Sha256 $np) -ne (Get-Sha256 $op))) { $changedDriver = $true }
        }
        if ($changedDriver) { & sc.exe stop WinDivert | Out-Null; Start-Sleep -Seconds 1 }
        $copyOk = $true
        try {
            foreach ($f in $files + 'WinDivert.dll', 'WinDivert64.sys') {
                $np = Join-Path $pkg $f; $op = Join-Path $InstDir $f
                if (Test-Path $np) {
                    if (($f -in @('WinDivert.dll', 'WinDivert64.sys')) -and (Test-Path $op) -and (Get-Sha256 $np) -eq (Get-Sha256 $op)) { continue }
                    Copy-Item $np $op -Force -ErrorAction Stop
                }
            }
            # nivyx.cmd is read by cmd.exe while it runs: replace it only
            # after this process has exited
            $newCmd = Join-Path $pkg 'nivyx.cmd'; $curCmd = Join-Path $InstDir 'nivyx.cmd'
            if ((Test-Path $newCmd) -and (Get-Sha256 $newCmd) -ne (Get-Sha256 $curCmd)) {
                $staged = Join-Path $InstDir 'nivyx.cmd.new'
                Copy-Item $newCmd $staged -Force
                Start-Process -WindowStyle Hidden cmd.exe "/c timeout /t 3 >nul & move /y `"$staged`" `"$curCmd`" >nul"
            }
            Start-Service $Service
        } catch { $copyOk = $false; Write-Host "nivyx: install step failed: $($_.Exception.Message)" }

        if ($copyOk -and (Test-UpdateHealthy)) {
            Write-Host 'Health check passed.'
            Write-Host "Nivyx updated to $latest. Configuration and learned state were kept."
            Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue
            return
        }
        Write-Host "nivyx: the new version failed its health check; restoring $current"
        Stop-Service $Service -Force -ErrorAction SilentlyContinue
        & sc.exe stop WinDivert | Out-Null
        Start-Sleep -Seconds 1
        foreach ($f in Get-ChildItem $bak -File) { Copy-Item $f.FullName (Join-Path $InstDir $f.Name) -Force }
        Start-Service $Service -ErrorAction SilentlyContinue
        if (Test-UpdateHealthy) { Write-Host "nivyx: rolled back; Nivyx $current is running again" }
        else { Write-Host 'nivyx: rollback finished but the service is still unhealthy: run nivyx repair' }
        Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    } finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- doctor -------------------------------------------------------------

$script:DoctorFailed = $false
function Check($level, $msg) {
    if ($level -eq 'FAIL') { $script:DoctorFailed = $true }
    $color = switch ($level) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'White' } }
    WriteColor ("[{0,-4}] {1}" -f $level, $msg) $color
}

function Doctor-Permissions {
    if (Is-Elevated) { Check PASS 'permissions: running elevated - full diagnostics available' }
    else { Check WARN 'permissions: not elevated - some checks are limited; re-run as Administrator for full detail' }
    if (Test-Path $Exe) { Check PASS "permissions: $Exe is present" }
    else { Check FAIL "permissions: dpi-proxy.exe not found at $Exe" }
}

function Doctor-Service {
    $svc = Get-Service $Service -ErrorAction SilentlyContinue
    if (-not $svc) { Check WARN "service: $Service is not installed"; return }
    if ($svc.Status -eq 'Running') { Check PASS "service: $Service is running" }
    elseif ($svc.Status -eq 'Stopped') { Check WARN "service: $Service is stopped" }
    else { Check WARN "service: $Service is $($svc.Status)" }
}

function Doctor-Interception {
    $svc = Get-Service $Service -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        Check WARN 'interception: service not running - HTTPS/DNS are not intercepted'
        return
    }
    $wd = Get-Service WinDivert -ErrorAction SilentlyContinue
    if ($wd -and $wd.Status -eq 'Running') { Check PASS 'interception: WinDivert driver loaded' }
    elseif ($wd) { Check FAIL "interception: WinDivert service present but $($wd.Status)" }
    else { Check WARN 'interception: WinDivert driver service not found (may not have loaded yet)' }
}

function Doctor-Dns {
    if (-not (Test-Path $StatusFile)) { Check WARN 'dns: no status file yet'; return }
    $fails = Field dns_failures
    switch (Field dns_intercept) {
        'doh' {
            if (-not $fails -or $fails -eq '0') { Check PASS 'dns: DNS-over-HTTPS active, 0 failures' }
            else { Check WARN "dns: DNS-over-HTTPS active but $fails failure(s)" }
        }
        'off' { Check WARN 'dns: interception is off' }
        default { Check WARN "dns: unexpected state `"$(Field dns_intercept)`"" }
    }
}

function Doctor-Reachability {
    try {
        $r = Invoke-WebRequest -Uri 'https://example.com/' -Method Head -UseBasicParsing -TimeoutSec 8
        Check PASS "reachability: https://example.com/ -> HTTP $($r.StatusCode)"
    } catch {
        Check FAIL "reachability: https://example.com/ failed: $($_.Exception.Message)"
    }
}

function Doctor-Bypass {
    if (-not (Test-Path $Exe)) { Check WARN 'bypass path: dpi-proxy.exe not found'; return }
    $caps = & $Exe --capabilities 2>$null
    if ($caps -match '^transparent_mode: supported') { Check PASS 'bypass path: this binary supports transparent mode' }
    else { Check FAIL 'bypass path: this binary was built without transparent mode support' }
}

function Doctor-Conflicts {
    $other = Get-Process -Name goodbyedpi, winws -ErrorAction SilentlyContinue
    $c = Field conflict
    $found = @()
    if ($other) { $found += ($other | Select-Object -Expand Name -Unique) }
    if ($c -and $c -ne 'none') { $found += $c }
    if ($found.Count -gt 0) {
        Check WARN ("conflicts: other DPI/interception tool(s) detected: " + ($found -join ', ') + " - dpi-proxy does not disable them; stop one manually")
    } else {
        Check PASS 'conflicts: no other known DPI-bypass tool detected'
    }
}

function Doctor-Vpn {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'TAP|TUN|WireGuard|VPN|OpenVPN' }
    if ($adapters) {
        $names = ($adapters | Select-Object -Expand Name) -join ', '
        Check WARN "vpn: active VPN/tunnel adapter(s) ($names) - if one filters HTTPS, it may interact with dpi-proxy"
    } else {
        Check PASS 'vpn: no active VPN/tunnel adapter detected'
    }
}

function Doctor-Stale {
    $svc = Get-Service $Service -ErrorAction SilentlyContinue
    $wd = Get-Service WinDivert -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { Check PASS 'stale rules: service is running, nothing to check'; return }
    if ($wd -and $wd.Status -eq 'Running' -and (-not (Get-Process -Name goodbyedpi, winws -ErrorAction SilentlyContinue))) {
        Check WARN 'stale rules: WinDivert driver still loaded although dpi-proxy is stopped and no other known WinDivert tool is running'
    } else {
        Check PASS 'stale rules: none found'
    }
}

function Invoke-Doctor {
    Write-Host "nivyx doctor - $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    Write-Host ''
    Doctor-Permissions
    Doctor-Service
    Doctor-Interception
    Doctor-Dns
    Doctor-Reachability
    Doctor-Bypass
    Doctor-Conflicts
    Doctor-Vpn
    Doctor-Stale
    Write-Host ''
    if ($script:DoctorFailed) {
        Write-Host 'Result: one or more checks FAILED - see above.'
        exit 1
    }
    Write-Host 'Result: no failures.'
    exit 0
}

# ---- support-bundle -------------------------------------------------------

function Protect-Text([string]$text) {
    if (-not $text) { return $text }
    $out = $text -replace '(?i)(token|key|secret|password)[=: ]+[A-Za-z0-9_.\-]{4,}', '$1=[REDACTED]'
    $out = $out -replace '(\[(?:learn|verify)\] )[^ :]+:', '$1<host>:'
    $userHome = $env:USERPROFILE
    if ($userHome) { $out = $out -replace [regex]::Escape($userHome), '~' }
    $userName = $env:USERNAME
    if ($userName) { $out = $out -replace "\b$([regex]::Escape($userName))\b", '[user]' }
    return $out
}

function Invoke-SupportBundle([string]$OutFile) {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $tmp = Join-Path $env:TEMP "nivyx-support-$ts"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    if (-not $OutFile) { $OutFile = Join-Path (Get-Location) "nivyx-support-$ts.zip" }

    $ver = Get-VersionString
    @(
        'nivyx support-bundle'
        "generated: $ts (UTC)"
        "version:   $ver"
        "binary:    $Exe"
    ) | Set-Content (Join-Path $tmp 'version.txt')

    @(
        "OS: $((Get-CimInstance Win32_OperatingSystem).Caption)"
        "Version: $([System.Environment]::OSVersion.VersionString)"
        "Arch: $env:PROCESSOR_ARCHITECTURE"
    ) | Set-Content (Join-Path $tmp 'os.txt')

    # Show-Status{Short,Verbose} print with Write-Host, which does not
    # flow through the success stream that Out-String reads by
    # default; *>&1 merges every stream (including Write-Host's
    # Information stream) into it first.
    # the "last learned" line names a host: counts only in a bundle
    (((Show-StatusShort *>&1 | Out-String) + "`n" + (Show-StatusVerbose *>&1 | Out-String)) -replace '; last: [^\r\n]*', '') |
        Set-Content (Join-Path $tmp 'status.txt')

    $prevFailed = $script:DoctorFailed
    $script:DoctorFailed = $false
    try {
        $doctorOut = & {
            Doctor-Permissions
            Doctor-Service
            Doctor-Interception
            Doctor-Dns
            Doctor-Reachability
            Doctor-Bypass
            Doctor-Conflicts
            Doctor-Vpn
            Doctor-Stale
        } *>&1 | Out-String
    } finally {
        $script:DoctorFailed = $prevFailed
    }
    $doctorOut | Set-Content (Join-Path $tmp 'doctor.txt')

    $svc = Get-Service $Service -ErrorAction SilentlyContinue
    if ($svc) { (Protect-Text ($svc | Format-List | Out-String)) | Set-Content (Join-Path $tmp 'service-state.txt') }

    if (Test-Path $LogFile) {
        (Get-Content $LogFile -Tail 500 | ForEach-Object { Protect-Text $_ }) |
            Set-Content (Join-Path $tmp 'log.txt')
    }

    $conf = Join-Path $DataDir 'strategy.conf'
    if (Test-Path $conf) {
        (Get-Content $conf | ForEach-Object { Protect-Text $_ }) | Set-Content (Join-Path $tmp 'strategy.conf')
    }

    $decisions = Join-Path $DataDir 'tp-decisions.conf'
    if (Test-Path $decisions) {
        $n = (Get-Content $decisions | Measure-Object -Line).Lines
        @(
            "learned decisions on record: $n"
            '(raw per-domain/per-IP records are not included in support bundles)'
        ) | Set-Content (Join-Path $tmp 'dns-history-summary.txt')
    }

    if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
    Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $OutFile
    Remove-Item $tmp -Recurse -Force

    Write-Host "Wrote $OutFile"
    Write-Host 'Redacted: tokens/keys/passwords, %USERPROFILE%, username, host names in log lines, and per-domain DNS history (counts only).'
    Write-Host 'Review it before sharing - it may still contain domain names you visited and log timestamps.'
}

# nivyx.cmd rewrites --help/-h to the literal word "help"
# before invoking this script (PowerShell's -File argument binder
# treats a bare "--help"/"-h" token as an attempt to bind a *named*
# parameter and aborts with NamedParameterNotFound before any script
# code runs — a plain word binds fine positionally). $Command is still
# checked directly for anyone invoking this script itself.
function Show-Usage {
    Write-Host 'Nivyx -- system-wide DPI bypass'
    Write-Host ''
    Write-Host 'Usage: nivyx <command> [options]'
    Write-Host ''
    Write-Host 'Everyday'
    Write-Host '  status [--verbose]       is it working? (--verbose: full detail)'
    Write-Host '  doctor                   health checks (read-only)'
    Write-Host '  diagnose DOMAIN          explain what happens for one site (--verbose: detail)'
    Write-Host '  stats                    local counters (no browsing history)'
    Write-Host '  logs [N]                 recent log lines'
    Write-Host ''
    Write-Host 'Control (need an elevated terminal)'
    Write-Host '  start | stop | restart | reload'
    Write-Host '  repair                   fix Nivyx-owned state (service, stale state, files)'
    Write-Host '  update [--check]         update to the latest official release'
    Write-Host ''
    Write-Host 'Configuration'
    Write-Host '  config show|path|check|set DOMAIN STRATEGY|unset DOMAIN'
    Write-Host '  strategy DOMAIN          which rule applies to DOMAIN right now'
    Write-Host ''
    Write-Host 'Other'
    Write-Host '  support-bundle [FILE]    redacted local diagnostics archive (no telemetry)'
    Write-Host '  version                  print the version'
    Write-Host '  help [COMMAND]           this text, or help for one command'
}

function Show-CommandHelp([string]$c) {
    switch ($c) {
        'status'   { Write-Host 'nivyx status [--verbose]'; Write-Host 'Shows version, service state, protection, DNS health and mode. --verbose adds flows, counters and the network fingerprint.' }
        'doctor'   { Write-Host 'nivyx doctor'; Write-Host 'Read-only health checks: service, interception, DNS, reachability, conflicts, VPN, stale state. Changes nothing; exits 1 if a check failed. Use repair to fix.' }
        'diagnose' { Write-Host 'nivyx diagnose DOMAIN [--verbose]'; Write-Host 'Explains DNS (resolver, address, poisoning suspected), HTTPS (result through Nivyx) and the decision Nivyx holds (source, strategy, TTL). Read-only.' }
        'stats'    { Write-Host 'nivyx stats'; Write-Host 'Uptime, connection counters, DNS counters and strategy-cache sizes from the local status file. No hostnames; nothing leaves this machine.' }
        'logs'     { Write-Host 'nivyx logs [N]   last N log lines (default 100)' }
        'repair'   { Write-Host 'nivyx repair   (elevated)'; Write-Host 'Fixes Nivyx-owned state only: stopped service, stale status file, stale WinDivert driver state, startup type, firewall rule, PATH entry, damaged learned-decision file. Never edits your rules or touches other software. Every repair is printed.' }
        'update'   { Write-Host 'nivyx update [--check]   (elevated to apply)'; Write-Host '--check only compares versions. Otherwise downloads the official release, verifies its SHA-256 against SHA256SUMS, installs, restarts, health-checks, and restores the previous version if the check fails. Config and learned state are kept. Never runs on its own.' }
        'config'   { Write-Host 'nivyx config show | path | check | set DOMAIN STRATEGY | unset DOMAIN'; Write-Host 'STRATEGY is pass, tlsrec or tlsrec-split. Manual rules always override automatic learning. set and unset change one line, keep a .bak copy, and never run unless you ask.' }
        'strategy' { Write-Host 'nivyx strategy DOMAIN   which rule applies right now (manual / learned / automatic)' }
        'support-bundle' { Write-Host 'nivyx support-bundle [FILE]   zip of version, status, logs and config; tokens, profile path and username redacted, host history reduced to counts. Written locally only.' }
        'version'  { Write-Host 'nivyx version' }
        'help'     { Write-Host 'nivyx help [COMMAND]   this overview, or details for one command' }
        { $_ -in 'start', 'stop', 'restart', 'reload' } { Write-Host "nivyx $c   (elevated) control the service; stop leaves networking untouched" }
        default    { Write-Host "nivyx: no help for: $c"; exit 1 }
    }
}

# nivyx.cmd rewrites --help/-h to the literal word "help"
# before invoking this script (PowerShell's -File argument binder
# treats a bare "--help"/"-h" token as an attempt to bind a *named*
# parameter and aborts with NamedParameterNotFound before any script
# code runs — a plain word binds fine positionally). $Command is still
# checked directly for anyone invoking this script itself.
if ($Command -in '--help', '-h') { Show-Usage; exit 0 }
if ($Command -eq 'help') { if ($Arg) { Show-CommandHelp $Arg } else { Show-Usage }; exit 0 }

# nivyx.cmd strips dash-prefixed options from the argument list (see the
# comment there) and passes them through the environment.
$WantVerbose = ($env:NIVYX_VERBOSE -eq '1' -or $Arg -eq '--verbose' -or $Arg -eq '-v' -or $Arg2 -eq '--verbose')
$CheckOnly = ($env:NIVYX_CHECK -eq '1' -or $Arg -eq '--check')

switch ($Command) {
    'status' {
        # nivyx.cmd sets NIVYX_VERBOSE=1 when it sees --verbose/-v
        # among the raw arguments (see that file for why: PowerShell's
        # own parameter binder cannot be trusted to hand a bare
        # dash-prefixed token to $Arg intact through -File). $Arg is
        # also checked directly for anyone invoking this script itself.
        if ($WantVerbose) { Show-StatusVerbose } else { Show-StatusShort }
    }
    'start'    { Start-Service $Service; Show-StatusVerbose }
    'stop'     { Stop-Service $Service; Write-Host 'stopped; networking is back to normal (unbypassed)' }
    'restart'  { Restart-Service $Service; Start-Sleep -Seconds 2; Show-StatusVerbose }
    'logs'     {
        $n = if ($Arg) { [int]$Arg } else { 100 }
        if (Test-Path $LogFile) { Get-Content $LogFile -Tail $n } else { Write-Host "no log yet ($LogFile)" }
    }
    'diagnose'       { Show-Diagnose $Arg $WantVerbose }
    'stats'          { Show-Stats }
    'config'         { Invoke-Config $Arg $Arg2 $Arg3 }
    'repair'         { Invoke-Repair }
    'update'         {
        try { Invoke-Update $CheckOnly }
        catch { Write-Host "nivyx: update failed: $($_.Exception.Message)"; exit 1 }
    }
    'reload'         {
        if (-not (Is-Elevated)) { Write-Host 'nivyx: reload needs an elevated (Administrator) terminal'; exit 1 }
        # the engine reads manual rules at startup; restarting is the reload
        Restart-Service $Service; Start-Sleep -Seconds 2; Show-StatusVerbose
    }
    'strategy'       {
        if (-not $Arg) { Write-Host 'nivyx: strategy needs a domain'; exit 1 }
        Show-DecisionBlock $Arg
    }
    'doctor'         { Invoke-Doctor }
    'support-bundle' { Invoke-SupportBundle $Arg }
    'version'        {
        $ver = Get-VersionString
        if ($ver) { Write-Host "Nivyx $ver" } else { Write-Host 'Nivyx (version unknown - dpi-proxy.exe not found)' }
    }
    default    {
        Write-Host "Nivyx: unknown command '$Command' (see: nivyx --help)"
        exit 1
    }
}
