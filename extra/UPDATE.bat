@echo off
rem Zapret Pro - update core + lists from upstream (self-elevating)
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\update.ps1"
echo.
pause
exit /b 0
