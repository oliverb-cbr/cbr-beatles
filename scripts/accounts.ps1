<#
.SYNOPSIS
    The accounts on this PC: who has one, when they last signed in and how much space they use,
    plus adding people, end dates, removing accounts and resetting the session account.

.DESCRIPTION
    Run it from bootstrap.bat (Accounts, on a CBR workstation). Needs admin.
    -AsJson prints the audit for fleet.ps1. -ResetSession resets the session account; with
    -NoPrompt (fleet.ps1 -Action ResetSession) it doesn't ask, and skips it if someone's using it.
#>
[CmdletBinding()]
param([switch]$AsJson, [switch]$ResetSession, [switch]$NoPrompt)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
$manifest = Get-CbrManifest
$settings = $manifest.Settings
$logDir = 'C:\CBR\logs'
$noLimitGB = 16384   # what provision.ps1 sets for accounts with no limit

# Who's signed in now (including locked), as username -> session number, from their Explorer.
function Get-SignedInSessions {
    $sessions = @{}
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='explorer.exe'") {
        $owner = Invoke-CimMethod -InputObject $p -MethodName GetOwner
        if ($owner.User) { $sessions[$owner.User] = $p.SessionId }
    }
    $sessions
}

function Get-AccountRows {
    $usage = Get-QuotaUsage
    $sessions = Get-SignedInSessions
    foreach ($user in Get-LocalUser) {
        if (Test-BuiltInAccount $user) { continue }
        $userProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'"
        # Windows doesn't record when an account was made; this script writes it in the description.
        $created = ''
        if ($user.Description -match 'Created (\d{4}-\d{2}-\d{2})') { $created = $Matches[1] }
        elseif ($userProfile) { $created = (Get-Item $userProfile.LocalPath -Force -ErrorAction SilentlyContinue).CreationTime.ToString('yyyy-MM-dd') }
        $q = $usage[$user.Name]
        $type = Get-CbrAccountType $user.Name $settings
        # No entry yet (nothing saved since quotas were turned on): the default for its type applies.
        $default = @{ personal = $settings.Quotas.Personal.Limit; shared = $settings.Quotas.Shared.Limit; session = $settings.Quotas.Session.Limit }[$type]
        $limitGB = $(if ($q -and $q.Limit) { [math]::Round($q.Limit / 1GB) } else { $default })
        $legacyUbuntu = ($user.Name -eq $settings.SharedUser) -and (Test-Path 'C:\ProgramData\CBR\staff-setup-done.txt')
        [pscustomobject]@{
            Account     = $user.Name
            Name        = $user.FullName
            Type        = $type
            Created     = $created
            LastSignIn  = $(if ($user.LastLogon) { $user.LastLogon.ToString('yyyy-MM-dd HH:mm') } else { 'never' })
            DaysSince   = $(if ($user.LastLogon) { [int]((Get-Date) - $user.LastLogon).TotalDays } else { $null })
            Ends        = $(if ($user.AccountExpires) { $user.AccountExpires.ToString('yyyy-MM-dd') } else { '' })
            Expired     = [bool]($user.AccountExpires -and $user.AccountExpires -lt (Get-Date))
            Enabled     = $user.Enabled
            UsedGB      = $(if ($q) { [math]::Round($q.Used / 1GB, 1) } else { 0 })
            LimitGB     = $(if ($limitGB -and $limitGB -lt $noLimitGB) { $limitGB } else { 'none' })
            OverWarning = [bool]($q -and $q.Warn -and $q.Used -ge $q.Warn)
            SignedIn    = $sessions.ContainsKey($user.Name)
            Ubuntu      = (Test-Path (Get-UbuntuMarker $user.Name)) -or $legacyUbuntu
        }
    }
}

function Show-Audit($Rows) {
    $Rows | Format-Table Account, Name, Type, Created, LastSignIn, Ends,
        @{ n = 'Used GB'; e = { $_.UsedGB } }, @{ n = 'Limit GB'; e = { $_.LimitGB } }, SignedIn, Ubuntu -AutoSize | Out-Host
    foreach ($r in $Rows) {
        if ($r.Expired) { Write-Host "$($r.Account): ended on $($r.Ends). Remove it once they've copied their work off." -ForegroundColor Yellow }
        if ($r.OverWarning) { Write-Host "$($r.Account): over their warning level ($($r.UsedGB) GB of $($r.LimitGB) GB)." -ForegroundColor Yellow }
        if (-not $r.Enabled) { Write-Host "$($r.Account): turned off." -ForegroundColor Yellow }
    }
    $c = Get-Volume -DriveLetter C
    $people = ($Rows | Where-Object { $_.Type -ne 'admin' } | Measure-Object UsedGB -Sum).Sum
    Write-Host ("C: has {0:N0} GB free of {1:N0} GB. Accounts other than the admin use {2:N0} GB." -f ($c.SizeRemaining / 1GB), ($c.Size / 1GB), $people)
    if ($c.SizeRemaining -lt 200GB) { Write-Host 'Under 200 GB free: time to clear out some accounts.' -ForegroundColor Yellow }
}

function Save-Csv($Rows) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $file = Join-Path $logDir ('accounts-{0}-{1:yyyyMMdd-HHmm}.csv' -f $env:COMPUTERNAME, (Get-Date))
    $Rows | Select-Object @{ n = 'PC'; e = { $env:COMPUTERNAME } }, * | Export-Csv $file -NoTypeInformation
    Write-Host "Saved: $file" -ForegroundColor Green
}

function Read-EndDate([string]$Prompt) {
    while ($true) {
        $text = (Read-Host $Prompt).Trim()
        if (-not $text -or $text -eq 'none') { return $null }
        $date = [datetime]::MinValue
        if ([datetime]::TryParseExact($text, 'yyyy-MM-dd', $null, 'None', [ref]$date)) {
            if ($date.Date -ge (Get-Date).Date) { return $date.Date }
            Write-Host "That's in the past." -ForegroundColor Yellow
        } else { Write-Host 'Type it as yyyy-mm-dd, e.g. 2027-01-31.' -ForegroundColor Yellow }
    }
}

# The end of the last day: Windows stops sign-in from then on.
function Get-ExpiryMoment([datetime]$LastDay) { $LastDay.Date.AddDays(1).AddSeconds(-1) }

function New-StarterPassword {
    $chars = 'abcdefghjkmnpqrstuvwxyz23456789'   # nothing that's easy to misread
    $bytes = New-Object byte[] 8
    (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
    $part = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    'Cbr-' + $part.Substring(0, 4) + '-' + $part.Substring(4, 4)
}

# Only personal accounts: the admin, shared and session accounts are part of the build.
function Read-PersonalAccount([string]$Prompt) {
    $name = (Read-Host $Prompt).Trim()
    $user = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if (-not $user -or (Test-BuiltInAccount $user)) { throw "There's no account called '$name' on this PC." }
    if ((Get-CbrAccountType $name $settings) -ne 'personal') {
        throw "$name is part of the build (admin, shared or session), so it can't be changed here."
    }
    $user
}

function Add-Person {
    $name = (Read-Host 'Username (letters and numbers, e.g. jsmith)').Trim()
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9._-]{1,19}$') { throw 'Use 2-20 letters, numbers, dots, dashes or underscores, starting with a letter.' }
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { throw "There's already an account called $name on this PC." }
    $fullName = (Read-Host 'Their full name').Trim()
    $lastDay = Read-EndDate 'Last day of the account, as yyyy-mm-dd (or press Enter for no end date)'
    $password = New-StarterPassword
    $params = @{
        Name        = $name
        Password    = ConvertTo-SecureString $password -AsPlainText -Force
        FullName    = $fullName
        Description = "Personal account. Created $(Get-Date -Format yyyy-MM-dd) by $env:USERNAME."
    }
    if ($lastDay) { $params.AccountExpires = Get-ExpiryMoment $lastDay }
    New-LocalUser @params | Out-Null
    Add-LocalGroupMember -Group 'Users' -Member $name
    & net.exe user $name /logonpasswordchg:yes | Out-Null   # they choose their own at first sign-in
    $q = $settings.Quotas.Personal
    & fsutil quota modify C: ([int64]$q.Warn * 1GB) ([int64]$q.Limit * 1GB) $name | Out-Null
    Write-Host ''
    Write-Host "Created $name on $env:COMPUTERNAME." -ForegroundColor Green
    Write-Host "Starter password: $password"
    Write-Host 'Give them this. Windows asks them to choose their own password the first time they sign in.'
    if ($lastDay) { Write-Host "They can sign in until the end of $($lastDay.ToString('d MMMM yyyy'))." }
}

function Set-EndDate {
    $user = Read-PersonalAccount 'Username'
    $lastDay = Read-EndDate "New last day as yyyy-mm-dd, or 'none' for no end date"
    if ($lastDay) {
        Set-LocalUser -Name $user.Name -AccountExpires (Get-ExpiryMoment $lastDay)
        Write-Host "$($user.Name) can sign in until the end of $($lastDay.ToString('d MMMM yyyy'))." -ForegroundColor Green
    } else {
        Set-LocalUser -Name $user.Name -AccountNeverExpires
        Write-Host "$($user.Name) has no end date now." -ForegroundColor Green
    }
}

function Remove-Account {
    $user = Read-PersonalAccount 'Username to remove'
    if ((Get-SignedInSessions).ContainsKey($user.Name)) { throw "$($user.Name) is signed in. Ask them to sign out first." }
    $row = Get-AccountRows | Where-Object { $_.Account -eq $user.Name }
    Write-Host "This deletes $($user.Name) ($($user.FullName)) and all their files on this PC: $($row.UsedGB) GB." -ForegroundColor Red
    if ((Read-Host "Type $($user.Name) to go ahead").Trim() -ne $user.Name) { Write-Host 'Cancelled.'; return }
    $userProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'"
    if ($userProfile) { Remove-CimInstance -InputObject $userProfile }   # the folder and its registry entry, as Windows does it
    Remove-LocalUser -Name $user.Name
    Remove-Item (Get-UbuntuMarker $user.Name) -Force -ErrorAction SilentlyContinue
    Write-Host "Removed $($user.Name)." -ForegroundColor Green
}

# Deletes the session account's profile (files, browser history, app sign-ins, Ubuntu, settings).
# The account and its password stay; the next sign-in builds a fresh profile, and the note opens again.
function Reset-SessionAccount([switch]$NoPrompt) {
    $name = $settings.SessionUser
    $user = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if (-not $user) { throw "There's no $name account on this PC yet; provisioning makes it." }
    $sessions = Get-SignedInSessions
    if ($sessions.ContainsKey($name)) {
        if ($NoPrompt) { Write-Host "${env:COMPUTERNAME}: someone is signed in to $name, so it was left alone." -ForegroundColor Yellow; return }
        Write-Host "Someone is signed in to $name. Signing them out loses anything they haven't saved." -ForegroundColor Yellow
        if ((Read-Host 'Sign them out and reset it? (y/N)').Trim() -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; return }
        & logoff.exe $sessions[$name]
        for ($i = 0; $i -lt 60; $i++) {
            $p = Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'"
            if (-not $p -or -not $p.Loaded) { break }
            Start-Sleep -Seconds 1
        }
    } elseif (-not $NoPrompt) {
        if ((Read-Host "Reset $name? Its files, browser history and app sign-ins are deleted (y/N)").Trim() -notmatch '^(y|yes)$') {
            Write-Host 'Cancelled.'
            return
        }
    }
    $userProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'"
    if ($userProfile) {
        if ($userProfile.Loaded) { throw "$name is still signing out; try again in a minute." }
        Remove-CimInstance -InputObject $userProfile
    }
    Remove-Item (Get-UbuntuMarker $name) -Force -ErrorAction SilentlyContinue
    # Steam isn't in the build, but if it's been installed by hand, forget its remembered accounts too.
    $steamAccounts = 'C:\Program Files (x86)\Steam\config\loginusers.vdf'
    if ((Test-Path $steamAccounts) -and -not (Get-Process steam -ErrorAction SilentlyContinue)) {
        Remove-Item $steamAccounts -Force
        Write-Host "Cleared Steam's list of remembered accounts."
    }
    Write-Host "${env:COMPUTERNAME}: $name is reset. The next sign-in starts fresh." -ForegroundColor Green
}

function Show-BiggestFolders {
    $name = (Read-Host 'Username').Trim()
    $user = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if (-not $user) { throw "There's no account called '$name' on this PC." }
    $userProfile = Get-CimInstance Win32_UserProfile -Filter "SID='$($user.SID.Value)'"
    if (-not $userProfile) { Write-Host "$name hasn't signed in yet, so there are no files."; return }
    $root = $userProfile.LocalPath
    Write-Host "Measuring $root. This can take a minute or two..."
    $notLink = { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }
    $places = @(Get-ChildItem $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object $notLink | Where-Object { $_.Name -ne 'AppData' })
    $places += @(Get-ChildItem (Join-Path $root 'AppData\Local') -Directory -Force -ErrorAction SilentlyContinue | Where-Object $notLink)
    $places += @(Get-Item (Join-Path $root 'AppData\Roaming') -Force -ErrorAction SilentlyContinue)
    $sizes = foreach ($dir in $places) {
        $bytes = (Get-ChildItem $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        [pscustomobject]@{ Folder = $dir.FullName.Substring($root.Length + 1); GB = [math]::Round($bytes / 1GB, 1) }
    }
    $sizes | Sort-Object GB -Descending | Select-Object -First 12 | Format-Table -AutoSize | Out-Host
    Write-Host 'Usually the big ones: Work, Downloads, AppData\Local\UnrealEngine (Unreal''s cache, safe to delete),'
    Write-Host 'AppData\Local\Unity, and AppData\Local\wsl or Packages (Ubuntu and Docker).'
}

if (-not (Test-IsAdmin)) { throw 'Run this through bootstrap.bat, which asks for administrator rights.' }

if ($AsJson) { @(Get-AccountRows) | ConvertTo-Json -Depth 3; return }
if ($ResetSession) { Reset-SessionAccount -NoPrompt:$NoPrompt; return }

while ($true) {
    Write-Step "Accounts on $env:COMPUTERNAME"
    $rows = @(Get-AccountRows)
    Show-Audit $rows
    Write-Host ''
    Write-Host '  A  Add a person'
    Write-Host '  E  Change an end date'
    Write-Host '  R  Remove an account and its files'
    Write-Host "  S  Reset the session account ($($settings.SessionUser))"
    Write-Host '  B  Show the biggest folders in an account'
    Write-Host '  C  Save this table as a CSV (for the spreadsheet)'
    Write-Host '  Q  Back'
    $choice = (Read-Host "`nChoose").Trim().ToUpper()
    if ($choice -eq 'Q') { return }
    try {
        switch ($choice) {
            'A' { Add-Person }
            'E' { Set-EndDate }
            'R' { Remove-Account }
            'S' { Reset-SessionAccount }
            'B' { Show-BiggestFolders }
            'C' { Save-Csv $rows }
            default { Write-Host 'Type one of the letters above.' -ForegroundColor Yellow }
        }
    } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    Read-Host "`nPress Enter to carry on" | Out-Null
}
