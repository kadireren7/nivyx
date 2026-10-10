# Linux

Linux transparent mode is the original, most mature platform here:
nftables redirects outgoing HTTPS and DNS to the local `dpi-proxy`
service, which applies DNS-over-HTTPS, TLS record fragmentation and
per-network learning. Real ISP/DPI field-tested.

## Install

```sh
git clone https://github.com/kadireren7/nivyx.git
cd nivyx
sudo ./scripts/install.sh
```

On Debian and Ubuntu (and derivatives) the installer installs whatever
is missing — compiler and `make` (`build-essential`), `nftables`,
`openssl`, the OpenSSL headers (`libssl-dev`), `pkg-config`, `curl` —
with `apt-get` in non-interactive mode. It installs only what is absent,
runs `apt-get update` only if a package can't be installed from the
current lists, never edits your package sources and never removes
packages. Then it builds from source, installs the
`dpi-proxy-transparent` systemd service, starts it, checks DNS and HTTPS
through it, and enables it at boot. Nothing to configure afterwards.
If another transparent DPI tool (e.g. `dpi-bypass`) is active, the
installer warns but still installs; stop one of them, running two at
once breaks both.

If package installation fails (no network, broken sources), the
installer stops before changing anything, prints the `apt-get` command to
run by hand and exits. Your internet is untouched, and an existing Nivyx
install keeps running as it was. Re-run the installer after fixing it.

Supported: **systemd + nftables based Linux distributions** (Debian,
Ubuntu, Arch, Fedora, openSUSE, ...). On those other than Debian/Ubuntu
the installer works as-is when the dependencies are already installed
(C compiler and `make`, `nftables`, `openssl` with development headers,
systemd); if something is missing it lists it and stops without running
any package manager — install it yourself and re-run. Distributions
without systemd (OpenRC, runit, Slackware, ...) are not supported by the
installer, because the service integration depends on systemd.

There is no standalone Linux download: use the installer above.

## Commands

```sh
nivyx status                # short summary
nivyx status --verbose      # full detail (nft counters as root)
nivyx doctor                # health checks, PASS/WARN/FAIL
nivyx diagnose discord.com  # DNS + HTTPS check for one site
nivyx logs 50
nivyx support-bundle        # local diagnostics archive, redacted, no telemetry
nivyx strategy discord.com  # what applies to a site right now
nivyx stats                 # local counters (no browsing history)
nivyx config check          # validate manual rules (config set/unset/show/path)
sudo nivyx repair           # fix Nivyx-owned state (service, stale nft table, files)
sudo nivyx update           # verified update with automatic rollback (--check: look only)
sudo nivyx restart
sudo nivyx stop              # until next start/boot
```

See [cli.md](cli.md) for the full
command reference (shared across platforms).

Optional manual rules go in `/etc/dpi-proxy/strategy.conf` (e.g.
`example.com = tlsrec`); none are needed.

Files: `/usr/local/bin/dpi-proxy`, `/usr/local/bin/nivyx`,
`/etc/dpi-proxy/strategy.conf`, `/var/lib/dpi-proxy/tp-decisions.conf`
(learned decisions), status file and nftables table `inet
dpi_proxy_tp`, systemd unit `dpi-proxy-transparent.service`. Logs go
to the journal: `journalctl -u dpi-proxy-transparent`
(`DPI_PROXY_LOG_LEVEL=debug` in the unit for a line per connection).

## Update / uninstall

```sh
git pull && sudo ./scripts/install.sh   # rebuilds and restarts; config kept
sudo nivyx update                       # verified binary update from the latest release
sudo ./scripts/uninstall.sh             # removes service, binaries, nftables table
sudo ./scripts/uninstall.sh --purge     # ...and /etc/dpi-proxy
```

Re-running the installer is safe: it keeps `/etc/dpi-proxy/strategy.conf`
and learned state, and does not reinstall packages that are present.
Uninstalling does not remove the packages the installer added.

## Troubleshooting

```sh
nivyx doctor                    # service/interception/DNS/reachability/conflicts
nivyx diagnose discord.com      # DNS + HTTPS for one site
nivyx logs 100
nivyx support-bundle            # redacted archive to attach to a bug report
```

`doctor` also flags other known DPI tools (`dpi-bypass`, zapret's
`nfqws`, GoodbyeDPI) and VPN/tunnel interfaces that might interfere,
without disabling anything it finds — stop the other one yourself.

## Packet mode (optional, advanced)

An older NFQUEUE-based engine (`dpi-proxy-packet`, strategies
`split`/`disorder`/`fake`/`fragment`) is still included for
experimentation: `sudo ./scripts/install.sh --packet` builds it
(needs `libnetfilter-queue-dev`) but does not start it. Transparent
mode replaces it as the automatic engine. See
[packet-mode.md](packet-mode.md).

## SOCKS5 mode

`dpi-proxy` run without arguments is a plain local SOCKS5 proxy on
`127.0.0.1:1080` (`DPI_PROXY_SPLIT_TLS=record ./dpi-proxy` for the
bypass) — on every platform, not just Linux.

See also: [../README.md](../README.md) for the platform-independent
limitations, and [transparent-mode.md](transparent-mode.md) for how
the engine itself works.
