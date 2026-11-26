#!/usr/bin/env bash
# Builds the mock releases the updater signature tests serve (Linux, macOS,
# Windows run the same cases): one folder per case, each holding the files a
# release would have plus
#   tag     the version the (mock) release API announces
#   expect  "install", "up-to-date" or "refuse:<text the updater must print>"
# Temporary test keys only: KEY_A is the one the tests trust, KEY_B is not.
#
#   signed-release-cases.sh OUT PACKAGE VERSION KEY_A.pem KEY_B.pem
#     PACKAGE  the newer package (its file name is the release asset name)
#     VERSION  the version inside PACKAGE (newer than the installed one)
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${1:?usage}"; PKG="${2:?usage}"; VER="${3:?usage}"; KA="${4:?usage}"; KB="${5:?usage}"
SIGN="$ROOT/scripts/release-sign.sh"
MAN=nivyx-release.manifest
asset="$(basename "$PKG")"
OLD_VER=1.0.0	# a release older than anything installed

sums() { # dir: SHA256SUMS over the packages, as published
	(cd "$1" && for f in nivyx-*.tar.gz nivyx-*.zip; do
		[ -f "$f" ] || continue
		if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f"; else shasum -a 256 "$f"; fi
	done >SHA256SUMS)
}
mkcase() { # name tag expect [manifest-version]
	local d="$OUT/$1"
	mkdir -p "$d"
	cp "$PKG" "$d/$asset"
	"$ROOT/scripts/release-manifest.sh" "${4:-$2}" "$d" test >"$d/.manifest"
	printf '%s\n' "$2" >"$d/tag"
	printf '%s\n' "$3" >"$d/expect"
	sums "$d"
}
finish() { mv "$1/.manifest" "$1/$MAN"; }
sign() { "$SIGN" sign "$2" "$1/$MAN" >/dev/null; }

rm -rf "$OUT"; mkdir -p "$OUT"

# 1. no manifest at all (a release made before signing, or one stripped of it)
mkcase unsigned "$VER" "refuse:is not signed"; rm -f "$OUT/unsigned/.manifest"
# 2. manifest without its signature
mkcase no-signature "$VER" "refuse:is not signed"; finish "$OUT/no-signature"
# 3. manifest changed after it was signed (a hash swapped in)
mkcase modified-manifest "$VER" "refuse:signature is not valid"; finish "$OUT/modified-manifest"
sign "$OUT/modified-manifest" "$KA"
sed "s/^commit test\$/commit tampered/" "$OUT/modified-manifest/$MAN" >"$OUT/modified-manifest/m.tmp"
mv "$OUT/modified-manifest/m.tmp" "$OUT/modified-manifest/$MAN"
# 4. package changed after signing; SHA256SUMS changed to match it (both
#    come from the same place), the signed manifest still has the original
mkcase modified-package "$VER" "refuse:does not match the signed manifest"; finish "$OUT/modified-package"
sign "$OUT/modified-package" "$KA"
printf 'tampered' >>"$OUT/modified-package/$asset"; sums "$OUT/modified-package"
# 5. a valid signature by a key the updater does not trust
mkcase wrong-key "$VER" "refuse:signature is not valid"; finish "$OUT/wrong-key"
sign "$OUT/wrong-key" "$KB"
# 6. a genuinely signed OLD manifest put into a release announced as new
#    (manifest substitution / downgrade under a new tag)
mkcase substituted-manifest "$VER" "refuse:refusing a substituted or replayed release" "$OLD_VER"
finish "$OUT/substituted-manifest"; sign "$OUT/substituted-manifest" "$KA"
# 7. an old, correctly signed release served as "latest" (rollback attack):
#    never installed
mkcase old-release "$OLD_VER" "up-to-date"; finish "$OUT/old-release"; sign "$OUT/old-release" "$KA"
# 8. correct
mkcase valid "$VER" "install"; finish "$OUT/valid"; sign "$OUT/valid" "$KA"

"$SIGN" pubkey "$KA" test-key-a >"$OUT/trusted-keys"
for d in "$OUT"/*/; do
	printf '%s: tag %s, %s\n' "$(basename "$d")" "$(cat "$d/tag")" "$(cat "$d/expect")"
done
