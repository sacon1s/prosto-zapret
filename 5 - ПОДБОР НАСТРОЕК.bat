@echo off
rem Zapret Pro [5] - find best strategy/settings (self-elevating)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
echo Fast mode? [Y/N] - 2-3x faster, checks less precise
choice /c YN /n
if errorlevel 2 set "FAST="
if errorlevel 1 set "FAST=-Fast"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\tune.ps1" %FAST%
echo.
pause
exit /b 0
