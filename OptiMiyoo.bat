@echo off
setlocal DisableDelayedExpansion
title OptiMiyoo v1.0.0
set "OPTIMIYOO_SCRIPT=%~dp0app\launch.ps1"
if not exist "%OPTIMIYOO_SCRIPT%" (
    echo ERROR: Extract the entire ZIP before running this launcher.
    pause
    exit /b 1
)
if "%~1"=="" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%OPTIMIYOO_SCRIPT%"
) else (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%OPTIMIYOO_SCRIPT%" -Root "%~1"
)
set "OPTIMIYOO_RESULT=%ERRORLEVEL%"
endlocal & exit /b %OPTIMIYOO_RESULT%
