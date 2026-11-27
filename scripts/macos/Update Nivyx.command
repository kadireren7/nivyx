#!/bin/sh
#
# Nivyx: double-click updater for macOS. Asks for your password once
# (sudo), then:
#   - Nivyx installed: runs `nivyx update` (downloads the latest release,
#     checks it, installs it; rolls back if it fails);
#   - not installed, or an older "dpi-proxy" version: installs the version
#     in this folder (settings of an older version are kept).
set -u
cd "$(dirname "$0")" || { echo "Update Nivyx.command: could not cd to its own folder" >&2; exit 1; }
if [ ! -f ./files/install.sh ]; then
	echo "The \"files\" folder was not found next to this file: extract the whole"
	echo "ZIP and run \"Update Nivyx.command\" from the extracted folder."
	printf 'Press Return to close this window...'
	read -r _ || true
	exit 3
fi
echo "This needs administrator (sudo) access."
echo
if [ -f /Library/LaunchDaemons/io.github.kadireren7.nivyx.plist ] && [ -x /usr/local/bin/nivyx ]; then
	echo "Checking for a newer Nivyx..."
	if sudo /usr/local/bin/nivyx update; then status=0; else status=$?; fi
else
	echo "Installing the Nivyx version in this folder..."
	if sudo sh ./files/install.sh; then status=0; else status=$?; fi
fi
echo
if [ $status -eq 0 ]; then
	echo "Done. You can close this window."
else
	echo "Nivyx was not updated (exit $status). See the output above; the installed version was left working."
fi
printf 'Press Return to close this window...'
read -r _ || true
exit "$status"
