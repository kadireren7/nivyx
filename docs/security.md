# Security, supply chain and privacy

## What is verified, and how

| Item | How it is pinned / verified |
|---|---|
| Release files | the four packages and `SHA256SUMS`, nothing else |
| Build provenance | signed GitHub build-provenance attestations for every release file: `gh attestation verify nivyx-windows-x86_64.zip --repo kadireren7/nivyx` |
| `nivyx update` | downloads only from `github.com/kadireren7/nivyx/releases` (the test override `NIVYX_RELEASE_API` is refused unless it points at 127.0.0.1/localhost), verifies the SHA-256 against the release's `SHA256SUMS` *before* unpacking, refuses archives with links or paths outside the package folder, checks the new engine runs and reports the expected version, then runs the package's installer, which backs up the installed version, restores it if the health check fails and keeps the backup if even that fails |
| WinDivert (Windows) | `scripts/windows/fetch-windivert.sh`: official 2.2.2-A archive, SHA-256 pinned, a different file is refused; shipped unmodified |
| OpenSSL (macOS) | `scripts/macos/build-openssl.sh`: official 3.5.8 source tarball, SHA-256 pinned, built static |
| GitHub Actions | every action pinned to a full commit SHA (with the tag in a comment); `.github/workflows/*.yml` |
| Workflow permissions | CI: `contents: read`. Release: `contents: read` everywhere; the `provenance` job gets `id-token: write` and `attestations: write`; only the `publish` job gets `contents: write`, and it runs only for a pushed `v<VERSION>` tag |
| Release gate | the release workflow runs the whole CI matrix first (builds, unit and sanitizer tests, end-to-end on Linux, Windows and macOS arm64 + Intel, upgrades from v2.1.0 ... v2.4.0, the old updaters refusing the new layout safely), then assembles the release once and tests those exact files again (installed over v2.4.0 on Linux, macOS and Windows; macOS and Windows end-to-end from the final archives) and verifies their provenance; nothing is published unless all of it passed. The Linux package must need at most glibc 2.35 and run on Debian, Ubuntu and openSUSE images |
| Release dry run | `Actions → release → Run workflow`: the same jobs, nothing published (no tag, no release). It does create provenance attestations for the dry-run files, which name the branch, not a tag |

Checksums vs provenance: `SHA256SUMS` comes from the same release as
the files, so it detects a damaged or partial download, not a
compromised release. The signed build-provenance attestation is what
ties a file to this repository's release workflow. You can check it
yourself:

    gh attestation verify nivyx-windows-x86_64.zip --repo kadireren7/nivyx

**Could `nivyx update` check the provenance itself?** Evaluated, not
implemented. The attestation is a Sigstore bundle (a DSSE envelope signed
with a short-lived Fulcio certificate and logged in Rekor). Verifying it
means validating that certificate chain against Sigstore's root (TUF
metadata), the certificate's workflow identity and the transparency-log
inclusion proof. On the machines that run the updater this would need
`gh` (with a GitHub login) or `cosign`, neither of which is installed
there, or a verifier of our own that tracks Sigstore's root rotation —
a large, fast-moving dependency for a tool that otherwise needs only
bash/sh/PowerShell, curl and the system's OpenSSL.

Not implemented either: a separate release signature. A release offers
`SHA256SUMS` (checked by `nivyx update`) and the provenance attestation
(checked by you, with the command above).

OpenSSL configuration on Windows: the engine never loads an OpenSSL
configuration file (`OPENSSL_INIT_NO_LOAD_CONFIG`, `src/tlsclient.c`).
Up to v2.3.0 it did: libssl loads a configuration by default, the MSYS2
OpenSSL it linked honours `OPENSSL_CONF` (verified on real Windows in
CI), and a configuration can load provider DLLs. Where it looks by
default: under wine it was `etc\ssl\openssl.cnf` relative to the current
directory, but on real Windows (CI) a file planted there was **not**
read, so the wine result does not carry over; the real default location
is measured by the update-compat test (see docs/PROGRESS.md). The service
environment and `%ProgramFiles%` are writable by administrators only, so
no privilege escalation in a normal install has been shown; this is
hardening that removes a code-loading path. Linux keeps the
distribution's OpenSSL configuration on purpose (system crypto
policies); macOS's static OpenSSL uses the root-owned `/private/etc/ssl`.

Install-script integrity: the Linux installer builds from the checkout
you made (so you can read exactly what runs as root); Windows/macOS
installers come inside the ZIP whose hash is in `SHA256SUMS`. A
`curl | sudo sh` installer is deliberately not provided: it would have
no integrity check of its own beyond TLS to GitHub.

## Dependency inventory

| Component | Where | Version | Pinned? |
|---|---|---|---|
| Nivyx engine and CLI | this repository | see `VERSION` | — |
| OpenSSL | Linux: system `libssl` (dynamic); macOS: static | system / 3.5.8 | macOS: source hash pinned. Linux: distribution package |
| OpenSSL | Windows: static, built with MinGW (`scripts/windows/build-openssl.sh`) | 3.5.8 (the macOS pin) | yes — official source archive, SHA-256 pinned; CI checks that `nivyx-engine.exe` embeds that version, `scripts/windows/package.sh` refuses to package one that does not. Up to v2.3.0 it was the MSYS2 package current on the build day (v2.3.0: 3.6.4) |
| WinDivert | Windows | 2.2.2-A | SHA-256 pinned |
| MSYS2 / GCC toolchains | CI | runner image | not pinned |

## Reproducible builds

Builds are **not** bit-for-bit reproducible today (embedded paths and
toolchain versions differ between machines; the Windows binary links an
unpinned MSYS2 OpenSSL). To check a release you can: rebuild the tagged
revision (`git checkout v<version>`, `make re`, or the package scripts
in `scripts/*/package.sh`), compare behaviour with `nivyx-engine
--capabilities` and `--version`, and verify the published files against
`SHA256SUMS` and their attestation. Pinning the Windows OpenSSL and
building with fixed toolchains are the open steps toward real
reproducibility.

## Privacy and logging

Nivyx has no telemetry, analytics or remote collection. The only
network connections it makes are the ones you ask for, its DNS-over-HTTPS
resolvers (Cloudflare and Google, see `docs/transparent-mode.md`) and,
on `nivyx update`, GitHub.

What the default log (`nivyx logs`) contains: service lifecycle lines
and a `[learn]`/`[verify]` line for each host the engine had to bypass
(host name and the address used) — hosts that reached directly are not
logged. It never contains URLs, query strings, cookies, tokens, request
bodies or private keys: the engine reads only the TLS server name (SNI)
and never decrypts traffic. Debug logging (opt-in) is more verbose.

What is stored on disk: the learned-decision file (host, network
fingerprint, strategy, timestamp; entries expire after 24 h unless
used; this is required for the bypass to work) and the status file
(counters, plus the last learned host).

`nivyx stats` shows aggregates only. `nivyx support-bundle` masks host
names in log lines and the status file, keeps only a *count* of learned
decisions, and redacts token/key/secret/password-looking values, your
home directory and your user name; `scripts/redaction-test.sh` checks
this in CI.
