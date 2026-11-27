#!/usr/bin/env bash
# Checks the Linux release package before it is published: exactly the
# documented layout (regular files only), and an engine that needs at most
# glibc 2.35 (Ubuntu 22.04; Debian 12 has 2.36) and only libc and the
# OpenSSL 3 libraries.
#   check-linux-package.sh <nivyx-linux-x86_64.tar.gz>
set -euo pipefail
TGZ="${1:?usage: check-linux-package.sh <tar.gz>}"
MAX_GLIBC=2.35
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
tar -C "$work" -xzf "$TGZ"
pkg="$work/nivyx-linux-x86_64"
listing="$(tar -tvzf "$TGZ")"
if grep -q '^[lh]' <<<"$listing"; then echo "check: links in the package"; exit 1; fi
want="nivyx-linux-x86_64/
nivyx-linux-x86_64/QUICKSTART.txt
nivyx-linux-x86_64/files/
nivyx-linux-x86_64/files/LICENSE
nivyx-linux-x86_64/files/nivyx-engine
nivyx-linux-x86_64/files/nivyx.service
nivyx-linux-x86_64/install.sh
nivyx-linux-x86_64/nivyx
nivyx-linux-x86_64/uninstall.sh
nivyx-linux-x86_64/update.sh"
got="$(tar -tzf "$TGZ" | LC_ALL=C sort)"
[ "$got" = "$(LC_ALL=C sort <<<"$want")" ] || { echo "check: unexpected package contents:"; echo "$got"; exit 1; }
for f in install.sh uninstall.sh update.sh nivyx files/nivyx-engine; do
	[ -x "$pkg/$f" ] || { echo "check: $f is not executable"; exit 1; }
done
need="$(objdump -p "$pkg/files/nivyx-engine" | awk '/NEEDED/ {print $2}' | LC_ALL=C sort | tr '\n' ' ')"
[ "$need" = "libc.so.6 libcrypto.so.3 libssl.so.3 " ] || { echo "check: unexpected libraries: $need"; exit 1; }
glibc="$(objdump -T "$pkg/files/nivyx-engine" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -V | tail -n 1)"
[ "$(printf '%s\n%s\n' "$glibc" "$MAX_GLIBC" | sort -V | tail -n 1)" = "$MAX_GLIBC" ] \
	|| { echo "check: the engine needs glibc $glibc; at most $MAX_GLIBC is allowed (build on Ubuntu 22.04)"; exit 1; }
"$pkg/files/nivyx-engine" --capabilities | grep -q '^transparent_mode: supported' || { echo "check: no transparent mode"; exit 1; }
"$pkg/files/nivyx-engine" --version | grep -q '^nivyx-engine ' || { echo "check: unexpected --version output"; exit 1; }
echo "check: OK (needs glibc >= $glibc, $need; $(du -h "$TGZ" | cut -f1) packed)"
