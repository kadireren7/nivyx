#!/bin/sh
#
# End-to-end test of macOS transparent mode on a real Mac (CI: GitHub's
# macOS runners; needs passwordless sudo). Installs from a package
# folder exactly as a user would, then checks the whole lifecycle:
# PF interception, DNS, the bypass path, loops, restart, stop, crash
# and hang fail-open, launchd restart, uninstall leaving nothing
# behind, clean reinstall. Exits non-zero on the first failure.
#
#   ./e2e-test.sh <package-dir>
#
# It uninstalls at the end: don't run it on a Mac whose dpi-proxy
# installation you want to keep.
set -u

PKG="$(cd "${1:?usage: e2e-test.sh <package-dir>}" && pwd)"
LABEL="io.github.kadireren7.dpi-proxy"
ANCHOR="com.apple/dpi-proxy"
STATUS=/var/run/dpi-proxy/transparent.status
CONF=/usr/local/etc/dpi-proxy/strategy.conf
LOG=/var/log/dpi-proxy.log
step=0

stepn() { step=$((step + 1)); printf '\n=== [%d] %s\n' "$step" "$1"; }
pass() { printf 'PASS: %s\n' "$1"; }
note() { printf 'NOTE: %s\n' "$1"; }
die() {
	printf 'FAIL: %s\n' "$1"
	echo '--- log ---'; sudo tail -n 80 "$LOG" 2>/dev/null
	echo '--- stderr log ---'; sudo tail -n 20 /var/log/dpi-proxy.stderr.log 2>/dev/null
	echo '--- status ---'; cat "$STATUS" 2>/dev/null
	echo '--- anchor ---'; sudo pfctl -a "$ANCHOR" -s nat 2>/dev/null; sudo pfctl -a "$ANCHOR" -s rules 2>/dev/null
	echo '--- pf info ---'; sudo pfctl -s info 2>/dev/null | head -n 3
	exit 1
}
field() { sed -n "s/^$1: //p" "$STATUS" 2>/dev/null | head -n 1; }
# the status file is rewritten on every heartbeat (10 s)
wait_status() { sleep 11; }
fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>&1 || true; }
ok() { echo "$1" | grep -Eq '^[23][0-9][0-9]$'; }
daemon_pid() {
	launchctl print "system/$LABEL" 2>/dev/null \
		| sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1
}
anchor_rules() {
	{ sudo pfctl -a "$ANCHOR" -s nat 2>/dev/null; sudo pfctl -a "$ANCHOR" -s rules 2>/dev/null; } \
		| grep -c -e '^rdr' -e 'route-to' -e '^block'
}
wait_running() {
	i=0
	while [ $i -lt 60 ]; do
		p="$(daemon_pid)"
		if [ -n "$p" ] && [ "$(field pid)" = "$p" ] && [ "$(field engine)" = running ]; then
			return 0
		fi
		sleep 0.5
		i=$((i + 1))
	done
	return 1
}
pf_state() {
	# PF on/off, the main ruleset and nat/rdr rules, the other anchors:
	# what must be exactly the same before install and after stop /
	# uninstall. (Our anchor's *name* is left out: once created, macOS
	# keeps an anchor name registered, empty, until reboot — no pfctl
	# operation removes it, not even -F all. anchor_empty checks that
	# nothing is in it.)
	sudo pfctl -s info 2>/dev/null | sed -n 's/^Status: \([A-Za-z]*\).*/\1/p'
	sudo pfctl -s rules 2>/dev/null
	sudo pfctl -s nat 2>/dev/null
	sudo pfctl -a com.apple -s Anchors 2>/dev/null | grep -v -x '  com.apple/dpi-proxy'
}
anchor_empty() {
	[ -z "$( { sudo pfctl -a "$ANCHOR" -s nat; sudo pfctl -a "$ANCHOR" -s rules;
		sudo pfctl -a "$ANCHOR" -s Tables; } 2>/dev/null | grep -v -e '^No ALTQ' -e '^ALTQ')" ]
}

stepn "before: PF state and direct networking"
sudo pfctl -s info 2>/dev/null | head -n 2
sudo pfctl -s References 2>/dev/null
pf_state >/tmp/dpi-e2e-pf-before.txt
cat /tmp/dpi-e2e-pf-before.txt
c="$(fetch https://example.com/)"; ok "$c" || die "no direct HTTPS before installing: '$c'"
v6=0
if curl -6 -sS -o /dev/null --max-time 8 https://www.google.com/ 2>/dev/null; then v6=1; fi
note "this machine has IPv6 internet: $([ $v6 -eq 1 ] && echo yes || echo no)"
t0="$(date +%s)"
curl -sS -o /dev/null --max-time 60 -w 'direct download: %{size_download} bytes in %{time_total}s (%{speed_download} B/s)\n' \
	'https://speed.cloudflare.com/__down?bytes=50000000' || true
pass "direct HTTPS $c"

stepn "the generated PF anchor parses (pfctl -n, nothing loaded)"
"$PKG/dpi-proxy" --print-pf-rules | sudo pfctl -a "$ANCHOR-ci-parse" -n -f - || die "pfctl rejects the ruleset"
pass "pfctl accepts the ruleset"

stepn "install (sudo ./install.sh from the package, as a user would)"
( cd "$PKG" && sudo ./install.sh ) || die "install.sh failed"
wait_running || die "service not running after install"
[ -f "/Library/LaunchDaemons/$LABEL.plist" ] || die "plist missing"
[ -x /usr/local/bin/dpi-proxy ] && [ -x /usr/local/bin/nivyx ] \
	|| die "binaries missing"
command -v nivyx >/dev/null || die "nivyx is not on the PATH"
pass "installed; launchd job running (pid $(daemon_pid)); installer health check passed"

stepn "PF: enabled, our anchor loaded, main ruleset untouched, watchdog up"
[ "$(sudo pfctl -s info | sed -n 's/^Status: \([A-Za-z]*\).*/\1/p')" = Enabled ] || die "PF not enabled"
sudo pfctl -a "$ANCHOR" -s nat
sudo pfctl -a "$ANCHOR" -s rules
n="$(anchor_rules)"
[ "$n" -ge 4 ] || die "only $n rules in $ANCHOR"
sudo pfctl -s rules 2>/dev/null >/tmp/dpi-e2e-main-rules.txt
sudo pfctl -s nat 2>/dev/null >/tmp/dpi-e2e-main-nat.txt
sed -n '2,$p' /tmp/dpi-e2e-pf-before.txt | grep -v -e 'dpi-proxy' >/tmp/dpi-e2e-a.txt
{ cat /tmp/dpi-e2e-main-rules.txt /tmp/dpi-e2e-main-nat.txt; sudo pfctl -a com.apple -s Anchors 2>/dev/null; } \
	| grep -v -e 'dpi-proxy' >/tmp/dpi-e2e-b.txt
diff /tmp/dpi-e2e-a.txt /tmp/dpi-e2e-b.txt || die "the main ruleset or other anchors changed"
wd="$(pgrep -f -- '--pf-watchdog' | head -n 1)"
[ -n "$wd" ] || die "no watchdog process"
[ "$(field pf_watchdog)" = "running (pid $wd)" ] || die "status says watchdog '$(field pf_watchdog)'"
sudo pfctl -s References 2>/dev/null
pass "$n rules in $ANCHOR; main ruleset unchanged; watchdog pid $wd"

stepn "normal HTTPS works and is intercepted"
for u in https://example.com/ https://www.wikipedia.org/ https://github.com/ https://www.apple.com/; do
	c="$(fetch "$u")"; ok "$c" || die "$u -> '$c'"
done
wait_status
[ "$(field flows)" -ge 4 ] || die "expected >= 4 intercepted flows, status says $(field flows)"
[ "$(field failures)" -eq 0 ] || die "failures=$(field failures)"
pass "4 sites OK; flows=$(field flows) direct=$(field direct) failures=0"

stepn "the original destination is recovered (DIOCNATLOOK) for a literal IP"
ip="$(dig +short +time=3 +tries=1 A example.com | grep -E '^[0-9.]+$' | head -n 1)"
[ -n "$ip" ] || die "could not resolve example.com"
before="$(field flows)"
c="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --resolve "example.com:443:$ip" https://example.com/ 2>&1)"
ok "$c" || die "https://example.com via $ip -> '$c'"
wait_status
[ "$(field flows)" -gt "$before" ] || die "the connection to $ip was not intercepted"
pass "connection to $ip:443 went through the proxy and reached the right server (HTTP $c)"

stepn "DNS goes through the forwarder (DoH), local names do not"
dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null; sleep 1
q0="$(field dns_queries)"
dscacheutil -q host -a name example.net | grep -q '^ip_address:' || die "system resolution of example.net failed"
dig +time=3 +tries=1 example.org | grep -q 'status: NOERROR' || die "dig example.org failed"
wait_status
[ "$(field dns_intercept)" = doh ] || die "dns_intercept=$(field dns_intercept)"
[ "$(field dns_queries)" -gt "$q0" ] || die "no DNS query reached the forwarder"
dig +time=3 +tries=1 "dpi-e2e-$$.invalid" | grep -q 'status: NXDOMAIN' || die "a nonexistent name did not get NXDOMAIN"
if dig +time=5 +tries=1 "dpi-e2e-host-$$.lan" >/tmp/dpi-e2e-lan.txt 2>&1; then
	note "local name (.lan) -> $(sed -n 's/.*status: \([A-Z]*\).*/\1/p' /tmp/dpi-e2e-lan.txt) from the network's own resolver"
fi
ping -c 1 -t 2 localhost >/dev/null 2>&1 || die "localhost does not resolve"
lh="$(scutil --get LocalHostName 2>/dev/null).local"
if dscacheutil -q host -a name "$lh" | grep -q '^ip_address:'; then
	note "mDNS/Bonjour name $lh still resolves"
else
	note "mDNS name $lh did not resolve (runner has no Bonjour responder on the LAN side; not an error)"
fi
pass "dns_intercept=doh dns_queries=$(field dns_queries) dns_failures=$(field dns_failures); localhost OK"

stepn "QUIC fallback: a known-blocked name's addresses go into the QUIC-reject table"
dig +time=5 +tries=1 A discord.com >/dev/null 2>&1
sleep 1
sudo pfctl -a "$ANCHOR" -t dpi_quic4 -T show 2>/dev/null | tee /tmp/dpi-e2e-quic.txt
[ -s /tmp/dpi-e2e-quic.txt ] || die "no addresses in dpi_quic4 after resolving discord.com"
qip="$(head -n 1 /tmp/dpi-e2e-quic.txt | tr -d ' ')"
if python3 - "$qip" <<'PY' 2>/dev/null
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.connect((sys.argv[1], 443))
s.send(b"\xc0" + b"\x00" * 1199)
try:
    s.recv(100)
except ConnectionRefusedError:
    sys.exit(0)
except Exception:
    pass
try:
    s.send(b"\xc0" + b"\x00" * 1199)
except ConnectionRefusedError:
    sys.exit(0)
sys.exit(1)
PY
then
	pass "UDP/443 to $qip is refused at once (applications fall back to TCP)"
else
	note "UDP/443 refusal to $qip not observable from python here; table populated"
	pass "QUIC-reject table populated"
fi

stepn "IPv6"
if [ $v6 -eq 1 ]; then
	before="$(field flows)"
	c="$(curl -6 -sS -o /dev/null -w '%{http_code}' --max-time 20 https://www.google.com/ 2>&1)"
	ok "$c" || die "IPv6 HTTPS through the proxy -> '$c'"
	wait_status
	[ "$(field flows)" -gt "$before" ] || die "IPv6 connection was not intercepted"
	pass "IPv6 HTTPS intercepted (HTTP $c)"
else
	note "no IPv6 internet on this machine: IPv6 interception not exercised"
fi

stepn "no redirect loop"
before="$(field flows)"
for _ in 1 2 3 4 5; do fetch https://example.com/ >/dev/null; done
wait_status
delta=$(( $(field flows) - before ))
{ [ "$delta" -ge 5 ] && [ "$delta" -le 60 ]; } || die "5 requests -> $delta flows (loop?)"
pass "5 requests -> $delta flows"

stepn "bypass path: forced tlsrec rule for example.com"
printf '\n[domains]\nexample.com = tlsrec\n' | sudo tee -a "$CONF" >/dev/null
sudo nivyx restart >/dev/null || die "restart failed"
wait_running || die "not running after restart"
c="$(fetch https://example.com/)"; ok "$c" || die "example.com with tlsrec -> '$c'"
wait_status
[ "$(field bypassed)" -ge 1 ] || die "bypassed=$(field bypassed); the TLSREC path was not used"
pass "example.com via tlsrec: HTTP $c; bypassed=$(field bypassed)"

stepn "throughput and resource use"
pid="$(daemon_pid)"
curl -sS -o /dev/null --max-time 90 -w 'through dpi-proxy: %{size_download} bytes in %{time_total}s (%{speed_download} B/s)\n' \
	'https://speed.cloudflare.com/__down?bytes=50000000' || true
for u in https://www.wikipedia.org/ https://github.com/ https://www.apple.com/ https://example.com/; do
	for _ in 1 2 3; do fetch "$u" >/dev/null & done
done
wait
ps -o pid=,rss=,vsz=,%cpu=,time= -p "$pid" | awk '{ printf "daemon pid %s: RSS %.1f MB, VSZ %.0f MB, CPU now %s%%, CPU time %s\n", $1, $2/1024, $3/1024, $4, $5 }'
ps -o pid=,rss= -p "$(pgrep -f -- '--pf-watchdog' | head -n 1)" | awk '{ printf "watchdog pid %s: RSS %.1f MB\n", $1, $2/1024 }'
pass "measured"

stepn "nivyx (as a normal user, by name)"
out="$(nivyx status --verbose 2>&1)"; echo "$out"
echo "$out" | grep -q '^engine:    running' || die "status --verbose: engine not running"
for k in mode dns network flows direct bypassed failures pf watchdog; do
	echo "$out" | grep -q "^$k:" || die "status --verbose lacks '$k'"
done
short="$(nivyx status 2>&1)"; echo "$short"
echo "$short" | grep -q '^Service: Running' || die "short status: service not Running"
echo "$short" | grep -q '^Protection: Active' || die "short status: protection not Active"
out="$(nivyx diagnose example.com 2>&1)"; echo "$out"
echo "$out" | grep -q 'Result: Success (HTTP [23]' || die "diagnose failed"
for h in '^DNS' '^HTTPS' '^Decision' 'Poisoning suspected' 'Source:'; do
	echo "$out" | grep -q "$h" || die "diagnose output lacks '$h'"
done
nivyx diagnose example.com --verbose | grep -q '^Detail' || die "diagnose --verbose has no detail"
out="$(nivyx logs 5 2>&1)"; echo "$out"
nivyx logs 200 | grep -q 'transparent mode: TCP/443' || die "logs lack the startup line"
nivyx strategy example.com | grep -q 'tlsrec (manual' || die "strategy"
out="$(sudo nivyx status --verbose 2>&1)"
echo "$out" | grep -q '^pf rules:' || die "status as root lacks the live PF rule count"
nivyx stop >/dev/null 2>&1 && die "stop without sudo should refuse"
nivyx version | grep -q . || die "version printed nothing"
pass "nivyx status/diagnose/logs/strategy/version report correctly"

stepn "nivyx doctor"
nivyx doctor || die "doctor reported a failure while the service is healthy"
pass "doctor: no failures"

stepn "nivyx support-bundle (redaction)"
bundle="/tmp/dpi-e2e-support-$$.tar.gz"
nivyx support-bundle "$bundle" || die "support-bundle failed"
[ -s "$bundle" ] || die "support-bundle produced an empty/missing archive"
bdir="/tmp/dpi-e2e-support-$$"
mkdir -p "$bdir"
tar -xzf "$bundle" -C "$bdir"
[ -f "$bdir/version.txt" ] || die "support-bundle missing version.txt"
grep -rl "$HOME" "$bdir" >/dev/null 2>&1 && die "support-bundle leaked \$HOME into the archive"
[ -f "$bdir/dns-history-summary.txt" ] && ! grep -q "raw per-domain/per-IP records are not included" "$bdir/dns-history-summary.txt" \
	&& die "support-bundle included raw DNS decision history instead of a summary"
rm -rf "$bdir" "$bundle"
pass "support-bundle archive redacted correctly"

stepn "nivyx (primary CLI, v2.1+)"
out="$(nivyx status 2>&1)"; echo "$out"
echo "$out" | grep -q '^Nivyx ' || die "nivyx status did not print the Nivyx version header"
nivyx --help >/dev/null || die "nivyx --help failed"
no_color_out="$(NO_COLOR=1 nivyx status 2>&1)"
printf '%s' "$no_color_out" | grep -q "$(printf '\033')" && die "NO_COLOR=1 but nivyx emitted a color escape code"
pass "nivyx status/--help ran; NO_COLOR honored"

stepn "one public command: no legacy aliases installed"
for old in dpictl dpi-proxy-ctl; do
	[ -e "/usr/local/bin/$old" ] && die "/usr/local/bin/$old is still installed"
	command -v "$old" >/dev/null 2>&1 && die "$old is on the PATH"
done
pass "only nivyx is installed"

stepn "restart keeps working"
sudo nivyx restart >/dev/null || die "restart failed"
wait_running || die "not running after restart"
c="$(fetch https://www.wikipedia.org/)"; ok "$c" || die "after restart -> '$c'"
pass "after restart: HTTP $c (pid $(daemon_pid))"

stepn "stop = ordinary networking, PF as before"
sudo nivyx stop || die "stop failed"
[ -z "$(daemon_pid)" ] || die "still running"
anchor_empty || die "rules or tables left in $ANCHOR after stop"
sleep 1
pgrep -f -- '--pf-watchdog' >/dev/null && die "watchdog still running after a clean stop"
pf_state >/tmp/dpi-e2e-pf-stopped.txt
diff /tmp/dpi-e2e-pf-before.txt /tmp/dpi-e2e-pf-stopped.txt || die "PF state differs from before install"
c="$(fetch https://example.com/)"; ok "$c" || die "stopped -> '$c'"
dscacheutil -flushcache; sudo killall -HUP mDNSResponder 2>/dev/null; sleep 1
dscacheutil -q host -a name example.com | grep -q '^ip_address:' || die "DNS broken after stop"
pass "stopped: anchor empty, PF exactly as before, HTTPS $c, DNS OK"

stepn "crash (SIGKILL of the daemon) = fail-open at once, then launchd restarts it"
sudo nivyx start >/dev/null || die "start failed"
wait_running || die "not running after start"
old="$(daemon_pid)"
sudo kill -9 "$old"
sleep 0.5
[ "$(anchor_rules)" -eq 0 ] || note "rules still present 0.5 s after the crash"
c="$(fetch https://example.com/)"; ok "$c" || die "right after a crash -> '$c' (not fail-open)"
sudo grep -q 'dpi-proxy exited unexpectedly: PF rules removed' "$LOG" || die "watchdog did not log the cleanup"
i=0
while [ $i -lt 40 ]; do
	p="$(daemon_pid)"; [ -n "$p" ] && [ "$p" != "$old" ] && break
	sleep 0.5; i=$((i + 1))
done
wait_running || die "launchd did not restart the daemon after the crash"
[ "$(anchor_rules)" -ge 4 ] || die "rules not reinstalled after the restart"
c="$(fetch https://example.com/)"; ok "$c" || die "after automatic restart -> '$c'"
pass "killed pid $old: HTTPS still worked at once; restarted as pid $(daemon_pid); HTTPS $c"

stepn "hang (SIGSTOP) = watchdog removes the rules within 30 s"
p="$(daemon_pid)"
sudo kill -STOP "$p"
t=0
while [ $t -lt 45 ] && [ "$(anchor_rules)" -gt 0 ]; do sleep 1; t=$((t + 1)); done
[ "$(anchor_rules)" -eq 0 ] || { sudo kill -CONT "$p"; die "rules still present ${t}s after the daemon hung"; }
c="$(fetch https://example.com/)"; ok "$c" || { sudo kill -CONT "$p"; die "while hung -> '$c'"; }
sudo kill -CONT "$p"
t2=0
while [ $t2 -lt 30 ] && [ "$(anchor_rules)" -lt 4 ]; do sleep 1; t2=$((t2 + 1)); done
[ "$(anchor_rules)" -ge 4 ] || die "rules not reinstalled after the daemon resumed"
c="$(fetch https://example.com/)"; ok "$c" || die "after resume -> '$c'"
pass "hung: rules removed after ${t}s, HTTPS $c meanwhile; resumed: reinstalled after ${t2}s"

stepn "crash of daemon and watchdog together: launchd's restart cleans up"
sudo pkill -9 -f '^/usr/local/bin/dpi-proxy'
t=0
note "rules right after killing both: $(anchor_rules) (stay until launchd restarts the daemon)"
while [ $t -lt 30 ] && ! ok "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 https://example.com/ 2>/dev/null)"; do
	sleep 1; t=$((t + 1))
done
note "HTTPS worked again after ${t}s"
[ $t -lt 30 ] || die "no HTTPS for 30 s after killing daemon and watchdog"
wait_running || die "launchd did not restart the daemon"
c="$(fetch https://example.com/)"; ok "$c" || die "after restart -> '$c'"
[ "$(pgrep -f -- '--pf-watchdog' | wc -l | tr -d ' ')" -eq 1 ] || die "not exactly one watchdog"
pass "restarted as pid $(daemon_pid) with one watchdog; HTTPS $c"

stepn "stats, config, help (v2.2 commands)"
nivyx help | grep -q 'update \[--check\]' || die "help does not list update"
nivyx help config | grep -q 'config show' || die "help config failed"
out="$(nivyx stats)"; echo "$out"
echo "$out" | grep -q '^Connections:' || die "stats printed no connection counters"
echo "$out" | grep -q 'example\.com' && die "stats leaked a host name"
nivyx config path | grep -q strategy.conf || die "config path"
nivyx config check || die "config check failed on the installed config"
sudo cp -p "$CONF" /tmp/nivyx-conf.orig
sudo nivyx config set e2e-config-test.example tlsrec | grep -q 'Set e2e-config-test.example' || die "config set"
grep -q '^e2e-config-test.example = tlsrec' "$CONF" || die "config set did not write the rule"
[ -f "$CONF.bak" ] || die "config set kept no backup"
nivyx strategy e2e-config-test.example | grep -q 'tlsrec (manual' || die "strategy does not show the manual rule"
sudo nivyx config unset e2e-config-test.example >/dev/null
grep -q e2e-config-test "$CONF" && die "config unset left the rule"
printf 'this is not valid\n' | sudo tee -a "$CONF" >/dev/null
nivyx config check && die "config check missed a broken line"
sudo cp -p /tmp/nivyx-conf.orig "$CONF"
pass "stats/config/help behave; manual config preserved"

stepn "repair: nothing wrong, then PF anchor emptied externally, then unloaded job"
out="$(sudo nivyx repair)"; echo "$out"
echo "$out" | grep -q 'nothing else wrong' || die "repair on a healthy install reported something"
sudo pfctl -a "$ANCHOR" -F nat >/dev/null 2>&1; sudo pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1
[ "$(anchor_rules)" -eq 0 ] || die "could not empty the anchor for the test"
# the daemon's watchdog restores the rules by itself; whichever happens, the end state must be healthy
sudo nivyx repair >/dev/null; wait_running || die "not running after repair"
sleep 3
[ "$(anchor_rules)" -ge 4 ] || die "anchor rules missing after repair"
sudo launchctl bootout "system/$LABEL" 2>/dev/null; sleep 2
sudo pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1
out="$(sudo nivyx repair)"; echo "$out"
wait_running || die "repair did not bring the job back"
c="$(fetch https://example.com/)"; ok "$c" || die "after repair -> '$c'"
pass "repair restored interception; HTTPS $c"

stepn "update: check, bad checksum, broken release (rollback), good release"
mock="$(mktemp -d /tmp/nivyx-mock.XXXXXX)"; port=18765
arch="$(uname -m)"
current="$(nivyx version | awk '{print $2}')"
# an engine that claims to be 9.9.9: the real one with the version string patched
LC_ALL=C sed 's/2\.2\.0/9.9.9/g' /usr/local/bin/dpi-proxy > "$mock/engine-good"
chmod +x "$mock/engine-good"; codesign --force -s - "$mock/engine-good" >/dev/null 2>&1
"$mock/engine-good" --version | grep -q '9\.9\.9' || die "could not build the 9.9.9 test engine ($("$mock/engine-good" --version))"
cat > "$mock/engine-broken" <<'BROKEN'
#!/bin/sh
case "$1" in
--version) echo "dpi-proxy 9.9.9" ;;
--capabilities) echo "transparent_mode: supported" ;;
*) exit 1 ;;
esac
BROKEN
chmod +x "$mock/engine-broken"
mk_release() {	# $1 engine, $2 good|bad checksum
	rm -rf "$mock/pkg" "$mock/nivyx-macos-$arch.zip" "$mock/SHA256SUMS" "$mock/latest.json"
	mkdir -p "$mock/pkg/nivyx-macos-$arch"
	cp "$1" "$mock/pkg/nivyx-macos-$arch/dpi-proxy"
	cp "$PKG/nivyx" "$mock/pkg/nivyx-macos-$arch/nivyx"
	ditto -c -k --keepParent "$mock/pkg/nivyx-macos-$arch" "$mock/nivyx-macos-$arch.zip"
	if [ "$2" = good ]; then
		(cd "$mock" && shasum -a 256 "nivyx-macos-$arch.zip" > SHA256SUMS)
	else
		echo "0000000000000000000000000000000000000000000000000000000000000000  nivyx-macos-$arch.zip" > "$mock/SHA256SUMS"
	fi
	cat > "$mock/latest.json" <<JSON
{"tag_name":"v9.9.9","prerelease":false,"assets":[
{"name":"nivyx-macos-$arch.zip","browser_download_url":"http://127.0.0.1:$port/nivyx-macos-$arch.zip"},
{"name":"SHA256SUMS","browser_download_url":"http://127.0.0.1:$port/SHA256SUMS"}]}
JSON
}
( cd "$mock" && python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
httpd=$!
sleep 1
NIVYX_RELEASE_API="http://127.0.0.1:$port/latest.json"
upd() { sudo env NIVYX_RELEASE_API="$NIVYX_RELEASE_API" nivyx update "$@"; }

mk_release "$mock/engine-good" good
out="$(NIVYX_RELEASE_API="$NIVYX_RELEASE_API" nivyx update --check)"; echo "$out"
echo "$out" | grep -q 'Update available' || die "update --check did not report the newer release"
[ "$(nivyx version | awk '{print $2}')" = "$current" ] || die "update --check changed the installed version"

mk_release "$mock/engine-good" bad
upd >/tmp/upd.out 2>&1 && die "update accepted a wrong checksum"
cat /tmp/upd.out; grep -q 'SHA-256 mismatch' /tmp/upd.out || die "no checksum diagnostic"
[ "$(nivyx version | awk '{print $2}')" = "$current" ] || die "bad checksum still changed the install"
wait_running || die "service down after a rejected update"

mk_release "$mock/engine-broken" good
upd >/tmp/upd.out 2>&1 && die "update kept a release whose engine does not run"
cat /tmp/upd.out
[ "$(nivyx version | awk '{print $2}')" = "$current" ] || die "broken release was not rolled back"
wait_running || die "service down after rollback"
c="$(fetch https://example.com/)"; ok "$c" || die "after rollback -> '$c'"

cfg_before="$(sudo shasum -a 256 "$CONF" | cut -d' ' -f1)"
mk_release "$mock/engine-good" good
upd || die "a good update failed"
[ "$(nivyx version | awk '{print $2}')" = 9.9.9 ] || die "version after update: $(nivyx version)"
[ "$(sudo shasum -a 256 "$CONF" | cut -d' ' -f1)" = "$cfg_before" ] || die "update changed the config"
wait_running || die "service down after update"
c="$(fetch https://example.com/)"; ok "$c" || die "after update -> '$c'"
kill "$httpd" 2>/dev/null || true
rm -rf "$mock"
pass "check ok; bad checksum rejected; broken release rolled back; good release installed ($current -> 9.9.9), config kept"

stepn "uninstall leaves nothing behind"
( cd "$PKG" && sudo ./uninstall.sh ) || die "uninstall.sh failed"
[ -e "/Library/LaunchDaemons/$LABEL.plist" ] && die "plist left"
launchctl print "system/$LABEL" >/dev/null 2>&1 && die "launchd job left"
for f in /usr/local/bin/dpi-proxy /usr/local/bin/nivyx /usr/local/etc/dpi-proxy \
	/usr/local/var/dpi-proxy /var/run/dpi-proxy /var/log/dpi-proxy.log /var/log/dpi-proxy.stderr.log; do
	[ -e "$f" ] && die "$f left"
done
# a new shell: this one still has the old location hashed
/bin/sh -c 'command -v nivyx' >/dev/null && die "nivyx still on the PATH"
pgrep -f '^/usr/local/bin/dpi-proxy' >/dev/null && die "a dpi-proxy process is left"
anchor_empty || die "rules or tables left in $ANCHOR"
sudo pfctl -s References 2>/dev/null | grep -q '[0-9]\{8,\}' && [ "$(sed -n 1p /tmp/dpi-e2e-pf-before.txt)" = Disabled ] \
	&& die "a PF enable reference is still held"
pf_state >/tmp/dpi-e2e-pf-after.txt
diff /tmp/dpi-e2e-pf-before.txt /tmp/dpi-e2e-pf-after.txt || die "PF state differs from before install"
sudo pfctl -s References 2>/dev/null
c="$(fetch https://example.com/)"; ok "$c" || die "after uninstall -> '$c'"
pass "no plist, job, binaries, config, state, logs, processes, PF rules, tables or PF reference; PF as before; HTTPS $c"

stepn "clean reinstall"
( cd "$PKG" && sudo ./install.sh ) || die "reinstall failed"
wait_running || die "not running after reinstall"
c="$(fetch https://github.com/)"; ok "$c" || die "after reinstall -> '$c'"
( cd "$PKG" && sudo ./uninstall.sh ) || die "second uninstall failed"
pf_state >/tmp/dpi-e2e-pf-after2.txt
diff /tmp/dpi-e2e-pf-before.txt /tmp/dpi-e2e-pf-after2.txt || die "PF state differs after the second uninstall"
pass "reinstalled (HTTPS $c) and uninstalled cleanly again"

printf '\nALL MACOS E2E CHECKS PASSED (%s, macOS %s, %ss)\n' "$(uname -m)" "$(sw_vers -productVersion)" "$(( $(date +%s) - t0 ))"
