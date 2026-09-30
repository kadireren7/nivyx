@echo off
setlocal
rem Nivyx: double-click uninstaller for Windows. Elevates itself and
rem runs uninstall.ps1 from this same folder. Add -Purge to also
rem remove settings and logs: run uninstall.ps1 directly for that
rem (see WINDOWS-QUICKSTART.txt).

net session >nul 2>&1
if %errorlevel% == 0 goto :run

echo Removing Nivyx needs administrator rights.
echo A User Account Control prompt will appear - choose Yes.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
	"Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs"
exit /b 0

:run
cd /d "%~dp0"
echo Uninstalling Nivyx...
powershell -NoProfile -ExecutionPolicy Bypass -File ".\uninstall.ps1"
echo.
echo Press any key to close this window...
pause >nul
