@echo off
rem CBR workstations: the one file to run, on any Windows PC.
rem Gets the latest scripts from GitHub, then offers what makes sense on this PC:
rem   - on your own PC: make or refresh the install USB stick
rem   - on a PC just installed from that stick: set it up as JOHN, PAUL, GEORGE or RINGO
rem   - on a CBR workstation: update it, check it, or refresh the stick
rem
rem   bootstrap.bat          show the menu
rem   bootstrap.bat JOHN     set up this PC as JOHN (or PAUL, GEORGE, RINGO)
rem   bootstrap.bat usb      make or refresh the install USB stick
rem
rem Asks for administrator rights if it doesn't have them. Safe to run again.

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

rem ---- Run from a copy, so the USB stick can be rewritten while this runs ---------------------
rem (Windows reads a .bat file as it goes; changing it mid-run would run garbage.)
if defined CBR_FROM goto :running
set "CBR_FROM=%~dp0"
copy /y "%~f0" "%TEMP%\cbr-bootstrap.bat" >nul
"%TEMP%\cbr-bootstrap.bat" %1

:running
setlocal
title CBR workstations
set "REPO_URL=https://github.com/oliverb-cbr/cbr-beatles.git"
set "ROOT=C:\CBR"
set "REPO=C:\CBR\cbr-beatles"
set "GIT=C:\Program Files\Git\cmd\git.exe"

rem ---- Network drivers from the stick, for a PC whose network port Windows has no driver for --
if exist "%CBR_FROM%cbr-deploy\drivers\" (
    echo Installing drivers from "%CBR_FROM%cbr-deploy\drivers"
    pnputil /add-driver "%CBR_FROM%cbr-deploy\drivers\*.inf" /subdirs /install
)

rem ---- Internet -----------------------------------------------------------------------------
set /a tries=0
:checknet
curl.exe --silent --head --max-time 10 --output nul https://github.com
if not errorlevel 1 goto :netok
set /a tries+=1
if %tries%==1 echo Waiting for an internet connection...
if %tries% lss 12 (
    timeout /t 10 /nobreak >nul
    goto :checknet
)
echo.
echo No internet connection. Check the network cable.
echo If Windows has no driver for this PC's network port, unzip the motherboard maker's
echo network driver into cbr-deploy\drivers on the USB stick, then run this again.
pause
exit /b 1
:netok

rem ---- Git ----------------------------------------------------------------------------------
if exist "%GIT%" goto :gitok
call :waitwinget
if errorlevel 1 (
    pause
    exit /b 1
)
echo Installing Git...
winget install --id Git.Git --exact --scope machine --silent --accept-source-agreements --accept-package-agreements
if not exist "%GIT%" (
    echo Git didn't install - see the messages above.
    pause
    exit /b 1
)
:gitok

rem ---- C:\CBR: staff can read the scripts, only admins can change them ----------------------
if not exist "%ROOT%" mkdir "%ROOT%"
rem Permissions go on C:\CBR itself; everything inside just inherits them.
icacls "%ROOT%" /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" "Users:(OI)(CI)RX" /Q >nul
icacls "%ROOT%\*" /reset /T /C /Q >nul 2>&1

"%GIT%" config --system --get-all safe.directory 2>nul | findstr /i /x "C:/CBR/cbr-beatles" >nul
if errorlevel 1 "%GIT%" config --system --add safe.directory C:/CBR/cbr-beatles

rem ---- Clone or update ----------------------------------------------------------------------
if exist "%REPO%\.git" (
    echo Getting the latest scripts...
    "%GIT%" -C "%REPO%" pull --ff-only
) else (
    echo Downloading the scripts. If GitHub asks you to sign in, a browser window opens.
    "%GIT%" clone "%REPO_URL%" "%REPO%"
)
if errorlevel 1 (
    echo Git failed - see the messages above.
    pause
    exit /b 1
)

rem ---- Hand over to the menu in the repo, which is always the latest -------------------------
rem start.ps1 waits for Enter itself; a non-zero exit means it stopped with an error.
powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO%\scripts\start.ps1" %1
if errorlevel 1 pause
exit /b

rem ---- winget can take a few minutes to appear on a brand-new Windows install ----------------
:waitwinget
where winget >nul 2>&1
if not errorlevel 1 exit /b 0
echo Getting winget ready. On a new Windows install this can take a few minutes...
powershell -NoProfile -Command "Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe" >nul 2>&1
for /l %%i in (1,1,18) do (
    where winget >nul 2>&1
    if not errorlevel 1 exit /b 0
    timeout /t 10 /nobreak >nul
)
echo winget still isn't available. Run Windows Update, and update "App Installer" in the
echo Microsoft Store, then run this again.
exit /b 1
