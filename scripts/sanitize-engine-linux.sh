#!/usr/bin/env bash
#
# The transparent engine itself under the sanitizers, on a real machine:
# built with ASan+UBSan, then with TSan, each run in transparent mode
# (nftables, DNS forwarder, DoH, bypass ladder, verifier) against real
# HTTPS and DNS traffic, reloaded, stopped with SIGTERM. Fails on any
# sanitizer report, on a table left behind (fail-open) or on a failed
# request. CI: GitHub's ubuntu runner (sudo, nftables). Not installed;
# nothing outside a temporary folder is written. Rebuilds the tree.
#
#   ./scripts/sanitize-engine-linux.sh
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'sudo nft delete table inet dpi_proxy_tp >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
fetch() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>&1 || true; }
ok() { [[ "$1" =~ ^[23][0-9][0-9]$ ]]; }
die() { printf 'FAIL: %s\n' "$1"; tail -n 80 "$work/engine.log" 2>/dev/null || true; exit 1; }

run_one() { # name sanitizer-flags runtime-options
	local name="$1" flags="$2" opts="$3" pid i c fails=0
	printf '\n=== %s\n' "$name"
	make -C "$ROOT" clean >/dev/null
	make -C "$ROOT" all SAN_CFLAGS="$flags" >/dev/null || die "$name build failed"
	printf '[domains]\nexample.com = tlsrec\n' >"$work/strategy.conf"
	: >"$work/engine.log"
	sudo env $opts DPI_PROXY_STRATEGY_CONF="$work/strategy.conf" \
		DPI_PROXY_TP_STATUS="$work/status" DPI_PROXY_TP_DECISIONS="$work/decisions" \
		"$ROOT/dpi-proxy" --mode transparent 2>&1 | tee -a "$work/engine.log" >/dev/null &
	pid=$!
	for i in $(seq 1 60); do
		sudo grep -q '^engine: running' "$work/status" 2>/dev/null && break
		sleep 0.5
	done
	sudo grep -q '^engine: running' "$work/status" 2>/dev/null || die "$name: engine did not start"
	for round in 1 2; do
		# (wait only for these: a bare `wait` would also wait for the engine)
		local load=""
		for u in https://example.com/ https://www.wikipedia.org/ https://github.com/ https://www.cloudflare.com/; do
			for _ in 1 2 3; do { fetch "$u"; echo; } >>"$work/codes" & load="$load $!"; done
		done
		for _ in $(seq 1 10); do getent ahostsv4 "san-$RANDOM.example.org" >/dev/null 2>&1 & load="$load $!"; done
		getent ahostsv4 example.net >/dev/null 2>&1 || fails=$((fails + 1))
		# shellcheck disable=SC2086
		wait $load || true
		# reload the manual rules mid-run
		sudo kill -HUP "$(pgrep -f -n "^$ROOT/dpi-proxy --mode transparent")" 2>/dev/null || true
		sleep 1
	done
	c="$(fetch https://example.com/)"; ok "$c" || fails=$((fails + 1))
	sudo kill -TERM "$(pgrep -f -n "^$ROOT/dpi-proxy --mode transparent")"
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
# TSan needs a fixed memory layout on recent kernels
sudo sysctl -w vm.mmap_rnd_bits=28 >/dev/null 2>&1 || true
run_one 'TSan' '-fsanitize=thread -g' 'TSAN_OPTIONS=halt_on_error=0'
make -C "$ROOT" clean >/dev/null
printf '\nENGINE SANITIZER RUN: ALL CHECKS PASSED\n'
