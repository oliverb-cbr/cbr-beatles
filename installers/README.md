# Vendor installers

The installers themselves don't go in Git. They live on the install USB in a `cbr-deploy\installers` folder at its root. Provisioning searches every drive for that folder, so the USB's drive letter doesn't matter. (`Settings.InstallerRoot` in `manifest.psd1` sets the folder; a full path such as a network share also works.)

```text
<USB>:\cbr-deploy\installers\
├── NVIDIA\            617.42-desktop-win10-win11-64bit-international-nsd-dch-whql.exe
├── TouchDesigner\     (TouchDesigner installer)
├── DaVinciResolve\    (Resolve installer: unzip the download, keep the .exe)
├── Insta360Studio\
├── Insta360Stitcher\
├── LCC\
├── Meta\              (Meta Quest Developer Hub)
└── VIVE\              (VIVE Mars)
```

Keep the downloads' original names. Each folder holds exactly one installer (.exe or .msi) directly inside it, and provisioning uses that one. If a folder has two, provisioning stops and tells you, so keep older versions in a subfolder such as `old\`.

To roll out a new version of one of these:

1. Move the old installer into the app's `old\` subfolder so you can roll back.
2. Put the new one in the app's folder.
3. Test it on JOHN, then update `Version` (and `Sha256`, if you use it) in the manifest.
4. Commit and push, then plug the USB into each machine and run `scripts\update.ps1` there. (`fleet.ps1 -Action Update` works over the network, so it can't reach the installers on the USB.)

Get the SHA-256 with `Get-FileHash <file>`.

