<#
.SYNOPSIS
    Runs at every sign-in, as the person signing in, from a task provision.ps1 makes.

.DESCRIPTION
    - Makes their Work folder, with a shortcut on their desktop.
    - Removes shortcuts that per-user installers put on their desktop, which are already in the
      desktop folders.
    - The first time: puts Work in Explorer's sidebar, opens the "How to use this PC" note, and says
      when the account ends if it has an end date.
    Does nothing for the admin account. Problems go to %LOCALAPPDATA%\CBR\sign-in.log.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
    $settings = (Get-CbrManifest).Settings
    if ($env:USERNAME -eq $settings.AdminUser) { return }

    $desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($name in @(Get-Content 'C:\ProgramData\CBR\desktop-tidy.txt' -ErrorAction SilentlyContinue)) {
        Remove-Item (Join-Path $desktop "$name.lnk") -Force -ErrorAction SilentlyContinue
    }

    $work = Join-Path $env:USERPROFILE 'Work'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $workLink = Join-Path $desktop 'Work.lnk'
    if (-not (Test-Path $workLink)) { New-CbrShortcut -Path $workLink -Target $work }

    $state = 'HKCU:\Software\CBR'
    if (-not (Get-ItemProperty $state -Name 'FirstSignIn' -ErrorAction SilentlyContinue)) {
        try { (New-Object -ComObject Shell.Application).Namespace($work).Self.InvokeVerb('pintohome') } catch { }
        if (Test-Path (Get-NotePath)) { Start-Process (Get-NotePath) }
        $me = Get-LocalUser -Name $env:USERNAME -ErrorAction SilentlyContinue
        if ($me -and $me.AccountExpires) {
            Add-Type -AssemblyName System.Windows.Forms
            $message = "Your account on this PC ends on $($me.AccountExpires.ToString('d MMMM yyyy')).`n`n" +
                       'Copy your work off before then: the account and everything in it are deleted afterwards.'
            [System.Windows.Forms.MessageBox]::Show($message, 'CBR workstation') | Out-Null
        }
        New-Item -Path $state -Force | Out-Null
        Set-ItemProperty -Path $state -Name 'FirstSignIn' -Value (Get-Date -Format s)
    }
} catch {
    $log = Join-Path $env:LOCALAPPDATA 'CBR\sign-in.log'
    New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
    Add-Content $log "$(Get-Date -Format s) $($_.Exception.Message)"
}
