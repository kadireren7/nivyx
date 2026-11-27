@echo off
setlocal EnableDelayedExpansion
rem PowerShell's own argument binder can swallow or misread dash-prefixed
rem tokens passed through -File (observed for real in CI: `nivyx status
rem --verbose` silently fell back to the short status, and a leading
rem "--help" aborts with NamedParameterNotFound before any script code
rem runs). So every dash-prefixed option is handled here, in cmd.exe where
rem there is no such ambiguity: --verbose/-v and --check are passed to
rem nivyx-impl.ps1 as environment variables and removed from its argument
rem list, and --help/-h becomes the plain word "help".
set NIVYX_VERBOSE=0
set NIVYX_CHECK=0
set HELP_REQUESTED=0
set PSARGS=
for %%A in (%*) do (
	set "CURARG=%%~A"
	if "!CURARG!"=="--verbose" (
		set NIVYX_VERBOSE=1
	) else if "!CURARG!"=="-v" (
		set NIVYX_VERBOSE=1
	) else if "!CURARG!"=="--check" (
		set NIVYX_CHECK=1
	) else if "!CURARG!"=="--help" (
		set HELP_REQUESTED=1
	) else if "!CURARG!"=="-h" (
		set HELP_REQUESTED=1
	) else (
		set PSARGS=!PSARGS! "%%~A"
	)
)
rem installed: nivyx-impl.ps1 is next to this file; in the package: in files\
set "IMPL=%~dp0nivyx-impl.ps1"
if not exist "%IMPL%" set "IMPL=%~dp0files\nivyx-impl.ps1"
if "%HELP_REQUESTED%"=="1" (
	powershell -NoProfile -ExecutionPolicy Bypass -File "!IMPL!" help
) else (
	powershell -NoProfile -ExecutionPolicy Bypass -File "!IMPL!" !PSARGS!
)
exit /b %ERRORLEVEL%
