<#
.SYNOPSIS
    What bootstrap.bat runs once it has the latest repo: set up, update or check this PC, or make
    the install USB stick.

.DESCRIPTION
    Shows only what makes sense on this PC:
    - A CBR workstation (hostname in the manifest): update it, check it, or make the USB stick.
    - A PC installed from the CBR stick but not set up yet (it has the cbradmin account): set it
      up as JOHN, PAUL, GEORGE or RINGO, or make the USB stick.
    - Any other PC: only make the USB stick, so a set-up can't wreck someone's own computer.

    Setting up leaves a task that carries on after each restart when cbradmin signs in, and
    provision.ps1 leaves one that sets up WSL and Docker the first time CBR signs in.

.EXAMPLE
    bootstrap.bat            (menu)
    bootstrap.bat JOHN       (set up this PC as JOHN, still with the checks and confirmation)
    bootstrap.bat usb        (make or refresh the install USB stick)
#>
[CmdletBinding()]
param(
    # JOHN, PAUL, GEORGE or RINGO; usb, update or audit; continue (used by the sign-in task).
    # Empty shows the menu.
    [string]$Action,
    # With 'continue': the machine being set up.
    [string]$Machine
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

$manifest = Get-CbrManifest
$settings = $manifest.Settings
$continueTask = 'CBR - continue setup after restart'
$git = 'C:\Program Files\Git\cmd\git.exe'

$thisMachine = $manifest.Machines | Where-Object { $_.ComputerName -eq $env:COMPUTERNAME }
# Only a PC installed from the CBR stick has this account (windows\autounattend.xml makes it).
$fromStick = [bool](Get-LocalUser -Name $settings.AdminUser -ErrorAction SilentlyContinue)

# Exit code 0 even after a failure: the message is on screen and this has already waited for
# Enter, so bootstrap.bat needn't pause again. Only an unexpected error exits non-zero.
function Exit-AfterKey {
    Read-Host "`nPress Enter to close this window" | Out-Null
    exit 0
}

function Confirm-YesNo([string]$Question) {
    (Read-Host "$Question (y/N)").Trim() -match '^(y|yes)$'
}

# Runs provision.ps1 in this window and returns its exit code: 0 done, 3010 restart to carry on.
function Invoke-Provision([hashtable]$Arguments = @{}) {
    try {
        & (Join-Path $PSScriptRoot 'provision.ps1') @Arguments | Out-Host
        $LASTEXITCODE
    } catch {
        Write-Host "`nProvisioning stopped: $($_.Exception.Message)" -ForegroundColor Red
        1
    }
}

# True if another computer on the network already answers to this name (often the test VM).
function Test-NameTaken([string]$ComputerName) {
    try { $found = [Net.Dns]::GetHostAddresses($ComputerName) } catch { return $false }
    $mine = @(Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { ($_.IPAddress -split '%')[0] })
    @($found | Where-Object { $mine -notcontains ($_.IPAddressToString -split '%')[0] }).Count -gt 0
}

function Request-Restart {
    Write-Host "`nThis PC needs to restart to carry on." -ForegroundColor Yellow
    Write-Host "After the restart, sign in as $($settings.AdminUser). Setup carries on by itself in a window like this one."
    Read-Host 'Press Enter to restart now (or close this window to restart later)' | Out-Null
    Restart-Computer -Force
    exit 0
}

# After a provision run: restart and carry on, or tidy up and say what's left.
function Complete-Setup([int]$Code, [string]$ComputerName) {
    if ($Code -eq 3010) { Request-Restart }
    Unregister-CbrTask $continueTask
    if ($Code -ne 0) {
        Write-Host "`nSetup didn't finish. The log is in C:\CBR\logs. Fix the problem above, then run bootstrap.bat again." -ForegroundColor Red
        Exit-AfterKey
    }
    Write-Host ''
    Write-Host "$ComputerName is set up." -ForegroundColor Green
    Write-Host 'Anything under "Problems" above still needs sorting; run bootstrap.bat again afterwards.'
    if (-not (Test-Path (Get-StaffSetupMarker))) {
        Write-Host ''
        Write-Host 'Next:' -ForegroundColor Cyan
        Write-Host " 1. Sign out, then sign in as $($settings.SharedUser). Ubuntu, Docker and GPU support set themselves up"
        Write-Host '    in a window (10-20 minutes, once only).'
        Write-Host " 2. Still as $($settings.SharedUser), sign in to Steam, Epic Games, Unity Hub and Meta Quest Developer Hub"
        Write-Host '    with the shared CBR accounts.'
    }
    Exit-AfterKey
}

function Invoke-Setup([string]$Name) {
    $entry = $manifest.Machines | Where-Object { $_.Name -eq $Name }
    if (-not $entry) { throw "There's no machine called '$Name' in the manifest." }

    # The checks that stop this wrecking the wrong computer.
    if (-not $fromStick) {
        Write-Host "This PC wasn't installed from the CBR USB stick (it has no '$($settings.AdminUser)' account)." -ForegroundColor Red
        Write-Host 'Setting it up would rename it, remove apps and change its settings, so this script won''t.'
        Exit-AfterKey
    }
    if ($env:USERNAME -ne $settings.AdminUser) {
        Write-Host "Sign in as $($settings.AdminUser) to set up this PC (you're $env:USERNAME)." -ForegroundColor Red
        Exit-AfterKey
    }
    if ($thisMachine -and $thisMachine.Name -ne $Name) {
        Write-Host "This PC is already $($thisMachine.ComputerName). It can't be set up as $Name too." -ForegroundColor Red
        Exit-AfterKey
    }

    if (-not $thisMachine) {
        Write-Host "`nChecking the network for another computer called $($entry.ComputerName)..."
        if (Test-NameTaken $entry.ComputerName) {
            Write-Host "Something on the network already answers to $($entry.ComputerName): maybe the test VM, or a" -ForegroundColor Yellow
            Write-Host 'workstation that was already built. Two PCs with one name cause problems: turn the other one off first.' -ForegroundColor Yellow
            Write-Host '(Straight after a PC is reinstalled, its old name can linger on the network for a while.)' -ForegroundColor Yellow
            if (-not (Confirm-YesNo 'Carry on anyway?')) { Exit-AfterKey }
        }
        $freeGB = [math]::Floor((Get-PSDrive C).Free / 1GB)
        if ($freeGB -lt 250) {
            Write-Host "C: has only $freeGB GB free. All the apps need about 250 GB." -ForegroundColor Yellow
            if (-not (Confirm-YesNo 'Carry on anyway?')) { Exit-AfterKey }
        }

        Write-Host ''
        Write-Host "This turns this PC into $($entry.ComputerName):" -ForegroundColor Cyan
        Write-Host " - renames it $($entry.ComputerName) and restarts it when needed"
        Write-Host " - creates the shared staff account $($settings.SharedUser) (you choose its password)"
        Write-Host ' - removes OneDrive and the preinstalled Store apps; turns off adverts and most telemetry'
        Write-Host ' - installs the apps in the manifest. A few open their own installer: click through those.'
        Write-Host " - carries on by itself after each restart, once you sign in as $($settings.AdminUser)"
        Write-Host 'It takes a couple of hours, mostly downloads. Keep the PC plugged in to the network.'
        if ((Read-Host "`nType $Name to go ahead").Trim() -ne $Name) {
            Write-Host 'Cancelled. Nothing has changed.'
            Exit-AfterKey
        }
    }

    # Registered before anything else, so setup still carries on if something restarts the PC early.
    Register-CbrSignInTask -Name $continueTask -User $settings.AdminUser -Elevated `
        -Script $PSCommandPath -Arguments "-Action continue -Machine $Name"
    Complete-Setup (Invoke-Provision @{ Machine = $Name }) $entry.ComputerName
}

function Resume-Setup([string]$Name) {
    $host.UI.RawUI.WindowTitle = 'CBR setup'
    Write-Host 'Carrying on with setting up this PC after the restart. Leave this window open.' -ForegroundColor Cyan
    if (-not (Wait-Internet)) { Write-Host "No internet yet; carrying on, but downloads will fail." -ForegroundColor Yellow }
    else {
        & $git -C $settings.RepoPath pull --ff-only
        if ($LASTEXITCODE -ne 0) { Write-Host 'Couldn''t update the scripts; carrying on with this copy.' -ForegroundColor Yellow }
    }
    $entry = $manifest.Machines | Where-Object { $_.Name -eq $Name }
    Complete-Setup (Invoke-Provision @{ Machine = $Name }) $entry.ComputerName
}

function Invoke-Update {
    & (Join-Path $PSScriptRoot 'update.ps1') -SkipPull
    if ($LASTEXITCODE -eq 3010) {
        Write-Host "`nRestart this PC to finish the update." -ForegroundColor Yellow
        if (Confirm-YesNo 'Restart now?') { Restart-Computer -Force }
    }
    Exit-AfterKey
}

function Read-MachineName {
    $names = @($manifest.Machines | ForEach-Object Name)
    while ($true) {
        $answer = (Read-Host "Which one is this PC? Type $($names -join ', ') (or Q to quit)").Trim().ToUpper()
        if ($answer -eq 'Q') { exit 0 }
        if ($names -contains $answer) { return $answer }
        Write-Host "That's not one of them." -ForegroundColor Yellow
    }
}

function Show-Menu {
    $host.UI.RawUI.WindowTitle = 'CBR workstations'
    Write-Host ''
    Write-Host 'CBR workstations' -ForegroundColor Cyan
    Write-Host "This PC: $env:COMPUTERNAME, signed in as $env:USERNAME"
    Write-Host ''
    $items = [ordered]@{}
    if ($thisMachine) {
        $items['1'] = @('Update this PC: apps, settings and any new apps in the manifest', 'update')
        $items['2'] = @('Check this PC against the manifest (changes nothing)', 'audit')
        $items['3'] = @('Make or refresh the install USB stick', 'usb')
    } elseif ($fromStick) {
        $items['1'] = @('Set up this PC as a CBR workstation (JOHN, PAUL, GEORGE or RINGO)', 'setup')
        $items['2'] = @('Make or refresh the install USB stick', 'usb')
    } else {
        Write-Host "This PC wasn't installed from the CBR USB stick, so the only thing to do here is make the stick."
        Write-Host ''
        $items['1'] = @('Make or refresh the install USB stick', 'usb')
    }
    foreach ($key in $items.Keys) { Write-Host "  $key  $($items[$key][0])" }
    Write-Host '  Q  Quit'
    while ($true) {
        $choice = (Read-Host "`nChoose").Trim().ToUpper()
        if ($choice -eq 'Q') { exit 0 }
        if ($items.Contains($choice)) { return $items[$choice][1] }
        Write-Host 'Type one of the numbers above.' -ForegroundColor Yellow
    }
}

if (-not (Test-IsAdmin)) { throw 'Run this through bootstrap.bat, which asks for administrator rights.' }

$todo = $(if ($Action) { $Action } else { Show-Menu })
switch -Regex ($todo) {
    '^continue$' { Resume-Setup $Machine }
    '^setup$'    { Invoke-Setup (Read-MachineName) }
    '^update$'   { Invoke-Update }
    '^audit$'    { & (Join-Path $PSScriptRoot 'audit.ps1'); Exit-AfterKey }
    '^usb$'      {
        try { & (Join-Path $PSScriptRoot 'make-usb.ps1') }
        catch { Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red; Exit-AfterKey }
        Exit-AfterKey
    }
    default {
        $name = $todo.ToUpper()
        if (@($manifest.Machines | ForEach-Object Name) -contains $name) { Invoke-Setup $name }
        else { throw "Unknown choice '$todo'. Use JOHN, PAUL, GEORGE, RINGO, usb, update or audit." }
    }
}
