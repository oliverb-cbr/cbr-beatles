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
$oneDrive = Get-InstalledPrograms | Where-Object { $_.DisplayName -like 'Microsoft OneDrive*' }
$telemetry = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -ErrorAction SilentlyContinue).AllowTelemetry
try {
    $leftover = @(Get-AppxProvisionedPackage -Online | Where-Object { $manifest.Settings.RemoveAppx -contains $_.DisplayName })
    $bloat = if ($leftover.Count) { ($leftover.DisplayName -join ', ') } else { 'none' }
} catch { $bloat = 'unknown (run as admin)' }
try { $encryption = [string](Get-BitLockerVolume -MountPoint $env:SystemDrive).VolumeStatus }
catch { $encryption = 'unknown (run as admin)' }

function New-Check($Name, $Value, $Ok) {
    [pscustomobject]@{ Name = $Name; Value = [string]$Value; Status = $(if ($Ok) { 'OK' } else { 'CHECK' }) }
}
$checks = @(
    $known = $manifest.Machines.ComputerName -contains $env:COMPUTERNAME
    New-Check 'Hostname in manifest' $(if ($known) { 'yes' } else { $env:COMPUTERNAME }) $known
    New-Check 'Windows' "$($os.Caption) $($os.Version)" $true
    New-Check 'WSL platform' $vmp ($vmp -eq 'Enabled')
    New-Check 'WU driver updates blocked' $wuDrivers ($wuDrivers -eq 1)
    New-Check 'Telemetry at minimum' $telemetry ($telemetry -eq 1)
    New-Check 'Preinstalled apps removed' $bloat ($bloat -eq 'none')
    New-Check 'System drive not encrypted' $encryption ($encryption -eq 'FullyDecrypted')
    New-Check 'OneDrive removed' $(if ($oneDrive) { 'installed' } else { 'absent' }) (-not $oneDrive)
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
