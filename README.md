# cbr-beatles

Build and maintenance scripts for the four CBR RTX 5090 workstations: **JOHN, PAUL, GEORGE and RINGO**.

The idea: what a CBR workstation *is* lives in [`manifest.psd1`](manifest.psd1). The scripts make a machine match it and report when it doesn't. Nobody installs or updates software on these machines by hand, apart from Unreal and RealityScan until Epic's offline installers for them arrive (see [installers/README.md](installers/README.md#unreal-engine-and-realityscan)).

## Start here

On any Windows PC, open PowerShell (right-click Start → Terminal) and run:

```powershell
irm https://raw.githubusercontent.com/oliverb-cbr/cbr-beatles/HEAD/go.ps1 | iex
```

It asks for administrator rights, gets the latest scripts and shows a menu: make the install USB stick, set up this PC as one of the four, update it or check it. It only offers what's safe on the PC it's on. Running `bootstrap.bat` (also on the install stick) does the same. No GitHub sign-in is needed while the repo is public.

## Passwords and accounts

| Account | Password | Notes |
|---|---|---|
| `cbradmin` (local admin) | `ChangeMe-CBR1` for the first sign-in only. Windows makes you choose a real one at the second sign-in. | The temporary password is in the answer file, and so in this public repo: treat it as public and change it straight away. Use the same real password on all four, and keep it in a password manager, never in this repo. |
| `CBR` (staff drop-in) | You choose it during setup; it's asked for twice so a typo can't lock staff out. | Standard user, no admin rights. Use the same one on all four. |
| `CBRSession` (sessions) | You choose it during setup, twice, as above. | Standard user you sign in for people during a session, then wipe from **Accounts** (see [Accounts](#accounts)). Use the same one on all four. |
| Personal accounts | A starter password that **Accounts** makes when you add the person, like `Cbr-7kq2-x9mp`. | Windows makes them choose their own at their first sign-in. |
| `cbr` inside Ubuntu (WSL) | None | Passwordless `sudo` inside Ubuntu only; it gives no rights on Windows. |
| Epic, Unity, Meta | Each person's own | Nothing shared is signed in on the PCs. Steam isn't installed ([why](#deliberate-trade-offs)). |
| GitHub | None | Not needed while the repo is public. |

Windows passwords on these PCs don't expire. Accounts end by their end date instead.

## What you'll be asked to do

Everything else is automatic. Full walkthrough with checkboxes: [docs/build-checklist.md](docs/build-checklist.md).

**Making the install USB stick** (on your own PC, once):

1. Run the command above and choose **Make or refresh the install USB stick**.
2. Type the stick's disk number. Only USB drives of 260 GB or less are listed, so a big external drive can't be picked.
3. If the stick hasn't got Ventoy yet, type `ERASE` at the red warning. A stick with Ventoy keeps what's on it.

It finds and checks the Windows ISO itself (or asks you to pick it), then copies and checks everything.

**On each workstation:**

1. **Boot from the stick.** The first time on each PC, a blue screen says *Verification failed: (0x1A) Security Violation*. That's Ventoy asking you to trust its key, once per PC; no BIOS change is needed. Use the arrow keys and Enter:
   1. **OK**, then press a key straight away at *Press any key to perform MOK management* (missed it? restart and boot the stick again).
   2. **Enroll key from disk** → **VTOYEFI** → **ENROLL_THIS_KEY_IN_MOKMANAGER.cer** → **Continue** → **Yes** → **Reboot**. If there's a second `.cer` file, enrol that too.
   3. Boot the stick again. If the blue screen keeps coming back, turn on "Allow Microsoft 3rd Party UEFI CA" in the BIOS.
2. **Ventoy menu:** pick the Windows ISO, then choose the **CBR template** when asked.
3. **Windows Setup** only asks which disk. Unplug other drives first, choose the internal SSD and delete its old partitions.
4. **Sign in as `cbradmin` / `ChangeMe-CBR1`.** Run **Check for updates** until nothing's left. At the next sign-in Windows asks for the real `cbradmin` password.
5. **Run the command above** (or `bootstrap.bat` on the stick). Choose **Set up this PC**, type its name (JOHN, PAUL, GEORGE or RINGO), then type it again to confirm. It warns first if another PC on the network already has that name, or C: is short of space.
6. **Choose the `CBR` and `CBRSession` passwords** (each twice).
7. **Click through the installers that open on their own**, keeping the defaults: Insta360 Studio, Insta360 Stitcher, LCC Studio, LCC Editor, LCC Model Editor and Meta Quest Developer Hub. Close any app that starts afterwards.
8. **Restart when asked** (press Enter). Sign in as `cbradmin` again: setup carries on by itself in a window, restarting again if it needs to. It finishes with *CBR-JOHN is set up*; anything listed under *Problems* still needs sorting.
9. **Sign out and sign in as `CBR` to check it.** The desktop should have the app folders, a **Work** folder and the *How to use this PC* note, which opens by itself the first time. Ubuntu and Docker aren't set up for anyone automatically: whoever needs them runs **Code > Set up Ubuntu & Docker** once (10 to 20 minutes).
10. **Add people** as `cbradmin`: run the command again and choose **Accounts**.

No internet on a new PC? Windows may have no driver for its network port: unzip the motherboard maker's network driver into `cbr-deploy\drivers` on the stick, then double-click `bootstrap.bat` on the stick (the one-line command needs internet to start). It installs the driver first.

## How it fits together

| Layer | What | Where it's defined |
|---|---|---|
| Windows install | Windows 11 Pro, UK settings, local `cbradmin`, no Microsoft account | `windows/autounattend.xml` |
| Windows settings | Hostname, accounts, disk limits, power, update policy, debloat, privacy, OpenSSH, what runs in the background | `scripts/provision.ps1`, `Settings` in the manifest |
| Apps | 35 apps via winget, vendor installers and Unity Hub | `manifest.psd1` |
| Desktop | App shortcuts in folders on every account's desktop and under **CBR** in the Start menu, plus the *How to use this PC* note | `Shortcut` per app in the manifest, `config/how-to-use-this-pc.html` |
| Linux / AI | WSL2 Ubuntu 24.04 + Docker Engine + NVIDIA container toolkit + uv, per person, when they ask for it | `scripts/user-setup.ps1`, `wsl/setup-docker.sh` |
| Installers | Vendor installers: downloaded from the vendor where the link is stable, otherwise put in `C:\CBR\installers` by hand; all checked against a SHA-256 or the vendor's signature | `Url`, `Sha256`, `Signer` per app in the manifest |

To change what's in the desktop folders, edit the `Shortcut` lines in the manifest; to change the note, edit `config/how-to-use-this-pc.html`. Then run **Update this PC** (or `fleet.ps1 -Action Update`). Don't edit either on a PC: the next update puts them back.

## Accounts

Accounts are local: each one is on one PC only, with its files on that PC.

| Account | Who | Disk: warning / limit | OneDrive app |
|---|---|---|---|
| `cbradmin` | You, for setup and updates | No limit | Not used |
| `CBR` | Staff dropping in. Shared, so nothing personal stays signed in | 300 / 500 GB | Blocked: use OneDrive in the browser |
| `CBRSession` | Sessions you run: sign it in for people, wipe it afterwards | 100 / 150 GB | Blocked: use OneDrive in the browser |
| Personal | One person, on one PC, for a while | 250 / 400 GB | Yes, university accounts only |

Every account except `cbradmin` gets, at each sign-in, a **Work** folder on its desktop and in Explorer's sidebar: the place to keep work in progress, on the fast drive. The first time, the *How to use this PC* note opens, and an account with an end date is told when it ends. When an account is over its warning level, a message says so at sign-in. At the limit, Windows refuses to save more.

On personal accounts, OneDrive downloads files only when they're opened, frees the local copy of anything not opened for 7 days, accepts only Falmouth accounts, and doesn't move Desktop or Documents into OneDrive.

**Managing them:** run the command above as `cbradmin` (or `bootstrap.bat`) and choose **Accounts**. It shows every account on this PC: when it was made, last sign-in, end date, space used against its limit, whether anyone's signed in to it and whether it has Ubuntu. It also shows the free space on C:. Then:

| Key | Does |
|---|---|
| **A** | Add a person: a username (like `jsmith`), their name and an optional end date. It shows a starter password to give them; they choose their own at their first sign-in. |
| **E** | Change an end date, or remove it. After the end date Windows won't let them sign in; their files stay until you remove the account. |
| **R** | Remove an account and all its files, once you've typed its name to confirm. Not while it's signed in. |
| **S** | Reset `CBRSession`: deletes its files, browser history and app sign-ins. It offers to sign it out first if it's in use. The next sign-in starts fresh, with the desktop folders and the note. |
| **B** | The biggest folders in an account, for when someone's near their limit. |
| **C** | Save the table as a CSV in `C:\CBR\logs`, for the accounts spreadsheet. |

From any one of the four, `fleet.ps1 -Action Accounts` shows the accounts on all four PCs in one table and saves it as one CSV. `fleet.ps1 -Action ResetSession` resets `CBRSession` on all four; it skips a PC where `CBRSession` is in use.

## Scripts

| Script | Run as | Does |
|---|---|---|
| `bootstrap.bat` | anyone (asks for admin) | **The one to run.** Gets the latest repo into `C:\CBR\cbr-beatles`, then shows a menu: make the install USB stick, set up this PC, update it or check it. Only offers what's safe on the PC it's on. |
| `scripts/start.ps1` | (via `bootstrap.bat`) | The menu. Setting up carries on by itself after each restart when `cbradmin` signs in. |
| `scripts/make-usb.ps1` | (via `bootstrap.bat`) | Makes or refreshes the install USB stick: Ventoy, the checked Windows ISO, the answer file. |
| `scripts/provision.ps1` | admin | Builds or re-converges a machine. Safe to re-run. |
| `scripts/update.ps1` | admin | `git pull`, then provision with `-Upgrade` (upgrades `current` apps, moves pinned apps to the manifest version). |
| `scripts/audit.ps1` | anyone | Read-only report of anything missing or at the wrong version. |
| `scripts/accounts.ps1` | admin (via `bootstrap.bat` → **Accounts**) | The accounts table and the add, end date, remove and session reset options above. |
| `scripts/fleet.ps1` | admin, from any machine | Over SSH on all four: audits them side by side with drift marked (default), updates them (`-Action Update`), lists every account (`-Action Accounts`) or resets the session account (`-Action ResetSession`). |
| `scripts/user-setup.ps1` | the person who wants it | WSL Ubuntu, Docker, GPU in containers, uv, for one account. Started from **Code > Set up Ubuntu & Docker** on the desktop. |
| `scripts/sign-in.ps1` | each person, at every sign-in (hidden) | The Work folder, tidying installers' desktop shortcuts, and the first-time note and end date message. |
| `scripts/usage-check.ps1` | SYSTEM, at every sign-in | The message when someone's over their disk space warning level. |
| `scripts/find-app.ps1` | anyone | Lists installed apps matching a pattern, for writing `Detect` patterns. |

Run them with `powershell -ExecutionPolicy Bypass -File <script>`.

## Version policy

- **current**: browsers, utilities, Git, VS Code, OneDrive etc. `update.ps1` keeps them up to date.
- **pinned**: Blender, TouchDesigner, Unreal 5.6, Unity, RealityScan, NVIDIA driver, OBS, Processing, CloudCompare and the hardware tools. All four machines must have the same version.

To roll out a new pinned version: install and test it on JOHN, change `Version` in the manifest, commit, push, then `fleet.ps1 -Action Update`.

The pinned versions in the manifest are the ones installed and checked in the VM test. A pinned app with `Version = $null` installs the latest and shows as `UNPINNED` in the audit until you copy its installed version into the manifest.

## Building the machines

See [docs/build-checklist.md](docs/build-checklist.md). In short: run `bootstrap.bat` on your own PC to make the install USB stick, install Windows on JOHN from it, run `bootstrap.bat` from the stick to set JOHN up, test it with real projects and record versions, then repeat on PAUL, GEORGE and RINGO.

## Deliberate trade-offs

Places where the build gives up a little safety or convenience on purpose. If one causes trouble, this is the list to check, and most are one setting in the manifest.

- **Defender doesn't scan the Work folders, or Unreal's and Unity's caches, as files are written** (`Settings.DefenderExclusions`). Engines, shader compiles and scan processing write tens of thousands of small files, and scanning each one makes builds and imports much slower. The cost: something harmful saved into Work isn't caught when it's saved. Everything else is scanned as normal, including programs when they start. To undo it, take the entry out of the manifest and run **Update this PC**.
- **Switch user is hidden.** One person is signed in at a time, so there's never a second person's jobs and open files sitting in the background, and the disk space message and session reset reach the right person. The cost: a locked PC can only be unlocked by whoever locked it. If someone leaves one locked without booking it, restarting it from the lock screen's power button signs them out, losing their unsaved work.
- **Steam isn't installed.** Steam is one installation for the whole PC, and doesn't keep its remembered sign-ins and settings apart between Windows accounts, so one person's sign-in could be offered to the next. If one PC needs it, install it by hand as `cbradmin` and tell people to choose *Don't save account credentials on this computer* when they sign in. **S** in Accounts also clears Steam's remembered sign-ins, if it's there. Steam is already on the list of things kept from starting with Windows.
- **Disk limits are hard limits.** At the limit, saving fails, and some apps only say "disk full" or give a less clear error. The warning at sign-in comes well before that. If hard limits cause more trouble than they save, set `Settings.QuotaMode = 'Warn'` and update: the warnings and the Accounts table stay, and nothing is blocked. The limits add up to more than the 1.86 TB drive if there are lots of accounts, so keep an eye on the free space the Accounts table shows; it warns under 200 GB.
- **The OneDrive app is only for personal accounts.** On `CBR` or `CBRSession` it would leave one person's OneDrive signed in for the next. Storage Sense is turned on so OneDrive can free space, which also means Windows' usual clean-up runs: temporary files, and Recycle Bin items older than 30 days.
- **The Public folders are read-only, and `C:\CBR\logs` and `C:\CBR\installers` are admin-only.** Nobody can leave files in Public Documents for others to find or change, or change the shared desktop; the logs hold account names and sign-in times. If an app turns out to need to write to a Public folder (some licence managers do), that one folder needs opening up in `provision.ps1`.
- **Windows passwords don't expire.** A forced change on a shared account locks out whoever doesn't hear the new one. Personal accounts end by their end date instead.
- **The NVIDIA App is removed** after the driver installs. It updates the driver by itself, and the driver version is pinned so all four match. Driver updates go through the manifest like everything else.
- **The Waves audio service doesn't start with Windows** (`WavesSvc`, the motherboard's audio tray app). On some boards it handles the front headphone socket; if the front or back sockets stop working, take `WavesSvc` out of `Settings.StartupOff` and update.
- **Other things kept from running in the background:** Steam, the Epic Games Launcher and Insta360 Studio's QuickLook helper at sign-in, Edge's startup boost, browsers carrying on after they're closed, Firefox's default browser agent and Windows' SoftLanding tips. Each still works when opened. The audit lists anything else that starts at sign-in.
- **Ubuntu and Docker are per person, and only for those who ask.** Each copy takes 15 minutes and several GB of that person's space, and most people won't need it.

## Not done yet / decided against for now

- VHDX and Ventoy multi-boot: parked.
- A recovery image: capture one (after Sysprep) once JOHN is proven.
- Deep Freeze: add later if staff changes become a problem.
- Kinect v2 SDK: left out (no hardware).
- Older CUDA work goes on the eGPU with the 3090, not the 5090s.
