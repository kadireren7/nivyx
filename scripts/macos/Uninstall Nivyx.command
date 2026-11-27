#!/bin/sh
#
# Nivyx: double-click uninstaller for macOS. Asks for your password once
# (sudo) and runs files/uninstall.sh. Settings are kept; to remove them
# too run:  sudo sh files/uninstall.sh --purge
set -u
cd "$(dirname "$0")" || { echo "Uninstall Nivyx.command: could not cd to its own folder" >&2; exit 1; }
echo "Uninstalling Nivyx..."
if [ ! -f ./files/uninstall.sh ]; then
	echo "The \"files\" folder was not found next to this file: extract the whole"
	echo "ZIP and run \"Uninstall Nivyx.command\" from the extracted folder."
	printf 'Press Return to close this window...'
	read -r _ || true
	exit 3
fi
echo "This needs administrator (sudo) access to remove a system service."
echo
if sudo sh ./files/uninstall.sh; then status=0; else status=$?; fi
echo
if [ $status -eq 0 ]; then
	echo "Done. You can close this window."
else
	echo "Uninstall did not finish successfully (exit $status). See the output above."
fi
printf 'Press Return to close this window...'
read -r _ || true
exit "$status"
