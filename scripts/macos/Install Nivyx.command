#!/bin/sh
#
# Nivyx: double-click installer for macOS (also upgrades an existing
# installation in place). Finder runs .command files in Terminal.app.
# Asks for your password once (sudo) and runs files/install.sh.
set -u
cd "$(dirname "$0")" || { echo "Install Nivyx.command: could not cd to its own folder" >&2; exit 1; }
echo "Installing Nivyx..."
if [ ! -f ./files/install.sh ]; then
	echo "The \"files\" folder was not found next to this file: extract the whole"
	echo "ZIP and run \"Install Nivyx.command\" from the extracted folder."
	printf 'Press Return to close this window...'
	read -r _ || true
	exit 3
fi
echo "This needs administrator (sudo) access to install a system service."
echo
if sudo sh ./files/install.sh; then status=0; else status=$?; fi
echo
if [ $status -eq 0 ]; then
	echo "Done. You can close this window."
else
	echo "Install did not finish successfully (exit $status). See the output above."
	[ $status -eq 1 ] && echo "(If the password prompt was cancelled or the password was wrong, nothing was changed.)"
fi
printf 'Press Return to close this window...'
read -r _ || true
exit "$status"
