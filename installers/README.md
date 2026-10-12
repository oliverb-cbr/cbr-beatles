# Vendor installers

The installers themselves don't go in Git. The manifest is still the source of truth for them: each vendor app in `manifest.psd1` records where its installer comes from and the SHA-256 of the tested file, and provisioning checks every installer against that hash before running it, wherever the file came from.

## Where provisioning gets them

1. **`C:\CBR\installers` on the machine.** Downloads land here, and so do installers you fetch by hand. Files keep the names they downloaded with.
2. **An extra folder, if one is plugged in:** a `cbr-deploy\installers` folder at the root of any drive (a USB stick), or a NAS share set in `Settings.InstallerRoot`. Optional.
3. **The vendor's own link (`Url` in the manifest).** If neither folder has the file, provisioning downloads it into `C:\CBR\installers`. Only for links that don't expire and need no sign-in.

| App | How it's fetched |
|---|---|
| NVIDIA Studio driver | Downloaded from NVIDIA |
| TouchDesigner | Downloaded from Derivative |
| DaVinci Resolve | **By hand.** Blackmagic's links expire, so download it from their site and unzip it into `C:\CBR\installers` |
| Insta360 Studio and Stitcher, LCC Studio, LCC Editor, LCC Model Editor, Meta Quest Developer Hub | By hand for now, until their download links are checked |

When an installer can't be found or downloaded, provisioning says where to get it and carries on with everything else.

## Hashes

When a file has no `Sha256` in the manifest yet, provisioning prints its hash. Copy that into the manifest once you've tested the installer. From then on a damaged or different file is refused instead of installed.

To get one yourself: `Get-FileHash <file>`.

## How each file is matched

Each app has an `Installer` name pattern, such as `TouchDesigner*` or `*-nsd-*` (the NVIDIA Studio driver; Game Ready drivers don't have `-nsd-`). `.zip` and `.iso` files are unpacked or mounted and the installer inside is run. Files that no pattern matches are listed at the end of provisioning, so a vendor's unexpected file name shows up straight away.

## Updating one

1. Change `Url` (or download the new file by hand), test it on JOHN, then update `Version` and `Sha256` in the manifest.
2. Commit and push, then run `scripts\update.ps1` on each machine.
