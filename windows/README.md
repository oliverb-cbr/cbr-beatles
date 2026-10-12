# Installing Windows

`autounattend.xml` is the answer file for Windows Setup. It makes a Windows 11 install almost hands-off:

- Windows 11 Pro, UK language, keyboard and time zone.
- No Microsoft account, privacy or OEM screens.
- Creates the local admin `cbradmin` with the temporary password `ChangeMe-CBR1`. Windows makes you choose a real password at the second sign-in. (This file is in Git, so treat that password as public.)
- Turns off the automatic drive encryption Windows 11 now applies, which would get in the way of disk images.

You still choose the disk yourself. That's deliberate: with external drives plugged in, the internal SSD isn't always disk 0, and an answer file that wipes "disk 0" could wipe the wrong drive. Unplug any other external drives while installing anyway.

Debloat and privacy settings aren't in here. `scripts/provision.ps1` applies them, so they're re-applied on every update and checked by the audit.

**Use the "English International" Windows 11 ISO** from Microsoft's download page. The answer file asks for UK English, and Setup stops with an error if the ISO doesn't contain that language.

## On the install USB stick

Run `bootstrap.bat` on any Windows PC and choose **Make or refresh the install USB stick**. It does all of this for you, and checks the ISO against `Settings.WindowsIso` in the manifest:

| On the stick | What it is |
|---|---|
| Ventoy | The boot menu. Installed (erasing the stick) only if the stick doesn't have it already. |
| `ISO\Windows11\<the ISO>` | Windows 11 |
| `ventoy\script\cbr-autounattend.xml` | This answer file |
| `ventoy\ventoy.json` | Tells Ventoy to offer the answer file for ISOs in `ISO\Windows11` (merged with any settings already there) |
| `bootstrap.bat` | To run on each machine once Windows is installed |
| `cbr-deploy\installers` | Installers that can't be downloaded automatically, copied from `C:\CBR\installers` |

To install: boot the stick, pick the Windows ISO, and choose the CBR template when Ventoy asks.

**Secure Boot:** the first time the stick boots on each PC, Ventoy shows a blue screen asking you to enrol its key. Follow it (Enroll key from disk, then the `.cer` file on the stick), and restart. Once per PC. Some boards also need "Allow Microsoft 3rd Party UEFI CA" turned on in the firmware.

## In the Hyper-V test VM

Hyper-V VMs can't boot from a USB stick, so the answer file goes on a small second disc instead.

1. On the host, run `windows\make-answer-iso.ps1`. It writes `windows\cbr-answer.iso`.
2. Attach it as a second DVD drive alongside the Windows ISO:
   ```powershell
   Add-VMDvdDrive CBR-Test -Path C:\CBR\cbr-beatles\windows\cbr-answer.iso
   ```
3. Start the VM, press a key to boot from the DVD, and Setup picks up the answer file.

## Why not NTLite

NTLite edits the Windows image itself. That's hard to repeat exactly, can't be reviewed in Git, and removing Windows components can break Windows Update or software that quietly depends on them (Unreal, TouchDesigner and WSL all lean on bits of Windows people like to strip). An answer file plus scripted removal of the preinstalled apps gets most of the benefit and stays reversible.
