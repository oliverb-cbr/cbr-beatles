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
| `CBR` (staff) | You choose it during setup; it's asked for twice so a typo can't lock staff out. | Standard user, no admin rights. Use the same one on all four. |
| `cbr` inside Ubuntu (WSL) | None | Passwordless `sudo` inside Ubuntu only; it gives no rights on Windows. |
| Steam, Epic, Unity, Meta | The shared CBR accounts | Signed in by hand under `CBR` after setup. |
| GitHub | None | Not needed while the repo is public. |

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
6. **Choose the `CBR` password** (twice).
7. **Click through the installers that open on their own**, keeping the defaults: Insta360 Studio, Insta360 Stitcher, LCC Studio, LCC Editor, LCC Model Editor and Meta Quest Developer Hub. Close any app that starts afterwards.
8. **Restart when asked** (press Enter). Sign in as `cbradmin` again: setup carries on by itself in a window, restarting again if it needs to. It finishes with *CBR-JOHN is set up*; anything listed under *Problems* still needs sorting.
9. **Sign out and sign in as `CBR`.** Ubuntu, Docker and GPU support set themselves up in a window (10 to 20 minutes, once only). Leave it open.
10. **Still as `CBR`, sign in** to Steam, Epic Games, Unity Hub and Meta Quest Developer Hub with the shared CBR accounts.

No internet on a new PC? Windows may have no driver for its network port: unzip the motherboard maker's network driver into `cbr-deploy\drivers` on the stick, then double-click `bootstrap.bat` on the stick (the one-line command needs internet to start). It installs the driver first.

## How it fits together

| Layer | What | Where it's defined |
|---|---|---|
| Windows install | Windows 11 Pro, UK settings, local `cbradmin`, no Microsoft account | `windows/autounattend.xml` |
| Windows settings | Hostname, accounts, power, update policy, debloat, privacy, OpenSSH | `scripts/provision.ps1` |
| Apps | 35 apps via winget, vendor installers and Unity Hub | `manifest.psd1` |
| Linux / AI | WSL2 Ubuntu 24.04 + Docker Engine + NVIDIA container toolkit + uv | `scripts/user-setup.ps1`, `wsl/setup-docker.sh` |
| Installers | Vendor installers: downloaded from the vendor where the link is stable, otherwise put in `C:\CBR\installers` by hand; all checked against a SHA-256 | `Url`, `Sha256` per app in the manifest |

Accounts on every machine:

- **`cbradmin`**: local admin. Used only for provisioning and updates.
- **`CBR`**: standard user that staff log in with. Can't install software or change the scripts.
- Shared CBR accounts for Steam, Epic, Unity and Meta are signed in under `CBR`. OneDrive is removed.

## Scripts

| Script | Run as | Does |
|---|---|---|
| `bootstrap.bat` | anyone (asks for admin) | **The one to run.** Gets the latest repo into `C:\CBR\cbr-beatles`, then shows a menu: make the install USB stick, set up this PC, update it or check it. Only offers what's safe on the PC it's on. |
| `scripts/start.ps1` | (via `bootstrap.bat`) | The menu. Setting up carries on by itself after each restart when `cbradmin` signs in. |
| `scripts/make-usb.ps1` | (via `bootstrap.bat`) | Makes or refreshes the install USB stick: Ventoy, the checked Windows ISO, the answer file. |
| `scripts/provision.ps1` | admin | Builds or re-converges a machine. Safe to re-run. |
| `scripts/update.ps1` | admin | `git pull`, then provision with `-Upgrade` (upgrades `current` apps, moves pinned apps to the manifest version). |
| `scripts/audit.ps1` | anyone | Read-only report of anything missing or at the wrong version. |
| `scripts/fleet.ps1` | admin, from any machine | Audits (or updates) all four over SSH and shows a side-by-side grid with drift marked. |
| `scripts/user-setup.ps1` | `CBR` | One-off: WSL Ubuntu, Docker, GPU in containers, uv. Starts by itself the first time `CBR` signs in after setup. |
| `scripts/find-app.ps1` | anyone | Lists installed apps matching a pattern, for writing `Detect` patterns. |

Run them with `powershell -ExecutionPolicy Bypass -File <script>`.

## Version policy

- **current**: browsers, utilities, Git, VS Code, Steam etc. `update.ps1` keeps them up to date.
- **pinned**: Blender, TouchDesigner, Unreal 5.6, Unity, RealityScan, NVIDIA driver, OBS, Processing, CloudCompare and the hardware tools. All four machines must have the same version.

To roll out a new pinned version: install and test it on JOHN, change `Version` in the manifest, commit, push, then `fleet.ps1 -Action Update`.

The pinned versions in the manifest are the ones installed and checked in the VM test. A pinned app with `Version = $null` installs the latest and shows as `UNPINNED` in the audit until you copy its installed version into the manifest.

## Building the machines

See [docs/build-checklist.md](docs/build-checklist.md). In short: run `bootstrap.bat` on your own PC to make the install USB stick, install Windows on JOHN from it, run `bootstrap.bat` from the stick to set JOHN up, test it with real projects and record versions, then repeat on PAUL, GEORGE and RINGO.

## Not done yet / decided against for now

- VHDX and Ventoy multi-boot: parked.
- A recovery image: capture one (after Sysprep) once JOHN is proven.
- Deep Freeze: add later if staff changes become a problem.
- Kinect v2 SDK: left out (no hardware).
- Older CUDA work goes on the eGPU with the 3090, not the 5090s.
