@echo off
setlocal
rem PowerShell's own argument binder can swallow a bare "--verbose"/"-v"
rem token passed through -File (observed for real in CI: `nivyx status
rem --verbose` silently fell back to the short status). Detect it here,
rem in cmd.exe, where there is no such ambiguity, and hand it to the
rem script as an environment variable instead of relying on positional
rem binding of a dash-prefixed argument.
rem
rem "--help"/"-h" as the FIRST argument is worse: PowerShell's -File
rem tries to bind it as a *named* parameter ("-help"), finds no such
rem parameter on dpictl-impl.ps1, and aborts with a
rem NamedParameterNotFound error before any script code (env vars
rem included) ever runs. Rewritten below to the single literal word
rem "help" instead, which binds fine positionally.
set DPICTL_VERBOSE=0
set HELP_REQUESTED=0
for %%A in (%*) do (
	if "%%~A"=="--verbose" set DPICTL_VERBOSE=1
	if "%%~A"=="-v" set DPICTL_VERBOSE=1
	if "%%~A"=="--help" set HELP_REQUESTED=1
	if "%%~A"=="-h" set HELP_REQUESTED=1
)
if "%HELP_REQUESTED%"=="1" (
	powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dpictl-impl.ps1" help
) else (
	powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dpictl-impl.ps1" %*
)
