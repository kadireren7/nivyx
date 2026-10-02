#!/usr/bin/env bash
#
# Cross-platform parity: the same public commands must be dispatched by the
# Linux, macOS and Windows implementations (list: scripts/commands.txt),
# each must have its own `help COMMAND` text everywhere, completions and the
# man page must know them, and no legacy command may remain.
# Static (reads the sources, runs on any OS); the e2e tests additionally run
# `nivyx help <command>` for every command on the real platforms.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
fail=0
bad() { printf 'PARITY FAIL: %s\n' "$1"; fail=1; }

# command labels dispatched by the top-level `case "$cmd"` of the shell
# implementations (labels at column 0, "a | b)" or "a)")
shell_labels() {
	awk '/^case "\$cmd" in/ { in_c = 1; next } in_c && /^esac/ { in_c = 0 }
		in_c && /^[a-z-]+( \| [a-z-]+)*\)/ { sub(/\).*/, ""); gsub(/ \| /, "\n"); print }' "$1"
}
# labels of the final `switch ($Command)` and the early `help` handling
ps_labels() {
	awk '/^switch \(\$Command\)/ { in_s = 1; next } in_s && /^    '"'"'[a-z-]+'"'"'/ { gsub(/^ +'"'"'|'"'"'.*$/, ""); print }' "$1"
	grep -q -- "\$Command -eq 'help'" "$1" && echo help
}
shell_labels scripts/nivyx > /tmp/parity-linux.$$
shell_labels scripts/macos/nivyx > /tmp/parity-macos.$$
ps_labels scripts/windows/nivyx-impl.ps1 > /tmp/parity-windows.$$

n=0
while read -r c; do
	[ -n "$c" ] || continue
	n=$((n + 1))
	grep -qx -- "$c" /tmp/parity-linux.$$ || bad "scripts/nivyx does not dispatch '$c'"
	grep -qx -- "$c" /tmp/parity-macos.$$ || bad "scripts/macos/nivyx does not dispatch '$c'"
	grep -qx -- "$c" /tmp/parity-windows.$$ || bad "nivyx-impl.ps1 does not dispatch '$c'"
	# per-command help text: `help COMMAND` must have an entry on every platform
	grep -Eq "^	$c( \| [a-z-]+)*\) (echo|usage)|^	[a-z| -]*\| $c( \| [a-z-]+)*\) echo|^	$c\) echo" scripts/nivyx || grep -Eq "^	([a-z-]+ \| )*$c( \| [a-z-]+)*\) echo" scripts/nivyx || bad "scripts/nivyx has no help entry for '$c'"
	grep -Eq "^	([a-z-]+ \| )*$c( \| [a-z-]+)*\) echo" scripts/macos/nivyx || bad "scripts/macos/nivyx has no help entry for '$c'"
	grep -Eq "^        '$c' +\{|\{ \\\$_ -in .*'$c'" scripts/windows/nivyx-impl.ps1 || bad "nivyx-impl.ps1 has no help entry for '$c'"
	for f in scripts/completions/nivyx.bash scripts/completions/_nivyx scripts/completions/nivyx.fish scripts/completions/nivyx.ps1; do
		grep -q -- "$c" "$f" || bad "$f does not complete '$c'"
	done
	grep -q -- "$c" scripts/nivyx.1 || bad "man page does not mention '$c'"
done < scripts/commands.txt
rm -f /tmp/parity-linux.$$ /tmp/parity-macos.$$ /tmp/parity-windows.$$

for f in scripts/nivyx scripts/macos/nivyx scripts/windows/nivyx.cmd; do
	grep -q -- '--help' "$f" || bad "$f lacks --help"
done

# one public command only
for f in scripts/dpictl scripts/dpi-proxy-ctl scripts/macos/dpictl scripts/macos/dpi-proxy-ctl \
	scripts/windows/dpictl.cmd scripts/windows/dpi-proxy-ctl.cmd scripts/windows/dpictl-impl.ps1; do
	[ -e "$f" ] && bad "legacy file $f still exists"
done
for f in scripts/macos/package.sh scripts/windows/package.sh scripts/package-linux.sh; do
	grep -Eq 'dpictl|dpi-proxy-ctl' "$f" && bad "$f still packages a legacy command"
done
# public text: legacy names only in the upgrade code, development notes, release notes and tests
hits="$(grep -rIlE 'dpictl|dpi-proxy-ctl' README.md docs scripts/nivyx scripts/macos/nivyx scripts/windows/nivyx-impl.ps1 \
	scripts/windows/nivyx.cmd scripts/completions scripts/nivyx.1 scripts/windows/*.txt scripts/macos/*.txt 2>/dev/null || true)"
for f in $hits; do
	case "$f" in docs/development.md) ;; *) bad "$f mentions a legacy command name" ;; esac
done
[ "$fail" = 0 ] && echo "parity: $n commands dispatched, documented and completed on Linux, macOS and Windows"
exit "$fail"
