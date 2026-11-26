#!/usr/bin/env bash
#
# Certificate and hostname verification of the engine's TLS client
# (src/tlsclient.c: DNS-over-HTTPS and the bypass verifier) against
# controlled local endpoints - no external network, no installed Nivyx
# needed, no root. A test CA is the only trust anchor (SSL_CERT_FILE /
# SSL_CERT_DIR, which OpenSSL's default verify paths honour); servers on
# 127.0.0.1 serve:
#   good     good.test, signed by the test CA
#   expired  good.test, signed by the test CA, validity in the past
#   rogue    good.test, signed by a CA that is not trusted
# Checks: right name accepted; wrong name, expired and untrusted rejected
# (and no session handed out when a valid certificate is required);
# failing to set the expected hostname fails closed; many threads sharing
# one SSL_CTX verify concurrently (both trust modes: CA file loaded at
# start, CA directory looked up on demand).
#
#   ./scripts/tls-verify-test.sh [--san asan|tsan] [--openssl PREFIX]
#
# --openssl: link a static OpenSSL from PREFIX (e.g. a TSan-instrumented
# build, so ThreadSanitizer sees libcrypto's own atomics and locks).
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SAN=""
OSSL=""
while [ $# -gt 0 ]; do
	case "$1" in
	--san) SAN="$2"; shift 2 ;;
	--openssl) OSSL="$2"; shift 2 ;;
	*) echo "usage: $0 [--san asan|tsan] [--openssl PREFIX]" >&2; exit 2 ;;
	esac
done
work="$(mktemp -d)"
pids=""
cleanup() {
	for p in $pids; do kill "$p" 2>/dev/null || true; done
	rm -rf "$work"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# ---- certificates ---------------------------------------------------------
cd "$work"
mkca() { # name
	mkdir -p "$1/db"; : >"$1/db/index"; echo 01 >"$1/db/serial"
	openssl req -x509 -newkey rsa:2048 -nodes -keyout "$1/key.pem" -out "$1/cert.pem" \
		-days 30 -subj "/CN=Nivyx test CA $1" \
		-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
		>/dev/null 2>&1
	cat >"$1/ca.cnf" <<EOF
[ca]
default_ca = d
[d]
dir = $work/$1
database = \$dir/db/index
serial = \$dir/db/serial
new_certs_dir = \$dir/db
certificate = \$dir/cert.pem
private_key = \$dir/key.pem
default_md = sha256
policy = p
copy_extensions = none
unique_subject = no
[p]
commonName = supplied
[leaf]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:good.test
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
}
leaf() { # ca out startdate enddate
	openssl req -newkey rsa:2048 -nodes -keyout "$2.key" -out "$2.csr" -subj /CN=good.test >/dev/null 2>&1
	openssl ca -batch -config "$1/ca.cnf" -extensions leaf -in "$2.csr" -out "$2.crt" \
		-startdate "$3" -enddate "$4" >/dev/null 2>&1 || fail "openssl ca ($2)"
	cat "$2.crt" "$1/cert.pem" >"$2.chain"
}
mkca ca
mkca rogue
now="$(date -u +%Y%m%d%H%M%SZ)"
later="$(date -u -d '+20 days' +%Y%m%d%H%M%SZ)"
leaf ca good "$now" "$later"
leaf ca expired 20200101000000Z 20200201000000Z
leaf rogue rogue "$now" "$later"
mkdir trustdir && cp ca/cert.pem trustdir/ca.pem && openssl rehash trustdir >/dev/null 2>&1 \
	|| fail "openssl rehash"
: >empty.pem

# ---- servers --------------------------------------------------------------
for s in good expired rogue; do
	python3 "$ROOT/tests/tls/tls_server.py" "$s.chain" "$s.key" "$s.port" &
	pids="$pids $!"
done
for s in good expired rogue; do
	for _ in $(seq 1 50); do [ -s "$s.port" ] && break; sleep 0.1; done
	[ -s "$s.port" ] || fail "$s server did not start"
done
good="$(cat good.port)"; expired="$(cat expired.port)"; rogue="$(cat rogue.port)"

# ---- client ---------------------------------------------------------------
cflags="-Wall -Wextra -Werror -g -O1 -DHAVE_TRANSPARENT -I$ROOT/include"
case "$SAN" in
asan) cflags="$cflags -fsanitize=address,undefined -fno-omit-frame-pointer" ;;
tsan) cflags="$cflags -fsanitize=thread" ;;
"") ;;
*) fail "unknown --san $SAN" ;;
esac
if [ -n "$OSSL" ]; then
	ocflags="-I$OSSL/include"; olibs="$OSSL/lib/libssl.a $OSSL/lib/libcrypto.a -ldl"
else
	ocflags="$(pkg-config --cflags openssl 2>/dev/null || true)"; olibs="$(pkg-config --libs openssl 2>/dev/null || echo -lssl -lcrypto)"
fi
srcs="$ROOT/tests/tls/tlsc_test.c $ROOT/src/tlsclient.c $ROOT/src/compat.c $ROOT/src/relay.c $ROOT/src/tls.c $ROOT/src/platform.c"
# shellcheck disable=SC2086
cc $cflags $ocflags $srcs $olibs -lpthread -o tlsc_test || fail "build"
if [ -n "$OSSL" ]; then wrapsym="$(grep -q 'define OPENSSL_VERSION_MAJOR  *4' "$OSSL/include/openssl/opensslv.h" && echo SSL_set1_dnsname || echo SSL_set1_host)"
else wrapsym="$(printf '#include <openssl/opensslv.h>\nOPENSSL_VERSION_MAJOR\n' | cc -E $ocflags - | tail -n 1 | grep -q '^4' && echo SSL_set1_dnsname || echo SSL_set1_host)"; fi
# shellcheck disable=SC2086
cc $cflags -DTLSC_TEST_WRAP -Wl,--wrap=$wrapsym $ocflags $srcs $olibs -lpthread -o tlsc_test_fc || fail "build (fail-closed variant)"
echo "client built (${SAN:-no sanitizer}; OpenSSL ${OSSL:-from the system}; hostname setter wrapped for fail-closed: $wrapsym)"

run() { # label env... -- args
	local label="$1"; shift
	printf '\n== %s\n' "$label"
	"$@" >out.txt 2>&1; rc=$?
	cat out.txt
	grep -qE 'WARNING: ThreadSanitizer|ERROR: AddressSanitizer|runtime error:|ERROR: LeakSanitizer' out.txt \
		&& fail "$label: sanitizer report"
	[ "$rc" = 0 ] || fail "$label (exit $rc)"
}
set +e
for mode in file dir; do
	if [ "$mode" = file ]; then trust=(SSL_CERT_FILE="$work/ca/cert.pem" SSL_CERT_DIR="$work/empty-dir")
	else trust=(SSL_CERT_FILE="$work/empty.pem" SSL_CERT_DIR="$work/trustdir"); fi
	run "verification cases (trust: CA $mode)" env "${trust[@]}" ./tlsc_test cases "$good" "$expired" "$rogue"
	run "fail closed (trust: CA $mode)" env "${trust[@]}" ./tlsc_test_fc failclosed "$good"
	run "concurrent handshakes on one SSL_CTX (trust: CA $mode)" env "${trust[@]}" ./tlsc_test concurrent "$good" 16 30
done
set -e
printf '\nTLS VERIFICATION: ALL CHECKS PASSED (%s)\n' "${SAN:-plain}"
