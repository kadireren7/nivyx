#!/usr/bin/env bash
#
# An install made by an older release (service dpi-proxy-transparent) must
# keep working through that release's own `nivyx update`, and then move to
# the nivyx names without losing settings. CI: GitHub's ubuntu runner
# (sudo, nftables, tags). It uninstalls at the end.
#
#   ./scripts/update-compat-test-linux.sh [old-tag]     (default: v2.2.2)
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OLD_TAG="${1:-v2.2.2}"
OLD_CONF=/etc/dpi-proxy/strategy.conf
CONF=/etc/nivyx/strategy.conf
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

old="$(mktemp -d)/old"
git -C "$ROOT" worktree add --detach "$old" "$OLD_TAG" >/dev/null || die "cannot check out $OLD_TAG (fetch tags?)"
httpd=""
trap 'kill $httpd 2>/dev/null || true; git -C "$ROOT" worktree remove --force "$old" >/dev/null 2>&1 || true' EXIT

# the package the current tree would publish, served as "the latest release"
make -C "$ROOT" clean >/dev/null && make -C "$ROOT" >/dev/null || die "build failed"
new_version="$(cat "$ROOT/VERSION")"
tree_version="$new_version"
"$ROOT/scripts/package-linux.sh" "$mock/out" >/dev/null
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

install_old() {
	sudo "$old/scripts/install.sh" || die "$OLD_TAG install.sh failed"
	active dpi-proxy-transparent || die "$OLD_TAG service not active"
	printf '\n[domains]\nexample.com = tlsrec\n' | sudo tee -a "$OLD_CONF" >/dev/null
	sudo systemctl restart dpi-proxy-transparent; sleep 3
	conf_hash="$(sudo sha256sum "$OLD_CONF" | cut -d' ' -f1)"
}
old_cli_update() {
	# the OLD release's own updater, installing the NEW package
	sudo env NIVYX_RELEASE_API="$NIVYX_RELEASE_API" /usr/local/bin/nivyx update || die "the $OLD_TAG updater failed on the new package"
	[ "$(nivyx version | awk '{print $2}')" = "$new_version" ] || die "version after the old updater: $(nivyx version)"
	active dpi-proxy-transparent || die "old-layout service down after the old updater"
	c="$(fetch https://example.com/)"; ok "$c" || die "HTTPS after the old updater -> '$c'"
	out="$(nivyx status)"; echo "$out" | grep -q '^Service: Running' || die "the new CLI does not see the old-layout service"
}
assert_migrated() {
	active nivyx || die "nivyx service not active after the move"
	systemctl list-unit-files | grep -q 'dpi-proxy-transparent' && die "old unit left behind"
	[ -e /usr/local/bin/dpi-proxy ] && die "old engine path left behind"
	[ -x /usr/local/bin/nivyx-engine ] || die "nivyx-engine missing"
	[ -d /etc/dpi-proxy ] && die "/etc/dpi-proxy left behind"
	[ "$(sudo sha256sum "$CONF" | cut -d' ' -f1)" = "$conf_hash" ] || die "the manual config changed in the move"
	systemctl is-enabled --quiet nivyx || die "nivyx is not enabled at boot"
	out="$(nivyx strategy example.com)"; echo "$out" | grep -q 'tlsrec (manual' || die "the manual rule no longer applies"
	c="$(fetch https://example.com/)"; ok "$c" || die "HTTPS after the move -> '$c'"
	nivyx doctor || die "doctor failed after the move"
}

stepn "$OLD_TAG installed, its own updater installs the new package"
install_old
old_cli_update
pass "old updater OK; old names keep running with the new CLI and engine"

stepn "sudo nivyx repair moves the install to the nivyx names"
sudo nivyx repair || die "repair failed"
assert_migrated
pass "moved by repair, settings intact"
sudo "$ROOT/scripts/uninstall.sh" --purge

stepn "the new CLI's update moves it as part of updating"
install_old
old_cli_update
# a newer release than the one installed now
make -C "$ROOT" clean >/dev/null && make -C "$ROOT" VERSION=99.0.0 >/dev/null || die "99.0.0 build failed"
"$ROOT/scripts/package-linux.sh" "$mock/out" >/dev/null
(cd "$mock/out" && sha256sum nivyx-linux-x86_64.tar.gz > SHA256SUMS)
sed -i "s/\"v$new_version\"/\"v99.0.0\"/;s/v$new_version/v99.0.0/" "$mock/out/latest.json"
sudo env NIVYX_RELEASE_API="$NIVYX_RELEASE_API" nivyx update || die "the new CLI's update failed"
[ "$(nivyx version | awk '{print $2}')" = 99.0.0 ] || die "version after update: $(nivyx version)"
assert_migrated
pass "update installed 99.0.0 and moved the install to the nivyx names"

stepn "rollback: the renamed service cannot start -> the old layout is restored"
sudo "$ROOT/scripts/uninstall.sh" --purge
new_version=99.0.0	# the mock release now serves the 99.0.0 package
install_old
old_cli_update
# a drop-in makes the NEW unit fail to start (systemd applies it once the unit exists)
sudo mkdir -p /etc/systemd/system/nivyx.service.d
printf '[Service]\nExecStart=\nExecStart=/bin/false\n' | sudo tee /etc/systemd/system/nivyx.service.d/fail.conf >/dev/null
sudo systemctl daemon-reload
out="$(sudo nivyx repair 2>&1)" && echo "$out" || echo "$out"
sudo rm -rf /etc/systemd/system/nivyx.service.d
sudo systemctl daemon-reload
active dpi-proxy-transparent || die "rollback: the old service is not running"
active nivyx && die "rollback: both old and new services are active"
[ -e /etc/systemd/system/nivyx.service ] && die "rollback: the new unit was left behind"
[ -e /usr/local/bin/nivyx-engine ] && die "rollback: the staged new engine was left behind"
[ -x /usr/local/bin/dpi-proxy ] || die "rollback: the old engine is gone"
[ "$(sudo sha256sum "$OLD_CONF" | cut -d' ' -f1)" = "$conf_hash" ] || die "rollback: the manual config changed"
c="$(fetch https://example.com/)"; ok "$c" || die "rollback: HTTPS -> '$c'"
out="$(nivyx status)"; echo "$out" | grep -q '^Service: Running' || die "rollback: nivyx status not Running"
pass "unhealthy new service: old layout restored, one service active, config intact, HTTPS fine"
sudo "$ROOT/scripts/uninstall.sh" --purge

stepn "uninstall"
sudo "$ROOT/scripts/uninstall.sh" --purge
systemctl list-unit-files | grep -qE '^(nivyx|dpi-proxy-transparent)\.service' && die "unit still present"
for f in /usr/local/bin/nivyx /usr/local/bin/nivyx-engine /usr/local/bin/dpi-proxy /etc/nivyx /etc/dpi-proxy /var/lib/nivyx /var/lib/dpi-proxy; do
	[ -e "$f" ] && die "$f left behind"
done
printf '\nUPDATE COMPAT %s -> %s: ALL CHECKS PASSED\n' "$OLD_TAG" "$tree_version"
