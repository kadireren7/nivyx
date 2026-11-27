#!/usr/bin/env bash
# Assembles the Windows package folder. Usage: package.sh <out-dir>
#
#   <out-dir>/Install Nivyx.cmd  Uninstall Nivyx.cmd  Update Nivyx.cmd
#             nivyx.cmd  QUICKSTART.txt
#             files/  nivyx-engine.exe, the unmodified official WinDivert
#                     runtime files and license, LICENSE.txt and the
#                     scripts the launchers run
#
# `nivyx update` requires files/nivyx-engine.exe (reporting
# "nivyx-engine <version>") and files/install.ps1 inside a top folder named
# nivyx-windows-x86_64.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT="${1:?usage: package.sh <out-dir>}"
WD="$ROOT/third_party/WinDivert-2.2.2-A"
W="$ROOT/scripts/windows"
mkdir -p "$OUT/files"
cp "$ROOT/nivyx-engine.exe" "$OUT/files/"
# the engine must link the pinned OpenSSL (scripts/macos/build-openssl.sh)
pin="$(sed -n 's/^VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/scripts/macos/build-openssl.sh" | head -n 1 || true)"
have="$(strings "$OUT/files/nivyx-engine.exe" | sed -n 's/^OpenSSL \([0-9][0-9.]*[a-z]\{0,1\}\) .*/\1/p' | head -n 1 || true)"
[ -n "$pin" ] && [ "$have" = "$pin" ] \
	|| { echo "package.sh: nivyx-engine.exe contains OpenSSL ${have:-<not found>}, the pinned version is ${pin:-?}" >&2; exit 1; }
# Strip the packaged copy only (debug symbols, not needed at
# runtime). Never strip WinDivert: it's shipped unmodified, exactly
# as officially signed.
strip "$OUT/files/nivyx-engine.exe"
cp "$WD/x64/WinDivert.dll" "$WD/x64/WinDivert64.sys" "$OUT/files/"
cp "$WD/LICENSE" "$OUT/files/WinDivert-LICENSE.txt"
cp "$ROOT/LICENSE" "$OUT/files/LICENSE.txt"
cp "$W/install.ps1" "$W/uninstall.ps1" "$W/nivyx-impl.ps1" "$OUT/files/"
cp "$W/Install Nivyx.cmd" "$W/Uninstall Nivyx.cmd" "$W/Update Nivyx.cmd" "$W/nivyx.cmd" "$OUT/"
# Windows Notepad of Windows 10 1809 and earlier shows LF-only text as one line
sed 's/\r$//; s/$/\r/' "$W/QUICKSTART.txt" >"$OUT/QUICKSTART.txt"
# cmd.exe reads batch files in blocks and can miss a `goto` label in an
# LF-only file: ship the .cmd files with CRLF line endings.
for f in "$OUT"/*.cmd; do
	sed -i 's/\r$//; s/$/\r/' "$f"
done
ls -l "$OUT" "$OUT/files"
