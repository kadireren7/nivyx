# Performance: v2.1.0 vs v2.2.0

v2.2 does not change the traffic engine (`git diff v2.1.0..v2.2.0 -- src include`
is one comment), so engine numbers are expected to be equal — and they
are. What did change is the `nivyx` control CLI, measured below.

All "CI" numbers come from the end-to-end test logs of GitHub-hosted
runners (single samples; runner hardware varies from run to run, so
differences of a few percent — and throughput especially — are noise).
The "local" numbers were measured on the development machine (Linux, the
installed v2.1.0 service running), 20–30 runs each.

## Engine (unchanged)

| Metric | v2.1.0 | v2.2.0 | Source |
|---|---|---|---|
| Linux engine binary (stripped) | 113,312 B | 113,312 B | release asset / CI |
| Windows `dpi-proxy.exe` (stripped) | 6,021,120 B | 6,021,120 B | CI package step |
| Linux startup to `engine: running` | 0.30 s | 0.31 s | CI |
| Windows startup (restart → running) | 1.28 s | 1.27 s | CI |
| Linux idle / under load RSS | 8.7 / 10.5 MB | 8.7 / 10.5 MB | CI |
| Windows idle / under load working set | 18.9 / 20.5 MB | 18.9 / 20.6 MB | CI |
| macOS Intel daemon RSS | 6.0 MB | 6.0 MB | CI |
| macOS arm64 daemon RSS | 7.6 MB | 7.6 MB | CI |
| Threads: Linux / Windows | 6 / 17 | 6 / 17 | CI |
| 50 MB download through the service: Linux / Windows | 113 / 42.5 MB/s | 194 / 55.2 MB/s | CI (runner noise, not a change) |

## Control CLI

| Metric | v2.1.0 | v2.2.0 | Notes |
|---|---|---|---|
| `nivyx status` latency (Linux, local) | 87 ms | **37 ms** | one `systemctl show` per run instead of three, and status fields read in-shell instead of one `sed`+`head` pair each |
| `nivyx status --verbose` | 137 ms | see note | not separately optimized; shares the same two improvements |
| `nivyx stats` (new, Linux, local) | — | 38 ms | |
| CLI size on Linux | 22.9 KB | 47.3 KB | the new commands (update, repair, stats, config, layered diagnose, help) |
| CLI files installed on Linux | 3 (`dpictl`, `dpi-proxy-ctl`, `nivyx`: 46.5 KB) | 1 (`nivyx`: 47.3 KB) | the aliases are gone |
| Linux installed man page / completions | none | 1.7 KB + 3 small files | |

## Packages

| Asset | v2.1.0 | v2.2.0 |
|---|---|---|
| `nivyx-linux-x86_64` (engine only) | 113,312 B | 113,312 B |
| `nivyx-linux-x86_64.tar.gz` (engine + CLI, used by `nivyx update`) | — | ~60 KB |
| `nivyx-windows-x86_64.zip` | 2,377,037 B | see release page |
| `nivyx-macos-arm64.zip` | 2,225,874 B | see release page |
| `nivyx-macos-x86_64.zip` | 1,926,507 B | see release page |

(The final v2.2.0 sizes are recorded in the release notes' asset list;
they differ from 2.1 only by the larger CLI scripts, the man page and
completions, minus the removed aliases.)

## What was not optimized, and why

- Engine size, memory and CPU: unchanged on purpose; there is no
  measured problem, and changing the engine is the thing v2.2 avoids.
- No polling was added: `update`, `repair` and `stats` run only when
  invoked; nothing runs in the background.
- Windows `status` reads fields with plain .NET file reads instead of
  `Select-String` (a dozen calls per `status`); not separately timed
  here because there is no PowerShell on the development machine.
