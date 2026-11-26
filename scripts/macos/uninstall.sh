#!/bin/sh
#
# Nivyx for macOS — uninstaller.
#
#   sudo ./uninstall.sh           remove Nivyx, keep your settings,
#                                 learned decisions and logs
#   sudo ./uninstall.sh --purge   remove those too
#
# Stops the service and removes what install.sh put on the system: the
# launchd job, the binaries, man page, completion, Nivyx's PF anchor
# rules and its PF enable reference. Nothing else is touched: other PF
# anchors, the main ruleset, /etc/pf.conf and other programs' PF
# references stay as they are. (The same on every platform: a plain
# uninstall keeps your data, --purge removes everything.)
set -u

PURGE=0
for arg in "$@"; do
	case "$arg" in
	--purge) PURGE=1 ;;
	-h | --help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "uninstall.sh: unknown option: $arg (only --purge)" >&2; exit 1 ;;
	esac
done

LABEL="io.github.kadireren7.dpi-proxy"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
ANCHOR="com.apple/dpi-proxy"
VAR_DIR="/usr/local/var/dpi-proxy"
RUN_DIR="/var/run/dpi-proxy"

log() { printf '==> %s\n' "$1"; }

[ "$(uname -s)" = Darwin ] || { echo "uninstall.sh: this is for macOS" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "uninstall.sh: run it with sudo:  sudo ./uninstall.sh" >&2; exit 1; }

# One install/update/repair/uninstall at a time: install.sh, uninstall.sh
# and nivyx update/repair share this lock (macOS has no flock(1)): a
# directory holding the owner's pid. A lock whose owner is gone is taken
# over; one that was just created and has no pid yet is waited for.
ADMIN_LOCK=/var/run/nivyx-admin.lock
ADMIN_LOCK_HELD=0
take_admin_lock() {
	_tries=0
	while ! mkdir "$ADMIN_LOCK" 2>/dev/null; do
		_tries=$((_tries + 1))
		[ "$_tries" -le 25 ] || { echo "could not take $ADMIN_LOCK" >&2; exit 1; }
		_owner="$(cat "$ADMIN_LOCK/pid" 2>/dev/null || true)"
		if [ -z "$_owner" ] && [ "$_tries" -le 10 ]; then sleep 0.2; continue; fi
		if [ -n "$_owner" ] && kill -0 "$_owner" 2>/dev/null; then
			echo "another Nivyx install, update, repair or uninstall is running (pid $_owner); try again when it has finished" >&2
			exit 1
		fi
		# the owner is gone: move its lock aside (a rename: only one taker wins)
		mv "$ADMIN_LOCK" "$ADMIN_LOCK.stale.$$" 2>/dev/null && rm -rf "$ADMIN_LOCK.stale.$$"
	done
	echo $$ >"$ADMIN_LOCK/pid"
	ADMIN_LOCK_HELD=1
}
release_admin_lock() {
	[ "$ADMIN_LOCK_HELD" = 1 ] || return 0
	[ "$(cat "$ADMIN_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$ADMIN_LOCK"
	ADMIN_LOCK_HELD=0
}
take_admin_lock
trap release_admin_lock EXIT

log "Stopping the service..."
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	i=0
	while [ $i -lt 40 ] && launchctl print "system/$LABEL" >/dev/null 2>&1; do
		sleep 0.25
		i=$((i + 1))
	done
fi
launchctl disable "system/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
# anything of ours still running (e.g. a watchdog whose daemon was
# killed): it removes our rules on SIGTERM
for pid in $(pgrep -f '^/usr/local/bin/dpi-proxy' 2>/dev/null); do
	kill "$pid" 2>/dev/null || true
done
sleep 1
for pid in $(pgrep -f '^/usr/local/bin/dpi-proxy' 2>/dev/null); do
	kill -9 "$pid" 2>/dev/null || true
done

log "Removing Nivyx's PF rules (anchor $ANCHOR only)..."
pfctl -a "$ANCHOR" -F nat >/dev/null 2>&1 || true
pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1 || true
pfctl -a "$ANCHOR" -F Tables >/dev/null 2>&1 || true
# the PF enable reference of a daemon that could not release it itself
if [ -f "$RUN_DIR/pf.token" ]; then
	token="$(tr -cd '0-9' <"$RUN_DIR/pf.token")"
	[ -n "$token" ] && pfctl -X "$token" >/dev/null 2>&1 || true
fi

log "Removing files..."
rm -f /usr/local/bin/dpi-proxy /usr/local/bin/nivyx
rm -f /usr/local/share/man/man1/nivyx.1 /usr/local/share/zsh/site-functions/_nivyx
# legacy v2.1 command names, only if they are our own scripts
for legacy in /usr/local/bin/dpictl /usr/local/bin/dpi-proxy-ctl; do
	[ -f "$legacy" ] && [ ! -L "$legacy" ] && grep -q 'dpi-proxy' "$legacy" 2>/dev/null && rm -f "$legacy"
done
rm -rf "$RUN_DIR"
rm -rf "$VAR_DIR"/update-rollback.* "$VAR_DIR/rollback" 2>/dev/null || true
if [ "$PURGE" = 1 ]; then
	log "--purge: removing settings, learned decisions and logs..."
	created=""
	[ -f "$VAR_DIR/created-dirs" ] && created="$(sort -r -u "$VAR_DIR/created-dirs")"
	rm -rf /usr/local/etc/dpi-proxy "$VAR_DIR"
	rm -f /var/log/dpi-proxy.log /var/log/dpi-proxy.log.1 /var/log/dpi-proxy.stderr.log
	# parent directories install.sh had to create, if nothing else uses them
	for d in $created; do
		rmdir "$d" 2>/dev/null || true
	done
fi

# answers cached while the service ran came from the trusted resolvers;
# start fresh with the network's own
dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true

left=""
[ -e "$PLIST" ] && left="$left $PLIST"
[ -e /usr/local/bin/dpi-proxy ] && left="$left /usr/local/bin/dpi-proxy"
[ -e /usr/local/bin/nivyx ] && left="$left /usr/local/bin/nivyx"
if [ "$PURGE" = 1 ]; then
	[ -e /usr/local/etc/dpi-proxy ] && left="$left /usr/local/etc/dpi-proxy"
	[ -e "$VAR_DIR" ] && left="$left $VAR_DIR"
fi
launchctl print "system/$LABEL" >/dev/null 2>&1 && left="$left launchd-job"
pfctl -a "$ANCHOR" -s nat 2>/dev/null | grep -q . && left="$left pf-anchor"
pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q . && left="$left pf-anchor"
pgrep -f '^/usr/local/bin/dpi-proxy' >/dev/null 2>&1 && left="$left process"
if [ -n "$left" ]; then
	echo "uninstall.sh: could not remove:$left" >&2
	exit 1
fi
log "Nivyx is uninstalled; networking is back to normal."
if [ "$PURGE" != 1 ]; then
	for kept in /usr/local/etc/dpi-proxy "$VAR_DIR" /var/log/dpi-proxy.log; do
		[ -e "$kept" ] && echo "    kept $kept (remove with: sudo ./uninstall.sh --purge)"
	done
fi
echo "    (macOS keeps the now empty PF anchor name $ANCHOR registered until"
echo "    the next restart; it contains no rules and does nothing.)"
