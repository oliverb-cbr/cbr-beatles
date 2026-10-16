<#
.SYNOPSIS
    At each sign-in: tells whoever's signed in if they're over their disk space warning level.

.DESCRIPTION
    Runs as SYSTEM, from a task provision.ps1 makes, because reading disk quotas needs admin. Windows
    keeps the totals as files change, so this is instant. Switch user is hidden, so there's one
    person signed in at a time.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

$signedIn = (Get-CimInstance Win32_ComputerSystem).UserName   # e.g. CBR-JOHN\jsmith
if (-not $signedIn) { return }
$name = ($signedIn -split '\\')[-1]
$usage = (Get-QuotaUsage)[$name]
if (-not $usage -or -not $usage.Warn -or $usage.Used -lt $usage.Warn) { return }

$used = [math]::Round($usage.Used / 1GB)
$limit = [math]::Round($usage.Limit / 1GB)
$text = "You're using $used GB of your $limit GB on this PC. Copy finished work to OneDrive or your own drive " +
        "and delete it here, so you don't run out of space in the middle of saving something."
& "$env:SystemRoot\System32\msg.exe" $name /TIME:3600 $text
