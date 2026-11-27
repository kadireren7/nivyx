#!/usr/bin/env bash
#
# The transparent engine itself under the sanitizers, on a real machine:
# built with ASan+UBSan, then with TSan, each run in transparent mode
# (nftables, DNS forwarder, DoH, bypass ladder, verifier) against real
# HTTPS and DNS traffic - including a burst of concurrent DNS queries for
# unique names, so the DNS workers resolve over DoH in parallel - reloaded,
# stopped with SIGTERM. Fails on any sanitizer report, on a table left
# behind (fail-open), on a failed request or on a DNS failure counted by
# the engine. Then the TLS verification test (controlled local endpoints)
# under both sanitizers. CI: GitHub's ubuntu runner (sudo, nftables). Not
# installed; nothing outside temporary folders is written. Rebuilds the tree.
#
# The TSan run links a TSan-instrumented OpenSSL (scripts/build-openssl-tsan.sh,
# pinned source): with the distribution's uninstrumented libcrypto, TSan
# reports a race on OpenSSL's lock-free certificate cache that it cannot
# see the synchronisation of (docs/PROGRESS.md, E2). No suppressions.
#
#   ./scripts/sanitize-engine-linux.sh [TSAN_OPENSSL_PREFIX]
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
TSAN_OSSL="${1:-$work/openssl-tsan}"
trap 'sudo nft delete table inet dpi_proxy_tp >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>&1 || true; }
ok() { [[ "$1" =~ ^[23][0-9][0-9]$ ]]; }
die() { printf 'FAIL: %s\n' "$1"; tail -n 80 "$work/engine.log" 2>/dev/null || true; exit 1; }

run_one() { # name sanitizer-flags runtime-options [make args...]
	local name="$1" flags="$2" opts="$3" pid i c fails=0 dnsf0 dnsf1 dnsq0 dnsq1 load
	shift 3
	printf '\n=== %s\n' "$name"
	make -C "$ROOT" clean >/dev/null
	make -C "$ROOT" all SAN_CFLAGS="$flags" "$@" >/dev/null || die "$name build failed"
	printf '[domains]\nexample.com = tlsrec\n' >"$work/strategy.conf"
	: >"$work/engine.log"
	sudo env $opts DPI_PROXY_STRATEGY_CONF="$work/strategy.conf" \
		DPI_PROXY_TP_STATUS="$work/status" DPI_PROXY_TP_DECISIONS="$work/decisions" \
		"$ROOT/nivyx-engine" --mode transparent 2>&1 | tee -a "$work/engine.log" >/dev/null &
	pid=$!
	for i in $(seq 1 60); do
		sudo grep -q '^engine: running' "$work/status" 2>/dev/null && break
		sleep 0.5
	done
	sudo grep -q '^engine: running' "$work/status" 2>/dev/null || die "$name: engine did not start"
	for round in 1 2; do
		# (wait only for these: a bare `wait` would also wait for the engine)
		load=""
		for u in https://example.com/ https://www.wikipedia.org/ https://github.com/ https://www.cloudflare.com/; do
			# one write per line: parallel appends of a few bytes do not mix
			for _ in 1 2 3; do { c1="$(fetch "$u")"; printf '%s\n' "$c1" >>"$work/codes"; } & load="$load $!"; done
		done
		for _ in $(seq 1 10); do getent ahostsv4 "san-$RANDOM.example.org" >/dev/null 2>&1 & load="$load $!"; done
		getent ahostsv4 example.net >/dev/null 2>&1 || fails=$((fails + 1))
		# shellcheck disable=SC2086
		wait $load || true
		# reload the manual rules mid-run
		sudo kill -HUP "$(pgrep -f -n "^$ROOT/nivyx-engine --mode transparent")" 2>/dev/null || true
		sleep 1
	done
	# concurrent DNS: 40 unique names at once (none cached: every one goes
	# to a DoH server through a DNS worker); NXDOMAIN is a valid answer,
	# a failure is a SERVFAIL counted by the engine as dns_failures
	sleep 11	# status heartbeat
	dnsf0="$(sudo sed -n 's/^dns_failures: //p' "$work/status")"; dnsq0="$(sudo sed -n 's/^dns_queries: //p' "$work/status")"
	load=""
	for i in $(seq 1 40); do getent ahostsv4 "nivyx-san-$$-$i-$RANDOM.example.org" >/dev/null 2>&1 & load="$load $!"; done
	for n in example.com www.wikipedia.org github.com www.cloudflare.com; do
		getent ahostsv4 "$n" >/dev/null 2>&1 || fails=$((fails + 1))
	done
	# shellcheck disable=SC2086
	wait $load || true
	sleep 11
	dnsf1="$(sudo sed -n 's/^dns_failures: //p' "$work/status")"; dnsq1="$(sudo sed -n 's/^dns_queries: //p' "$work/status")"
	echo "concurrent DNS: $((dnsq1 - dnsq0)) queries through the forwarder, $((dnsf1 - dnsf0)) failed"
	[ $((dnsq1 - dnsq0)) -ge 40 ] || die "$name: the DNS burst did not reach the forwarder ($((dnsq1 - dnsq0)) queries)"
	if [ "$dnsf1" != "$dnsf0" ]; then
		# tell an unreachable DoH provider (external) from an engine failure
		curl -sS -o /dev/null -w 'direct DoH probe (cloudflare): %{http_code}\n' --max-time 10 \
			-H 'accept: application/dns-json' 'https://1.1.1.1/dns-query?name=example.org&type=A' || true
		die "$name: $((dnsf1 - dnsf0)) DNS failure(s) during the concurrent burst"
	fi
	c="$(fetch https://example.com/)"; ok "$c" || fails=$((fails + 1))
	sudo kill -TERM "$(pgrep -f -n "^$ROOT/nivyx-engine --mode transparent")"
	wait "$pid" || true
	sudo nft list table inet dpi_proxy_tp >/dev/null 2>&1 && die "$name: the table is left after SIGTERM"
	if grep -E -q 'ERROR: AddressSanitizer|runtime error:|WARNING: ThreadSanitizer|ERROR: LeakSanitizer' "$work/engine.log"; then
		die "$name: sanitizer report (above)"
	fi
	sort "$work/codes" | uniq -c
	grep -vqE '^[23][0-9][0-9]$' "$work/codes" && die "$name: a request failed"
	[ "$fails" = 0 ] || die "$name: $fails DNS/HTTPS check(s) failed"
	rm -f "$work/codes"
	printf 'PASS: %s: no sanitizer report; all requests OK; clean stop, no table left\n' "$name"
}

run_one 'ASan+UBSan' '-fsanitize=address,undefined -fno-omit-frame-pointer -g' \
	'ASAN_OPTIONS=detect_leaks=1:abort_on_error=0 UBSAN_OPTIONS=print_stacktrace=1'
"$ROOT/scripts/tls-verify-test.sh" --san asan || die "TLS verification test under ASan+UBSan"
# TSan needs a fixed memory layout on recent kernels
sudo sysctl -w vm.mmap_rnd_bits=28 >/dev/null 2>&1 || true
"$ROOT/scripts/build-openssl-tsan.sh" "$TSAN_OSSL"
run_one 'TSan' '-fsanitize=thread -g' 'TSAN_OPTIONS=halt_on_error=0' \
	OPENSSL_CFLAGS="-I$TSAN_OSSL/include" OPENSSL_LIBS="$TSAN_OSSL/lib/libssl.a $TSAN_OSSL/lib/libcrypto.a -ldl"
"$ROOT/scripts/tls-verify-test.sh" --san tsan --openssl "$TSAN_OSSL" || die "TLS verification test under TSan"
make -C "$ROOT" clean >/dev/null
printf '\nENGINE SANITIZER RUN: ALL CHECKS PASSED\n'
