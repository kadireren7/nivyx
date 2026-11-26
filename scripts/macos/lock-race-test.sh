#!/bin/sh
#
# The macOS admin lock (take_admin_lock in scripts/macos/nivyx, the same
# function as in install.sh and uninstall.sh) under contention: many
# processes start at once against (a) a lock left by a dead process, (b)
# no lock, (c) a live holder. At most one may hold it at any time (a
# critical-section marker catches overlap), a live holder is never taken
# over, and the lock is gone once its holder released it. POSIX sh; runs
# on macOS and Linux, needs no root (the lock path is redirected).
#
#   lock-race-test.sh [file-with-the-lock-functions] [rounds]
#   CONTROL=1 lock-race-test.sh <old nivyx> [rounds]
#     positive control: the lock of 5d572af (a directory holding the pid)
#     against its own stale-lock format must FAIL (two holders at once)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/nivyx}"
ROUNDS="${2:-40}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
LOCK="$T/admin.lock"
# the functions exactly as shipped, with only the lock path changed
awk '/^ADMIN_LOCK=\/var\/run\/nivyx-admin.lock$/ { on = 1 } on { print } on && /^release_admin_lock\(\) \{/ { r = 1 } r && /^}$/ { exit }' "$SRC" \
	| sed "s#^ADMIN_LOCK=/var/run/nivyx-admin.lock\$#ADMIN_LOCK=$LOCK#" >"$T/lock.sh"
grep -q '^take_admin_lock() {' "$T/lock.sh" && grep -q '^release_admin_lock() {' "$T/lock.sh" \
	|| { echo "FAIL: lock functions not found in $SRC"; exit 1; }

cat >"$T/taker.sh" <<TAKER
. "$T/lock.sh"
take_admin_lock 2>/dev/null || exit 1
if ! mkdir "$T/inside" 2>/dev/null; then echo overlap >>"$T/violations"; fi
echo \$\$ >>"$T/held"
sleep 0.2
rmdir "$T/inside" 2>/dev/null
release_admin_lock
TAKER

dead_pid() { sh -c 'echo $$' ; }	# a pid that has exited
fails=0
round() { # scenario
	rm -f "$T/violations" "$T/held"; rm -rf "$T/inside" "$LOCK" "$LOCK.takeover"
	case "$1" in
	stale)
		if [ "${CONTROL:-}" = 1 ]; then mkdir "$LOCK" && dead_pid >"$LOCK/pid"
		else ln -s "$(dead_pid)" "$LOCK"; fi ;;
	legacy) mkdir "$LOCK" && dead_pid >"$LOCK/pid" ;;
	esac
	i=0; pids=""
	while [ $i -lt 16 ]; do sh "$T/taker.sh" & pids="$pids $!"; i=$((i + 1)); done
	for p in $pids; do wait "$p"; done
	n=$(cat "$T/held" 2>/dev/null | wc -l | tr -d ' ')
	if [ -s "$T/violations" ]; then echo "FAIL ($1): two holders at once"; fails=$((fails + 1)); fi
	if [ "$n" -lt 1 ]; then echo "FAIL ($1): nobody got the lock"; fails=$((fails + 1)); fi
	if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then echo "FAIL ($1): lock left after release"; fails=$((fails + 1)); fi
}
r=0
if [ "${CONTROL:-}" = 1 ]; then
	while [ $r -lt "$ROUNDS" ]; do round stale; r=$((r + 1)); done
	echo "lock-race-test (control): $fails of $ROUNDS rounds failed"
	[ "$fails" -gt 0 ] && exit 1
	exit 0
fi
while [ $r -lt "$ROUNDS" ]; do round stale; round none; r=$((r + 1)); done
round legacy

# a live holder is never taken over
sleep 30 & live=$!
ln -s "$live" "$LOCK"
( . "$T/lock.sh"; take_admin_lock ) 2>"$T/err" && { echo "FAIL: a live holder's lock was taken"; fails=$((fails + 1)); }
grep -q 'another Nivyx install, update, repair or uninstall is running' "$T/err" || { echo "FAIL: no message for a live holder"; fails=$((fails + 1)); }
[ "$(readlink "$LOCK")" = "$live" ] || { echo "FAIL: the live holder's lock was changed"; fails=$((fails + 1)); }
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null

[ "$fails" = 0 ] || { echo "lock-race-test: $fails failure(s) in $ROUNDS rounds"; exit 1; }
echo "lock-race-test: $ROUNDS rounds x 16 takers (dead owner / no lock), legacy dir, live holder: at most one holder, nothing left"
