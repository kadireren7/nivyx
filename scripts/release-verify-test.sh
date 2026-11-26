#!/usr/bin/env bash
# The engine's release-signature check (`dpi-proxy --verify-release`, used
# by every updater) against temporary test keys: valid, missing, modified,
# wrong key, key rotation, malformed input, and an OpenSSL configuration in
# the environment that would break Ed25519 if it were read.
# Linux, macOS (bash 3.2) and Windows (MSYS2). Needs the OpenSSL 3 CLI
# (OPENSSL=... to choose one).
#
#   ./scripts/release-verify-test.sh [path/to/dpi-proxy]
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENGINE="${1:-$ROOT/dpi-proxy}"
SIGN="$ROOT/scripts/release-sign.sh"
OPENSSL="${OPENSSL:-openssl}"; export OPENSSL
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0

expect() { # expected-exit description command...
	local want="$1" what="$2" rc=0
	shift 2
	"$@" >"$T/out" 2>&1 || rc=$?
	if [ "$rc" = "$want" ]; then
		printf 'PASS: %s (exit %s)\n' "$what" "$rc"
	else
		printf 'FAIL: %s: exit %s, expected %s\n' "$what" "$rc" "$want"; cat "$T/out"; fails=$((fails + 1))
	fi
}
v() { "$ENGINE" --verify-release "$@"; }

"$OPENSSL" genpkey -algorithm ed25519 -out "$T/a.pem" 2>/dev/null
"$OPENSSL" genpkey -algorithm ed25519 -out "$T/b.pem" 2>/dev/null
"$SIGN" pubkey "$T/a.pem" key-a >"$T/keys-a"
"$SIGN" pubkey "$T/b.pem" key-b >"$T/keys-b"
cat "$T/keys-a" "$T/keys-b" >"$T/keys-ab"
printf 'nivyx-release-manifest 1\nproduct nivyx\nversion 9.9.9\nsha256 %064d nivyx-linux-x86_64.tar.gz\n' 0 >"$T/m"
"$SIGN" sign "$T/a.pem" "$T/m" >/dev/null
cp "$T/m.sig" "$T/sig-a"

expect 0 "valid signature, trusted key" v "$T/keys-a" "$T/m" "$T/sig-a"
expect 0 "the OpenSSL CLI agrees" "$SIGN" verify "$T/keys-a" "$T/m" "$T/sig-a"
expect 2 "signature file missing" v "$T/keys-a" "$T/m" "$T/nonexistent"
: >"$T/empty"
expect 1 "signature file empty" v "$T/keys-a" "$T/m" "$T/empty"
cp "$T/m" "$T/m-mod"; printf 'sha256 %064d nivyx-macos-arm64.zip\n' 1 >>"$T/m-mod"
expect 1 "manifest with a line added after signing" v "$T/keys-a" "$T/m-mod" "$T/sig-a"
sed 's/version 9.9.9/version 9.9.8/' "$T/m" >"$T/m-ver"
expect 1 "manifest with its version changed" v "$T/keys-a" "$T/m-ver" "$T/sig-a"
expect 1 "signed by a key that is not trusted" v "$T/keys-b" "$T/m" "$T/sig-a"
# the right signature under another key's id, and a flipped signature byte
id_b="$("$SIGN" keyid "$T/b.pem")"
awk -v id="$id_b" '{ $2 = id; print }' "$T/sig-a" >"$T/sig-wrongid"
expect 1 "signature line naming another trusted key" v "$T/keys-ab" "$T/m" "$T/sig-wrongid"
s="$(cut -d' ' -f3 "$T/sig-a")"; first="${s:0:1}"; [ "$first" = A ] && r=B || r=A
printf 'ed25519 %s %s%s\n' "$(cut -d' ' -f2 "$T/sig-a")" "$r" "${s:1}" >"$T/sig-flip"
expect 1 "signature with one character changed" v "$T/keys-a" "$T/m" "$T/sig-flip"
# rotation: a keyring with old and new key accepts either; two signatures
"$SIGN" sign "$T/b.pem" "$T/m" >/dev/null	# m.sig now holds a then b
expect 0 "keyring with two keys, signed by the second" v "$T/keys-b" "$T/m" "$T/m.sig"
expect 0 "keyring with two keys, signed by the first" v "$T/keys-ab" "$T/m" "$T/sig-a"
cat "$T/sig-flip" "$T/sig-a" >"$T/sig-badgood"
expect 0 "a bad signature line followed by a good one" v "$T/keys-a" "$T/m" "$T/sig-badgood"
grep '^#' "$ROOT/scripts/release-keys.txt" >"$T/keys-none" || true
expect 1 "keyring with no key (signatures not configured)" v "$T/keys-none" "$T/m" "$T/sig-a"
printf 'ed25519 not-base64!\n' >"$T/keys-bad"
expect 1 "malformed keyring" v "$T/keys-bad" "$T/m" "$T/sig-a"
printf 'rsa %s\n' "$(cut -d' ' -f2 "$T/keys-a")" >"$T/keys-rsa"
expect 1 "keyring line of an unknown key type" v "$T/keys-rsa" "$T/m" "$T/sig-a"
sed 's/$/\r/' "$T/keys-a" >"$T/keys-crlf"; sed 's/$/\r/' "$T/sig-a" >"$T/sig-crlf"
expect 0 "CRLF line endings (Windows)" v "$T/keys-crlf" "$T/m" "$T/sig-crlf"
dd if=/dev/zero of="$T/big" bs=1024 count=1025 2>/dev/null
expect 2 "manifest larger than 1 MiB" v "$T/keys-a" "$T/big" "$T/sig-a"
# an OpenSSL configuration that disables every algorithm (fips=yes, no
# FIPS provider): the check must not read it
printf 'openssl_conf = t\n[t]\nalg_section = a\n[a]\ndefault_properties = fips=yes\n' >"$T/hostile.cnf"
expect 1 "control: that configuration breaks OpenSSL when it is read" env OPENSSL_CONF="$T/hostile.cnf" "$SIGN" verify "$T/keys-a" "$T/m" "$T/sig-a"
expect 0 "OPENSSL_CONF in the environment is not read" env OPENSSL_CONF="$T/hostile.cnf" "$ENGINE" --verify-release "$T/keys-a" "$T/m" "$T/sig-a"
expect 1 "... and a wrong signature is still refused with it" env OPENSSL_CONF="$T/hostile.cnf" "$ENGINE" --verify-release "$T/keys-b" "$T/m" "$T/sig-a"

[ "$fails" = 0 ] || { echo "release-verify-test: $fails failure(s)"; exit 1; }
echo "release-verify-test: all checks passed"
