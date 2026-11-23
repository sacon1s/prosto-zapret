@echo off
rem Zapret Pro [2] - autostart TOGGLE: run = install, run again = remove (self-elevating)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\autostart-toggle.ps1"
echo.
pause
exit /b 0
