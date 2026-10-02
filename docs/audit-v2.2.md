# v2.2 engine audit

The v2.2 milestone deliberately left the traffic engine alone. This page
records what was audited, what the audit found, and what was (not)
changed, so the next release starts from facts.

**Engine changes in v2.2: none** (the only C change is one added unit-test
assertion). Everything user-visible that is new lives in the `nivyx`
control CLI, the installers and the release pipeline.

## Network changes

How the engine reacts (read from `src/transparent/transparent.c`): the
default route's interface, gateway and gateway MAC form a *network
fingerprint*, recomputed when the platform reports a change (after a short
settle delay) and periodically as a fallback. On a change the engine drops everything specific to
the old network — cached DNS answers, cooldowns, "direct verified bad"
marks, QUIC blocks, idle DoH connections — and keeps learned decisions,
which are keyed by fingerprint, so returning to a known network finds
them again. With no default route nothing is learned until one appears.
Interception stays fail-open on all three platforms (heartbeat-gated nft
sets on Linux, a watchdog process on macOS, the service lifecycle on
Windows).

Tested in CI: crash, hang (macOS), stop, restart, automatic restart,
rules removed externally (repair). **Not tested** (no hardware or
runner support): Wi-Fi/Ethernet/hotspot switching, VPN connect and
disconnect, sleep/wake and hibernate, DHCP renewal, booting before the
network is up. v2.2 therefore makes no new claim there; v2.1's field
results stand.

## IPv6

| | Linux | macOS | Windows |
|---|---|---|---|
| DNS AAAA through the forwarder | live-verified (AAAA answered over DoH) | unit + field | unit + field |
| IPv6 HTTPS interception | nft `inet` table covers it; ruleset unit-tested | PF `inet6` rules; ruleset unit-tested | WinDivert filter covers IPv6 |
| Strategy scoping by family | unit-tested (a v4 decision is never used for v6, and vice versa; direct-bad marks too) | same code | same code |
| Real IPv6 traffic in CI | **no** — hosted runners have no IPv6 connectivity | no | no |

The development machine used for this audit had an IPv6 default route
but no global address, so end-to-end IPv6 HTTPS could not be exercised
there either. The family scoping, ruleset generation and AAAA paths are
covered; real IPv6 transport is as validated as in v2.1 (field use).

## QUIC / HTTP/3

Current behaviour (`src/transparent/quic.c`, the nft/PF/WinDivert
layers): UDP/443 is rejected only to addresses that are known-blocked
(from DNS answers for known-blocked names) or that a bypass just carried;
the browser then falls back to TCP. It is never global. Each decision is
per address and expires after `TP_QUIC_BLOCK_TIMEOUT_S` (1 h; entries are
refreshed only while traffic keeps confirming them), is flushed on a
network change, and an in-memory table avoids re-adding an address more
often than every half timeout. Address reuse by CDNs is therefore bounded
to one hour. No QUIC bypass strategy exists and none was invented.
v2.2 adds a regression assertion that the nft element timeout is the
shared bounded constant. No behavioural change was justified by evidence.

## Decision ladder

Already deterministic and explainable (`src/transparent/policy.c`):
manual rule > cached decision (per host, network fingerprint and address
family, 24 h TTL, re-validated at half TTL) > the ladder
(direct first; known-blocked hosts skip straight to the bypass), a
60 s cooldown for hosts that failed every attempt, a one-hour in-memory
"direct verified bad" negative mark per host/network/family, and
verification of a learned decision before it is cached. The first
blocked connection to a *new* host pays the direct attempt
(`TP_CONNECT_TIMEOUT_MS` 3 s / `TP_REPLY_TIMEOUT_MS` 4 s) — that cost is
the price of not bypassing hosts that do not need it, and no measurement
justified tuning it. No change.

## DNS

| Requirement | Linux | macOS | Windows |
|---|---|---|---|
| Encrypted DNS is the normal path | DoH, plain resolvers only if every DoH server fails | same | same |
| mDNS/Bonjour untouched | yes (only port 53) | yes | yes |
| Local / LAN names answered by the network's own resolver | **not supported** | yes | **not supported** |
| Captive portal before login | **not supported** (see below) | DNS falls back to the network's resolver | **not supported** |
| DoH failover | in-order walk over 4 DoH servers, then plain | same | same |
| No endless retries | bounded (8 connection attempts per query; client retry timers) | same | same |
| No recursive interception | own sockets are marked / use a reserved port range | same | same |

The gap: on Linux and Windows the forwarder cannot tell which server a
redirected query was addressed to (`tpp_dns_original` is macOS-only), so
names that only the router answers (`printer.lan`, `nas`) get the DoH
answer — NXDOMAIN — and a captive portal's DNS is not consulted. Plain
workarounds: put the LAN name in the hosts file; for a captive portal run
`nivyx stop` (root/Administrator), log in, then `nivyx start`. Fixing it
properly means recovering the original destination on Linux
(conntrack) and Windows (WinDivert), or consulting the system's
configured resolver, and was judged too invasive and untestable in CI for
this release. A configurable resolver list (`DPI_PROXY_DOH_SERVERS`,
`DPI_PROXY_DNS_SERVERS` in the unit environment) already exists; a
`nivyx config resolver` front end for it was not added.

## Not changed on purpose

Everything above. The measured and the claimed are kept apart: this file
lists what is covered by a test or by reading the code, and says "not
tested" where it is not.
