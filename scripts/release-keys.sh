#!/usr/bin/env bash
# The updaters carry the release public keys of scripts/release-keys.txt
# between "# BEGIN RELEASE KEYS" and "# END RELEASE KEYS".
#
#   release-keys.sh check   fail if any updater's keys differ from the file (CI)
#   release-keys.sh sync    write the file's keys into the three updaters
#   release-keys.sh list    print the trusted keys with their key ids
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
KEYS="$ROOT/scripts/release-keys.txt"
TARGETS="scripts/nivyx scripts/macos/nivyx scripts/windows/nivyx-impl.ps1"

wanted() {
	# key lines only; a quote would end the shell/PowerShell string
	if grep '^ed25519 ' "$KEYS" | grep -q "'"; then echo "release-keys: no quotes allowed in key lines" >&2; exit 1; fi
	grep -E '^ed25519 ' "$KEYS" || true
	if grep -vqE '^(#|ed25519 [A-Za-z0-9+/]{43}=( [^[:space:]].*)?$|[[:space:]]*$)' "$KEYS"; then
		echo "release-keys: malformed line in $KEYS" >&2; exit 1
	fi
}

embedded() { # file
	awk '/^# BEGIN RELEASE KEYS/ { b = 1; n++; next } /^# END RELEASE KEYS/ { b = 0; next } b && /^ed25519 / { print } END { if (n != 1) exit 3 }' "$1"
}

case "${1:-}" in
check)
	w="$(wanted)"; bad=0
	for t in $TARGETS; do
		e="$(embedded "$ROOT/$t")" || { echo "release-keys: $t has no single RELEASE KEYS block" >&2; exit 1; }
		if [ "$e" != "$w" ]; then
			echo "release-keys: $t differs from scripts/release-keys.txt (run scripts/release-keys.sh sync)" >&2; bad=1
		fi
	done
	[ "$bad" = 0 ] || exit 1
	echo "release keys: $(printf '%s' "$w" | grep -c . || true) key(s), the same in all updaters"
	;;
sync)
	w="$(wanted)"
	for t in $TARGETS; do
		embedded "$ROOT/$t" >/dev/null || { echo "release-keys: $t has no single RELEASE KEYS block" >&2; exit 1; }
		awk -v keys="$w" '
			/^# BEGIN RELEASE KEYS/ { print; b = 1; next }
			/^# END RELEASE KEYS/ { b = 0 }
			b && /^ed25519 / { next }
			{ print }
			b && (/^RELEASE_KEYS=.$/ || /^\$ReleaseKeys = @.$/) { if (keys != "") print keys }
		' "$ROOT/$t" >"$ROOT/$t.tmp"
		cat "$ROOT/$t.tmp" >"$ROOT/$t" && rm -f "$ROOT/$t.tmp"
		echo "updated $t"
	done
	"$0" check
	;;
list)
	OPENSSL="${OPENSSL:-openssl}"
	wanted | while read -r _ b64 comment; do
		printf '%s  %s\n' "$(printf '%s' "$b64" | "$OPENSSL" base64 -d -A | "$OPENSSL" dgst -sha256 -r | cut -c1-16)" "$comment"
	done
	;;
*) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
