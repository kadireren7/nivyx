#!/usr/bin/env bash
# Writes the release manifest (the file the maintainer signs, see
# docs/release-signing.md) for every file in a release folder:
#
#   release-manifest.sh <version> <release-dir> [commit] > nivyx-release.manifest
#
# Format (one item per line, LF):
#   nivyx-release-manifest 1
#   product nivyx
#   version <x.y.z>
#   commit <git revision>
#   sha256 <hex> <file name>        one per release file, sorted by name
# SHA256SUMS, the manifest itself and its signature are not listed.
set -euo pipefail
VERSION="${1:?usage: release-manifest.sh <version> <release-dir> [commit]}"
DIR="${2:?usage: release-manifest.sh <version> <release-dir> [commit]}"
COMMIT="${3:-$(git -C "$(dirname -- "$0")" rev-parse HEAD 2>/dev/null || echo unknown)}"

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.]+)?$ ]] || { echo "release-manifest: not a release version: $VERSION" >&2; exit 1; }

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

printf 'nivyx-release-manifest 1\nproduct nivyx\nversion %s\ncommit %s\n' "$VERSION" "$COMMIT"
n=0
while IFS= read -r f; do
	case "$f" in
	SHA256SUMS | nivyx-release.manifest | nivyx-release.manifest.sig) continue ;;
	*[[:space:]]*) echo "release-manifest: file name with spaces: $f" >&2; exit 1 ;;
	esac
	[ -f "$DIR/$f" ] || continue
	printf 'sha256 %s %s\n' "$(sha256_of "$DIR/$f")" "$f"
	n=$((n + 1))
done < <(LC_ALL=C ls "$DIR" | LC_ALL=C sort)
[ "$n" -gt 0 ] || { echo "release-manifest: no files in $DIR" >&2; exit 1; }
