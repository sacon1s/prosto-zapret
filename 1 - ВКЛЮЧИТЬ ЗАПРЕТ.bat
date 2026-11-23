@echo off
rem Zapret Pro [1] - enable. First run = full auto-setup, then fast start.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
if not exist "%~dp0.setup-done" (
    echo === First run: full setup ===
    echo Driver fix, foreign managers, strategy tuning, Discord media pins, autostart.
    echo This takes 3-5 minutes. Do not close the window.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\setup-full.ps1"
    if not errorlevel 1 type nul > "%~dp0.setup-done"
    echo.
    pause
    exit /b 0
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\run.ps1"
if errorlevel 1 (
    echo.
    pause
)
exit /b 0
