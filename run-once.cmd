@echo off
REM ============================================================
REM  手动跑一次 scan.ps1，方便测试。
REM  双击即可，跑完会停住让你看输出 + scan.log。
REM  计划任务走的是 scan-silent.vbs，与此文件互不影响。
REM ============================================================

chcp 65001 >nul
echo === Running scan.ps1 once (manual test) ===
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan.ps1"

echo.
echo === Done. Last 20 lines of scan.log: ===
powershell.exe -NoProfile -Command "Get-Content -Path '%~dp0scan.log' -Tail 20 -Encoding UTF8"

echo.
pause
