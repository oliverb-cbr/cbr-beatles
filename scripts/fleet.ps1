<#
.SYNOPSIS
    Runs the audit or an update on all four machines over SSH and compares them side by side.

.DESCRIPTION
    Run from any machine with OpenSSH client and an SSH key listed in
    config\ssh\administrators_authorized_keys (installed on each machine by provision.ps1).

.EXAMPLE
    .\fleet.ps1                       # audit all four, show a comparison grid
    .\fleet.ps1 -Action Update        # git pull + update.ps1 on each, one after another
    .\fleet.ps1 -Machine PAUL,RINGO   # only these
    .\fleet.ps1 -Action Accounts     # every account on all four in one table, saved as a CSV
    .\fleet.ps1 -Action ResetSession # reset the session account on all four (skips any in use)
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'Update', 'Accounts', 'ResetSession')]
    [string]$Action = 'Audit',
    [string[]]$Machine
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

$manifest = Get-CbrManifest
$settings = $manifest.Settings
$targets = $manifest.Machines
if ($Machine) { $targets = $targets | Where-Object { $Machine -contains $_.Name } }

function Invoke-Remote($Target, [string]$Script, [string]$ScriptArgs = '') {
    $path = Join-Path $settings.RepoPath "scripts\$Script"
    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$path`" $ScriptArgs"
    & ssh -o ConnectTimeout=10 "$($settings.AdminUser)@$($Target.Address)" $cmd
}

if ($Action -eq 'Accounts') {
    $all = foreach ($t in $targets) {
        try {
            $rows = (Invoke-Remote $t 'accounts.ps1' '-AsJson') -join "`n" | ConvertFrom-Json
            foreach ($r in @($rows)) { $r | Add-Member -NotePropertyName PC -NotePropertyValue $t.Name -PassThru }
        } catch { Write-Warning "$($t.Name): $($_.Exception.Message)" }
    }
    $all | Format-Table PC, Account, Name, Type, Created, LastSignIn, Ends, UsedGB, LimitGB, SignedIn, Ubuntu -AutoSize
    $dir = $(if (Test-Path 'C:\CBR\logs') { 'C:\CBR\logs' } else { (Get-Location).Path })
    $file = Join-Path $dir ('accounts-all-{0:yyyyMMdd-HHmm}.csv' -f (Get-Date))
    $all | Select-Object PC, Account, Name, Type, Created, LastSignIn, DaysSince, Ends, Expired, Enabled,
        UsedGB, LimitGB, OverWarning, SignedIn, Ubuntu | Export-Csv $file -NoTypeInformation
    Write-Host "Saved: $file"
    return
}

if ($Action -eq 'ResetSession') {
    foreach ($t in $targets) {
        Write-Step "Resetting the session account on $($t.Name)"
        Invoke-Remote $t 'accounts.ps1' '-ResetSession -NoPrompt'
    }
    return
}

if ($Action -eq 'Update') {
    foreach ($t in $targets) {
        Write-Step "Updating $($t.Name)"
        Invoke-Remote $t 'update.ps1'
        if ($LASTEXITCODE -eq 3010) {
            Write-Warning "$($t.Name) needs a restart to finish updating: ssh $($settings.AdminUser)@$($t.Address) shutdown /r /t 0"
        } elseif ($LASTEXITCODE -ne 0) {
            Write-Warning "$($t.Name) update exited with $LASTEXITCODE. winget can fail over SSH; if so, run update.ps1 at the machine."
        }
    }
    Write-Step 'Re-auditing'
}

$results = @{}
foreach ($t in $targets) {
    try {
        $json = (Invoke-Remote $t 'audit.ps1' '-AsJson') -join "`n"
        $results[$t.Name] = $json | ConvertFrom-Json
    } catch {
        Write-Warning "$($t.Name): $($_.Exception.Message)"
    }
}
if (-not $results.Count) { throw 'No machines responded.' }

# Grid: one row per check/app, one column per machine. Shows installed version, or the problem.
$names = $targets | Where-Object { $results.ContainsKey($_.Name) } | ForEach-Object Name
$rows = foreach ($section in 'Checks', 'Apps') {
    $itemNames = $results[$names[0]].$section | ForEach-Object Name
    foreach ($item in $itemNames) {
        $row = [ordered]@{ Item = $item }
        $cells = @()
        foreach ($n in $names) {
            $r = $results[$n].$section | Where-Object { $_.Name -eq $item }
            $value = if ($section -eq 'Apps') { $r.Installed } else { $r.Value }
            $cell = if ($r.Status -eq 'OK') { $value } else { "$($r.Status) $value".Trim() }
            $row[$n] = $cell
            $cells += $cell
        }
        $row['Drift'] = if (@($cells | Select-Object -Unique).Count -gt 1 -or ($cells -match '^(MISSING|WRONG-VERSION|UNPINNED|CHECK)')) { '<<' } else { '' }
        [pscustomobject]$row
    }
}

$rows | Format-Table -AutoSize
$drift = @($rows | Where-Object { $_.Drift })
if ($drift.Count) { Write-Host "$($drift.Count) row(s) differ between machines or need attention." -ForegroundColor Yellow }
else { Write-Host 'All machines match each other and the manifest.' -ForegroundColor Green }
