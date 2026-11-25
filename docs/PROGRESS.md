# Reliability work: progress

Branches: `fix/windows-runtime-packaging` (Windows runtime/packaging),
`hardening/cross-platform` (on top of it: Linux, macOS, update contract,
diagnostics, supply chain, CI). Nothing merged to `main`, no tag, no
release. Version in the tree: 2.3.1 (not tagged).

Legend: ✅ done and verified (where/how stated) · 🟡 done, verified in CI
only (no local root/Windows/macOS) · ⏳ waiting for CI · ⛔ not possible
here (stated why).

## Findings and status

| ID | Sev | Finding | Status |
|---|---|---|---|
| W1 | P1 | `dpi-proxy.exe` opened from Explorer starts a plain SOCKS5 proxy (`src/main.c`, default mode) and does nothing visible | ✅ explains itself, no server started; terminal use unchanged (wine + CI) |
| W2 | P1 | `Install/Uninstall Nivyx.cmd` drop the real exit code; UAC refusal exits 0; apostrophe in path breaks elevation | 🟡 exit codes 0/1/2/3/4/5/1223 passed through; CI e2e checks 2/3/4/0. UAC refusal itself cannot be automated ⛔ |
| W3 | P2 | `--service` from a terminal exits 1 silently | 🟡 message, exit 1063 |
| W4 | P2 | WinDivertOpen failure logged without the reason | 🟡 Win32 error + hint (CI saw `error 193`) |
| W5 | P1 | Failed Windows upgrade deletes the previous service, no rollback | 🟡 previous files + service restored (exit 4), exit 5 if even that fails |
| W6 | P2 | Updater schedules the `nivyx.cmd` swap before the health check (a rolled-back update kept the new one) | 🟡 swap only after success |
| W7 | P1 | `nivyx update` fails when Windows PowerShell inherits PowerShell 7's module path (`Expand-Archive`) | 🟡 .NET ZipFile + entry check |
| L1 | P0 | Linux: a failed build stops the running service and deletes its nftables table (`install.sh` EXIT trap) | 🟡 preflight changes nothing; CI e2e asserts same PID, table, binary |
| L2 | P0 | Linux migration deletes old service/binaries/config before the new service is verified | 🟡 old layout removed only after health check; CI test restores v2.x layout |
| L3 | P1 | Failed Linux reinstall: no rollback | 🟡 full backup/restore of files, units, enabled/active state |
| L4 | P2 | Migration with both `/etc/dpi-proxy` and `/etc/nivyx`: differing old files silently dropped | 🟡 kept as `*.legacy` |
| L5 | P2 | Linux plain uninstall deletes learned state (Windows keeps it) | 🟡 kept unless `--purge`; unknown options rejected; verifies no interception left |
| L6 | P1 | v2.3.0 Linux update package needs glibc 2.38: `nivyx update` refuses it on Debian 12 / Ubuntu 22.04 | ✅ measured on the v2.3.0 asset; fix ✅ CI: built in `ubuntu:22.04`, `check-linux-package.sh` enforces ≤ 2.35, runs on Debian 12, Ubuntu 22.04/24.04, Tumbleweed |
| L7 | P1 | Fedora 45 (OpenSSL 4.0.3) and Arch (4.1.0) have no `libssl.so.3`: no prebuilt Linux engine (old or new) runs there, so `nivyx update` cannot work | ✅ seen in CI; refusal now explains and points to `git pull && install.sh`; source build against OpenSSL 4 in CI (`linux-source-openssl4`) ⏳. A package for OpenSSL 4 (or static OpenSSL) is not done: decision for you |
| L8 | P2 | Ubuntu 26.04 (now `ubuntu-latest`, systemd 259): after `systemctl kill -s KILL` systemd skips ExecStopPost, the nft table stays and HTTPS is refused until the restart (~2 s). The e2e used `systemctl kill` as its "crash", so it failed on unchanged `main` too. A real crash (`kill -9` from outside systemd) runs ExecStopPost within ~25 ms: table removed, HTTPS 200 after 1 s | ✅ measured in CI (diagnostics run). The crash test now kills like a real crash (same 1 s expectation); `systemctl kill` gets its own check (HTTPS back after the restart); documented in docs/linux.md |
| E1 | P1 | **Source build fails with OpenSSL 4** (Arch 4.1, Fedora 45): `SSL_set1_host` is deprecated in 4.0 and the build uses -Werror, so `install.sh` cannot install Nivyx there | ✅ seen in CI; fixed: `SSL_set1_dnsname()` on OpenSSL >= 4. The return value is now checked on both versions: if the name cannot be set the handshake fails, instead of verifying the certificate without a name (DoH server authenticity) ⏳ CI |
| M1 | P1 | macOS uninstall always removes settings, learned state, logs; `--purge` does not exist | 🟡 kept unless `--purge` |
| M2 | P2 | macOS `.command` launchers always exit 0 | 🟡 real code |
| M3 | P1 | Failed macOS reinstall leaves the old install broken (binary replaced, plist deleted) | 🟡 previous files + job restored |
| M4 | P2 | Installer strips quarantine from the whole extracted folder | 🟡 only the two installed programs (copied without it) |
| M5 | P3 | `dpi-proxy` opened from Finder: silent SOCKS5 | 🟡 stderr note on a terminal; behaviour unchanged |
| U1 | P1 | Updaters (all 3): fixed rollback dir and staging names; backup deleted even when rollback failed; man page/completions not in rollback | 🟡 unique dirs, kept on failure, full file set |
| U2 | P2 | `NIVYX_RELEASE_API` accepts any URL | ✅ (Linux, local) 🟡 (macOS/Windows): only 127.0.0.1/localhost |
| U3 | P2 | Linux/macOS updater extracts without checking members | ✅ links, `..`, foreign top folders refused (tested locally with crafted archives) |
| U4 | P2 | No lock: concurrent install/update/repair/uninstall | 🟡 Linux `flock` (install, update, repair, uninstall); macOS lock dir (update only) |
| D1 | P2 | `status` "Active" from a stale status file / hung engine (Linux checked no PID; no platform checked the heartbeat) | ✅ Linux logic tested locally with stubs; 🟡 macOS/Windows |
| S1 | P2 | SBOM: Windows OpenSSL `NOASSERTION`, Nivyx license `NOASSERTION`, Linux runtime OpenSSL missing | ✅ version read from the shipped exe (3.6.4 in v2.3.0) |
| S2 | P3 | No updater-checked signature (SHA256SUMS comes from the same release) | ⛔ needs a project signing key; documented in docs/security.md |
| C1 | P2 | CI upgrade tests only from v2.1.0; no old-updater test on Windows; no v2.3.0 baseline | 🟡 Windows: v2.1.0/v2.2.2/v2.3.0 upgrade + v2.2.2/v2.3.0 updaters; Linux: v2.3.0 updater |
| C2 | P2 | Engine never run under sanitizers (only unit tests) | ✅ locally: SOCKS5 mode ASan/UBSan + TSan under load; 🟡 transparent mode in CI (`engine-sanitizers`) |
| A1 | P3 | Linux arm64 | 🟡 CI build + unit + e2e on `ubuntu-24.04-arm`; no release asset (no package, updater says so) |
| T1 | P3 | `cmd | grep -q` under `pipefail` can report "no match" on SIGPIPE | fixed where it decides security (updater); other uses checked small outputs, left as is |

## Decisions

- **No renaming / no `runtime/` folder** for the Windows engine or the
  macOS/Linux packages: the updaters of v2.2.x and v2.3.x require
  `dpi-proxy(.exe)` (reporting `dpi-proxy <version>`), `WinDivert.dll`
  next to it and `nivyx-impl.ps1` / `nivyx` at the top of the package
  folder, and refuse anything else (`nivyx-impl.ps1:582-591`,
  `scripts/nivyx` and `scripts/macos/nivyx` "unexpected package
  layout"). A rename would strand every installed v2.2/v2.3. The
  layout is documented as a contract in the packaging scripts; the user
  side is fixed instead (W1, docs, README in the Linux archive).
- Plain uninstall keeps user data on all platforms; `--purge`/`-Purge`
  removes it.

## Local verification (this machine, no root)

- `make re`, `make test`: 13/13 suites OK. `make sanitize` (ASan+UBSan): 13/13 OK.
- Parser fuzzing (gcc + ASan/UBSan, mutation, no libFuzzer available):
  150 000 000 iterations over TLS ClientHello/SNI, record split/fragment,
  HTTP Host, DNS response/query/reply builders: no report.
- SOCKS5 engine under ASan+UBSan and TSan: 60 real HTTPS requests + 180
  hostile/garbage connections per run: all 200, no report, fds back to
  baseline.
- `parity-test.sh`, `redaction-test.sh`: OK.
- v2.3.0 release assets downloaded and checksum-verified: Windows exe
  imports only system DLLs + WinDivert.dll; macOS arm64/x86_64 minOS
  11.0, libSystem only; Linux engine needs glibc 2.38 (L6).
- Not possible here: Linux/macOS/Windows install/e2e (no root, no
  Windows/macOS) → CI; Windows build (no cross compiler; installing one
  was declined) → CI.
