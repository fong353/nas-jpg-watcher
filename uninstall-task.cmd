@echo off
setlocal
set "TASK_NAME=NAS JPG Watcher"
schtasks /delete /tn "%TASK_NAME%" /f
if %errorlevel% equ 0 (
  echo [OK] Task uninstalled
) else (
  echo [FAIL] Uninstall failed (task may not be installed)
)
endlocal
pause
