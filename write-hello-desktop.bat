@echo off
setlocal EnableExtensions

for /f "delims=" %%D in ('powershell -NoProfile -Command "[Environment]::GetFolderPath('Desktop')"') do set "DESKTOP=%%D"
set "OUTFILE=%DESKTOP%\hello-world.txt"

(
  echo hello world
  echo %date% %time%
) > "%OUTFILE%"

endlocal
