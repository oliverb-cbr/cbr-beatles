# Installing Windows

`autounattend.xml` is the answer file for Windows Setup. It makes a Windows 11 install almost hands-off:

- Windows 11 Pro, UK language, keyboard and time zone.
- No Microsoft account, privacy or OEM screens.
- Creates the local admin `cbradmin` with the temporary password `ChangeMe-CBR1`. Windows makes you choose a real password at the second sign-in. (This file is in Git, so treat that password as public.)
- Turns off the automatic drive encryption Windows 11 now applies, which would get in the way of disk images.

You still choose the disk yourself. That's deliberate: with external drives plugged in, the internal SSD isn't always disk 0, and an answer file that wipes "disk 0" could wipe the wrong drive. Unplug any other external drives while installing anyway.

Debloat and privacy settings aren't in here. `scripts/provision.ps1` applies them, so they're re-applied on every update and checked by the audit.

**Use the "English International" Windows 11 ISO** from Microsoft's download page. The answer file asks for UK English, and Setup stops with an error if the ISO doesn't contain that language.

## On a USB stick with Ventoy

1. Put the ISO in an `ISO\Windows11` folder on the Ventoy drive.
2. Copy `autounattend.xml` to `ventoy\script\cbr-autounattend.xml` on the Ventoy drive.
3. Copy `ventoy.json` to `ventoy\ventoy.json` (merge it in if you already have one).
   While you're there, put `bootstrap.bat` and the `cbr-deploy\installers` folder (see [installers/README.md](../installers/README.md)) on the stick too, so one USB has everything.
4. Boot the stick and pick the Windows ISO. Ventoy asks whether to use the CBR template. Choose it.

## On a USB stick with Rufus

1. Write the ISO with Rufus. When it shows the "Windows User Experience" box, **untick everything**: Rufus otherwise writes its own answer file, which would clash with ours.
2. Copy `autounattend.xml` to the root of the stick.

## In the Hyper-V test VM

1. On the host, run `windows\make-answer-iso.ps1`. It writes `windows\cbr-answer.iso`.
2. Attach it as a second DVD drive alongside the Windows ISO:
   ```powershell
   Add-VMDvdDrive CBR-Test -Path C:\CBR\cbr-beatles\windows\cbr-answer.iso
   ```
3. Start the VM, press a key to boot from the DVD, and Setup picks up the answer file.

## Why not NTLite

NTLite edits the Windows image itself. That's hard to repeat exactly, can't be reviewed in Git, and removing Windows components can break Windows Update or software that quietly depends on them (Unreal, Resolve and WSL all lean on bits of Windows people like to strip). An answer file plus scripted removal of the preinstalled apps gets most of the benefit and stays reversible.
