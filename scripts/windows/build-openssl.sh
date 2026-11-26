#!/usr/bin/env bash
# Builds the static OpenSSL that dpi-proxy.exe links (MSYS2 MINGW64 shell):
# the same pinned official 3.5 LTS release as macOS (scripts/macos/
# build-openssl.sh), SHA-256 checked, instead of whatever MSYS2 package is
# current on the build day. Headers and libssl.a/libcrypto.a go to PREFIX;
# nothing is installed system-wide.
#
#   build-openssl.sh PREFIX
#   make windows CC_WIN=gcc OPENSSL_WIN_PREFIX=PREFIX
#
# OPENSSLDIR/MODULESDIR are absolute and under %ProgramFiles% (writable by
# administrators only). The engine never loads a configuration anyway
# (OPENSSL_INIT_NO_LOAD_CONFIG, src/tlsclient.c); MSYS2's own package
# resolves them relative to the current directory instead.
#
# An existing PREFIX built from the same version is reused (CI caches it).
set -euo pipefail
VERSION="$(sed -n 's/^VERSION=//p' "$(dirname "$0")/../macos/build-openssl.sh")"
SHA256="$(sed -n 's/^SHA256=//p' "$(dirname "$0")/../macos/build-openssl.sh")"
PREFIX="${1:?usage: build-openssl.sh PREFIX}"
[ -n "$VERSION" ] && [ -n "$SHA256" ] || { echo "no pinned OpenSSL version found" >&2; exit 1; }
if [ -f "$PREFIX/lib/libssl.a" ] && [ -f "$PREFIX/.version-$VERSION" ]; then
	echo "OpenSSL $VERSION already built in $PREFIX"
	exit 0
fi
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/openssl.tar.gz" \
	"https://github.com/openssl/openssl/releases/download/openssl-$VERSION/openssl-$VERSION.tar.gz"
echo "$SHA256  $work/openssl.tar.gz" | sha256sum -c - >/dev/null || { echo "OpenSSL $VERSION: SHA-256 mismatch" >&2; exit 1; }
tar -xzf "$work/openssl.tar.gz" -C "$work"
cd "$work/openssl-$VERSION"
./Configure mingw64 no-shared no-tests no-docs no-apps no-zlib \
	--prefix="$PREFIX" --libdir=lib \
	"--openssldir=C:/Program Files/Common Files/SSL" >/dev/null
make -j"$(nproc)" build_libs >/dev/null
make install_dev >/dev/null
touch "$PREFIX/.version-$VERSION"
echo "OpenSSL $VERSION (mingw64, static) in $PREFIX"
