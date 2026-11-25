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
# The Windows build links the MSYS2 OpenSSL package current at build time:
# its exact version is read from the shipped engine itself (OpenSSL embeds
# its version string), so the SBOM states what is really inside.
WIN_OPENSSL="NOASSERTION"
if [ -f "$DIR/nivyx-windows-x86_64.zip" ]; then
	v="$(unzip -p "$DIR/nivyx-windows-x86_64.zip" nivyx-windows-x86_64/dpi-proxy.exe 2>/dev/null \
		| strings | sed -n 's/^OpenSSL \([0-9][0-9.]*[a-z]\{0,1\}\) .*/\1/p' | head -n 1)" || true
	[ -n "$v" ] && WIN_OPENSSL="$v"
fi
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
    {"SPDXID": "SPDXRef-Nivyx", "name": "nivyx", "versionInfo": "$VERSION", "downloadLocation": "git+https://github.com/kadireren7/nivyx@$COMMIT", "filesAnalyzed": false, "licenseConcluded": "MIT", "licenseDeclared": "MIT", "copyrightText": "Copyright (c) 2026 Kadir Eren Altintas"},
    {"SPDXID": "SPDXRef-OpenSSL-macOS", "name": "openssl", "versionInfo": "$OPENSSL_VERSION", "downloadLocation": "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz", "filesAnalyzed": false, "checksums": [{"algorithm": "SHA256", "checksumValue": "$OPENSSL_SHA"}], "licenseConcluded": "Apache-2.0", "licenseDeclared": "Apache-2.0", "copyrightText": "NOASSERTION", "comment": "Statically linked into the macOS binaries; built from this pinned source archive."},
    {"SPDXID": "SPDXRef-WinDivert", "name": "WinDivert", "versionInfo": "$WD_VERSION", "downloadLocation": "https://reqrypt.org/download/WinDivert-$WD_VERSION.zip", "filesAnalyzed": false, "checksums": [{"algorithm": "SHA256", "checksumValue": "$WD_SHA"}], "licenseConcluded": "LGPL-3.0-or-later OR GPL-2.0-only", "licenseDeclared": "LGPL-3.0-or-later OR GPL-2.0-only", "copyrightText": "NOASSERTION", "comment": "Shipped unmodified (signed driver and DLL) in the Windows package."},
    {"SPDXID": "SPDXRef-OpenSSL-Windows", "name": "mingw-w64-x86_64-openssl", "versionInfo": "$WIN_OPENSSL", "downloadLocation": "NOASSERTION", "filesAnalyzed": false, "licenseConcluded": "Apache-2.0", "licenseDeclared": "Apache-2.0", "copyrightText": "NOASSERTION", "comment": "Statically linked into dpi-proxy.exe from the MSYS2 package current at build time (not pinned, see docs/security.md); the version is the one embedded in the shipped binary."},
    {"SPDXID": "SPDXRef-OpenSSL-Linux", "name": "openssl (system libssl.so.3/libcrypto.so.3)", "versionInfo": "NOASSERTION", "downloadLocation": "NOASSERTION", "filesAnalyzed": false, "licenseConcluded": "Apache-2.0", "licenseDeclared": "Apache-2.0", "copyrightText": "NOASSERTION", "comment": "Not shipped: the Linux engine links the distribution's own OpenSSL 3 at run time (OPENSSL_3.0.0 ABI or newer) and glibc 2.35 or newer."}
  ],
  "files": [$files_json
  ],
  "relationships": [
    {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-Nivyx"},
    {"spdxElementId": "SPDXRef-Nivyx", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-OpenSSL-macOS"},
    {"spdxElementId": "SPDXRef-Nivyx", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-WinDivert"},
    {"spdxElementId": "SPDXRef-Nivyx", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-OpenSSL-Windows"},
    {"spdxElementId": "SPDXRef-Nivyx", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-OpenSSL-Linux"}
  ]
}
JSON
