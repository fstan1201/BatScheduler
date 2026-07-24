@echo off
cd /d "%~dp0"
echo Bat Scheduler + Cloudflare Tunnel
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-tunnel.ps1"
pause
