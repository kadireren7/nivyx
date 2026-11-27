#!/bin/sh
#
# Nivyx for macOS — transparent mode installer.
#
#   sudo ./files/install.sh     (normally started by "Install Nivyx.command")
#
# Run it from the extracted package. Installs
#   /usr/local/bin/nivyx-engine, /usr/local/bin/nivyx
#   /Library/LaunchDaemons/io.github.kadireren7.nivyx.plist
#   /usr/local/etc/nivyx/strategy.conf  (kept if it exists)
# starts the service and checks DNS and HTTPS through it. Re-running it
# updates an existing installation. An installation of v2.4.0 or earlier
# ("dpi-proxy" names) is moved over, keeping its settings and learned
# state. If anything fails after the first change to the system, the
# previous installation (files and launchd job) is put back and started
# again; a fresh install is removed again.
# Either way networking stays as it was, and the installer exits
# non-zero. Nothing else on the system is changed: PF rules live only in
# Nivyx's own anchor while the service runs.
#
# Exit codes: 0 installed; 1 cannot run here (not root, not macOS, wrong
# processor, files missing); 4 the service failed its health check (the
# previous state was restored); 5 the previous state could not be fully
# restored (a backup is kept and named).
set -eu

LABEL="io.github.kadireren7.nivyx"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
BIN_DIR="/usr/local/bin"
ETC_DIR="/usr/local/etc/nivyx"
VAR_DIR="/usr/local/var/nivyx"
STATUS_FILE="/var/run/nivyx/transparent.status"
LOG_FILE="/var/log/nivyx.log"
# v2.4.0 and earlier
OLD_LABEL="io.github.kadireren7.dpi-proxy"
OLD_PLIST="/Library/LaunchDaemons/$OLD_LABEL.plist"
OLD_ETC="/usr/local/etc/dpi-proxy"
OLD_VAR="/usr/local/var/dpi-proxy"
HERE="$(cd "$(dirname "$0")" && pwd)"
# the nivyx command is at the top of the package, the rest in files/
CLI="$HERE/../nivyx"
[ -f "$CLI" ] || CLI="$HERE/nivyx"
# everything an install may replace or remove (put back if it fails)
MANAGED="$BIN_DIR/nivyx-engine $BIN_DIR/nivyx $PLIST $ETC_DIR/strategy.conf
$BIN_DIR/dpi-proxy $OLD_PLIST $BIN_DIR/dpictl $BIN_DIR/dpi-proxy-ctl"

log() { printf '==> %s\n' "$1"; }
fail() { printf 'install.sh: ERROR: %s\n' "$1" >&2; }
die() { fail "$1"; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this installer is for macOS"
[ "$(id -u)" -eq 0 ] || die "run it with sudo:  sudo ./files/install.sh"
for f in nivyx-engine "$LABEL.plist"; do
	[ -f "$HERE/$f" ] || die "$f is missing next to install.sh (extract the whole package)"
done
[ -f "$CLI" ] || die "the nivyx command is missing (extract the whole package)"

# One install/update/repair/uninstall at a time (nivyx update runs this
# installer while holding the lock and says so with NIVYX_FROM_UPDATE=1): install.sh, uninstall.sh
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
[ "${NIVYX_FROM_UPDATE:-}" = 1 ] || take_admin_lock || exit 1

PHASE=preflight
DONE=0
STAGE="$(mktemp -d /private/var/tmp/nivyx-install.XXXXXX)"
BACKUP=""
WAS_LOADED=0
OLD_WAS_LOADED=0
NEW_DIRS=""

wait_gone() {
	i=0
	while [ $i -lt 40 ] && launchctl print "system/$1" >/dev/null 2>&1; do
		sleep 0.25
		i=$((i + 1))
	done
}

restore_previous() {
	ok=0
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	wait_gone "$LABEL"
	for p in $MANAGED; do
		if [ -e "$BACKUP/files$p" ]; then
			cp -p "$BACKUP/files$p" "$p.restore" && mv -f "$p.restore" "$p" || ok=1
		elif grep -qxF "$p" "$BACKUP/absent"; then
			rm -f "$p" || ok=1
		fi
	done
	# folders this install created (an old installation's are untouched)
	for d in $NEW_DIRS; do rm -rf "$d"; done
	if [ "$WAS_LOADED" = 1 ]; then
		launchctl bootstrap system "$PLIST" 2>/dev/null || ok=1
		launchctl print "system/$LABEL" >/dev/null 2>&1 || ok=1
	elif [ "$OLD_WAS_LOADED" = 1 ]; then
		launchctl bootstrap system "$OLD_PLIST" 2>/dev/null || ok=1
		launchctl print "system/$OLD_LABEL" >/dev/null 2>&1 || ok=1
	fi
	return $ok
}

on_exit() {
	rc=$?
	rm -rf "$STAGE"
	[ "$DONE" = 1 ] && { release_admin_lock; return 0; }
	if [ "$PHASE" = preflight ]; then
		[ -n "$BACKUP" ] && rm -rf "$BACKUP"
		fail "stopped before changing anything; an existing Nivyx installation is untouched"
		release_admin_lock
		return 0
	fi
	if [ "$WAS_LOADED" = 1 ] || [ "$OLD_WAS_LOADED" = 1 ]; then
		fail "restoring the previous installation (fail-open: networking is unchanged)"
	else
		fail "stopping and removing the service again (fail-open: networking is unchanged)"
	fi
	if restore_previous; then
		rm -rf "$BACKUP"
		{ [ "$WAS_LOADED" = 1 ] || [ "$OLD_WAS_LOADED" = 1 ]; } && fail "the previous installation is back and running"
		fail "please send the output above; remove the rest with \"Uninstall Nivyx.command\""
	else
		fail "could not fully restore the previous state; nothing was deleted:"
		fail "  backup kept in $BACKUP (files/ = the replaced files)"
		release_admin_lock
		exit 5
	fi
	release_admin_lock
	exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

log "[1/5] Checking the package..."
# Work on copies: `cat` writes plain files, without the download's
# quarantine attribute, so only the two programs that get installed lose
# it - the extracted folder itself is left as it is.
cat "$HERE/nivyx-engine" >"$STAGE/nivyx-engine"
cat "$CLI" >"$STAGE/nivyx"
chmod 755 "$STAGE/nivyx-engine" "$STAGE/nivyx"
if ! "$STAGE/nivyx-engine" --version >/dev/null 2>&1; then
	die "Nivyx does not run on this Mac ($(uname -m), macOS $(sw_vers -productVersion)); is this the package for this Mac's processor?"
fi
"$STAGE/nivyx-engine" --capabilities | grep -q '^transparent_mode: supported' \
	|| die "this Nivyx engine was built without transparent mode"
echo "    $("$STAGE/nivyx-engine" --version), macOS $(sw_vers -productVersion), $(uname -m)"
for p in tpws spoofdpi ciadpi byedpi; do
	if pgrep -x "$p" >/dev/null 2>&1; then
		echo "    WARNING: $p is running (another DPI tool). Stop it: the two interfere."
	fi
done

log "[2/5] Backing up and stopping a previous installation (if any)..."
BACKUP="$(mktemp -d /private/var/tmp/nivyx-install-backup.XXXXXX)"
: >"$BACKUP/absent"
for p in $MANAGED; do
	if [ -e "$p" ]; then
		mkdir -p "$BACKUP/files$(dirname "$p")"
		cp -p "$p" "$BACKUP/files$p"
	else
		printf '%s\n' "$p" >>"$BACKUP/absent"
	fi
done
launchctl print "system/$LABEL" >/dev/null 2>&1 && WAS_LOADED=1
launchctl print "system/$OLD_LABEL" >/dev/null 2>&1 && OLD_WAS_LOADED=1
[ -d "$ETC_DIR" ] || NEW_DIRS="$NEW_DIRS $ETC_DIR"
[ -d "$VAR_DIR" ] || NEW_DIRS="$NEW_DIRS $VAR_DIR"
PHASE=commit
for l in "$LABEL" "$OLD_LABEL"; do
	if launchctl print "system/$l" >/dev/null 2>&1; then
		[ "$l" = "$OLD_LABEL" ] && echo "    moving over the older installation (dpi-proxy)"
		launchctl bootout "system/$l" 2>/dev/null || true
		wait_gone "$l"
	fi
done

log "[3/5] Installing files..."
# remember which parent directories we create, so uninstall.sh removes
# exactly those (and only if they are empty then)
created=""
for d in /usr/local /usr/local/bin /usr/local/etc /usr/local/var; do
	if [ ! -d "$d" ]; then
		mkdir -p "$d"
		chmod 755 "$d"
		created="$created $d"
	fi
done
mkdir -p "$ETC_DIR" "$VAR_DIR"
chmod 755 "$ETC_DIR" "$VAR_DIR"
if [ -n "$created" ]; then
	for d in $created; do echo "$d"; done >>"$VAR_DIR/created-dirs"
fi
# settings and learned state of an older installation (never overwriting)
for d in "$OLD_ETC:$ETC_DIR" "$OLD_VAR:$VAR_DIR"; do
	from="${d%%:*}"; to="${d#*:}"
	[ -d "$from" ] || continue
	for f in "$from"/*; do
		[ -f "$f" ] || continue
		b="$(basename "$f")"
		if [ "$b" = created-dirs ]; then
			cat "$f" >>"$to/created-dirs"
		elif [ ! -e "$to/$b" ]; then
			cp -p "$f" "$to/$b"
		fi
	done
done
install -m 755 -o root -g wheel "$STAGE/nivyx-engine" "$BIN_DIR/nivyx-engine"
install -m 755 -o root -g wheel "$STAGE/nivyx" "$BIN_DIR/nivyx"
# Upgrade from v2.1 or earlier: drop our own old command names, never an
# unrelated tool that shares the name.
for legacy in "$BIN_DIR/dpictl" "$BIN_DIR/dpi-proxy-ctl"; do
	[ -f "$legacy" ] && [ ! -L "$legacy" ] || continue
	if [ "$(wc -c <"$legacy")" -lt 200000 ] && grep -q 'dpi-proxy' "$legacy" 2>/dev/null; then
		rm -f "$legacy"
		log "removed legacy command $legacy (use: nivyx)"
	fi
done
if [ ! -f "$ETC_DIR/strategy.conf" ]; then
	cat >"$ETC_DIR/strategy.conf" <<'CONF'
# Nivyx manual rules. None are needed: known-blocked hosts get the
# bypass straight away; any other host is tried directly first and
# learns a bypass only if it needs one.
# Stream strategies: pass | tlsrec | tlsrec-split
# After editing: sudo nivyx reload
#
# [domains]
# example.com = tlsrec
default = pass
CONF
	chmod 644 "$ETC_DIR/strategy.conf"
fi
install -m 644 -o root -g wheel "$HERE/$LABEL.plist" "$PLIST"
plutil -lint "$PLIST" >/dev/null || { fail "$PLIST is not a valid property list"; exit 4; }
echo "    $BIN_DIR/nivyx-engine, $BIN_DIR/nivyx, $PLIST, $ETC_DIR/"

log "[4/5] Starting the service..."
rm -f "$STATUS_FILE"
launchctl enable "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST" || { fail "launchctl bootstrap failed"; exit 4; }

log "[5/5] Checking health (DNS and HTTPS through the service)..."
field() { sed -n "s/^$1: //p" "$STATUS_FILE" 2>/dev/null | head -n 1; }
job_pid() { launchctl print "system/$LABEL" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1; }
healthy=0
problem="the service did not report \"engine: running\" within 20 s"
i=0
while [ $i -lt 40 ]; do
	# the status file must come from the process launchd just started
	pid="$(job_pid)"
	if [ -n "$pid" ] && [ "$(field pid)" = "$pid" ] && [ "$(field engine)" = running ] \
		&& [ "$(field pf_anchor)" = "com.apple/nivyx loaded" ]; then
		healthy=1
		break
	fi
	sleep 0.5
	i=$((i + 1))
done
if [ $healthy -eq 1 ]; then
	dscacheutil -flushcache 2>/dev/null || true
	killall -HUP mDNSResponder 2>/dev/null || true
	sleep 1
	if ! dscacheutil -q host -a name example.com | grep -q '^ip_address:'; then
		healthy=0
		problem="name resolution (example.com) through the service failed"
	elif ! code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://example.com/ 2>&1)" \
		|| ! echo "$code" | grep -Eq '^[23][0-9][0-9]$'; then
		healthy=0
		problem="HTTPS check (https://example.com/) through the service failed: $code"
	elif [ "$(job_pid)" != "$pid" ]; then
		# fail-open would let the checks pass without the engine
		healthy=0
		problem="the engine stopped during the DNS/HTTPS check"
	fi
fi
if [ $healthy -ne 1 ]; then
	fail "$problem"
	echo '--- last log lines ---' >&2
	tail -n 25 "$LOG_FILE" 2>/dev/null >&2 || true
	[ -s /var/log/nivyx.stderr.log ] && tail -n 10 /var/log/nivyx.stderr.log >&2
	exit 4
fi

# the older installation, now that this one works (backed up until here)
rm -f "$OLD_PLIST" "$BIN_DIR/dpi-proxy"
launchctl disable "system/$OLD_LABEL" 2>/dev/null || true
DONE=1
rm -rf "$BACKUP"
if [ -d "$OLD_ETC" ] || [ -d "$OLD_VAR" ] || [ -d /var/run/dpi-proxy ]; then
	rm -rf "$OLD_ETC" "$OLD_VAR" /var/run/dpi-proxy
	rm -f /var/log/dpi-proxy.log /var/log/dpi-proxy.log.1 /var/log/dpi-proxy.stderr.log
	# a man page and zsh completion of an earlier version
	rm -f /usr/local/share/man/man1/nivyx.1 /usr/local/share/zsh/site-functions/_nivyx
	echo "    removed the older installation (settings and learned state were kept)"
fi
echo
log "Done. Nivyx is running and starts automatically at boot."
echo "    HTTPS and DNS from all applications now go through the automatic"
echo "    bypass; no proxy settings, no DNS changes, no per-app setup."
echo
echo "    Status:     nivyx status"
echo "    Problems:   nivyx doctor"
echo "    Update:     sudo nivyx update"
echo "    Uninstall:  double-click \"Uninstall Nivyx.command\""
c="$(field conflict)"
if [ -n "$c" ] && [ "$c" != none ]; then
	echo
	echo "    WARNING: $c — stop it, the two tools interfere."
fi
