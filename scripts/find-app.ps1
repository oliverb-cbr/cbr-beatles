<#
.SYNOPSIS
    Lists Apps & Features entries matching a wildcard, to help write Detect patterns.

.EXAMPLE
    .\find-app.ps1 '*Insta360*'
#>
param([Parameter(Mandatory)][string]$Pattern)

Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
Get-InstalledPrograms | Where-Object { $_.DisplayName -like $Pattern } |
    Sort-Object DisplayName | Format-Table DisplayName, DisplayVersion, Publisher -AutoSize
