# CBR workstation manifest: the single source of truth for what a CBR workstation is.
#
# Every script reads this file. To change the build on all four machines, edit it here,
# commit, push, then run update.ps1 (or fleet.ps1 -Action Update).
#
# App fields
#   Name      Display name used in logs and the audit.
#   Method    winget    - installed with winget.
#             installer - vendor installer kept under InstallerRoot (see installers/README.md).
#             unity     - Unity Editor installed through Unity Hub's headless CLI.
#             manual    - installed by hand; the scripts only check that it is there.
#   Policy    current   - install latest; update.ps1 upgrades it.
#             pinned    - must match Version exactly (prefix match, so '5.6' matches '5.6.1').
#                         Change Version here to roll out a new version.
#   Version   Required version for pinned apps. $null = not decided yet: installs the latest and
#             the audit shows UNPINNED until you fill it in. Record versions after testing on JOHN.
#   Detect    Wildcard matched against the Apps & Features (uninstall registry) display name.
#             Run scripts\find-app.ps1 '<pattern>' on JOHN to check a pattern matches one entry.
#   DetectPath  Alternative to Detect: a path (wildcards allowed) that exists when installed.
#
# winget-only fields
#   Id        winget package id (checked against microsoft/winget-pkgs, October 2026).
#   Scope     'machine' (default) so every user gets the app. '' = don't pass --scope, for
#             manifests that don't declare one.
#   Override  Replaces the installer's own arguments (used for Visual Studio workloads).
#
# installer-only fields
#   Installer Wildcard matched against the file names in Settings.InstallerRoot, where all the
#             installers sit loose under their download names. If an old and a new version both
#             match, the one whose name contains Version is used. Provisioning lists any file
#             no pattern matches, so a wrong pattern shows up. .zip and .iso files are opened
#             and the installer inside is run.
#   Inner     Optional, for .zip/.iso: pattern for the installer inside, if there's more than one.
#   Args      Silent-install arguments. $null = run the installer interactively and wait.
#   Sha256    Optional; checked before running when set.

@{
    # Machines: Name is used by fleet.ps1 -Machine; ComputerName is the Windows hostname;
    # Address is what ssh connects to (swap in an IP if name lookup doesn't work on your LAN).
    Machines = @(
        @{ Name = 'JOHN';   ComputerName = 'CBR-JOHN';   Address = 'CBR-JOHN' }
        @{ Name = 'PAUL';   ComputerName = 'CBR-PAUL';   Address = 'CBR-PAUL' }
        @{ Name = 'GEORGE'; ComputerName = 'CBR-GEORGE'; Address = 'CBR-GEORGE' }
        @{ Name = 'RINGO';  ComputerName = 'CBR-RINGO';  Address = 'CBR-RINGO' }
    )

    Settings = @{
        RepoPath      = 'C:\CBR\cbr-beatles'
        # Vendor installers. A relative path is searched for at the root of every drive, so this finds
        # the folder on the install USB whatever letter it gets. A full path (e.g. a NAS share) also works.
        InstallerRoot = 'cbr-deploy\installers'
        AdminUser     = 'cbradmin'      # local admin, created during Windows setup
        SharedUser    = 'CBR'           # standard (non-admin) account staff log in with
        WslDistro     = 'Ubuntu-24.04'
        WslUser       = 'cbr'           # Linux user inside the WSL distro

        # Region: UK time (GMT/BST), UK English formats and keyboard. Also set by windows\autounattend.xml.
        TimeZone      = 'GMT Standard Time'
        Locale        = 'en-GB'
        GeoId         = 242             # United Kingdom

        # Preinstalled Store apps that provision.ps1 removes for all users, including future ones.
        # Never add Microsoft.DesktopAppInstaller (that's winget) or Microsoft.WindowsStore.
        # Xbox apps are kept on purpose (Game Bar, game testing).
        RemoveAppx    = @(
            'Clipchamp.Clipchamp'
            'Microsoft.BingNews'
            'Microsoft.BingSearch'
            'Microsoft.BingWeather'
            'Microsoft.Copilot'
            'Microsoft.GetHelp'
            'Microsoft.MicrosoftOfficeHub'
            'Microsoft.MicrosoftSolitaireCollection'
            'Microsoft.OutlookForWindows'
            'Microsoft.PowerAutomateDesktop'
            'Microsoft.Todos'
            'Microsoft.WindowsFeedbackHub'
            'Microsoft.YourPhone'
            'MicrosoftCorporationII.MicrosoftFamily'
            'MSTeams'
        )
    }

    Apps = @(
        # ---- Browsers, utilities: keep current -------------------------------------------
        @{ Name = 'Brave';           Method = 'winget'; Id = 'Brave.Brave';                 Policy = 'current'; Detect = 'Brave*' }
        @{ Name = 'Chrome';          Method = 'winget'; Id = 'Google.Chrome';               Policy = 'current'; Detect = 'Google Chrome' }
        @{ Name = 'Firefox';         Method = 'winget'; Id = 'Mozilla.Firefox';             Policy = 'current'; Detect = 'Mozilla Firefox*' }
        @{ Name = 'Everything';      Method = 'winget'; Id = 'voidtools.Everything';        Policy = 'current'; Detect = 'Everything*' }
        @{ Name = 'Notepad++';       Method = 'winget'; Id = 'Notepad++.Notepad++';         Policy = 'current'; Detect = 'Notepad++*' }
        @{ Name = 'PuTTY';           Method = 'winget'; Id = 'PuTTY.PuTTY';                 Policy = 'current'; Detect = 'PuTTY release*' }
        @{ Name = 'VLC';             Method = 'winget'; Id = 'VideoLAN.VLC';                Policy = 'current'; Detect = 'VLC media player' }
        @{ Name = 'WinDirStat';      Method = 'winget'; Id = 'WinDirStat.WinDirStat';       Policy = 'current'; Detect = 'WinDirStat*' }
        @{ Name = 'WinMerge';        Method = 'winget'; Id = 'WinMerge.WinMerge';           Policy = 'current'; Detect = 'WinMerge*' }
        @{ Name = '7-Zip';           Method = 'winget'; Id = '7zip.7zip';                   Policy = 'current'; Detect = '7-Zip*' }
        @{ Name = 'PowerShell 7';    Method = 'winget'; Id = 'Microsoft.PowerShell';        Policy = 'current'; Detect = 'PowerShell 7*' }
        @{ Name = 'Steam';           Method = 'winget'; Id = 'Valve.Steam';                 Policy = 'current'; Detect = 'Steam' }
        @{ Name = 'SideQuest';       Method = 'winget'; Id = 'SideQuestVR.SideQuest';       Policy = 'current'; Detect = 'SideQuest*' }

        # ---- Development -----------------------------------------------------------------
        @{ Name = 'Git';             Method = 'winget'; Id = 'Git.Git';                     Policy = 'current'; Detect = 'Git' }
        # Machine scope installs the Deployment Tool, which installs Desktop for each user at login.
        @{ Name = 'GitHub Desktop';  Method = 'winget'; Id = 'GitHub.GitHubDesktop';        Policy = 'current'; Detect = 'GitHub Desktop Deployment Tool' }
        @{ Name = 'VS Code';         Method = 'winget'; Id = 'Microsoft.VisualStudioCode';  Policy = 'current'; Detect = 'Microsoft Visual Studio Code' }
        # The id pins the minor version (3.13.x); patches update. Projects use uv for other Pythons.
        @{ Name = 'Python 3.13';     Method = 'winget'; Id = 'Python.Python.3.13';          Policy = 'current'; Detect = 'Python 3.13.* (64-bit)' }
        @{ Name = 'uv';              Method = 'winget'; Id = 'astral-sh.uv';                Policy = 'current'; DetectPath = 'C:\Program Files\WinGet\Links\uv.exe' }
        # Needed for Unreal C++ projects, Unity IL2CPP and Python packages that compile native code.
        # Community edition is licensed for academic research.
        @{ Name = 'Visual Studio 2022'; Method = 'winget'; Id = 'Microsoft.VisualStudio.2022.Community'; Policy = 'current'; Detect = 'Visual Studio Community 2022'
           Override = '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.NativeGame --add Microsoft.VisualStudio.Workload.NativeDesktop --add Microsoft.VisualStudio.Workload.ManagedGame --includeRecommended' }
        @{ Name = 'Processing';      Method = 'winget'; Id = 'ProcessingFoundation.Processing'; Policy = 'pinned'; Version = $null; Detect = 'Processing*' }

        # ---- Creative / 3D: pinned -------------------------------------------------------
        @{ Name = 'Blender';         Method = 'winget'; Id = 'BlenderFoundation.Blender';   Policy = 'pinned'; Version = $null; Detect = 'Blender*' }
        @{ Name = 'OBS Studio';      Method = 'winget'; Id = 'OBSProject.OBSStudio';        Policy = 'pinned'; Version = $null; Detect = 'OBS Studio' }
        @{ Name = 'CloudCompare';    Method = 'winget'; Id = 'CloudCompare.CloudCompare';   Policy = 'pinned'; Version = $null; Detect = 'CloudCompare*'; Scope = '' }
        @{ Name = 'TouchDesigner';   Method = 'installer'; Installer = 'TouchDesigner*';  Args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; Policy = 'pinned'; Version = $null; Detect = 'TouchDesigner*' }
        # Silent arguments for Resolve's installer: check on JOHN before relying on them.
        @{ Name = 'DaVinci Resolve'; Method = 'installer'; Installer = '*Resolve*'; Args = '/i /q /noreboot'; Policy = 'pinned'; Version = $null; Detect = 'DaVinci Resolve*' }

        # ---- Game engines and Epic tools -------------------------------------------------
        @{ Name = 'Epic Games Launcher'; Method = 'winget'; Id = 'EpicGames.EpicGamesLauncher'; Policy = 'current'; Detect = 'Epic Games Launcher' }
        @{ Name = 'Unreal Engine 5.6'; Method = 'manual'; Policy = 'pinned'; Version = '5.6'
           DetectPath = 'C:\Program Files\Epic Games\UE_5.6\Engine\Binaries\Win64\UnrealEditor.exe'
           Notes = 'Install from Epic Games Launcher, signed in with the CBR Epic account.' }
        @{ Name = 'RealityScan';     Method = 'manual'; Policy = 'pinned'; Version = $null
           DetectPath = 'C:\Program Files\Epic Games\RealityScan*'
           Notes = 'Install from Epic Games Launcher, signed in with the CBR Epic account. Check the install path on JOHN.' }
        @{ Name = 'Unity Hub';       Method = 'winget'; Id = 'Unity.UnityHub';              Policy = 'current'; Detect = 'Unity Hub*' }
        # Fill in Version and Changeset (from the Unity download archive) to have provision install it.
        @{ Name = 'Unity Editor';    Method = 'unity'; Policy = 'pinned'; Version = $null; Changeset = $null
           Modules = @('windows-il2cpp', 'android', 'android-sdk-ndk-tools', 'android-open-jdk', 'webgl')
           DetectPath = 'C:\Program Files\Unity\Hub\Editor\{Version}\Editor\Unity.exe' }

        # ---- Hardware and vendor tools ---------------------------------------------------
        # Version is the driver number. '-nsd-' in the file name marks a Studio driver (Game Ready ones lack it).
        # Test a new one on JOHN, then change Version here.
        @{ Name = 'NVIDIA driver';   Method = 'installer'; Installer = '*-nsd-*'; Args = '-s -noreboot -noeula'; Policy = 'pinned'; Version = '617.42'; Detect = 'nvidia-driver' }
        @{ Name = 'Insta360 Studio';   Method = 'installer'; Installer = 'Insta360_Studio*';    Args = $null; Policy = 'pinned'; Version = $null; Detect = 'Insta360 Studio*' }
        @{ Name = 'Insta360 Stitcher'; Method = 'installer'; Installer = 'Insta360Stitcher*';   Args = $null; Policy = 'pinned'; Version = $null; Detect = 'Insta360*Stitcher*' }
        # XGRIDS LCC tools. LCC Studio ships as an ISO; provisioning mounts it and runs the installer inside.
        @{ Name = 'LCC Studio';        Method = 'installer'; Installer = 'LCCStudio*';          Args = $null; Policy = 'pinned'; Version = $null; Detect = 'LCC Studio*' }
        @{ Name = 'LCC Editor';        Method = 'installer'; Installer = 'LCCEditorSetup*';     Args = $null; Policy = 'pinned'; Version = $null; Detect = 'LCC Editor*' }
        @{ Name = 'LCC Model Editor';  Method = 'installer'; Installer = 'LCC Model Editor*';   Args = $null; Policy = 'pinned'; Version = $null; Detect = 'LCC Model Editor*' }
        # Downloads as a .zip; provisioning unpacks it and runs the installer inside.
        @{ Name = 'Meta Quest Developer Hub'; Method = 'installer'; Installer = 'Meta-Quest-Developer-Hub*'; Args = $null; Policy = 'current'; Detect = 'Meta Quest Developer Hub*' }
        # VIVE Mars needs no PC software.
        # Kinect v2 SDK left out on purpose (no hardware). Add it here if that changes.
    )
}
