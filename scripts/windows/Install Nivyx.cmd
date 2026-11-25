@echo off
setlocal
rem Nivyx: double-click installer for Windows.
rem
rem Elevates itself (a UAC prompt appears) and runs install.ps1 from
rem this same folder, then keeps the window open so you can read the
rem result. The exit code is install.ps1's own (0 = installed;
rem 1 = not elevated, 2 = files missing, 4 = install/health check
rem failed and was undone; 1223 = UAC prompt declined; 3 = install.ps1
rem itself is missing). For manual or scripted installs, run install.ps1
rem directly instead (see WINDOWS-QUICKSTART.txt).

rem Run straight from inside the ZIP, Explorer extracts only this file
rem to a temporary folder: nothing else is next to it.
if not exist "%~dp0install.ps1" (
	echo Nivyx: install.ps1 was not found next to this file.
	echo Extract the whole ZIP first ^(right click - Extract All^), then
	echo double-click "Install Nivyx.cmd" in the extracted folder.
	echo.
	pause
	exit /b 3
)

rem "net session" only succeeds for an already-elevated process; it is
rem the standard, dependency-free way to test for administrator rights
rem from a batch file.
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
	"try { $p = Start-Process -FilePath $env:NIVYX_SELF -WorkingDirectory $env:NIVYX_DIR -Verb RunAs -Wait -PassThru; exit $p.ExitCode } catch { exit 1223 }"
set RC=%errorlevel%
if "%RC%"=="1223" (
	echo.
	echo Nivyx was NOT installed: the administrator prompt was declined.
	echo Nothing was changed. Double-click "Install Nivyx.cmd" again and
	echo choose Yes to install.
	echo.
	pause
)
exit /b %RC%

:run
cd /d "%~dp0"
echo Installing Nivyx...
powershell -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"
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
