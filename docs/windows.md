# Windows

Windows transparent mode works the same way as on Linux: [WinDivert](https://reqrypt.org/windivert.html)
redirects this machine's own outgoing HTTPS and DNS to the local
`dpi-proxy` service. It passes the full automated end-to-end test on
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
   (Advanced/manual: `powershell -ExecutionPolicy Bypass -File .\install.ps1`
   from an elevated PowerShell.)
3. Check it: `nivyx status` in any PowerShell window — you should see
   `Service: Running` and `Protection: Active`.
4. Use Firefox, Chrome, Discord, … normally. No proxy arguments, no
   manual DNS changes, no per-app configuration.

Everything needed is in the ZIP (`dpi-proxy.exe`, `nivyx.cmd` (+
`dpictl.cmd`, `dpi-proxy-ctl.cmd` aliases), `Install Nivyx.cmd`,
`Uninstall Nivyx.cmd`, `install.ps1`, `uninstall.ps1`, the WinDivert
driver files and license, `WINDOWS-QUICKSTART.txt`). No Visual Studio,
MinGW, Git or Python; the installer puts `nivyx` on the PATH itself.

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

`dpictl` and `dpi-proxy-ctl` still work with the same commands —
compatibility aliases for `nivyx`. See [cli.md](cli.md) for the full
command reference (shared across platforms).

Files: `%ProgramFiles%\dpi-proxy` (program), `%ProgramData%\dpi-proxy`
(`strategy.conf`, learned decisions, `dpi-proxy.log`).

## Uninstall

Double-click **`Uninstall Nivyx.cmd`** in the install folder
(`%ProgramFiles%\dpi-proxy`), or manually, PowerShell as Administrator
in the extracted package folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1          # keeps settings/logs
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge   # removes them too
```

Removes the service, program folder, firewall rule and PATH entry, and
unloads the WinDivert driver unless another program is using it.

## WinDivert

Windows interception uses [WinDivert](https://reqrypt.org/windivert.html),
a **third-party, signed** packet interception driver (LGPLv3/GPLv2) —
not our code — shipped unmodified in the ZIP with its license. It
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
