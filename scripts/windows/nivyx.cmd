@echo off
setlocal
rem PowerShell's own argument binder can swallow a bare "--verbose"/"-v"
rem (and, likewise, "--help"/"-h") token passed through -File (observed
rem for real in CI: `nivyx status --verbose` silently fell back to the
rem short status; `nivyx --help` similarly failed to reach the script's
rem $Command binding as "--help"). Detect these here, in cmd.exe, where
rem there is no such ambiguity, and hand them to the script as
rem environment variables instead of relying on positional binding of a
rem dash-prefixed argument.
set DPICTL_VERBOSE=0
set DPICTL_HELP=0
for %%A in (%*) do (
	if "%%~A"=="--verbose" set DPICTL_VERBOSE=1
	if "%%~A"=="-v" set DPICTL_VERBOSE=1
	if "%%~A"=="--help" set DPICTL_HELP=1
	if "%%~A"=="-h" set DPICTL_HELP=1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dpictl-impl.ps1" %*
