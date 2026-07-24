@echo off
cd /d "%~dp0"
echo Starting Bat Scheduler...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
pause
