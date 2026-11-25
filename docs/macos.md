# macOS

macOS transparent mode works the same way as on Linux: the built-in
macOS packet filter (PF) sends this Mac's HTTPS and DNS to the local
`dpi-proxy` service. It passes the full automated end-to-end test on
real macOS GitHub runners (macOS 14, 15 and 26 on Apple silicon,
macOS 15 on Intel; real PF and launchd, root), and has been field-
tested on a physical Mac against real ISP-level DPI in Turkey:
DPI-blocked sites (Discord and others) opened normally with system-
wide transparent mode, with no manual proxy or DNS configuration. It
has not yet been validated across a wide range of consumer hardware
and networks. Field reports are welcome.

## Quick start

1. Download **`nivyx-macos-arm64.zip`** (Apple silicon:
   M1/M2/M3/…) or **`nivyx-macos-x86_64.zip`** (Intel Macs) from
   [Releases](https://github.com/kadireren7/nivyx/releases)
   and double-click it to extract it.
2. Double-click **`Install Nivyx.command`**. It opens in Terminal and
   asks for your Mac password (sudo) — that is expected, it is
   installing a system service. If macOS says the file is "from an
   unidentified developer", right-click (or Control-click) it and
   choose *Open* once instead of double-clicking.
   (Advanced/manual: `cd` into the extracted folder and run
   `sudo ./install.sh`.)
3. Check it: `nivyx status` in any Terminal window — you should see
   `Service: Running` and `Protection: Active`.
4. Use Safari, Chrome, Firefox, Discord, … normally. No proxy
   settings, no manual DNS changes, no per-app configuration.

The ZIP contains everything (`dpi-proxy`, `nivyx`, `Install Nivyx.command`,
`Uninstall Nivyx.command`, `install.sh`, `uninstall.sh`, the launchd
job, the man page and zsh completion, LICENSE, `MACOS-QUICKSTART.txt`); no Xcode, Homebrew, Git or
Python is needed. Before testing, quit SpoofDPI, ByeDPI, zapret and
VPN apps that filter traffic (`nivyx doctor` checks for the ones it
can detect).

## Commands

```sh
nivyx status
nivyx status --verbose       # full detail, PF rule counts
nivyx doctor                 # health checks, PASS/WARN/FAIL
nivyx diagnose discord.com   # DNS + HTTPS check for one site
nivyx logs 50
nivyx support-bundle         # local diagnostics .tar.gz, redacted, no telemetry
sudo nivyx stop              # normal internet, no bypass (until start/reboot)
sudo nivyx start
sudo nivyx restart
```

See [cli.md](cli.md) for the full
command reference (shared across platforms).

Files: `/usr/local/bin/dpi-proxy`, `/usr/local/bin/nivyx`,
`/Library/LaunchDaemons/io.github.kadireren7.dpi-proxy.plist`,
`/usr/local/etc/dpi-proxy/strategy.conf`, log `/var/log/dpi-proxy.log`.

## Uninstall

Double-click **`Uninstall Nivyx.command`** in the extracted folder, or
manually: `sudo ./uninstall.sh`. Removes the service, the programs and
Nivyx's PF rules, and releases its PF reference; PF, `/etc/pf.conf` and
every other rule are left exactly as they were. Your settings
(`/usr/local/etc/dpi-proxy`), learned decisions
(`/usr/local/var/dpi-proxy`) and log are **kept**, so a reinstall picks
them up; `sudo ./uninstall.sh --purge` removes them too.

Both `.command` launchers and both scripts exit with the real result
(0 = done). A reinstall or upgrade that fails its health check puts the
previous installation (programs, plist, launchd job) back and starts it
(exit 4); a fresh install that fails is removed again. If even that
fails, the installer exits 5 and keeps its backup in
`/private/var/tmp/nivyx-install-backup.*`.

Gatekeeper: the binaries are not notarized (there is no Apple Developer
ID certificate behind this project). macOS may ask you to confirm
opening `Install Nivyx.command` (right click → Open). The installer
then copies the two programs it installs without the download's
quarantine flag; it no longer strips that flag from the whole extracted
folder. Opening `dpi-proxy` itself from Finder only starts a plain
SOCKS5 proxy and says so: use the `.command` launchers.

## How it touches the system

All rules live in dpi-proxy's own PF anchor (`com.apple/dpi-proxy`);
`/etc/pf.conf` is never edited and other PF rules are never touched.
If the service stops, crashes or hangs, a watchdog process removes the
rules (immediately, or within 30 seconds for a hang), so the internet
keeps working, just unbypassed. Details:
[transparent-mode.md](transparent-mode.md#macos).

## Limitations specific to macOS

- Field-tested against real ISP DPI on one physical Mac (real home
  network in Turkey); not yet validated across a wide range of
  consumer hardware, networks or ISPs (CI machines remain virtual
  machines on Apple hardware).
- DNS servers with IPv6 link-local addresses (`fe80::…`) are not
  intercepted; if a network hands out only such a resolver, names are
  resolved by it unprotected.
- A custom `/etc/pf.conf` without Apple's `com.apple/*` anchor hooks is
  not supported (the service says so and does not start).

See also: [../README.md](../README.md) for the platform-independent
limitations, and [transparent-mode.md](transparent-mode.md) for how
the engine itself works.

## SOCKS5 mode

`dpi-proxy` run without arguments is still a plain local SOCKS5 proxy
on `127.0.0.1:1080` (`DPI_PROXY_SPLIT_TLS=record ./dpi-proxy` for the
bypass) — on every platform, not just macOS.
