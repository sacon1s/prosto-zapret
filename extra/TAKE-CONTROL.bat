@echo off
rem Zapret Pro - disable third-party winws manager (ZapretGUI) and hand control to our watchdog
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\take-control.ps1"
echo.
pause
exit /b 0
