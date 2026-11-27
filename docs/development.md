# Development

Building, testing, and CI for Nivyx. For how the engine works
internally, see [docs/architecture.md](architecture.md) and
[docs/transparent-mode.md](transparent-mode.md).

## SOCKS5 proxy details

- Listens on `127.0.0.1:1080` by default.
- SOCKS5 address types supported: `0x01` (IPv4), `0x03` (DOMAIN),
  `0x04` (IPv6).
- Only TCP `CONNECT` is supported (no UDP).
- TLS is not intercepted or decrypted (no MITM) — same property as
  packet mode, see [docs/architecture.md](architecture.md).

## CLI reference

`nivyx-engine` (SOCKS5 proxy, all platforms):

```
nivyx-engine [--listen HOST:PORT] [--log-level error|info]
          [--capabilities] [--version] [--help]
```

`nivyx-packet-engine` (Linux packet mode) has its own reference in
[docs/packet-mode.md](packet-mode.md#cli-reference).

Both binaries print an actionable message (not a bare error code) on
common startup failures: an address already in use, a malformed
strategy config (with the offending line number), missing
`libnetfilter-queue-dev`, or missing `nft`/capabilities.

## Building from source

```sh
# Linux — SOCKS5 proxy + transparent mode (needs libssl-dev)
# macOS — the same, if OpenSSL is found (Homebrew's openssl@3 by
#         default, or OPENSSL_PREFIX=...); otherwise SOCKS5 only
make fclean && make
./nivyx-engine
```

```sh
# macOS release build: static OpenSSL 3.5 LTS (SHA-256-pinned source),
# binary depends on macOS system libraries only, runs on macOS >= 11
export MACOSX_DEPLOYMENT_TARGET=11.0
./scripts/macos/build-openssl.sh "$PWD/../openssl-$(uname -m)"
make fclean && make OPENSSL_PREFIX="$PWD/../openssl-$(uname -m)" OPENSSL_STATIC=1
./scripts/macos/package.sh nivyx-macos-$(uname -m)   # the package folder
```

```sh
# Linux — packet mode (see docs/packet-mode.md)
make packet-mode
```

```sh
# Windows, cross-compiled from Linux/macOS with mingw-w64
# requires the toolchain, e.g. `apt install mingw-w64`
make windows
```

`make windows` produces a statically linked `nivyx-engine.exe` that runs
on a plain Windows machine without extra runtime DLLs.

## Tests

```sh
make test        # unit tests, plain build
make sanitize     # same unit tests, forced clean rebuild under ASan+UBSan
```

`make sanitize` always runs `make clean` first — if it didn't, stale
plain `.o` files from a prior `make test` could slip through
uninstrumented. `make packet-mode` does the same for the reverse
direction (a prior `make sanitize` leaving instrumented `.o` files that
would otherwise get linked into `nivyx-packet-engine` unsanitized) — see
the comment above the `packet-mode` target in the `Makefile` if you're
touching either.

`test_nft_rules` only exercises its unprivileged-failure path when run
as a normal user; running `make test` as root additionally exercises
the real `nft` success path.

## CI

`.github/workflows/build.yml` runs on every push/PR:

- `linux`, `windows`: `make re` (or `make windows`) + a smoke
  test (SOCKS5 proxy against a real `curl` request) + `--version`/
  `--capabilities`/`--help` CLI checks.
- `macos` (arm64 on macos-15, x86_64 on macos-15-intel): the release
  build (static OpenSSL), `make test`, `make sanitize`, binary checks
  (architecture, minimum macOS version, system-only libraries), SOCKS5
  smoke test, and the zipped test package as an artifact.
- `macos-e2e` (macOS 15, 26 on Apple silicon; 15 on Intel; the macOS 14 runner is retired - its jobs were cancelled unrun): the
  zipped package extracted and installed as a tester would, then
  `scripts/macos/e2e-test.sh`: real PF interception, original
  destination recovery, DoH, QUIC reject table, IPv6 (where the
  runner has it), no loop, forced bypass, ctl, restart, stop, SIGKILL
  and SIGSTOP fail-open, launchd restart, uninstall leaving nothing
  behind, clean reinstall.
- `linux-e2e`, and the Windows job's end-to-end step: the same
  lifecycle for Linux and Windows.
- `sanitize`: `make sanitize`.
- `packet-mode-compile`: installs real `libnetfilter-queue-dev` +
  `nftables` via `sudo apt-get`, runs `make packet-mode`, and runs
  `./nivyx-packet-engine --capabilities` (read-only — does not apply
  nftables rules or bind a live NFQUEUE; GitHub-hosted runners aren't a
  confirmed-reliable place to do that; live verification is done on
  real machines with `scripts/field-test-linux.sh`).
- `sanitize-then-packet-mode`: runs `make sanitize` immediately
  followed by `make packet-mode` in one workspace — regression
  coverage for the stale-object-file class of bug described above.

## Release builds

A release (from v2.4.1) is exactly five files: `nivyx-windows-x86_64.zip`,
`nivyx-macos-arm64.zip`, `nivyx-macos-x86_64.zip`,
`nivyx-linux-x86_64.tar.gz` and `SHA256SUMS`. Each package has the same
top level — the Install / Update / Uninstall launchers, the `nivyx`
command, `QUICKSTART.txt` — and a `files/` folder with the engine and
the scripts the launchers run (`scripts/*/package.sh`,
`scripts/package-linux.sh`). Every package is built only after it passed
its platform's end-to-end test (packet mode is Linux-only and built
from source, not released).

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

`nivyx-engine --version` reports the version baked in at build time
(from the repo's `VERSION` file) — it will match the release tag for any
official build; `nivyx update` relies on that.

### Release workflow and dry run

`.github/workflows/release.yml` has one path for both modes:

- **release**: push the tag `v<VERSION>` (it must equal `VERSION`);
- **dry run**: `Actions → release → Run workflow` (or `gh workflow run
  release.yml --ref <branch>`); nothing is published.

Jobs: `preflight` (version and mode) → `ci` (the whole `build.yml`
matrix as a reusable workflow; its artifacts are the release packages) →
`assemble` (the exact release set, consistency and package layout
checks; stored as the `release-assets` artifact) → `final-linux`,
`final-macos` (arm64, Intel), `final-windows` (the final files installed
over v2.4.0, whose own updater must refuse them; macOS and Windows
end-to-end from the final archives) and `provenance` (attest and verify
every file) → `publish`. Only `publish` can write repository contents;
it runs only for a pushed `v*` tag (job condition and a guard step). The
dry run's `release-assets` artifact holds exactly the files a release
would publish.

## Optional: TLS ClientHello splitting in the SOCKS5 proxy

Separate from packet mode's `SPLIT` strategy. Set
`DPI_PROXY_SPLIT_TLS=1` before starting the SOCKS5 proxy to make it
split the first TLS ClientHello across two TCP segments, mid-hostname:

```sh
DPI_PROXY_SPLIT_TLS=1 ./nivyx-engine
```

**It's off by default because testing showed it reliably breaks the
handshake against at least Cloudflare-fronted hosts** (the upstream
server closes the connection right after the split write), while
leaving other hosts unaffected. Enable it only if you've verified it
actually helps for the sites you care about, on your own network —
otherwise it will make things worse, not better.

## Internal identifiers

`nivyx` is the only public command, and since v2.4.1 every platform uses
the nivyx names:

| | Linux | macOS | Windows |
|---|---|---|---|
| service | `nivyx` (`nivyx-packet`) | launchd `io.github.kadireren7.nivyx` | `nivyx` |
| engine | `/usr/local/bin/nivyx-engine` | `/usr/local/bin/nivyx-engine` | `%ProgramFiles%\Nivyx\nivyx-engine.exe` |
| settings, state | `/etc/nivyx`, `/var/lib/nivyx`, `/run/nivyx` | `/usr/local/etc/nivyx`, `/usr/local/var/nivyx`, `/var/run/nivyx` | `%ProgramData%\Nivyx` |
| interception | nftables `dpi_proxy_tp` | PF anchor `com.apple/nivyx` | WinDivert, firewall rule `nivyx` |

Installs with the earlier `dpi-proxy` names (Linux before v2.3, macOS and
Windows before v2.4.1) are moved by the installer, keeping settings and
learned state; the old service is started again if the new one fails
its health check. The `dpi-proxy` names remain only in that migration
code, in the uninstallers (to clean up leftovers) and in the upgrade
tests. Unchanged on purpose: the nftables table names (`dpi_proxy_tp`,
`dpi_proxy`, deleted by name by every uninstaller) and the `DPI_PROXY_*`
environment overrides (used by the units and tests); `dpictl` /
`dpi-proxy-ctl` appear only in v2.1 cleanup code.

## CLI tests

- `scripts/parity-test.sh` — the same commands are dispatched, documented
  and completed on all three platforms (list: `scripts/commands.txt`);
  no legacy command files exist.
- `scripts/redaction-test.sh` — support-bundle redaction.
- `scripts/e2e-test-linux.sh`, `scripts/macos/e2e-test.sh`,
  `scripts/windows/e2e-test.ps1` — full lifecycle on the real platform,
  including `stats`, `config`, `diagnose`, `repair` (with injected
  breakage), and `update` against a local mock release server
  (`NIVYX_RELEASE_API`): wrong checksum, a release that cannot start
  (rolled back), and a good release.
- `scripts/macos/update-test.sh`, `scripts/windows/update-compat-test.ps1`,
  `scripts/update-compat-test-linux.sh` — an older release's own updater
  (as released) refuses the new package layout and changes nothing; the
  candidate's installer then moves the install over (settings and learned
  state kept); on macOS the candidate's updater also rolls back a release
  that cannot start.
- `scripts/upgrade-test-linux.sh`, `scripts/macos/upgrade-test.sh`,
  `scripts/windows/upgrade-test.ps1` — a real older install (tagged
  source / the published ZIP, checksum-verified) upgraded in place.
