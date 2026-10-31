@echo off
setlocal DisableDelayedExpansion
set "PSModuleAnalysisCachePath=NUL"
title OptiMiyoo v0.0.9
set "OPTIMIYOO_SCRIPT=%~dp0app\launch.ps1"
if not exist "%OPTIMIYOO_SCRIPT%" (
    echo ERROR: Extract the entire ZIP before running this launcher.
    pause
    exit /b 1
)
set "OPTIMIYOO_ROOT="
set "OPTIMIYOO_NO_ANIMATION="
:parse_arguments
if "%~1"=="" goto end_arguments
if /I "%~1"=="-NoAnimation" goto no_animation
if defined OPTIMIYOO_ROOT goto invalid_arguments
set "OPTIMIYOO_ROOT=%~1"
shift
goto parse_arguments
:no_animation
if defined OPTIMIYOO_NO_ANIMATION goto invalid_arguments
set "OPTIMIYOO_NO_ANIMATION=1"
shift
goto parse_arguments
:end_arguments
if not "%1"=="" goto invalid_arguments
:launch
rem Pass literal paths through the environment, not PowerShell source or native quoting.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $p=@{NoAnimation=[bool]$env:OPTIMIYOO_NO_ANIMATION}; if($env:OPTIMIYOO_ROOT){$p.Root=$env:OPTIMIYOO_ROOT}; & $env:OPTIMIYOO_SCRIPT @p; exit $LASTEXITCODE"
set "OPTIMIYOO_RESULT=%ERRORLEVEL%"
endlocal & exit /b %OPTIMIYOO_RESULT%
:invalid_arguments
echo ERROR: Use one collection folder and/or -NoAnimation.
endlocal & exit /b 1
