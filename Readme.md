NSudo.cmdNSudo.cmd is a 100% native PowerShell 5.1 / Batch polyglot fork of the legendary NSudo by M2-Team. It completely replaces the traditional C++ NSudo Launcher with a single, highly evasive, zero-compiled-binary .cmd script.Key FeaturesZero Compiled Binaries: No .exe or .dll files required. The entire application, including the WinForms UI and the Win32 API bridge, is packed into one file.Defender-Friendly (0/61 VT): Designed to bypass modern AV heuristics and Sigma rules (e.g., utilizing fltmc for elevation checks).Zero Temp-File Execution: UAC elevation and Current Working Directory (CWD) preservation are handled entirely in-memory using Base64 encoding."Crazy Path" Immunity: Preserves working directories containing complex Unicode or brackets [ ] across CMD, PowerShell, and PowerShell ISE, bypassing native Microsoft path-resolution bugs.Win11 UWP Alias Bypass: Explicitly routes commands like notepad to System32\notepad.exe to prevent Win32 Error 2 when running under the TrustedInstaller identity.Ghost-Window Free: Natively executes non-PE files like .msc (e.g., services.msc) by dynamically routing them through mmc.exe, preventing Win32 Error 193.UsageDouble-click NSudo.cmd to open the GUI, or run it directly from the command line:Format: NSudo.cmd [ Options and parameters ] Command line or ShortCut Command

Options:

-U:[ Option ] Create a process with specified user option.
Available options:
    T TrustedInstaller
    S System
    C Current User
    E Current User (Elevated)
    P Current Process
    D Current Process (Drop right)

-P:[ Option ] Create a process with specified privilege option.
Available options:
    E Enable All Privileges
    D Disable All Privileges

-M:[ Option ] Create a process with specified Integrity Level option.
Available options:
    S System
    H High
    M Medium
    L Low

-Priority:[ Option ] Create a process with specified process priority option.
Available options:
    Idle
    BelowNormal
    Normal
    AboveNormal
    High
    RealTime

-ShowWindowMode:[ Option ] Create a process with specified window mode option.
Available options:
    Show
    Hide
    Maximize
    Minimize

-Wait Make NSudo Launcher wait for the created process to end before exiting.
-CurrentDirectory:[ DirectoryPath ] Set the current directory for the process.
-UseCurrentConsole Create a process with the current console window.
-Version Show version information of NSudo Launcher.
-? / -H / -Help Show this content.
Technical DetailsUnder the hood, NSudo.cmd acts as an advanced C# wrapper dynamically compiled via PowerShell's Add-Type. It relies heavily on direct Win32 API calls (CreateProcessWithTokenW, DuplicateTokenEx, OpenProcessToken, SetTokenInformation) to accurately duplicate and adjust process tokens across Active Sessions, entirely avoiding third-party dependencies.CreditsOriginal C++ concept and NSudo tool by M2-Team.