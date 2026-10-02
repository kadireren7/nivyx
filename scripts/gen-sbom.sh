#!/usr/bin/env bash
# Writes an SPDX 2.3 JSON SBOM for a release: the Nivyx source revision, the
# third-party components that end up in the shipped binaries (versions and
# hashes are the ones the build scripts pin), and the release files with
# their SHA-256.
#   gen-sbom.sh <version> <release-dir> > nivyx-<version>.spdx.json
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="${1:?usage: gen-sbom.sh <version> <release-dir>}"
DIR="${2:?usage: gen-sbom.sh <version> <release-dir>}"

pin() { sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$1" | head -n 1; }
OPENSSL_VERSION="$(pin "$ROOT/scripts/macos/build-openssl.sh" VERSION)"
OPENSSL_SHA="$(pin "$ROOT/scripts/macos/build-openssl.sh" SHA256)"
WD_VERSION="$(pin "$ROOT/scripts/windows/fetch-windivert.sh" VERSION)"
WD_SHA="$(pin "$ROOT/scripts/windows/fetch-windivert.sh" SHA256)"
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo NOASSERTION)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

files_json=""
sep=""
for f in "$DIR"/*; do
	[ -f "$f" ] || continue
	case "$(basename "$f")" in *.spdx.json) continue ;; esac
	sum="$(sha256sum "$f" | cut -d' ' -f1)"
	files_json="$files_json$sep
    {\"SPDXID\": \"SPDXRef-File-$(basename "$f" | tr -c 'A-Za-z0-9.-' '-')\", \"fileName\": \"./$(basename "$f")\", \"checksums\": [{\"algorithm\": \"SHA256\", \"checksumValue\": \"$sum\"}], \"licenseConcluded\": \"NOASSERTION\", \"copyrightText\": \"NOASSERTION\"}"
	sep=","
done

cat <<JSON
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "nivyx-$VERSION",
  "documentNamespace": "https://github.com/kadireren7/nivyx/releases/tag/v$VERSION/sbom-$COMMIT",
  "creationInfo": {"created": "$NOW", "creators": ["Tool: nivyx scripts/gen-sbom.sh"]},
  "packages": [
    {"SPDXID": "SPDXRef-Nivyx", "name": "nivyx", "versionInfo": "$VERSION", "downloadLocation": "git+https://github.com/kadireren7/nivyx@$COMMIT", "filesAnalyzed": false, "licenseConcluded": "NOASSERTION", "licenseDeclared": "NOASSERTION", "copyrightText": "NOASSERTION"},
    {"SPDXID": "SPDXRef-OpenSSL-macOS", "name": "openssl", "versionInfo": "$OPENSSL_VERSION", "downloadLocation": "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz", "filesAnalyzed": false, "checksums": [{"algorithm": "SHA256", "checksumValue": "$OPENSSL_SHA"}], "licenseConcluded": "Apache-2.0", "licenseDeclared": "Apache-2.0", "copyrightText": "NOASSERTION", "comment": "Statically linked into the macOS binaries; built from this pinned source archive."},
    {"SPDXID": "SPDXRef-WinDivert", "name": "WinDivert", "versionInfo": "$WD_VERSION", "downloadLocation": "https://reqrypt.org/download/WinDivert-$WD_VERSION.zip", "filesAnalyzed": false, "checksums": [{"algorithm": "SHA256", "checksumValue": "$WD_SHA"}], "licenseConcluded": "LGPL-3.0-or-later OR GPL-2.0-only", "licenseDeclared": "LGPL-3.0-or-later OR GPL-2.0-only", "copyrightText": "NOASSERTION", "comment": "Shipped unmodified (signed driver and DLL) in the Windows package."},
    {"SPDXID": "SPDXRef-OpenSSL-Windows", "name": "mingw-w64-x86_64-openssl", "versionInfo": "NOASSERTION", "downloadLocation": "NOASSERTION", "filesAnalyzed": false, "licenseConcluded": "Apache-2.0", "licenseDeclared": "Apache-2.0", "copyrightText": "NOASSERTION", "comment": "MSYS2 package current at build time; its version is not pinned (see docs/security.md)."}
  ],
  "files": [$files_json
  ],
  "relationships": [
    {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Nivyx"},
    {"spdxElementId": "SPDXRef-Nivyx", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-OpenSSL-macOS"},
    {"spdxElementId": "SPDXRef-Nivyx", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-WinDivert"},
    {"spdxElementId": "SPDXRef-Nivyx", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-OpenSSL-Windows"}
  ]
}
JSON
