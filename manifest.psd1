# CBR workstation manifest: the single source of truth for what a CBR workstation is.
#
# Every script reads this file. To change the build on all four machines, edit it here,
# commit, push, then run update.ps1 (or fleet.ps1 -Action Update).
#
# App fields
#   Name      Display name used in logs and the audit.
#   Method    winget    - installed with winget.
#             installer - vendor installer kept under InstallerRoot (see installers/README.md).
#             portable  - zip of standalone programs (Url) unpacked into InstallDir, which is added
#                         to the system PATH. For tools winget installs in a way staff can't run.
#             unity     - Unity Editor installed through Unity Hub's headless CLI. Only Version is
#                         needed: the changeset is looked up in Unity's release list.
#             manual    - installed by hand; the scripts only check that it is there.
#   Policy    current   - install latest; update.ps1 upgrades it.
#             pinned    - must match Version exactly (prefix match, so '5.6' matches '5.6.1').
#                         Change Version here to roll out a new version.
#   Version   Required version for pinned apps. $null = not decided yet: installs the latest and
#             the audit shows UNPINNED until you fill it in. Record versions after testing on JOHN.
#   Detect    Wildcard matched against the Apps & Features (uninstall registry) display name.
#             Run scripts\find-app.ps1 '<pattern>' on JOHN to check a pattern matches one entry.
#   DetectPath  Alternative to Detect: a path (wildcards allowed) that exists when installed.
#             A path with the version in it (UE_5.6) counts as that version being installed.
#   Notes     How to install it by hand, shown when it's missing and can't be installed automatically.
#   Shortcut  Where its shortcut goes in the desktop and Start menu folders (Settings.ShortcutFolders):
#             @{ Folder = 'Tools'; StartMenu = 'Notepad++' } copies the Start menu shortcut its installer
#             made (a name, wildcards allowed, or a list of them). Target = 'C:\...\app.exe' makes one
#             instead, or is used if no Start menu shortcut is found. UserTarget is for apps installed
#             into each person's own profile ('%LOCALAPPDATA%\...'). Name overrides the shortcut's name.
#
# winget-only fields
#   Id        winget package id (checked against microsoft/winget-pkgs, October 2026).
#   Scope     'machine' (default) so every user gets the app. '' = don't pass --scope, for
#             manifests that don't declare one.
#   Override  Replaces the installer's own arguments (used for Visual Studio workloads).
#   InstallerType  Forces a particular installer when a package also offers a Store-style MSIX,
#             which installs outside Program Files and isn't seen by the audit.
#   MsixName  Package name (wildcards allowed) of that MSIX, so a copy from an earlier run is removed.
#
# installer-only fields
#   Installer Wildcard matched against installer file names (they keep their download names). If an
#             old and a new version both match, the one whose name contains Version is used.
#             Provisioning lists any file no pattern matches, so a wrong pattern shows up.
#             .zip and .iso files are opened and the installer inside is run.
#   Url       Stable public download link. If no matching file is found, provisioning downloads it.
#             Leave it out for links that expire or need a sign-in (use DownloadPage instead).
#   FileName  Name to save a download as, for links that don't end in the file name.
#   DownloadPage  Where to fetch it by hand, shown when there's no file and no Url.
#   Sha256    SHA-256 of the tested installer. Every file is checked against it before it runs;
#             provisioning prints the hash of files that don't have one yet, to copy in here.
#   Signer    Instead of Sha256, for a file the vendor replaces at every release (Chrome): the
#             organisation its signature must be from, e.g. 'Google LLC'.
#   Inner     Optional, for .zip/.iso: pattern for the installer inside, if there's more than one.
#   Args      Silent-install arguments. $null = run the installer interactively and wait.

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
        # Vendor installers. Downloads land in InstallerCache, and installers that can't be downloaded
        # automatically are put there by hand. InstallerRoot is an optional extra place to look: a
        # relative path is searched for at the root of every drive (a USB stick), a full path can be a
        # NAS share. Either way the manifest's Sha256 decides whether a file is the right one.
        InstallerCache = 'C:\CBR\installers'
        InstallerRoot  = 'cbr-deploy\installers'
        AdminUser     = 'cbradmin'      # local admin, created during Windows setup
        SharedUser    = 'CBR'           # standard (non-admin) account staff log in with
        SessionUser   = 'CBRSession'    # shown as "CBR Session": for running sessions; reset from the Accounts menu
        WslDistro     = 'Ubuntu-24.04'
        WslUser       = 'cbr'           # Linux user inside the WSL distro

        # The install USB stick, made by bootstrap.bat (scripts\make-usb.ps1). Only a Windows ISO with
        # this SHA-256 goes on it: the one tested in the VM. Ventoy is the boot menu on the stick.
        WindowsIso    = @{ File = 'Windows11_Client_x64_en-gb_26300_9457.iso'
                           Sha256 = '7E3F373BD3C2321B5D5125DFCF718DFBF1A0ABC50A267118669951890DF98A5D' }
        Ventoy        = @{ Version = '1.1.17'
                           Url = 'https://sourceforge.net/projects/ventoy/files/v1.1.17/ventoy-1.1.17-windows.zip/download'
                           Sha256 = 'D250E97A7595FDAC4F97DEBC630D7A8DA942319274A76CB32384596B659DBAEB' }

        # Region: UK time (GMT/BST), UK English formats and keyboard. Also set by windows\autounattend.xml.
        TimeZone      = 'GMT Standard Time'
        Locale        = 'en-GB'
        GeoId         = 242             # United Kingdom

        # Desktop and Start menu folders. Each app's Shortcut field says which one it goes in.
        ShortcutFolders = @('360 & Video', '3D & Scanning', 'Browsers', 'Code', 'Creative Coding', 'Game Engines', 'Tools', 'VR & Quest')

        # Disk space each account can use on C:, in GB. Windows refuses to write past Limit; the sign-in
        # check tells the person as soon as they pass Warn. Admin and Windows' own accounts have no limit.
        # QuotaMode 'Enforce' applies the limits; 'Warn' only tracks usage (a quick way back if limits misbehave).
        Quotas        = @{ Personal = @{ Warn = 250; Limit = 400 }
                           Shared   = @{ Warn = 300; Limit = 500 }
                           Session  = @{ Warn = 100; Limit = 150 } }
        QuotaMode     = 'Enforce'

        # OneDrive app: for personal accounts only (blocked for the shared ones), Falmouth's Microsoft 365
        # only, files online-only until opened and made online-only again after this many days unopened.
        OneDriveTenantId      = '550beeb3-6a3d-4646-a111-f89d0177792e'
        OneDriveDehydrateDays = 7

        # Not scanned by Defender as they're written (still scanned when opened). Speeds up Unreal, Unity and
        # Blender a lot. See "Deliberate trade-offs" in the README.
        DefenderExclusions = @('C:\Users\*\Work', 'C:\Users\*\AppData\Local\UnrealEngine', 'C:\Users\*\AppData\Local\Unity\cache')

        # Things that start themselves at sign-in, kept off for every account (Task Manager's Startup apps
        # switch, so they stay off even when the app adds itself again). WavesSvc is the motherboard's audio
        # "enhancements"; check speakers and headphones still work on JOHN.
        StartupOff     = @('Steam', 'Studio.QuickLook', 'EpicGamesLauncher', 'WavesSvc')
        # Expected to start at sign-in. The audit lists anything else that does.
        StartupAllowed = @('SecurityHealth', 'Everything', 'RtkAudUService', 'OneDrive')
        # Scheduled tasks to turn off, and ones that are expected (full task path, wildcards allowed).
        TasksOff       = @('\Mozilla\Firefox Default Browser Agent*', '\SoftLanding\*', '\NVIDIA App SelfUpdate*')
        TasksAllowed   = @('\CBR - *')
        # Programs installers add that we don't want, uninstalled silently. The NVIDIA App comes with the
        # driver and exists to offer newer drivers, which is no use when the driver is pinned.
        Unwanted       = @(@{ DisplayName = 'NVIDIA app*'; SilentArgs = '-silent' })

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
            'MicrosoftWindows.Client.WebExperience'   # Widgets
            'MSTeams'
        )
    }

    Apps = @(
        # ---- Browsers, utilities: keep current -------------------------------------------
        @{ Name = 'Brave';           Method = 'winget'; Id = 'Brave.Brave';                 Policy = 'current'; Detect = 'Brave*'
           Shortcut = @{ Folder = 'Browsers'; StartMenu = 'Brave' } }
        # Google replaces this file at every release, so winget's recorded hash is often out of date and
        # winget then refuses it. Taken straight from Google instead, and checked by Google's signature.
        @{ Name = 'Chrome';          Method = 'installer'; Installer = 'googlechromestandaloneenterprise64*'; Signer = 'Google LLC'
           Url = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'; Args = $null; Policy = 'current'; Detect = 'Google Chrome'
           Shortcut = @{ Folder = 'Browsers'; StartMenu = 'Google Chrome' } }
        @{ Name = 'Firefox';         Method = 'winget'; Id = 'Mozilla.Firefox';             Policy = 'current'; Detect = 'Mozilla Firefox*'
           Shortcut = @{ Folder = 'Browsers'; StartMenu = 'Firefox' } }
        @{ Name = 'Everything';      Method = 'winget'; Id = 'voidtools.Everything';        Policy = 'current'; Detect = 'Everything*'
           Shortcut = @{ Folder = 'Tools'; StartMenu = 'Everything' } }
        @{ Name = 'Notepad++';       Method = 'winget'; Id = 'Notepad++.Notepad++';         Policy = 'current'; Detect = 'Notepad++*'
           Shortcut = @{ Folder = 'Tools'; StartMenu = 'Notepad++' } }
        @{ Name = 'PuTTY';           Method = 'winget'; Id = 'PuTTY.PuTTY';                 Policy = 'current'; Detect = 'PuTTY release*'
           Shortcut = @{ Folder = 'Tools'; StartMenu = 'PuTTY' } }
        @{ Name = 'VLC';             Method = 'winget'; Id = 'VideoLAN.VLC';                Policy = 'current'; Detect = 'VLC media player'
           Shortcut = @{ Folder = '360 & Video'; StartMenu = 'VLC media player'; Name = 'VLC' } }
        @{ Name = 'WinDirStat';      Method = 'winget'; Id = 'WinDirStat.WinDirStat';       Policy = 'current'; Detect = 'WinDirStat*'
           Shortcut = @{ Folder = 'Tools'; StartMenu = 'WinDirStat' } }
        @{ Name = 'WinMerge';        Method = 'winget'; Id = 'WinMerge.WinMerge';           Policy = 'current'; Detect = 'WinMerge*'
           Shortcut = @{ Folder = 'Tools'; StartMenu = 'WinMerge' } }
        @{ Name = '7-Zip';           Method = 'winget'; Id = '7zip.7zip';                   Policy = 'current'; Detect = '7-Zip*' }
        # Installed once for the whole PC. Microsoft replaces the file at every release, so it's checked by
        # Microsoft's signature. Settings.OneDrive* control it; it's blocked for the shared accounts.
        @{ Name = 'OneDrive';        Method = 'installer'; Installer = 'OneDriveSetup*'; Signer = 'Microsoft Corporation'
           Url = 'https://go.microsoft.com/fwlink/?linkid=844652'; FileName = 'OneDriveSetup.exe'; Args = '/allusers /silent'
           Policy = 'current'; DetectPath = 'C:\Program Files*\Microsoft OneDrive\OneDrive.exe' }
        # Steam is left out on purpose: its sign-ins aren't kept apart between Windows accounts. Install it
        # by hand on a particular PC if it's needed (see "Deliberate trade-offs" in the README).
        @{ Name = 'SideQuest';       Method = 'winget'; Id = 'SideQuestVR.SideQuest';       Policy = 'current'; Detect = 'SideQuest*'
           Shortcut = @{ Folder = 'VR & Quest'; StartMenu = 'SideQuest' } }

        # ---- Development -----------------------------------------------------------------
        @{ Name = 'Git';             Method = 'winget'; Id = 'Git.Git';                     Policy = 'current'; Detect = 'Git'
           Shortcut = @{ Folder = 'Code'; StartMenu = 'Git Bash'; Name = 'Git Bash' } }
        # Machine scope installs the Deployment Tool, which installs Desktop for each user at login.
        @{ Name = 'GitHub Desktop';  Method = 'winget'; Id = 'GitHub.GitHubDesktop';        Policy = 'current'; Detect = 'GitHub Desktop Deployment Tool'
           Shortcut = @{ Folder = 'Code'; UserTarget = '%LOCALAPPDATA%\GitHubDesktop\GitHubDesktop.exe'; Icon = 'C:\Program Files*\GitHub Desktop Deployment\*.exe' } }
        @{ Name = 'VS Code';         Method = 'winget'; Id = 'Microsoft.VisualStudioCode';  Policy = 'current'; Detect = 'Microsoft Visual Studio Code'
           Shortcut = @{ Folder = 'Code'; StartMenu = 'Visual Studio Code' } }
        # The id pins the minor version (3.13.x); patches update. Projects use uv for other Pythons.
        @{ Name = 'Python 3.13';     Method = 'winget'; Id = 'Python.Python.3.13';          Policy = 'current'; Detect = 'Python 3.13.* (64-bit)' }
        # Not via winget: its machine-wide 'portable' install can only be run by admins.
        @{ Name = 'uv';              Method = 'portable'; Url = 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip'
           InstallDir = 'C:\Program Files\uv'; Policy = 'current'; DetectPath = 'C:\Program Files\uv\uv.exe' }
        # Needed for Unreal C++ projects, Unity IL2CPP and Python packages that compile native code.
        # Community edition is licensed for academic research.
        @{ Name = 'Visual Studio 2022'; Method = 'winget'; Id = 'Microsoft.VisualStudio.2022.Community'; Policy = 'current'; Detect = 'Visual Studio Community 2022'
           Override = '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.NativeGame --add Microsoft.VisualStudio.Workload.NativeDesktop --add Microsoft.VisualStudio.Workload.ManagedGame --includeRecommended'
           Shortcut = @{ Folder = 'Code'; StartMenu = 'Visual Studio 2022' } }
        @{ Name = 'Processing';      Method = 'winget'; Id = 'ProcessingFoundation.Processing'; Policy = 'pinned'; Version = '4.5.7'; Detect = 'Processing*'
           Shortcut = @{ Folder = 'Creative Coding'; StartMenu = 'Processing*' } }

        # ---- Creative / 3D: pinned -------------------------------------------------------
        @{ Name = 'Blender';         Method = 'winget'; Id = 'BlenderFoundation.Blender';   Policy = 'pinned'; Version = '5.2.2'; Detect = 'Blender*'
           Shortcut = @{ Folder = '3D & Scanning'; StartMenu = 'Blender*'; Name = 'Blender' } }
        @{ Name = 'OBS Studio';      Method = 'winget'; Id = 'OBSProject.OBSStudio';        Policy = 'pinned'; Version = '32.2.2'; Detect = 'OBS Studio'
           Shortcut = @{ Folder = '360 & Video'; StartMenu = 'OBS Studio*'; Name = 'OBS Studio' } }
        @{ Name = 'CloudCompare';    Method = 'winget'; Id = 'CloudCompare.CloudCompare';   Policy = 'pinned'; Version = '2.13.2 (07-06-2024)'; Detect = 'CloudCompare*'; Scope = ''
           Shortcut = @{ Folder = '3D & Scanning'; StartMenu = 'CloudCompare' } }
        @{ Name = 'TouchDesigner';   Method = 'installer'; Installer = 'TouchDesigner*';  Url = 'https://download.derivative.ca/TouchDesigner.2025.33230.exe'; Args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'; Policy = 'pinned'; Version = '2025.33230'; Detect = 'TouchDesigner*'; Sha256 = 'AB6E8F72848DFA3BBA7DDB7B2CECE546FE668474D13AB8C82C326AE551BDAE64'
           Shortcut = @{ Folder = 'Creative Coding'; StartMenu = 'TouchDesigner*'; Name = 'TouchDesigner' } }

        # ---- Game engines and Epic tools -------------------------------------------------
        @{ Name = 'Epic Games Launcher'; Method = 'winget'; Id = 'EpicGames.EpicGamesLauncher'; Policy = 'current'; Detect = 'Epic Games Launcher'
           Shortcut = @{ Folder = 'Game Engines'; StartMenu = 'Epic Games Launcher' } }
        # Unreal and RealityScan come from Epic's offline installers, which install silently. They're
        # on the Epic Developer Portal once Epic approves CBR's education request (installers/README.md),
        # and are put in C:\CBR\installers by hand. Until then, install them from the Epic Games Launcher.
        @{ Name = 'Unreal Engine 5.6'; Method = 'installer'; Installer = '*Unreal*'; Inner = '*.msi'
           # Leaves out debug symbols (tens of GB) and the iOS, tvOS, Linux and HoloLens targets; keeps Android for Quest.
           Args = 'INSTALLLOCATION="C:\Program Files\Epic Games\UE_5.6" ENGINE_SYMBOLS_CHECKED=0 ENGINE_IOS_CHECKED=0 ENGINE_TVOS_CHECKED=0 ENGINE_LUMIN_CHECKED=0 ENGINE_HOLOLENS_CHECKED=0 ENGINE_LINUX_CHECKED=0'
           Policy = 'pinned'; Version = '5.6'; Sha256 = $null
           DownloadPage = 'the Epic Developer Portal (Unreal Engine > Downloads, type Unreal Engine Offline Installer)'
           DetectPath = 'C:\Program Files\Epic Games\UE_5.6\Engine\Binaries\Win64\UnrealEditor.exe'
           Notes = 'Or install it from the Epic Games Launcher, signed in with the CBR Epic account.'
           Shortcut = @{ Folder = 'Game Engines'; StartMenu = 'Unreal Engine 5.6*'; Target = 'C:\Program Files\Epic Games\UE_5.6\Engine\Binaries\Win64\UnrealEditor.exe' } }
        @{ Name = 'RealityScan';     Method = 'installer'; Installer = '*RealityScan*'; Args = $null
           Policy = 'pinned'; Version = $null; Sha256 = $null
           DownloadPage = 'the Epic Developer Portal (RealityScan downloads)'
           DetectPath = 'C:\Program Files\Epic Games\RealityScan*\RealityScan.exe'
           Notes = 'Or install it from the Epic Games Launcher, signed in with the CBR Epic account.'
           Shortcut = @{ Folder = '3D & Scanning'; StartMenu = 'RealityScan*'; Target = 'C:\Program Files\Epic Games\RealityScan*\RealityScan.exe'; Name = 'RealityScan' } }
        @{ Name = 'Unity Hub';       Method = 'winget'; Id = 'Unity.UnityHub';              Policy = 'current'; Detect = 'Unity Hub*'; InstallerType = 'nullsoft'; MsixName = '*UnityHub*'
           Shortcut = @{ Folder = 'Game Engines'; StartMenu = 'Unity Hub' } }
        # Latest LTS in October 2026. Modules are Unity Hub's ids; Android brings its JDK, SDK and NDK with it.
        # People sign in to Unity Hub with their own (free) Unity account to licence it.
        @{ Name = 'Unity Editor';    Method = 'unity'; Policy = 'pinned'; Version = '6000.3.26f1'
           Modules = @('windows-il2cpp', 'android', 'webgl')
           DetectPath = 'C:\Program Files\Unity\Hub\Editor\{Version}\Editor\Unity.exe' }

        # ---- Hardware and vendor tools ---------------------------------------------------
        # Version is the driver number. '-nsd-' in the file name marks a Studio driver (Game Ready ones lack it).
        # Test a new one on JOHN, then change Version here.
        @{ Name = 'NVIDIA driver';   Method = 'installer'; Installer = '*-nsd-*'; Url = 'https://us.download.nvidia.com/Windows/617.42/617.42-desktop-win10-win11-64bit-international-nsd-dch-whql.exe'; Args = '-s -noreboot -noeula'; Policy = 'pinned'; Version = '617.42'; Detect = 'nvidia-driver'; Sha256 = 'D929D8B4587CC49717357B7EF3F60582304568C198F90F8263E1177A8C963B2F' }
        @{ Name = 'Insta360 Studio';   Method = 'installer'; Installer = 'Insta360_Studio*';    Url = 'https://wassets.insta360.com/common/c28b0183013d44f0ac9afdf803100cd8/Insta360_Studio_6.0.6_release_insta360(RC_build99)_20260929_154023_1790667881441.exe'
           Args = $null; Policy = 'pinned'; Version = '6.0.6'; Detect = 'Insta360 Studio*'; Sha256 = '21C3AEF2B0A21276F1A367D3AB81ABEB8B6CDAE150E49F8CA77D3453E5203639'
           Shortcut = @{ Folder = '360 & Video'; StartMenu = 'Insta360 Studio*'; Name = 'Insta360 Studio' } }
        @{ Name = 'Insta360 Stitcher'; Method = 'installer'; Installer = 'Insta360Stitcher*';   Url = 'https://file.insta360.com/static/80e76b2df50579a44d44f6bba7fc07e2/Insta360Stitcher_Winx64_4.0.1_build_202506122124.zip'
           Args = $null; Policy = 'pinned'; Version = '4.0.1'; Detect = 'Insta360*Stitcher*'; Sha256 = '3AD8E4205FA327546B1C58B57B897BE95B4647BA038EF33CDA814E2F8084DF20'
           Shortcut = @{ Folder = '360 & Video'; StartMenu = @('Insta360 Stitcher*', 'Insta360Stitcher*'); Name = 'Insta360 Stitcher' } }
        # XGRIDS LCC tools. LCC Studio ships as an ISO; provisioning mounts it and runs the installer inside.
        @{ Name = 'LCC Studio';        Method = 'installer'; Installer = 'LCCStudio*';          Url = 'https://d1hl53kddblsn9.cloudfront.net/prd/lixel/lixelstudio/2.5.0.025//LCCStudio_2.5.0.025_full_en.iso'
           Args = $null; Policy = 'pinned'; Version = '2.5.0.025'; Detect = 'LCC Studio*'; Sha256 = '132D87FF83972BC8C3FE5E217AAB0C49C868B07538E7805D14D65066DD889145'
           Shortcut = @{ Folder = '3D & Scanning'; StartMenu = 'LCC Studio*'; Name = 'LCC Studio' } }
        @{ Name = 'LCC Editor';        Method = 'installer'; Installer = 'LCCEditorSetup*';     Url = 'https://d1hl53kddblsn9.cloudfront.net/lcc/app/LCCEditor/LCCEditorSetup_v2.5.0.018-online-en.exe'
           Args = $null; Policy = 'pinned'; Version = '2.5.0'; Detect = 'LCCEditor*'; Sha256 = 'D44F992B9FB6EF3C89ED10E56264A3254B87BAC77638D9A13C7D7E0471BEBE6C'
           Shortcut = @{ Folder = '3D & Scanning'; StartMenu = @('LCC Editor*', 'LCCEditor*'); Name = 'LCC Editor' } }
        @{ Name = 'LCC Model Editor';  Method = 'installer'; Installer = 'LCC Model Editor*';   Url = 'https://d2x3vt26aihlkb.cloudfront.net/prd/LCC/LCC%20Model%20Editor/1.3.1.1/LCC%20Model%20Editor_v1.3.1.exe'
           Args = $null; Policy = 'pinned'; Version = '1.3.1.1'; Detect = 'LCC Model Editor*'; Sha256 = '3BE825C4F66842A88C410AB5844E8C747C2016C6085A5AC25F5B1684D377571B'
           Shortcut = @{ Folder = '3D & Scanning'; StartMenu = 'LCC Model Editor*'; Name = 'LCC Model Editor' } }
        # Downloads as a .zip; provisioning unpacks it and runs the installer inside.
        @{ Name = 'Meta Quest Developer Hub'; Method = 'installer'; Installer = 'Meta-Quest-Developer-Hub*'; Url = 'https://securecdn-lhr11-1.oculus.com/binaries/download/?id=28433721256286253'
           FileName = 'Meta-Quest-Developer-Hub-6.5.2.exe.zip'; Args = $null; Policy = 'current'; Detect = 'Meta Quest Developer Hub*'; Sha256 = '05F7E7AA3008721764F2D082E3BC4F1F7D04C96CD2F3A33C7F3F64B890C4E4F3'
           Shortcut = @{ Folder = 'VR & Quest'; StartMenu = 'Meta Quest Developer Hub*'; Name = 'Meta Quest Developer Hub' } }
        # VIVE Mars needs no PC software.
        # Kinect v2 SDK left out on purpose (no hardware). Add it here if that changes.
    )
}
