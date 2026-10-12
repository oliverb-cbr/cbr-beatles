# Build walkthrough

The whole process, start to finish. Five phases:

1. **Prep**: gather everything once, on your own PC.
2. **Test in a VM**: shake the bugs out of the scripts where mistakes cost nothing.
3. **Build JOHN**: the reference machine, tested with real work.
4. **Build PAUL, GEORGE and RINGO**: repeat, faster.
5. **After**: remote management, routine updates.

Don't skip phase 2. Most of the early problems will be script bugs, and a VM checkpoint undoes them in seconds.

---

## Phase 1: Prep

Do all of this on your own PC before touching the workstations.

### The Windows ISO

- [ ] Download the Windows 11 26H2 **English International** x64 ISO from Microsoft's download page.
- [ ] Check its SHA-256 against Microsoft's list ("Verify your download" on the same page):
  ```powershell
  Get-FileHash .\<iso file>
  ```
- [ ] Mount it (double-click) and check it has Pro in UK English. `E:` is whatever letter the ISO mounts as:
  ```powershell
  dism /Get-WimInfo /WimFile:E:\sources\install.wim            # note the index for Windows 11 Pro
  dism /Get-WimInfo /WimFile:E:\sources\install.wim /Index:6   # use that index; Languages: en-GB
  ```

### The install USB

Full details in [windows/README.md](../windows/README.md). With Ventoy:

- [ ] Put the ISO in `ISO\Windows11\` on the Ventoy drive.
- [ ] Copy `windows\autounattend.xml` to `ventoy\script\cbr-autounattend.xml` on the Ventoy drive.
- [ ] Copy `windows\ventoy.json` to `ventoy\ventoy.json` (merge if you already have one).
- [ ] Also copy `bootstrap.bat` onto the stick, so it's to hand on each machine.

### Vendor installers

Provisioning downloads almost every vendor installer itself from the links in the manifest and checks each against the SHA-256 recorded there before running it (see [installers/README.md](../installers/README.md)). Unity Hub downloads the Unity Editor.

- [ ] **Start this now, as Epic takes a while:** ask Epic for the Unreal Engine and RealityScan offline installers through its education request form. Details in [installers/README.md](../installers/README.md#unreal-engine-and-realityscan). Without them, those two are installed from the Epic Games Launcher by hand.

### Accounts and keys

- [ ] Shared CBR accounts, signed up with a CBR email address: Steam, Epic Games, Unity, Meta developer account.
- [ ] Any licences: Unity (Personal or Education), TouchDesigner (if commercial/educational keys).
- [ ] An SSH key for `fleet.ps1`, made on your own PC:
  ```powershell
  ssh-keygen -t ed25519 -f $HOME\.ssh\cbr_admin
  ```
  Put the contents of `cbr_admin.pub` (the public half only) into `config/ssh/administrators_authorized_keys` in this repo and commit it. Provisioning copies it onto each machine.

### Firmware

- [ ] Download the latest BIOS for the workstations' motherboard onto a USB stick.

---

## Phase 2: Test in a VM

On the PC where you turned on Hyper-V. If that PC is one of the four workstations, keep the VM on an external drive so it survives when that machine is reinstalled.

### Create the VM

1. Download this repo onto the host (GitHub → Code → Download ZIP is fine here), unzip it, and in PowerShell run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\windows\make-answer-iso.ps1
   ```
   It writes `windows\cbr-answer.iso`.
2. In an admin PowerShell, adjust the three paths and run:
   ```powershell
   $name   = 'CBR-Test'
   $iso    = 'D:\ISO\Win11_26H2_EnglishInternational_x64.iso'
   $answer = 'D:\cbr-beatles\windows\cbr-answer.iso'
   $dir    = 'D:\VMs'                                  # needs ~300 GB free

   New-VM -Name $name -Generation 2 -Path $dir -MemoryStartupBytes 16GB `
          -NewVHDPath "$dir\$name\$name.vhdx" -NewVHDSizeBytes 300GB -SwitchName 'Default Switch'
   Set-VMProcessor $name -Count 8 -ExposeVirtualizationExtensions $true   # lets WSL run inside the VM
   Set-VMMemory $name -DynamicMemoryEnabled $false                        # required for the line above
   Set-VM $name -CheckpointType Standard
   Set-VMKeyProtector $name -NewLocalKeyProtector
   Enable-VMTPM $name
   Add-VMDvdDrive $name -Path $iso
   Add-VMDvdDrive $name -Path $answer
   Set-VMFirmware $name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice (Get-VMDvdDrive $name)[0]
   Start-VM $name; vmconnect localhost $name
   ```
3. Press a key straight away at "Press any key to boot from CD or DVD". (Missed it? Restart the VM.)
4. Setup only asks which disk. Pick the VM's disk; everything else is automatic.
5. Sign in as `cbradmin` / `ChangeMe-CBR1`. Run **Check for updates** until nothing's left. Windows asks for a new password at the next sign-in.
6. Shut the VM down and take the checkpoint:
   ```powershell
   Checkpoint-VM -Name CBR-Test -SnapshotName 'clean base'
   ```

### Run the scripts

1. In the VM, open this repo on GitHub, open `bootstrap.bat`, use "Download raw file", and run `bootstrap.bat JOHN` from a command prompt in the download folder. If Windows says it "protected your PC", choose More info → Run anyway (it does that for any downloaded script). Sign in to GitHub when the browser asks.
2. It asks for a `CBR` staff password, renames the VM to CBR-JOHN, enables WSL, installs apps, then asks for a reboot. Reboot and run it again:
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\CBR\cbr-beatles\scripts\provision.ps1
   ```
3. Sign in as `CBR` and run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\CBR\cbr-beatles\scripts\user-setup.ps1
   ```

**Expected to fail in the VM**, so ignore these: the NVIDIA driver (no NVIDIA GPU), Unreal and RealityScan (until Epic's offline installers are in `C:\CBR\installers`), and the final GPU check in `user-setup.ps1`.

**Everything else should work**: Windows settings, debloat, the WinGet apps and vendor installers, the Unity Editor (a long download through Unity Hub), WSL and Docker, and the audit.

### The fix loop

When something fails, send me the error (the full log is in `C:\CBR\logs\`). I fix the script and push. Then go back to the checkpoint and run it again:

```powershell
Restore-VMCheckpoint -VMName CBR-Test -Name 'clean base' -Confirm:$false
```

**Done when:** provision runs to the end twice in a row, and the audit shows OK for everything except the hardware items above. Then shut the VM down for good before building the real JOHN, so two machines called CBR-JOHN aren't on the network at once.

---

## Phase 3: Build JOHN

### Firmware

- [ ] Update the BIOS. Record the version: `____`
- [ ] Turn on: virtualisation (Intel VT-x / AMD SVM), IOMMU (VT-d / AMD-Vi), Resizable BAR, Secure Boot, TPM.
- [ ] Note any other setting you change, so the other three match: `____`

### Windows

- [ ] **Unplug every external drive except the install USB.**
- [ ] Boot the Ventoy USB, pick the Windows ISO, and choose the CBR template when Ventoy asks.
- [ ] When Setup asks for a disk, choose the internal SSD and delete its old partitions.
- [ ] Sign in as `cbradmin` / `ChangeMe-CBR1`. Run **Check for updates** until nothing's left. Set the real `cbradmin` password when asked (use the same one on all four).
- [ ] Install chipset and network drivers from the motherboard vendor if Windows didn't find them.

### Safety image

- [ ] Take a full disk image onto the install USB with Veeam Agent for Windows (free). Call it `JOHN-base`. A fresh Windows image is about 20 to 30 GB, so it fits alongside everything else. If anything below goes badly, restoring it takes 10 to 20 minutes. (Ventoy sticks are formatted exFAT; if Veeam won't save there, skip the image. Reinstalling Windows from the USB is the fallback, just slower.)

### Provision

- [ ] Run `bootstrap.bat JOHN` from the USB stick. Click through the installers that open on their own (Insta360, the three LCC tools, MQDH).
- [ ] Reboot when asked, then run `provision.ps1` again (command in phase 2).

### Unreal, RealityScan and Unity

- [ ] Unity: nothing to do. Provisioning installs the editor version in the manifest through Unity Hub.
- [ ] Unreal and RealityScan: if Epic's offline installers are in `C:\CBR\installers`, provisioning installed them; copy the SHA-256s it printed into the manifest. If not, install both from the Epic Games Launcher, signed in as the CBR Epic account, into the default folders.
- [ ] Check every app is detected: run `scripts\audit.ps1`. For any showing MISSING that is installed, find its real name with `scripts\find-app.ps1 '*name*'` and tell me, so I can fix its `Detect` pattern.

### Staff account

- [ ] Sign in as `CBR` and run `user-setup.ps1`. It should finish by showing the RTX 5090 from inside a Docker container.
- [ ] Sign in to Steam, Epic, Unity Hub and Meta Quest Developer Hub with the shared CBR accounts.

### Test with real work

- [ ] Blender GPU render, TouchDesigner project, Unreal 5.6 project (including a C++ build), Unity build.
- [ ] Insta360 stitch, LCC Studio and the LCC editors, VIVE Mars tracking, Quest through MQDH and SideQuest.
- [ ] A PyTorch container using the GPU in WSL.

### Lock in versions

- [ ] Run `scripts\audit.ps1`. Every pinned app shows `UNPINNED` with its installed version. Copy those versions into `Version` in `manifest.psd1`, commit and push.
- [ ] Run `scripts\update.ps1`. The audit should now be all OK.

---

## Phase 4: Build PAUL, GEORGE and RINGO

For each machine, follow phase 3 with its own name (`bootstrap.bat PAUL` and so on):

- [ ] Firmware: same BIOS version and settings as JOHN.
- [ ] Windows, then **Check for updates**.
- [ ] `bootstrap.bat <NAME>`, reboot, provision again.
- [ ] Unreal and RealityScan, with Epic's offline installers: before the second provision run, copy them from JOHN (provisioning then installs them):
  ```powershell
  scp -r "cbradmin@CBR-JOHN:C:/CBR/installers" C:/CBR/
  ```
  Without them: either let the Epic launcher download Unreal (50+ GB), or copy it from JOHN, then in the Epic launcher choose Install and point it at the copied folder so it checks the files instead of downloading:
  ```powershell
  scp -r "cbradmin@CBR-JOHN:C:/Program Files/Epic Games/UE_5.6" "C:/Program Files/Epic Games/"
  ```
- [ ] Unity installs itself, as on JOHN.
- [ ] As `CBR`: `user-setup.ps1`, then sign in to the shared accounts.
- [ ] A quick smoke test: open one project in each of the main apps.

Install Windows on these from the USB as for JOHN. **Don't restore JOHN's image onto them**: copying one machine's Windows onto another causes duplicate identities and activation problems.

Then, from JOHN, compare all four:

```powershell
C:\CBR\cbr-beatles\scripts\fleet.ps1
```

Every row should match across the four machines. Rows marked `<<` differ.

---

## Phase 5: After

- [ ] **Remote updates**: add a read-only deploy key for this repo on GitHub (Settings → Deploy keys) and switch each machine's copy of the repo to `git@github.com:oliverb-cbr/cbr-beatles.git`. Until then, `fleet.ps1` can audit remotely but updates have to be run at each machine. (Updates over SSH can't use the browser sign-in that `bootstrap.bat` saves.)
- [ ] **Routine**: every few weeks, run `fleet.ps1` to check for drift and `fleet.ps1 -Action Update` (or `update.ps1` at each machine) to update apps. Windows updates itself.
- [ ] **New version of a pinned app**: test it on JOHN, change `Version` in the manifest, commit, push, update the rest.
- [ ] **NAS**: if one arrives, copy `cbr-deploy\installers` onto it and set `Settings.InstallerRoot` to the share's full path, e.g. `\\CBR-NAS\cbr-deploy\installers`.
- [ ] **Deep Freeze**: add it if staff changes start causing problems.
