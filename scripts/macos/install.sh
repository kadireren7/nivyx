#!/bin/sh
#
# Nivyx for macOS — transparent mode installer.
#
#   sudo ./install.sh
#
# Run it from the extracted package folder. Installs
#   /usr/local/bin/dpi-proxy, /usr/local/bin/nivyx
#   /Library/LaunchDaemons/io.github.kadireren7.dpi-proxy.plist
#   /usr/local/etc/dpi-proxy/strategy.conf  (kept if it exists)
# starts the service and checks DNS and HTTPS through it. Re-running it
# updates an existing installation. If anything fails after the first
# change to the system, the previous installation (files and launchd
# job) is put back and started again; a fresh install is removed again.
# Either way networking stays as it was, and the installer exits
# non-zero. Nothing else on the system is changed: PF rules live only in
# Nivyx's own anchor while the service runs.
#
# Exit codes: 0 installed; 1 cannot run here (not root, not macOS, wrong
# processor, files missing); 4 the service failed its health check (the
# previous state was restored); 5 the previous state could not be fully
# restored (a backup is kept and named).
set -eu

LABEL="io.github.kadireren7.dpi-proxy"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
BIN_DIR="/usr/local/bin"
ETC_DIR="/usr/local/etc/dpi-proxy"
VAR_DIR="/usr/local/var/dpi-proxy"
STATUS_FILE="/var/run/dpi-proxy/transparent.status"
LOG_FILE="/var/log/dpi-proxy.log"
HERE="$(cd "$(dirname "$0")" && pwd)"
# everything an install may replace (put back if it fails)
MANAGED="$BIN_DIR/dpi-proxy $BIN_DIR/nivyx $PLIST
/usr/local/share/man/man1/nivyx.1 /usr/local/share/zsh/site-functions/_nivyx
$BIN_DIR/dpictl $BIN_DIR/dpi-proxy-ctl $ETC_DIR/strategy.conf"

log() { printf '==> %s\n' "$1"; }
fail() { printf 'install.sh: ERROR: %s\n' "$1" >&2; }
die() { fail "$1"; exit 1; }

[ "$(uname -s)" = Darwin ] || die "this installer is for macOS"
[ "$(id -u)" -eq 0 ] || die "run it with sudo:  sudo ./install.sh"
for f in dpi-proxy nivyx "$LABEL.plist"; do
	[ -f "$HERE/$f" ] || die "$f is missing next to install.sh (extract the whole package)"
done

PHASE=preflight
DONE=0
STAGE="$(mktemp -d /private/var/tmp/nivyx-install.XXXXXX)"
BACKUP=""
WAS_LOADED=0

restore_previous() {
	ok=0
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	i=0
	while [ $i -lt 40 ] && launchctl print "system/$LABEL" >/dev/null 2>&1; do
		sleep 0.25
		i=$((i + 1))
	done
	for p in $MANAGED; do
		if [ -e "$BACKUP/files$p" ]; then
			cp -p "$BACKUP/files$p" "$p.restore" && mv -f "$p.restore" "$p" || ok=1
		elif grep -qxF "$p" "$BACKUP/absent"; then
			rm -f "$p" || ok=1
		fi
	done
	if [ "$WAS_LOADED" = 1 ]; then
		launchctl bootstrap system "$PLIST" 2>/dev/null || ok=1
		launchctl print "system/$LABEL" >/dev/null 2>&1 || ok=1
	fi
	return $ok
}

on_exit() {
	rc=$?
	rm -rf "$STAGE"
	[ "$DONE" = 1 ] && return 0
	if [ "$PHASE" = preflight ]; then
		[ -n "$BACKUP" ] && rm -rf "$BACKUP"
		fail "stopped before changing anything; an existing Nivyx installation is untouched"
		return 0
	fi
	if [ "$WAS_LOADED" = 1 ]; then
		fail "restoring the previous installation (fail-open: networking is unchanged)"
	else
		fail "stopping and removing the service again (fail-open: networking is unchanged)"
	fi
	if restore_previous; then
		rm -rf "$BACKUP"
		[ "$WAS_LOADED" = 1 ] && fail "the previous installation is back and running"
		fail "please send the output above; remove the rest with: sudo ./uninstall.sh"
	else
		fail "could not fully restore the previous state; nothing was deleted:"
		fail "  backup kept in $BACKUP (files/ = the replaced files)"
		exit 5
	fi
	exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

log "[1/5] Checking the package..."
# Work on copies: `cat` writes plain files, without the download's
# quarantine attribute, so only the two programs that get installed lose
# it - the extracted folder itself is left as it is.
cat "$HERE/dpi-proxy" >"$STAGE/dpi-proxy"
cat "$HERE/nivyx" >"$STAGE/nivyx"
chmod 755 "$STAGE/dpi-proxy" "$STAGE/nivyx"
if ! "$STAGE/dpi-proxy" --version >/dev/null 2>&1; then
	die "Nivyx does not run on this Mac ($(uname -m), macOS $(sw_vers -productVersion)); is this the package for this Mac's processor?"
fi
"$STAGE/dpi-proxy" --capabilities | grep -q '^transparent_mode: supported' \
	|| die "this Nivyx engine was built without transparent mode"
echo "    $("$STAGE/dpi-proxy" --version), macOS $(sw_vers -productVersion), $(uname -m)"
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
PHASE=commit
if [ "$WAS_LOADED" = 1 ]; then
	launchctl bootout "system/$LABEL" 2>/dev/null || true
	i=0
	while [ $i -lt 40 ] && launchctl print "system/$LABEL" >/dev/null 2>&1; do
		sleep 0.25
		i=$((i + 1))
	done
fi

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
install -m 755 -o root -g wheel "$STAGE/dpi-proxy" "$BIN_DIR/dpi-proxy"
install -m 755 -o root -g wheel "$STAGE/nivyx" "$BIN_DIR/nivyx"
# man page and zsh completion (best effort)
if [ -f "$HERE/nivyx.1" ]; then
	install -d /usr/local/share/man/man1
	install -m 644 "$HERE/nivyx.1" /usr/local/share/man/man1/nivyx.1
fi
if [ -f "$HERE/_nivyx" ]; then
	install -d /usr/local/share/zsh/site-functions
	install -m 644 "$HERE/_nivyx" /usr/local/share/zsh/site-functions/_nivyx
fi
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
# dpi-proxy manual rules. Transparent mode needs none: known-blocked
# hosts (Discord and a few others, built in) get the bypass straight
# away; any other host is tried directly first and learns a bypass only
# if it needs one. Stream strategies: pass | tlsrec | tlsrec-split
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
echo "    $BIN_DIR/dpi-proxy, $BIN_DIR/nivyx, $PLIST, $ETC_DIR/"

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
		&& [ "$(field pf_anchor)" = "com.apple/dpi-proxy loaded" ]; then
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
	[ -s /var/log/dpi-proxy.stderr.log ] && tail -n 10 /var/log/dpi-proxy.stderr.log >&2
	exit 4
fi

DONE=1
rm -rf "$BACKUP"
echo
log "Done. Nivyx is running and starts automatically at boot."
echo "    HTTPS and DNS from all applications now go through the automatic"
echo "    bypass; no proxy settings, no DNS changes, no per-app setup."
echo
echo "    Status:     nivyx status"
echo "    Doctor:     nivyx doctor"
echo "    Problems:   nivyx diagnose discord.com   and   nivyx logs"
echo "    Stop:       sudo nivyx stop     (networking keeps working, unbypassed)"
echo "    Uninstall:  sudo ./uninstall.sh         (in this folder)"
c="$(field conflict)"
if [ -n "$c" ] && [ "$c" != none ]; then
	echo
	echo "    WARNING: $c — stop it, the two tools interfere."
fi
