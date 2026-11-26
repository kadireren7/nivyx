#ifndef RELEASE_VERIFY_H
# define RELEASE_VERIFY_H

/* ============================================================
 * Release manifest signature check, run by the updaters with the
 * INSTALLED engine before anything downloaded is unpacked or run:
 *
 *   dpi-proxy --verify-release KEYRING MANIFEST SIGNATURE
 *
 * KEYRING    lines "ed25519 <base64 32-byte public key> [comment]"
 * SIGNATURE  lines "ed25519 <key id> <base64 64-byte signature>"
 *            (key id: first 8 bytes of SHA-256(public key), hex)
 * MANIFEST   the exact bytes that were signed (any content; the
 *            updater parses it only after this check passed)
 *
 * Exit 0: at least one signature line by a key in KEYRING verifies
 * over MANIFEST. 1: none does (or a file is malformed). 2: usage or
 * unreadable file. Never loads an OpenSSL configuration file.
 * See docs/release-signing.md.
 * ============================================================ */

int	release_verify_main(const char *keyring, const char *manifest,
		const char *signature);

#endif
