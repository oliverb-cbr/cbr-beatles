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
        if ($App.Method -eq 'unity' -or $App.Method -eq 'manual') {
            if ($App.Version -and $path -notmatch '[\*\?]') { return $App.Version }
        }
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

Export-ModuleMember -Function *
