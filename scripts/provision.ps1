<#
.SYNOPSIS
    Builds or re-converges a CBR workstation to match manifest.psd1.

.DESCRIPTION
    Run as the local admin account. Safe to run again at any time: it only installs what is
    missing, fixes pinned apps at the wrong version and re-applies Windows settings.
    With -Upgrade it also upgrades every app whose policy is 'current'.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\CBR\cbr-beatles\scripts\provision.ps1 -Machine JOHN
#>
[CmdletBinding()]
param(
    # Machine name from manifest.psd1 (JOHN, PAUL, GEORGE, RINGO). Defaults to matching the hostname.
    [string]$Machine,
    [switch]$Upgrade,
    [switch]$SkipSystem,
    [switch]$SkipApps,
    # Overrides Settings.InstallerRoot, e.g. -InstallerRoot E:\cbr-deploy\installers
    [string]$InstallerRoot
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

if (-not (Test-IsAdmin)) { throw 'Run this from an elevated PowerShell as the admin account.' }

$manifest = Get-CbrManifest
$settings = $manifest.Settings
$script:RebootNeeded = $false
$failures = New-Object System.Collections.Generic.List[string]

$logDir = 'C:\CBR\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir ("provision-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))) | Out-Null

if ($Machine) {
    $machineEntry = $manifest.Machines | Where-Object { $_.Name -eq $Machine }
    if (-not $machineEntry) { throw "Unknown machine '$Machine'. Known: $(($manifest.Machines | ForEach-Object Name) -join ', ')" }
} else {
    $machineEntry = $manifest.Machines | Where-Object { $_.ComputerName -eq $env:COMPUTERNAME }
    if (-not $machineEntry) { throw "Hostname $env:COMPUTERNAME isn't in manifest.psd1. Pass -Machine on the first run." }
}

# ---------------------------------------------------------------------------------------------
# Windows settings
# ---------------------------------------------------------------------------------------------
function Set-RegistryValue($Path, $Name, $Value, $Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
}

function Remove-Bloat {
    $provisioned = Get-AppxProvisionedPackage -Online
    foreach ($name in $settings.RemoveAppx) {
        try {
            $found = $false
            foreach ($p in ($provisioned | Where-Object { $_.DisplayName -eq $name })) {
                Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -AllUsers | Out-Null
                $found = $true
            }
            foreach ($p in (Get-AppxPackage -AllUsers -Name $name)) {
                Remove-AppxPackage -Package $p.PackageFullName -AllUsers
                $found = $true
            }
            if ($found) { Write-Host "Removed $name" }
        } catch {
            Write-Warning "Couldn't remove ${name}: $($_.Exception.Message)"
        }
    }
}

function Set-PrivacyPolicies {
    $policies = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
    # Diagnostic data at the minimum Pro allows ("Required"). 0 (off) only works on Enterprise/Education.
    Set-RegistryValue "$policies\DataCollection" 'AllowTelemetry' 1
    Set-RegistryValue "$policies\AdvertisingInfo" 'DisabledByGroupPolicy' 1
    Set-RegistryValue "$policies\System" 'PublishUserActivities' 0
    Set-RegistryValue "$policies\System" 'UploadUserActivities' 0
    Set-RegistryValue "$policies\WindowsAI" 'DisableAIDataAnalysis' 1          # Recall snapshots
    Set-RegistryValue "$policies\WindowsCopilot" 'TurnOffWindowsCopilot' 1
    Set-RegistryValue "$policies\CloudContent" 'DisableWindowsConsumerFeatures' 1   # Enterprise/Education only; harmless on Pro
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0   # Widgets
    # Also set by the answer file; repeated here for machines installed without it.
    Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1
}

# Explorer, Start and suggestion settings that only exist per user. $Root is a registry path
# to the top of a user's hive, e.g. 'HKCU:' or 'Registry::HKEY_USERS\CBR_DEFAULT'.
function Set-UserSettings([string]$Root) {
    $cv = "$Root\Software\Microsoft\Windows\CurrentVersion"
    Set-RegistryValue "$cv\Explorer\Advanced" 'HideFileExt' 0                    # show file extensions
    Set-RegistryValue "$cv\Explorer\Advanced" 'Start_IrisRecommendations' 0      # no Start menu promotions
    Set-RegistryValue "$cv\Search" 'SearchboxTaskbarMode' 1                      # search icon, not the box
    Set-RegistryValue "$Root\Software\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 1   # no Bing in Start search
    # Stop Windows quietly installing promoted apps and showing tips and adverts.
    $cdm = "$cv\ContentDeliveryManager"
    foreach ($v in 'ContentDeliveryAllowed', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'SilentInstalledAppsEnabled',
                   'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled', 'SubscribedContent-338388Enabled',
                   'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled') {
        Set-RegistryValue $cdm $v 0
    }
    Remove-ItemProperty "$cv\Run" -Name 'OneDriveSetup' -ErrorAction SilentlyContinue
}

# Runs Set-UserSettings against a hive file that isn't loaded (a signed-out user, or the Default
# profile that new accounts are copied from).
function Set-UserSettingsInHiveFile([string]$HiveFile) {
    $mount = 'CBR_HIVE'
    & reg.exe load "HKU\$mount" $HiveFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't load $HiveFile" }
    try { Set-UserSettings "Registry::HKEY_USERS\$mount" }
    finally {
        # Registry handles from the provider must be released before the hive can unload.
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$mount" | Out-Null
    }
}

function Set-AllUserSettings {
    try {
        Set-UserSettingsInHiveFile 'C:\Users\Default\NTUSER.DAT'
        Write-Host 'Default profile (applies to accounts that sign in for the first time).'
    } catch { $failures.Add("Default profile settings: $($_.Exception.Message)") }

    $shared = Get-LocalUser -Name $settings.SharedUser -ErrorAction SilentlyContinue
    if ($shared) {
        $userProfile = Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $shared.SID.Value }
        try {
            if (-not $userProfile) { Write-Host "$($settings.SharedUser) hasn't signed in yet; the Default profile covers it." }
            elseif ($userProfile.Loaded) { Set-UserSettings "Registry::HKEY_USERS\$($shared.SID.Value)"; Write-Host "$($settings.SharedUser) (signed in)." }
            else { Set-UserSettingsInHiveFile (Join-Path $userProfile.LocalPath 'NTUSER.DAT'); Write-Host "$($settings.SharedUser)." }
        } catch { $failures.Add("$($settings.SharedUser) settings: $($_.Exception.Message)") }
    }

    Set-UserSettings 'HKCU:'
    Write-Host "$env:USERNAME (this account). Sign out and back in to see Explorer changes."
}

function Set-RegionalSettings {
    Set-TimeZone -Id $settings.TimeZone
    Set-WinHomeLocation -GeoId $settings.GeoId
    if ((Get-WinSystemLocale).Name -ne $settings.Locale) {
        Set-WinSystemLocale -SystemLocale $settings.Locale
        $script:RebootNeeded = $true
    }
    # Formats and keyboard for this account, then copied to the sign-in screen and new accounts.
    Set-Culture $settings.Locale
    Set-WinUserLanguageList -LanguageList $settings.Locale -Force
    Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
    Write-Host "$($settings.TimeZone), $($settings.Locale) formats and keyboard."
}

function Invoke-SystemConfig {
    Write-Step "Hostname"
    if ($env:COMPUTERNAME -ne $machineEntry.ComputerName) {
        Rename-Computer -NewName $machineEntry.ComputerName -Force
        $script:RebootNeeded = $true
        Write-Host "Renamed to $($machineEntry.ComputerName) (takes effect after reboot)."
    } else { Write-Host "Already $($machineEntry.ComputerName)." }

    Write-Step "Repo folder permissions (staff can read the scripts, only admins can change them)"
    $root = Split-Path $settings.RepoPath -Parent
    & icacls $root /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' 'Users:(OI)(CI)RX' /T /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { $failures.Add('icacls on repo folder') }

    Write-Step "Shared staff account '$($settings.SharedUser)'"
    if (-not (Get-LocalUser -Name $settings.SharedUser -ErrorAction SilentlyContinue)) {
        $pw = Read-Host "Password for the new '$($settings.SharedUser)' account" -AsSecureString
        New-LocalUser -Name $settings.SharedUser -Password $pw -PasswordNeverExpires -FullName 'CBR Staff' | Out-Null
        Add-LocalGroupMember -Group 'Users' -Member $settings.SharedUser
        Write-Host "Created as a standard user."
    } else {
        $isAdmin = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*\$($settings.SharedUser)" }
        if ($isAdmin) { Write-Warning "$($settings.SharedUser) is an administrator. It should be a standard user." }
        else { Write-Host "Exists, standard user." }
    }

    Write-Step "Region: UK time zone, formats and keyboard"
    try { Set-RegionalSettings } catch { $failures.Add("Regional settings: $($_.Exception.Message)") }

    Write-Step "Power: no sleep on AC, no hibernation or Fast Startup, High performance plan"
    & powercfg /hibernate off
    & powercfg /change standby-timeout-ac 0
    & powercfg /change hibernate-timeout-ac 0
    & powercfg /setactive SCHEME_MIN

    Write-Step "Long path support"
    Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1

    Write-Step "Stop Windows Update replacing drivers (the NVIDIA driver is pinned in the manifest)"
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1

    Write-Step "Remove OneDrive"
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    $oneDrive = Get-InstalledPrograms | Where-Object { $_.DisplayName -like 'Microsoft OneDrive*' }
    if ($oneDrive) {
        & winget uninstall --id Microsoft.OneDrive --exact --silent --accept-source-agreements --disable-interactivity
        Reset-InstalledProgramsCache
    } else { Write-Host "Not installed." }

    Write-Step "Remove preinstalled Store apps (Settings.RemoveAppx in the manifest)"
    Remove-Bloat

    Write-Step "Privacy and advert settings (machine-wide policies)"
    Set-PrivacyPolicies

    Write-Step "Per-user settings: new accounts, '$($settings.SharedUser)' and this account"
    Set-AllUserSettings

    Write-Step "WSL platform (distros are installed per user by user-setup.ps1)"
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    if ($vmp.State -ne 'Enabled') {
        & wsl.exe --install --no-distribution
        $script:RebootNeeded = $true
    } else {
        & wsl.exe --update
    }

    Write-Step "OpenSSH server (lets fleet.ps1 audit and update this machine remotely)"
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
    if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    Set-RegistryValue 'HKLM:\SOFTWARE\OpenSSH' 'DefaultShell' 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' 'String'
    $keys = Join-Path (Get-CbrRepoRoot) 'config\ssh\administrators_authorized_keys'
    if (Test-Path $keys) {
        $dest = 'C:\ProgramData\ssh\administrators_authorized_keys'
        Copy-Item $keys $dest -Force
        & icacls $dest /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
        Write-Host "Admin SSH keys installed."
    } else { Write-Host "No config\ssh\administrators_authorized_keys in the repo yet; skipping keys." }
}

# ---------------------------------------------------------------------------------------------
# Apps
# ---------------------------------------------------------------------------------------------
function Invoke-Winget([string[]]$Arguments) {
    $common = @('--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    & winget @Arguments @common
    $code = $LASTEXITCODE
    # 0 = ok; 0x8A15002B = no applicable upgrade; 0x8A150061 = already installed
    $ok = @(0, -1978335189, -1978335135)
    if ($ok -notcontains $code) { throw "winget $($Arguments -join ' ') failed with exit code $code" }
}

function Install-WingetApp($App, $Status) {
    $wgArgs = @('--id', $App.Id)
    $scope = 'machine'
    if ($App.ContainsKey('Scope')) { $scope = $App.Scope }
    if ($scope) { $wgArgs += @('--scope', $scope) }
    $override = @()
    if ($App.Override) { $override = @('--override', $App.Override) }

    if ($App.Policy -eq 'pinned') {
        if ($Status.Status -eq 'MISSING' -or $Status.Status -eq 'WRONG-VERSION') {
            $verArgs = @()
            if ($App.Version) { $verArgs = @('--version', $App.Version) }
            if ($Status.Status -eq 'WRONG-VERSION') { $verArgs += '--force' }
            Invoke-Winget (@('install') + $wgArgs + $override + $verArgs)
        }
        # Stops a manual 'winget upgrade --all' moving it. update.ps1 never upgrades pinned apps.
        & winget pin add --id $App.Id --exact --force --accept-source-agreements | Out-Null
    } else {
        if ($Status.Status -eq 'MISSING') { Invoke-Winget (@('install') + $wgArgs + $override) }
        # Override is install-time only (e.g. Visual Studio workloads); upgrades use the defaults.
        elseif ($Upgrade) { Invoke-Winget (@('upgrade') + $wgArgs) }
    }
}

function Install-VendorApp($App, $Status) {
    if ($Status.Status -eq 'OK' -or $Status.Status -eq 'UNPINNED') { return }
    if (-not $script:InstallerRootPath) {
        $wanted = $(if ($InstallerRoot) { $InstallerRoot } else { $settings.InstallerRoot })
        $script:InstallerRootPath = Resolve-InstallerRoot $wanted
        if (-not $script:InstallerRootPath) { throw "Installer folder '$wanted' not found on any drive. Plug in the install USB." }
        Write-Host "Using installers in $($script:InstallerRootPath)"
    }
    $path = Join-Path $script:InstallerRootPath $App.Installer
    if (-not (Test-Path $path)) { throw "Installer not found: $path" }
    if ($App.Sha256) {
        $hash = (Get-FileHash $path -Algorithm SHA256).Hash
        if ($hash -ne $App.Sha256) { throw "SHA-256 mismatch for $path" }
    }
    if ($path -like '*.msi') {
        $exe = 'msiexec.exe'
        $argList = "/i `"$path`" /qn /norestart $($App.Args)"
    } else {
        $exe = $path
        $argList = $App.Args
    }
    if (-not $App.Args -and $path -notlike '*.msi') {
        Write-Host "No silent arguments for $($App.Name): the installer will open. Click through it." -ForegroundColor Yellow
    }
    $p = if ($argList) { Start-Process $exe -ArgumentList $argList -Wait -PassThru } else { Start-Process $exe -Wait -PassThru }
    if ($p.ExitCode -eq 3010 -or $p.ExitCode -eq 1641) { $script:RebootNeeded = $true }
    elseif ($p.ExitCode -ne 0) { throw "$($App.Name) installer exited with $($p.ExitCode)" }
}

function Install-UnityEditor($App, $Status) {
    if ($Status.Status -eq 'OK') { return }
    if (-not $App.Version -or -not $App.Changeset) {
        Write-Host "Unity Editor Version/Changeset not set in the manifest; skipping." -ForegroundColor Yellow
        return
    }
    $hub = 'C:\Program Files\Unity Hub\Unity Hub.exe'
    if (-not (Test-Path $hub)) { throw "Unity Hub isn't installed at $hub" }
    $hubArgs = @('--', '--headless', 'install', '--version', $App.Version, '--changeset', $App.Changeset)
    foreach ($m in $App.Modules) { $hubArgs += @('--module', $m) }
    $hubArgs += '--childModules'
    & $hub @hubArgs
    if ($LASTEXITCODE -ne 0) { throw "Unity Hub install exited with $LASTEXITCODE" }
}

function Invoke-Apps {
    $manual = @()
    foreach ($app in $manifest.Apps) {
        $status = Get-AppStatus $app
        Write-Step "$($app.Name) [$($app.Policy)] - $($status.Status) $($status.Installed)"
        try {
            switch ($app.Method) {
                'winget'    { Install-WingetApp $app $status }
                'installer' { Install-VendorApp $app $status }
                'unity'     { Install-UnityEditor $app $status }
                'manual'    { if ($status.Status -ne 'OK') { $manual += $app } }
                default     { throw "Unknown method '$($app.Method)'" }
            }
        } catch {
            Write-Warning $_.Exception.Message
            $failures.Add("$($app.Name): $($_.Exception.Message)")
        }
        Reset-InstalledProgramsCache
    }
    if ($manual) {
        Write-Step "Manual steps still needed"
        foreach ($m in $manual) { Write-Host " - $($m.Name): $($m.Notes)" -ForegroundColor Yellow }
    }
}

try {
    if (-not $SkipSystem) { Invoke-SystemConfig }
    if (-not $SkipApps) { Invoke-Apps }

    Write-Step "Audit"
    & (Join-Path $PSScriptRoot 'audit.ps1')

    if ($failures.Count) {
        Write-Step "Problems"
        $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    }
    if ($script:RebootNeeded) { Write-Host "`nReboot needed, then run this script again." -ForegroundColor Yellow }
} finally {
    Stop-Transcript | Out-Null
}
