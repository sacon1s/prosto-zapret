@echo off
rem Zapret Pro - PIN Discord media domains to working IPs in hosts (fast, 3 seconds)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\fix-media-hosts.ps1" -Action add
echo.
pause
exit /b 0
