#!/usr/bin/env bash
# Release signing for the maintainer (offline machine) and for the test
# suite (temporary keys). Needs the OpenSSL 3 command line tool (not
# LibreSSL); set OPENSSL=/path/to/openssl to choose one.
# Full procedure: docs/release-signing.md.
#
#   release-sign.sh pubkey  KEY.pem [comment]   keyring line for scripts/release-keys.txt
#   release-sign.sh keyid   KEY.pem             the key id used in signature lines
#   release-sign.sh sign    KEY.pem MANIFEST    append a signature line to MANIFEST.sig
#   release-sign.sh verify  KEYRING MANIFEST [SIG]
#                                               check with OpenSSL (independent of the
#                                               engine's own check)
#   release-sign.sh check   DIR VERSION         DIR/nivyx-release.manifest is for VERSION
#                                               and matches every file in DIR
#   release-sign.sh release KEY.pem DIR VERSION check + sign + verify against
#                                               scripts/release-keys.txt
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OPENSSL="${OPENSSL:-openssl}"
SPKI_PREFIX=MCowBQYDK2VwAyEA	# base64 of the 12-byte Ed25519 SubjectPublicKeyInfo header
MANIFEST_NAME=nivyx-release.manifest

die() { echo "release-sign: $*" >&2; exit 1; }

need_openssl() {
	local v
	v="$("$OPENSSL" version 2>/dev/null)" || die "no openssl command ($OPENSSL)"
	case "$v" in
	"OpenSSL 3."* | "OpenSSL 4."*) ;;
	*) die "needs the OpenSSL 3 command line tool, found: $v (set OPENSSL=...)" ;;
	esac
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

pub_b64() { # KEY.pem -> base64 of the raw 32-byte public key
	local pem
	pem="$("$OPENSSL" pkey -in "$1" -pubout 2>/dev/null)" || die "cannot read the private key $1"
	pem="$(printf '%s\n' "$pem" | grep -v -- '-----' | tr -d '\n')"
	case "$pem" in
	"$SPKI_PREFIX"*) printf '%s' "${pem#"$SPKI_PREFIX"}" ;;
	*) die "$1 is not an Ed25519 key" ;;
	esac
}

id_of_b64() { printf '%s' "$1" | "$OPENSSL" base64 -d -A | "$OPENSSL" dgst -sha256 -r | cut -c1-16; }

cmd_sign() { # KEY MANIFEST
	local key="$1" man="$2" tmp sig id
	[ -f "$man" ] || die "no manifest $man"
	id="$(id_of_b64 "$(pub_b64 "$key")")"
	tmp="$(mktemp)"
	"$OPENSSL" pkeyutl -sign -rawin -inkey "$key" -in "$man" -out "$tmp" || { rm -f "$tmp"; die "signing failed"; }
	sig="$("$OPENSSL" base64 -A -in "$tmp")"
	rm -f "$tmp"
	printf 'ed25519 %s %s\n' "$id" "$sig" >>"$man.sig"
	echo "signed $man with key $id -> $man.sig"
}

cmd_verify() { # KEYRING MANIFEST [SIG]
	local keyring="$1" man="$2" sig="${3:-$2.sig}" line b64 id alg sid ssig tmp pem ok=0
	[ -f "$sig" ] || die "no signature file $sig"
	tmp="$(mktemp -d)"
	while read -r alg sid ssig _; do
		[ "$alg" = ed25519 ] || continue
		while read -r line; do
			set -- $line
			[ "${1:-}" = ed25519 ] || continue
			b64="$2"; id="$(id_of_b64 "$b64")"
			[ "$id" = "$sid" ] || continue
			pem="$tmp/k.pem"
			printf -- '-----BEGIN PUBLIC KEY-----\n%s%s\n-----END PUBLIC KEY-----\n' "$SPKI_PREFIX" "$b64" >"$pem"
			printf '%s' "$ssig" | "$OPENSSL" base64 -d -A >"$tmp/s.bin"
			if "$OPENSSL" pkeyutl -verify -pubin -inkey "$pem" -rawin -in "$man" -sigfile "$tmp/s.bin" >/dev/null 2>&1; then
				echo "OpenSSL: valid signature by trusted key $id"
				ok=1
			fi
		done < <(grep '^ed25519 ' "$keyring" || true)
	done <"$sig"
	rm -rf "$tmp"
	[ "$ok" = 1 ] || die "no valid signature by a key in $keyring"
}

cmd_check() { # DIR VERSION
	local dir="$1" ver="$2" man="$1/$MANIFEST_NAME" n=0 h f want
	[ -f "$man" ] || die "no $man"
	[ "$(sed -n 1p "$man")" = "nivyx-release-manifest 1" ] || die "$man: not a version 1 manifest"
	[ "$(grep -c '^product nivyx$' "$man")" = 1 ] || die "$man: product line"
	[ "$(grep -c "^version $ver\$" "$man")" = 1 ] && [ "$(grep -c '^version ' "$man")" = 1 ] \
		|| die "$man is not for version $ver"
	while read -r _ h f; do
		[ -f "$dir/$f" ] || die "listed but missing: $f"
		[ "$(sha256_of "$dir/$f")" = "$h" ] || die "SHA-256 differs from the manifest: $f"
		n=$((n + 1))
	done < <(grep '^sha256 ' "$man")
	for f in "$dir"/*; do
		f="${f##*/}"
		case "$f" in SHA256SUMS | "$MANIFEST_NAME" | "$MANIFEST_NAME.sig") continue ;; esac
		grep -q " $f\$" "$man" || die "in $dir but not in the manifest: $f"
	done
	echo "manifest OK: version $ver, $n files match"
}

case "${1:-}" in
pubkey) need_openssl; printf 'ed25519 %s %s\n' "$(pub_b64 "${2:?KEY.pem}")" "${3:-nivyx-release-$(date +%Y)}" ;;
keyid) need_openssl; id_of_b64 "$(pub_b64 "${2:?KEY.pem}")" ;;
sign) need_openssl; cmd_sign "${2:?KEY.pem}" "${3:?MANIFEST}" ;;
verify) need_openssl; cmd_verify "${2:?KEYRING}" "${3:?MANIFEST}" "${4:-}" ;;
check) cmd_check "${2:?DIR}" "${3:?VERSION}" ;;
release)
	need_openssl
	key="${2:?KEY.pem}"; dir="${3:?DIR}"; ver="${4:?VERSION}"
	cmd_check "$dir" "$ver"
	grep -q "^ed25519 $(pub_b64 "$key") " "$ROOT/scripts/release-keys.txt" \
		|| die "this key is not in scripts/release-keys.txt: users' updaters would not trust it"
	[ ! -e "$dir/$MANIFEST_NAME.sig" ] || [ -n "${APPEND_SIGNATURE:-}" ] \
		|| die "$dir/$MANIFEST_NAME.sig exists (set APPEND_SIGNATURE=1 to add a second signature)"
	cmd_sign "$key" "$dir/$MANIFEST_NAME"
	cmd_verify "$ROOT/scripts/release-keys.txt" "$dir/$MANIFEST_NAME"
	echo "upload $dir/$MANIFEST_NAME.sig to the draft release, then publish it"
	;;
*) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
