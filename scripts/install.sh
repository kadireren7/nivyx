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

# If anything below fails, leave the machine fail-open: our service
# stopped and our nftables table gone. Files already copied stay (a
# re-run overwrites them).
INSTALL_OK=0
# Set when we stop before changing anything (missing dependencies): an
# existing, working installation is then left running untouched.
NOTHING_CHANGED=0
cleanup_on_failure() {
	if [ "$INSTALL_OK" -ne 1 ] && [ "$NOTHING_CHANGED" -ne 1 ]; then
		err "install failed — stopping $TP_SERVICE and removing its nftables table"
		systemctl stop "$TP_SERVICE" >/dev/null 2>&1 || true
		nft delete table inet "$TP_TABLE" >/dev/null 2>&1 || true
	fi
}
trap cleanup_on_failure EXIT

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
	{ NOTHING_CHANGED=1; exit 2; }
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
				|| { tail -n 8 "$aptlog" >&2; err "apt-get update failed (network or package sources). Nothing was changed; your internet and any existing Nivyx are unaffected."; err "install manually, then re-run: sudo apt-get install -y $need_pkgs"; { NOTHING_CHANGED=1; exit 2; }; }
			# shellcheck disable=SC2086
			apt-get install -y --no-install-recommends $need_pkgs >>"$aptlog" 2>&1 \
				|| { tail -n 8 "$aptlog" >&2; err "could not install: $need_pkgs. Nothing was changed; your internet and any existing Nivyx are unaffected."; err "install manually, then re-run: sudo apt-get install -y $need_pkgs"; { NOTHING_CHANGED=1; exit 2; }; }
		fi
		rm -f "$aptlog"
		# verify the install really provided what was missing
		for tool in cc make nft openssl; do
			have "$tool" || { err "$tool is still missing after installing packages"; { NOTHING_CHANGED=1; exit 2; }; }
		done
		have_openssl_headers || { err "OpenSSL headers are still missing after installing libssl-dev"; { NOTHING_CHANGED=1; exit 2; }; }
	else
		err "missing: $need_desc"
		err "packages are installed automatically only on Debian/Ubuntu."
		err "install the equivalents with your package manager, then re-run:"
		err "  C compiler + make, nftables, openssl + OpenSSL development headers"
		err "  (Arch: base-devel nftables openssl; Fedora: gcc make nftables openssl-devel;"
		err "   openSUSE: gcc make nftables libopenssl-devel)"
		[ "$WITH_PACKET" = 1 ] && err "  and libnetfilter_queue development files for --packet"
		{ NOTHING_CHANGED=1; exit 2; }
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

log "[3/7] Stopping running Nivyx services for a clean (re)install..."
systemctl stop "$TP_SERVICE" "$OLD_TP_SERVICE" >/dev/null 2>&1 || true
# Move an install from before v2.3 to the current names. Settings and
# learned state are copied (never overwriting what already exists under
# the new names); the old unit, binaries and folders go afterwards.
if [ -f "$UNIT_DIR/$OLD_TP_SERVICE.service" ] || [ -d /etc/dpi-proxy ]; then
	log "  moving the previous install to the nivyx names (settings kept)"
	for d in /etc /var/lib; do
		[ -d "$d/dpi-proxy" ] || continue
		mkdir -p "$d/nivyx"
		cp -an "$d/dpi-proxy/." "$d/nivyx/"
		rm -rf "$d/dpi-proxy"
	done
	systemctl disable --now "$OLD_TP_SERVICE" "$OLD_PACKET_SERVICE" >/dev/null 2>&1 || true
	rm -f "$UNIT_DIR/$OLD_TP_SERVICE.service" "$UNIT_DIR/$OLD_PACKET_SERVICE.service" \
		/usr/local/bin/dpi-proxy /usr/local/bin/dpi-proxy-packet
	rm -rf /run/dpi-proxy
	systemctl daemon-reload
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
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if systemctl is-active --quiet "$TP_SERVICE" \
		&& nft list set inet "$TP_TABLE" alive 2>/dev/null | grep -q '443' \
		&& grep -q '^engine: running' "$STATUS_FILE" 2>/dev/null; then
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

INSTALL_OK=1
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
