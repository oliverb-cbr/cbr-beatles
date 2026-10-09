# cbr-beatles

Build and maintenance scripts for the four CBR RTX 5090 workstations: **JOHN, PAUL, GEORGE and RINGO**.

The idea: what a CBR workstation *is* lives in [`manifest.psd1`](manifest.psd1). The scripts make a machine match it and report when it doesn't. Nobody installs or updates software on these machines by hand except for the few apps marked `manual`.

## How it fits together

| Layer | What | Where it's defined |
|---|---|---|
| Windows install | Windows 11 Pro, UK settings, local `cbradmin`, no Microsoft account | `windows/autounattend.xml` |
| Windows settings | Hostname, accounts, power, update policy, debloat, privacy, OpenSSH | `scripts/provision.ps1` |
| Apps | ~36 apps via winget, vendor installers, Unity Hub or by hand | `manifest.psd1` |
| Linux / AI | WSL2 Ubuntu 24.04 + Docker Engine + NVIDIA container toolkit + uv | `scripts/user-setup.ps1`, `wsl/setup-docker.sh` |
| Installers | Vendor installers on the install USB, found on any drive letter | `Settings.InstallerRoot` in the manifest |

Accounts on every machine:

- **`cbradmin`**: local admin. Used only for provisioning and updates.
- **`CBR`**: standard user that staff log in with. Can't install software or change the scripts.
- Shared CBR accounts for Steam, Epic, Unity and Meta are signed in under `CBR`. OneDrive is removed.

## Scripts

| Script | Run as | Does |
|---|---|---|
| `bootstrap.bat` | admin, on a fresh machine | Installs Git, downloads this repo to `C:\CBR\cbr-beatles`, optionally runs provision (`bootstrap.bat JOHN`). |
| `scripts/provision.ps1` | admin | Builds or re-converges a machine. Safe to re-run. |
| `scripts/update.ps1` | admin | `git pull`, then provision with `-Upgrade` (upgrades `current` apps, moves pinned apps to the manifest version). |
| `scripts/audit.ps1` | anyone | Read-only report of anything missing or at the wrong version. |
| `scripts/fleet.ps1` | admin, from any machine | Audits (or updates) all four over SSH and shows a side-by-side grid with drift marked. |
| `scripts/user-setup.ps1` | `CBR` | One-off: WSL Ubuntu, Docker, GPU in containers, uv. |
| `scripts/find-app.ps1` | anyone | Lists installed apps matching a pattern, for writing `Detect` patterns. |

Run them with `powershell -ExecutionPolicy Bypass -File <script>`.

## Version policy

- **current**: browsers, utilities, Git, VS Code, Steam etc. `update.ps1` keeps them up to date.
- **pinned**: Blender, TouchDesigner, Resolve, Unreal 5.6, Unity, RealityScan, NVIDIA driver, OBS, Processing, CloudCompare and the hardware tools. All four machines must have the same version.

To roll out a new pinned version: install and test it on JOHN, change `Version` in the manifest, commit, push, then `fleet.ps1 -Action Update`.

Pinned apps start with `Version = $null`. The first build installs the latest, the audit shows them as `UNPINNED`, and once JOHN is tested you copy the installed versions from the audit into the manifest.

## Building the machines

See [docs/build-checklist.md](docs/build-checklist.md). In short: build JOHN by hand with the scripts, test it with real projects, record versions, then repeat on PAUL, GEORGE and RINGO.

## Not done yet / decided against for now

- VHDX and Ventoy multi-boot: parked.
- A recovery image: capture one (after Sysprep) once JOHN is proven.
- Deep Freeze: add later if staff changes become a problem.
- Kinect v2 SDK: left out (no hardware).
- Older CUDA work goes on the eGPU with the 3090, not the 5090s.
