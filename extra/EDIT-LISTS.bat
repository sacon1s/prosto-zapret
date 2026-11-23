@echo off
rem Zapret Pro - edit user lists (your own domains / excludes)
start notepad "%~dp0..\lists\list-general-user.txt"
start notepad "%~dp0..\lists\list-exclude-user.txt"
start notepad "%~dp0..\lists\ipset-exclude-user.txt"
exit /b 0
