@echo off
rem Zapret Pro - check access (no admin needed)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\check.ps1"
echo.
pause
exit /b 0
