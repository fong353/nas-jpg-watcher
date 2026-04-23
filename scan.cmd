@echo off
REM ============================================================
REM  NAS JPG metadata scanner (forwards to PowerShell)
REM  All real logic and config live in scan.ps1 in the same folder.
REM ============================================================

REM Switch console codepage to UTF-8 so exiftool STDOUT (paths, errors)
REM reads back cleanly in the log.
chcp 65001 >nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan.ps1"
