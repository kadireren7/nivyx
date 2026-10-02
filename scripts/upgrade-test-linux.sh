#!/usr/bin/env bash
#
# Upgrade regression test: a real v2.1.0 installation, upgraded in place
# with the current tree's installer. CI: GitHub's ubuntu runner (sudo,
# nftables, full git history with tags). It uninstalls at the end - don't
# run it where you want to keep an installation.
#
#   ./scripts/upgrade-test-linux.sh [old-tag]     (default: v2.1.0)
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OLD_TAG="${1:-v2.1.0}"
STATUS=/run/dpi-proxy/transparent.status
CONF=/etc/dpi-proxy/strategy.conf
DECISIONS=/var/lib/dpi-proxy/tp-decisions.conf
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
fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>&1 || true; }
ok() { [[ "$1" =~ ^[23][0-9][0-9]$ ]]; }

old="$(mktemp -d)/old"
git -C "$ROOT" worktree add --detach "$old" "$OLD_TAG" >/dev/null || die "cannot check out $OLD_TAG (fetch tags?)"
trap 'git -C "$ROOT" worktree remove --force "$old" >/dev/null 2>&1 || true' EXIT

stepn "install the real $OLD_TAG"
sudo "$old/scripts/install.sh" || die "$OLD_TAG install.sh failed"
systemctl is-active --quiet dpi-proxy-transparent || die "$OLD_TAG service not active"
[ -x /usr/local/bin/dpictl ] && [ -x /usr/local/bin/dpi-proxy-ctl ] || die "the $OLD_TAG layout lacks dpictl/dpi-proxy-ctl; wrong baseline?"
old_version="$(/usr/local/bin/nivyx version | awk '{print $2}')"
c="$(fetch https://example.com/)"; ok "$c" || die "$OLD_TAG HTTPS -> '$c'"
pass "$OLD_TAG installed (version $old_version), dpictl/dpi-proxy-ctl present, HTTPS $c"

stepn "user state that must survive: a manual rule and learned decisions"
printf '\n[domains]\nexample.com = tlsrec\n' | sudo tee -a "$CONF" >/dev/null
sudo systemctl restart dpi-proxy-transparent
sleep 3
for _ in 1 2 3; do fetch https://example.com/ >/dev/null; done
fetch https://gateway.discord.gg/ >/dev/null || true
sleep 11
conf_hash="$(sudo sha256sum "$CONF" | cut -d' ' -f1)"
decisions_before=0
[ -s "$DECISIONS" ] && decisions_before="$(grep -vc '^#' "$DECISIONS" || true)"
echo "decisions on record before the upgrade: $decisions_before"
# a third-party tool that happens to share a legacy name must not be touched
printf '#!/bin/sh\necho third-party tool\n' | sudo tee /usr/local/bin/dpictl >/dev/null
sudo chmod 0755 /usr/local/bin/dpictl
pass "rule written, state recorded, third-party dpictl planted"

stepn "upgrade in place with the current installer"
sudo "$ROOT/scripts/install.sh" || die "v2.2 install.sh failed over $OLD_TAG"
systemctl is-active --quiet dpi-proxy-transparent || die "service not active after the upgrade"

stepn "after the upgrade: nivyx, ghost commands, preserved state"
new_version="$(nivyx version | awk '{print $2}')"
[ "$new_version" = "$(cat "$ROOT/VERSION")" ] || die "nivyx reports $new_version, expected $(cat "$ROOT/VERSION")"
[ "$new_version" != "$old_version" ] || die "version did not change ($new_version)"
out="$(nivyx status)"; echo "$out" | grep -q '^Service: Running' || die "nivyx status: not Running"
[ -e /usr/local/bin/dpi-proxy-ctl ] && die "legacy dpi-proxy-ctl was not removed"
[ -e /usr/local/bin/dpictl ] || die "the third-party dpictl was deleted"
[ "$(/usr/local/bin/dpictl)" = "third-party tool" ] || die "the third-party dpictl was altered"
sudo rm -f /usr/local/bin/dpictl
[ "$(sudo sha256sum "$CONF" | cut -d' ' -f1)" = "$conf_hash" ] || die "the manual config was modified by the upgrade"
if [ "$decisions_before" -gt 0 ]; then
	[ -s "$DECISIONS" ] || die "learned decisions were lost in the upgrade"
fi
out="$(nivyx strategy example.com)"; echo "$out" | grep -q 'tlsrec (manual' || die "the manual rule no longer applies"
pass "version $old_version -> $new_version; dpi-proxy-ctl gone; foreign dpictl untouched; config and state intact"

stepn "DNS, HTTPS, bypass, restart, doctor after the upgrade"
sleep 11
[ "$(field dns_intercept)" = doh ] || die "dns_intercept=$(field dns_intercept)"
sudo resolvectl flush-caches 2>/dev/null || true
getent ahostsv4 example.net >/dev/null || die "DNS resolution failed"
c="$(fetch https://example.com/)"; ok "$c" || die "HTTPS through the manual tlsrec rule -> '$c'"
c="$(fetch https://www.wikipedia.org/)"; ok "$c" || die "HTTPS -> '$c'"
sudo nivyx restart
sleep 3
systemctl is-active --quiet dpi-proxy-transparent || die "not active after nivyx restart"
c="$(fetch https://example.com/)"; ok "$c" || die "HTTPS after restart -> '$c'"
nivyx doctor || die "doctor reported a failure"
out="$(sudo nivyx repair)"; echo "$out" | grep -q 'nothing else wrong' || die "repair found something wrong right after an upgrade"
pass "DNS over DoH, HTTPS, bypass rule, restart, doctor and repair all fine"

stepn "uninstall removes everything of ours"
sudo "$ROOT/scripts/uninstall.sh" --purge
systemctl list-unit-files | grep -q dpi-proxy-transparent && die "unit still present"
sudo nft list table inet dpi_proxy_tp >/dev/null 2>&1 && die "table still present"
for f in /usr/local/bin/nivyx /usr/local/bin/dpi-proxy /usr/local/bin/dpictl /usr/local/bin/dpi-proxy-ctl /etc/dpi-proxy /var/lib/dpi-proxy; do
	[ -e "$f" ] && die "$f left behind"
done
c="$(fetch https://example.com/)"; ok "$c" || die "after uninstall -> '$c'"
pass "uninstalled; HTTPS $c"

printf '\nUPGRADE %s -> current: ALL CHECKS PASSED\n' "$OLD_TAG"
