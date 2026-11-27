#!/bin/sh
# Assembles the macOS package folder from a built nivyx-engine:
#   package.sh <out-dir>
# (zipped with: ditto -c -k --keepParent <out-dir> <zip>)
#
#   <out-dir>/Install Nivyx.command  Uninstall Nivyx.command
#             Update Nivyx.command  nivyx  QUICKSTART.txt
#             files/  nivyx-engine, install.sh, uninstall.sh,
#                     the launchd job, LICENSE
#
# `nivyx update` requires files/nivyx-engine (reporting "nivyx-engine
# <version>"), files/install.sh and nivyx inside nivyx-macos-<arch>.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
M="$ROOT/scripts/macos"
OUT="${1:?usage: package.sh <out-dir>}"
mkdir -p "$OUT/files"
install -m 755 "$ROOT/nivyx-engine" "$OUT/files/nivyx-engine"
# Strip the packaged copy only (debug symbols, not needed at
# runtime); the build tree's own binary is untouched.
strip "$OUT/files/nivyx-engine"
install -m 755 "$M/install.sh" "$M/uninstall.sh" "$OUT/files/"
install -m 644 "$M/io.github.kadireren7.nivyx.plist" "$ROOT/LICENSE" "$OUT/files/"
for f in "Install Nivyx.command" "Uninstall Nivyx.command" "Update Nivyx.command" nivyx; do
	install -m 755 "$M/$f" "$OUT/$f"
done
install -m 644 "$M/QUICKSTART.txt" "$OUT/QUICKSTART.txt"
# what the binary needs at run time: macOS system libraries only
if otool -L "$OUT/files/nivyx-engine" | tail -n +2 | grep -v -e '^[[:space:]]*/usr/lib/' -e '^[[:space:]]*/System/'; then
	echo "package.sh: nivyx-engine links a non-system library (see above)" >&2
	exit 1
fi
ls -l "$OUT" "$OUT/files"
