@echo off
rem Zapret Pro - undo take-control: re-enable ZapretGUI service
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\restore-zapretgui.ps1"
echo.
pause
exit /b 0
