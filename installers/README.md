# Vendor installers

The installers themselves don't go in Git. The manifest is still the source of truth for them: each vendor app in `manifest.psd1` records where its installer comes from and the SHA-256 of the tested file, and provisioning checks every installer against that hash before running it, wherever the file came from.

## Where provisioning gets them

1. **`C:\CBR\installers` on the machine.** Downloads land here, and so do installers you fetch by hand. Files keep the names they downloaded with.
2. **An extra folder, if one is plugged in:** a `cbr-deploy\installers` folder at the root of any drive (the install USB stick; refreshing the stick puts the hand-downloaded installers there), or a NAS share set in `Settings.InstallerRoot`. Optional.
3. **The vendor's own link (`Url` in the manifest).** If neither folder has the file, provisioning downloads it into `C:\CBR\installers`. Only for links that don't expire and need no sign-in.

| App | How it's fetched |
|---|---|
| NVIDIA Studio driver, TouchDesigner, Insta360 Studio and Stitcher, LCC Studio (.iso), LCC Editor, LCC Model Editor, Meta Quest Developer Hub (.zip) | Downloaded from the vendor's own link |
| Unreal Engine 5.6, RealityScan | From the Epic Developer Portal, by hand (see below) |
| Unity Editor | Not a file: Unity Hub downloads it, with the version from the manifest |

Apps whose links expire or need a sign-in can still be added with a `DownloadPage` instead of a `Url`: the file is then put in `C:\CBR\installers` by hand. (DaVinci Resolve was dropped from the build for this reason: Blackmagic's download links are issued per registration and expire within hours.)

When an installer can't be found or downloaded, provisioning says where to get it and carries on with everything else.

## Unreal Engine and RealityScan

Epic makes offline installers for both. They install silently, with no Epic Games Launcher and no sign-in. They're only for education institutions and organisations with paid Unreal seats, so CBR has to ask for them once:

1. A member of staff (Epic asks that students don't) fills in Epic's [UE EDU Offline Installer Request Form](https://forms.unrealengine.com/s/edu-offline-request), also linked from Epic's [Students & Schools](https://www.unrealengine.com/students-and-schools) page. Ask for RealityScan as well: a reply on Epic's forum says the same request covers its offline installer.
2. Once Epic approves it, sign in to the [Epic Developer Portal](https://dev.epicgames.com/portal) and pick the CBR organisation. Unreal is under **Unreal Engine > Downloads**, with Type set to **Unreal Engine Offline Installer**. Download 5.6, and RealityScan from its downloads page there.
3. Put the files, as downloaded, in `C:\CBR\installers` on JOHN and run provisioning. Unreal arrives as a .zip with an .msi inside; provisioning unpacks it. Copy the SHA-256 it prints into the manifest. If a file shows up under "Installer files that no app in the manifest uses", tell me its name so I can fix the pattern.
4. For the other machines, plug the install stick into JOHN and run `bootstrap.bat` → **Make or refresh the install USB stick**. It copies these installers onto the stick, and machines set up from it use them from there. The hash check makes sure each copy is the tested one. (Or copy them over the network, into `C:\CBR\installers` on the other machine: `scp -r "cbradmin@CBR-JOHN:C:/CBR/installers" C:/CBR/`.)

Unreal's install options are its `Args` in the manifest: it goes to `C:\Program Files\Epic Games\UE_5.6` (where the launcher puts it too), without debug symbols (tens of GB) or the iOS, tvOS, Linux and HoloLens targets, and with Android for Quest. Epic doesn't document RealityScan's installer options: if it's an .msi it installs silently anyway; if it's an .exe it opens for you to click through.

Until then, provisioning lists both as problems and says to install them from the Epic Games Launcher, signed in with the CBR Epic account. The audit detects them however they were installed.

The Unreal installer is big. Once every machine has it installed, you can delete it from `C:\CBR\installers`: provisioning only needs it again to reinstall.

## Hashes

When a file has no `Sha256` in the manifest yet, provisioning prints its hash. Copy that into the manifest once you've tested the installer. From then on a damaged or different file is refused instead of installed.

To get one yourself: `Get-FileHash <file>`.

## How each file is matched

Each app has an `Installer` name pattern, such as `TouchDesigner*` or `*-nsd-*` (the NVIDIA Studio driver; Game Ready drivers don't have `-nsd-`). `.zip` and `.iso` files are unpacked or mounted and the installer inside is run. Files that no pattern matches are listed at the end of provisioning, so a vendor's unexpected file name shows up straight away.

## Updating one

1. Change `Url` (or download the new file by hand), test it on JOHN, then update `Version` and `Sha256` in the manifest.
2. Commit and push, then run `scripts\update.ps1` on each machine.
