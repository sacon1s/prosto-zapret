@echo off
rem Zapret Pro - diagnostics (no admin needed)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\diagnostics.ps1"
echo.
pause
exit /b 0
