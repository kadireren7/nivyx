# PowerShell completion for nivyx. Load it with:
#   . "$env:ProgramFiles\dpi-proxy\nivyx-completion.ps1"
# (add that line to your $PROFILE to keep it)
Register-ArgumentCompleter -Native -CommandName nivyx -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $cmds = 'status','start','stop','restart','reload','logs','doctor','diagnose','stats','config','update','repair','strategy','support-bundle','version','help'
    $words = @($commandAst.CommandElements | ForEach-Object { $_.ToString() })
    $n = $words.Count
    if ($wordToComplete) { $n-- }
    if ($n -le 1) { $list = $cmds }
    else {
        switch ($words[1]) {
            'status'   { $list = '--verbose' }
            'diagnose' { $list = '--verbose' }
            'update'   { $list = '--check' }
            'config'   { if ($n -eq 2) { $list = 'show','path','check','set','unset' }
                         elseif ($words[2] -eq 'set' -and $n -eq 4) { $list = 'pass','tlsrec','tlsrec-split' } }
            'help'     { if ($n -eq 2) { $list = $cmds } }
        }
    }
    $list | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}
