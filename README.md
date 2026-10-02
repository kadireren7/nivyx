<p align="center">
  <img src="assets/logo.svg" width="240" alt="Nivyx">
</p>

<h3 align="center">Lightweight system-wide DPI bypass.</h3>
<p align="center">Linux &middot; Windows &middot; macOS</p>

<p align="center">
  <a href="https://github.com/kadireren7/nivyx/actions/workflows/build.yml"><img src="https://github.com/kadireren7/nivyx/actions/workflows/build.yml/badge.svg" alt="build status"></a>
  <a href="https://github.com/kadireren7/nivyx/releases"><img src="https://img.shields.io/github/v/release/kadireren7/nivyx" alt="latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/platform-Linux%20%7C%20Windows%20%7C%20macOS-informational" alt="platforms">
</p>

Nivyx gets HTTPS traffic past SNI-based DPI (deep packet inspection)
filtering. On Linux, Windows and macOS it runs as a system service:
after one install, blocked sites and apps work in every browser and
application — **automatic and system-wide, with no manual proxy
configuration and no manual DNS configuration**.

It runs entirely on your own machine. It is **not a VPN**, it does not
tunnel through a remote server, and it never decrypts or
man-in-the-middles TLS.

## Platforms

| Platform | What you get | Validation |
|---|---|---|
| Linux | **Transparent automatic mode** | Real ISP/DPI field-tested |
| Windows 10/11 (x64) | **Transparent automatic mode** | Real ISP/DPI field-tested |
| macOS (Apple silicon, Intel) | **Transparent automatic mode** | Real ISP/DPI field-tested |

`nivyx doctor` prints what your install supports.

## Install

### Linux

```bash
git clone https://github.com/kadireren7/nivyx.git
cd nivyx
sudo ./scripts/install.sh
```

[Linux guide](docs/linux.md)

### Windows

1. Download `nivyx-windows-x86_64.zip` from [Releases](https://github.com/kadireren7/nivyx/releases/latest).
2. Extract it.
3. Double-click **Install Nivyx.cmd**.
4. Accept the UAC prompt.

[Windows guide](docs/windows.md)

### macOS

1. Download the correct ZIP from [Releases](https://github.com/kadireren7/nivyx/releases/latest):
   - Apple silicon (M1/M2/M3/M4/...): `nivyx-macos-arm64.zip`
   - Intel Mac: `nivyx-macos-x86_64.zip`
2. Extract it.
3. Double-click **Install Nivyx.command**.
4. Enter your password when asked.

[macOS guide](docs/macos.md)

Each installer checks DNS and HTTPS through the service before it
finishes, enables it at boot, and ends with `Nivyx is running.` —
nothing to configure afterwards. Before installing, stop other DPI
tools or VPN packet filters (`nivyx doctor` after install checks for
the ones it can detect).

Release files can be verified: every release ships `SHA256SUMS`, an
SPDX SBOM and signed build provenance (`gh attestation verify <file>
--repo kadireren7/nivyx`). Piping a downloaded script into a root shell
is deliberately not offered: the Linux installer builds from the source
you cloned, so you can read what it runs.

## Downloads

Most people need just one file: the Windows ZIP, or the macOS ZIP for their Mac. On Linux, use the install steps above.

| File | For |
|---|---|
| `nivyx-linux-x86_64` | Linux x86_64 standalone engine binary |
| `nivyx-linux-x86_64.tar.gz` | Linux packaged build used by `nivyx update` |
| `nivyx-windows-x86_64.zip` | Windows 10/11 x64 |
| `nivyx-macos-arm64.zip` | Apple silicon Macs |
| `nivyx-macos-x86_64.zip` | Intel Macs |
| `SHA256SUMS` | SHA-256 integrity verification |
| `nivyx-2.2.x.spdx.json` | SBOM / dependency inventory |

An SBOM is a machine-readable list of software components and dependencies. You only need it, `SHA256SUMS` or the source archives if you want to verify a download or develop Nivyx.

GitHub also automatically provides *Source code (zip)* and *Source code (tar.gz)*. These are source archives for developers, not normal installation packages.

## Usage

One command, the same on every platform (`start`/`stop`/`restart`/
`reload`/`repair`/`update` need root/Administrator):

```
$ nivyx status
Nivyx 2.2.0
Service: Running
Protection: Active
DNS: Healthy
Mode: Transparent
Bypassed: 128
Failures: 0
```

<p align="center">
  <img src="assets/nivyx-terminal.svg" width="560" alt="nivyx status and nivyx doctor sample output">
</p>

```
nivyx status [--verbose]    # short summary / full detail
nivyx doctor                # read-only health checks (PASS/WARN/FAIL)
nivyx diagnose discord.com  # DNS, HTTPS and the stored decision for one site
nivyx stats                 # local counters (no browsing history)
nivyx logs 50
nivyx config show|path|check|set|unset   # manual rules, safely
nivyx repair                # fix Nivyx-owned state (service, stale rules, files)
nivyx update [--check]      # verified self-update with automatic rollback
nivyx support-bundle        # local diagnostics archive, redacted, no telemetry
nivyx restart | stop        # (root/Administrator)
nivyx help [command]
```

Full reference, including exactly what `doctor` checks, what `repair`
touches and what `support-bundle` redacts: [docs/cli.md](docs/cli.md).
Linux and macOS also install `man nivyx` and tab completion; PowerShell
completion ships as `nivyx-completion.ps1`.

Output is colored on a terminal (green/yellow/red for
healthy/warning/failed) and plain when piped, redirected, or when
[`NO_COLOR`](https://no-color.org) is set.

Optional manual rules go in `strategy.conf` (`nivyx config path`,
e.g. `nivyx config set example.com tlsrec`); none are needed —
known-blocked services get the bypass automatically, other sites are
tried directly first and only bypassed if they need it. Manual rules
always win over automatic learning and are never changed unless you
ask.

## Limitations

- **Not a VPN.** Traffic leaves from your own connection with your own
  IP address. Sites blocked by IP address, or services that block your
  region, are not reachable this way.
- **HTTPS and DNS only.** Other UDP traffic — voice and video calls,
  game traffic — is not touched (e.g. Discord text and media work,
  voice may not).
- **Network-dependent.** DPI systems differ between ISPs and change
  over time; this bypasses DPI that inspects the TLS server name
  without reassembling TLS records, not every censorship system.
- **One interceptor at a time.** Don't run another transparent DPI
  tool (dpi-bypass, GoodbyeDPI, zapret, …) alongside it — `nivyx
  doctor` and the service itself warn if they detect one.
- **Field-tested, not exhaustively validated.** All three platforms
  are end-to-end tested in CI on real runners, and field-tested
  against real ISP-level DPI (Windows and macOS each on one physical
  machine); not yet validated across a wide range of consumer hardware
  and networks. Platform-specific details and limitations:
  [docs/windows.md](docs/windows.md), [docs/macos.md](docs/macos.md).

## Uninstall

Linux: `sudo ./scripts/uninstall.sh` (details: [docs/linux.md](docs/linux.md)).
Windows: double-click `Uninstall Nivyx.cmd` (details: [docs/windows.md](docs/windows.md)).
macOS: double-click `Uninstall Nivyx.command` (details: [docs/macos.md](docs/macos.md)).

## Documentation

- [docs/cli.md](docs/cli.md) — full `nivyx` command reference.
- [docs/linux.md](docs/linux.md), [docs/windows.md](docs/windows.md),
  [docs/macos.md](docs/macos.md) — platform-specific install, commands,
  files, troubleshooting, and how each one touches the system
  (nftables / WinDivert / PF).
- [docs/transparent-mode.md](docs/transparent-mode.md) — how the
  engine works (all platforms): DNS, the decision ladder, fail-open,
  operation.
- [docs/development.md](docs/development.md) — building, tests,
  sanitizers, CI.
- [docs/performance.md](docs/performance.md) — package size breakdown
  and measured resource use, per platform;
  [docs/performance-v2.2.md](docs/performance-v2.2.md) — v2.1 vs v2.2.
- [docs/security.md](docs/security.md) — release trust, dependencies,
  SBOM, provenance, privacy and logging.
- [docs/packet-mode.md](docs/packet-mode.md),
  [docs/architecture.md](docs/architecture.md),
  [docs/discovery.md](docs/discovery.md),
  [docs/network-profiles.md](docs/network-profiles.md) — the optional
  packet-mode engine (Linux, advanced).

## License

MIT — see [LICENSE](LICENSE).
