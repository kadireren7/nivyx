#!/usr/bin/env bash
#
# Installs Nivyx on Linux: transparent mode as a system service —
# after this, HTTPS from every application goes through the automatic
# DPI bypass with no proxy settings anywhere. Needs root (sudo).
#
#   sudo ./scripts/install.sh            install or upgrade (idempotent)
#   sudo ./scripts/install.sh --packet   also install packet mode
#                                        (dpi-proxy-packet; needs
#                                        libnetfilter-queue-dev), not
#                                        started automatically
#
# On Debian/Ubuntu, missing build and runtime dependencies (compiler,
# make, nftables, OpenSSL + headers, pkg-config, curl) are installed
# with apt-get automatically. On other systemd + nftables distributions
# (Arch, Fedora, openSUSE, ...) the installer works as long as the
# dependencies are present; if something is missing it lists it and stops.
#
# Everything installed is owned by Nivyx; scripts/uninstall.sh removes
# exactly that and nothing else. An install from before v2.3 (service
# dpi-proxy-transparent, /etc/dpi-proxy, ...) is moved to the current
# names automatically, keeping its settings and learned state.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

TP_SERVICE="nivyx"
PACKET_SERVICE="nivyx-packet"
TP_TABLE="dpi_proxy_tp"
BIN_DEST="/usr/local/bin/nivyx-engine"
PACKET_BIN_DEST="/usr/local/bin/nivyx-packet-engine"
NIVYX_DEST="/usr/local/bin/nivyx"
UNIT_DIR="/etc/systemd/system"
CONF_DIR="/etc/nivyx"
CONF_DEST="$CONF_DIR/strategy.conf"
STATUS_FILE="/run/nivyx/transparent.status"
# names used by installs made before v2.3 (moved to the ones above)
OLD_TP_SERVICE="dpi-proxy-transparent"
OLD_PACKET_SERVICE="dpi-proxy-packet"

WITH_PACKET=0
for arg in "$@"; do
	case "$arg" in
	--packet) WITH_PACKET=1 ;;
	-h | --help)
		sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		printf '[install] unknown option: %s\n' "$arg" >&2
		exit 1
		;;
	esac
done

log() { printf '[install] %s\n' "$1"; }
err() { printf '[install] ERROR: %s\n' "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
	err "this installer sets up a system-wide service and needs root."
	err "run: sudo $0"
	exit 1
fi

# Two phases. PREFLIGHT (dependencies, build, checking the built engine)
# changes nothing on the system: if it fails, an existing installation is
# left exactly as it was, running. COMMIT starts by backing up everything
# the install may replace (binaries, units, man page, completions,
# /etc/nivyx, /var/lib/nivyx) and the state of every Nivyx service. If
# anything fails from then on, the backup is put back and the services
# that were running before are started again; an install from before
# v2.3 keeps its old names, files and service until the new one has
# passed its health check.
PHASE=preflight
INSTALL_OK=0
BACKUP=""
MANAGED_FILES="$BIN_DEST $PACKET_BIN_DEST $NIVYX_DEST
/usr/local/share/man/man1/nivyx.1
/usr/share/bash-completion/completions/nivyx
/usr/local/share/zsh/site-functions/_nivyx
/usr/share/fish/vendor_completions.d/nivyx.fish
$UNIT_DIR/$TP_SERVICE.service $UNIT_DIR/$PACKET_SERVICE.service
/usr/local/bin/dpictl /usr/local/bin/dpi-proxy-ctl"
MANAGED_DIRS="/etc/nivyx /var/lib/nivyx"
ALL_SERVICES="$TP_SERVICE $PACKET_SERVICE $OLD_TP_SERVICE $OLD_PACKET_SERVICE"

backup_state() {
	local p s
	BACKUP="$(mktemp -d /var/tmp/nivyx-install-backup.XXXXXX)"
	: >"$BACKUP/absent"
	for p in $MANAGED_FILES $MANAGED_DIRS; do
		if [ -e "$p" ] || [ -L "$p" ]; then
			mkdir -p "$BACKUP/files$(dirname "$p")"
			cp -a "$p" "$BACKUP/files$p"
		else
			printf '%s\n' "$p" >>"$BACKUP/absent"
		fi
	done
	for s in $ALL_SERVICES; do
		printf '%s %s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || true)" \
			"$(systemctl is-enabled "$s" 2>/dev/null || true)" >>"$BACKUP/services"
	done
}

# Puts back what backup_state saved; returns non-zero if a service that
# ran before is not running again (the backup is then kept).
restore_state() {
	local p s active enabled ok=0
	systemctl stop "$TP_SERVICE" "$PACKET_SERVICE" >/dev/null 2>&1 || true
	nft delete table inet "$TP_TABLE" >/dev/null 2>&1 || true
	# un-enable what was not enabled before while its unit file still exists
	while read -r s active enabled; do
		[ "$enabled" = enabled ] || systemctl disable "$s" >/dev/null 2>&1 || true
	done <"$BACKUP/services"
	for p in $MANAGED_FILES $MANAGED_DIRS; do
		if [ -e "$BACKUP/files$p" ] || [ -L "$BACKUP/files$p" ]; then
			rm -rf "$p" && cp -a "$BACKUP/files$p" "$p" || ok=1
		elif grep -qxF "$p" "$BACKUP/absent"; then
			rm -rf "$p" || ok=1
		fi
	done
	systemctl daemon-reload || ok=1
	while read -r s active enabled; do
		[ "$enabled" = enabled ] && { systemctl enable "$s" >/dev/null 2>&1 || ok=1; }
	done <"$BACKUP/services"
	while read -r s active enabled; do
		[ "$active" = active ] || continue
		systemctl reset-failed "$s" >/dev/null 2>&1 || true
		systemctl start "$s" >/dev/null 2>&1 && systemctl is-active --quiet "$s" || ok=1
	done <"$BACKUP/services"
	return $ok
}

on_exit() {
	[ "$INSTALL_OK" = 1 ] && return 0
	if [ "$PHASE" = preflight ]; then
		[ -n "$BACKUP" ] && rm -rf "$BACKUP"
		err "stopped before changing anything; an existing Nivyx installation is untouched"
		return 0
	fi
	err "install failed — restoring the previous state"
	if restore_state; then
		rm -rf "$BACKUP"
		err "previous state restored (services that were running are running again)"
	else
		err "could not fully restore the previous state; nothing was deleted:"
		err "  backup kept in $BACKUP (files/ = the replaced files, services = their state)"
		err "  your internet works (fail-open); check: systemctl status $TP_SERVICE $OLD_TP_SERVICE"
	fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

# Build as the invoking (non-root) user, so build artifacts in the repo
# stay owned by them.
BUILD_USER="${SUDO_USER:-root}"
run_as_build_user() {
	if [ "$BUILD_USER" != "root" ]; then
		sudo -u "$BUILD_USER" -- "$@"
	else
		"$@"
	fi
}

# one install/update/repair/uninstall at a time (same lock as nivyx)
if command -v flock >/dev/null 2>&1; then
	exec 9>/run/nivyx-admin.lock
	flock -n 9 || { err "another Nivyx install, update, repair or uninstall is running; try again when it has finished"; exit 1; }
fi

log "[1/7] Checking dependencies..."

# Debian family (Debian, Ubuntu, Mint, ...): apt-get is only ever used here.
is_debian_family() {
	[ -r /etc/os-release ] || return 1
	local id id_like
	id="$(. /etc/os-release && printf '%s' "${ID:-}")"
	id_like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
	case " $id $id_like " in
	*" debian "* | *" ubuntu "*) command -v apt-get >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

have() { command -v "$1" >/dev/null 2>&1; }
have_openssl_headers() {
	[ -f /usr/include/openssl/ssl.h ] || [ -f "/usr/include/$(uname -m)-linux-gnu/openssl/ssl.h" ] \
		|| pkg-config --exists openssl 2>/dev/null
}

# Fills $need_pkgs (apt package names) and $need_desc (what is missing)
# with only what is actually absent.
need_pkgs=""
need_desc=""
want() { # package description
	case " $need_pkgs " in *" $1 "*) ;; *) need_pkgs="$need_pkgs $1" ;; esac
	need_desc="$need_desc $2"
}
{ have cc && have make; } || want build-essential "cc/make"
have nft || want nftables "nft"
have openssl || want openssl "openssl"
# curl and pkg-config were never hard requirements (the health check falls
# back to openssl; headers are also found by path), so they are only
# installed on Debian-family systems, where it costs nothing.
if is_debian_family; then
	have curl || want curl "curl"
	have pkg-config || want pkg-config "pkg-config"
fi
have_openssl_headers || want libssl-dev "openssl-headers"
if [ "$WITH_PACKET" = 1 ] && ! pkg-config --exists libnetfilter_queue 2>/dev/null; then
	want libnetfilter-queue-dev "libnetfilter-queue"
fi
need_pkgs="${need_pkgs# }"
need_desc="${need_desc# }"

# The service integration is systemd-based; systemd is never installed here.
if ! have systemctl; then
	err "systemd (systemctl) is required and was not found. Nivyx supports"
	err "systemd + nftables based Linux distributions; other init systems"
	err "(OpenRC, runit, Slackware's rc, ...) are not supported by this installer."
	exit 2
fi

if [ -n "$need_pkgs" ]; then
	if is_debian_family; then
		log "  missing: $need_desc"
		log "  installing with apt-get: $need_pkgs"
		export DEBIAN_FRONTEND=noninteractive
		aptlog="$(mktemp /var/tmp/nivyx-apt.XXXXXX)"
		# refresh the package lists only when a package is not installable
		# from the current lists; the package sources are never modified
		# shellcheck disable=SC2086
		if ! apt-get install -y --no-install-recommends $need_pkgs >"$aptlog" 2>&1; then
			log "  refreshing package lists (apt-get update)..."
			apt-get update >>"$aptlog" 2>&1 \
				|| { tail -n 8 "$aptlog" >&2; err "apt-get update failed (network or package sources). Nothing was changed; your internet and any existing Nivyx are unaffected."; err "install manually, then re-run: sudo apt-get install -y $need_pkgs"; exit 2; }
			# shellcheck disable=SC2086
			apt-get install -y --no-install-recommends $need_pkgs >>"$aptlog" 2>&1 \
				|| { tail -n 8 "$aptlog" >&2; err "could not install: $need_pkgs. Nothing was changed; your internet and any existing Nivyx are unaffected."; err "install manually, then re-run: sudo apt-get install -y $need_pkgs"; exit 2; }
		fi
		rm -f "$aptlog"
		# verify the install really provided what was missing
		for tool in cc make nft openssl; do
			have "$tool" || { err "$tool is still missing after installing packages"; exit 2; }
		done
		have_openssl_headers || { err "OpenSSL headers are still missing after installing libssl-dev"; exit 2; }
	else
		err "missing: $need_desc"
		err "packages are installed automatically only on Debian/Ubuntu."
		err "install the equivalents with your package manager, then re-run:"
		err "  C compiler + make, nftables, openssl + OpenSSL development headers"
		err "  (Arch: base-devel nftables openssl; Fedora: gcc make nftables openssl-devel;"
		err "   openSUSE: gcc make nftables libopenssl-devel)"
		[ "$WITH_PACKET" = 1 ] && err "  and libnetfilter_queue development files for --packet"
		exit 2
	fi
fi
log "  OK"

log "[2/7] Building (as user: $BUILD_USER)..."
cd "$PROJECT_ROOT"
if [ "$WITH_PACKET" = 1 ]; then
	# packet-mode starts with `make clean`, so it goes first
	run_as_build_user make packet-mode || { err "packet-mode build failed"; exit 3; }
else
	# always from clean: objects from an older tree may predate header
	# dependency tracking and would otherwise be linked stale
	run_as_build_user make clean >/dev/null
fi
run_as_build_user make all || { err "build failed — see output above"; exit 3; }
"$PROJECT_ROOT/dpi-proxy" --capabilities | grep -q '^transparent_mode: supported' \
	|| { err "built binary has no transparent mode"; exit 3; }

# Upgrade from v2.1 or earlier: the old public command names are gone.
# Remove ONLY our own leftovers - a regular file that is a Nivyx/dpi-proxy
# script - never an unrelated tool that happens to share the name.
remove_legacy_cli() {
	for legacy in /usr/local/bin/dpictl /usr/local/bin/dpi-proxy-ctl; do
		[ -f "$legacy" ] && [ ! -L "$legacy" ] || continue
		if [ "$(wc -c <"$legacy")" -lt 200000 ] && grep -q 'dpi-proxy' "$legacy" 2>/dev/null; then
			rm -f "$legacy"
			log "  removed legacy command $legacy (use: nivyx)"
		else
			log "  leaving $legacy alone (not a Nivyx file)"
		fi
	done
}

log "[3/7] Backing up and stopping the current installation (if any)..."
backup_state
PHASE=commit
systemctl stop "$TP_SERVICE" "$OLD_TP_SERVICE" >/dev/null 2>&1 || true
# Move an install from before v2.3 to the current names. Settings and
# learned state are copied, never overwriting what already exists under
# the new names (a differing old copy is kept next to it as *.legacy);
# the old unit, binaries and folders are removed only after the new
# service has passed its health check.
MIGRATING=0
if [ -f "$UNIT_DIR/$OLD_TP_SERVICE.service" ] || [ -d /etc/dpi-proxy ] || [ -d /var/lib/dpi-proxy ]; then
	MIGRATING=1
	log "  moving the previous install to the nivyx names (settings kept)"
	for d in /etc /var/lib; do
		[ -d "$d/dpi-proxy" ] || continue
		mkdir -p "$d/nivyx"
		# file by file (not cp -n, whose exit status differs between
		# coreutils releases)
		(cd "$d/dpi-proxy" && find . -type f) | while read -r f; do
			if [ ! -e "$d/nivyx/$f" ]; then
				mkdir -p "$(dirname "$d/nivyx/$f")"
				cp -a "$d/dpi-proxy/$f" "$d/nivyx/$f"
			elif ! cmp -s "$d/dpi-proxy/$f" "$d/nivyx/$f" && [ ! -e "$d/nivyx/$f.legacy" ]; then
				cp -a "$d/dpi-proxy/$f" "$d/nivyx/$f.legacy"
				log "  kept the differing old $d/dpi-proxy/${f#./} as $d/nivyx/${f#./}.legacy"
			fi
		done
	done
	systemctl disable --now "$OLD_TP_SERVICE" "$OLD_PACKET_SERVICE" >/dev/null 2>&1 || true
fi
# Two engines on TCP/443 at once is never intended: transparent mode
# replaces packet mode as the automatic engine. Packet mode stays
# installed and can be started by hand (nivyx packet start).
if systemctl is-enabled --quiet "$PACKET_SERVICE" 2>/dev/null \
	|| systemctl is-active --quiet "$PACKET_SERVICE" 2>/dev/null; then
	log "  stopping and disabling $PACKET_SERVICE (transparent mode replaces it)"
	systemctl disable --now "$PACKET_SERVICE" >/dev/null 2>&1 || true
fi

# Another transparent DPI tool (e.g. the dpi-bypass service) running at
# the same time intercepts our upstream connections and DNS and breaks
# both. We never touch it; the user decides which one runs.
OTHER_ACTIVE=0
if nft list table ip dpibypass >/dev/null 2>&1 \
	|| systemctl is-active --quiet dpi-bypass 2>/dev/null; then
	OTHER_ACTIVE=1
	echo
	err "the dpi-bypass service is active. Two transparent DPI tools at once"
	err "proxy each other's traffic and break connections. Nivyx is"
	err "installed anyway, but stop one of them:"
	err "  sudo systemctl stop dpi-bypass            (until reboot)"
	err "  sudo systemctl disable --now dpi-bypass   (permanently)"
	echo
fi

log "[4/7] Installing binaries to /usr/local/bin..."
install -m 0755 "$PROJECT_ROOT/dpi-proxy" "$BIN_DEST"
# Strip the installed copy only — the source tree's own dpi-proxy
# keeps its symbols for local debugging (make re rebuilds it anyway).
command -v strip >/dev/null 2>&1 && strip "$BIN_DEST" 2>/dev/null || true
install -m 0755 "$PROJECT_ROOT/scripts/nivyx" "$NIVYX_DEST"
remove_legacy_cli
# man page and shell completions (best effort; harmless if the shell is absent)
install -d /usr/local/share/man/man1
install -m 0644 "$PROJECT_ROOT/scripts/nivyx.1" /usr/local/share/man/man1/nivyx.1
install -D -m 0644 "$PROJECT_ROOT/scripts/completions/nivyx.bash" /usr/share/bash-completion/completions/nivyx
install -D -m 0644 "$PROJECT_ROOT/scripts/completions/_nivyx" /usr/local/share/zsh/site-functions/_nivyx
install -D -m 0644 "$PROJECT_ROOT/scripts/completions/nivyx.fish" /usr/share/fish/vendor_completions.d/nivyx.fish
if [ "$WITH_PACKET" = 1 ]; then
	install -m 0755 "$PROJECT_ROOT/dpi-proxy-packet" "$PACKET_BIN_DEST"
fi

log "[5/7] Config..."
mkdir -p "$CONF_DIR"
if [ -f "$CONF_DEST" ]; then
	log "  keeping existing $CONF_DEST"
else
	cat > "$CONF_DEST" <<'EOF'
# dpi-proxy manual rules. Transparent mode needs none: known-blocked
# hosts (Discord and a few others, built in) get the bypass straight
# away; any other host is tried directly first and learns a bypass only
# if it needs one. A rule here overrides that for exactly the named host
# (and its subdomains). Stream strategies: pass | tlsrec | tlsrec-split
#
# [domains]
# example.com = tlsrec
default = pass
EOF
	log "  wrote $CONF_DEST (no manual rules — everything automatic)"
fi

log "[6/7] Installing systemd unit(s)..."
install -m 0644 "$PROJECT_ROOT/systemd/$TP_SERVICE.service" "$UNIT_DIR/$TP_SERVICE.service"
if [ "$WITH_PACKET" = 1 ]; then
	install -m 0644 "$PROJECT_ROOT/systemd/$PACKET_SERVICE.service" "$UNIT_DIR/$PACKET_SERVICE.service"
fi
systemctl daemon-reload
systemctl enable "$TP_SERVICE" >/dev/null

log "[7/7] Starting $TP_SERVICE and checking health..."
rm -f "$STATUS_FILE"
systemctl start "$TP_SERVICE" || { err "start failed: journalctl -u $TP_SERVICE -n 50"; exit 4; }
healthy=0
# the status file must come from the process systemd just started
for _ in $(seq 1 20); do
	pid="$(systemctl show -p MainPID --value "$TP_SERVICE" 2>/dev/null || true)"
	if systemctl is-active --quiet "$TP_SERVICE" && [ -n "$pid" ] && [ "$pid" != 0 ] \
		&& nft list set inet "$TP_TABLE" alive 2>/dev/null | grep -q '443' \
		&& grep -q '^engine: running' "$STATUS_FILE" 2>/dev/null \
		&& grep -qx "pid: $pid" "$STATUS_FILE" 2>/dev/null; then
		healthy=1
		break
	fi
	sleep 0.5
done
if [ "$healthy" != 1 ]; then
	err "service is not healthy. Check: journalctl -u $TP_SERVICE -n 50"
	exit 4
fi
# answers cached before DNS was intercepted may be block-page addresses
command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches >/dev/null 2>&1 || true
if grep -q '^dns_intercept: off' "$STATUS_FILE" 2>/dev/null; then
	log "  note: DNS is not intercepted (see journalctl -u $TP_SERVICE)"
elif ! getent ahostsv4 example.com >/dev/null 2>&1; then
	err "name resolution through the engine's DNS forwarder failed; stopping it"
	exit 4
fi
if ! curl -sS -o /dev/null --max-time 15 https://example.com/ 2>/dev/null \
	&& ! openssl s_client -connect example.com:443 -servername example.com \
		-verify_hostname example.com </dev/null 2>/dev/null \
		| grep -q 'Verify return code: 0 (ok)'; then
	err "HTTPS check through the engine failed (example.com); stopping it"
	exit 4
fi

# Fail-open would let the checks above pass without the engine: they
# count only if the same engine process is still the one running.
[ "$(systemctl show -p MainPID --value "$TP_SERVICE" 2>/dev/null)" = "$pid" ] \
	&& systemctl is-active --quiet "$TP_SERVICE" \
	|| { err "the engine stopped during the DNS/HTTPS check"; exit 4; }

# Committed: only now do the names of an install from before v2.3 go.
if [ "$MIGRATING" = 1 ]; then
	rm -f "$UNIT_DIR/$OLD_TP_SERVICE.service" "$UNIT_DIR/$OLD_PACKET_SERVICE.service" \
		/usr/local/bin/dpi-proxy /usr/local/bin/dpi-proxy-packet
	rm -rf /etc/dpi-proxy /var/lib/dpi-proxy /run/dpi-proxy
	systemctl daemon-reload || true
	log "  removed the previous (dpi-proxy) names"
fi
INSTALL_OK=1
rm -rf "$BACKUP"
echo
log "Done. Nivyx is running and enabled at boot."
echo
echo "  HTTPS from all applications now goes through the automatic bypass,"
echo "  and DNS is answered over DNS-over-HTTPS (no poisoned answers);"
echo "  no browser/app proxy settings and no DNS changes are needed."
if [ "$OTHER_ACTIVE" = 1 ]; then
	echo
	echo "  WARNING: dpi-bypass is still active — stop it (see above), or the"
	echo "  two will interfere."
fi
echo
echo "  Status:     nivyx status               (sudo for interception counters)"
echo "  Doctor:     nivyx doctor                (health checks)"
echo "  Logs:       nivyx logs"
echo "  Stop:       sudo nivyx stop             (internet keeps working, unbypassed)"
echo "  Uninstall:  sudo ./scripts/uninstall.sh"
echo "  Config:     $CONF_DEST (optional manual rules)"
