#!/usr/bin/env bash
#
# The release package on a machine with an older Nivyx (CI: GitHub's ubuntu
# runner, sudo, nftables, tags). Uninstalls at the end.
#   1. the old release (installed from its tag) is offered the package by
#      its own `nivyx update` and refuses it, changing nothing (v2.4.1 has
#      a new package layout);
#   2. the package's own install.sh (prebuilt engine, nothing compiled)
#      installs over it, keeping the manual rule, and works;
#   3. the package's update.sh hands over to `nivyx update`;
#   4. the package's uninstall.sh removes it.
#
#   ./scripts/update-compat-test-linux.sh [old-tag]     (default: v2.4.0)
#   NIVYX_TEST_PACKAGE=<tar.gz>: the exact archive a release would publish
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OLD_TAG="${1:-v2.4.0}"
mock="$(mktemp -d)"; port=18766
step=0

stepn() { step=$((step + 1)); printf '\n=== [%d] %s\n' "$step" "$1"; }
pass() { printf 'PASS: %s\n' "$1"; }
die() {
	printf 'FAIL: %s\n' "$1"
	journalctl -u nivyx -u dpi-proxy-transparent --no-pager -n 60 || true
	exit 1
}
fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>&1 || true; }
ok() { [[ "$1" =~ ^[23][0-9][0-9]$ ]]; }
active() { systemctl is-active --quiet "$1"; }
conf_of() { if [ -e /etc/systemd/system/dpi-proxy-transparent.service ]; then echo /etc/dpi-proxy/strategy.conf; else echo /etc/nivyx/strategy.conf; fi; }
svc_of() { if [ -e /etc/systemd/system/dpi-proxy-transparent.service ]; then echo dpi-proxy-transparent; else echo nivyx; fi; }

old="$(mktemp -d)/old"
git -C "$ROOT" worktree add --detach "$old" "$OLD_TAG" >/dev/null || die "cannot check out $OLD_TAG (fetch tags?)"
httpd=""
trap 'kill $httpd 2>/dev/null || true; git -C "$ROOT" worktree remove --force "$old" >/dev/null 2>&1 || true' EXIT

new_version="$(cat "$ROOT/VERSION")"
mkdir -p "$mock/out"
if [ -n "${NIVYX_TEST_PACKAGE:-}" ]; then
	cp "$NIVYX_TEST_PACKAGE" "$mock/out/nivyx-linux-x86_64.tar.gz"
else
	make -C "$ROOT" clean >/dev/null && make -C "$ROOT" >/dev/null || die "build failed"
	"$ROOT/scripts/package-linux.sh" "$mock/out" >/dev/null
fi
tar -C "$mock" -xzf "$mock/out/nivyx-linux-x86_64.tar.gz"
PKG="$mock/nivyx-linux-x86_64"
[ "$("$PKG/files/nivyx-engine" --version)" = "nivyx-engine $new_version" ] || die "the package is not version $new_version"
(cd "$mock/out" && sha256sum nivyx-linux-x86_64.tar.gz > SHA256SUMS)
cat > "$mock/out/latest.json" <<JSON
{"tag_name":"v$new_version","prerelease":false,"assets":[
{"name":"nivyx-linux-x86_64.tar.gz","browser_download_url":"http://127.0.0.1:$port/nivyx-linux-x86_64.tar.gz"},
{"name":"SHA256SUMS","browser_download_url":"http://127.0.0.1:$port/SHA256SUMS"}]}
JSON
(cd "$mock/out" && exec python3 -m http.server "$port" --bind 127.0.0.1 >"$mock/httpd.log" 2>&1) &
httpd=$!
t=0
until curl -fsS --max-time 3 "http://127.0.0.1:$port/latest.json" >/dev/null 2>&1 || [ $t -ge 15 ]; do sleep 1; t=$((t + 1)); done
export NIVYX_RELEASE_API="http://127.0.0.1:$port/latest.json"

stepn "$OLD_TAG installed from its tag, with a manual rule"
sudo "$old/scripts/install.sh" >/dev/null || die "$OLD_TAG install.sh failed"
svc="$(svc_of)"; conf="$(conf_of)"
active "$svc" || die "$OLD_TAG service not active"
printf '\n[domains]\nexample.com = tlsrec\n' | sudo tee -a "$conf" >/dev/null
sudo systemctl restart "$svc"; sleep 3
conf_hash="$(sudo sha256sum "$conf" | cut -d' ' -f1)"
old_version="$(nivyx version | awk '{print $2}')"
pass "$OLD_TAG installed ($old_version, service $svc)"

stepn "the $OLD_TAG updater (as released) refuses the $new_version package and changes nothing"
before="$(sha256sum /usr/local/bin/nivyx | cut -d' ' -f1) $(systemctl show -p MainPID --value "$svc")"
rc=0; out="$(sudo env NIVYX_RELEASE_API="$NIVYX_RELEASE_API" /usr/local/bin/nivyx update 2>&1)" || rc=$?
echo "$out"
[ "$rc" != 0 ] || die "the $OLD_TAG updater reported success on the new layout"
grep -q 'nothing was installed' <<<"$out" || die "the $OLD_TAG updater did not say that nothing was installed"
[ "$before" = "$(sha256sum /usr/local/bin/nivyx | cut -d' ' -f1) $(systemctl show -p MainPID --value "$svc")" ] \
	|| die "the CLI or the service process changed"
[ "$(nivyx version | awk '{print $2}')" = "$old_version" ] || die "the installed version changed"
c="$(fetch https://example.com/)"; ok "$c" || die "HTTPS after the refused update -> '$c'"
pass "refused; nothing changed (HTTPS $c)"

stepn "the package's install.sh (prebuilt, nothing compiled) installs over $OLD_TAG"
sudo "$PKG/install.sh" || die "the package's install.sh failed over $OLD_TAG"
active nivyx || die "nivyx not active"
[ "$(nivyx version | awk '{print $2}')" = "$new_version" ] || die "version after install: $(nivyx version)"
systemctl list-unit-files | grep -q 'dpi-proxy-transparent' && die "old unit left behind"
[ -e /usr/local/bin/dpi-proxy ] && die "old engine path left behind"
[ "$(sudo sha256sum /etc/nivyx/strategy.conf | cut -d' ' -f1)" = "$conf_hash" ] || die "the manual config changed"
nivyx strategy example.com | grep -q 'tlsrec (manual' || die "the manual rule no longer applies"
c="$(fetch https://example.com/)"; ok "$c" || die "HTTPS after install -> '$c'"
nivyx doctor || die "doctor failed"
pass "$old_version -> $new_version from the package; config and rule kept; HTTPS $c"

stepn "the package's update.sh hands over to nivyx update"
out="$(sudo env NIVYX_RELEASE_API="$NIVYX_RELEASE_API" "$PKG/update.sh" 2>&1)" || { echo "$out"; die "update.sh failed"; }
echo "$out"
grep -q 'up to date' <<<"$out" || die "update.sh did not run nivyx update"
pass "update.sh -> nivyx update (up to date)"

stepn "the package's uninstall.sh"
sudo "$PKG/uninstall.sh" --purge
systemctl list-unit-files | grep -qE '^(nivyx|dpi-proxy-transparent)\.service' && die "unit still present"
for f in /usr/local/bin/nivyx /usr/local/bin/nivyx-engine /usr/local/bin/dpi-proxy /etc/nivyx /etc/dpi-proxy /var/lib/nivyx /var/lib/dpi-proxy; do
	[ -e "$f" ] && die "$f left behind"
done
c="$(fetch https://example.com/)"; ok "$c" || die "after uninstall -> '$c'"
printf '\nLINUX PACKAGE OVER %s -> %s: ALL CHECKS PASSED\n' "$OLD_TAG" "$new_version"
