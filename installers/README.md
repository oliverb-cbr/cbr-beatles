# Vendor installers

The installers themselves don't go in Git. They live in the share set as `Settings.InstallerRoot` in `manifest.psd1`, laid out like this:

```text
<InstallerRoot>\
├── NVIDIA\driver.exe
├── TouchDesigner\TouchDesigner.exe
├── DaVinciResolve\DaVinci_Resolve_Windows.exe
├── Insta360\Insta360Studio.exe
├── Insta360\Insta360Stitcher.exe
├── LCC\LCCStudio.exe
├── Meta\MQDH.exe
└── VIVE\ViveMars.exe
```

Use those fixed file names (rename the downloads) so the manifest only changes when the version does.

To roll out a new version of one of these:

1. Keep the old installer in an `old\` subfolder so you can roll back.
2. Put the new one in place under the same name.
3. Test it on JOHN, then update `Version` (and `Sha256`, if you use it) in the manifest.
4. Commit, push and run `scripts\fleet.ps1 -Action Update`.

Get the SHA-256 with `Get-FileHash <file>`.

The machines should only have read access to this share.
