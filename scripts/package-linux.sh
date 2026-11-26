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
# The archive is what `nivyx update` installs, not an installer: say so to
# anyone who downloads and opens it. (Its layout - dpi-proxy and nivyx at
# the top of nivyx-linux-x86_64/ - is what the updater of every v2.2.x and
# v2.3.x release requires; keep it.)
cat >"$PKG/README.txt" <<'EOF_README'
Nivyx for Linux - update package
================================

This archive is what "sudo nivyx update" downloads and installs on a
machine where Nivyx is already installed. It is not an installer, and
the files in it are not meant to be run by hand ("dpi-proxy" is the
internal engine; started without options it is only a plain SOCKS5
proxy and does not protect the system).

To install Nivyx, use the installer from the repository:

    git clone https://github.com/kadireren7/nivyx.git
    cd nivyx
    sudo ./scripts/install.sh

Already installed?   nivyx status   |   sudo nivyx update
More: https://github.com/kadireren7/nivyx/blob/main/docs/linux.md
EOF_README
chmod 0644 "$PKG/README.txt"
tar -C "$OUT" -czf "$OUT/nivyx-linux-x86_64.tar.gz" nivyx-linux-x86_64
ls -l "$OUT"
