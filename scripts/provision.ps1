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
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\SQM' 'OptIn' 0   # Visual Studio usage reporting
    # Also set by the answer file; repeated here for machines installed without it.
    Set-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1
}

# Explorer, Start and suggestion settings that only exist per user. $Root is a registry path
# to the top of a user's hive, e.g. 'HKCU:' or 'Registry::HKEY_USERS\CBR_DEFAULT'. $Shared is for
# the two shared accounts, which don't get OneDrive.
function Set-UserSettings([string]$Root, [bool]$Shared = $false) {
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
    Remove-ItemProperty "$cv\Run" -Name 'OneDriveSetup' -ErrorAction SilentlyContinue   # per-account OneDrive; it's installed for the PC instead

    # Edge's "startup boost" entries (the Edge policy stops new ones).
    $run = Get-Item "$cv\Run" -ErrorAction SilentlyContinue
    if ($run) {
        foreach ($value in $run.GetValueNames()) {
            if ($value -like 'MicrosoftEdgeAutoLaunch_*') { Remove-ItemProperty "$cv\Run" -Name $value }
        }
    }
    # Apps that add themselves to start at sign-in stay off: this is Task Manager's Startup apps switch,
    # which keeps working when the app adds itself again.
    $off = @($settings.StartupOff)
    if ($Shared) { $off += 'OneDrive' }
    foreach ($name in $off) {
        Set-RegistryValue "$cv\Explorer\StartupApproved\Run" $name ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 'Binary'
    }
    # OneDrive: university accounts only, never personal Microsoft accounts.
    Set-RegistryValue "$Root\Software\Policies\Microsoft\OneDrive" 'DisablePersonalSync' 1
}

# Runs Set-UserSettings against a hive file that isn't loaded (a signed-out user, or the Default
# profile that new accounts are copied from).
function Set-UserSettingsInHiveFile([string]$HiveFile, [bool]$Shared = $false) {
    $mount = 'CBR_HIVE'
    & reg.exe load "HKU\$mount" $HiveFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Couldn't load $HiveFile" }
    try { Set-UserSettings "Registry::HKEY_USERS\$mount" $Shared }
    finally {
        # Registry handles from the provider must be released before the hive can unload.
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$mount" | Out-Null
    }
}

# The Default profile (new accounts are copied from it), then every account that has signed in,
# whether it's signed in now (its hive is loaded) or not.
function Set-AllUserSettings {
    try {
        Set-UserSettingsInHiveFile 'C:\Users\Default\NTUSER.DAT'
        Write-Host 'Default profile (applies to accounts that sign in for the first time).'
    } catch { $failures.Add("Default profile settings: $($_.Exception.Message)") }

    $sharedNames = @($settings.SharedUser, $settings.SessionUser)
    foreach ($user in Get-LocalUser) {
        if (Test-BuiltInAccount $user) { continue }
        $userProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'"
        if (-not $userProfile) { continue }   # never signed in: the Default profile covers it
        $isShared = $sharedNames -contains $user.Name
        try {
            if ($userProfile.Loaded) { Set-UserSettings "Registry::HKEY_USERS\$($user.SID.Value)" $isShared }
            else { Set-UserSettingsInHiveFile (Join-Path $userProfile.LocalPath 'NTUSER.DAT') $isShared }
            Write-Host "$($user.Name)."
        } catch { $failures.Add("$($user.Name) settings: $($_.Exception.Message)") }
    }
    Write-Host 'Sign out and back in to see Explorer changes.'
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

# OneDrive is installed for the whole PC (see the manifest). These keep it to Falmouth's Microsoft 365,
# with files downloaded only when opened, and stop it offering to move people's Desktop and Documents.
function Set-OneDrivePolicies {
    # Builds before October 2026 blocked OneDrive completely; undo that.
    Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -ErrorAction SilentlyContinue
    $od = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
    Set-RegistryValue $od 'FilesOnDemandEnabled' 1
    Set-RegistryValue $od 'KFMBlockOptIn' 1
    Set-RegistryValue "$od\AllowTenantList" $settings.OneDriveTenantId $settings.OneDriveTenantId 'String'
    # Storage Sense makes OneDrive files that haven't been opened for a while online-only again. When
    # it's on, Windows also empties anything left in the Recycle Bin for over 30 days.
    $ss = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'
    Set-RegistryValue $ss 'AllowStorageSenseGlobal' 1
    Set-RegistryValue $ss 'ConfigStorageSenseGlobalCadence' 1   # daily
    Set-RegistryValue $ss 'ConfigStorageSenseCloudContentDehydrationThreshold' $settings.OneDriveDehydrateDays
    Write-Host "Falmouth accounts only; files online-only until opened, and again after $($settings.OneDriveDehydrateDays) days unopened."
}

function Set-BrowserPolicies {
    # Edge: no "startup boost" at sign-in, no running after it's closed, and no first-run screens
    # (the "How to use this PC" note may open in it).
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    Set-RegistryValue $edge 'StartupBoostEnabled' 0
    Set-RegistryValue $edge 'BackgroundModeEnabled' 0
    Set-RegistryValue $edge 'HideFirstRunExperience' 1
    # Chrome and Brave: don't keep running after the last window closes.
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 0
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BackgroundModeEnabled' 0
    # Firefox: no Default Browser Agent, which reports to Mozilla which browser is the default.
    Set-RegistryValue 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox' 'DisableDefaultBrowserAgent' 1
}

# Public Documents, Downloads, Music, Pictures and Videos: readable by everyone, writable only by
# admins, so they can't be used to pass files between people or as a dumping ground. (The Public
# Desktop is admin-only already; provisioning manages what's on it.)
function Lock-PublicFolders {
    foreach ($name in 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos') {
        $dir = Join-Path 'C:\Users\Public' $name
        if (-not (Test-Path $dir)) { continue }
        & icacls $dir /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' 'Users:(OI)(CI)RX' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Couldn't set permissions on $dir (icacls exit $LASTEXITCODE)" }
        if (Get-ChildItem $dir -Force -ErrorAction SilentlyContinue) { & icacls "$dir\*" /reset /T /C /Q | Out-Null }
    }
    Write-Host 'Read-only for everyone except admins.'
}

# Per-account disk limits on C: (Settings.Quotas). Windows refuses writes past the limit; the
# sign-in check (usage-check.ps1) tells people when they pass the warning level.
function Set-DiskQuotas {
    $gb = [int64]1GB
    $q = $settings.Quotas
    $qs = @(Get-CimInstance Win32_QuotaSetting | Where-Object { $_.VolumePath -like 'C:*' })[0]
    if (-not $qs) { throw "Windows has no disk quota settings for C:." }
    $state = $(if ($settings.QuotaMode -eq 'Enforce') { 2 } else { 1 })
    # The defaults apply to every account not listed below, which means personal ones.
    Set-CimInstance -InputObject $qs -Property @{
        State                       = [uint32]$state
        DefaultWarningLimit         = [int64]$q.Personal.Warn * $gb
        DefaultLimit                = [int64]$q.Personal.Limit * $gb
        WarningExceededNotification = $true
        ExceededNotification        = $true
    }
    $none = [int64]16384 * $gb   # far beyond the drive: no limit
    $limits = [ordered]@{}
    foreach ($name in 'NT AUTHORITY\SYSTEM', 'NT SERVICE\TrustedInstaller', 'NT AUTHORITY\LOCAL SERVICE',
                      'NT AUTHORITY\NETWORK SERVICE', 'BUILTIN\Administrators', $settings.AdminUser) {
        $limits[$name] = @($none, $none)
    }
    $limits[$settings.SharedUser]  = @(([int64]$q.Shared.Warn * $gb), ([int64]$q.Shared.Limit * $gb))
    $limits[$settings.SessionUser] = @(([int64]$q.Session.Warn * $gb), ([int64]$q.Session.Limit * $gb))
    foreach ($user in Get-LocalUser) {
        if ((Test-BuiltInAccount $user) -or $limits.Contains($user.Name)) { continue }
        if ((Get-CbrAccountType $user.Name $settings) -eq 'admin') { $limits[$user.Name] = @($none, $none) }
        else { $limits[$user.Name] = @(([int64]$q.Personal.Warn * $gb), ([int64]$q.Personal.Limit * $gb)) }
    }
    foreach ($name in $limits.Keys) {
        & fsutil quota modify C: $limits[$name][0] $limits[$name][1] $name | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "Couldn't set the limit for $name (fsutil exit $LASTEXITCODE)." -ForegroundColor Yellow }
    }
    $mode = $(if ($state -eq 2) { 'enforced' } else { 'tracked only, not enforced' })
    Write-Host "Limits $mode. Personal accounts: warning at $($q.Personal.Warn) GB, limit $($q.Personal.Limit) GB."
}

function Set-DefenderExclusions {
    $current = @((Get-MpPreference).ExclusionPath)
    foreach ($path in $settings.DefenderExclusions) {
        if ($current -notcontains $path) { Add-MpPreference -ExclusionPath $path; Write-Host "Excluded $path" }
    }
    Write-Host "$(@($settings.DefenderExclusions).Count) folders aren't scanned as they're written (see the README)."
}

# Startup entries made for every account (HKLM Run) that stay off, and scheduled tasks to turn off.
# Per-account startup entries are switched off with the other per-user settings.
function Set-BackgroundOff {
    $off = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    foreach ($name in $settings.StartupOff) {
        foreach ($key in 'Run', 'Run32') {
            Set-RegistryValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$key" $name $off 'Binary'
        }
    }
    Write-Host "Kept off at sign-in: $($settings.StartupOff -join ', ')."
    foreach ($task in Get-ScheduledTask) {
        $full = $task.TaskPath + $task.TaskName
        if (-not @($settings.TasksOff | Where-Object { $full -like $_ }).Count -or $task.State -eq 'Disabled') { continue }
        Disable-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath | Out-Null
        Write-Host "Turned off the scheduled task $full"
    }
}

# Uninstalls programs that installers add and the build doesn't want (Settings.Unwanted).
function Remove-UnwantedPrograms {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $removed = 0
    foreach ($unwanted in $settings.Unwanted) {
        $entries = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $unwanted.DisplayName -and $_.UninstallString })
        foreach ($entry in $entries) {
            Write-Host "Uninstalling $($entry.DisplayName)..."
            $p = Start-Process cmd.exe -ArgumentList "/s /c `"$($entry.UninstallString) $($unwanted.SilentArgs)`"" -WindowStyle Hidden -PassThru
            $null = $p.Handle
            if (-not $p.WaitForExit(300000)) { Write-Host 'Its uninstaller is still running after 5 minutes; carrying on.' -ForegroundColor Yellow }
            $removed++
        }
    }
    Reset-InstalledProgramsCache
    $left = @(foreach ($unwanted in $settings.Unwanted) {
        Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $unwanted.DisplayName } })
    if ($left.Count) { throw "Couldn't remove $(($left.DisplayName | Sort-Object -Unique) -join ', ') silently. Uninstall it in Settings > Apps > Installed apps." }
    if (-not $removed) { Write-Host 'None found.' }
}

# The shared accounts can't start OneDrive at all, so nobody leaves their university files signed
# in for the next person. (Their startup entry for it is off too, with the per-user settings.)
function Block-OneDriveForSharedAccounts {
    $dir = @(Get-Item 'C:\Program Files*\Microsoft OneDrive' -ErrorAction SilentlyContinue)[0]
    if (-not $dir) { Write-Host "OneDrive isn't installed yet."; return }
    foreach ($name in $settings.SharedUser, $settings.SessionUser) {
        if (-not (Get-LocalUser -Name $name -ErrorAction SilentlyContinue)) { continue }
        & icacls $dir.FullName /deny "${name}:(OI)(CI)RX" /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Couldn't block OneDrive for $name (icacls exit $LASTEXITCODE)" }
    }
    Write-Host "Blocked for $($settings.SharedUser) and $($settings.SessionUser)."
}

# A Start menu shortcut an installer made: the first pattern with a match wins; an exact name beats
# a wildcard match, and a shorter name beats a longer one.
function Find-StartMenuShortcut([string[]]$Patterns, $Candidates) {
    foreach ($pattern in $Patterns) {
        $exact = @($Candidates | Where-Object { $_.BaseName -eq $pattern })
        if ($exact.Count) { return $exact[0] }
        $like = @($Candidates | Where-Object { $_.BaseName -like $pattern } | Sort-Object { $_.BaseName.Length })
        if ($like.Count) { return $like[0] }
    }
    $null
}

# The desktop folders and Start > CBR, rebuilt from the manifest on every run, plus the note.
function Set-Shortcuts {
    $desktop = Get-PublicDesktop
    $startMenu = Get-CbrStartMenu
    $shell = New-Object -ComObject WScript.Shell
    # Start menu shortcuts made by installers: for all users, or for this admin if they point
    # somewhere every account can reach.
    $allUsers = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
    $candidates = @(Get-ChildItem $allUsers -Recurse -Filter *.lnk -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "$startMenu\*" })
    $candidates += @(Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') -Recurse -Filter *.lnk -ErrorAction SilentlyContinue |
        Where-Object { $target = $shell.CreateShortcut($_.FullName).TargetPath; $target -and $target -notlike 'C:\Users\*' })

    $plan = New-Object System.Collections.Generic.List[hashtable]
    $missing = @()
    foreach ($app in $manifest.Apps) {
        $sc = $app.Shortcut
        if (-not $sc -or (Get-AppStatus $app).Status -eq 'MISSING') { continue }
        $entry = @{ Folder = $sc.Folder; Name = $(if ($sc.Name) { $sc.Name } else { $app.Name }) }
        $source = $(if ($sc.StartMenu) { Find-StartMenuShortcut @($sc.StartMenu) $candidates } else { $null })
        $target = $(if ($sc.Target) { @(Get-Item $sc.Target -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)[0] } else { $null })
        if ($source) {
            $entry.Source = $source.FullName
            $entry.SourceName = $source.BaseName
        } elseif ($target) {
            $entry.Target = $target.FullName
        } elseif ($sc.UserTarget) {
            # Installed into each person's own profile: cmd fills in their own folder when it's opened.
            $entry.Target = "$env:SystemRoot\System32\cmd.exe"
            $entry.Arguments = "/c start `"`" `"$($sc.UserTarget)`""
            $entry.Style = 7
            $icon = $(if ($sc.Icon) { @(Get-Item $sc.Icon -ErrorAction SilentlyContinue)[0] } else { $null })
            if ($icon) { $entry.Icon = "$($icon.FullName),0" }
        } else {
            $missing += "$($entry.Name) (no Start menu shortcut called $(@($sc.StartMenu) -join ' or '))"
            continue
        }
        $plan.Add($entry)
    }
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $plan.Add(@{ Folder = 'Code'; Name = 'Terminal'; Target = "$env:SystemRoot\explorer.exe"
                 Arguments = 'shell:AppsFolder\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App'; Icon = "$env:SystemRoot\System32\cmd.exe,0" })
    $plan.Add(@{ Folder = 'Code'; Name = 'Ubuntu'; Target = "$env:SystemRoot\System32\wsl.exe"; Arguments = "-d $($settings.WslDistro) --cd ~" })
    $plan.Add(@{ Folder = 'Code'; Name = 'Set up Ubuntu & Docker'; Target = $powershell; Icon = "$env:SystemRoot\System32\wsl.exe,0"
                 Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'user-setup.ps1')`" -Window" })

    # Rebuilt from scratch, so they always match the manifest. A hidden .cbr file marks our folders.
    foreach ($root in $desktop, $startMenu) {
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        foreach ($old in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
            if (Test-Path (Join-Path $old.FullName '.cbr')) { Remove-Item $old.FullName -Recurse -Force }
        }
        foreach ($folder in $settings.ShortcutFolders) {
            $dir = Join-Path $root $folder
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $flag = New-Item -ItemType File -Force -Path (Join-Path $dir '.cbr')
            $flag.Attributes = 'Hidden'
        }
        foreach ($entry in $plan) {
            $path = Join-Path (Join-Path $root $entry.Folder) "$($entry.Name).lnk"
            if ($entry.Source) { Copy-Item $entry.Source $path -Force }
            else {
                $style = $(if ($entry.Style) { $entry.Style } else { 1 })
                New-CbrShortcut -Path $path -Target $entry.Target -Arguments $entry.Arguments -Icon $entry.Icon -WindowStyle $style
            }
        }
    }
    # Loose shortcuts installers dropped on the shared desktop: they're in the folders now.
    Get-ChildItem $desktop -Filter *.lnk -File -ErrorAction SilentlyContinue | Remove-Item -Force
    # The sign-in script removes these names from people's own desktops too (per-user installers).
    New-Item -ItemType Directory -Force -Path 'C:\ProgramData\CBR' | Out-Null
    Set-Content 'C:\ProgramData\CBR\desktop-tidy.txt' @($plan | ForEach-Object { $_.Name; $_.SourceName } | Where-Object { $_ } | Sort-Object -Unique)

    # The "How to use this PC" note, with this PC's name and the folders as they are now.
    $folderList = foreach ($folder in $settings.ShortcutFolders) {
        $names = @($plan | Where-Object { $_.Folder -eq $folder } | ForEach-Object { $_.Name } | Sort-Object)
        if ($names.Count) { "<li><strong>$([Net.WebUtility]::HtmlEncode($folder)):</strong> $([Net.WebUtility]::HtmlEncode($names -join ', '))</li>" }
    }
    $html = Get-Content (Join-Path (Get-CbrRepoRoot) 'config\how-to-use-this-pc.html') -Raw
    $html = $html.Replace('{{COMPUTER}}', $machineEntry.ComputerName)
    $html = $html.Replace('{{FOLDERS}}', ($folderList -join "`n"))
    $html = $html.Replace('{{UPDATED}}', (Get-Date -Format 'd MMMM yyyy'))
    [IO.File]::WriteAllText((Get-NotePath), $html, (New-Object Text.UTF8Encoding $false))
    New-CbrShortcut -Path (Join-Path $startMenu 'How to use this PC.lnk') -Target (Get-NotePath)

    Write-Host "$($plan.Count) shortcuts in $(@($settings.ShortcutFolders).Count) folders, on the desktop and in Start > CBR, plus the note."
    if ($missing.Count) {
        Write-Host 'No shortcut made for:' -ForegroundColor Yellow
        $missing | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
        Write-Host "Find the app in Start, right-click it and choose Open file location, and tell me the shortcut's name." -ForegroundColor Yellow
    }
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

    Invoke-Step "Folder permissions: staff can read the scripts; logs and installers are admin-only" {
        # Set the permissions on C:\CBR itself only, then make the repo inherit them.
        # (Granting them file by file with icacls /T left files unreadable, even to admins.)
        $root = Split-Path $settings.RepoPath -Parent
        & icacls $root /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' 'Users:(OI)(CI)RX' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Setting permissions on $root failed (icacls exit $LASTEXITCODE)" }
        & icacls $settings.RepoPath /reset /T /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Resetting permissions on $($settings.RepoPath) failed (icacls exit $LASTEXITCODE)" }
        # Git needs to read its own files; fail loudly here rather than at the next update.
        Get-Content (Join-Path $settings.RepoPath '.git\HEAD') -ErrorAction Stop | Out-Null
        # The logs (including the account audit, with people's names) and the installer cache.
        foreach ($dir in $logDir, $settings.InstallerCache) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            & icacls $dir /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' /Q | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Setting permissions on $dir failed (icacls exit $LASTEXITCODE)" }
            if (Get-ChildItem $dir -Force -ErrorAction SilentlyContinue) { & icacls "$dir\*" /reset /T /C /Q | Out-Null }
        }
        Write-Host 'Done; the repo is still readable.'
    }

    foreach ($account in @(
            @{ Name = $settings.SharedUser;  FullName = 'CBR Staff';   Description = 'Shared drop-in account.' }
            @{ Name = $settings.SessionUser; FullName = 'CBR Session'; Description = 'Shared account for sessions; reset from the Accounts menu.' })) {
        Invoke-Step "Shared account '$($account.Name)' ($($account.FullName))" {
            if (-not (Get-LocalUser -Name $account.Name -ErrorAction SilentlyContinue)) {
                $pw = Read-NewPassword "the new '$($account.Name)' account"
                New-LocalUser -Name $account.Name -Password $pw -PasswordNeverExpires -FullName $account.FullName `
                    -Description $account.Description | Out-Null
                Add-LocalGroupMember -Group 'Users' -Member $account.Name
                Write-Host 'Created as a standard user.'
            } elseif ((Get-CbrAccountType $account.Name $settings) -eq 'admin') {
                Write-Warning "$($account.Name) is an administrator. It should be a standard user."
            } else { Write-Host 'Exists, standard user.' }
        }
    }

    Invoke-Step "At each sign-in: Work folder, the note, a tidy desktop and a disk space check" {
        # Replaced: Ubuntu and Docker are now set up from Code > Set up Ubuntu & Docker, when someone needs them.
        Unregister-CbrTask 'CBR - staff setup at sign-in'
        Register-CbrSignInTask -Name 'CBR - at sign-in' -AllUsers -Hidden -Script (Join-Path $PSScriptRoot 'sign-in.ps1')
        # Runs as SYSTEM, so it can read everyone's disk use, and tells whoever's signed in if they're
        # over their warning level.
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'usage-check.ps1')`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $trigger.Delay = 'PT1M'
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $options = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'CBR - disk space check' -Action $action -Trigger $trigger -Principal $principal `
            -Settings $options -Force | Out-Null
        Write-Host 'Done.'
    }

    Invoke-Step "Hide Switch user, so whoever's signed in signs out (closing their apps) before the next person" {
        Set-RegistryValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'HideFastUserSwitching' 1
    }

    Invoke-Step "Local passwords don't expire (people still choose their own at first sign-in)" {
        & net.exe accounts /maxpwage:unlimited | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "net accounts failed ($LASTEXITCODE)" }
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

    Invoke-Step "OneDrive: Falmouth accounts only, files downloaded only when opened" {
        Set-OneDrivePolicies
    }

    Invoke-Step "Browsers: no running in the background, no Edge startup boost or first-run screens" {
        Set-BrowserPolicies
    }

    Invoke-Step "Public folders read-only for everyone except admins" {
        Lock-PublicFolders
    }

    Invoke-Step "Disk limits per account (Settings.Quotas)" {
        Set-DiskQuotas
    }

    Invoke-Step "Defender: don't scan engine caches and Work folders as they're written (Settings.DefenderExclusions)" {
        Set-DefenderExclusions
    }

    Invoke-Step "Remove preinstalled Store apps (Settings.RemoveAppx in the manifest)" {
        Remove-Bloat
    }

    Invoke-Step "Privacy and advert settings (machine-wide policies)" {
        Set-PrivacyPolicies
    }

    Invoke-Step "Per-user settings: new accounts and every account that has signed in" {
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
    # --source winget: never the Microsoft Store source, which asks to send the region first.
    $common = @('--exact', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    # Run as its own process writing straight to the window, however this script was started.
    # When PowerShell captures winget's output instead, its progress bars come out as garbled
    # characters and its spinner prints a new line per turn.
    $argText = (@($Arguments) + $common | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $winget = (Get-Command winget -CommandType Application | Select-Object -First 1).Source
    $p = Start-Process $winget -ArgumentList $argText -NoNewWindow -PassThru
    $null = $p.Handle   # needed to read ExitCode once it ends
    $p.WaitForExit()
    $code = $p.ExitCode
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
        # 7-Zip (installed earlier in the app list) is much faster than Expand-Archive on big files.
        $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
        if (Test-Path $sevenZip) {
            & $sevenZip x $Path "-o$dest" -y -bso0
            if ($LASTEXITCODE -ne 0) { throw "7-Zip couldn't unpack $(Split-Path -Leaf $Path) (exit $LASTEXITCODE)" }
        } else {
            Expand-Archive -Path $Path -DestinationPath $dest
        }
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
    if ($App.Signer) {
        # A file the vendor replaces at every release has no fixed SHA-256, so check that it's
        # validly signed by the vendor instead.
        $sig = Get-AuthenticodeSignature $Path
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notlike "*O=$($App.Signer),*") {
            throw "$(Split-Path -Leaf $Path) isn't validly signed by $($App.Signer) ($($sig.Status)). Delete it and download it again."
        }
        Write-Host "Signed by $($App.Signer)."
        return
    }
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

# Some installers hand over to Windows Installer and exit before it has finished. Windows Installer
# holds this mutex while it's installing, so wait for it to be free (up to 30 minutes).
function Wait-WindowsInstaller {
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
        $mutex = $null
        try {
            if (-not [Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$mutex)) { return }
            $mutex.Dispose()
        } catch [UnauthorizedAccessException] { }   # it exists but can't be opened: still busy
        Start-Sleep -Seconds 5
    }
}

function Install-VendorApp($App, $Status) {
    if ($Status.Status -eq 'OK' -or $Status.Status -eq 'UNPINNED') { return }
    $package = Resolve-VendorInstaller $App
    if (-not $package) {
        if ($App.Url) { $package = Save-VendorInstaller $App }
        else {
            $from = $(if ($App.DownloadPage) { " from $($App.DownloadPage)" } else { '' })
            $msg = "No installer for $($App.Name) yet. Download it$from into $($settings.InstallerCache), then run this again."
            if ($App.Notes) { $msg += " $($App.Notes)" }
            throw $msg
        }
    }
    Write-Host "Installer: $package"
    Assert-InstallerHash $App $package
    $path = Open-InstallerPackage $package $App
    if ($path -like '*.msi') {
        $exe = 'msiexec.exe'
        $msiLog = Join-Path $logDir (($App.Name -replace '[^\w.-]', '-') + '-msi.log')
        Write-Host "Installing silently (log: $msiLog)..."
        $argList = "/i `"$path`" /qn /norestart /l+ `"$msiLog`" $($App.Args)"
    } else {
        $exe = $path
        $argList = $App.Args
    }
    if (-not $App.Args -and $path -notlike '*.msi') {
        Write-Host "No silent arguments for $($App.Name): the installer will open. Click through it." -ForegroundColor Yellow
    }
    # Waits for the installer itself only. Start-Process -Wait would also wait for anything it starts,
    # so an installer that opens its app at the end (Insta360, LCC) would hang here until the app closed.
    $p = if ($argList) { Start-Process $exe -ArgumentList $argList -PassThru } else { Start-Process $exe -PassThru }
    $null = $p.Handle   # needed to read ExitCode once it ends
    $p.WaitForExit()
    Wait-WindowsInstaller
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

# The changeset is part of every Unity download link; Unity's release list gives it for a version.
function Get-UnityChangeset([string]$Version) {
    $uri = "https://services.api.unity.com/unity/editor/release/v1/releases?version=$Version&platform=WINDOWS&architecture=X86_64"
    $release = @((Invoke-RestMethod $uri -UseBasicParsing).results | Where-Object { $_.version -eq $Version })
    if (-not $release.Count) { throw "Unity $Version isn't in Unity's release list. Check Version in the manifest." }
    $release[0].shortRevision
}

function Install-UnityEditor($App, $Status) {
    if ($Status.Status -eq 'OK') { return }
    if (-not $App.Version) {
        Write-Host "Unity Editor Version not set in the manifest; skipping." -ForegroundColor Yellow
        return
    }
    $hub = 'C:\Program Files\Unity Hub\Unity Hub.exe'
    if (-not (Test-Path $hub)) { throw "Unity Hub isn't installed at $hub" }
    $changeset = Get-UnityChangeset $App.Version
    Write-Host "Installing Unity $($App.Version) (changeset $changeset) through Unity Hub. This takes a while."
    # Unity Hub is a windowed program: PowerShell only waits for it when its output is piped.
    # Its install folder is a per-user setting; set it to the shared one that DetectPath expects.
    # Arguments go in arrays so PowerShell passes the leading '--' on to Unity Hub as it is.
    New-Item -ItemType Directory -Force -Path 'C:\Program Files\Unity\Hub\Editor' | Out-Null   # Hub refuses a folder that isn't there
    $pathArgs = @('--', '--headless', 'install-path', '--set', 'C:\Program Files\Unity\Hub\Editor')
    & $hub @pathArgs | Out-Host
    $hubArgs = @('--', '--headless', 'install', '--version', $App.Version, '--changeset', $changeset)
    foreach ($m in $App.Modules) { $hubArgs += @('--module', $m) }
    $hubArgs += '--childModules'
    & $hub @hubArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Unity Hub install exited with $LASTEXITCODE" }
    $editor = Resolve-DetectPath $App
    if (-not (Test-Path $editor)) { throw "Unity Hub finished, but there's no editor at $editor. See the Unity Hub output above." }
}

# After the apps, because installers add shortcuts, startup entries, tasks and extra programs.
function Invoke-Finish {
    Invoke-Step "Programs installers added that the build doesn't want (Settings.Unwanted)" { Remove-UnwantedPrograms }
    Invoke-Step "Background: startup entries and scheduled tasks kept off" { Set-BackgroundOff }
    Invoke-Step "OneDrive blocked for the shared accounts" { Block-OneDriveForSharedAccounts }
    Invoke-Step "Desktop and Start menu folders, and the 'How to use this PC' note" { Set-Shortcuts }
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
    Invoke-Finish

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
# 3010 is Windows' "worked, but restart to finish". start.ps1 uses it to restart and carry on.
if ($script:RebootNeeded) { exit 3010 }
exit 0
