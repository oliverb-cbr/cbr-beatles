<#
.SYNOPSIS
    Checks this machine against manifest.psd1 and reports anything missing or at the wrong version.

.DESCRIPTION
    Read-only and doesn't need admin. Uses the Apps & Features registry rather than winget,
    so it also works over SSH. -AsJson prints machine-readable output for fleet.ps1.
#>
[CmdletBinding()]
param([switch]$AsJson)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

$manifest = Get-CbrManifest
$apps = @($manifest.Apps | ForEach-Object { Get-AppStatus $_ })

$os = Get-CimInstance Win32_OperatingSystem
# Reading Windows features needs admin; a staff-account audit reports it as unknown.
try { $vmp = [string](Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State }
catch { $vmp = 'unknown (run as admin)' }
$wuDrivers = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue).ExcludeWUDriversInQualityUpdate
$telemetry = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -ErrorAction SilentlyContinue).AllowTelemetry
try {
    $leftover = @(Get-AppxProvisionedPackage -Online | Where-Object { $manifest.Settings.RemoveAppx -contains $_.DisplayName })
    $bloat = if ($leftover.Count) { ($leftover.DisplayName -join ', ') } else { 'none' }
} catch { $bloat = 'unknown (run as admin)' }
try { $encryption = [string](Get-BitLockerVolume -MountPoint $env:SystemDrive).VolumeStatus }
catch { $encryption = 'unknown (run as admin)' }

$settings = $manifest.Settings
$ordinary = '^(BUILTIN\\Users|NT AUTHORITY\\INTERACTIVE|NT AUTHORITY\\Authenticated Users|Everyone)$'

# Whether ordinary accounts have these rights on a folder; $null if it can't be read.
function Test-OrdinaryAccess([string]$Path, [Security.AccessControl.FileSystemRights]$Rights) {
    $acl = Get-Acl $Path -ErrorAction SilentlyContinue
    if (-not $acl) { return $null }
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -match $ordinary -and ($rule.FileSystemRights -band $Rights)) { return $true }
    }
    $false
}

# Startup entries for every account and for this one, that aren't expected or switched off.
function Get-StartupExtras {
    $extras = @()
    $sets = @(
        @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
        @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
        @{ Run = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' })
    foreach ($set in $sets) {
        $run = Get-Item $set.Run -ErrorAction SilentlyContinue
        if (-not $run) { continue }
        $approved = Get-ItemProperty $set.Approved -ErrorAction SilentlyContinue
        foreach ($name in $run.GetValueNames()) {
            if ($settings.StartupAllowed -contains $name) { continue }
            $flag = $(if ($approved -and $approved.$name) { ($approved.$name)[0] } else { 2 })
            if ($flag % 2 -eq 1) { continue }   # switched off
            $extras += $name
        }
    }
    $extras += @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $full = $_.TaskPath + $_.TaskName
        $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' -and -not @($settings.TasksAllowed | Where-Object { $full -like $_ }).Count
    } | ForEach-Object { "task $($_.TaskPath)$($_.TaskName)" })
    $extras
}

function New-Check($Name, $Value, $Ok) {
    [pscustomobject]@{ Name = $Name; Value = [string]$Value; Status = $(if ($Ok) { 'OK' } else { 'CHECK' }) }
}
$checks = @(
    $known = $manifest.Machines.ComputerName -contains $env:COMPUTERNAME
    New-Check 'Hostname in manifest' $(if ($known) { 'yes' } else { $env:COMPUTERNAME }) $known
    New-Check 'Windows' "$($os.Caption) $($os.Version)" $true
    New-Check 'WSL platform' $vmp ($vmp -eq 'Enabled')
    New-Check 'WU driver updates blocked' $wuDrivers ($wuDrivers -eq 1)
    New-Check 'Time zone' (Get-TimeZone).Id ((Get-TimeZone).Id -eq $manifest.Settings.TimeZone)
    New-Check 'System locale' (Get-WinSystemLocale).Name ((Get-WinSystemLocale).Name -eq $manifest.Settings.Locale)
    New-Check 'Telemetry at minimum' $telemetry ($telemetry -eq 1)
    New-Check 'Preinstalled apps removed' $bloat ($bloat -eq 'none')
    New-Check 'System drive not encrypted' $encryption ($encryption -eq 'FullyDecrypted')

    $hidden = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).HideFastUserSwitching
    New-Check 'Switch user hidden' $(if ($hidden -eq 1) { 'yes' } else { 'no' }) ($hidden -eq 1)

    $writable = @('Documents', 'Downloads', 'Music', 'Pictures', 'Videos' | Where-Object {
        Test-OrdinaryAccess (Join-Path 'C:\Users\Public' $_) ([Security.AccessControl.FileSystemRights]'WriteData, AppendData') })
    New-Check 'Public folders read-only' $(if ($writable.Count) { "writable: $($writable -join ', ')" } else { 'yes' }) (-not $writable.Count)

    $logsOpen = Test-OrdinaryAccess 'C:\CBR\logs' ([Security.AccessControl.FileSystemRights]'ReadData')
    New-Check 'Logs admin-only' $(if ($null -eq $logsOpen) { 'unknown (run as admin)' } elseif ($logsOpen) { 'readable by staff' } else { 'yes' }) ($logsOpen -eq $false)

    try {
        $qs = @(Get-CimInstance Win32_QuotaSetting -ErrorAction Stop | Where-Object { $_.VolumePath -like 'C:*' })[0]
        $wantState = $(if ($settings.QuotaMode -eq 'Enforce') { 2 } else { 1 })
        $quota = "$(@('off', 'tracked', 'enforced')[$qs.State]); personal $([math]::Round($qs.DefaultWarningLimit / 1GB))/$([math]::Round($qs.DefaultLimit / 1GB)) GB"
        $quotaOk = $qs.State -eq $wantState -and $qs.DefaultLimit -eq ([int64]$settings.Quotas.Personal.Limit * 1GB)
    } catch { $quota = 'unknown (run as admin)'; $quotaOk = $false }
    New-Check 'Disk limits' $quota $quotaOk

    $odPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
    $odDir = @(Get-Item 'C:\Program Files*\Microsoft OneDrive' -ErrorAction SilentlyContinue)[0]
    $odProblems = @()
    if ((Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -ErrorAction SilentlyContinue).DisableFileSyncNGSC) { $odProblems += 'blocked for everyone' }
    if ((Get-ItemProperty $odPolicy -ErrorAction SilentlyContinue).FilesOnDemandEnabled -ne 1) { $odProblems += 'Files On-Demand not forced' }
    if (-not (Get-ItemProperty "$odPolicy\AllowTenantList" -ErrorAction SilentlyContinue).($settings.OneDriveTenantId)) { $odProblems += 'not limited to Falmouth' }
    if ($odDir) {
        $denied = @((Get-Acl $odDir.FullName).Access | Where-Object { $_.AccessControlType -eq 'Deny' } | ForEach-Object { ($_.IdentityReference.Value -split '\\')[-1] })
        foreach ($name in $settings.SharedUser, $settings.SessionUser) { if ($denied -notcontains $name) { $odProblems += "not blocked for $name" } }
    } else { $odProblems += 'not installed' }
    New-Check 'OneDrive (personal accounts only)' $(if ($odProblems.Count) { $odProblems -join '; ' } else { 'set up' }) (-not $odProblems.Count)

    try {
        $exclusions = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ })
        if ($exclusions | Where-Object { $_ -like 'N/A*' }) { throw 'needs admin' }
        $extra = @($exclusions | Where-Object { $settings.DefenderExclusions -notcontains $_ })
        $absent = @($settings.DefenderExclusions | Where-Object { $exclusions -notcontains $_ })
        $defender = $(if ($extra.Count -or $absent.Count) { (@($extra | ForEach-Object { "extra: $_" }) + @($absent | ForEach-Object { "missing: $_" })) -join '; ' } else { 'as in the manifest' })
        $defenderOk = -not ($extra.Count -or $absent.Count)
    } catch { $defender = 'unknown (run as admin)'; $defenderOk = $false }
    New-Check 'Defender exclusions' $defender $defenderOk

    $background = @(Get-StartupExtras)
    New-Check 'Nothing unexpected in the background' $(if ($background.Count) { $background -join ', ' } else { 'yes' }) (-not $background.Count)

    $unwanted = @(foreach ($u in $settings.Unwanted) { Get-InstalledPrograms | Where-Object { $_.DisplayName -like $u.DisplayName } | ForEach-Object DisplayName })
    New-Check 'Unwanted programs absent' $(if ($unwanted.Count) { $unwanted -join ', ' } else { 'yes' }) (-not $unwanted.Count)

    $shortcutsMissing = @(foreach ($app in $manifest.Apps) {
        if (-not $app.Shortcut -or (Get-AppStatus $app).Status -eq 'MISSING') { continue }
        $name = $(if ($app.Shortcut.Name) { $app.Shortcut.Name } else { $app.Name })
        if (-not (Test-Path (Join-Path (Join-Path (Get-PublicDesktop) $app.Shortcut.Folder) "$name.lnk"))) { $name }
    })
    if (-not (Test-Path (Get-NotePath))) { $shortcutsMissing += 'How to use this PC (note)' }
    New-Check 'Desktop folders complete' $(if ($shortcutsMissing.Count) { "missing: $($shortcutsMissing -join ', ')" } else { 'yes' }) (-not $shortcutsMissing.Count)
    New-Check 'sshd running' (Get-Service sshd -ErrorAction SilentlyContinue).Status ((Get-Service sshd -ErrorAction SilentlyContinue).Status -eq 'Running')
)

if ($AsJson) {
    [pscustomobject]@{ Computer = $env:COMPUTERNAME; Time = (Get-Date).ToString('s'); Checks = $checks; Apps = $apps } |
        ConvertTo-Json -Depth 4
    return
}

$checks | Format-Table -AutoSize
$apps | Format-Table Name, Policy, Expected, Installed, Status -AutoSize

$bad = @($apps | Where-Object { $_.Status -ne 'OK' }) + @($checks | Where-Object { $_.Status -ne 'OK' })
if ($bad.Count) {
    Write-Host "$($bad.Count) item(s) need attention." -ForegroundColor Yellow
} else {
    Write-Host "Everything matches the manifest." -ForegroundColor Green
}
