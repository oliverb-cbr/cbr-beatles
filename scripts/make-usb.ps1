<#
.SYNOPSIS
    Makes or refreshes the CBR install USB stick.

.DESCRIPTION
    Run it through bootstrap.bat ("Make or refresh the install USB stick"). It:
    1. Asks which stick to use. Only USB drives of 260 GB or less are offered, so a big external
       drive can't be picked by mistake.
    2. Finds the Windows ISO and checks it against the SHA-256 in the manifest.
    3. If the stick doesn't have Ventoy yet, erases it and installs Ventoy, once you type ERASE.
       A stick that already has Ventoy keeps everything on it.
    4. Puts the ISO, the answer file, Ventoy's settings and bootstrap.bat on the stick, and checks
       the copied ISO.
    5. Copies installers from C:\CBR\installers that can't be downloaded automatically (Unreal,
       RealityScan), so machines set up from the stick find them.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

$manifest = Get-CbrManifest
$settings = $manifest.Settings
$repo = Get-CbrRepoRoot
$maxStickGB = 260

# Most sticks report their bus as USB. Fast ones (and USB SSDs) using UAS can report SCSI
# instead, so also check whether the disk's device hangs off a USB port.
function Test-OnUsb($Disk) {
    if ($Disk.BusType -eq 'USB') { return $true }
    $drive = Get-CimInstance Win32_DiskDrive -Filter "Index=$($Disk.Number)" -ErrorAction SilentlyContinue
    if (-not $drive) { return $false }
    if ($drive.InterfaceType -eq 'USB') { return $true }
    $id = $drive.PNPDeviceID
    for ($i = 0; $i -lt 3 -and $id; $i++) {
        $id = (Get-PnpDeviceProperty -InstanceId $id -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue).Data
        if ($id -like 'USB\*') { return $true }
    }
    $false
}

# Why a disk can't be the stick, or $null if it can.
function Get-StickProblem($Disk) {
    if ($Disk.IsBoot -or $Disk.IsSystem) { return 'Windows is on it' }
    if ($Disk.Size -le 0) { return 'no media in it' }
    if ($Disk.Size -gt $maxStickGB * 1GB) { return "over $maxStickGB GB" }
    if (-not (Test-OnUsb $Disk)) { return 'not plugged in by USB' }
    $null
}

function Get-UsbSticks {
    Get-Disk | Where-Object { -not (Get-StickProblem $_) } | Sort-Object Number
}

function Get-DriveLetters($Disk) {
    @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue |
        Where-Object { "$($_.DriveLetter)" -match '^[A-Z]$' } | ForEach-Object { "$($_.DriveLetter):\" })
}

function Test-VentoyDisk($Disk) {
    $parts = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue)
    $labels = @($parts | Get-Volume -ErrorAction SilentlyContinue | ForEach-Object FileSystemLabel)
    # Ventoy's layout: a big data partition, then a 32 MB boot partition called VTOYEFI.
    ($labels -contains 'VTOYEFI') -or ($parts.Count -eq 2 -and $parts[1].Size -eq 32MB)
}

function Get-DiskSummary($Disk) {
    $volumes = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue |
        Where-Object { "$($_.DriveLetter)" -match '^[A-Z]$' } |
        ForEach-Object { "$($_.DriveLetter): '$(($_ | Get-Volume -ErrorAction SilentlyContinue).FileSystemLabel)'" })
    $letters = $(if ($volumes) { ' - ' + ($volumes -join ', ') } else { '' })
    "disk $($Disk.Number): $($Disk.FriendlyName), $([math]::Round($Disk.Size / 1GB)) GB$letters"
}

function Select-Stick {
    while ($true) {
        # @() keeps a single stick a list; a function hands back one result on its own.
        $sticks = @(Get-UsbSticks)
        if (-not $sticks.Count) {
            Write-Host "No USB stick found. USB drives over $maxStickGB GB aren't offered, so a big external drive can't be picked by mistake." -ForegroundColor Yellow
            Write-Host 'The disks on this PC, and why each was left out:'
            foreach ($d in Get-Disk | Sort-Object Number) {
                Write-Host "  disk $($d.Number): $($d.FriendlyName), bus $($d.BusType), $([math]::Round($d.Size / 1GB)) GB - $(Get-StickProblem $d)"
            }
            if ((Read-Host 'Press Enter to look again, or type Q to quit').Trim().ToUpper() -eq 'Q') { return $null }
            continue
        }
        Write-Host 'USB sticks plugged in:'
        foreach ($d in $sticks) {
            $tag = $(if (Test-VentoyDisk $d) { '  [has Ventoy already]' } else { '' })
            Write-Host "  $(Get-DiskSummary $d)$tag"
        }
        if ($sticks.Count -eq 1) {
            if ((Read-Host "`nUse disk $($sticks[0].Number)? (y/N)").Trim() -eq 'y') { return $sticks[0] }
            return $null
        }
        $n = (Read-Host "`nType the disk number of the stick to use (or Q to quit)").Trim()
        if ($n.ToUpper() -eq 'Q') { return $null }
        $pick = $sticks | Where-Object { [string]$_.Number -eq $n }
        if ($pick) { return $pick }
        Write-Host "That's not one of the disks listed." -ForegroundColor Yellow
    }
}

# Ventoy's data partition (always the first) as a drive root like 'E:\'.
function Get-StickRoot($Disk) {
    Update-HostStorageCache
    for ($i = 0; $i -lt 30; $i++) {
        $part = Get-Partition -DiskNumber $Disk.Number -PartitionNumber 1 -ErrorAction SilentlyContinue
        if ($part -and "$($part.DriveLetter)" -match '^[A-Z]$') { return "$($part.DriveLetter):\" }
        if ($i -eq 10 -and $part) { $part | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
    throw "The stick's Ventoy partition has no drive letter. Unplug the stick, plug it back in and run this again."
}

function Get-Sha256([string]$Path) {
    Write-Host "Checking $(Split-Path -Leaf $Path) (a minute or two for an ISO)..."
    (Get-FileHash $Path -Algorithm SHA256).Hash
}

# Looks in the usual download folders, then near the top of every drive except $Skip.
function Find-File([string]$Name, [string[]]$Skip) {
    foreach ($folder in 'Downloads', 'Desktop', 'Documents') {
        $candidate = Join-Path (Join-Path $env:USERPROFILE $folder) $Name
        if (Test-Path $candidate) { return $candidate }
    }
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        if ($drive.Root -notmatch '^[A-Za-z]:\\$' -or $Skip -contains $drive.Root) { continue }
        $hit = Get-ChildItem $drive.Root -Filter $Name -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $null
}

function Select-IsoFile([string]$Name) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Pick the Windows ISO ($Name)"
    $dialog.Filter = 'Disc images (*.iso)|*.iso'
    $dialog.InitialDirectory = Join-Path $env:USERPROFILE 'Downloads'
    # An always-on-top owner stops the dialog opening hidden behind this window.
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    try { if ($dialog.ShowDialog($owner) -eq 'OK') { return $dialog.FileName } }
    finally { $owner.Dispose() }
    $null
}

# Returns the ISO to copy and its hash, or $null if the stick already has the tested one.
# Runs before anything is erased, so an ISO kept on the stick itself isn't lost.
function Get-IsoToCopy($Disk, [bool]$HasVentoy) {
    $iso = $settings.WindowsIso
    if ($HasVentoy) {
        $onStick = Join-Path (Get-StickRoot $Disk) "ISO\Windows11\$($iso.File)"
        if ((Test-Path $onStick) -and (Get-Sha256 $onStick) -eq $iso.Sha256) {
            Write-Host 'The stick already has the tested Windows ISO.'
            return $null
        }
    }
    $source = Find-File $iso.File (Get-DriveLetters $Disk)
    if (-not $source) {
        Write-Host "Couldn't find $($iso.File) on this PC." -ForegroundColor Yellow
        Write-Host 'Pick it in the window that opens. If you haven''t got it, download the Windows 11 English International'
        Write-Host 'ISO from https://www.microsoft.com/software-download/windows11 first.'
        $source = Select-IsoFile $iso.File
        if (-not $source) { throw 'No Windows ISO picked, so the stick was left as it was.' }
        if ((Get-DriveLetters $Disk) -contains ([IO.Path]::GetPathRoot($source)) -and -not $HasVentoy) {
            throw 'That ISO is on the stick that would be erased. Copy it to this PC first, then run this again.'
        }
    }
    Write-Host "Windows ISO: $source"
    $hash = Get-Sha256 $source
    if ($hash -ne $iso.Sha256) {
        Write-Host "That isn't the ISO tested for the CBR build: its SHA-256 differs from the manifest." -ForegroundColor Yellow
        Write-Host 'Only use it to move the build to a new Windows release. Test it in the VM, then put its name'
        Write-Host "and SHA-256 ($hash) in Settings.WindowsIso in manifest.psd1."
        if ((Read-Host 'Put it on the stick anyway? (y/N)').Trim() -ne 'y') { throw 'Stopped, so the stick was left as it was.' }
    }
    [pscustomobject]@{ Path = $source; Sha256 = $hash }
}

function Install-Ventoy($Disk) {
    $v = $settings.Ventoy
    $zip = Join-Path $env:TEMP "ventoy-$($v.Version)-windows.zip"
    if (-not (Test-Path $zip) -or (Get-FileHash $zip -Algorithm SHA256).Hash -ne $v.Sha256) {
        Write-Host "Downloading Ventoy $($v.Version)..."
        & curl.exe --fail --location --retry 3 --progress-bar --output $zip $v.Url
        if ($LASTEXITCODE -ne 0) { throw "Couldn't download Ventoy (curl exit $LASTEXITCODE): $($v.Url)" }
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $v.Sha256) {
            Remove-Item $zip -Force
            throw "The Ventoy download doesn't match the SHA-256 in the manifest, so it wasn't used."
        }
    }
    $dir = Join-Path $env:TEMP "cbr-ventoy-$($v.Version)"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $dir
    $exe = Get-ChildItem $dir -Recurse -Filter 'Ventoy2Disk.exe' | Select-Object -First 1
    if (-not $exe) { throw "Ventoy2Disk.exe isn't in the Ventoy download." }
    $work = $exe.DirectoryName

    Write-Host "Installing Ventoy on disk $($Disk.Number). This takes a minute or two..."
    # Ventoy's command-line mode. /I installs, erasing the disk. Ventoy refuses disks that don't
    # report their bus as USB; a UAS stick reports SCSI, so after Test-OnUsb has checked it's on
    # a USB port, that check is turned off for it.
    $ventoyArgs = "VTOYCLI /I /PhyDrive:$($Disk.Number)"
    if ($Disk.BusType -ne 'USB') { $ventoyArgs += ' /NOUSBCheck' }
    Start-Process $exe.FullName -ArgumentList $ventoyArgs -WorkingDirectory $work -Wait
    # It writes 0 (worked) or 1 (failed) to cli_done.txt once it has finished.
    $done = Join-Path $work 'cli_done.txt'
    $deadline = (Get-Date).AddMinutes(10)
    while (-not (Test-Path $done) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    $result = $(if (Test-Path $done) { (Get-Content $done -Raw).Trim() } else { 'no result after 10 minutes' })
    if ($result -ne '0') { throw "Ventoy didn't install ($result). Its log: $(Join-Path $work 'cli_log.txt')" }
    Write-Host 'Ventoy installed.'
}

function Copy-BigFile([string]$Source, [string]$DestDir) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    # /IS /IT: copy even if a same-sized file is there (it may be a damaged copy).
    & robocopy (Split-Path $Source) $DestDir (Split-Path -Leaf $Source) /J /IS /IT /NJH /NJS /NDL /NC /NS
    # robocopy: 0-7 mean it worked; 8 and up are failures.
    if ($LASTEXITCODE -ge 8) { throw "Copying $(Split-Path -Leaf $Source) to the stick failed (robocopy $LASTEXITCODE)." }
}

function Copy-WindowsIso([string]$Root, $Iso) {
    $isoDir = Join-Path $Root 'ISO\Windows11'
    $keep = $settings.WindowsIso.File
    if ($Iso) {
        Write-Host 'Copying the Windows ISO to the stick (5-10 minutes)...'
        Copy-BigFile $Iso.Path $isoDir
        $keep = Split-Path -Leaf $Iso.Path
        if ((Get-Sha256 (Join-Path $isoDir $keep)) -ne $Iso.Sha256) {
            throw 'The copy on the stick is damaged (its SHA-256 differs). Try another USB port or stick.'
        }
        Write-Host 'Copied and checked.'
    }
    # Every ISO in this folder gets the CBR answer file, so old ones shouldn't linger.
    $others = @(Get-ChildItem $isoDir -Filter *.iso -File -ErrorAction SilentlyContinue | Where-Object Name -ne $keep)
    if ($others.Count) {
        Write-Host "Other ISOs in ISO\Windows11 on the stick: $(($others | ForEach-Object Name) -join ', ')"
        if ((Read-Host 'Delete them, so the stick only offers the tested one? (Y/n)').Trim() -ne 'n') { $others | Remove-Item -Force }
    }
}

# Ventoy's settings. Ours make it offer the answer file for ISOs in ISO\Windows11; anything else
# already in the stick's ventoy.json is kept.
function Write-VentoyJson([string]$Path) {
    $oursPath = Join-Path $repo 'windows\ventoy.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    if (-not (Test-Path $Path)) { Copy-Item $oursPath $Path; return }
    $ours = Get-Content $oursPath -Raw | ConvertFrom-Json
    try { $theirs = Get-Content $Path -Raw | ConvertFrom-Json }
    catch { throw "ventoy\ventoy.json on the stick isn't valid JSON. Fix or delete it, then run this again." }
    $parents = @($ours.auto_install | ForEach-Object parent)
    $kept = @($theirs.auto_install | Where-Object { $_ -and $parents -notcontains $_.parent })
    $otherKeys = @($theirs.PSObject.Properties.Name | Where-Object { $_ -ne 'auto_install' })
    if (-not $kept.Count -and -not $otherKeys.Count) { Copy-Item $oursPath $Path -Force; return }
    # Windows PowerShell wraps arrays oddly in ConvertTo-Json unless this type data is removed.
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
    $merged = [ordered]@{}
    foreach ($key in $otherKeys) { $merged[$key] = $theirs.$key }
    $merged['auto_install'] = @($kept) + @($ours.auto_install)
    $json = [pscustomobject]$merged | ConvertTo-Json -Depth 20
    # No byte-order mark: Ventoy's parser doesn't expect one.
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding $false))
}

# Installers with no download link in the manifest (Unreal, RealityScan) go on the stick too, so
# machines set up from it find them. Provisioning checks each one's SHA-256 before using it.
function Copy-ManualInstallers([string]$Root) {
    $apps = @($manifest.Apps | Where-Object { $_.Method -eq 'installer' -and -not $_.Url })
    $files = @(Get-ChildItem $settings.InstallerCache -File -ErrorAction SilentlyContinue |
        Where-Object { $name = $_.Name; $apps | Where-Object { $name -like $_.Installer } })
    if (-not $files.Count) {
        Write-Host "None in $($settings.InstallerCache) on this PC."
        return
    }
    $dest = Join-Path $Root $settings.InstallerRoot
    foreach ($f in $files) {
        $there = Join-Path $dest $f.Name
        if ((Test-Path $there) -and (Get-Item $there).Length -eq $f.Length) { Write-Host "$($f.Name): on the stick already."; continue }
        $free = (Get-Volume -DriveLetter $Root.Substring(0, 1)).SizeRemaining
        if ($f.Length -gt $free) { Write-Host "Not enough room on the stick for $($f.Name); skipped." -ForegroundColor Yellow; continue }
        Write-Host "Copying $($f.Name)..."
        Copy-BigFile $f.FullName $dest
    }
}

Write-Step 'Which USB stick'
$disk = Select-Stick
if (-not $disk) { Write-Host 'Stopped. Nothing has changed.'; return }
$hasVentoy = Test-VentoyDisk $disk

Write-Step 'Windows ISO'
$iso = Get-IsoToCopy $disk $hasVentoy

# Checked now, before anything is erased.
if ($iso) {
    $isoBytes = (Get-Item $iso.Path).Length
    if ($hasVentoy) {
        $stickRoot = Get-StickRoot $disk
        $room = (Get-Volume -DriveLetter $stickRoot.Substring(0, 1)).SizeRemaining
        $old = Join-Path $stickRoot ("ISO\Windows11\" + (Split-Path -Leaf $iso.Path))
        if (Test-Path $old) { $room += (Get-Item $old).Length }
    } else {
        $room = $disk.Size - 100MB   # Ventoy's own partitions take a few MB
    }
    if ($isoBytes -gt $room) {
        throw "Not enough room on the stick for the Windows ISO: it needs $([math]::Ceiling($isoBytes / 1GB)) GB, and there's $([math]::Floor($room / 1GB)) GB."
    }
}

Write-Step 'Ventoy (the stick''s boot menu)'
if ($hasVentoy) {
    Write-Host 'The stick has Ventoy already, so nothing on it is erased.'
} else {
    Write-Host "EVERYTHING on $(Get-DiskSummary $disk) will be erased." -ForegroundColor Red
    if ((Read-Host 'Type ERASE to erase it and install Ventoy').Trim() -ne 'ERASE') {
        Write-Host 'Stopped. Nothing has changed.'
        return
    }
    Install-Ventoy $disk
}
$root = Get-StickRoot $disk
Write-Host "The stick is $root"

Write-Step 'Copying the Windows ISO'
Copy-WindowsIso $root $iso

Write-Step 'Answer file, Ventoy settings and bootstrap.bat'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'ventoy\script') | Out-Null
Copy-Item (Join-Path $repo 'windows\autounattend.xml') (Join-Path $root 'ventoy\script\cbr-autounattend.xml') -Force
Write-VentoyJson (Join-Path $root 'ventoy\ventoy.json')
Copy-Item (Join-Path $repo 'bootstrap.bat') (Join-Path $root 'bootstrap.bat') -Force
Write-Host 'Done.'

Write-Step 'Installers that can''t be downloaded automatically'
Copy-ManualInstallers $root

Write-Host ''
Write-Host "The stick ($root) is ready. Eject it before unplugging it." -ForegroundColor Green
Write-Host 'To install a workstation: boot it from the stick, pick the Windows ISO and choose the CBR template.'
Write-Host 'After Windows is installed, run bootstrap.bat from the stick. Full steps: docs\build-checklist.md.'
