# Vendor installers

The installers don't go in Git. Put them straight into a `cbr-deploy\installers` folder at the root of the install USB, with the names they downloaded with. No renaming, no subfolders:

```text
<USB>:\cbr-deploy\installers\
├── 617.42-desktop-win10-win11-64bit-international-nsd-dch-whql.exe
├── TouchDesigner.2025.xxxxx.exe
├── DaVinci_Resolve_xx.x_Windows.exe        (unzip Resolve's download, keep the .exe)
├── Insta360 Studio ... .exe
├── Insta360 Stitcher ... .exe
├── LCC Studio ... .exe
├── Meta Quest Developer Hub ... .exe
└── VIVE Mars ... .exe
```

Provisioning searches every drive for `cbr-deploy\installers`, so the USB's drive letter doesn't matter.

**How it knows which file is which:** each app in `manifest.psd1` has an `Installer` pattern, such as `TouchDesigner*` or `*-nsd-*` for the NVIDIA Studio driver. If a file doesn't match any pattern, provisioning lists it at the end, so a vendor's unexpected file name shows up straight away and the pattern can be fixed.

## Updating one

1. Download the new installer into the same folder. You can leave the old one there: when both match, provisioning picks the one whose name contains the `Version` from the manifest. (Delete old ones once you're happy, to keep the folder tidy.)
2. Test it on JOHN, then change `Version` in the manifest.
3. Commit and push, then plug the USB into each machine and run `scripts\update.ps1` there. (`fleet.ps1 -Action Update` works over the network, so it can't reach the USB.)

If an installer's name doesn't include its version, keep only one copy in the folder.
