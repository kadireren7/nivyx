# Release checklist: physical-device validation

CI (GitHub-hosted runners) covers a lot, but every runner is a clean
virtual machine on a data-centre network with no antivirus, no user, no
sleep and no DPI. This checklist is for the tests that need **real
machines**. Nothing in it has been done for the current candidate unless a
tester records it below; CI results are not physical-device results.

Use the dry-run packages (`Actions → release → Run workflow`, artifact
`release-assets`) or the draft release. Record for every machine: OS
version and build, CPU architecture, antivirus/security software, network
(ISP/country, VPN), the package file names and `sha256sum` of what you
installed, the date, and each step's result.

## What CI already verifies (do not repeat unless it fails on a device)

| Area | CI evidence (build.yml / release.yml) |
|---|---|
| Build, unit tests, ASan/UBSan, TSan (instrumented OpenSSL) | linux, sanitize, engine-sanitizers, macos, windows |
| TLS certificate and hostname verification | `tls-verify-test.sh` (linux, linux-arm64, sanitizers) |
| Install → intercept → bypass → crash → repair → uninstall | linux-e2e, linux-arm64, macos-e2e (15, 26, Intel), windows |
| One admin operation at a time | the three e2e suites |
| Failed install/upgrade restores the previous version | the three e2e suites, upgrade tests |
| Upgrades from v2.1.0 ... v2.4.0 (moved to the nivyx names, settings kept) | linux-upgrade, macos-upgrade, macos-update, windows-upgrade |
| Old releases' own updaters refuse the new layout and change nothing | Linux v2.4.0; Windows v2.2.2/v2.4.0; macOS v2.2.2/v2.4.0 (arm64 + Intel) |
| Package top level is exactly the launchers, `nivyx`, `QUICKSTART.txt` and `files/` | the e2e suites, check-linux-package.sh, release.yml assemble |
| Final release files (exact bytes) | release.yml final-linux / final-macos / final-windows |
| Linux package runs on Debian 12, Ubuntu 22.04/24.04, openSUSE | linux-package-distros |
| Windows elevation: failure classification, exit-code passthrough | windows e2e (the UAC prompt itself: **not** testable in CI) |

Not covered by CI at all: UAC and Gatekeeper prompts, antivirus, macOS
11–14, real ISPs with DPI, Wi-Fi changes, sleep/resume, VPNs, long uptime,
consumer hardware (incl. Raspberry Pi), and the release-signing ceremony.

## Common log collection

Collect these whenever a step fails (attach them to the report):

| | Linux | macOS | Windows (elevated PowerShell) |
|---|---|---|---|
| Version | `nivyx version` | `nivyx version` | `nivyx version` |
| State | `nivyx status --verbose` | `nivyx status --verbose` | `nivyx status --verbose` |
| Checks | `nivyx doctor` | `nivyx doctor` | `nivyx doctor` |
| Log | `journalctl -u nivyx -n 200 --no-pager` | `sudo tail -n 200 /var/log/nivyx.log` | `Get-Content $env:ProgramData\Nivyx\nivyx.log -Tail 200` |
| Everything, redacted | `nivyx support-bundle` | `nivyx support-bundle` | `nivyx support-bundle` |
| Interception rules | `sudo nft list table inet dpi_proxy_tp` | `sudo pfctl -a com.apple/nivyx -s nat` | `Get-Service nivyx, WinDivert` |

`support-bundle` masks host names, tokens, the home directory and the user
name; check it before sharing anyway.

## Configuration and state preservation (every platform)

Before each install/update/uninstall test, add a manual rule and note the
learned state:

| | Config file | Learned state |
|---|---|---|
| Linux | `/etc/nivyx/strategy.conf` | `/var/lib/nivyx/tp-decisions.conf` |
| macOS | `/usr/local/etc/nivyx/strategy.conf` | `/usr/local/var/nivyx/tp-decisions.conf` |
| Windows | `%ProgramData%\Nivyx\strategy.conf` | `%ProgramData%\Nivyx\tp-decisions.conf` |

1. `sudo nivyx config set example.com tlsrec` (Windows: elevated, without
   `sudo`).
2. Record `sha256sum` (macOS `shasum -a 256`, Windows `Get-FileHash`) of
   the config file and `wc -l` of the learned-state file.
3. After the operation: the config hash is identical, `nivyx strategy
   example.com` still names the manual rule, the learned-state file still
   exists with about the same number of lines (entries expire after 24 h).

**Failure indicators:** a changed hash, `nivyx strategy example.com` says
"automatic", the learned-state file is missing or empty.

## Windows 10 and Windows 11

Machines: one Windows 10 22H2, one Windows 11 (current), both x64,
consumer installs with Microsoft Defender **on**; repeat the install steps
on one machine with a third-party antivirus. Standard user account with
UAC at its default level, plus one administrator account.

| # | Procedure | Expected | Failure indicators |
|---|---|---|---|
| W1 | Download `nivyx-windows-x86_64.zip`; `Get-FileHash` and compare with `SHA256SUMS`; optionally `gh attestation verify` | hashes match | mismatch: stop, report |
| W2 | Double-click `Install Nivyx.cmd` **inside** the ZIP (not extracted) | message to extract first, window stays open, exit code 3, nothing installed | anything installed, window closes at once |
| W3 | Extract; double-click `Install Nivyx.cmd`; answer **No** at the UAC prompt | "was NOT installed: the administrator prompt was declined", exit 1223, nothing installed | exit 6, or anything installed |
| W4 | Same, answer **Yes** | "Nivyx is installed and running"; `nivyx status` Active; browsing works | other exit code; browsing broken |
| W5 | Defender/antivirus: note any warning about `WinDivert64.sys` or `nivyx-engine.exe` (SmartScreen, quarantine) | record it; if a file is quarantined the installer must fail with a clear message and leave networking working | silent failure, broken networking |
| W6 | Double-click `nivyx-engine.exe` in the extracted folder | explanation window, nothing starts, no listener (`Get-NetTCPConnection -LocalPort 1080` empty) | a proxy starts silently |
| W7 | Damaged package: delete `files\WinDivert64.sys` from a copy, run its `Install Nivyx.cmd` over the working install | exit 2 (missing) or 4 (restored), previous version still running | previous install broken |
| W8 | Upgrade from v2.4.0: install v2.4.0 from its release ZIP, add the manual rule, then (a) `nivyx update` (must refuse, nothing changed); (b) double-click the new `Update Nivyx.cmd` | (a) "nothing was installed", v2.4.0 still running; (b) version = new, service `nivyx`, `%ProgramFiles%\dpi-proxy` gone, config preserved, browsing works | version unchanged after (b), config changed, HTTPS fails (attach the log and `nivyx status --verbose`) |
| W9 | Failed upgrade restore: install over a working install a copy whose `files\WinDivert64.sys` is replaced by a text file | exit 4, previous version running, `nivyx status` Active | exit 0, or the service is gone |
| W10 | Sleep/resume and Wi-Fi ↔ wired switch with the service running | browsing resumes within ~30 s without action | stays broken until restart |
| W11 | `Uninstall Nivyx.cmd` (decline UAC once: exit 1223; then accept) | removed; `%ProgramData%\Nivyx` kept; browsing works | data deleted without `-Purge`; browsing broken |
| W12 | `powershell -ExecutionPolicy Bypass -File files\uninstall.ps1 -Purge` (elevated) after a reinstall | everything removed incl. `%ProgramData%\Nivyx` | leftovers (`Get-Service nivyx`, folders) |

Recovery if networking breaks: `sc.exe stop nivyx` then `sc.exe stop
WinDivert` (an elevated prompt); networking returns at once; then run
`Uninstall Nivyx.cmd`. A reboot also stops interception if the service is
disabled (`sc.exe config nivyx start= disabled`).

## macOS

Machines: one Apple silicon Mac on the current macOS, one Intel Mac, and
**one Mac on macOS 11–14** (CI only runs 15 and 26). Gatekeeper at its
default setting.

| # | Procedure | Expected | Failure indicators |
|---|---|---|---|
| M1 | Download the right ZIP (`nivyx-macos-arm64.zip` / `-x86_64.zip`), `shasum -a 256` against `SHA256SUMS` | match | mismatch |
| M2 | Double-click `Install Nivyx.command` without extracting (Finder preview / inside the archive) | message, exit 3, nothing installed | anything installed |
| M3 | Extract; double-click `Install Nivyx.command`; note every Gatekeeper prompt and what had to be done (right-click → Open, System Settings → Privacy & Security) | installs after the documented steps; `nivyx status` Active; browsing works | the installer cannot be opened at all, or installs but the service does not start (attach `launchctl print system/io.github.kadireren7.nivyx`) |
| M4 | Open `files/nivyx-engine` in Terminal with no arguments | a note on stderr that it is the engine; Ctrl-C stops it | silent proxy without note |
| M5 | Reinstall over a working install with a copy whose `files/nivyx-engine` is replaced by an empty file | exit 1 or 4, previous version running | previous install broken |
| M6 | Upgrade from v2.4.0 (its ZIP), add the manual rule, then double-click the new `Update Nivyx.command` | version = new, `/usr/local/bin/dpi-proxy` gone, config preserved | as W8 |
| M7 | Sleep/resume, Wi-Fi change, with the service running | browsing resumes within ~30 s | stays broken |
| M8 | `Uninstall Nivyx.command` | removed; `/usr/local/etc/nivyx` and `/usr/local/var/nivyx` kept; `sudo pfctl -a com.apple/nivyx -s nat` empty | data deleted; anchor rules left |
| M9 | Reinstall, then `sudo sh files/uninstall.sh --purge` | everything removed | leftovers |

Recovery: `sudo launchctl bootout system/io.github.kadireren7.nivyx`
and `sudo pfctl -a com.apple/nivyx -F all`; networking returns at once.

## Linux

Machines: Debian 12 (x86_64), Ubuntu 22.04 (x86_64; the package's
glibc 2.35 floor), Fedora or Arch (OpenSSL 4: source install only), a
Raspberry Pi 4/5 on 64-bit Raspberry Pi OS (arm64: source install, no
package), and one machine with an install from before v2.3 (service
`dpi-proxy-transparent`).

| # | Procedure | Expected | Failure indicators |
|---|---|---|---|
| L0 | Extract `nivyx-linux-x86_64.tar.gz`, `sudo ./install.sh` | nothing compiled, "installed"; `nivyx status` Active | "does not run here" on Debian 12 / Ubuntu 22.04+ |
| L1 | `git clone`, `git checkout v<VERSION>`, `sudo ./scripts/install.sh` | dependencies offered/installed (Debian/Ubuntu), build, "installed"; `nivyx status` Active | build fails (attach the output); service inactive |
| L2 | Break the build on purpose (`echo '#error x' >> src/main.c`), rerun the installer over a working install | exit 3, "existing Nivyx installation is untouched", same service PID | service restarted or stopped |
| L3 | Migration: on the pre-v2.3 machine, add a manual rule to `/etc/dpi-proxy/strategy.conf`, run the new installer | service `nivyx` active, `dpi-proxy-transparent` gone, rule kept in `/etc/nivyx/strategy.conf` | both services, rule lost |
| L4 | x86_64 only: from v2.4.0 installed from its tag, `sudo nivyx update` (must refuse), then the package's `sudo ./update.sh` | refused with "nothing was installed"; then updated, config preserved | as W8 |
| L6 | Fedora/Arch: the package's `sudo ./install.sh` | refused with the explanation to install from source, nothing changed | an install that does not run |
| L7 | `sudo kill -9 $(systemctl show -p MainPID --value nivyx)` | HTTPS works again within ~1 s (table removed), service back within ~3 s | browsing broken for longer |
| L8 | `sudo systemctl kill -s KILL nivyx` (systemd ≥ 259, e.g. Ubuntu 26.04) | HTTPS fails for about 2–3 s, then works (known behaviour, L8 in PROGRESS.md) | longer than ~5 s |
| L9 | Suspend/resume, network change | browsing resumes within ~30 s | stays broken |
| L10 | `sudo ./scripts/uninstall.sh` then reinstall, then `--purge` | plain uninstall keeps `/etc/nivyx`, `/var/lib/nivyx`; purge removes them; no `dpi_proxy_tp` table left | leftovers / data lost |

Recovery: `sudo systemctl stop nivyx` (deletes the table) or `sudo nft
delete table inet dpi_proxy_tp`; networking returns at once.

## On every platform: a real DPI network

On a network where the target sites are actually blocked by DPI (record
ISP and country), with the service running for at least 24 hours:

- blocked sites open; `nivyx diagnose <site>` names a learned strategy;
- unblocked sites unchanged (no extra latency noticeable);
- DNS: `nivyx status` DNS healthy; DoH fallback when one resolver is
  blocked;
- with a VPN connected: no interference (or the documented VPN handling);
- memory stays flat (`nivyx status --verbose`; Task Manager / Activity
  Monitor / `ps`) over the day.

## Update validation

On one machine per platform with v2.4.1 or later installed:

1. `nivyx update` (elevated) → new version running, config preserved.
2. Interrupt an update (pull the network cable during the download):
   nothing installed, previous version running.
3. Confirm no `nivyx-update.*` download folders and no install backup
   folders were left behind.

## Sign-off

A release needs, for each row, a tester, machine, date and result:

| Platform | Machines covered | Result | Tester / date |
|---|---|---|---|
| Windows 10 | | | |
| Windows 11 | | | |
| Windows + third-party AV | | | |
| macOS Apple silicon | | | |
| macOS Intel | | | |
| macOS 11–14 | | | |
| Debian 12 | | | |
| Ubuntu 22.04 | | | |
| Fedora or Arch (source) | | | |
| Raspberry Pi (arm64, source) | | | |
| Pre-v2.3 Linux migration | | | |
| Real DPI network, 24 h | | | |
