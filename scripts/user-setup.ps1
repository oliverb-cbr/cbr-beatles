<#
.SYNOPSIS
    One-off setup for the shared staff account: WSL Ubuntu with Docker Engine and GPU support.

.DESCRIPTION
    WSL distros belong to a single Windows user, so run this logged in as the staff account
    (not the admin), after provision.ps1 has enabled the WSL platform and the machine has rebooted.
    Doesn't need Windows admin rights. Safe to run again.

    provision.ps1 leaves a task that runs this by itself each time the staff account signs in
    (-AtSignIn), until it has worked once. It then writes a marker and the task stops.

    Docker Engine runs inside Ubuntu, not Docker Desktop, so there's no Docker Desktop licence.
#>
[CmdletBinding()]
param(
    # Used by the sign-in task: does nothing if this has already worked, otherwise opens a window
    # and runs the setup there (-FromSignIn).
    [switch]$AtSignIn,
    [switch]$FromSignIn
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$settings = (Get-CbrManifest).Settings
$distro = $settings.WslDistro
$marker = Get-StaffSetupMarker

if ($AtSignIn) {
    if (Test-Path $marker) { return }
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -FromSignIn"
    return
}

if ($FromSignIn) {
    $host.UI.RawUI.WindowTitle = 'CBR staff setup'
    Write-Host "Setting up Ubuntu, Docker and GPU support for the '$($settings.SharedUser)' account." -ForegroundColor Cyan
    Write-Host 'This happens once and takes about 10-20 minutes. Leave this window open.'
    try {
        & $PSCommandPath
        Write-Host "`nAll done. This won't run again." -ForegroundColor Green
    } catch {
        Write-Host "`nStaff setup didn't finish: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'It tries again the next time this account signs in. If it keeps failing, send the message above to whoever looks after these PCs.'
    }
    Read-Host "`nPress Enter to close this window" | Out-Null
    return
}

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
New-Item -ItemType Directory -Force -Path (Split-Path $marker) | Out-Null
Set-Content -Path $marker -Value "Staff setup finished $(Get-Date -Format s) by $env:USERNAME."
Write-Host "`nDone. Open Ubuntu from the Start menu to use Docker and uv. On a workstation the GPU check above should have listed the RTX 5090." -ForegroundColor Green
