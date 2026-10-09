# Build checklist

Do JOHN first and properly. It becomes the reference everything else is compared against.

## 0. Before touching a machine

- [ ] Choose the NVIDIA Studio driver version to start with.
- [ ] Put the vendor installers in the installer share, laid out as in [installers/README.md](../installers/README.md).
- [ ] Set `Settings.InstallerRoot` in `manifest.psd1` (a folder on the 20 TB drive is fine until the NAS exists).
- [ ] Make an SSH key for admin use and add its public half to `config/ssh/administrators_authorized_keys`.
- [ ] Later, once you want `fleet.ps1 -Action Update`: add a read-only **deploy key** for this repo on GitHub (Settings → Deploy keys) and switch each clone's remote to `git@github.com:oliverb-cbr/cbr-beatles.git`. Updates run over SSH can't use the browser sign-in that the first clone saves.

## 1. Firmware

- [ ] Update BIOS to the same version on all four. Note it here: `____`
- [ ] Enable virtualisation (Intel VT-x / AMD SVM), and IOMMU (VT-d / AMD-Vi).
- [ ] Resizable BAR on. Secure Boot and TPM on (Windows 11 needs them).
- [ ] Record any other settings you change so the other three match.

## 2. Windows

- [ ] Make the install USB with the answer file: see [windows/README.md](../windows/README.md) (Ventoy or Rufus, "English International" ISO).
- [ ] Unplug the external NVMe and 20 TB drive, boot the USB, and choose the internal SSD when Setup asks. Everything else is answered for you: Windows 11 Pro, UK settings, no Microsoft account, local admin `cbradmin` with password `ChangeMe-CBR1`.
- [ ] Sign in as `cbradmin`. At the next sign-in Windows makes you set a real password. Use the same one on all four.
- [ ] Run Windows Update until there's nothing left.
- [ ] Install chipset and network drivers from the motherboard vendor if Windows didn't get them.

## 3. Get the repo

Copy `bootstrap.bat` from this repo onto the machine: on a USB stick, or open it on GitHub while signed in and use "Download raw file". Log in as `cbradmin` and double-click it, or run `bootstrap.bat JOHN` to go straight on to provisioning.

It asks for admin rights, installs Git with winget (built into Windows 11), creates `C:\CBR` so only admins can change it, and downloads the repo to `C:\CBR\cbr-beatles`. The repo is private, so a browser window opens asking you to sign in to GitHub. Git remembers the sign-in for `cbradmin`, so `update.ps1` works when you run it at the machine. Running `bootstrap.bat` again just updates the repo.

The vendor installers aren't in the repo. Plug in the drive holding them (or connect to the NAS) and check `Settings.InstallerRoot` in the manifest points at it. External drives can get a different letter on each machine, so check it's the same letter everywhere, or set it in Disk Management.

## 4. Provision

If you didn't pass a machine name to `bootstrap.bat`:

```powershell
powershell -ExecutionPolicy Bypass -File C:\CBR\cbr-beatles\scripts\provision.ps1 -Machine JOHN
```

- Asks for a password for the `CBR` staff account the first time.
- Renames the machine and enables WSL, so it will ask for a reboot. Reboot and run it again (without `-Machine`).
- Apps without silent-install arguments (Insta360, LCC, VIVE Mars, MQDH) open their installers; click through them.
- At the end it prints the audit and any manual steps.

## 5. Manual installs

Sign in to the launchers as `cbradmin` to install, then as `CBR` for day-to-day use:

- [ ] Epic Games Launcher → Unreal Engine 5.6, RealityScan.
- [ ] Unity: set `Version` and `Changeset` in the manifest and re-run provision, or install through Unity Hub.
- [ ] Check every `Detect` pattern actually matches: `scripts\find-app.ps1 '*name*'`.

## 6. Staff account

Log in as `CBR`:

- [ ] `powershell -ExecutionPolicy Bypass -File C:\CBR\cbr-beatles\scripts\user-setup.ps1`. It should end with `nvidia-smi` listing the 5090 from inside a container.
- [ ] Sign in to Steam, Epic, Unity Hub, Meta Quest Developer Hub with the shared CBR accounts.

## 7. Test with real work

- [ ] A Blender render (GPU), a TouchDesigner project, a Resolve export, an Unreal 5.6 project (C++ build too), a Unity build.
- [ ] Insta360 stitch, LCC, VIVE Mars, Quest via MQDH and SideQuest.
- [ ] A PyTorch container on the GPU in WSL.

## 8. Lock in versions

- [ ] Run `scripts\audit.ps1`. Copy the installed version of each `UNPINNED` app into `Version` in the manifest.
- [ ] Commit and push. Run the audit again: everything should be `OK`.

## 9. PAUL, GEORGE, RINGO

Steps 1 to 6 on each, using `-Machine PAUL` etc. Then from JOHN:

```powershell
C:\CBR\cbr-beatles\scripts\fleet.ps1
```

Every row should be identical across the four machines.

## 10. Recovery image (later)

Once all four are stable, capture an image of JOHN after `sysprep /generalize` (Clonezilla or similar) and store it on the NAS. The scripts stay the source of truth; the image only gets a dead machine back to step 4 quickly.
