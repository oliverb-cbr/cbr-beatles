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

# Written by user-setup.ps1 once the staff account's WSL and Docker are set up. Staff can create
# files in C:\ProgramData, and everyone can read it, so the admin side and the audit can see it.
function Get-StaffSetupMarker { 'C:\ProgramData\CBR\staff-setup-done.txt' }

# A task that runs a script from this repo each time $User signs in, in a window on their desktop.
# No password is stored: it only runs while they're signed in. -Elevated runs it as admin without
# a prompt (for the admin account); -Hidden starts it without a window.
function Register-CbrSignInTask([string]$Name, [string]$User, [string]$Script, [string]$Arguments,
                                [switch]$Elevated, [switch]$Hidden) {
    $style = $(if ($Hidden) { '-WindowStyle Hidden ' } else { '' })
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass $style-File `"$Script`" $Arguments"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
    $trigger.Delay = 'PT20S'   # let the desktop and network settle first
    $level = $(if ($Elevated) { 'Highest' } else { 'Limited' })
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $level
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
