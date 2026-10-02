#!/usr/bin/env bash
#
# End-to-end test of Linux transparent mode on a real machine (CI:
# GitHub's ubuntu runner, sudo). Installs with scripts/install.sh, then
# checks the whole lifecycle; exits non-zero on the first failure.
# It uninstalls at the end — don't run it where you want to keep an
# installation.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATUS=/run/dpi-proxy/transparent.status
CONF=/etc/dpi-proxy/strategy.conf
step=0

stepn() { step=$((step + 1)); printf '\n=== [%d] %s\n' "$step" "$1"; }
pass() { printf 'PASS: %s\n' "$1"; }
die() {
	printf 'FAIL: %s\n' "$1"
	journalctl -u dpi-proxy-transparent --no-pager -n 60 || true
	cat "$STATUS" 2>/dev/null || true
	exit 1
}
field() { sed -n "s/^$1: //p" "$STATUS" | head -n 1; }
wait_status() { sleep 11; }	# status is rewritten every 10 s
fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>&1 || true; }
ok() { [[ "$1" =~ ^[23][0-9][0-9]$ ]]; }

stepn install
sudo "$ROOT/scripts/install.sh" || die "install.sh failed"
systemctl is-active --quiet dpi-proxy-transparent || die "service not active"
pass "installed; installer health check (DNS + HTTPS through it) passed"

stepn "normal HTTPS works and is intercepted"
for u in https://example.com/ https://www.wikipedia.org/ https://github.com/; do
	c="$(fetch "$u")"; ok "$c" || die "$u -> '$c'"
done
wait_status
[ "$(field flows)" -ge 3 ] || die "flows=$(field flows)"
[ "$(field failures)" -eq 0 ] || die "failures=$(field failures)"
pass "flows=$(field flows) direct=$(field direct) failures=0"

stepn "DNS goes through the forwarder (DoH)"
sudo resolvectl flush-caches 2>/dev/null || true
getent ahostsv4 example.net >/dev/null || die "resolution failed"
wait_status
[ "$(field dns_intercept)" = doh ] || die "dns_intercept=$(field dns_intercept)"
[ "$(field dns_queries)" -ge 1 ] || die "no DNS query reached the forwarder"
pass "dns_intercept=doh dns_queries=$(field dns_queries)"

stepn "no redirect loop"
before="$(field flows)"
for _ in 1 2 3 4 5; do fetch https://example.com/ >/dev/null; done
wait_status
delta=$(( $(field flows) - before ))
{ [ "$delta" -ge 5 ] && [ "$delta" -le 60 ]; } || die "5 requests -> $delta flows"
pass "5 requests -> $delta flows"

stepn "bypass path: forced tlsrec rule for example.com"
printf '\n[domains]\nexample.com = tlsrec\n' | sudo tee -a "$CONF" >/dev/null
sudo systemctl restart dpi-proxy-transparent
sleep 3
c="$(fetch https://example.com/)"; ok "$c" || die "example.com with tlsrec -> '$c'"
wait_status
[ "$(field bypassed)" -ge 1 ] || die "bypassed=$(field bypassed)"
pass "example.com via tlsrec: HTTP $c; bypassed=$(field bypassed)"

stepn "stop = ordinary networking"
sudo systemctl stop dpi-proxy-transparent
sudo nft list table inet dpi_proxy_tp >/dev/null 2>&1 && die "table left behind"
c="$(fetch https://example.com/)"; ok "$c" || die "stopped -> '$c'"
pass "stopped: table gone, HTTPS $c"

stepn "crash = fail-open, then automatic restart"
sudo systemctl start dpi-proxy-transparent
sleep 3
sudo systemctl kill -s KILL dpi-proxy-transparent
sleep 1
c="$(fetch https://example.com/)"; ok "$c" || die "right after a crash -> '$c'"
for _ in $(seq 1 20); do systemctl is-active --quiet dpi-proxy-transparent && break; sleep 1; done
systemctl is-active --quiet dpi-proxy-transparent || die "not restarted"
sleep 3
c="$(fetch https://example.com/)"; ok "$c" || die "after restart -> '$c'"
pass "killed: fail-open, restarted, HTTPS $c"

stepn "nivyx commands"
nivyx status
nivyx status --verbose
nivyx diagnose example.com
nivyx version | grep -q . || die "nivyx version printed nothing"
nivyx doctor || die "nivyx doctor reported a failure while the service is healthy"
bundle="$(mktemp -u).tar.gz"
nivyx support-bundle "$bundle" || die "support-bundle failed"
[ -s "$bundle" ] || die "support-bundle produced an empty/missing archive"
bundle_dir="$(mktemp -d)"
tar -xzf "$bundle" -C "$bundle_dir"
[ -f "$bundle_dir/version.txt" ] || die "support-bundle archive missing version.txt"
if grep -rl "$HOME" "$bundle_dir" >/dev/null 2>&1; then
	die "support-bundle leaked \$HOME ($HOME) into the archive"
fi
if grep -rlE '(^|[^a-zA-Z0-9_])'"$USER"'([^a-zA-Z0-9_]|$)' "$bundle_dir" >/dev/null 2>&1; then
	die "support-bundle leaked the username ($USER) into the archive"
fi
# dns-history-summary.txt is only written when tp-decisions.conf
# exists (i.e. something was auto-learned, as opposed to the manual
# tlsrec rule this test uses) — so its absence here is not a failure,
# but if present it must be the redacted summary, never raw records.
if [ -f "$bundle_dir/dns-history-summary.txt" ]; then
	grep -q "raw per-domain/per-IP records are not included" "$bundle_dir/dns-history-summary.txt" \
		|| die "support-bundle included raw DNS decision history instead of a summary"
fi
rm -rf "$bundle_dir" "$bundle"
pass "nivyx status/doctor/support-bundle/version ran; archive redaction verified"

stepn "nivyx output"
out="$(nivyx status)"; echo "$out"
echo "$out" | grep -q '^Nivyx ' || die "nivyx status did not print the Nivyx version header"
nivyx status --verbose
nivyx --help >/dev/null || die "nivyx --help failed"
no_color_out="$(NO_COLOR=1 nivyx status)"
if printf '%s' "$no_color_out" | grep -q "$(printf '\033')"; then die "NO_COLOR=1 but nivyx emitted a color escape code"; fi
pass "nivyx status/--help ran; NO_COLOR honored"

stepn "one public command: no legacy aliases installed"
for old in dpictl dpi-proxy-ctl; do
	[ -e "/usr/local/bin/$old" ] && die "/usr/local/bin/$old is still installed"
	command -v "$old" >/dev/null 2>&1 && die "$old is still on the PATH"
done
pass "only nivyx is installed"

stepn "stats, config, diagnose, help (v2.2 commands)"
out="$(nivyx help)"; echo "$out" | grep -q 'update \[--check\]' || die "help does not list update"
while read -r c; do [ -n "$c" ] || continue; out="$(nivyx help "$c" 2>&1)" && [ -n "$out" ] || die "nivyx help $c failed"; done < "$ROOT/scripts/commands.txt"
out="$(nivyx help config)"; echo "$out" | grep -q 'config show' || die "help config failed"
out="$(nivyx stats)"; echo "$out"
echo "$out" | grep -q '^Connections:' || die "stats printed no connection counters"
echo "$out" | grep -q 'example\.com' && die "stats leaked a host name"
out="$(nivyx config path)"; echo "$out" | grep -q strategy.conf || die "config path"
nivyx config check || die "config check failed on the installed config"
out="$(nivyx config show)"; echo "$out" | grep -q 'default = pass' || die "config show"
out="$(nivyx diagnose example.com)"; echo "$out"
for h in '^DNS' '^HTTPS' '^Decision' 'Poisoning suspected' 'Source:'; do
	echo "$out" | grep -q "$h" || die "diagnose output lacks '$h'"
done
echo "$out" | grep -q 'Result: Success' || die "diagnose HTTPS did not succeed"
out="$(nivyx diagnose example.com --verbose)"; echo "$out" | grep -q '^Detail' || die "diagnose --verbose has no detail"
sudo cp -p "$CONF" /tmp/nivyx-conf.orig
out="$(sudo nivyx config set e2e-config-test.example tlsrec)"; echo "$out" | grep -q 'Set e2e-config-test.example' || die "config set"
grep -q '^e2e-config-test.example = tlsrec' "$CONF" || die "config set did not write the rule"
[ -f "$CONF.bak" ] || die "config set kept no backup"
out="$(nivyx strategy e2e-config-test.example)"; echo "$out" | grep -q 'tlsrec (manual' || die "strategy does not show the manual rule"
sudo nivyx config unset e2e-config-test.example >/dev/null
grep -q e2e-config-test "$CONF" && die "config unset left the rule"
printf 'this is not valid\n' | sudo tee -a "$CONF" >/dev/null
nivyx config check && die "config check missed a broken line"
sudo cp -p /tmp/nivyx-conf.orig "$CONF"
sudo systemctl reload dpi-proxy-transparent
pass "stats/config/diagnose/help behave; manual config preserved"

stepn "repair: nothing wrong on a healthy install"
out="$(sudo nivyx repair 2>&1)" || { echo "$out"; die "nivyx repair failed"; }; echo "$out"
echo "$out" | grep -q 'nothing else wrong' || die "repair on a healthy install reported something"

stepn "repair: firewall table removed externally"
sudo nft delete table inet dpi_proxy_tp || die "could not delete the table"
out="$(sudo nivyx repair 2>&1)" || { echo "$out"; die "nivyx repair failed"; }; echo "$out"
echo "$out" | grep -q 'fixed' || die "repair fixed nothing"
sudo nft list table inet dpi_proxy_tp >/dev/null || die "repair did not restore the table"
c="$(fetch https://example.com/)"; ok "$c" || die "after repair -> '$c'"
pass "table restored, HTTPS $c"

stepn "repair: service disabled, stopped, with a stale table and status file"
sudo systemctl disable --now dpi-proxy-transparent >/dev/null 2>&1
sudo nft add table inet dpi_proxy_tp
sudo mkdir -p "$(dirname "$STATUS")"
printf 'engine: running\n' | sudo tee "$STATUS" >/dev/null
out="$(sudo nivyx repair 2>&1)" || { echo "$out"; die "nivyx repair failed"; }; echo "$out"
systemctl is-enabled --quiet dpi-proxy-transparent || die "repair did not re-enable the service"
systemctl is-active --quiet dpi-proxy-transparent || die "repair did not start the service"
c="$(fetch https://example.com/)"; ok "$c" || die "after repair -> '$c'"
pass "enabled, started, stale state cleared, HTTPS $c"

stepn "repair: damaged learned-decision file"
sudo systemctl stop dpi-proxy-transparent
printf '# header\nbroken line\nexample.org %s 4 tlsrec original 1790000000\n' "0123456789abcdef" | sudo tee /var/lib/dpi-proxy/tp-decisions.conf >/dev/null
out="$(sudo nivyx repair 2>&1)" || { echo "$out"; die "nivyx repair failed"; }; echo "$out"
echo "$out" | grep -q 'damaged' || die "repair did not report the damaged line"
grep -q 'broken line' /var/lib/dpi-proxy/tp-decisions.conf && die "damaged line still present"
c="$(fetch https://example.com/)"; ok "$c" || die "after repair -> '$c'"
pass "damaged line removed, HTTPS $c"

stepn "update: check, bad checksum, broken release (rollback), good release"
mock="$(mktemp -d)"; port=18765
current="$(nivyx version | awk '{print $2}')"
mk_release() {	# $1 = engine file, $2 = SHA256SUMS mode (good|bad), $3 = version tag
	rm -rf "$mock/pkg" "$mock"/*.tar.gz "$mock"/SHA256SUMS "$mock"/latest.json
	mkdir -p "$mock/pkg/nivyx-linux-x86_64"
	cp "$1" "$mock/pkg/nivyx-linux-x86_64/dpi-proxy"
	cp "$ROOT/scripts/nivyx" "$mock/pkg/nivyx-linux-x86_64/nivyx"
	tar -C "$mock/pkg" -czf "$mock/nivyx-linux-x86_64.tar.gz" nivyx-linux-x86_64
	if [ "$2" = good ]; then
		(cd "$mock" && sha256sum nivyx-linux-x86_64.tar.gz > SHA256SUMS)
	else
		echo "0000000000000000000000000000000000000000000000000000000000000000  nivyx-linux-x86_64.tar.gz" > "$mock/SHA256SUMS"
	fi
	cat > "$mock/latest.json" <<JSON
{"tag_name":"v$3","prerelease":false,"assets":[
{"name":"nivyx-linux-x86_64.tar.gz","browser_download_url":"http://127.0.0.1:$port/nivyx-linux-x86_64.tar.gz"},
{"name":"SHA256SUMS","browser_download_url":"http://127.0.0.1:$port/SHA256SUMS"}]}
JSON
}
# an engine that claims 99.0.0 and works: the real source, rebuilt with the version overridden
cp "$ROOT/dpi-proxy" "$mock/engine-current"
make -C "$ROOT" clean >/dev/null && make -C "$ROOT" VERSION=99.0.0 >/dev/null || die "could not build the 99.0.0 test engine"
cp "$ROOT/dpi-proxy" "$mock/engine-good"
cat > "$mock/engine-broken" <<'BROKEN'
#!/bin/sh
case "$1" in
--version) echo "dpi-proxy 99.0.0" ;;
--capabilities) echo "transparent_mode: supported" ;;
*) exit 1 ;;
esac
BROKEN
chmod +x "$mock/engine-broken"

mk_release "$mock/engine-good" good 99.0.0
(cd "$mock" && exec python3 -m http.server "$port" --bind 127.0.0.1 >"$mock/httpd.log" 2>&1) &
httpd=$!
t=0
until curl -fsS --max-time 3 "http://127.0.0.1:$port/latest.json" >/dev/null 2>&1 || [ $t -ge 15 ]; do sleep 1; t=$((t + 1)); done
curl -fsS --max-time 3 "http://127.0.0.1:$port/latest.json" >/dev/null 2>&1 || { cat "$mock/httpd.log"; die "the local mock release server is not reachable"; }
export NIVYX_RELEASE_API="http://127.0.0.1:$port/latest.json"
upd() { sudo env NIVYX_RELEASE_API="$NIVYX_RELEASE_API" nivyx update "$@"; }

out="$(nivyx update --check)"; echo "$out"
echo "$out" | grep -q 'Update available' || die "update --check did not report the newer release"
[ "$(nivyx version | awk '{print $2}')" = "$current" ] || die "update --check changed the installed version"

mk_release "$mock/engine-good" bad 99.0.0
upd >/tmp/upd.out 2>&1 && die "update accepted a wrong checksum"
cat /tmp/upd.out; grep -q 'SHA-256 mismatch' /tmp/upd.out || die "no checksum diagnostic"
[ "$(nivyx version | awk '{print $2}')" = "$current" ] || die "bad checksum still changed the install"
systemctl is-active --quiet dpi-proxy-transparent || die "service down after a rejected update"

mk_release "$mock/engine-broken" good 99.0.0
upd >/tmp/upd.out 2>&1 && die "update kept a release whose engine does not run"
cat /tmp/upd.out
[ "$(nivyx version | awk '{print $2}')" = "$current" ] || die "broken release was not rolled back"
systemctl is-active --quiet dpi-proxy-transparent || die "service down after rollback"
c="$(fetch https://example.com/)"; ok "$c" || die "after rollback -> '$c'"

cfg_sudo cp -p "$CONF" /tmp/nivyx-conf.orig
mk_release "$mock/engine-good" good 99.0.0
upd || die "a good update failed"
[ "$(nivyx version | awk '{print $2}')" = 99.0.0 ] || die "version after update: $(nivyx version)"
[ "$(sudo sha256sum "$CONF" | cut -d' ' -f1)" = "$cfg_before" ] || die "update changed the config"
systemctl is-active --quiet dpi-proxy-transparent || die "service down after update"
c="$(fetch https://example.com/)"; ok "$c" || die "after update -> '$c'"
out="$(nivyx update --check)"; echo "$out"; echo "$out" | grep -q 'up to date' || die "still offering an update after updating"
kill "$httpd" 2>/dev/null || true
unset NIVYX_RELEASE_API
pass "check ok; bad checksum rejected; broken release rolled back; good release installed ($current -> 99.0.0), config kept"

stepn "size and resource use"
ls -l /usr/local/bin/dpi-proxy
t0="$(date +%s.%N)"
sudo systemctl restart dpi-proxy-transparent
i=0
while [ $i -lt 40 ]; do
	grep -q '^engine: running' "$STATUS" 2>/dev/null && break
	sleep 0.25
	i=$((i + 1))
done
t1="$(date +%s.%N)"
grep -q '^engine: running' "$STATUS" || die "did not report running after restart (resource-use step)"
awk -v a="$t0" -v b="$t1" 'BEGIN { printf "startup time: %.2fs (start issued -> engine: running)\n", b - a }'
pid="$(field pid)"
ps -o pid=,nlwp=,rss=,vsz=,%cpu= -p "$pid" \
	| awk '{ printf "daemon pid %s: %s thread(s), RSS %.1f MB, VSZ %.0f MB, CPU %s%%\n", $1, $2, $3/1024, $4/1024, $5 }'
for u in https://example.com/ https://www.wikipedia.org/ https://github.com/; do
	for _ in 1 2 3; do fetch "$u" >/dev/null & done
done
wait
ps -o pid=,rss=,%cpu= -p "$pid" | awk '{ printf "daemon pid %s under load: RSS %.1f MB, CPU %s%%\n", $1, $2/1024, $3 }'
curl -sS -o /dev/null --max-time 60 \
	-w 'throughput: %{size_download} bytes in %{time_total}s (%{speed_download} B/s)\n' \
	'https://speed.cloudflare.com/__down?bytes=50000000' || true
pass "measured"

stepn "uninstall cleans only our own state"
sudo "$ROOT/scripts/uninstall.sh" --purge
systemctl list-unit-files | grep -q dpi-proxy-transparent && die "unit still present"
sudo nft list table inet dpi_proxy_tp >/dev/null 2>&1 && die "table still present"
c="$(fetch https://example.com/)"; ok "$c" || die "after uninstall -> '$c'"
pass "uninstalled; HTTPS $c"

printf '\nALL LINUX E2E CHECKS PASSED\n'
