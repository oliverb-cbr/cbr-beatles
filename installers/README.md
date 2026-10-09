# Vendor installers

The installers don't go in Git. Put them straight into a `cbr-deploy\installers` folder at the root of the install USB, with the names they downloaded with. No renaming, no subfolders:

```text
<USB>:\cbr-deploy\installers\
├── 617.42-desktop-win10-win11-64bit-international-nsd-dch-whql.exe
├── DaVinci_Resolve_21.1.1_Windows.exe
├── Insta360Stitcher_Winx64_4.0.1_build_202506122124.exe
├── Insta360_Studio_6.0.6_release_....exe
├── LCC Model Editor_v1.3.1.exe
├── LCCEditorSetup_v2.5.0.018-online-en.exe
├── LCCStudio_2.5.0.025_full_en.iso          (mounted automatically)
├── Meta-Quest-Developer-Hub.exe
└── TouchDesigner.2025.33230.exe
```

.zip and .iso files are fine as downloaded: provisioning unpacks or mounts them and runs the installer inside.

Provisioning searches every drive for `cbr-deploy\installers`, so the USB's drive letter doesn't matter.

**How it knows which file is which:** each app in `manifest.psd1` has an `Installer` pattern, such as `TouchDesigner*` or `*-nsd-*` for the NVIDIA Studio driver. If a file doesn't match any pattern, provisioning lists it at the end, so a vendor's unexpected file name shows up straight away and the pattern can be fixed.

## Updating one

1. Download the new installer into the same folder. You can leave the old one there: when both match, provisioning picks the one whose name contains the `Version` from the manifest. (Delete old ones once you're happy, to keep the folder tidy.)
2. Test it on JOHN, then change `Version` in the manifest.
3. Commit and push, then plug the USB into each machine and run `scripts\update.ps1` there. (`fleet.ps1 -Action Update` works over the network, so it can't reach the USB.)

If an installer's name doesn't include its version, keep only one copy in the folder.
