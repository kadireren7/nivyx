#!/usr/bin/env bash
# Assembles the Linux release package nivyx-linux-x86_64.tar.gz:
#
#   nivyx-linux-x86_64/  install.sh  uninstall.sh  update.sh  nivyx
#                        QUICKSTART.txt
#                        files/  nivyx-engine (prebuilt, stripped),
#                                nivyx.service, LICENSE
#
# `nivyx update` requires files/nivyx-engine (reporting "nivyx-engine
# <version>"), install.sh and nivyx in nivyx-linux-x86_64/.
#   package-linux.sh <out-dir>     (run after `make re`)
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${1:?usage: package-linux.sh <out-dir>}"
PKG="$OUT/nivyx-linux-x86_64"
rm -rf "$PKG"
mkdir -p "$PKG/files"
install -m 0755 "$ROOT/nivyx-engine" "$PKG/files/nivyx-engine"
strip "$PKG/files/nivyx-engine"
install -m 0644 "$ROOT/systemd/nivyx.service" "$ROOT/LICENSE" "$PKG/files/"
install -m 0755 "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$ROOT/scripts/update.sh" "$ROOT/scripts/nivyx" "$PKG/"
install -m 0644 "$ROOT/scripts/QUICKSTART-linux.txt" "$PKG/QUICKSTART.txt"
tar -C "$OUT" -czf "$OUT/nivyx-linux-x86_64.tar.gz" nivyx-linux-x86_64
ls -l "$PKG" "$PKG/files"
