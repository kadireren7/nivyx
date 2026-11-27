# Reliability work: progress

Branches: `fix/windows-runtime-packaging` (Windows runtime/packaging),
`hardening/cross-platform` (on top of it: Linux, macOS, update contract,
diagnostics, supply chain, CI). Nothing merged to `main`, no tag, no
release until v2.4.0 (see "v2.4.0 release" at the end). Version: 2.4.0.

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
| 45777694148 | 434aba6 (Phase 13 start) | 30/34: linux-e2e + linux-arm64 (my lock test: `flock` handed the lock to `sleep`), linux-upgrade (U5: silent updater exit), windows (my CI step ran the 99.0.0 exe without WinDivert.dll) |
| 45778878182 | 8278452 | 32/34: engine-sanitizers (**E3, real data race**, fixed), linux-upgrade (test restarted the service into systemd's start limit) |
| 45780449466 | 75b6707 | 28/30: windows (**W8 reproduced**: `socket error 10048`, root cause found) |
| 45780470849 | 75b6707, release dry run | CI matrix green (W8 did not occur in that run's windows job), `assemble` failed: **R1** (seen only later, when 45784787236 failed the same way) |
| 45783308004 | 55fab4a | 28/30: windows (W8 positive-control step could not fetch the old file; the fixed test passed on Windows) |
| **45784766015** | be31de8 | **34/34** |
| 45784787236 | be31de8, release dry run | 35/41: `assemble` failed (**R1**: SBOM generator broken since dece6c6), later jobs skipped, nothing published |
| **45786750460** | **38e93a2** | **34/34** |
| **45786770442** | **38e93a2, release dry run** | **41/42 = everything except `publish`, which is skipped by design**: CI matrix 34/34, assemble, final-linux, final-macos x2, final-windows, provenance (7/7 attestations verified); no release, no tag |

Reliability of the previously failing jobs on 630dd25: `linux-arm64`
3/3, `windows-upgrade (v2.3.0, upgrade)` 3/3, `engine-sanitizers` 3/3,
all other jobs 3/3 except the one runner loss above.

No suppressions, no sanitizer options turned off, no assertion relaxed.
Phase 13 failures were all diagnosed; none was re-run away (each is
listed above with its cause). Cancelled (superseded by a fix pushed while
they ran): 45777709805, 45778814620, 45778788822, 45778908270,
45783332626.
The release workflow is exercised by `workflow_dispatch` (dry run);
publishing (a pushed tag) has not been run.

## Phase 13 — final release blockers

**1. Signed updates (S2/S5) — implemented, not enforced.**
`dpi-proxy --verify-release` (`src/release_verify.c`, 271 lines): Ed25519
through the OpenSSL the engine already links on every platform, no
configuration file read (`OPENSSL_INIT_NO_LOAD_CONFIG`; without it
libcrypto applies `OPENSSL_CONF` — mutation-checked). The release
workflow publishes `nivyx-release.manifest` (format 1: product, version,
commit, SHA-256 of every file); the maintainer signs it offline
(`scripts/release-sign.sh`, docs/release-signing.md). All three updaters,
before unpacking or running anything downloaded, require (once they carry
a key): both files, a valid signature by a carried key (checked by the
installed engine), the signed version equal to the announced one
(substitution/replay) and newer than the installed one (downgrade), and
the archive's signed SHA-256. `scripts/release-keys.txt` is empty: **no
key was generated**; updaters say "release signatures are not checked yet"
and behave as before. Old updaters ignore the new files (their own tests
pass unchanged). Key rotation: primary + offline recovery key, dual
signatures, documented recovery. Tests: `release-verify-test.sh` (20
cases; Linux, macOS, Windows; ASan/UBSan clean; 4000 mutated inputs under
ASan, 0 reports); `signed-release-cases.sh` (unsigned, no signature,
modified manifest, modified package with matching SHA256SUMS, wrong key,
substituted old manifest, old release as "latest", valid) run against
real installs on Linux, macOS (arm64 + Intel) and Windows: every bad case
refused with engine, CLI, service process and config unchanged; the valid
one installs and keeps config and learned state; with no key configured
the update works as before.

**2. macOS old updaters (C1).** `scripts/macos/update-test.sh`, CI
`macos-update` (arm64 + Intel x v2.2.2 + v2.3.0): the updater code as
released (macOS updater identical in v2.2.0-v2.3.0, `git diff` empty)
installs the candidate; the candidate's and the old updater both roll
back a release whose engine cannot start; manual rule, config hash and a
planted learned decision survive; v2.3.0 rows also run every signature
case. Passed in 45784766015 and 45786750460, and in the dry run
against the final zips (final-macos).

**3. Release dry run (R1).** `release.yml`: tag = publish, `Run workflow`
= dry run, one path: the whole `build.yml` matrix (`workflow_call`), then
`assemble` (exact release set, consistency and layout checks), then the
final files tested again (v2.3.0 updater installs them on Linux, macOS,
Windows; macOS and Windows e2e from the final archives), provenance
attested and verified, then `publish` — the only job with
`contents: write`, run only for a pushed `v<VERSION>` tag (condition +
guard step); draft when a key is configured. The dry runs found R1
(45780470849, 45784787236: SBOM generator broken by my dece6c6 — a real
release would have failed at that step); fixed, and the release tooling now runs on every push.
Dry run 45786770442: everything green, nothing published.

**4. Reliability gaps.**
- **W8 — root cause proven, fixed.** New occurrence in 45780449466 with
  the Phase 12 logging: `connect-fail - connect: socket error 10048`.
  Windows reports a non-blocking connect whose 4-tuple is still in
  TIME_WAIT through SO_ERROR (WSAEADDRINUSE), not from `connect()`; only
  the latter was retried (Phase 12's "ruled out by code" covered only the
  synchronous path — that conclusion was wrong). `test_connect_retry`
  creates the TIME_WAIT clash deliberately: on native Windows the
  pre-fix code fails it ("failed (connect: socket error 10048)", positive
  control in every CI run), the fixed code retries ("in use,
  retryable"). macOS reports it synchronously (already handled); Linux
  marks rather than binds its sockets.
- **E3 — data race, fixed.** TSan (instrumented OpenSSL) reported
  `dns_resolver_healthy()` reading health state without the resolver
  lock; pre-existing, timing-dependent. Fixed; unit test fails without it.
- **U4 — locking on all three platforms**, tested (see table).
- **Windows elevation classification (W2)** — fixed, tested as shipped.
- **L8 (systemd 259 `systemctl kill`) — open.** Reproducible in CI,
  bounded (HTTPS back after the restart, ~3 s), real crashes unaffected.
  The cause is in systemd (ExecStopPost not run after `systemctl kill`
  there); I found no upstream change note explaining it, so it is not
  classified as understood. Nothing in Nivyx was changed for it.
- **U5** (silent Linux updater exit) found and fixed on the way.

**5. Physical-device preparation.** docs/RELEASE-CHECKLIST.md: procedures,
expected results, failure indicators, log collection, config/state checks,
rollback and recovery per platform; CI-verified behaviour listed
separately. **No physical-device test has been performed.**

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
| W2 | P1 | `Install/Uninstall Nivyx.cmd` drop the real exit code; UAC refusal exits 0; apostrophe in path breaks elevation | 🟡 exit codes 0/1/2/3/4/5/6/1223 passed through; CI e2e checks 2/3/4/0. Phase 13: every elevation failure used to become 1223 "declined"; now only Win32 error 1223 does, others exit 6 with the reason (CI runs the shipped command: missing target → 6, elevated exit 7 passes through). UAC refusal itself cannot be automated ⛔ |
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
| L8 | P2 | Ubuntu 26.04 (now `ubuntu-latest`, systemd 259): after `systemctl kill -s KILL` systemd skips ExecStopPost, the nft table stays and HTTPS is refused until the restart (~2 s). The e2e used `systemctl kill` as its "crash", so it failed on unchanged `main` too. A real crash (`kill -9` from outside systemd) runs ExecStopPost within ~25 ms: table removed, HTTPS 200 after 1 s | ✅ measured in CI (diagnostics run). The crash test now kills like a real crash (same 1 s expectation); `systemctl kill` gets its own check (HTTPS back after the restart); documented in docs/linux.md. **Accepted for v2.4.0 as a documented known limitation** (README/release notes, docs/linux.md) |
| E1 | P1 | **Source build fails with OpenSSL 4** (Arch 4.1, Fedora 45): `SSL_set1_host` is deprecated in 4.0 and the build uses -Werror, so `install.sh` cannot install Nivyx there | ✅ seen in CI; fixed: `SSL_set1_dnsname()` on OpenSSL >= 4. The return value is now checked on both versions: if the name cannot be set the handshake fails, instead of verifying the certificate without a name (DoH server authenticity) ⏳ CI |
| M1 | P1 | macOS uninstall always removes settings, learned state, logs; `--purge` does not exist | 🟡 kept unless `--purge` |
| M2 | P2 | macOS `.command` launchers always exit 0 | 🟡 real code |
| M3 | P1 | Failed macOS reinstall leaves the old install broken (binary replaced, plist deleted) | 🟡 previous files + job restored |
| M4 | P2 | Installer strips quarantine from the whole extracted folder | 🟡 only the two installed programs (copied without it) |
| M5 | P3 | `dpi-proxy` opened from Finder: silent SOCKS5 | 🟡 stderr note on a terminal; behaviour unchanged |
| U1 | P1 | Updaters (all 3): fixed rollback dir and staging names; backup deleted even when rollback failed; man page/completions not in rollback | 🟡 unique dirs, kept on failure, full file set |
| U2 | P2 | `NIVYX_RELEASE_API` accepts any URL | ✅ (Linux, local) 🟡 (macOS/Windows): only 127.0.0.1/localhost |
| U3 | P2 | Linux/macOS updater extracts without checking members | ✅ links, `..`, foreign top folders refused (tested locally with crafted archives) |
| U4 | P2 | No lock: concurrent install/update/repair/uninstall | ✅ all three platforms lock install, update, repair and uninstall (Linux flock; macOS atomic symlink lock with guarded stale takeover — the earlier directory lock let two processes take over the same dead owner, fixed for v2.4.0 with `scripts/macos/lock-race-test.sh`, whose positive control fails the old lock: two holders at once in 20 of 20 rounds on macOS arm64 and Intel (CI 45793692154), 37 of 40 locally; the new lock 0; Windows named mutex). Tested in all three e2e suites |
| D1 | P2 | `status` "Active" from a stale status file / hung engine (Linux checked no PID; no platform checked the heartbeat) | ✅ Linux logic tested locally with stubs; 🟡 macOS/Windows |
| S1 | P2 | SBOM: Windows OpenSSL `NOASSERTION`, Nivyx license `NOASSERTION`, Linux runtime OpenSSL missing | ✅ version read from the shipped exe (3.6.4 in v2.3.0) |
| S2 | P3 | No updater-checked signature (SHA256SUMS comes from the same release) | 🟡 Phase 13: implemented, **not enforced**: Ed25519 over a versioned manifest, checked by the installed engine in all three updaters (fail-closed, downgrade/substitution refused); enforced once the maintainer adds the offline key (docs/release-signing.md). No key generated |
| C1 | P2 | CI upgrade tests only from v2.1.0; no old-updater test on Windows; no v2.3.0 baseline | 🟡 Windows: v2.1.0/v2.2.2/v2.3.0 upgrade + v2.2.2/v2.3.0 updaters; Linux: v2.2.2/v2.3.0 updaters; macOS (Phase 13): v2.2.2/v2.3.0 updaters on arm64 and Intel, incl. rollback |
| C2 | P2 | Engine never run under sanitizers (only unit tests) | ✅ locally: SOCKS5 mode ASan/UBSan + TSan under load; 🟡 transparent mode in CI (`engine-sanitizers`) |
| A1 | P3 | Linux arm64 | 🟡 CI build + unit + e2e on `ubuntu-24.04-arm`; no release asset (no package, updater says so) |
| E2 | — | TSan data race reported inside libcrypto (DNS workers sharing the DoH `SSL_CTX`) | ✅ instrumentation artifact, proven (see Phase 12); TSan run links an instrumented OpenSSL; no suppression |
| C3 | P3 | CI `macos-e2e (macos-14)` was cancelled unrun in every recent run (main too): GitHub retired the image, so macOS 14 had silently no coverage | removed from the matrix; docs say 15 and 26 (arm64) + 15 (Intel). macOS 11-14 are declared (minOS 11.0) but not tested |
| T1 | P3 | `cmd | grep -q` under `pipefail` can report "no match" on SIGPIPE | fixed where it decides security (updater); other uses checked small outputs, left as is |
| W8 | P1 | Windows: a connection now and then fails with "Connection was reset" right after the engine restarted (seen in 45723297716, v2.3.0 upgrade; not reproduced in 3 later runs) | ✅ Phase 13, root cause proven: the Phase 12 instrumentation logged `connect-fail - connect: socket error 10048` (45780449466). A non-blocking connect whose local-port + remote 4-tuple is still in TIME_WAIT is reported by Windows through SO_ERROR (WSAEADDRINUSE), and only the synchronous case was retried. Fixed (`src/transparent/net.c`); `test_connect_retry` reproduces it on native Windows (unfixed code: "failed (connect: socket error 10048)", positive control in CI; fixed: retried from the next port). macOS reports it synchronously (already retried), Linux does not bind its own ports |
| E3 | P2 | Data race: `dns_resolver_healthy()` read the resolvers' health without the resolver lock while DNS workers updated it (status writer + forwarder workers) | ✅ Phase 13: found by TSan in CI (45778878182; pre-existing, timing-dependent: passed 3/3 before); fixed (lock taken); unit test fails without the fix; TSan run clean since |
| U5 | P3 | Linux updater: a release lacking an expected file ended the updater silently (exit 1, no message) under `set -euo pipefail` | ✅ Phase 13, found by the signature test in CI; now reported ("is not signed", "has no <asset>"); pre-existing for a missing archive/SHA256SUMS |
| R1 | P1 | Release workflow never executed; its SBOM step was broken (`NOW` unset since dece6c6): a tagged release would have failed after the whole matrix | ✅ Phase 13: found by the dry runs (45780470849, 45784787236), fixed; release tooling now runs in every CI push; dry run 45786770442 green |

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

Phase 13 (this machine): `make re`, `make test` (15 suites incl.
test_connect_retry), `make sanitize`; `release-verify-test.sh` plain and
with an ASan/UBSan engine (20/20, no report); 4000 mutated signature /
keyring files against the ASan engine (0 reports); the Linux and macOS
updaters' signature functions run against the 8 mock releases under
bash `-euo pipefail`, dash and `bash --posix` (all cases as expected);
shellcheck 0.10.0 on every script CI checks; mutation checks: without
`OPENSSL_INIT_NO_LOAD_CONFIG` the hostile-config case fails, without the
E3 fix test_dns fails. Everything that needs root, macOS or Windows: CI.

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

## Remaining limitations and blockers (end of Phase 13)

Resolved in Phase 13 (evidence above): W8 (root cause proven, fixed,
reproduced on Windows), release workflow executed as a dry run (R1 fixed),
macOS old-updater compatibility tested, cross-platform locking (U4),
Windows elevation classification, the E3 data race, U5.

Still open:
- **Release signing not enforced** (maintainer action): no production key
  exists; until `scripts/release-keys.txt` holds one, updates rely on
  `SHA256SUMS` from the same release (S2). Procedure: docs/release-signing.md.
- **Publishing path not executed**: the dry run exercised everything
  except `publish` (a pushed tag); `gh release create` itself, the draft
  mode and the offline signing ceremony have never run.
- **L8** `systemctl kill` on systemd 259: ~3 s of refused HTTPS until the
  restart; cause in systemd not identified; real crashes unaffected.
  Accepted as a known limitation for v2.4.0.
- **OpenSSL 4 distributions** (Fedora 45+, Arch): source install only, no
  update package (L7).
- **UAC and Gatekeeper prompts, antivirus, macOS 11-14**: not testable in
  CI.
- **No physical-device validation** of any change in this branch: see
  docs/RELEASE-CHECKLIST.md (nothing in it has been performed).

### Physical-device tests still required before a release

Full procedures: docs/RELEASE-CHECKLIST.md. Summary:

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


Phase 13: afa37e5 (engine signature check, release tooling), 2487fbf
(updaters: signed manifest), e59a4f7 (U4 locking + tests), 3834493
(elevation classification), 434aba6 (macOS old-updater tests, release dry
run), a0931f3 (U5), b24f35c (test fixes), 8278452 (docs: signing,
checklist), 0810a4f (E3 data race), 75b6707 (test fix), 55fab4a (W8 fix +
regression test), be31de8 (W8 control), c74b475 (docs), 38e93a2 (R1 SBOM
fix; release tooling in CI). Verified state: 38e93a2 — build 45786750460
34/34, release dry run 45786770442 41/42 (publish skipped by design).

## v2.4.0 release

Scope frozen. Final changes: macOS lock stale-takeover race fixed (U4,
`lock-race-test.sh` with positive control), version 2.4.0, release notes
covering v2.3.0 -> v2.4.0, README states the testing status (no
physical-device validation) and that Ed25519 enforcement is off. L8
accepted as a known limitation; no OpenSSL 4 binary package (Fedora/Arch
install from source). Ed25519 infrastructure stays inactive; no key.

Pre-merge validation on 6bf9c83: build 45793692154 34/34; release dry run
45793712918 41/42 (publish skipped by design). Publication results are
recorded below after the tag ran.

## v2.4.1: simple packages, one name (2026-11-28)

Decisions (maintainer): every package holds only Install / Update /
Uninstall, the `nivyx` command, a short `QUICKSTART.txt` and `files/`;
`nivyx` everywhere (no `dpi-proxy`); a release is the four packages plus
`SHA256SUMS`; the release-signing infrastructure is removed from the code
(release_verify.c, release-keys, manifest, signature tests, release-signing
doc), the SBOM is dropped (its Windows OpenSSL pin check moved into
scripts/windows/package.sh); man page and shell completions are no longer
shipped in the macOS/Windows packages (Linux source installs keep them).

Clean break, chosen deliberately: the `nivyx update` of v2.2.x-v2.4.0
refuses the new layout ("unexpected package layout; nothing was
installed", checked against the tagged sources) and changes nothing;
users run the new package's Install/Update once. The installers move
macOS/Windows "dpi-proxy" installs to the nivyx names (service, launchd
label, PF anchor, folders, firewall rule) with rollback to the old
service; `nivyx update` now runs the downloaded package's own installer.
Linux gained a prebuilt package install (scripts/install.sh detects
files/nivyx-engine). CI and release tests were rewritten for this (old
updaters refuse safely; migration keeps rule and learned state; layout
checks of every package top level).

Not verified locally: PowerShell scripts (no pwsh here) and every
root/admin path on all platforms; CI is the first real run.
