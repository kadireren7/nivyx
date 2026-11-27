# Windows

Windows transparent mode works the same way as on Linux: [WinDivert](https://reqrypt.org/windivert.html)
redirects this machine's own outgoing HTTPS and DNS to the local
`nivyx` service. It passes the full automated end-to-end test on
real Windows GitHub runners (the real WinDivert driver, Administrator),
and has been field-tested on a physical Windows PC against real
ISP-level DPI in Turkey: DPI-blocked sites (Discord and others) opened
normally after a system-wide install, with no manual proxy or DNS
configuration. It has not yet been validated across a wide range of
consumer hardware and networks. Field reports are welcome.

## Quick start

1. Download **`nivyx-windows-x86_64.zip`** from
   [Releases](https://github.com/kadireren7/nivyx/releases)
   and extract it.
2. Double-click **`Install Nivyx.cmd`**. A User Account Control prompt
   appears (choose Yes) — it needs administrator rights to install a
   system service. The window stays open so you can read the result.
   (Advanced/manual: `powershell -ExecutionPolicy Bypass -File .\files\install.ps1`
   from an elevated PowerShell.)
3. Check it: `nivyx status` in any PowerShell window — you should see
   `Service: Running` and `Protection: Active`.
4. Use Firefox, Chrome, Discord, … normally. No proxy arguments, no
   manual DNS changes, no per-app configuration.

No Visual Studio, MinGW, Git or Python is needed; the installer puts
`nivyx` on the PATH itself.

### What is in the ZIP

| File | What it is |
|---|---|
| `Install Nivyx.cmd` | **Start here.** Double-click to install (also upgrades an existing installation). |
| `Update Nivyx.cmd` | Double-click to update to the latest release (`nivyx update`). |
| `Uninstall Nivyx.cmd` | Double-click to remove. |
| `nivyx.cmd` | The `nivyx` command (also works from this folder before installing). |
| `QUICKSTART.txt` | The same in five lines. |
| `files\` | What the launchers use: the engine `nivyx-engine.exe`, the WinDivert driver and its license, the Nivyx license and the PowerShell scripts. |

`files\nivyx-engine.exe` is the internal engine the service runs. Opened
from Explorer it only explains this and changes nothing. Run from a
terminal without options it is a plain local SOCKS5 proxy (it says so;
it does **not** protect the system), and `--help` lists the options.

An installation of v2.4.0 or earlier (service `dpi-proxy`,
`%ProgramFiles%\dpi-proxy`) is moved over by `Install Nivyx.cmd` or
`Update Nivyx.cmd`: settings and learned state are kept, and if the new
version fails its health check the old one is started again. Its own
`nivyx update` cannot install v2.4.1 (it refuses the new layout and
changes nothing).

### Installer exit codes

`Install Nivyx.cmd` and `install.ps1` exit with the same code, and the
window says whether it worked:

| Code | Meaning | What changed |
|---|---|---|
| 0 | installed, engine running, DNS and HTTPS checked through it | installed |
| 1 | not elevated, or another Nivyx install/update/repair/uninstall is running | nothing |
| 2 | a package file is missing (damaged or partial download) | nothing |
| 3 | the `files` folder is not next to the launcher (run from inside the ZIP) | nothing |
| 4 | the service did not start or failed its health check | a fresh install is removed again; an upgrade puts the previous version back and starts it; the last log lines are shown |
| 5 | an upgrade failed **and** the previous version could not be started again | its files are kept in `%ProgramData%\nivyx-install-backup-*`; networking works normally |
| 6 | Windows did not start the elevated installer for a reason other than a declined prompt (e.g. a policy that blocks elevation); the reason is printed | nothing |
| 1223 | the UAC prompt was declined | nothing |

A failed install never leaves interception behind: the new service is
stopped and deleted, and WinDivert stops diverting the moment the
engine exits.

If the service cannot start, `nivyx.log` (and the installer output)
says why, e.g. `WinDivert could not be opened: error 577` (driver
signature refused), `1275` (driver blocked by Windows/security
software), `2` (`WinDivert64.sys` missing, often removed by antivirus).

Before testing, stop GoodbyeDPI, zapret, other DPI tools and VPN
packet filters (`nivyx doctor` checks for the ones it can detect).

## Commands

```powershell
nivyx status
nivyx status --verbose       # full detail
nivyx doctor                 # health checks, PASS/WARN/FAIL
nivyx diagnose discord.com   # DNS + HTTPS check for one site
nivyx logs 50
nivyx support-bundle         # local diagnostics .zip, redacted, no telemetry
nivyx stop                   # (Administrator) normal internet, no bypass
nivyx start                  # (Administrator)
nivyx restart                # (Administrator)
```

See [cli.md](cli.md) for the full
command reference (shared across platforms).

Files: `%ProgramFiles%\Nivyx` (program), `%ProgramData%\Nivyx`
(`strategy.conf`, learned decisions, `nivyx.log`). Service: `nivyx`.

## Uninstall

Double-click **`Uninstall Nivyx.cmd`** (in the extracted package or in
`%ProgramFiles%\Nivyx`), or manually, PowerShell as Administrator in the
extracted package folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\files\uninstall.ps1          # keeps settings/logs
powershell -ExecutionPolicy Bypass -File .\files\uninstall.ps1 -Purge   # removes them too
```

Removes the service, program folder, firewall rule and PATH entry, and
unloads the WinDivert driver unless another program is using it.

## WinDivert

Windows interception uses [WinDivert](https://reqrypt.org/windivert.html),
a **third-party, signed** packet interception driver (LGPLv3/GPLv2) —
not our code — shipped unmodified in the ZIP's `files` folder with its
license. It
redirects this computer's own outgoing HTTPS and DNS to the local
service, and stops the moment the service stops or crashes (fail-open).
Windows Defender or other antivirus software may warn about it because
DPI tools use it.

## Limitations specific to Windows

- Field-tested against real ISP DPI on one physical Windows PC (real
  home network in Turkey); not yet validated across a wide range of
  consumer hardware, networks or ISPs.
- IPv6 interception and the QUIC fallback are implemented but not yet
  exercised by the automated test (the test machines have no IPv6).
- All traffic to port 443 passes through the service in user space,
  which costs some throughput compared to Linux; performance on
  consumer machines is still to be measured.

See also: [../README.md](../README.md) for the platform-independent
limitations, and [transparent-mode.md](transparent-mode.md) for how
the engine itself works.
