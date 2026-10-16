# Shared helpers for the CBR workstation scripts. Windows PowerShell 5.1 compatible.

$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:InstalledCache = $null

function Get-CbrRepoRoot { $script:RepoRoot }

function Get-CbrManifest {
    Import-PowerShellDataFile (Join-Path $script:RepoRoot 'manifest.psd1')
}

# Finds the vendor installer folder. A rooted path is used as-is; a relative one (the default,
# 'cbr-deploy\installers') is looked for at the root of every drive, so the install USB is found
# whatever letter it gets. Returns $null if it isn't anywhere.
function Resolve-InstallerRoot([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        if (Test-Path $Path -ErrorAction SilentlyContinue) { return $Path }
        return $null
    }
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        if ($drive.Root -notmatch '^[A-Za-z]:\\$') { continue }
        $candidate = Join-Path $drive.Root $Path
        if (Test-Path $candidate -ErrorAction SilentlyContinue) { return $candidate }
    }
    $null
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

# Entries from Apps & Features (machine 64/32-bit and current user).
function Get-InstalledPrograms {
    if ($null -eq $script:InstalledCache) {
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $script:InstalledCache = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, PSChildName)
    }
    $script:InstalledCache
}

function Reset-InstalledProgramsCache { $script:InstalledCache = $null }

# Driver version as NVIDIA numbers it: Windows reports e.g. 32.0.15.8157 -> 581.57.
function Get-NvidiaDriverVersion {
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'NVIDIA*' } | Select-Object -First 1
    if (-not $gpu) { return $null }
    $digits = ($gpu.DriverVersion -replace '\.', '')
    if ($digits.Length -lt 5) { return $null }
    $last5 = $digits.Substring($digits.Length - 5)
    '{0}.{1}' -f [int]$last5.Substring(0, 3), $last5.Substring(3)
}

function Resolve-DetectPath($App) {
    $path = $App.DetectPath
    if ($App.Version) { $path = $path -replace '\{Version\}', $App.Version }
    $path
}

# Returns the installed version string, '' if installed with unknown version, or $null if missing.
function Get-InstalledVersion($App) {
    if ($App.Detect -eq 'nvidia-driver') { return Get-NvidiaDriverVersion }

    if ($App.DetectPath) {
        $path = Resolve-DetectPath $App
        if ($path -match '\{Version\}') { return $null }   # pinned version not chosen yet
        $item = Get-Item $path -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $item) { return $null }
        # A path with the version in it (UE_5.6, Editor\6000.3.26f1) is proof of that version.
        if ($App.Version -and $path -notmatch '[\*\?]' -and $path.Contains([string]$App.Version)) { return $App.Version }
        if ($item.VersionInfo -and $item.VersionInfo.ProductVersion) { return $item.VersionInfo.ProductVersion.Trim() }
        return ''
    }

    if ($App.Detect) {
        $match = Get-InstalledPrograms | Where-Object { $_.DisplayName -like $App.Detect } | Select-Object -First 1
        if (-not $match) { return $null }
        if ($match.DisplayVersion) { return [string]$match.DisplayVersion }
        return ''
    }
    $null
}

function Test-VersionMatch([string]$Installed, [string]$Expected) {
    if (-not $Expected) { return $true }
    if (-not $Installed) { return $false }
    ($Installed -eq $Expected) -or $Installed.StartsWith("$Expected.") -or $Installed.StartsWith("$Expected ")
}

# Status values: OK, MISSING, WRONG-VERSION, UNPINNED (pinned but Version not set yet).
function Get-AppStatus($App) {
    $installed = Get-InstalledVersion $App
    $status = 'OK'
    if ($null -eq $installed) {
        $status = 'MISSING'
    } elseif ($App.Policy -eq 'pinned') {
        if (-not $App.Version) { $status = 'UNPINNED' }
        elseif (-not (Test-VersionMatch $installed $App.Version)) { $status = 'WRONG-VERSION' }
    }
    [pscustomobject]@{
        Name      = $App.Name
        Method    = $App.Method
        Policy    = $App.Policy
        Expected  = $(if ($App.Version) { $App.Version } else { '' })
        Installed = $(if ($null -eq $installed) { '' } else { $installed })
        Status    = $status
    }
}

# Written by user-setup.ps1 once a person's Ubuntu and Docker are set up. Everyone can create files
# in C:\ProgramData and read them, so the admin side and the audit can see it.
function Get-UbuntuMarker([string]$User = $env:USERNAME) { "C:\ProgramData\CBR\ubuntu\$User.txt" }

# Where the "How to use this PC" note and the shortcuts go, for every account.
function Get-PublicDesktop { 'C:\Users\Public\Desktop' }
function Get-CbrStartMenu { 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\CBR' }
function Get-NotePath { Join-Path (Get-PublicDesktop) 'How to use this PC.html' }

# admin, shared (CBR), session (CBRSession) or personal.
function Get-CbrAccountType([string]$Name, $Settings) {
    if ($Name -eq $Settings.SharedUser) { return 'shared' }
    if ($Name -eq $Settings.SessionUser) { return 'session' }
    $admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue | ForEach-Object { ($_.Name -split '\\')[-1] })
    if ($admins -contains $Name) { return 'admin' }
    'personal'
}

# Accounts that are part of Windows itself, not people: Administrator, Guest, DefaultAccount,
# WDAGUtilityAccount (identified by the end of their SID, which doesn't depend on the language).
function Test-BuiltInAccount($LocalUser) { $LocalUser.SID.Value -match '-(500|501|503|504)$' }

# Asks twice, so a typo doesn't lock anyone out.
function Read-NewPassword([string]$For) {
    while ($true) {
        $first = Read-Host "Password for $For" -AsSecureString
        $second = Read-Host 'Type it again' -AsSecureString
        $a = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
        try {
            $plainA = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($a)
            $same = $plainA -ceq [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
            $empty = -not $plainA
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)
        }
        if ($empty) { Write-Host "It can't be blank." -ForegroundColor Yellow }
        elseif (-not $same) { Write-Host "Those didn't match. Try again." -ForegroundColor Yellow }
        else { return $first }
    }
}

function New-CbrShortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$Icon,
                         [string]$WorkingDirectory, [int]$WindowStyle = 1) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $link.TargetPath = $Target
    if ($Arguments) { $link.Arguments = $Arguments }
    if ($Icon) { $link.IconLocation = $Icon }
    if ($WorkingDirectory) { $link.WorkingDirectory = $WorkingDirectory }
    $link.WindowStyle = $WindowStyle   # 1 normal, 7 minimised
    $link.Save()
}

# Disk use per account on C:, from Windows' disk quotas: name -> @{ Used; Warn; Limit } in bytes.
# Instant, because Windows keeps the totals as files change. Needs admin.
function Get-QuotaUsage {
    $usage = @{}
    foreach ($q in Get-CimInstance Win32_DiskQuota -ErrorAction SilentlyContinue) {
        if ($q.QuotaVolume.DeviceID -ne 'C:') { continue }
        $usage[$q.User.Name] = @{ Used = [uint64]$q.DiskSpaceUsed; Warn = [uint64]$q.WarningLimit; Limit = [uint64]$q.Limit }
    }
    $usage
}

# A task that runs a script from this repo each time $User signs in, in a window on their desktop.
# No password is stored: it only runs while they're signed in. -Elevated runs it as admin without
# a prompt (for the admin account); -Hidden starts it without a window. -AllUsers runs it for
# whoever signs in, as that person.
function Register-CbrSignInTask([string]$Name, [string]$User, [string]$Script, [string]$Arguments,
                                [switch]$Elevated, [switch]$Hidden, [switch]$AllUsers) {
    $style = $(if ($Hidden) { '-WindowStyle Hidden ' } else { '' })
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass $style-File `"$Script`" $Arguments"
    $level = $(if ($Elevated) { 'Highest' } else { 'Limited' })
    if ($AllUsers) {
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel $level
    } else {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
        $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $level
    }
    $trigger.Delay = 'PT20S'   # let the desktop and network settle first
    $options = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal `
        -Settings $options -Force | Out-Null
}

function Unregister-CbrTask([string]$Name) {
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }
}

# Waits up to $Minutes for github.com to answer. A fresh sign-in can take a moment to get online.
function Wait-Internet([int]$Minutes = 2) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
        & curl.exe --silent --head --max-time 10 --output NUL https://github.com
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    $false
}

Export-ModuleMember -Function *
