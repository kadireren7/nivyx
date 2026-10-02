# bash completion for nivyx
_nivyx() {
	local cur prev cmds
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD-1]}"
	cmds="status start stop restart reload logs doctor diagnose stats config update repair strategy support-bundle version help"
	if [ "$COMP_CWORD" -eq 1 ]; then
		COMPREPLY=($(compgen -W "$cmds --help" -- "$cur"))
		return
	fi
	case "${COMP_WORDS[1]}" in
	status) COMPREPLY=($(compgen -W "--verbose" -- "$cur")) ;;
	diagnose) COMPREPLY=($(compgen -W "--verbose" -- "$cur")) ;;
	update) COMPREPLY=($(compgen -W "--check" -- "$cur")) ;;
	config)
		if [ "$COMP_CWORD" -eq 2 ]; then
			COMPREPLY=($(compgen -W "show path check set unset" -- "$cur"))
		elif [ "${COMP_WORDS[2]}" = set ] && [ "$COMP_CWORD" -eq 4 ]; then
			COMPREPLY=($(compgen -W "pass tlsrec tlsrec-split" -- "$cur"))
		fi
		;;
	help) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "$cmds" -- "$cur")) ;;
	esac
}
complete -F _nivyx nivyx
