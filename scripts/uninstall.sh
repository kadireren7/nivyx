#!/usr/bin/env bash
#
# Removes what scripts/install.sh installed — the transparent and
# packet services, binaries, control CLI, man page, completions and the
# two nftables tables Nivyx owns (inet dpi_proxy_tp, inet dpi_proxy).
# No other firewall state is touched. Needs root.
#
#   sudo ./scripts/uninstall.sh           keeps your settings (/etc/nivyx)
#                                         and learned state (/var/lib/nivyx)
#   sudo ./scripts/uninstall.sh --purge   removes those too
#
# (The same on every platform: a plain uninstall keeps your data, so a
# later reinstall picks it up; --purge / -Purge removes everything.)

set -euo pipefail

PURGE=0
for arg in "$@"; do
	case "$arg" in
	--purge) PURGE=1 ;;
	-h | --help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) printf '[uninstall] unknown option: %s (only --purge)\n' "$arg" >&2; exit 1 ;;
	esac
done

# current names first, then those of installs from before v2.3
SERVICES="nivyx nivyx-packet dpi-proxy-transparent dpi-proxy-packet"
BINS="/usr/local/bin/nivyx-engine /usr/local/bin/nivyx-packet-engine /usr/local/bin/nivyx /usr/local/bin/dpi-proxy /usr/local/bin/dpi-proxy-packet"
UNIT_DIR="/etc/systemd/system"
CONF_DIR="/etc/nivyx"
OLD_CONF_DIR="/etc/dpi-proxy"
STATE_DIR="/var/lib/nivyx"
OLD_STATE_DIR="/var/lib/dpi-proxy"

log() { printf '[uninstall] %s\n' "$1"; }
err() { printf '[uninstall] ERROR: %s\n' "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
	err "this uninstaller removes system-wide services and needs root."
	err "run: sudo $0"
	exit 1
fi

# one install/update/repair/uninstall at a time (same lock as nivyx)
if command -v flock >/dev/null 2>&1; then
	exec 9>/run/nivyx-admin.lock
	flock -n 9 || { err "another Nivyx install, update, repair or uninstall is running; try again when it has finished"; exit 1; }
fi

log "[1/4] Stopping and disabling services..."
for s in $SERVICES; do
	systemctl disable --now "$s" >/dev/null 2>&1 || true
	rm -f "$UNIT_DIR/$s.service"
done
systemctl daemon-reload

log "[2/4] Removing binaries..."
# shellcheck disable=SC2086
rm -f $BINS
rm -f /usr/local/share/man/man1/nivyx.1 /usr/share/bash-completion/completions/nivyx \
	/usr/local/share/zsh/site-functions/_nivyx /usr/share/fish/vendor_completions.d/nivyx.fish
# v2.1 and earlier command names, only if they are our own scripts
for legacy in /usr/local/bin/dpictl /usr/local/bin/dpi-proxy-ctl; do
	[ -f "$legacy" ] && [ ! -L "$legacy" ] && grep -q 'dpi-proxy' "$legacy" 2>/dev/null && rm -f "$legacy"
done

log "[3/4] Removing Nivyx's own nftables tables (if left over)..."
for t in dpi_proxy_tp dpi_proxy; do
	if nft list table inet "$t" >/dev/null 2>&1; then
		nft delete table inet "$t"
		log "  removed table inet $t"
	fi
done

rm -rf /run/nivyx /run/dpi-proxy
if [ "$PURGE" = 1 ]; then
	log "[4/4] --purge: removing settings and learned state..."
	rm -rf "$CONF_DIR" "$OLD_CONF_DIR" "$STATE_DIR" "$OLD_STATE_DIR"
else
	log "[4/4] Keeping settings and learned state"
fi

# nothing of ours may still intercept traffic
left=""
for s in $SERVICES; do
	systemctl is-active --quiet "$s" 2>/dev/null && left="$left service:$s"
done
for t in dpi_proxy_tp dpi_proxy; do
	nft list table inet "$t" >/dev/null 2>&1 && left="$left table:$t"
done
if [ -n "$left" ]; then
	err "could not remove:$left"
	exit 1
fi

echo
log "Nivyx removed; networking is back to normal."
for kept in "$CONF_DIR" "$OLD_CONF_DIR" "$STATE_DIR" "$OLD_STATE_DIR"; do
	if [ -d "$kept" ]; then
		echo "Kept $kept (remove with: sudo $0 --purge)"
	fi
done
