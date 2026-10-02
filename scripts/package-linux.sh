#!/usr/bin/env bash
# Assembles the Linux update package: nivyx-linux-x86_64.tar.gz holding the
# stripped engine and the nivyx CLI (what `nivyx update` installs).
#   package-linux.sh <out-dir>     (run after `make re`)
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${1:?usage: package-linux.sh <out-dir>}"
PKG="$OUT/nivyx-linux-x86_64"
rm -rf "$PKG"
mkdir -p "$PKG"
install -m 0755 "$ROOT/dpi-proxy" "$PKG/dpi-proxy"
strip "$PKG/dpi-proxy"
install -m 0755 "$ROOT/scripts/nivyx" "$PKG/nivyx"
install -m 0644 "$ROOT/scripts/nivyx.1" "$PKG/nivyx.1"
mkdir -p "$PKG/completions"
install -m 0644 "$ROOT"/scripts/completions/nivyx.bash "$ROOT"/scripts/completions/_nivyx "$ROOT"/scripts/completions/nivyx.fish "$PKG/completions/"
install -m 0644 "$ROOT/LICENSE" "$PKG/LICENSE"
tar -C "$OUT" -czf "$OUT/nivyx-linux-x86_64.tar.gz" nivyx-linux-x86_64
ls -l "$OUT"
