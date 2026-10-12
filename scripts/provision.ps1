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
    # An extra folder of vendor installers to use, e.g. -InstallerRoot E:\cbr-deploy\installers
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
    # Widgets. Recent Windows 11 builds refuse this write even from an admin script; the Widgets app
    # (MicrosoftWindows.Client.WebExperience) is removed via RemoveAppx anyway, so this is a bonus.
    try { Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 }
    catch { Write-Host 'Windows blocked the Widgets policy; relying on removing the Widgets app instead.' }
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

# Runs one Windows setting step. A failure is reported and recorded, and the next step still runs.
function Invoke-Step([string]$Title, [scriptblock]$Body) {
    Write-Step $Title
    try { & $Body }
    catch {
        Write-Warning $_.Exception.Message
        $failures.Add("${Title}: $($_.Exception.Message)")
    }
}

function Invoke-SystemConfig {
    Invoke-Step "Hostname" {
        if ($env:COMPUTERNAME -ne $machineEntry.ComputerName) {
            Rename-Computer -NewName $machineEntry.ComputerName -Force
            $script:RebootNeeded = $true
            Write-Host "Renamed to $($machineEntry.ComputerName) (takes effect after reboot)."
        } else { Write-Host "Already $($machineEntry.ComputerName)." }
    }

    Invoke-Step "Repo folder permissions (staff can read the scripts, only admins can change them)" {
        # Set the permissions on C:\CBR itself only, then make everything inside inherit them.
        # (Granting them file by file with icacls /T left files unreadable, even to admins.)
        $root = Split-Path $settings.RepoPath -Parent
        & icacls $root /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' 'Users:(OI)(CI)RX' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Setting permissions on $root failed (icacls exit $LASTEXITCODE)" }
        & icacls "$root\*" /reset /T /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Resetting permissions inside $root failed (icacls exit $LASTEXITCODE)" }
        # Git needs to read its own files; fail loudly here rather than at the next update.
        Get-Content (Join-Path $settings.RepoPath '.git\HEAD') -ErrorAction Stop | Out-Null
        Write-Host 'Done; the repo is still readable.'
    }

    Invoke-Step "Shared staff account '$($settings.SharedUser)'" {
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
    }

    Invoke-Step "Region: UK time zone, formats and keyboard" {
        try { Set-RegionalSettings } catch { $failures.Add("Regional settings: $($_.Exception.Message)") }
    }

    Invoke-Step "Power: no sleep on AC, no hibernation or Fast Startup, High performance plan" {
        & powercfg /hibernate off
        & powercfg /change standby-timeout-ac 0
        & powercfg /change hibernate-timeout-ac 0
        & powercfg /setactive SCHEME_MIN
    }

    Invoke-Step "Long path support" {
        Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1
    }

    Invoke-Step "Stop Windows Update replacing drivers (the NVIDIA driver is pinned in the manifest)" {
        Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
    }

    Invoke-Step "Remove OneDrive" {
        Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
        $oneDrive = Get-InstalledPrograms | Where-Object { $_.DisplayName -like 'Microsoft OneDrive*' }
        if ($oneDrive) {
            & winget uninstall --id Microsoft.OneDrive --exact --silent --accept-source-agreements --disable-interactivity
            Reset-InstalledProgramsCache
        } else { Write-Host "Not installed." }
    }

    Invoke-Step "Remove preinstalled Store apps (Settings.RemoveAppx in the manifest)" {
        Remove-Bloat
    }

    Invoke-Step "Privacy and advert settings (machine-wide policies)" {
        Set-PrivacyPolicies
    }

    Invoke-Step "Per-user settings: new accounts, '$($settings.SharedUser)' and this account" {
        Set-AllUserSettings
    }

    Invoke-Step "WSL platform (distros are installed per user by user-setup.ps1)" {
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
        if ($vmp.State -ne 'Enabled') {
            & wsl.exe --install --no-distribution
            $script:RebootNeeded = $true
        } else {
            & wsl.exe --update
        }
    }

    Invoke-Step "OpenSSH server (lets fleet.ps1 audit and update this machine remotely)" {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
        if ($cap.State -ne 'Installed') {
            Write-Host 'Downloading the OpenSSH Server feature from Microsoft. This can take 5-15 minutes with no output.'
            $result = Add-WindowsCapability -Online -Name $cap.Name
            if ($result.RestartNeeded) { $script:RebootNeeded = $true }
        }
        if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
            Write-Host 'Installed, but the sshd service only appears after a restart. Run this script again then.'
            $script:RebootNeeded = $true
            return
        }
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

# Removes a Store-style (MSIX) package for all users, including its machine-wide provisioning.
function Remove-MsixCopy([string]$Name) {
    foreach ($p in (Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like $Name })) {
        Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -AllUsers | Out-Null
        Write-Host "Removed Store-style copy (provisioned): $($p.DisplayName)"
    }
    foreach ($p in (Get-AppxPackage -AllUsers -Name $Name)) {
        Remove-AppxPackage -Package $p.PackageFullName -AllUsers
        Write-Host "Removed Store-style copy: $($p.Name)"
    }
}

function Install-WingetApp($App, $Status) {
    $wgArgs = @('--id', $App.Id)
    $scope = 'machine'
    if ($App.ContainsKey('Scope')) { $scope = $App.Scope }
    if ($scope) { $wgArgs += @('--scope', $scope) }
    $override = @()
    if ($App.Override) { $override = @('--override', $App.Override) }
    # Some packages also offer a Store-style MSIX that winget may pick first. InstallerType forces the
    # normal installer; MsixName removes an MSIX copy left by an earlier run, otherwise winget sees
    # that copy, calls the package installed and never puts the normal one on.
    if ($App.InstallerType) {
        $override += @('--installer-type', $App.InstallerType)
        if ($Status.Status -eq 'MISSING' -and $App.MsixName) { Remove-MsixCopy $App.MsixName }
    }

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

# Vendor installers sit loose under their download names in C:\CBR\installers (Settings.InstallerCache,
# where downloads land) and, if one is plugged in, an extra folder such as a USB stick or NAS
# (Settings.InstallerRoot). Each app's Installer field is a name pattern (e.g. 'TouchDesigner*').
function Get-InstallerFiles {
    @(foreach ($folder in $script:InstallerFolders) {
        Get-ChildItem $folder -File -ErrorAction SilentlyContinue |
            Where-Object { '.exe', '.msi', '.zip', '.iso' -contains $_.Extension.ToLower() }
    })
}

# For a .zip or .iso, unpacks or mounts it and returns the installer inside; otherwise returns $Path.
# Clean-up (unmount, delete the unpacked copy) waits until the end of provisioning, because some
# installers hand over to a second process and exit while it's still reading the files.
function Open-InstallerPackage([string]$Path, $App) {
    $ext = [IO.Path]::GetExtension($Path).ToLower()
    if ($ext -eq '.zip') {
        $dest = Join-Path $env:TEMP ('cbr-' + [IO.Path]::GetFileNameWithoutExtension($Path))
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Write-Host "Unpacking $(Split-Path -Leaf $Path)..."
        Expand-Archive -Path $Path -DestinationPath $dest
        $script:Cleanup.Add({ Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }.GetNewClosure())
        $root = $dest
    } elseif ($ext -eq '.iso') {
        Write-Host "Mounting $(Split-Path -Leaf $Path)..."
        $image = Mount-DiskImage -ImagePath $Path -PassThru
        $script:Cleanup.Add({ Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null }.GetNewClosure())
        $root = ($image | Get-Volume).DriveLetter + ':\'
    } else {
        return $Path
    }
    # Prefer installers at the top of the package; look deeper only if there are none.
    $candidates = @(Get-ChildItem $root -File | Where-Object { '.exe', '.msi' -contains $_.Extension.ToLower() })
    if (-not $candidates.Count) {
        $candidates = @(Get-ChildItem $root -File -Recurse | Where-Object { '.exe', '.msi' -contains $_.Extension.ToLower() })
    }
    if ($App.Inner) { $candidates = @($candidates | Where-Object { $_.Name -like $App.Inner }) }
    if ($candidates.Count -eq 1) { return $candidates[0].FullName }
    if (-not $candidates.Count) { throw "No installer found inside $(Split-Path -Leaf $Path)" }
    throw "Several installers inside $(Split-Path -Leaf $Path): $(($candidates | ForEach-Object Name) -join ', '). Set Inner on this app in the manifest to pick one."
}

# Returns the installer file for an app, or $null if there isn't one in any installer folder.
# If several match (old and new versions), the one whose name contains the manifest Version wins.
function Resolve-VendorInstaller($App) {
    $found = @(Get-InstallerFiles | Where-Object { $_.Name -like $App.Installer })
    # The same file in two folders counts once; the first folder (C:\CBR\installers) wins.
    $found = @($found | Group-Object Name | ForEach-Object { $_.Group[0] })
    if ($found.Count -gt 1 -and $App.Version) {
        $found = @($found | Where-Object { $_.Name -like "*$($App.Version)*" })
    }
    if ($found.Count -gt 1) {
        throw "Several installers match '$($App.Installer)': $(($found | ForEach-Object Name) -join ', '). Delete the old ones."
    }
    if ($found.Count -eq 1) { return $found[0].FullName }
    $null
}

# Downloads an app's installer from its Url in the manifest into the installer cache.
function Save-VendorInstaller($App) {
    # FileName is for links that don't end in the file's name (e.g. Meta's ?id= links).
    $name = $(if ($App.FileName) { $App.FileName } else { [Uri]::UnescapeDataString([IO.Path]::GetFileName(([Uri]$App.Url).AbsolutePath)) })
    $dest = Join-Path $settings.InstallerCache $name
    Write-Host "Downloading $name..."
    & curl.exe --fail --location --retry 3 --progress-bar --output "$dest.partial" $App.Url
    if ($LASTEXITCODE -ne 0) {
        Remove-Item "$dest.partial" -ErrorAction SilentlyContinue
        throw "Download failed (curl exit $LASTEXITCODE): $($App.Url)"
    }
    Move-Item "$dest.partial" $dest -Force
    $dest
}

# The manifest's SHA-256 decides whether an installer file is the right one, wherever it came from.
function Assert-InstallerHash($App, [string]$Path) {
    $hash = (Get-FileHash $Path -Algorithm SHA256).Hash
    if (-not $App.Sha256) {
        Write-Host "No Sha256 in the manifest for $($App.Name). This file's is $hash" -ForegroundColor Yellow
        return
    }
    if ($hash -ne $App.Sha256) {
        throw "$(Split-Path -Leaf $Path) doesn't match the SHA-256 in the manifest: it's damaged or a different version. Delete it and download it again."
    }
    Write-Host 'SHA-256 matches the manifest.'
}

# Files in the installer folders that no app in the manifest claims: usually a pattern that needs fixing.
function Show-UnclaimedInstallers {
    $patterns = @($manifest.Apps | Where-Object { $_.Method -eq 'installer' } | ForEach-Object Installer)
    $unclaimed = @(Get-InstallerFiles | Where-Object { $name = $_.Name; -not ($patterns | Where-Object { $name -like $_ }) })
    if ($unclaimed.Count) {
        Write-Step "Installer files that no app in the manifest uses"
        $unclaimed | ForEach-Object { Write-Host " - $($_.FullName)" -ForegroundColor Yellow }
        Write-Host "Either an app's Installer pattern in manifest.psd1 needs changing, or the file isn't needed."
    }
}

function Install-VendorApp($App, $Status) {
    if ($Status.Status -eq 'OK' -or $Status.Status -eq 'UNPINNED') { return }
    $package = Resolve-VendorInstaller $App
    if (-not $package) {
        if ($App.Url) { $package = Save-VendorInstaller $App }
        else {
            $from = $(if ($App.DownloadPage) { " from $($App.DownloadPage)" } else { '' })
            throw "No installer for $($App.Name) yet. Download it$from into $($settings.InstallerCache), then run this again."
        }
    }
    Write-Host "Installer: $package"
    Assert-InstallerHash $App $package
    $path = Open-InstallerPackage $package $App
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

# A zip of standalone programs (uv): unpacked into InstallDir, which is added to the system PATH.
# Used instead of winget's 'portable' installs, which standard users can't run.
function Install-PortableApp($App, $Status) {
    if ($Status.Status -ne 'MISSING' -and -not $Upgrade) { return }
    $zip = Join-Path $env:TEMP ('cbr-' + [IO.Path]::GetFileName(([Uri]$App.Url).AbsolutePath))
    Write-Host "Downloading $($App.Url)..."
    & curl.exe --fail --location --retry 3 --progress-bar --output $zip $App.Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed (curl exit $LASTEXITCODE): $($App.Url)" }
    New-Item -ItemType Directory -Force -Path $App.InstallDir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $App.InstallDir -Force
    Remove-Item $zip -Force
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($machinePath -split ';') -notcontains $App.InstallDir) {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$($App.InstallDir)", 'Machine')
        Write-Host "Added $($App.InstallDir) to the system PATH (new windows pick it up)."
    }
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
    $script:Cleanup = New-Object System.Collections.Generic.List[scriptblock]
    try { Invoke-AppList } finally { foreach ($c in $script:Cleanup) { & $c } }
}

function Invoke-AppList {
    # Installer folders: the local cache always; the extra folder (USB / NAS) only if it's there.
    New-Item -ItemType Directory -Force -Path $settings.InstallerCache | Out-Null
    $script:InstallerFolders = @($settings.InstallerCache)
    $wanted = $(if ($InstallerRoot) { $InstallerRoot } else { $settings.InstallerRoot })
    $extra = $(if ($wanted) { Resolve-InstallerRoot $wanted } else { $null })
    if ($extra) { $script:InstallerFolders += $extra }
    Write-Host "Vendor installers: $($script:InstallerFolders -join ', ')"

    $manual = @()
    foreach ($app in $manifest.Apps) {
        $status = Get-AppStatus $app
        Write-Step "$($app.Name) [$($app.Policy)] - $($status.Status) $($status.Installed)"
        try {
            switch ($app.Method) {
                'winget'    { Install-WingetApp $app $status }
                'installer' { Install-VendorApp $app $status }
                'portable'  { Install-PortableApp $app $status }
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
    Show-UnclaimedInstallers
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
