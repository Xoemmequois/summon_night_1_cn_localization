@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
)

set RC=%errorlevel%
echo.
if not "%RC%"=="0" echo Script exited with code %RC%.
echo Press any key to close...
pause >nul
exit /b %RC%
