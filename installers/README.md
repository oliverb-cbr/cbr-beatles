# Vendor installers

The installers themselves don't go in Git. They live on the install USB in a `cbr-deploy\installers` folder at its root. Provisioning searches every drive for that folder, so the USB's drive letter doesn't matter. (`Settings.InstallerRoot` in `manifest.psd1` sets the folder; a full path such as a network share also works.)

```text
<USB>:\cbr-deploy\installers\
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
4. Commit and push, then plug the USB into each machine and run `scripts\update.ps1` there. (`fleet.ps1 -Action Update` works over the network, so it can't reach the installers on the USB.)

Get the SHA-256 with `Get-FileHash <file>`.

