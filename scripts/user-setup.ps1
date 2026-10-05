<#
.SYNOPSIS
    One-off setup for the shared staff account: WSL Ubuntu with Docker Engine and GPU support.

.DESCRIPTION
    WSL distros belong to a single Windows user, so run this logged in as the staff account
    (not the admin), after provision.ps1 has enabled the WSL platform and the machine has rebooted.
    Doesn't need Windows admin rights. Safe to run again.

    Docker Engine runs inside Ubuntu, not Docker Desktop, so there's no Docker Desktop licence.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$settings = (Get-CbrManifest).Settings
$distro = $settings.WslDistro

if (Test-IsAdmin) {
    Write-Warning "You're running as an administrator. The distro will belong to this account, not '$($settings.SharedUser)'."
    if ((Read-Host 'Continue anyway? (y/N)') -ne 'y') { return }
}

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
Write-Host "`nDone. Open Ubuntu from the Start menu; 'docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi' should list the 5090." -ForegroundColor Green
