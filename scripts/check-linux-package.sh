#!/usr/bin/env bash
# Checks the Linux update package before it is published: the engine may
# need at most glibc 2.35 (Ubuntu 22.04; Debian 12 has 2.36) and only libc
# and the OpenSSL 3 libraries, and the layout is the one every updater
# since v2.2 expects (dpi-proxy and nivyx at the top of nivyx-linux-<arch>/,
# regular files only).
#   check-linux-package.sh <nivyx-linux-x86_64.tar.gz>
set -euo pipefail
TGZ="${1:?usage: check-linux-package.sh <tar.gz>}"
MAX_GLIBC=2.35
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
tar -C "$work" -xzf "$TGZ"
pkg="$work/nivyx-linux-x86_64"
for f in dpi-proxy nivyx nivyx.1 README.txt LICENSE completions/nivyx.bash; do
	[ -f "$pkg/$f" ] && [ ! -L "$pkg/$f" ] || { echo "check: $f missing (or a link)"; exit 1; }
done
[ -x "$pkg/dpi-proxy" ] && [ -x "$pkg/nivyx" ] || { echo "check: dpi-proxy/nivyx not executable"; exit 1; }
listing="$(tar -tvzf "$TGZ")"
if grep -q '^[lh]' <<<"$listing"; then echo "check: links in the package"; exit 1; fi
need="$(objdump -p "$pkg/dpi-proxy" | awk '/NEEDED/ {print $2}' | LC_ALL=C sort | tr '\n' ' ')"
[ "$need" = "libc.so.6 libcrypto.so.3 libssl.so.3 " ] || { echo "check: unexpected libraries: $need"; exit 1; }
glibc="$(objdump -T "$pkg/dpi-proxy" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -V | tail -n 1)"
[ "$(printf '%s\n%s\n' "$glibc" "$MAX_GLIBC" | sort -V | tail -n 1)" = "$MAX_GLIBC" ] \
	|| { echo "check: the engine needs glibc $glibc; at most $MAX_GLIBC is allowed (build on Ubuntu 22.04)"; exit 1; }
"$pkg/dpi-proxy" --capabilities | grep -q '^transparent_mode: supported' || { echo "check: no transparent mode"; exit 1; }
echo "check: OK (needs glibc >= $glibc, $need; $(du -h "$TGZ" | cut -f1) packed)"
