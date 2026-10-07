@echo off
setlocal
rem Gets this repo onto a fresh CBR workstation, then optionally runs provision.ps1.
rem Copy this file onto the machine (USB stick, or "Download raw file" on GitHub while signed in).
rem
rem   bootstrap.bat          download or update the repo only
rem   bootstrap.bat JOHN     then provision this machine as JOHN, PAUL, GEORGE or RINGO
rem
rem Asks for administrator rights if it doesn't have them. Safe to run again.

set "REPO_URL=https://github.com/oliverb-cbr/cbr-beatles.git"
set "ROOT=C:\CBR"
set "REPO=C:\CBR\cbr-beatles"
set "GIT=C:\Program Files\Git\cmd\git.exe"

rem ---- Elevate ------------------------------------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
    echo Asking for administrator rights...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
    )
    exit /b
)

rem ---- Git ----------------------------------------------------------------------------------
if not exist "%GIT%" (
    where winget >nul 2>&1
    if errorlevel 1 (
        echo winget isn't available. Update "App Installer" from the Microsoft Store, then run this again.
        pause
        exit /b 1
    )
    echo Installing Git...
    winget install --id Git.Git --exact --scope machine --silent --accept-source-agreements --accept-package-agreements
)
if not exist "%GIT%" (
    echo Git didn't install - see the messages above.
    pause
    exit /b 1
)

rem ---- C:\CBR: staff can read the scripts, only admins can change them ----------------------
if not exist "%ROOT%" mkdir "%ROOT%"
icacls "%ROOT%" /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "Users:(OI)(CI)RX" /T /Q >nul

"%GIT%" config --system --get-all safe.directory 2>nul | findstr /i /x "C:/CBR/cbr-beatles" >nul
if errorlevel 1 "%GIT%" config --system --add safe.directory C:/CBR/cbr-beatles

rem ---- Clone or update ----------------------------------------------------------------------
if exist "%REPO%\.git" (
    echo Updating the repo...
    "%GIT%" -C "%REPO%" pull --ff-only
) else (
    echo Downloading the repo. A browser window will ask you to sign in to GitHub.
    "%GIT%" clone "%REPO_URL%" "%REPO%"
)
if errorlevel 1 (
    echo Git failed - see the messages above.
    pause
    exit /b 1
)

rem ---- Provision -----------------------------------------------------------------------------
if "%~1"=="" (
    echo.
    echo The repo is in %REPO%.
    echo To build this machine, run: bootstrap.bat JOHN  - or PAUL, GEORGE, RINGO.
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%\scripts\provision.ps1" -Machine %~1
)
echo.
pause
