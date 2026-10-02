#!/usr/bin/env bash
#
# Regression test for support-bundle redaction (Linux, no root, no
# service needed): planted secrets, the user's home and name, learned host
# names (log lines, status file, decision file) must not appear in the
# archive. Everything is pointed at temp files through the same environment
# overrides the CLI honours.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fakehome="$tmp/home/e2euser-zq"
mkdir -p "$fakehome"

cat > "$tmp/strategy.conf" <<CONF
# token=SUPERSECRETTOKEN1234
password: hunter2hunter2
key=AKIAFAKEKEY0123456789
path $fakehome/rules
default = pass
CONF
cat > "$tmp/status" <<STATUS
engine: running
mode: transparent
pid: 1
started: 1
decisions: 2
last_learned: secret-learned-host.example original+tlsrec
flows: 5
STATUS
cat > "$tmp/decisions" <<DEC
# dpi-proxyd decisions: host fingerprint family strategy target validated_at
secret-learned-host.example 0123456789abcdef 4 tlsrec original 1790000000
another-private-site.example 0123456789abcdef 4 tlsrec original 1790000000
DEC

out="$tmp/bundle.tar.gz"
HOME="$fakehome" DPI_PROXY_STRATEGY_CONF="$tmp/strategy.conf" DPI_PROXY_TP_STATUS="$tmp/status" \
	DPI_PROXY_TP_DECISIONS="$tmp/decisions" "$ROOT/scripts/nivyx" support-bundle "$out" >/dev/null
mkdir "$tmp/x"
tar -xzf "$out" -C "$tmp/x"

fail=0
leak() { printf 'LEAK: %s\n' "$1"; fail=1; }
for secret in SUPERSECRETTOKEN1234 hunter2hunter2 AKIAFAKEKEY0123456789 secret-learned-host.example another-private-site.example "$fakehome" e2euser-zq; do
	if grep -rqF -- "$secret" "$tmp/x"; then leak "'$secret' is in the support bundle"; fi
done
grep -rq 'REDACTED' "$tmp/x" || leak "no [REDACTED] marker: the secret filter did not run"
[ -f "$tmp/x/dns-history-summary.txt" ] || leak "decision summary missing"
grep -q 'learned decisions on record: 3' "$tmp/x/dns-history-summary.txt" || leak "decision history is not reduced to a count"

# the log-line masking itself, on the exact lines the engine writes
masked="$(printf '[learn] www.example-private.com: original+tlsrec via 1.2.3.4 (certificate verified)\n[verify] x.example.org: did not verify\n' \
	| sed -E 's/(\[(learn|verify)\] )[^ :]+:/\1<host>:/')"
echo "$masked" | grep -q 'private' && leak "log masking regex left a host name"
echo "$masked" | grep -q '^\[learn\] <host>: original+tlsrec via 1.2.3.4' || leak "log masking regex damaged the line"
[ "$fail" = 0 ] && echo "redaction: secrets, home, user name and learned hosts absent from the bundle"
exit "$fail"
