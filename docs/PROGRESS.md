# Reliability work: progress

Branches: `fix/windows-runtime-packaging` (Windows runtime/packaging),
`hardening/cross-platform` (on top of it: Linux, macOS, update contract,
diagnostics, supply chain, CI). Nothing merged to `main`, no tag, no
release. Version in the tree: 2.3.1 (not tagged).

Legend: ✅ done and verified (where/how stated) · 🟡 done, verified in CI
only (no local root/Windows/macOS) · ⏳ waiting for CI · ⛔ not possible
here (stated why).

## CI status (2026-11-26, branch `hardening/cross-platform`)

| Run | Commit | Result |
|---|---|---|
| 45723297716 | (Phase 11 end) | 27/30: TSan (E2), arm64, Windows v2.3.0 upgrade failed |
| 45732271581 | 979f8cf | 27/30: arm64 (start-limit-hit, A2), Windows update-compat x2 (positive control showed the wine-based claim was wrong, S3) |
| 45734167213 | 630dd25 | **30/30** |
| 45735212794 | 630dd25 (re-run, workflow_dispatch) | **30/30** |
| 45735202409 | 630dd25 (re-run, workflow_dispatch) | 29/30, then **30/30**: `shellcheck` lost its runner during `apt-get install` (GitHub annotation: "The hosted runner lost communication with the server"; no Nivyx code had run); that one job re-run: passed |

Reliability of the previously failing jobs on 630dd25: `linux-arm64`
3/3, `windows-upgrade (v2.3.0, upgrade)` 3/3, `engine-sanitizers` 3/3,
all other jobs 3/3 except the one runner loss above.

No suppressions, no sanitizer options turned off, no assertion relaxed.
The release workflow (`release.yml`) runs only on a tag and was not run
(no tag was created); its jobs mirror `build.yml`'s, YAML-validated.

## Phase 12 — blockers resolved

**E2 TSan "race" in libcrypto — instrumentation artifact, resolved.**
`ossl_x509v3_cache_extensions()` (OpenSSL 3.5.5, `crypto/x509/v3_purp.c`)
caches a certificate's extensions lazily, under `x->lock`, and publishes
them with an atomic release store (`tsan_st_rel(&x->ex_cached, 1)`,
line 663); readers take a lock-free acquire load (`tsan_ld_acq`, line
452) and then read `x->skid` (`X509_check_akid`, line 1046). The shared
objects are the trust anchors loaded in `tlsc_ctx_new` (the lock `M0` in
the report is created there). The C11 acquire/release pair is correct,
but in an uninstrumented libcrypto TSan cannot see it, while its
memcpy/memcmp interceptors do see both accesses. Evidence (this machine,
`scripts/tls-verify-test.sh --san tsan`, 16 threads x 30 handshakes on
one SSL_CTX, leaves with AKID): TSan app + uninstrumented static OpenSSL
3.5.5: the same report (`ASN1_STRING_cmp` vs `ASN1_STRING_set` under write
M0) in 3/3 runs; the same OpenSSL 3.5.5 built with `-fsanitize=thread`:
0 reports in 5/5 runs; system OpenSSL 3.0.13: 0 reports. The report
appears only with the CA bundle loaded from a file at start (eager — the
Debian/Ubuntu default), never with on-demand directory lookup: loading CAs
eagerly is not a fix and was not implemented. Measured on Ubuntu: the
default verify paths already load the 120-certificate bundle at start
(`tlsc_ctx_new` 14 ms, +4.3 MB RSS; directory-only: 2 ms, +3.2 MB).
Trust-store refresh is unchanged: the CA file is read once at engine
start (an updated bundle is used after `nivyx restart`); CA directory
entries are looked up on demand. Fix: the TSan CI run links OpenSSL 3.5.5
built from pinned source with TSan (`scripts/build-openssl-tsan.sh`,
cached). CI: engine-sanitizers passes (45734167213), incl. 80 (ASan) and
200 (TSan) concurrent DNS queries through the forwarder, 0 failed.

**A1 arm64 "stats printed no connection counters" — test bug of mine.**
The systemctl-kill check added in Phase 11 ended its step while the
service waited out RestartSec=2 (on systemd 255 ExecStopPost ran, so HTTPS
worked at once); `nivyx stats` ran before the engine was back. Fixed with
bounded readiness waits (service active + status file written by its
MainPID + engine running) in place of fixed sleeps (Linux and Windows).

**A2 arm64 "nivyx repair failed" — product bug, fixed.** With the sleeps
gone, the steps ran back to back and repair's restart hit systemd's start
rate limit (`start-limit-hit`, >5 starts in 10 s). A user whose service
crash-looped would meet the same refusal when running repair: repair now
clears it (`systemctl reset-failed`) before restarting. Deterministic
regression test: 5 restarts, table removed, repair must restore it.

**W8 Windows v2.3.0 upgrade "Connection was reset" — not reproduced.**
The engine's single attempt (manual tlsrec rule = one strategy) to
example.com ended in `connect-fail` in under a second; the installer's
health check through the same engine had passed 13 s earlier. Own-port
reuse was ruled out by code (randomised start, EADDRINUSE retried 8x).
Not reproduced in 45732271581, 45734167213 and the re-runs. The `[fail]`
log line now carries the OS reason, and a failed HTTPS check in the
Windows tests prints evidence (engine reason, a direct non-intercepted
probe, own-port use) so the next occurrence can be attributed. Open:
root cause not proven.

**T2 TLS verification — isolated test, passing.** `scripts/tls-verify-test.sh`
(test CA only; local endpoints; the engine's `src/tlsclient.c`): trusted
right name accepted with a round trip; wrong name, name suffix, expired,
untrusted CA rejected and no session when a valid certificate is
required; failing to set the hostname fails closed (linker `--wrap`);
concurrent handshakes. Both trust modes. Plain (CI linux, arm64), ASan and
TSan-with-instrumented-OpenSSL (CI engine-sanitizers). Mutation check:
with the hostname check removed the test fails (wrong name "verified").

**S3 Windows OpenSSL configuration loading — hardening, severity corrected.**
Up to v2.3.0 the engine applied an OpenSSL configuration (which can load
provider DLLs). Measured on real Windows (45734167213, v2.2.2 and v2.3.0
as installed): `OPENSSL_CONF` applies, and so does
`C:\Program Files\etc\ssl\openssl.cnf` (the exe folder's parent: MSYS2
relocation); the exe folder, the drive's `\mingw64\etc\ssl` and the
working directory do not. Under wine the working directory was used; that
did not carry over (my first claim, corrected in 630dd25). Both real
locations are administrator-only: **no privilege escalation in a normal
install**; P3 hardening. The candidate applies none of the five
(`OPENSSL_INIT_NO_LOAD_CONFIG`), checked in e2e and after the old
updaters' update.

**S4 Windows OpenSSL pinned.** Built from the official 3.5.8 source (the
macOS pin, SHA-256), absolute OPENSSLDIR under Program Files, cached in
CI; CI checks the exe embeds it; `gen-sbom.sh` fails if the exe's version
differs from the pin (verified: it refuses the v2.3.0 exe, 3.6.4).

**S5 Provenance in the updater — evaluated, not implemented** (Sigstore
verification needs `gh`/`cosign` or a large verifier on every machine).
Proposed instead (maintainer decision; no key generated): RSA signature
over `SHA256SUMS` with an offline key, checked by updaters that ship the
public key; old updaters ignore the extra file. See docs/security.md.

### Measurements (CI runners; synthetic, not real devices or ISPs)

| | before (main, v2.3.0 code, run 38087987592) | after (630dd25, run 45734167213) |
|---|---|---|
| Windows exe | 6,021,120 B (MSYS2 OpenSSL 3.6.4) | 6,452,224 B (OpenSSL 3.5.8 from source) |
| Windows startup (restart → engine running) | 1.27 s | 0.53 s |
| Windows working set idle / under load | 19.0 / 20.5 MB | 18.8 / 20.4 MB |
| Linux startup | 0.30 s (Ubuntu 24.04 image) | 0.32 s (Ubuntu 26.04 image) |
| Linux RSS idle / under load | 8.7 / 10.5 MB (24.04) | 10.0 / 11.9 MB (26.04) |

Single samples. Linux rows are on different runner images and not
comparable. Throughput is measured against a public speed endpoint
(Windows 34.6 → 21.9 MB/s, Linux 173 → 298 MB/s) and dominated by the
network; it is not an engine comparison. Locally (same machine, SOCKS5
mode): Linux engine 113,312 B before and after, idle RSS 3.3 MB both.

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
| E2 | — | TSan data race reported inside libcrypto (DNS workers sharing the DoH `SSL_CTX`) | ✅ instrumentation artifact, proven (see Phase 12); TSan run links an instrumented OpenSSL; no suppression |
| C3 | P3 | CI `macos-e2e (macos-14)` was cancelled unrun in every recent run (main too): GitHub retired the image, so macOS 14 had silently no coverage | removed from the matrix; docs say 15 and 26 (arm64) + 15 (Intel). macOS 11-14 are declared (minOS 11.0) but not tested |
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

## Remaining limitations and blockers (end of Phase 12)

- **W8** (Windows v2.3.0 upgrade connect-fail, run 45723297716): not
  reproduced in 3 later runs; root cause not proven. The OS reason is now
  logged and the tests print attribution evidence if it recurs.
- **Release workflow not executed**: it runs only on a tag, and no tag was
  created. Its Windows job now builds OpenSSL from source (first build
  ~10 min, then cached); exercised so far only through the identical
  steps in `build.yml`.
- **macOS old-updater compatibility** (v2.2.x/v2.3.0's own `nivyx update`
  installing the new package) is not tested in CI; the package layout it
  requires (`dpi-proxy`, `nivyx` at the top) is unchanged. Windows and
  Linux have that test.
- **Updater authenticity** rests on SHA256SUMS from the same release
  (S5); a signing key and process are a maintainer decision.
- **Fail-open after `systemctl kill`** on systemd 259 lasts until the
  restart (measured: HTTPS back after 3 s); real crashes are unaffected (L8).
- **OpenSSL 4 distributions** (Fedora 45+, Arch) can install from source
  (CI-verified build) but get no prebuilt update package (L7).
- **No physical-device validation** of any change in this branch.

### Physical-device tests still required before a release

- Windows 10 and 11 (consumer PCs, Defender on, a third-party antivirus):
  double-click install, UAC decline, run from inside the ZIP, damaged
  ZIP, upgrade from v2.3.0 (installer and `nivyx update`), failed-upgrade
  restore, uninstall/-Purge; `dpi-proxy.exe` opened from Explorer.
- macOS on Apple silicon and Intel, incl. one macOS 11-14 machine (not
  covered by CI): Gatekeeper prompts for the `.command` files, install,
  failed reinstall restore, plain uninstall keeps data, `--purge`.
- Linux: Debian 12, Ubuntu 22.04 (update package glibc 2.35 limit),
  Fedora/Arch from source (OpenSSL 4), a Raspberry Pi (arm64), and the
  migration from a real pre-v2.3 install.
- On all: a real DPI network (DoH, bypass), sleep/resume and network
  changes, long-running stability, a VPN alongside.

### Commits (hardening/cross-platform, on top of fix/windows-runtime-packaging b93e474)

Phase 12: 7c25db8 (Windows: no OpenSSL configuration), 5ec6b74 (TLS
verification test), 5532f50 (TSan with instrumented OpenSSL, concurrent
DNS), dece6c6 (Windows OpenSSL pinned, SBOM check), 979f8cf (readiness
waits, connect-fail reason, CI), 2de4a5a, 630dd25 (repair start-limit
fix; config test on real Windows, wine claim corrected).

