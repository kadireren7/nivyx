#!/usr/bin/env bash
#
# The updater's release-signature check on a real install (CI: GitHub's
# ubuntu runner, sudo, nftables), with temporary test keys
# (scripts/signed-release-cases.sh): an unsigned, unverifiable, modified,
# wrongly signed, substituted or old release is refused and changes
# nothing (same engine, CLI and service process; settings and learned
# state untouched); a correctly signed one installs. Also checked: with no
# key configured (the state until the maintainer sets up signing) updates
# work exactly as before. Uninstalls at the end.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
STATUS=/run/nivyx/transparent.status
CONF=/etc/nivyx/strategy.conf
DECISIONS=/var/lib/nivyx/tp-decisions.conf
PLANTED="nivyx-signature-test.invalid 0123456789abcdef 4 tlsrec original"
mock="$(mktemp -d)"; port=18768
step=0

stepn() { step=$((step + 1)); printf '\n=== [%d] %s\n' "$step" "$1"; }
pass() { printf 'PASS: %s\n' "$1"; }
die() {
	printf 'FAIL: %s\n' "$1"
	journalctl -u nivyx --no-pager -n 60 || true
	exit 1
}
fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>&1 || true; }
ok() { [[ "$1" =~ ^[23][0-9][0-9]$ ]]; }
sha() { sudo sha256sum "$1" | cut -d' ' -f1; }
engine_ready() {
	local i pid
	for i in $(seq 1 60); do
		pid="$(systemctl show -p MainPID --value nivyx 2>/dev/null || true)"
		if systemctl is-active --quiet nivyx && [ -n "$pid" ] && [ "$pid" != 0 ] \
			&& grep -qx "pid: $pid" "$STATUS" 2>/dev/null && grep -q '^engine: running' "$STATUS" 2>/dev/null; then
			return 0
		fi
		sleep 0.5
	done
	return 1
}
httpd=""
trap 'kill $httpd 2>/dev/null || true' EXIT

install_base() {
	sudo "$ROOT/scripts/install.sh" >/dev/null || die "install.sh failed"
	engine_ready || die "service not ready after install"
	base="$(nivyx version | awk '{print $2}')"
}
plant_state() {
	sudo systemctl stop nivyx
	printf '\n[domains]\nexample.com = tlsrec\n' | sudo tee -a "$CONF" >/dev/null
	printf '%s %s\n' "$PLANTED" "$(date +%s)" | sudo tee -a "$DECISIONS" >/dev/null
	sudo systemctl start nivyx
	engine_ready || die "service not ready after planting state"
	conf_hash="$(sha "$CONF")"
}
snapshot() {
	printf '%s %s %s %s\n' "$(sha /usr/local/bin/nivyx-engine)" "$(sha /usr/local/bin/nivyx)" \
		"$(systemctl show -p MainPID --value nivyx)" "$(sha "$CONF")"
}
# serve case $1 as "the latest release"
serve() {
	local d="$mock/cases/$1" f a=""
	for f in "$d"/*; do
		f="${f##*/}"
		case "$f" in tag | expect) continue ;; esac
		a="$a{\"name\":\"$f\",\"browser_download_url\":\"http://127.0.0.1:$port/$1/$f\"},"
	done
	printf '{"tag_name":"v%s","prerelease":false,"assets":[%s]}\n' "$(cat "$d/tag")" "${a%,}" >"$mock/cases/latest.json"
}
run_update() { # case [keys-file]
	serve "$1"
	rc=0
	out="$(sudo env NIVYX_RELEASE_API="http://127.0.0.1:$port/latest.json" ${2:+NIVYX_TEST_RELEASE_KEYS="$2"} \
		/usr/local/bin/nivyx update 2>&1)" || rc=$?
	printf '%s\n' "$out" | sed 's/^/    | /'
}
no_leftovers() {
	compgen -G '/var/tmp/nivyx-update.*' >/dev/null && die "$1: a download folder was left behind"
	[ -z "$(sudo sh -c 'ls -d /var/lib/nivyx/update-rollback.* 2>/dev/null' || true)" ] || die "$1: a rollback folder was left behind"
	return 0
}

stepn "install this tree, add a manual rule and a learned decision"
install_base
plant_state
pass "installed $base"

stepn "a newer package (99.0.0) and the signed/tampered releases built from it"
make -C "$ROOT" clean >/dev/null && make -C "$ROOT" VERSION=99.0.0 >/dev/null || die "99.0.0 build failed"
"$ROOT/scripts/package-linux.sh" "$mock/pkg" >/dev/null
make -C "$ROOT" clean >/dev/null
openssl genpkey -algorithm ed25519 -out "$mock/key-a.pem" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$mock/key-b.pem" 2>/dev/null
"$ROOT/scripts/signed-release-cases.sh" "$mock/cases" "$mock/pkg/nivyx-linux-x86_64.tar.gz" 99.0.0 \
	"$mock/key-a.pem" "$mock/key-b.pem"
(cd "$mock/cases" && exec python3 -m http.server "$port" --bind 127.0.0.1 >"$mock/httpd.log" 2>&1) &
httpd=$!
t=0
until curl -fsS --max-time 3 "http://127.0.0.1:$port/valid/tag" >/dev/null 2>&1 || [ $t -ge 15 ]; do sleep 1; t=$((t + 1)); done
pass "temporary keys only; nothing here is a production key"

stepn "no release key configured (as shipped until signing is set up): unchanged behaviour"
run_update unsigned
[ "$rc" = 0 ] || die "update failed without a configured key (exit $rc)"
grep -q 'release signatures are not checked yet' <<<"$out" || die "no notice that signatures are not checked"
[ "$(nivyx version | awk '{print $2}')" = 99.0.0 ] || die "99.0.0 not installed"
pass "installed with the SHA256SUMS check alone, and says so"
install_base
[ "$(sha "$CONF")" = "$conf_hash" ] || die "reinstall changed the config"

stepn "signature enforced (test key): every bad release is refused and changes nothing"
for c in unsigned no-signature modified-manifest modified-package wrong-key substituted-manifest old-release; do
	expect="$(cat "$mock/cases/$c/expect")"
	before="$(snapshot)"
	echo "--- $c (expect: $expect)"
	run_update "$c" "$mock/cases/trusted-keys"
	case "$expect" in
	refuse:*)
		[ "$rc" != 0 ] || die "$c: the update was not refused"
		grep -qF "${expect#refuse:}" <<<"$out" || die "$c: refused, but not with '${expect#refuse:}'"
		grep -q 'nothing was installed' <<<"$out" || die "$c: no 'nothing was installed'"
		grep -q 'Installed\|restarting' <<<"$out" && die "$c: the updater went on to install"
		;;
	up-to-date)
		[ "$rc" = 0 ] && grep -q 'up to date' <<<"$out" || die "$c: an old release was not ignored"
		;;
	esac
	[ "$(snapshot)" = "$before" ] || die "$c: engine, CLI, service process or config changed"
	no_leftovers "$c"
	pass "$c: ${expect}; engine, CLI, service process and config unchanged"
done
sudo grep -q "^$PLANTED " "$DECISIONS" || die "the learned decision is gone"

stepn "a correctly signed release installs"
run_update valid "$mock/cases/trusted-keys"
[ "$rc" = 0 ] || die "the valid release was refused (exit $rc)"
grep -q 'Release signature verified' <<<"$out" || die "no signature verification reported"
[ "$(nivyx version | awk '{print $2}')" = 99.0.0 ] || die "version after the update: $(nivyx version)"
engine_ready || die "service not ready after the update"
[ "$(sha "$CONF")" = "$conf_hash" ] || die "the config changed"
nivyx strategy example.com | grep -q 'tlsrec (manual' || die "the manual rule no longer applies"
sudo systemctl stop nivyx	# writes the decisions out
sudo grep -q "^$PLANTED " "$DECISIONS" || die "the learned decision did not survive the update"
sudo systemctl start nivyx; engine_ready || die "service not ready after restart"
c="$(fetch https://example.com/)"; ok "$c" || die "HTTPS after the update -> '$c'"
no_leftovers valid
pass "99.0.0 installed: signature verified, config, manual rule and learned decision kept, HTTPS $c"

stepn "uninstall"
sudo "$ROOT/scripts/uninstall.sh" --purge >/dev/null
printf '\nUPDATE SIGNATURE TEST: ALL CHECKS PASSED\n'
