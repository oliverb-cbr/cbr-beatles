<#
.SYNOPSIS
    One-off setup for whoever runs it: WSL Ubuntu with Docker Engine and GPU support.

.DESCRIPTION
    WSL distros belong to a single Windows user, so each person runs it for themselves, from the
    desktop: Code > Set up Ubuntu & Docker (-Window). Not for the admin account. Needs provision.ps1
    to have enabled the WSL platform and the machine to have restarted. Doesn't need admin rights.
    Safe to run again. Writes a marker when it has worked, which the Accounts audit shows.

    Docker Engine runs inside Ubuntu, not Docker Desktop, so there's no Docker Desktop licence.
#>
[CmdletBinding()]
param(
    # Started from the desktop shortcut: explains what's happening and waits for Enter at the end.
    [switch]$Window
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$settings = (Get-CbrManifest).Settings
$distro = $settings.WslDistro
$marker = Get-UbuntuMarker $env:USERNAME

if ($Window) {
    $host.UI.RawUI.WindowTitle = 'Set up Ubuntu & Docker'
    Write-Host "Setting up Ubuntu, Docker and GPU support for $env:USERNAME on this PC." -ForegroundColor Cyan
    Write-Host 'It takes about 10-20 minutes, once. Leave this window open.'
    try {
        & $PSCommandPath
        Write-Host "`nAll done. Open Code > Ubuntu on the desktop to use it." -ForegroundColor Green
    } catch {
        Write-Host "`nIt didn't finish: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Run it again from the desktop. If it keeps failing, email cbr@falmouth.ac.uk with the message above.'
    }
    Read-Host "`nPress Enter to close this window" | Out-Null
    return
}

if ($env:USERNAME -eq $settings.AdminUser) { throw "Run this signed in as the person who'll use Ubuntu, not as $($settings.AdminUser)." }

# wsl.exe writes UTF-16; this makes its output readable in PowerShell.
$env:WSL_UTF8 = '1'

Write-Step "Ubuntu ($distro)"
$installed = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim() })
if ($installed -notcontains $distro) {
    & wsl.exe --install --distribution $distro --no-launch
    if ($LASTEXITCODE -ne 0) { throw "wsl --install failed ($LASTEXITCODE). Has provision.ps1 run and the machine rebooted?" }
} else { Write-Host 'Already installed.' }

$script = Join-Path (Get-CbrRepoRoot) 'wsl\setup-docker.sh'
$linuxScript = (& wsl.exe -d $distro -u root -- wslpath -a ($script -replace '\\', '/')).Trim()

Write-Step 'Docker Engine, NVIDIA container toolkit and uv inside Ubuntu'
& wsl.exe -d $distro -u root -- bash $linuxScript $settings.WslUser
if ($LASTEXITCODE -eq 2) {
    # The script enabled systemd, which needs the WSL VM restarted.
    & wsl.exe --shutdown
    Start-Sleep -Seconds 8
    & wsl.exe -d $distro -u root -- bash $linuxScript $settings.WslUser
}
if ($LASTEXITCODE -ne 0) { throw "setup-docker.sh failed ($LASTEXITCODE)" }

& wsl.exe --shutdown
New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
Set-Content -Path $marker -Value "Staff setup finished $(Get-Date -Format s) by $env:USERNAME."
Write-Host "`nDone. Open Ubuntu from the Start menu to use Docker and uv. On a workstation the GPU check above should have listed the RTX 5090." -ForegroundColor Green
