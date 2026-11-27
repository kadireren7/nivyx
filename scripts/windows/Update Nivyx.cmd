@echo off
setlocal
rem Nivyx: double-click updater for Windows. Elevates itself, then:
rem   - Nivyx installed: runs `nivyx update` (downloads the latest
rem     release, checks it, installs it; rolls back if it fails);
rem   - not installed, or an older "dpi-proxy" version: installs the
rem     version in this folder (settings of an older version are kept).
rem Exit code: the update's or installer's own, 1223 = UAC prompt
rem declined, 6 = Windows could not start it elevated, 3 = not extracted.

if not exist "%~dp0files\install.ps1" (
	echo Nivyx: the "files" folder was not found next to this file.
	echo Extract the whole ZIP first ^(right click - Extract All^), then
	echo double-click "Update Nivyx.cmd" in the extracted folder.
	echo.
	pause
	exit /b 3
)

net session >nul 2>&1
if %errorlevel% == 0 goto :run

echo Updating Nivyx needs administrator rights.
echo A User Account Control prompt will appear - choose Yes.
set "NIVYX_SELF=%~f0"
set "NIVYX_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
	"try { $p = Start-Process -FilePath $env:NIVYX_SELF -WorkingDirectory $env:NIVYX_DIR -Verb RunAs -Wait -PassThru; exit $p.ExitCode } catch { $e = $_.Exception; while ($e -and $e -isnot [ComponentModel.Win32Exception]) { $e = $e.InnerException }; if ($e -and $e.NativeErrorCode -eq 1223) { exit 1223 }; [Console]::Error.WriteLine('Nivyx: Windows could not start the elevated updater: ' + $_.Exception.Message); exit 6 }"
set RC=%errorlevel%
if "%RC%"=="1223" (
	echo.
	echo Nivyx was NOT updated: the administrator prompt was declined.
	echo.
	pause
)
if "%RC%"=="6" (
	echo.
	echo Nivyx was NOT updated: Windows did not start it with administrator rights
	echo ^(see the message above^). Nothing was changed.
	echo.
	pause
)
exit /b %RC%

:run
cd /d "%~dp0"
set "IMPL=%ProgramFiles%\Nivyx\nivyx-impl.ps1"
if exist "%IMPL%" (
	echo Checking for a newer Nivyx...
	powershell -NoProfile -ExecutionPolicy Bypass -File "%IMPL%" update
) else (
	echo Installing the Nivyx version in this folder...
	powershell -NoProfile -ExecutionPolicy Bypass -File ".\files\install.ps1"
)
set RC=%errorlevel%
echo.
if not "%RC%"=="0" (
	echo Nivyx was NOT updated ^(error %RC%^). See the messages above.
	echo The installed version was left working.
)
echo.
echo Press any key to close this window...
pause >nul
exit /b %RC%
