<#
.SYNOPSIS
    Pulls the latest manifest and brings this machine up to date.

.DESCRIPTION
    Run as the admin account. Upgrades 'current' apps, moves pinned apps to the version in the
    manifest, re-applies Windows settings, then audits.
#>
[CmdletBinding()]
param([switch]$SkipPull)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

if (-not $SkipPull) {
    & git -C $repo pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw 'git pull failed; fix the repo before updating.' }
}

# Run the freshly pulled copy of provision.ps1 rather than anything already loaded.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'provision.ps1') -Upgrade
exit $LASTEXITCODE
