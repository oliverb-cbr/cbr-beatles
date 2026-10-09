<#
.SYNOPSIS
    Packs autounattend.xml into a tiny ISO to attach to the Hyper-V test VM as a second DVD drive.

.DESCRIPTION
    Windows Setup looks for autounattend.xml at the root of every removable drive, including
    DVD drives, so attaching this ISO alongside the Windows ISO makes the VM install hands-off
    in the same way the USB stick does for the real machines.

.EXAMPLE
    .\make-answer-iso.ps1                         # writes windows\cbr-answer.iso
    Add-VMDvdDrive CBR-Test -Path C:\CBR\cbr-beatles\windows\cbr-answer.iso
#>
param([string]$Output = (Join-Path $PSScriptRoot 'cbr-answer.iso'))

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class CbrIsoWriter {
    public static void Write(object comStream, string path) {
        IStream stream = (IStream)comStream;
        byte[] buffer = new byte[65536];
        IntPtr read = Marshal.AllocHGlobal(4);
        try {
            using (FileStream file = File.Create(path)) {
                while (true) {
                    stream.Read(buffer, buffer.Length, read);
                    int n = Marshal.ReadInt32(read);
                    if (n == 0) break;
                    file.Write(buffer, 0, n);
                }
            }
        } finally { Marshal.FreeHGlobal(read); }
    }
}
'@

$staging = Join-Path ([IO.Path]::GetTempPath()) ('cbr-answer-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    Copy-Item (Join-Path $PSScriptRoot 'autounattend.xml') $staging
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.FileSystemsToCreate = 3      # ISO 9660 + Joliet
    $image.VolumeName = 'CBR_ANSWER'
    $image.Root.AddTree($staging, $false)
    [CbrIsoWriter]::Write($image.CreateResultImage().ImageStream, $Output)
    Write-Host "Wrote $Output"
} finally {
    Remove-Item $staging -Recurse -Force
}
