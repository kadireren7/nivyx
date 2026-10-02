# fish completion for nivyx
set -l cmds status start stop restart reload logs doctor diagnose stats config update repair strategy support-bundle version help
complete -c nivyx -f
complete -c nivyx -n "not __fish_seen_subcommand_from $cmds" -a "$cmds"
complete -c nivyx -n "__fish_seen_subcommand_from status diagnose" -l verbose -s v
complete -c nivyx -n "__fish_seen_subcommand_from update" -l check
complete -c nivyx -n "__fish_seen_subcommand_from config; and not __fish_seen_subcommand_from show path check set unset" -a "show path check set unset"
complete -c nivyx -n "__fish_seen_subcommand_from help" -a "$cmds"
