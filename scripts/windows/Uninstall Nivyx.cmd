@echo off
setlocal
rem Nivyx: double-click uninstaller for Windows. Elevates itself and
rem runs uninstall.ps1 from this same folder; the exit code is
rem uninstall.ps1's own (1223 = UAC prompt declined, 6 = Windows could
rem not start the elevated uninstaller for another reason, 3 = uninstall.ps1
rem missing). Add -Purge to also remove settings and logs: run
rem uninstall.ps1 directly for that (see WINDOWS-QUICKSTART.txt).

if not exist "%~dp0uninstall.ps1" (
	echo Nivyx: uninstall.ps1 was not found next to this file.
	echo Run "Uninstall Nivyx.cmd" from the Nivyx program folder
	echo ^(%ProgramFiles%\dpi-proxy^) or from the extracted ZIP folder.
	echo.
	pause
	exit /b 3
)

net session >nul 2>&1
if %errorlevel% == 0 goto :run

echo Removing Nivyx needs administrator rights.
echo A User Account Control prompt will appear - choose Yes.
set "NIVYX_SELF=%~f0"
set "NIVYX_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
	"try { $p = Start-Process -FilePath $env:NIVYX_SELF -WorkingDirectory $env:NIVYX_DIR -Verb RunAs -Wait -PassThru; exit $p.ExitCode } catch { $e = $_.Exception; while ($e -and $e -isnot [ComponentModel.Win32Exception]) { $e = $e.InnerException }; if ($e -and $e.NativeErrorCode -eq 1223) { exit 1223 }; [Console]::Error.WriteLine('Nivyx: Windows could not start the elevated uninstaller: ' + $_.Exception.Message); exit 6 }"
set RC=%errorlevel%
if "%RC%"=="1223" (
	echo.
	echo Nivyx was NOT removed: the administrator prompt was declined.
	echo.
	pause
)
rem 6: elevation itself failed for another reason (not a declined prompt),
rem e.g. a policy that blocks it; the reason was printed above
if "%RC%"=="6" (
	echo.
	echo Nivyx was NOT removed: Windows did not start it with administrator rights
	echo ^(see the message above^). Nothing was changed.
	echo.
	pause
)
exit /b %RC%

:run
cd /d "%~dp0"
echo Uninstalling Nivyx...
powershell -NoProfile -ExecutionPolicy Bypass -File ".\uninstall.ps1"
set RC=%errorlevel%
echo.
if not "%RC%"=="0" echo Uninstall reported error %RC%. See the messages above.
echo Press any key to close this window...
pause >nul
exit /b %RC%
