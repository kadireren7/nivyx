#!/bin/sh
#
# `nivyx update` on a real Mac (CI: GitHub's macOS runners, Apple silicon
# and Intel, passwordless sudo):
#   1. the OLD release's own updater (the code exactly as released)
#      installs the candidate package; settings and learned state are kept;
#   2. the candidate's updater rolls back a release whose engine cannot
#      start;
#   3. the old updater rolls back the same broken release;
#   4. (with a cases folder) the candidate's release-signature check:
#      every case of scripts/signed-release-cases.sh, test keys only.
# Uninstalls at the end.
#
#   update-test.sh <old-package-dir> <candidate.zip> [<cases-dir>]
#     <cases-dir>: output of signed-release-cases.sh for a 99.0.0 candidate zip
set -u

OLD="$(cd "${1:?usage: update-test.sh <old-package-dir> <candidate.zip> [cases-dir]}" && pwd)"
ZIP="$(cd "$(dirname "${2:?usage}")" && pwd)/$(basename "$2")"
CASES="${3:-}"
LABEL="io.github.kadireren7.dpi-proxy"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
STATUS=/var/run/dpi-proxy/transparent.status
CONF=/usr/local/etc/dpi-proxy/strategy.conf
DECISIONS=/usr/local/var/dpi-proxy/tp-decisions.conf
PLANTED="nivyx-update-test.invalid 0123456789abcdef 4 tlsrec original"
arch="$(uname -m)"
asset="nivyx-macos-$arch.zip"
port=18769
mock="$(mktemp -d /private/tmp/nivyx-update-test.XXXXXX)"
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
sha() { sudo shasum -a 256 "$1" | awk '{print $1}'; }
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
version_now() { /usr/local/bin/dpi-proxy --version 2>/dev/null | sed -n 's/^dpi-proxy //p'; }
httpd=""
cleanup() { [ -n "$httpd" ] && kill "$httpd" 2>/dev/null; sudo rm -rf "$mock"; }
trap cleanup EXIT

# the daemon writes its decisions when it stops and reads them when it starts
stop_daemon() { sudo launchctl bootout "system/$LABEL" 2>/dev/null; i=0; while [ -n "$(daemon_pid)" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done; }
start_daemon() { sudo launchctl bootstrap system "$PLIST" || die "bootstrap failed"; wait_running || die "daemon not running after start"; }
plant_state() {
	stop_daemon
	printf '\n[domains]\nexample.com = tlsrec\n' | sudo tee -a "$CONF" >/dev/null
	printf '%s %s\n' "$PLANTED" "$(date +%s)" | sudo tee -a "$DECISIONS" >/dev/null
	start_daemon
	conf_hash="$(sha "$CONF")"
}
assert_state() { # what
	[ "$(sha "$CONF")" = "$conf_hash" ] || die "$1: the configuration changed"
	/usr/local/bin/nivyx strategy example.com | grep -q 'tlsrec' || die "$1: the manual rule no longer applies"
	stop_daemon
	sudo grep -q "^$PLANTED " "$DECISIONS" || die "$1: the learned decision is gone"
	start_daemon
	c="$(fetch https://example.com/)"; ok "$c" || die "$1: HTTPS -> '$c'"
}
no_leftovers() {
	[ -z "$(ls -d /private/var/tmp/nivyx-update.* 2>/dev/null)" ] || die "$1: a download folder was left behind"
	[ -z "$(sudo sh -c 'ls -d /usr/local/var/dpi-proxy/update-rollback.* /usr/local/var/dpi-proxy/rollback 2>/dev/null')" ] \
		|| die "$1: a rollback folder was left behind"
	[ ! -e /var/run/nivyx-admin.lock ] || die "$1: the update lock was left behind"
}

# serve a folder (asset, SHA256SUMS, ...) as "the latest release" <tag>
serve_dir() { # dir tag
	a=""
	for f in "$1"/*; do
		f="${f##*/}"
		case "$f" in tag | expect) continue ;; esac
		a="$a{\"name\":\"$f\",\"browser_download_url\":\"http://127.0.0.1:$port/${1#"$mock"/}/$f\"},"
	done
	printf '{"tag_name":"v%s","prerelease":false,"assets":[%s]}\n' "$2" "${a%,}" >"$mock/latest.json"
}
run_update() { # [keys-file]
	rc=0
	if [ -n "${1:-}" ]; then
		out="$(sudo env NIVYX_RELEASE_API="http://127.0.0.1:$port/latest.json" NIVYX_TEST_RELEASE_KEYS="$1" /usr/local/bin/nivyx update 2>&1)" || rc=$?
	else
		out="$(sudo env NIVYX_RELEASE_API="http://127.0.0.1:$port/latest.json" /usr/local/bin/nivyx update 2>&1)" || rc=$?
	fi
	printf '%s\n' "$out" | sed 's/^/    | /'
}
release_dir() { # name zip
	mkdir -p "$mock/$1"
	cp "$2" "$mock/$1/$asset"
	(cd "$mock/$1" && shasum -a 256 "$asset" >SHA256SUMS)
}

cand_dir="$mock/candidate"
mkdir -p "$cand_dir" && ditto -x -k "$ZIP" "$cand_dir" || die "cannot unpack $ZIP"
NEW="$cand_dir/nivyx-macos-$arch"
new_version="$("$NEW/dpi-proxy" --version | sed -n 's/^dpi-proxy //p')"
old_version="$("$OLD/dpi-proxy" --version | sed -n 's/^dpi-proxy //p')"
[ -n "$new_version" ] && [ -n "$old_version" ] || die "cannot read the package versions"

# a release whose engine answers the updater's checks but cannot run the service
mkdir -p "$mock/broken-src"
ditto -x -k "$ZIP" "$mock/broken-src"
cat >"$mock/broken-src/nivyx-macos-$arch/dpi-proxy" <<'EOF'
#!/bin/sh
case "${1:-}" in
--version) echo "dpi-proxy 99.0.0" ;;
--capabilities) echo "transparent_mode: supported" ;;
*) exit 1 ;;
esac
EOF
chmod 755 "$mock/broken-src/nivyx-macos-$arch/dpi-proxy"
(cd "$mock/broken-src" && ditto -c -k --keepParent "nivyx-macos-$arch" "$mock/broken.zip")
release_dir candidate-release "$ZIP"
release_dir broken-release "$mock/broken.zip"

(cd "$mock" && exec python3 -m http.server "$port" --bind 127.0.0.1 >"$mock/httpd.log" 2>&1) &
httpd=$!
i=0
until curl -fsS --max-time 3 "http://127.0.0.1:$port/candidate-release/SHA256SUMS" >/dev/null 2>&1 || [ $i -ge 15 ]; do sleep 1; i=$((i + 1)); done

stepn "install the real $old_version package ($arch), add a manual rule and a learned decision"
( cd "$OLD" && sudo ./install.sh ) >/dev/null || die "$old_version install.sh failed"
wait_running || die "$old_version not running"
[ "$(version_now)" = "$old_version" ] || die "installed version: $(version_now)"
plant_state
pass "$old_version installed"

stepn "the $old_version updater (as released) installs the candidate $new_version"
serve_dir "$mock/candidate-release" "$new_version"
run_update
[ "$rc" = 0 ] || die "the $old_version updater failed on the candidate (exit $rc)"
echo "$out" | grep -q 'Health check passed' || die "the $old_version updater did not pass its health check"
[ "$(version_now)" = "$new_version" ] || die "version after the old updater: $(version_now)"
cmp -s /usr/local/bin/nivyx "$NEW/nivyx" || die "the CLI was not replaced by the candidate's"
assert_state "after the $old_version updater"
/usr/local/bin/nivyx doctor >/dev/null || die "doctor failed after the update"
no_leftovers "old updater"
pass "$old_version -> $new_version through the old updater; config, rule, learned decision, HTTPS, doctor fine"

stepn "the candidate's updater rolls back a release that cannot start"
serve_dir "$mock/broken-release" 99.0.0
run_update
[ "$rc" != 0 ] || die "the broken release was accepted"
echo "$out" | grep -q 'rolled back' || die "no rollback reported"
[ "$(version_now)" = "$new_version" ] || die "version after the rollback: $(version_now)"
wait_running || die "not running after the rollback"
cmp -s /usr/local/bin/nivyx "$NEW/nivyx" || die "the CLI was not restored"
assert_state "after the candidate's rollback"
no_leftovers "candidate rollback"
pass "candidate updater: broken 99.0.0 rolled back to $new_version, state intact"

stepn "the $old_version updater rolls back the same broken release"
( cd "$NEW" && sudo ./uninstall.sh ) >/dev/null || die "plain uninstall failed"
( cd "$OLD" && sudo ./install.sh ) >/dev/null || die "$old_version reinstall failed"
wait_running || die "$old_version not running after reinstall"
[ "$(sha "$CONF")" = "$conf_hash" ] || die "plain uninstall + reinstall changed the config"
old_cli="$(sha /usr/local/bin/nivyx)"
run_update
[ "$rc" != 0 ] || die "the $old_version updater accepted the broken release"
echo "$out" | grep -q 'rolled back' || die "the $old_version updater did not roll back"
[ "$(version_now)" = "$old_version" ] || die "version after the old updater's rollback: $(version_now)"
[ "$(sha /usr/local/bin/nivyx)" = "$old_cli" ] || die "the old CLI was not restored"
wait_running || die "not running after the old updater's rollback"
assert_state "after the $old_version rollback"
no_leftovers "old rollback"
pass "$old_version updater: broken release rolled back, state intact"

if [ -n "$CASES" ]; then
	stepn "release signatures (candidate updater, temporary test keys)"
	( cd "$NEW" && sudo ./install.sh ) >/dev/null || die "candidate install failed"
	wait_running || die "candidate not running"
	sudo rm -rf "$mock/cases"; cp -R "$CASES" "$mock/cases"
	for c in unsigned no-signature modified-manifest modified-package wrong-key substituted-manifest old-release valid; do
		expect="$(cat "$mock/cases/$c/expect")"
		before="$(sha /usr/local/bin/dpi-proxy) $(sha /usr/local/bin/nivyx) $(daemon_pid) $(sha "$CONF")"
		echo "--- $c (expect: $expect)"
		serve_dir "$mock/cases/$c" "$(cat "$mock/cases/$c/tag")"
		run_update "$mock/cases/trusted-keys"
		case "$expect" in
		refuse:*)
			[ "$rc" != 0 ] || die "$c: not refused"
			echo "$out" | grep -qF "${expect#refuse:}" || die "$c: refused, but not with '${expect#refuse:}'"
			echo "$out" | grep -q 'nothing was installed' || die "$c: no 'nothing was installed'"
			[ "$before" = "$(sha /usr/local/bin/dpi-proxy) $(sha /usr/local/bin/nivyx) $(daemon_pid) $(sha "$CONF")" ] \
				|| die "$c: engine, CLI, service process or config changed"
			;;
		up-to-date)
			[ "$rc" = 0 ] && echo "$out" | grep -q 'up to date' || die "$c: an old release was not ignored"
			[ "$before" = "$(sha /usr/local/bin/dpi-proxy) $(sha /usr/local/bin/nivyx) $(daemon_pid) $(sha "$CONF")" ] \
				|| die "$c: something changed"
			;;
		install)
			[ "$rc" = 0 ] || die "$c: the correctly signed release was refused"
			echo "$out" | grep -q 'Release signature verified' || die "$c: no signature verification reported"
			[ "$(version_now)" = 99.0.0 ] || die "$c: version $(version_now)"
			assert_state "after the signed update"
			;;
		esac
		no_leftovers "$c"
		pass "$c: $expect"
	done
fi

stepn "uninstall"
( cd "$NEW" && sudo ./uninstall.sh --purge ) >/dev/null || die "uninstall --purge failed"
[ ! -e "$PLIST" ] || die "plist left behind"
printf '\nMACOS UPDATE TEST (%s, %s -> %s): ALL CHECKS PASSED\n' "$arch" "$old_version" "$new_version"
