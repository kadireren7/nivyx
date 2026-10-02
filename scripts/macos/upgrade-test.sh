#!/bin/sh
#
# Upgrade regression test on a real Mac (CI: GitHub's macOS runners,
# passwordless sudo): the real v2.1.0 package is installed, then the
# candidate package is installed over it, exactly as a user would.
# Uninstalls at the end.
#
#   ./upgrade-test.sh <old-package-dir> <new-package-dir>
set -u

OLD="$(cd "${1:?usage: upgrade-test.sh <old-package-dir> <new-package-dir>}" && pwd)"
NEW="$(cd "${2:?usage: upgrade-test.sh <old-package-dir> <new-package-dir>}" && pwd)"
LABEL="io.github.kadireren7.dpi-proxy"
ANCHOR="com.apple/dpi-proxy"
STATUS=/var/run/dpi-proxy/transparent.status
CONF=/usr/local/etc/dpi-proxy/strategy.conf
DECISIONS=/usr/local/var/dpi-proxy/tp-decisions.conf
step=0

stepn() { step=$((step + 1)); printf '\n=== [%d] %s\n' "$step" "$1"; }
pass() { printf 'PASS: %s\n' "$1"; }
die() {
	printf 'FAIL: %s\n' "$1"
	sudo tail -n 60 /var/log/dpi-proxy.log 2>/dev/null
	cat "$STATUS" 2>/dev/null
	exit 1
}
field() { sed -n "s/^$1: //p" "$STATUS" 2>/dev/null | head -n 1; }
fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>&1 || true; }
ok() { echo "$1" | grep -Eq '^[23][0-9][0-9]$'; }
daemon_pid() {
	launchctl print "system/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1
}
wait_running() {
	i=0
	while [ $i -lt 60 ]; do
		p="$(daemon_pid)"
		if [ -n "$p" ] && [ "$(field pid)" = "$p" ] && [ "$(field engine)" = running ]; then return 0; fi
		sleep 0.5; i=$((i + 1))
	done
	return 1
}

stepn "install the real v2.1.0 package"
( cd "$OLD" && sudo ./install.sh ) || die "v2.1.0 install.sh failed"
wait_running || die "v2.1.0 service not running"
[ -x /usr/local/bin/dpictl ] && [ -x /usr/local/bin/dpi-proxy-ctl ] || die "the v2.1.0 layout lacks dpictl/dpi-proxy-ctl; wrong baseline?"
old_version="$(/usr/local/bin/nivyx version | awk '{print $2}')"
c="$(fetch https://example.com/)"; ok "$c" || die "v2.1.0 HTTPS -> '$c'"
pass "v2.1.0 installed (version $old_version), dpictl/dpi-proxy-ctl present, HTTPS $c"

stepn "user state that must survive, third-party tool planted"
printf '\n[domains]\nexample.com = tlsrec\n' | sudo tee -a "$CONF" >/dev/null
sudo launchctl kickstart -k "system/$LABEL"; wait_running || die "not running after config change"
for _ in 1 2 3; do fetch https://example.com/ >/dev/null; done
sleep 11
conf_hash="$(sudo shasum -a 256 "$CONF" | cut -d' ' -f1)"
decisions_before=0
[ -s "$DECISIONS" ] && decisions_before="$(grep -vc '^#' "$DECISIONS")"
printf '#!/bin/sh\necho third-party tool\n' | sudo tee /usr/local/bin/dpictl >/dev/null
sudo chmod 755 /usr/local/bin/dpictl
pass "rule written, third-party dpictl planted ($decisions_before decisions on record)"

stepn "upgrade: install the candidate package over it"
( cd "$NEW" && sudo ./install.sh ) || die "candidate install.sh failed over v2.1.0"
wait_running || die "service not running after the upgrade"

stepn "after the upgrade"
new_version="$(nivyx version | awk '{print $2}')"
[ "$new_version" != "$old_version" ] || die "version did not change ($new_version)"
nivyx status | grep -q '^Service: Running' || die "nivyx status: not Running"
[ -e /usr/local/bin/dpi-proxy-ctl ] && die "legacy dpi-proxy-ctl was not removed"
[ -e /usr/local/bin/dpictl ] || die "the third-party dpictl was deleted"
[ "$(/usr/local/bin/dpictl)" = "third-party tool" ] || die "the third-party dpictl was altered"
sudo rm -f /usr/local/bin/dpictl
[ "$(sudo shasum -a 256 "$CONF" | cut -d' ' -f1)" = "$conf_hash" ] || die "the manual config was modified by the upgrade"
if [ "$decisions_before" -gt 0 ]; then [ -s "$DECISIONS" ] || die "learned decisions were lost"; fi
nivyx strategy example.com | grep -q 'tlsrec (manual' || die "the manual rule no longer applies"
pass "version $old_version -> $new_version; dpi-proxy-ctl gone; foreign dpictl untouched; config and state intact"

stepn "DNS, HTTPS, bypass, restart, doctor, repair after the upgrade"
sleep 11
[ "$(field dns_intercept)" = doh ] || die "dns_intercept=$(field dns_intercept)"
dscacheutil -flushcache 2>/dev/null || true
dscacheutil -q host -a name example.net | grep -q ip_address || die "DNS resolution failed"
c="$(fetch https://example.com/)"; ok "$c" || die "HTTPS through the manual tlsrec rule -> '$c'"
c="$(fetch https://www.wikipedia.org/)"; ok "$c" || die "HTTPS -> '$c'"
sudo nivyx restart >/dev/null || die "restart failed"
wait_running || die "not running after nivyx restart"
c="$(fetch https://example.com/)"; ok "$c" || die "HTTPS after restart -> '$c'"
nivyx doctor || die "doctor reported a failure"
sudo nivyx repair | grep -q 'nothing else wrong' || die "repair found something wrong right after an upgrade"
pass "DNS over DoH, HTTPS, bypass rule, restart, doctor and repair all fine"

stepn "uninstall removes everything of ours"
( cd "$NEW" && sudo ./uninstall.sh ) || die "uninstall.sh failed"
for f in /Library/LaunchDaemons/$LABEL.plist /usr/local/bin/dpi-proxy /usr/local/bin/nivyx /usr/local/bin/dpictl /usr/local/bin/dpi-proxy-ctl /usr/local/etc/dpi-proxy /usr/local/var/dpi-proxy /var/run/dpi-proxy; do
	[ -e "$f" ] && die "$f left behind"
done
launchctl print "system/$LABEL" >/dev/null 2>&1 && die "launchd job left"
c="$(fetch https://example.com/)"; ok "$c" || die "after uninstall -> '$c'"
pass "uninstalled; HTTPS $c"

printf '\nMACOS UPGRADE v2.1.0 -> candidate: ALL CHECKS PASSED\n'
