# cbr-beatles

Build and maintenance scripts for the four CBR RTX 5090 workstations: **JOHN, PAUL, GEORGE and RINGO**.

The idea: what a CBR workstation *is* lives in [`manifest.psd1`](manifest.psd1). The scripts make a machine match it and report when it doesn't. Nobody installs or updates software on these machines by hand, apart from Unreal and RealityScan until Epic's offline installers for them arrive (see [installers/README.md](installers/README.md#unreal-engine-and-realityscan)).

## Start here

On any Windows PC, open PowerShell (right-click Start → Terminal) and run:

```powershell
irm https://raw.githubusercontent.com/oliverb-cbr/cbr-beatles/HEAD/go.ps1 | iex
```

It asks for administrator rights, gets the latest scripts and shows a menu: make the install USB stick, set up this PC as one of the four, update it or check it. It only offers what's safe on the PC it's on. Running `bootstrap.bat` (also on the install stick) does the same. No GitHub sign-in is needed while the repo is public.

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
