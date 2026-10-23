@echo off
setlocal
title OptiMiyoo v1.0.0
set "OPTIMIYOO_SCRIPT=%~dp0app\launch.ps1"
if not exist "%OPTIMIYOO_SCRIPT%" (
    echo ERROR: Extract the entire ZIP before running this launcher.
    pause
    exit /b 1
)
if "%~1"=="" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%OPTIMIYOO_SCRIPT%"
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%OPTIMIYOO_SCRIPT%" -Root "%~1"
)
set "OPTIMIYOO_RESULT=%ERRORLEVEL%"
endlocal & exit /b %OPTIMIYOO_RESULT%
