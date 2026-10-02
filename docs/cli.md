# nivyx — command reference

`nivyx` is the control CLI for Nivyx's transparent-mode service,
identical across Linux, Windows and macOS (`nivyx` on Linux/macOS is a
bash/sh script; on Windows, `nivyx.cmd` runs the equivalent
PowerShell). It is the only public command; the engine binary
(`dpi-proxy`) is an internal component you never need to run.

Commands that change service state (`start`/`stop`/`restart`/`reload`)
need root (`sudo`) on Linux/macOS or an elevated/Administrator terminal
on Windows. Everything else works as a normal user.

## status

```
nivyx status              # short summary
nivyx status --verbose    # full internals (engine, DNS, flows, PF/nft state, ...)
```

The default output is meant to be read at a glance:

```
Nivyx 2.2.0
Service: Running
Protection: Active
DNS: Healthy
Mode: Transparent
Bypassed: 123
Failures: 0
```

Colored on a terminal (green: healthy/running, yellow: warning/
degraded, red: failed) — plain text when piped/redirected or when
`NO_COLOR` is set ([no-color.org](https://no-color.org)).

`--verbose` prints engine state, DNS resolver/interception detail,
network fingerprint, flow counters, learned-decision counts, and (as
root) live nftables/PF rule counts.

## start / stop / restart / reload

Start, stop, restart the service, or reload manual rules from
`strategy.conf` without restarting (`reload` sends the daemon SIGHUP on
Linux/macOS; on Windows it restarts the service, which re-reads the
file). `stop` always leaves the machine on ordinary, unbypassed
networking — the manual equivalent of fail-open.

## logs [N]

The last N lines (default 100) of the service's log.

## diagnose DOMAIN [--verbose]

A read-only explanation of what happens for one domain, in three layers:

```
$ nivyx diagnose discord.com

DNS
  Resolver: DoH (answered by Nivyx)
  Address: 162.159.136.232 162.159.138.232
  Poisoning suspected: No

HTTPS
  Result: Success (HTTP 200, certificate OK)

Decision
  Source: Learned (this network)
  Strategy: tlsrec-split (IPv4)
  TTL: 17h 5m
  Direct connection: failed earlier on this network, so the bypass is applied
```

*Poisoning suspected* compares the system answer with a trusted
resolver's: `Yes` only for private/null addresses (a public site never
resolves to one); `Possible` when the answers differ entirely (which is
also normal for CDNs, hence the wording). *Source* is `Manual rule`
(from `strategy.conf`, never expires), `Learned` (found by Nivyx for
this network; expires after 24 h unless used again) or `Automatic`
(nothing learned, connections go direct). `--verbose` adds the network
fingerprint, both DNS answer sets and the recent log lines for the
domain. Not needed for normal use — for when one specific site looks
wrong.

## stats

Local-only counters read from the service's status file: uptime,
intercepted/direct/bypassed/passthrough connections, active flows,
failures, DNS queries and failures, certificate verifications, size of
the learned-strategy cache and its split by strategy and IP family, and
the network fingerprint. No host names are shown or kept for this; the
raw per-host history is never summarized by name. Nothing is sent
anywhere. The engine does not export separate TLS-record-vs-TCP
*connection* counters, so the strategy split is by cached decision, not
by connection.

## strategy DOMAIN

What applies to DOMAIN right now: a manual rule from `strategy.conf`,
else a learned decision for the current network, else "automatic".
(`diagnose` shows the same decision with more context.)

## config

```
nivyx config show                    # print strategy.conf
nivyx config path                    # where it is
nivyx config check                   # syntax check; lists problem lines
nivyx config set example.com tlsrec  # add/replace one manual rule
nivyx config unset example.com       # remove it
```

Manual rules always override automatic learning. `set` and `unset`
change exactly one line, keep the previous file as `strategy.conf.bak`,
re-check the result, and never run unless you invoke them (they need
root/Administrator, and `set` accepts `pass`, `tlsrec` or `tlsrec-split`
— the strategies transparent mode applies). Everything else in the file
(comments, `default`, other rules) is left byte for byte as it was.
`check` mirrors the engine's own parser, which skips an invalid line and
keeps running rather than refusing to start; it tells you which lines
that applies to. Apply a change with `nivyx reload`.

## doctor

Read-only health checks, each printed as `[PASS|WARN|FAIL]` with a
one-line reason (colored green/yellow/red on a terminal; see above).
Exits 0 if nothing failed, 1 otherwise. Never modifies or disables
anything it finds — including other DPI tools.

Checks: permissions (root/Administrator, binary present), service
state, interception layer (nftables table / PF anchor / WinDivert
driver), DNS-over-HTTPS health, internet reachability, that the binary
actually supports transparent mode, other known DPI-bypass tools
(dpi-bypass, GoodbyeDPI, zapret and its `nfqws`/`winws` processes,
SpoofDPI, ByeDPI, tpws, ciadpi) or a VPN/tunnel interface that might
also be filtering HTTPS, and stale interception rules left behind
while the service is stopped.

## repair

The mutating counterpart of `doctor` (root/Administrator). It checks
Nivyx-owned state, fixes what it can and prints every action, e.g.
`[fixed] removed stale nftables table inet dpi_proxy_tp`.

| Platform | What it can repair |
|---|---|
| Linux | stopped/failed/disabled service, stale status file, stale `inet dpi_proxy_tp` table while stopped, missing table while running (restarts the service), file permissions, missing config (recreated with defaults), damaged learned-decision lines (backup kept) |
| macOS | unloaded or stopped launchd job, disabled job, stale status file, stale rules in the `com.apple/dpi-proxy` anchor, leftover PF enable reference, emptied anchor while running, permissions, missing config, damaged decision lines |
| Windows | stopped service, startup type, missing firewall rule, missing PATH entry, stale status file, stale WinDivert driver state (only if no other WinDivert tool runs), missing config, damaged decision lines |

Rules it keeps: it touches only Nivyx-owned objects, never edits your
`strategy.conf` rules (a syntax problem is reported, not rewritten),
never touches other firewall tables/anchors/rules, and never disables
VPN or security software. A missing service unit, launchd job or
engine binary cannot be recreated safely — it tells you to re-run the
installer. Exit status 1 if something remains that it cannot fix.

## update [--check]

```
$ nivyx update --check
Current: 2.2.0
Latest:  2.3.0
Update available.
```

`--check` only compares versions. `nivyx update` (root/Administrator):

1. queries the official GitHub releases endpoint for the latest stable
   release and compares versions;
2. picks the asset for this OS and architecture (`nivyx-linux-x86_64.tar.gz`,
   `nivyx-macos-<arch>.zip`, `nivyx-windows-x86_64.zip`) and `SHA256SUMS`,
   and refuses download URLs outside `github.com/kadireren7/nivyx`;
3. verifies the SHA-256 **before** unpacking anything, then checks that
   the new engine runs here and reports the expected version;
4. backs up the files it replaces, swaps them in (rename-based on
   Linux/macOS), restarts the service;
5. runs a health check (the status file must come from the *new* service
   process, and HTTPS must work through it);
6. on any failure restores the previous version and says so.

Configuration and learned state are never touched. There is no
telemetry, no background checking and no automatic update: it runs only
when you invoke it. `NIVYX_RELEASE_API` overrides the release endpoint
(used by the test suite; a notice is printed whenever it is set).

## support-bundle [FILE]

Writes a local diagnostics archive (`.tar.gz` on Linux/macOS, `.zip`
on Windows) containing: version, OS/architecture, `status` output,
`doctor` output, recent service logs, `strategy.conf`, and service
state.

**No telemetry**: this command only ever writes a local file; nothing
is sent anywhere by nivyx itself. Redacted before writing: anything
that looks like a token/key/secret/password, `$HOME`/`%USERPROFILE%`,
your username, host names in `[learn]`/`[verify]` log lines (and the
"last learned" status line), and the per-domain/per-IP DNS decision
history (only a count is included — that history is effectively your
browsing history). `strategy.conf` is included as written (those are
domains you chose); review the archive before sharing it.

## version

Prints the Nivyx version and exits.

## help [COMMAND]

`nivyx --help` is the short overview; `nivyx help COMMAND` explains one
command. Linux and macOS also install `man nivyx`.

## Shell completion

Installed automatically: bash and fish (Linux), zsh (Linux and macOS).
PowerShell: add `. "$env:ProgramFiles\dpi-proxy\nivyx-completion.ps1"`
to your `$PROFILE`. Commands and options only, no network lookups.

## Packet mode (Linux, optional, advanced)

`nivyx packet <start|stop|restart|reload|status|logs>`,
`nivyx probe DOMAIN`, `nivyx reprobe DOMAIN`, `nivyx networks` — see
[packet-mode.md](packet-mode.md). Most installs never need these;
transparent mode is the default, automatic engine.
