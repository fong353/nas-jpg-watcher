@echo off
setlocal

REM Register a scheduled task to run scan.cmd every 3 minutes.
REM Run this file as Administrator (right-click -> Run as administrator).

set "TASK_NAME=NAS JPG Watcher"
set "HERE=%~dp0"
set "SCAN=%HERE%scan.cmd"

echo Registering task: %TASK_NAME%
echo Script path:      %SCAN%
echo Interval:         every 3 minutes
echo.

schtasks /create ^
  /tn "%TASK_NAME%" ^
  /tr "\"%SCAN%\"" ^
  /sc minute /mo 3 ^
  /rl highest ^
  /f

if %errorlevel% equ 0 (
  echo.
  echo [OK] Task installed. Open Task Scheduler to see "%TASK_NAME%".
  echo Uninstall: double-click uninstall-task.cmd
) else (
  echo.
  echo [FAIL] Install failed. Please run this file as Administrator.
)

endlocal
pause
