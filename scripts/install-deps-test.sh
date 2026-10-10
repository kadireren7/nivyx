#!/usr/bin/env bash
#
# Tests the installer's dependency step in clean Debian/Ubuntu containers
# (needs docker; systemctl is stubbed, so only the dependency logic and the
# start of the build are exercised - the service cycle is e2e-test-linux.sh):
#   - fresh image: everything missing is installed, second run installs nothing
#   - apt unavailable (no network): stops with exit 2, no half install
#   - non-Debian distro: nothing is installed, lists what is missing
#
#   ./scripts/install-deps-test.sh [image ...]     (default: ubuntu:24.04 debian:12)
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGES=("$@")
[ ${#IMAGES[@]} -gt 0 ] || IMAGES=(ubuntu:24.04 debian:12)
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
STUB='printf "#!/bin/sh\nexit 0\n" > /usr/local/bin/systemctl; chmod +x /usr/local/bin/systemctl; cp -r /src /work; cd /work'

for img in "${IMAGES[@]}"; do
	printf '=== %s: fresh install, then re-run\n' "$img"
	out="$(docker run --rm -v "$ROOT":/src:ro "$img" bash -c "$STUB
		./scripts/install.sh 2>&1 | grep -v '^cc ' | sed -n 1,6p
		echo '--- second run'
		./scripts/install.sh 2>&1 | grep -v '^cc ' | sed -n 1,3p" 2>&1)" || true
	echo "$out"
	echo "$out" | grep -q 'installing with apt-get: build-essential' || fail "$img: build-essential was not installed"
	echo "$out" | grep -q 'libssl-dev' || fail "$img: libssl-dev was not installed"
	second="${out#*--- second run}"
	echo "$second" | grep -q 'apt-get' && fail "$img: second run touched apt"
	echo "$second" | grep -q 'Checking dependencies' || fail "$img: second run did not start"
done
echo "PASS: fresh install resolves dependencies; re-run installs nothing"

printf '=== no network: package install must fail cleanly\n'
set +e
out="$(docker run --rm --network none -v "$ROOT":/src:ro ubuntu:24.04 bash -c "$STUB
	./scripts/install.sh; echo exit=\$?" 2>&1)"
set -e
echo "$out" | tail -6
echo "$out" | grep -q 'exit=2' || fail "expected exit 2 when packages cannot be installed"
echo "$out" | grep -q 'are unaffected' || fail "no safe-failure message"
echo "$out" | grep -q 'removing its nftables table' && fail "dependency failure touched the service"
echo "PASS: apt failure stops with exit 2 and a useful message"

printf '=== non-Debian: nothing is installed\n'
set +e
out="$(docker run --rm -v "$ROOT":/src:ro fedora:40 bash -c "$STUB
	./scripts/install.sh; echo exit=\$?" 2>&1)"
set -e
echo "$out" | tail -8
echo "$out" | grep -q 'exit=2' || fail "expected exit 2 on a non-Debian distro with missing tools"
echo "$out" | grep -q 'only on Debian/Ubuntu' || fail "no distro guidance"
echo "PASS: non-Debian gets guidance, no package manager run"

printf '=== non-Debian with the dependencies already present: installer proceeds\n'
out="$(docker run --rm -v "$ROOT":/src:ro fedora:40 bash -c "dnf install -y -q gcc make nftables openssl openssl-devel >/dev/null 2>&1
	$STUB
	./scripts/install.sh 2>&1 | grep -v '^cc ' | sed -n 1,4p" 2>&1)"
echo "$out"
echo "$out" | grep -q 'Building' || fail "Fedora with dependencies present did not get past the dependency check"
echo "PASS: non-Debian distro is not rejected when dependencies are present"
