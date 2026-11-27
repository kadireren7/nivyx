#!/usr/bin/env bash
#
# Nivyx for Linux — updater (in the release package).
#
#   sudo ./update.sh
#
# Nivyx installed: runs `nivyx update` (downloads the latest release,
# checks it, installs it; rolls back if it fails). Not installed yet, or an
# install too old for `nivyx update` to read this package: installs the
# version in this folder (settings are kept).
set -euo pipefail
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "update.sh: run it with sudo:  sudo ./update.sh" >&2; exit 1; }
if [ -x /usr/local/bin/nivyx ] && [ -x /usr/local/bin/nivyx-engine ] \
	&& /usr/local/bin/nivyx-engine --version 2>/dev/null | grep -q '^nivyx-engine '; then
	exec /usr/local/bin/nivyx update
fi
echo "Installing the Nivyx version in this folder..."
exec bash "$HERE/install.sh"
