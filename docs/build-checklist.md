# Build walkthrough

The whole process, start to finish. Five phases:

1. **Prep**: gather everything once, and make the install USB stick on your own PC.
2. **Test in a VM**: shake the bugs out of the scripts where mistakes cost nothing.
3. **Build JOHN**: the reference machine, tested with real work.
4. **Build PAUL, GEORGE and RINGO**: repeat, faster.
5. **After**: remote management, routine updates.

Don't skip phase 2. Most of the early problems will be script bugs, and a VM checkpoint undoes them in seconds.

**One file does everything: `bootstrap.bat`.** On any Windows PC it gets the latest scripts from GitHub, then shows a menu of what makes sense there:

| Where you run it | What it offers |
|---|---|
| Your own PC | Make or refresh the install USB stick. Nothing else, so it can't change your PC by mistake. |
| A PC just installed from the stick | Set it up as JOHN, PAUL, GEORGE or RINGO, or make the stick |
| A CBR workstation | Update it, check it, or refresh the stick |

Start it with one command in PowerShell (right-click Start → Terminal). It needs no GitHub sign-in:

```powershell
irm https://raw.githubusercontent.com/oliverb-cbr/cbr-beatles/HEAD/go.ps1 | iex
```

Or double-click `bootstrap.bat` on the install stick; it's the same thing. If Windows says it "protected your PC", choose More info → Run anyway.

---

## Phase 1: Prep

Do all of this on your own PC before touching the workstations.

### The Windows ISO

- [ ] Download the Windows 11 **English International** x64 ISO from [Microsoft](https://www.microsoft.com/software-download/windows11). The tested one is named in `Settings.WindowsIso` in the manifest, with its SHA-256; the stick script refuses anything else unless you say otherwise.

### The install USB stick

- [ ] Plug in the stick (128 GB is plenty) and run the command above. Choose **Make or refresh the install USB stick**.
  - It only offers USB drives of 260 GB or less, so a big external drive can't be picked by mistake.
  - A stick without Ventoy is erased once you type `ERASE`. A stick that has Ventoy already keeps everything on it.
  - It finds the ISO in Downloads (or asks you to pick it), checks it, copies it, then checks the copy.
  - It also adds the answer file, Ventoy's settings and `bootstrap.bat` itself.

The repo ends up in `C:\CBR\cbr-beatles` on your PC too, which the VM steps below use.

### Vendor installers

Provisioning downloads almost every vendor installer itself from the links in the manifest and checks each against the SHA-256 recorded there before running it (see [installers/README.md](../installers/README.md)). Unity Hub downloads the Unity Editor.

- [ ] **Start this now, as Epic takes a while:** ask Epic for the Unreal Engine and RealityScan offline installers through its education request form. Details in [installers/README.md](../installers/README.md#unreal-engine-and-realityscan). Without them, those two are installed from the Epic Games Launcher by hand.

### Accounts and keys

- [ ] A CBR Epic Games account, signed up with a CBR email address, for installing Unreal and RealityScan from the launcher if Epic's offline installers haven't arrived. Nothing else is shared: people sign in to Epic, Unity and Meta with their own accounts.
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

Hyper-V VMs can't boot from a USB stick, so the VM gets the ISO and a small second disc with the answer file instead.

1. In an admin PowerShell on the host, make that second disc. It writes `C:\CBR\cbr-beatles\windows\cbr-answer.iso`:
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\CBR\cbr-beatles\windows\make-answer-iso.ps1
   ```
2. Adjust the paths and run:
   ```powershell
   $name   = 'CBR-Test'
   $iso    = "$HOME\Downloads\Windows11_Client_x64_en-gb_26300_9457.iso"
   $answer = 'C:\CBR\cbr-beatles\windows\cbr-answer.iso'
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

1. In the VM, signed in as `cbradmin`, run the command above in PowerShell. Choose **Set up this PC**, then `JOHN`, and type `JOHN` to confirm.
2. It asks for passwords for the `CBR` and `CBRSession` accounts (each twice), then installs everything. Click through the installers that open on their own.
3. When it asks, press Enter to restart. Sign in as `cbradmin` again: setup carries on by itself in a window and says when it's finished.
4. Sign out and sign in as `CBR`. The desktop has the app folders and a Work folder, and the *How to use this PC* note opens. Run **Code > Set up Ubuntu & Docker** from the desktop to test that too.

**Expected to fail in the VM**, so ignore these: the NVIDIA driver (no NVIDIA GPU), Unreal and RealityScan (until Epic's offline installers are in `C:\CBR\installers`), and the final GPU check in the Ubuntu setup.

**Everything else should work**: Windows settings, debloat, the WinGet apps and vendor installers, the Unity Editor (a long download through Unity Hub), WSL and Docker, and the audit.

### The fix loop

When something fails, send me the error (the full log is in `C:\CBR\logs\`). I fix the script and push. Then go back to the checkpoint and run it again:

```powershell
Restore-VMCheckpoint -VMName CBR-Test -Name 'clean base' -Confirm:$false
```

**Done when:** setup runs to the end with no help from you except the prompts above, and running `bootstrap.bat` again → **Check this PC** shows OK for everything except the hardware items above. Then shut the VM down for good before building the real JOHN; setup warns if it finds another PC already called CBR-JOHN on the network.

---

## Phase 3: Build JOHN

### Firmware

- [ ] Update the BIOS. Record the version: `____`
- [ ] Turn on: virtualisation (Intel VT-x / AMD SVM), IOMMU (VT-d / AMD-Vi), Resizable BAR, Secure Boot, TPM. If the stick won't boot with Secure Boot on, also turn on "Allow Microsoft 3rd Party UEFI CA" (some boards have it).
- [ ] Note any other setting you change, so the other three match: `____`

### Windows

- [ ] **Unplug every external drive except the install USB.**
- [ ] Boot from the stick. **The first time on each PC**, a blue screen says *Verification failed: (0x1A) Security Violation*. That's Ventoy asking you to trust its key, once per PC; leave Secure Boot on. With the arrow keys and Enter:
  1. **OK**, then press a key straight away at *Press any key to perform MOK management* (missed it? restart and boot the stick again).
  2. **Enroll key from disk** → **VTOYEFI** → **ENROLL_THIS_KEY_IN_MOKMANAGER.cer** → **Continue** → **Yes** → **Reboot**. If there's a second `.cer` file, enrol that too.
  3. Boot the stick again: the Ventoy menu appears. If the blue screen keeps coming back, turn on "Allow Microsoft 3rd Party UEFI CA" in the firmware.
- [ ] Pick the Windows ISO, and choose the CBR template when Ventoy asks.
- [ ] When Setup asks for a disk, choose the internal SSD and delete its old partitions.
- [ ] Sign in as `cbradmin` / `ChangeMe-CBR1`. Run **Check for updates** until nothing's left. Set the real `cbradmin` password when asked (use the same one on all four).
- [ ] No internet? Windows may have no driver for the network port. Unzip the motherboard maker's network driver into `cbr-deploy\drivers` on the stick; `bootstrap.bat` installs it before anything else.

### Safety image

- [ ] Take a full disk image onto the install USB with Veeam Agent for Windows (free). Call it `JOHN-base`. A fresh Windows image is about 20 to 30 GB, so it fits alongside everything else. If anything below goes badly, restoring it takes 10 to 20 minutes. (Ventoy sticks are formatted exFAT; if Veeam won't save there, skip the image. Reinstalling Windows from the USB is the fallback, just slower.)

### Set up

- [ ] Run `bootstrap.bat` from the stick. Choose **Set up this PC**, then `JOHN`. Choose the `CBR` and `CBRSession` passwords and click through the installers that open on their own (Insta360, the three LCC tools, MQDH).
- [ ] Restart when asked and sign in as `cbradmin`: setup carries on and says when it's done.
- [ ] Sign out and sign in as `CBR`: the note opens, and the desktop has the app folders and Work.
- [ ] Still as `CBR`, run **Code > Set up Ubuntu & Docker**. It should finish by showing the RTX 5090 from inside a Docker container.

### Unreal, RealityScan and Unity

- [ ] Unity: nothing to do. Provisioning installs the editor version in the manifest through Unity Hub.
- [ ] Unreal and RealityScan: if Epic's offline installers are in `C:\CBR\installers`, provisioning installed them; copy the SHA-256s it printed into the manifest. If not, install both from the Epic Games Launcher, signed in as the CBR Epic account, into the default folders.
- [ ] Run `bootstrap.bat` → **Check this PC**. For any app showing MISSING that is installed, find its real name with `scripts\find-app.ps1 '*name*'` and tell me, so I can fix its `Detect` pattern.

### Test with real work

- [ ] Blender GPU render, TouchDesigner project, Unreal 5.6 project (including a C++ build), Unity build.
- [ ] Insta360 stitch, LCC Studio and the LCC editors, VIVE Mars tracking, Quest through MQDH and SideQuest.
- [ ] A PyTorch container using the GPU in WSL.

### Test the accounts and lock-downs

These are new and have only been checked on paper, so try each one on JOHN before building the others. Tell me what doesn't behave as described.

- [ ] **Check this PC** shows OK for: Switch user hidden, Public folders read-only, Logs admin-only, Disk limits, OneDrive (personal accounts only), Defender exclusions, Nothing unexpected in the background, Unwanted programs absent, Desktop folders complete. For *Desktop folders complete*, send me any names it says are missing.
- [ ] **Desktop folders:** as `CBR`, open each folder and start a few apps from it, including GitHub Desktop and Ubuntu. No loose app shortcuts on the desktop, apart from the note and Work.
- [ ] **A test person:** `bootstrap.bat` → **Accounts** → **A**, username `test1`, end date tomorrow. Sign in as `test1` with the starter password: Windows asks for a new one, the note opens, a message gives the end date, and Work is on the desktop and in Explorer's sidebar.
- [ ] **OneDrive:** as `test1`, OneDrive starts and accepts a Falmouth sign-in, and refuses a personal Microsoft account. A big file in OneDrive shows a cloud icon until it's opened. As `CBR`, OneDrive doesn't start and can't be opened.
- [ ] **Lock-downs:** as `CBR`, saving a file into `C:\Users\Public\Documents` is refused, and opening `C:\CBR\logs` is refused.
- [ ] **Disk limits:** as `cbradmin`, give `test1` a tiny allowance: `fsutil quota modify C: 1073741824 2147483648 test1` (1 GB warning, 2 GB limit). As `test1`, copy 1.5 GB into Work, sign out and in again: a message about disk space appears within a couple of minutes. Copying another 1 GB should fail. The Accounts table shows the space used.
- [ ] **Background:** as `CBR`, Task Manager → Startup apps shows only Windows Security, Everything and Realtek audio as enabled (plus OneDrive for `test1`). Steam isn't installed.
- [ ] **Audio:** with the Waves service off, headphones work in both the front and back sockets, and a mic works.
- [ ] **NVIDIA App:** gone from Settings → Apps; the driver is still installed (Check this PC shows its version).
- [ ] **Session reset:** sign in as `CBRSession`, sign in to a website, save a file in Work, sign out. **Accounts** → **S**. Sign in as `CBRSession` again: no file, no website sign-in, and the note opens as for a new account.
- [ ] **Remove:** **Accounts** → **R** → `test1`. It disappears from the table and `C:\Users\test1` is gone.
- [ ] **CSV:** **Accounts** → **C** saves a file in `C:\CBR\logs` that opens in Excel.

### Lock in versions

- [ ] Run **Check this PC**. Every pinned app showing `UNPINNED` lists its installed version. Copy those versions into `Version` in `manifest.psd1`, commit and push.
- [ ] Run `bootstrap.bat` → **Update this PC**. The check should now be all OK.

### Refresh the stick

- [ ] With the stick plugged into JOHN, run `bootstrap.bat` → **Make or refresh the install USB stick**. It keeps what's there, and adds the Unreal and RealityScan installers from `C:\CBR\installers`, so the other three install them without downloading.

---

## Phase 4: Build PAUL, GEORGE and RINGO

For each machine, follow phase 3 with its own name:

- [ ] Firmware: same BIOS version and settings as JOHN.
- [ ] Windows from the stick, then **Check for updates**.
- [ ] `bootstrap.bat` from the stick → **Set up this PC** → its name. Restart when asked, sign in as `cbradmin`, then check the desktop as `CBR`.
- [ ] Unreal and RealityScan come off the stick if JOHN refreshed it with Epic's offline installers. Without those: either let the Epic launcher download Unreal (50+ GB), or copy it from JOHN, then in the Epic launcher choose Install and point it at the copied folder so it checks the files instead of downloading:
  ```powershell
  scp -r "cbradmin@CBR-JOHN:C:/Program Files/Epic Games/UE_5.6" "C:/Program Files/Epic Games/"
  ```
- [ ] A quick smoke test: open one project in each of the main apps.

Install Windows on these from the USB as for JOHN. **Don't restore JOHN's image onto them**: copying one machine's Windows onto another causes duplicate identities and activation problems.

Then, from JOHN, compare all four:

```powershell
C:\CBR\cbr-beatles\scripts\fleet.ps1
```

Every row should match across the four machines. Rows marked `<<` differ.

---

## Phase 5: After

- [ ] **People**: add them with `bootstrap.bat` → **Accounts** on the PC they'll use. Every so often, `fleet.ps1 -Action Accounts` saves one CSV of every account on all four for the spreadsheet; remove accounts that have ended.
- [ ] **After a session**: `fleet.ps1 -Action ResetSession` wipes `CBRSession` on all four (or **Accounts** → **S** at each PC).
- [ ] **Remote updates**: once the repo is public, `fleet.ps1 -Action Update` works over SSH as it is. While it's private, add a read-only deploy key on GitHub (Settings → Deploy keys) and switch each machine's copy of the repo to `git@github.com:oliverb-cbr/cbr-beatles.git`; until then, updates have to be run at each machine, because updates over SSH can't use the browser sign-in `bootstrap.bat` saves.
- [ ] **Routine**: every few weeks, run `fleet.ps1` to check for drift and `fleet.ps1 -Action Update` (or `bootstrap.bat` → **Update this PC** at each machine) to update apps. Windows updates itself.
- [ ] **New version of a pinned app**: test it on JOHN, change `Version` in the manifest, commit, push, update the rest.
- [ ] **NAS**: if one arrives, copy `cbr-deploy\installers` onto it and set `Settings.InstallerRoot` to the share's full path, e.g. `\\CBR-NAS\cbr-deploy\installers`.
- [ ] **Deep Freeze**: add it if staff changes start causing problems.
