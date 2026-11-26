#!/usr/bin/env bash
# A ThreadSanitizer-instrumented static OpenSSL, for the TSan runs only
# (scripts/sanitize-engine-linux.sh, scripts/tls-verify-test.sh). Never
# used for anything shipped.
#
# Why: libcrypto's lock-free paths use C11 acquire/release atomics (e.g.
# the cached-extensions fast path in crypto/x509/v3_purp.c). In an
# uninstrumented libcrypto TSan cannot see them, yet it does see the
# memcpy/memcmp they order (interceptors), and reports a race that is
# not there. With an instrumented build it sees the synchronisation.
#
#   build-openssl-tsan.sh <prefix>      (installs <prefix>/lib/libssl.a ...)
set -euo pipefail
VERSION="3.5.5"
SHA256="b28c91532a8b65a1f983b4c28b7488174e4a01008e29ce8e69bd789f28bc2a89"
PREFIX="${1:?usage: build-openssl-tsan.sh <prefix>}"
[ -f "$PREFIX/lib/libcrypto.a" ] && [ -f "$PREFIX/.version-$VERSION" ] && { echo "OpenSSL $VERSION (TSan) already in $PREFIX"; exit 0; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/o.tar.gz" "https://github.com/openssl/openssl/releases/download/openssl-$VERSION/openssl-$VERSION.tar.gz"
echo "$SHA256  $work/o.tar.gz" | sha256sum -c - >/dev/null || { echo "OpenSSL $VERSION: SHA-256 mismatch" >&2; exit 1; }
tar -C "$work" -xzf "$work/o.tar.gz"
cd "$work/openssl-$VERSION"
./Configure linux-"$(uname -m)" --prefix="$PREFIX" --libdir=lib no-shared no-tests no-docs no-apps \
	-fsanitize=thread -g -O1 >/dev/null
make -j"$(nproc)" >/dev/null
make install_sw >/dev/null
touch "$PREFIX/.version-$VERSION"
echo "OpenSSL $VERSION (TSan-instrumented, static) installed in $PREFIX"
