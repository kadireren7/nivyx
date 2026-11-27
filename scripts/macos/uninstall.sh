#!/bin/sh
#
# Nivyx for macOS — uninstaller.
#
#   sudo ./files/uninstall.sh           remove Nivyx, keep your settings,
#                                       learned decisions and logs
#   sudo ./files/uninstall.sh --purge   remove those too
#
# Stops the service and removes what install.sh put on the system: the
# launchd job, the programs, Nivyx's PF anchor rules and its PF enable
# reference. Leftovers of v2.4.0 and earlier ("dpi-proxy" names) are
# removed too. Nothing else is touched: other PF anchors, the main
# ruleset, /etc/pf.conf and other programs' PF references stay as they are.
set -u

PURGE=0
for arg in "$@"; do
	case "$arg" in
	--purge) PURGE=1 ;;
	-h | --help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "uninstall.sh: unknown option: $arg (only --purge)" >&2; exit 1 ;;
	esac
done

# current names, then the names of v2.4.0 and earlier
NAMES="nivyx dpi-proxy"
ENGINES="/usr/local/bin/nivyx-engine /usr/local/bin/dpi-proxy"

log() { printf '==> %s\n' "$1"; }

[ "$(uname -s)" = Darwin ] || { echo "uninstall.sh: this is for macOS" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "uninstall.sh: run it with sudo:  sudo ./files/uninstall.sh" >&2; exit 1; }

# One install/update/repair/uninstall at a time: install.sh, uninstall.sh
# and nivyx update/repair share this lock (macOS has no flock(1)). The lock
# is a symlink whose target is the owner's pid, created atomically by
# `ln -s` (it never exists without its owner). A lock whose owner is gone is
# removed only under a takeover guard and only after re-checking it still
# names that dead owner, so two processes can never both hold it.
ADMIN_LOCK=/var/run/nivyx-admin.lock
ADMIN_LOCK_HELD=0
take_admin_lock() {
	_guard="$ADMIN_LOCK.takeover"
	_tries=0
	while :; do
		if [ ! -d "$ADMIN_LOCK" ] && ln -s "$$" "$ADMIN_LOCK" 2>/dev/null; then
			ADMIN_LOCK_HELD=1
			return 0
		fi
		_tries=$((_tries + 1))
		[ "$_tries" -le 50 ] || { echo "could not take $ADMIN_LOCK" >&2; exit 1; }
		_owner="$(readlink "$ADMIN_LOCK" 2>/dev/null || true)"
		if [ -n "$_owner" ] && kill -0 "$_owner" 2>/dev/null; then
			echo "another Nivyx install, update, repair or uninstall is running (pid $_owner); try again when it has finished" >&2
			exit 1
		fi
		# owner gone (or the lock vanished meanwhile): one taker at a time
		if mkdir "$_guard" 2>/dev/null; then
			_now="$(readlink "$ADMIN_LOCK" 2>/dev/null || true)"
			if [ -d "$ADMIN_LOCK" ] && [ ! -L "$ADMIN_LOCK" ]; then
				rm -rf "$ADMIN_LOCK"	# lock directory of a pre-release build
			elif [ -n "$_now" ] && [ "$_now" = "$_owner" ] && ! kill -0 "$_now" 2>/dev/null; then
				rm -f "$ADMIN_LOCK"
			fi
			rmdir "$_guard" 2>/dev/null || true
		elif [ -n "$(find "$_guard" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
			rmdir "$_guard" 2>/dev/null || true	# left by a taker that died mid-takeover
		else
			sleep 0.1
		fi
	done
}
release_admin_lock() {
	[ "$ADMIN_LOCK_HELD" = 1 ] || return 0
	[ "$(readlink "$ADMIN_LOCK" 2>/dev/null)" = "$$" ] && rm -f "$ADMIN_LOCK"
	ADMIN_LOCK_HELD=0
}
take_admin_lock
trap release_admin_lock EXIT

engine_pids() {
	for e in $ENGINES; do pgrep -f "^$e" 2>/dev/null; done
}

log "Stopping the service..."
for n in $NAMES; do
	label="io.github.kadireren7.$n"
	if launchctl print "system/$label" >/dev/null 2>&1; then
		launchctl bootout "system/$label" 2>/dev/null || true
		i=0
		while [ $i -lt 40 ] && launchctl print "system/$label" >/dev/null 2>&1; do
			sleep 0.25
			i=$((i + 1))
		done
	fi
	launchctl disable "system/$label" 2>/dev/null || true
	rm -f "/Library/LaunchDaemons/$label.plist"
done
# anything of ours still running (e.g. a watchdog whose daemon was
# killed): it removes our rules on SIGTERM
for pid in $(engine_pids); do kill "$pid" 2>/dev/null || true; done
sleep 1
for pid in $(engine_pids); do kill -9 "$pid" 2>/dev/null || true; done

log "Removing Nivyx's PF rules (its own anchor only)..."
for n in $NAMES; do
	anchor="com.apple/$n"
	pfctl -a "$anchor" -F nat >/dev/null 2>&1 || true
	pfctl -a "$anchor" -F rules >/dev/null 2>&1 || true
	pfctl -a "$anchor" -F Tables >/dev/null 2>&1 || true
	# the PF enable reference of a daemon that could not release it itself
	if [ -f "/var/run/$n/pf.token" ]; then
		token="$(tr -cd '0-9' <"/var/run/$n/pf.token")"
		[ -n "$token" ] && pfctl -X "$token" >/dev/null 2>&1 || true
	fi
done

log "Removing files..."
rm -f $ENGINES /usr/local/bin/nivyx
# earlier versions also installed a man page and zsh completion
rm -f /usr/local/share/man/man1/nivyx.1 /usr/local/share/zsh/site-functions/_nivyx
# legacy v2.1 command names, only if they are our own scripts
for legacy in /usr/local/bin/dpictl /usr/local/bin/dpi-proxy-ctl; do
	[ -f "$legacy" ] && [ ! -L "$legacy" ] && grep -q 'dpi-proxy' "$legacy" 2>/dev/null && rm -f "$legacy"
done
for n in $NAMES; do
	rm -rf "/var/run/$n"
	rm -rf "/usr/local/var/$n"/update-rollback.* "/usr/local/var/$n/rollback" 2>/dev/null || true
done
if [ "$PURGE" = 1 ]; then
	log "--purge: removing settings, learned decisions and logs..."
	created="$(cat /usr/local/var/nivyx/created-dirs /usr/local/var/dpi-proxy/created-dirs 2>/dev/null | sort -r -u)"
	for n in $NAMES; do
		rm -rf "/usr/local/etc/$n" "/usr/local/var/$n"
		rm -f "/var/log/$n.log" "/var/log/$n.log.1" "/var/log/$n.stderr.log"
	done
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
for n in $NAMES; do
	[ -e "/Library/LaunchDaemons/io.github.kadireren7.$n.plist" ] && left="$left io.github.kadireren7.$n.plist"
	launchctl print "system/io.github.kadireren7.$n" >/dev/null 2>&1 && left="$left launchd-job"
	pfctl -a "com.apple/$n" -s nat 2>/dev/null | grep -q . && left="$left pf-anchor"
	pfctl -a "com.apple/$n" -s rules 2>/dev/null | grep -q . && left="$left pf-anchor"
	if [ "$PURGE" = 1 ]; then
		[ -e "/usr/local/etc/$n" ] && left="$left /usr/local/etc/$n"
		[ -e "/usr/local/var/$n" ] && left="$left /usr/local/var/$n"
	fi
done
for f in $ENGINES /usr/local/bin/nivyx; do [ -e "$f" ] && left="$left $f"; done
[ -n "$(engine_pids)" ] && left="$left process"
if [ -n "$left" ]; then
	echo "uninstall.sh: could not remove:$left" >&2
	exit 1
fi
log "Nivyx is uninstalled; networking is back to normal."
if [ "$PURGE" != 1 ]; then
	for kept in /usr/local/etc/nivyx /usr/local/var/nivyx /var/log/nivyx.log; do
		[ -e "$kept" ] && echo "    kept $kept (remove with: sudo ./files/uninstall.sh --purge)"
	done
fi
exit 0
