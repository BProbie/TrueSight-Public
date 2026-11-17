@echo off
REM ===========================================================================
REM launch.bat -- TrueSight one-click launcher (Windows)
REM
REM Double-click this file, or run it from a terminal:
REM     launch.bat
REM     launch.bat public 8010
REM
REM This batch file is intentionally ASCII-only: cmd.exe reads .bat files using
REM the console code page, so all Chinese text lives in scripts\launch.ps1
REM (UTF-8 with BOM, which Windows PowerShell reads correctly).
REM ===========================================================================

setlocal
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
    echo [ERROR] PowerShell not found. Install Windows PowerShell or PowerShell 7 first.
    pause
    exit /b 1
)

REM Only pass explicit CLI arguments; otherwise launch.ps1 resolves
REM environment variables and truesight.config.json in that order.
set "MODE_ARG="
if not "%~1"=="" set "MODE_ARG=-Mode %~1"
set "PORT_ARG="
if not "%~2"=="" set "PORT_ARG=-Port %~2"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\launch.ps1" %MODE_ARG% %PORT_ARG%
set "EXITCODE=%ERRORLEVEL%"

REM Keep the window open when the launcher failed, so the error is readable.
if not "%EXITCODE%"=="0" (
    echo.
    echo [ERROR] Launcher exited with code %EXITCODE%.
    pause
)
endlocal & exit /b %EXITCODE%
