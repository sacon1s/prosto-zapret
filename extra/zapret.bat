@echo off
rem Zapret Pro - main menu (self-elevating)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
title Zapret Pro
:menu
cls
echo ==========================================================
echo                    Zapret Pro   [menu]
echo ==========================================================
echo   1. START        - start (saved strategy + check)
echo   2. TUNE         - auto-find working strategy
echo   3. CHECK        - check YouTube / Discord access
echo   4. STOP         - stop zapret
echo   -----------------------------------------------------
echo   5. AUTOSTART INSTALL  - autostart + watchdog (recommended)
echo   6. AUTOSTART REMOVE   - remove autostart
echo   -----------------------------------------------------
echo   7. UPDATE       - update core and lists
echo   8. DNS SET      - Cloudflare DNS + DoH (if ISP poisons DNS)
echo   9. DNS RESET    - back to DHCP
echo  10. DIAGNOSTICS  - check conflicts, DNS, lists
echo  11. EDIT LISTS   - edit user lists
echo  12. TAKE CONTROL - disable ZapretGUI service (give control to us)
echo  13. RESTORE ZAPRETGUI - re-enable ZapretGUI service
echo   0. EXIT
echo ==========================================================
set "c="
set /p "c=Choose: "
if "%c%"=="1"  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\run.ps1" & echo. & pause
if "%c%"=="2"  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\tune.ps1" & echo. & pause
if "%c%"=="3"  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\check.ps1" & echo. & pause
if "%c%"=="4"  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\stop.ps1" & echo. & pause
if "%c%"=="5"  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\install-autostart.ps1" & echo. & pause
if "%c%"=="6"  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\remove-autostart.ps1" & echo. & pause
if "%c%"=="7"  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\update.ps1" & echo. & pause
if "%c%"=="8"  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\dns.ps1" -Action set & echo. & pause
if "%c%"=="9"  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\dns.ps1" -Action reset & echo. & pause
if "%c%"=="10" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\diagnostics.ps1" & echo. & pause
if "%c%"=="11" start notepad "%~dp0..\lists\list-general-user.txt"
if "%c%"=="12" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\take-control.ps1" & echo. & pause
if "%c%"=="13" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\restore-zapretgui.ps1" & echo. & pause
if "%c%"=="0"  exit /b 0
goto menu
