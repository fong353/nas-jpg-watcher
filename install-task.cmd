@echo off
setlocal

REM Register a scheduled task to run scan.cmd every 30 minutes, silently.
REM The task points to scan-silent.vbs so no cmd window flashes on each run.
REM Run this file as Administrator (right-click -> Run as administrator).

set "TASK_NAME=NAS JPG Watcher"
set "HERE=%~dp0"
set "LAUNCHER=%HERE%scan-silent.vbs"

echo Registering task: %TASK_NAME%
echo Launcher:         %LAUNCHER%
echo Interval:         every 30 minutes (silent, no window)
echo.

schtasks /create ^
  /tn "%TASK_NAME%" ^
  /tr "wscript.exe \"%LAUNCHER%\"" ^
  /sc minute /mo 30 ^
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
