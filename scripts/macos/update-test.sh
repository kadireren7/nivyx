#!/bin/sh
#
# Updates on a real Mac (CI: GitHub's macOS runners, Apple silicon and
# Intel, passwordless sudo):
#   1. an OLD release (v2.2.x ... v2.4.0, "dpi-proxy" names) is installed
#      with a manual rule and a learned decision;
#   2. its own `nivyx update` (the code exactly as released) is offered the
#      candidate and refuses it, changing nothing: v2.4.1 has a new layout,
#      users move over once with "Install Nivyx.command";
#   3. the candidate's installer moves the old installation over to the
#      nivyx names, keeping the rule and the learned decision;
#   4. the candidate's `nivyx update` rolls back a release whose engine
#      cannot start.
# Uninstalls at the end.
#
#   update-test.sh <old-package-dir> <candidate.zip>
set -u

OLD="$(cd "${1:?usage: update-test.sh <old-package-dir> <candidate.zip>}" && pwd)"
ZIP="$(cd "$(dirname "${2:?usage}")" && pwd)/$(basename "$2")"
PLANTED="nivyx-update-test.invalid 0123456789abcdef 4 tlsrec original"
arch="$(uname -m)"
asset="nivyx-macos-$arch.zip"
port=18769
mock="$(mktemp -d /private/tmp/nivyx-update-test.XXXXXX)"
step=0

# the old names until the move (use_new_names), the new ones after it
use_names() { # name engine
	LABEL="io.github.kadireren7.$1"
	PLIST="/Library/LaunchDaemons/$LABEL.plist"
	STATUS="/var/run/$1/transparent.status"
	CONF="/usr/local/etc/$1/strategy.conf"
	DECISIONS="/usr/local/var/$1/tp-decisions.conf"
	LOGF="/var/log/$1.log"
	ENGINE="$2"
}
use_names dpi-proxy /usr/local/bin/dpi-proxy

stepn() { step=$((step + 1)); printf '\n=== [%d] %s\n' "$step" "$1"; }
pass() { printf 'PASS: %s\n' "$1"; }
die() {
	printf 'FAIL: %s\n' "$1"
	sudo tail -n 60 "$LOGF" 2>/dev/null
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
version_now() { "$ENGINE" --version 2>/dev/null | sed -n -e 's/^dpi-proxy //p' -e 's/^nivyx-engine //p'; }
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
	[ -z "$(ls -d /private/var/tmp/nivyx-update.* /private/var/tmp/nivyx-install-backup.* 2>/dev/null)" ] || die "$1: a work or backup folder was left behind"
	[ ! -e /var/run/nivyx-admin.lock ] && [ ! -L /var/run/nivyx-admin.lock ] || die "$1: the admin lock was left behind"
}

# serve a folder (asset, SHA256SUMS) as "the latest release" <tag>
serve_dir() { # dir tag
	a=""
	for f in "$1"/*; do
		f="${f##*/}"
		a="$a{\"name\":\"$f\",\"browser_download_url\":\"http://127.0.0.1:$port/${1#"$mock"/}/$f\"},"
	done
	printf '{"tag_name":"v%s","prerelease":false,"assets":[%s]}\n' "$2" "${a%,}" >"$mock/latest.json"
}
run_update() {
	rc=0
	out="$(sudo env NIVYX_RELEASE_API="http://127.0.0.1:$port/latest.json" /usr/local/bin/nivyx update 2>&1)" || rc=$?
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
new_version="$("$NEW/files/nivyx-engine" --version | sed -n 's/^nivyx-engine //p')"
old_version="$("$OLD/dpi-proxy" --version | sed -n 's/^dpi-proxy //p')"
[ -n "$new_version" ] && [ -n "$old_version" ] || die "cannot read the package versions"

# a release whose engine answers the updater's checks but cannot run the service
mkdir -p "$mock/broken-src"
ditto -x -k "$ZIP" "$mock/broken-src"
cat >"$mock/broken-src/nivyx-macos-$arch/files/nivyx-engine" <<'EOF'
#!/bin/sh
case "${1:-}" in
--version) echo "nivyx-engine 99.0.0" ;;
--capabilities) echo "transparent_mode: supported" ;;
*) exit 1 ;;
esac
EOF
chmod 755 "$mock/broken-src/nivyx-macos-$arch/files/nivyx-engine"
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

stepn "the $old_version updater (as released) refuses the candidate $new_version and changes nothing"
serve_dir "$mock/candidate-release" "$new_version"
before="$(sha "$ENGINE") $(sha /usr/local/bin/nivyx) $(daemon_pid)"
run_update
[ "$rc" != 0 ] || die "the $old_version updater reported success on the new layout"
echo "$out" | grep -q 'nothing was installed' || die "the $old_version updater did not say that nothing was installed"
[ "$before" = "$(sha "$ENGINE") $(sha /usr/local/bin/nivyx) $(daemon_pid)" ] || die "engine, CLI or service process changed"
assert_state "after the refused update"
pass "$old_version updater refused $new_version; nothing changed"

stepn "the candidate's installer moves $old_version over to the nivyx names"
( cd "$NEW" && sudo sh ./files/install.sh ) || die "candidate install over $old_version failed"
use_names nivyx /usr/local/bin/nivyx-engine
wait_running || die "candidate not running"
[ "$(version_now)" = "$new_version" ] || die "version after the move: $(version_now)"
launchctl print system/io.github.kadireren7.dpi-proxy >/dev/null 2>&1 && die "the old launchd job is still loaded"
for f in /Library/LaunchDaemons/io.github.kadireren7.dpi-proxy.plist /usr/local/bin/dpi-proxy \
	/usr/local/etc/dpi-proxy /usr/local/var/dpi-proxy /var/log/dpi-proxy.log; do
	[ -e "$f" ] && die "$f is still there"
done
assert_state "after the move"
/usr/local/bin/nivyx doctor >/dev/null || die "doctor failed after the move"
no_leftovers "move"
pass "$old_version -> $new_version; old names gone; rule, learned decision, HTTPS, doctor fine"

stepn "the candidate's updater rolls back a release that cannot start"
serve_dir "$mock/broken-release" 99.0.0
cli0="$(sha /usr/local/bin/nivyx)"
run_update
[ "$rc" != 0 ] || die "the broken release was accepted"
echo "$out" | grep -q 'previous installation is back and running' || die "no rollback reported"
[ "$(version_now)" = "$new_version" ] || die "version after the rollback: $(version_now)"
[ "$(sha /usr/local/bin/nivyx)" = "$cli0" ] || die "the CLI was not restored"
wait_running || die "not running after the rollback"
assert_state "after the rollback"
no_leftovers "rollback"
pass "broken 99.0.0 rolled back to $new_version, state intact"

stepn "uninstall"
( cd "$NEW" && sudo sh ./files/uninstall.sh --purge ) >/dev/null || die "uninstall --purge failed"
[ ! -e "$PLIST" ] || die "plist left behind"
printf '\nMACOS UPDATE TEST (%s, %s -> %s): ALL CHECKS PASSED\n' "$arch" "$old_version" "$new_version"
