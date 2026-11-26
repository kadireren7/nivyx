#!/usr/bin/env bash
# Assembles the Windows release folder: dpi-proxy.exe, the unmodified
# official WinDivert runtime files and license, and the install /
# uninstall / control scripts. Usage: package.sh <out-dir>
#
# The layout is a contract: the `nivyx update` of every installed v2.2.x
# and v2.3.x requires dpi-proxy.exe (reporting "dpi-proxy <version>"),
# WinDivert.dll next to it and nivyx-impl.ps1 at the top of the
# nivyx-windows-x86_64 folder, or it refuses the release. Moving or
# renaming them would strand those installs on their current version.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT="${1:?usage: package.sh <out-dir>}"
WD="$ROOT/third_party/WinDivert-2.2.2-A"
mkdir -p "$OUT"
cp "$ROOT/dpi-proxy.exe" "$OUT/"
# Strip the packaged copy only (debug symbols, not needed at
# runtime). Never strip WinDivert: it's shipped unmodified, exactly
# as officially signed.
strip "$OUT/dpi-proxy.exe"
cp "$WD/x64/WinDivert.dll" "$WD/x64/WinDivert64.sys" "$OUT/"
cp "$WD/LICENSE" "$OUT/WinDivert-LICENSE.txt"
cp "$ROOT/LICENSE" "$OUT/LICENSE.txt"
for f in install.ps1 uninstall.ps1 "Install Nivyx.cmd" "Uninstall Nivyx.cmd" \
	nivyx-impl.ps1 nivyx.cmd WINDOWS-QUICKSTART.txt; do
	cp "$ROOT/scripts/windows/$f" "$OUT/"
done
cp "$ROOT/scripts/completions/nivyx.ps1" "$OUT/nivyx-completion.ps1"
# cmd.exe reads batch files in blocks and can miss a `goto` label in an
# LF-only file: ship the .cmd files with CRLF line endings.
for f in "$OUT"/*.cmd; do
	sed -i 's/\r$//; s/$/\r/' "$f"
done
ls -l "$OUT"
