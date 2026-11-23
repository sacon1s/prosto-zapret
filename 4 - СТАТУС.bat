@echo off
rem Zapret Pro [4] - status: is zapret enabled right now? (no admin needed)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\status.ps1"
echo.
pause
exit /b 0
