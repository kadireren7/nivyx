@echo off
setlocal
rem Nivyx: double-click installer for Windows (also upgrades an existing
rem installation in place). Elevates itself (a UAC prompt appears), runs
rem files\install.ps1 and keeps the window open so you can read the
rem result. Exit code: install.ps1's own (0 installed, 2 files missing,
rem 4 failed and undone, 5 failed and the previous version could not be
rem restarted), 1223 = UAC prompt declined, 6 = Windows could not start
rem it elevated for another reason (e.g. a policy), 3 = not extracted.

rem Run straight from inside the ZIP, Explorer extracts only this file
rem to a temporary folder: nothing else is next to it.
if not exist "%~dp0files\install.ps1" (
	echo Nivyx: the "files" folder was not found next to this file.
	echo Extract the whole ZIP first ^(right click - Extract All^), then
	echo double-click "Install Nivyx.cmd" in the extracted folder.
	echo.
	pause
	exit /b 3
)

rem "net session" only succeeds for an already-elevated process.
net session >nul 2>&1
if %errorlevel% == 0 goto :run

echo Nivyx needs administrator rights to install a service.
echo A User Account Control prompt will appear - choose Yes.
rem The path goes through the environment, not into the command text, so
rem folder names with quotes or apostrophes cannot break it. -Wait keeps
rem the elevated window's exit code.
set "NIVYX_SELF=%~f0"
set "NIVYX_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
	"try { $p = Start-Process -FilePath $env:NIVYX_SELF -WorkingDirectory $env:NIVYX_DIR -Verb RunAs -Wait -PassThru; exit $p.ExitCode } catch { $e = $_.Exception; while ($e -and $e -isnot [ComponentModel.Win32Exception]) { $e = $e.InnerException }; if ($e -and $e.NativeErrorCode -eq 1223) { exit 1223 }; [Console]::Error.WriteLine('Nivyx: Windows could not start the elevated installer: ' + $_.Exception.Message); exit 6 }"
set RC=%errorlevel%
if "%RC%"=="1223" (
	echo.
	echo Nivyx was NOT installed: the administrator prompt was declined.
	echo Nothing was changed. Double-click "Install Nivyx.cmd" again and
	echo choose Yes to install.
	echo.
	pause
)
if "%RC%"=="6" (
	echo.
	echo Nivyx was NOT installed: Windows did not start it with administrator rights
	echo ^(see the message above^). Nothing was changed.
	echo.
	pause
)
exit /b %RC%

:run
cd /d "%~dp0"
echo Installing Nivyx...
powershell -NoProfile -ExecutionPolicy Bypass -File ".\files\install.ps1"
set RC=%errorlevel%
echo.
if "%RC%"=="0" (
	echo Nivyx is installed and running.
) else (
	echo Nivyx was NOT installed ^(error %RC%^). See the messages above.
	echo Your normal internet connection was left working.
)
echo.
echo Press any key to close this window...
pause >nul
exit /b %RC%
