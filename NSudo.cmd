<# :
@echo off
set "SCRIPT_PATH=%~f0"
set "SCRIPT_ARGS=%*"
set "NSUDO_CWD=%CD%"
if "%NSUDO_CWD%"=="" set "NSUDO_CWD=%~dp0"

fltmc.exe 1>nul 2>nul || (
    powershell.exe -NoProfile -Command "$ErrorActionPreference='SilentlyContinue'; $cwdB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:NSUDO_CWD)); $a = if ($env:SCRIPT_ARGS) { ' ' + $env:SCRIPT_ARGS } else { '' }; Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c \"\"{0}\" --cwd \"{1}\"{2}\"' -f $env:SCRIPT_PATH, $cwdB64, $a) -Verb RunAs" 1>nul 2>nul
    exit /b
)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ([scriptblock]::Create([System.IO.File]::ReadAllText($env:SCRIPT_PATH)))"
exit /b %errorlevel%
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['*:ErrorAction']='Stop'

function ConvertFrom-CommandLine {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return @() }
    if (-not ('RunAsTINative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RunAsTINative {
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LocalFree(IntPtr hMem);
}
'@
    }
    $count = 0
    $ptr = [RunAsTINative]::CommandLineToArgvW($CommandLine, [ref]$count)
    if ($ptr -eq [IntPtr]::Zero) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Command line parsing failed with Win32 error $code."
    }
    try {
        $items = New-Object string[] $count
        for ($i = 0; $i -lt $count; $i++) {
            $itemPtr = [Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $i * [IntPtr]::Size)
            $items[$i] = [Runtime.InteropServices.Marshal]::PtrToStringUni($itemPtr)
        }
        return $items
    } finally {
        [void][RunAsTINative]::LocalFree($ptr)
    }
}

[string[]]$script:LaunchArgs = @()
if (-not [string]::IsNullOrWhiteSpace($env:SCRIPT_ARGS)) {
    $parsedArgs = ConvertFrom-CommandLine $env:SCRIPT_ARGS
    if ($parsedArgs) { $script:LaunchArgs = @($parsedArgs) }
} elseif ($null -ne $args) {
    $script:LaunchArgs = @($args)
}

$script:SelfPath = $env:SCRIPT_PATH
if ([string]::IsNullOrWhiteSpace($script:SelfPath) -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    $script:SelfPath = $PSCommandPath
}

$script:CwdOverride = ''

$filteredArgs = @()
$skipNext = $false
for ($i = 0; $i -lt $script:LaunchArgs.Count; $i++) {
    if ($skipNext) { $skipNext = $false; continue }
    if ($script:LaunchArgs[$i] -eq '--cwd') {
        $skipNext = $true
        if (($i + 1) -lt $script:LaunchArgs.Count) {
            try {
                $decodedCwd = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:LaunchArgs[$i + 1]))
                if (-not [string]::IsNullOrWhiteSpace($decodedCwd)) {
                    $script:CwdOverride = $decodedCwd
                }
            } catch {}
        }
        continue
    }
    $filteredArgs += $script:LaunchArgs[$i]
}
$script:LaunchArgs = $filteredArgs

function Get-LaunchArgs {
    return $script:LaunchArgs
}

function Get-SelfPath {
    if (-not [string]::IsNullOrWhiteSpace($script:SelfPath)) { return $script:SelfPath }
    throw 'Unable to determine the current script path.'
}

function Get-PreservedWorkingDirectory {
    if ($script:CwdOverride) {
        try {
            if (Test-Path -LiteralPath $script:CwdOverride -PathType Container -ErrorAction SilentlyContinue) { return $script:CwdOverride }
        } catch {}
    }
    if ($env:NSUDO_CWD) {
        try {
            if (Test-Path -LiteralPath $env:NSUDO_CWD -PathType Container -ErrorAction SilentlyContinue) { return $env:NSUDO_CWD }
        } catch {}
    }
    try {
        $loc = (Get-Location -PSProvider FileSystem).ProviderPath
        if (-not [string]::IsNullOrWhiteSpace($loc)) { return $loc }
    } catch {}
    foreach ($fallback in @($env:USERPROFILE, $env:HOMEDRIVE, $env:SystemRoot)) {
        if (-not [string]::IsNullOrWhiteSpace($fallback)) {
            if ($fallback -match '^[A-Za-z]:$') { return "$fallback\" }
            try {
                if (Test-Path -LiteralPath $fallback -PathType Container -ErrorAction SilentlyContinue) { return $fallback }
            } catch {}
        }
    }
    return 'C:\'
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Join-CommandLine {
    param([string[]]$Tokens)
    if (-not $Tokens -or $Tokens.Count -eq 0) { return '' }
    $quoted = foreach ($token in $Tokens) {
        if ($null -eq $token) { '""'; continue }
        if ($token -eq '') { '""'; continue }
        if ($token -notmatch '[\s"]') { $token; continue }
        '"' + (($token -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
    }
    $quoted -join ' '
}

function Ensure-NSudoNative {
    if ('NSudoNativeBridge' -as [type]) { return }
    $source = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public enum NSudoUserModeType
{
    TrustedInstaller = 0,
    System = 1,
    CurrentUser = 2,
    CurrentUserElevated = 3,
    CurrentProcess = 4,
    CurrentProcessDropRight = 5
}

public enum NSudoPrivilegesModeType
{
    Default = 0,
    EnableAll = 1,
    DisableAll = 2
}

public enum NSudoMandatoryLabelType
{
    Default = 0,
    Low = 1,
    Medium = 2,
    High = 3,
    System = 4
}

public enum NSudoProcessPriorityClassType
{
    Idle = 0,
    BelowNormal = 1,
    Normal = 2,
    AboveNormal = 3,
    High = 4,
    RealTime = 5
}

public enum NSudoShowWindowModeType
{
    Default = 0,
    Show = 1,
    Hide = 2,
    Maximize = 3,
    Minimize = 4
}

public sealed class NSudoLaunchResult
{
    public int ProcessId;
    public int ExitCode;
    public bool Waited;
}

public static class NSudoNativeBridge
{
    private const uint MAXIMUM_ALLOWED = 0x02000000;
    private const uint PROCESS_QUERY_INFORMATION = 0x0400;
    private const uint TOKEN_DUPLICATE = 0x0002;
    private const uint TOKEN_QUERY = 0x0008;
    private const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint CREATE_NEW_CONSOLE = 0x00000010;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint STARTF_USESHOWWINDOW = 0x00000001;
    private const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    private const uint GENERIC_ALL = 0x10000000;
    private const uint SE_GROUP_INTEGRITY = 0x00000020;
    private const uint ACL_REVISION = 2;
    private const uint LUA_TOKEN = 0x00000004;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;
    private const int ERROR_INVALID_PARAMETER = 87;
    private const int ERROR_NO_TOKEN = 1008;
    private const int ERROR_NOT_ALL_ASSIGNED = 1300;
    private const int ERROR_SERVICE_NOT_ACTIVE = 1062;
    private const int WinBuiltinAdministratorsSid = 26;
    private const uint SC_MANAGER_CONNECT = 0x0001;
    private const uint SERVICE_QUERY_STATUS = 0x0004;
    private const int SC_STATUS_PROCESS_INFO = 0;
    private const uint WAIT_FAILED = 0xFFFFFFFF;

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS_PROCESS
    {
        public uint dwServiceType;
        public uint dwCurrentState;
        public uint dwControlsAccepted;
        public uint dwWin32ExitCode;
        public uint dwServiceSpecificExitCode;
        public uint dwCheckPoint;
        public uint dwWaitHint;
        public uint dwProcessId;
        public uint dwServiceFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WTS_SESSION_INFO
    {
        public int SessionId;
        public IntPtr pWinStationName;
        public WTS_CONNECTSTATE_CLASS State;
    }

    private enum WTS_CONNECTSTATE_CLASS
    {
        WTSActive = 0,
        WTSConnected = 1,
        WTSConnectQuery = 2,
        WTSShadow = 3,
        WTSDisconnected = 4,
        WTSIdle = 5,
        WTSListen = 6,
        WTSReset = 7,
        WTSDown = 8,
        WTSInit = 9
    }

    private enum SECURITY_IMPERSONATION_LEVEL
    {
        SecurityAnonymous = 0,
        SecurityIdentification = 1,
        SecurityImpersonation = 2,
        SecurityDelegation = 3
    }

    private enum TOKEN_TYPE
    {
        TokenPrimary = 1,
        TokenImpersonation = 2
    }

    private enum TOKEN_INFORMATION_CLASS
    {
        TokenUser = 1,
        TokenPrivileges = 3,
        TokenOwner = 4,
        TokenDefaultDacl = 6,
        TokenSessionId = 12,
        TokenLinkedToken = 19,
        TokenVirtualizationEnabled = 24,
        TokenIntegrityLevel = 25
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_LINKED_TOKEN
    {
        public IntPtr LinkedToken;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_OWNER
    {
        public IntPtr Owner;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_DEFAULT_DACL
    {
        public IntPtr DefaultDacl;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_USER
    {
        public SID_AND_ATTRIBUTES User;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_MANDATORY_LABEL
    {
        public SID_AND_ATTRIBUTES Label;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SID_AND_ATTRIBUTES
    {
        public IntPtr Sid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ACL
    {
        public byte AclRevision;
        public byte Sbz1;
        public ushort AclSize;
        public ushort AceCount;
        public ushort Sbz2;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ACE_HEADER
    {
        public byte AceType;
        public byte AceFlags;
        public ushort AceSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ACCESS_ALLOWED_ACE
    {
        public ACE_HEADER Header;
        public uint Mask;
        public uint SidStart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct LUID_AND_ATTRIBUTES
    {
        public LUID Luid;
        public uint Attributes;
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr hThread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetPriorityClass(IntPtr hProcess, uint dwPriorityClass);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObjectEx(IntPtr hHandle, uint dwMilliseconds, bool bAlertable);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out int lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeValueW(string lpSystemName, string lpName, out LUID lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(
        IntPtr TokenHandle,
        bool DisableAllPrivileges,
        IntPtr NewState,
        int BufferLength,
        IntPtr PreviousState,
        IntPtr ReturnLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(
        IntPtr hExistingToken,
        uint dwDesiredAccess,
        IntPtr lpTokenAttributes,
        SECURITY_IMPERSONATION_LEVEL ImpersonationLevel,
        TOKEN_TYPE TokenType,
        out IntPtr phNewToken);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetThreadToken(IntPtr Thread, IntPtr Token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr TokenHandle,
        TOKEN_INFORMATION_CLASS TokenInformationClass,
        IntPtr TokenInformation,
        int TokenInformationLength,
        out int ReturnLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetTokenInformation(
        IntPtr TokenHandle,
        TOKEN_INFORMATION_CLASS TokenInformationClass,
        IntPtr TokenInformation,
        int TokenInformationLength);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessWithTokenW(
        IntPtr hToken,
        uint dwLogonFlags,
        string lpApplicationName,
        StringBuilder lpCommandLine,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CreateRestrictedToken(
        IntPtr ExistingTokenHandle,
        uint Flags,
        uint DisableSidCount,
        IntPtr SidsToDisable,
        uint DeletePrivilegeCount,
        IntPtr PrivilegesToDelete,
        uint RestrictedSidCount,
        IntPtr SidsToRestrict,
        out IntPtr NewTokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool ConvertStringSidToSidW(string StringSid, out IntPtr Sid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool InitializeAcl(IntPtr pAcl, int nAclLength, uint dwAclRevision);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AddAccessAllowedAce(IntPtr pAcl, uint dwAclRevision, uint AccessMask, IntPtr pSid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetAce(IntPtr pAcl, int dwAceIndex, out IntPtr pAce);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AddAce(IntPtr pAcl, uint dwAceRevision, uint dwStartingAceIndex, IntPtr pAceList, uint nAceListLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool IsWellKnownSid(IntPtr pSid, int WellKnownSidType);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int GetLengthSid(IntPtr pSid);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr OpenSCManagerW(string lpMachineName, string lpDatabaseName, uint dwDesiredAccess);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr OpenServiceW(IntPtr hSCManager, string lpServiceName, uint dwDesiredAccess);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool QueryServiceStatusEx(
        IntPtr hService,
        int InfoLevel,
        IntPtr lpBuffer,
        int cbBufSize,
        out int pcbBytesNeeded);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CloseServiceHandle(IntPtr hSCObject);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQueryUserToken(uint SessionId, out IntPtr phToken);

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSEnumerateSessionsW(
        IntPtr hServer,
        int Reserved,
        int Version,
        out IntPtr ppSessionInfo,
        out int pCount);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr pMemory);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool CreateEnvironmentBlock(out IntPtr lpEnvironment, IntPtr hToken, bool bInherit);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool DestroyEnvironmentBlock(IntPtr lpEnvironment);

    private static void ThrowWin32(string apiName)
    {
        int code = Marshal.GetLastWin32Error();
        throw new InvalidOperationException(string.Format(
            "{0} failed with Win32 error {1} ({2}).",
            apiName,
            code,
            new Win32Exception(code).Message));
    }

    private static void CloseHandleIfNeeded(ref IntPtr handle)
    {
        if (handle != IntPtr.Zero)
        {
            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }

    private static void CloseServiceHandleIfNeeded(ref IntPtr handle)
    {
        if (handle != IntPtr.Zero)
        {
            CloseServiceHandle(handle);
            handle = IntPtr.Zero;
        }
    }

    private static uint GetActiveSessionId()
    {
        IntPtr sessionInfo = IntPtr.Zero;
        int count = 0;
        try
        {
            if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out sessionInfo, out count))
            {
                return unchecked((uint)Process.GetCurrentProcess().SessionId);
            }

            int structSize = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
            for (int i = 0; i < count; ++i)
            {
                IntPtr item = new IntPtr(sessionInfo.ToInt64() + (long)(i * structSize));
                WTS_SESSION_INFO info = (WTS_SESSION_INFO)Marshal.PtrToStructure(item, typeof(WTS_SESSION_INFO));
                if (info.State == WTS_CONNECTSTATE_CLASS.WTSActive)
                {
                    return unchecked((uint)info.SessionId);
                }
            }
        }
        finally
        {
            if (sessionInfo != IntPtr.Zero)
            {
                WTSFreeMemory(sessionInfo);
            }
        }
        
        return unchecked((uint)Process.GetCurrentProcess().SessionId);
    }

    private static IntPtr GetTokenInformationBuffer(IntPtr tokenHandle, TOKEN_INFORMATION_CLASS infoClass)
    {
        int length = 0;
        GetTokenInformation(tokenHandle, infoClass, IntPtr.Zero, 0, out length);
        int error = Marshal.GetLastWin32Error();
        if (error != ERROR_INSUFFICIENT_BUFFER || length <= 0)
        {
            throw new InvalidOperationException(string.Format(
                "GetTokenInformation({0}) failed with Win32 error {1} ({2}).",
                infoClass,
                error,
                new Win32Exception(error).Message));
        }

        IntPtr buffer = Marshal.AllocHGlobal(length);
        try
        {
            if (!GetTokenInformation(tokenHandle, infoClass, buffer, length, out length))
            {
                ThrowWin32("GetTokenInformation");
            }

            return buffer;
        }
        catch
        {
            Marshal.FreeHGlobal(buffer);
            throw;
        }
    }

    private static void EnablePrivilege(IntPtr tokenHandle, string privilegeName)
    {
        LUID luid;
        if (!LookupPrivilegeValueW(null, privilegeName, out luid))
        {
            ThrowWin32("LookupPrivilegeValueW");
        }

        int elementSize = Marshal.SizeOf(typeof(LUID_AND_ATTRIBUTES));
        int bufferSize = sizeof(int) + elementSize;
        IntPtr buffer = Marshal.AllocHGlobal(bufferSize);
        try
        {
            for (int i = 0; i < bufferSize; ++i)
            {
                Marshal.WriteByte(buffer, i, 0);
            }

            Marshal.WriteInt32(buffer, 1);
            LUID_AND_ATTRIBUTES privilege = new LUID_AND_ATTRIBUTES();
            privilege.Luid = luid;
            privilege.Attributes = SE_PRIVILEGE_ENABLED;
            Marshal.StructureToPtr(privilege, new IntPtr(buffer.ToInt64() + sizeof(int)), false);

            if (!AdjustTokenPrivileges(tokenHandle, false, buffer, bufferSize, IntPtr.Zero, IntPtr.Zero))
            {
                ThrowWin32("AdjustTokenPrivileges");
            }

            int lastError = Marshal.GetLastWin32Error();
            if (lastError == ERROR_NOT_ALL_ASSIGNED)
            {
                throw new InvalidOperationException(string.Format(
                    "AdjustTokenPrivileges failed with Win32 error {0} ({1}).",
                    lastError,
                    new Win32Exception(lastError).Message));
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static void AdjustTokenAllPrivileges(IntPtr tokenHandle, uint attributes)
    {
        IntPtr existingPrivileges = IntPtr.Zero;
        IntPtr replacement = IntPtr.Zero;
        try
        {
            existingPrivileges = GetTokenInformationBuffer(tokenHandle, TOKEN_INFORMATION_CLASS.TokenPrivileges);
            int privilegeCount = Marshal.ReadInt32(existingPrivileges);
            if (privilegeCount <= 0)
            {
                return;
            }

            int elementSize = Marshal.SizeOf(typeof(LUID_AND_ATTRIBUTES));
            int bufferSize = sizeof(int) + (privilegeCount * elementSize);
            replacement = Marshal.AllocHGlobal(bufferSize);
            for (int i = 0; i < bufferSize; ++i)
            {
                Marshal.WriteByte(replacement, i, 0);
            }

            Marshal.WriteInt32(replacement, privilegeCount);
            for (int i = 0; i < privilegeCount; ++i)
            {
                IntPtr sourceItem = new IntPtr(existingPrivileges.ToInt64() + sizeof(int) + (long)(i * elementSize));
                LUID_AND_ATTRIBUTES item = (LUID_AND_ATTRIBUTES)Marshal.PtrToStructure(sourceItem, typeof(LUID_AND_ATTRIBUTES));
                item.Attributes = attributes;
                Marshal.StructureToPtr(item, new IntPtr(replacement.ToInt64() + sizeof(int) + (long)(i * elementSize)), false);
            }

            if (!AdjustTokenPrivileges(tokenHandle, false, replacement, bufferSize, IntPtr.Zero, IntPtr.Zero))
            {
                ThrowWin32("AdjustTokenPrivileges");
            }

            int lastError = Marshal.GetLastWin32Error();
            if (lastError == ERROR_NOT_ALL_ASSIGNED)
            {
                throw new InvalidOperationException(string.Format(
                    "AdjustTokenPrivileges failed with Win32 error {0} ({1}).",
                    lastError,
                    new Win32Exception(lastError).Message));
            }
        }
        finally
        {
            if (existingPrivileges != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(existingPrivileges);
            }

            if (replacement != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(replacement);
            }
        }
    }

    private static string GetMandatoryLabelSid(NSudoMandatoryLabelType mandatoryLabel)
    {
        switch (mandatoryLabel)
        {
            case NSudoMandatoryLabelType.Low:
                return "S-1-16-4096";
            case NSudoMandatoryLabelType.Medium:
                return "S-1-16-8192";
            case NSudoMandatoryLabelType.High:
                return "S-1-16-12288";
            case NSudoMandatoryLabelType.System:
                return "S-1-16-16384";
            default:
                return null;
        }
    }

    private static void SetMandatoryLabel(IntPtr tokenHandle, NSudoMandatoryLabelType mandatoryLabel)
    {
        string sidString = GetMandatoryLabelSid(mandatoryLabel);
        if (string.IsNullOrEmpty(sidString))
        {
            return;
        }

        IntPtr sid = IntPtr.Zero;
        IntPtr labelBuffer = IntPtr.Zero;
        try
        {
            if (!ConvertStringSidToSidW(sidString, out sid))
            {
                ThrowWin32("ConvertStringSidToSidW");
            }

            TOKEN_MANDATORY_LABEL label = new TOKEN_MANDATORY_LABEL();
            label.Label.Sid = sid;
            label.Label.Attributes = SE_GROUP_INTEGRITY;

            int labelSize = Marshal.SizeOf(typeof(TOKEN_MANDATORY_LABEL));
            labelBuffer = Marshal.AllocHGlobal(labelSize);
            Marshal.StructureToPtr(label, labelBuffer, false);
            if (!SetTokenInformation(tokenHandle, TOKEN_INFORMATION_CLASS.TokenIntegrityLevel, labelBuffer, labelSize))
            {
                ThrowWin32("SetTokenInformation(TokenIntegrityLevel)");
            }
        }
        finally
        {
            if (labelBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(labelBuffer);
            }

            if (sid != IntPtr.Zero)
            {
                LocalFree(sid);
            }
        }
    }

    private static IntPtr CreateSystemToken(uint desiredAccess, uint sessionId)
    {
        int lsassPid = 0;
        int winlogonPid = 0;

        Process[] lsassProcesses = Process.GetProcessesByName("lsass");
        foreach (Process process in lsassProcesses)
        {
            try
            {
                if (process.SessionId == 0)
                {
                    lsassPid = process.Id;
                    break;
                }
            }
            finally
            {
                process.Dispose();
            }
        }

        Process[] winlogonProcesses = Process.GetProcessesByName("winlogon");
        foreach (Process process in winlogonProcesses)
        {
            try
            {
                if (process.SessionId == unchecked((int)sessionId))
                {
                    winlogonPid = process.Id;
                    break;
                }
            }
            finally
            {
                process.Dispose();
            }
        }

        if (lsassPid == 0 && winlogonPid == 0)
        {
            throw new InvalidOperationException(string.Format(
                "CreateSystemToken failed with Win32 error {0} ({1}).",
                ERROR_INVALID_PARAMETER,
                new Win32Exception(ERROR_INVALID_PARAMETER).Message));
        }

        IntPtr processHandle = IntPtr.Zero;
        IntPtr processToken = IntPtr.Zero;
        try
        {
            if (lsassPid != 0)
            {
                processHandle = OpenProcess(PROCESS_QUERY_INFORMATION, false, unchecked((uint)lsassPid));
            }

            if (processHandle == IntPtr.Zero && winlogonPid != 0)
            {
                processHandle = OpenProcess(PROCESS_QUERY_INFORMATION, false, unchecked((uint)winlogonPid));
            }

            if (processHandle == IntPtr.Zero)
            {
                ThrowWin32("OpenProcess");
            }

            if (!OpenProcessToken(processHandle, TOKEN_DUPLICATE, out processToken))
            {
                ThrowWin32("OpenProcessToken");
            }

            IntPtr duplicatedToken;
            if (!DuplicateTokenEx(
                processToken,
                desiredAccess,
                IntPtr.Zero,
                SECURITY_IMPERSONATION_LEVEL.SecurityIdentification,
                TOKEN_TYPE.TokenPrimary,
                out duplicatedToken))
            {
                ThrowWin32("DuplicateTokenEx");
            }

            return duplicatedToken;
        }
        finally
        {
            CloseHandleIfNeeded(ref processToken);
            CloseHandleIfNeeded(ref processHandle);
        }
    }

    private static IntPtr OpenServiceProcessToken(string serviceName, uint desiredAccess)
    {
        IntPtr scmHandle = IntPtr.Zero;
        IntPtr serviceHandle = IntPtr.Zero;
        IntPtr statusBuffer = IntPtr.Zero;
        IntPtr processHandle = IntPtr.Zero;
        IntPtr tokenHandle = IntPtr.Zero;

        try
        {
            scmHandle = OpenSCManagerW(null, null, SC_MANAGER_CONNECT);
            if (scmHandle == IntPtr.Zero)
            {
                ThrowWin32("OpenSCManagerW");
            }

            serviceHandle = OpenServiceW(scmHandle, serviceName, SERVICE_QUERY_STATUS);
            if (serviceHandle == IntPtr.Zero)
            {
                ThrowWin32("OpenServiceW");
            }

            int statusSize = Marshal.SizeOf(typeof(SERVICE_STATUS_PROCESS));
            int bytesNeeded = 0;
            statusBuffer = Marshal.AllocHGlobal(statusSize);
            if (!QueryServiceStatusEx(serviceHandle, SC_STATUS_PROCESS_INFO, statusBuffer, statusSize, out bytesNeeded))
            {
                ThrowWin32("QueryServiceStatusEx");
            }

            SERVICE_STATUS_PROCESS status =
                (SERVICE_STATUS_PROCESS)Marshal.PtrToStructure(statusBuffer, typeof(SERVICE_STATUS_PROCESS));
            if (status.dwProcessId == 0)
            {
                throw new InvalidOperationException(string.Format(
                    "QueryServiceStatusEx failed with Win32 error {0} ({1}).",
                    ERROR_SERVICE_NOT_ACTIVE,
                    new Win32Exception(ERROR_SERVICE_NOT_ACTIVE).Message));
            }

            processHandle = OpenProcess(PROCESS_QUERY_INFORMATION, false, status.dwProcessId);
            if (processHandle == IntPtr.Zero)
            {
                ThrowWin32("OpenProcess");
            }

            if (!OpenProcessToken(processHandle, desiredAccess, out tokenHandle))
            {
                ThrowWin32("OpenProcessToken");
            }

            return tokenHandle;
        }
        finally
        {
            if (statusBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(statusBuffer);
            }

            CloseHandleIfNeeded(ref processHandle);
            CloseServiceHandleIfNeeded(ref serviceHandle);
            CloseServiceHandleIfNeeded(ref scmHandle);
        }
    }

    private static IntPtr CreateSessionToken(uint sessionId)
    {
        IntPtr tokenHandle;
        if (!WTSQueryUserToken(sessionId, out tokenHandle))
        {
            ThrowWin32("WTSQueryUserToken");
        }

        return tokenHandle;
    }

    private static IntPtr CreateCurrentUserElevatedToken(uint sessionId)
    {
        IntPtr sessionToken = IntPtr.Zero;
        IntPtr linkedTokenHandle = IntPtr.Zero;
        try
        {
            sessionToken = CreateSessionToken(sessionId);
            IntPtr linkedTokenBuffer = GetTokenInformationBuffer(sessionToken, TOKEN_INFORMATION_CLASS.TokenLinkedToken);
            try
            {
                TOKEN_LINKED_TOKEN linked =
                    (TOKEN_LINKED_TOKEN)Marshal.PtrToStructure(linkedTokenBuffer, typeof(TOKEN_LINKED_TOKEN));
                linkedTokenHandle = linked.LinkedToken;
                IntPtr duplicatedToken;
                if (!DuplicateTokenEx(
                    linkedTokenHandle,
                    MAXIMUM_ALLOWED,
                    IntPtr.Zero,
                    SECURITY_IMPERSONATION_LEVEL.SecurityIdentification,
                    TOKEN_TYPE.TokenPrimary,
                    out duplicatedToken))
                {
                    ThrowWin32("DuplicateTokenEx");
                }

                return duplicatedToken;
            }
            finally
            {
                Marshal.FreeHGlobal(linkedTokenBuffer);
            }
        }
        finally
        {
            CloseHandleIfNeeded(ref linkedTokenHandle);
            CloseHandleIfNeeded(ref sessionToken);
        }
    }

    private static IntPtr CreateLUAToken(IntPtr existingToken)
    {
        IntPtr luaToken = IntPtr.Zero;
        IntPtr userBuffer = IntPtr.Zero;
        IntPtr defaultDaclBuffer = IntPtr.Zero;
        IntPtr ownerBuffer = IntPtr.Zero;
        IntPtr newTokenDefaultDaclBuffer = IntPtr.Zero;
        IntPtr virtualizationBuffer = IntPtr.Zero;

        try
        {
            if (!CreateRestrictedToken(
                existingToken,
                LUA_TOKEN,
                0,
                IntPtr.Zero,
                0,
                IntPtr.Zero,
                0,
                IntPtr.Zero,
                out luaToken))
            {
                ThrowWin32("CreateRestrictedToken");
            }

            SetMandatoryLabel(luaToken, NSudoMandatoryLabelType.Medium);

            userBuffer = GetTokenInformationBuffer(luaToken, TOKEN_INFORMATION_CLASS.TokenUser);
            TOKEN_USER tokenUser = (TOKEN_USER)Marshal.PtrToStructure(userBuffer, typeof(TOKEN_USER));

            TOKEN_OWNER owner = new TOKEN_OWNER();
            owner.Owner = tokenUser.User.Sid;
            ownerBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(TOKEN_OWNER)));
            Marshal.StructureToPtr(owner, ownerBuffer, false);
            if (!SetTokenInformation(luaToken, TOKEN_INFORMATION_CLASS.TokenOwner, ownerBuffer, Marshal.SizeOf(typeof(TOKEN_OWNER))))
            {
                ThrowWin32("SetTokenInformation(TokenOwner)");
            }

            defaultDaclBuffer = GetTokenInformationBuffer(luaToken, TOKEN_INFORMATION_CLASS.TokenDefaultDacl);
            TOKEN_DEFAULT_DACL tokenDefaultDacl =
                (TOKEN_DEFAULT_DACL)Marshal.PtrToStructure(defaultDaclBuffer, typeof(TOKEN_DEFAULT_DACL));

            ACL existingAcl = new ACL();
            ushort existingAclSize = 0;
            byte aclRevision = (byte)ACL_REVISION;
            if (tokenDefaultDacl.DefaultDacl != IntPtr.Zero)
            {
                existingAcl = (ACL)Marshal.PtrToStructure(tokenDefaultDacl.DefaultDacl, typeof(ACL));
                existingAclSize = existingAcl.AclSize;
                aclRevision = existingAcl.AclRevision;
            }

            int requiredAclBytes = existingAclSize;
            if (requiredAclBytes == 0)
            {
                requiredAclBytes = Marshal.SizeOf(typeof(ACL));
            }
            requiredAclBytes += GetLengthSid(tokenUser.User.Sid);
            requiredAclBytes += Marshal.SizeOf(typeof(ACCESS_ALLOWED_ACE));

            int tokenDefaultDaclStructSize = Marshal.SizeOf(typeof(TOKEN_DEFAULT_DACL));
            newTokenDefaultDaclBuffer = Marshal.AllocHGlobal(tokenDefaultDaclStructSize + requiredAclBytes);
            IntPtr newAcl = new IntPtr(newTokenDefaultDaclBuffer.ToInt64() + tokenDefaultDaclStructSize);

            TOKEN_DEFAULT_DACL newDefaultDacl = new TOKEN_DEFAULT_DACL();
            newDefaultDacl.DefaultDacl = newAcl;
            Marshal.StructureToPtr(newDefaultDacl, newTokenDefaultDaclBuffer, false);

            if (!InitializeAcl(newAcl, requiredAclBytes, aclRevision))
            {
                ThrowWin32("InitializeAcl");
            }

            if (!AddAccessAllowedAce(newAcl, aclRevision, GENERIC_ALL, tokenUser.User.Sid))
            {
                ThrowWin32("AddAccessAllowedAce");
            }

            if (tokenDefaultDacl.DefaultDacl != IntPtr.Zero)
            {
                for (int i = 0; ; ++i)
                {
                    IntPtr ace;
                    if (!GetAce(tokenDefaultDacl.DefaultDacl, i, out ace))
                    {
                        break;
                    }

                    ACCESS_ALLOWED_ACE aceData =
                        (ACCESS_ALLOWED_ACE)Marshal.PtrToStructure(ace, typeof(ACCESS_ALLOWED_ACE));
                    IntPtr aceSid =
                        new IntPtr(ace.ToInt64() + Marshal.OffsetOf(typeof(ACCESS_ALLOWED_ACE), "SidStart").ToInt64());
                    if (IsWellKnownSid(aceSid, WinBuiltinAdministratorsSid))
                    {
                        continue;
                    }

                    if (!AddAce(newAcl, aclRevision, unchecked((uint)-1), ace, aceData.Header.AceSize))
                    {
                        ThrowWin32("AddAce");
                    }
                }
            }

            if (!SetTokenInformation(
                luaToken,
                TOKEN_INFORMATION_CLASS.TokenDefaultDacl,
                newTokenDefaultDaclBuffer,
                tokenDefaultDaclStructSize + requiredAclBytes))
            {
                ThrowWin32("SetTokenInformation(TokenDefaultDacl)");
            }

            virtualizationBuffer = Marshal.AllocHGlobal(sizeof(int));
            Marshal.WriteInt32(virtualizationBuffer, 1);
            if (!SetTokenInformation(
                luaToken,
                TOKEN_INFORMATION_CLASS.TokenVirtualizationEnabled,
                virtualizationBuffer,
                sizeof(int)))
            {
                ThrowWin32("SetTokenInformation(TokenVirtualizationEnabled)");
            }

            IntPtr completedToken = luaToken;
            luaToken = IntPtr.Zero;
            return completedToken;
        }
        finally
        {
            if (virtualizationBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(virtualizationBuffer);
            }

            if (newTokenDefaultDaclBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(newTokenDefaultDaclBuffer);
            }

            if (ownerBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(ownerBuffer);
            }

            if (defaultDaclBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(defaultDaclBuffer);
            }

            if (userBuffer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(userBuffer);
            }

            CloseHandleIfNeeded(ref luaToken);
        }
    }

    private static IntPtr GetOriginalToken(NSudoUserModeType userMode, uint sessionId)
    {
        switch (userMode)
        {
            case NSudoUserModeType.TrustedInstaller:
                return OpenServiceProcessToken("TrustedInstaller", MAXIMUM_ALLOWED);
            case NSudoUserModeType.System:
                return CreateSystemToken(MAXIMUM_ALLOWED, sessionId);
            case NSudoUserModeType.CurrentUser:
                return CreateSessionToken(sessionId);
            case NSudoUserModeType.CurrentUserElevated:
                return CreateCurrentUserElevatedToken(sessionId);
            case NSudoUserModeType.CurrentProcess:
            {
                IntPtr currentToken;
                if (!OpenProcessToken(GetCurrentProcess(), MAXIMUM_ALLOWED, out currentToken))
                {
                    ThrowWin32("OpenProcessToken");
                }

                return currentToken;
            }
            case NSudoUserModeType.CurrentProcessDropRight:
            {
                IntPtr currentToken;
                if (!OpenProcessToken(GetCurrentProcess(), MAXIMUM_ALLOWED, out currentToken))
                {
                    ThrowWin32("OpenProcessToken");
                }

                try
                {
                    return CreateLUAToken(currentToken);
                }
                finally
                {
                    CloseHandleIfNeeded(ref currentToken);
                }
            }
            default:
                throw new InvalidOperationException("Unsupported NSudo user mode.");
        }
    }

    private static short GetShowWindowMode(NSudoShowWindowModeType showWindowMode)
    {
        switch (showWindowMode)
        {
            case NSudoShowWindowModeType.Show:
                return 5;
            case NSudoShowWindowModeType.Hide:
                return 0;
            case NSudoShowWindowModeType.Maximize:
                return 3;
            case NSudoShowWindowModeType.Minimize:
                return 6;
            default:
                return 10;
        }
    }

    private static uint GetPriorityClass(NSudoProcessPriorityClassType priorityClass)
    {
        switch (priorityClass)
        {
            case NSudoProcessPriorityClassType.Idle:
                return 0x00000040;
            case NSudoProcessPriorityClassType.BelowNormal:
                return 0x00004000;
            case NSudoProcessPriorityClassType.AboveNormal:
                return 0x00008000;
            case NSudoProcessPriorityClassType.High:
                return 0x00000080;
            case NSudoProcessPriorityClassType.RealTime:
                return 0x00000100;
            default:
                return 0x00000020;
        }
    }

    public static NSudoLaunchResult Launch(
        NSudoUserModeType userMode,
        NSudoPrivilegesModeType privilegesMode,
        NSudoMandatoryLabelType mandatoryLabel,
        NSudoProcessPriorityClassType priorityClass,
        NSudoShowWindowModeType showWindowMode,
        uint waitMilliseconds,
        bool useCurrentConsole,
        string commandLine,
        string currentDirectory,
        string windowTitle)
    {
        if (string.IsNullOrWhiteSpace(commandLine))
        {
            throw new ArgumentException("Command line is required.", "commandLine");
        }

        IntPtr currentProcessToken = IntPtr.Zero;
        IntPtr duplicatedCurrentProcessToken = IntPtr.Zero;
        IntPtr originalSystemToken = IntPtr.Zero;
        IntPtr systemToken = IntPtr.Zero;
        IntPtr originalToken = IntPtr.Zero;
        IntPtr primaryToken = IntPtr.Zero;
        IntPtr environment = IntPtr.Zero;
        PROCESS_INFORMATION processInfo = new PROCESS_INFORMATION();
        bool processCreated = false;
        bool threadTokenAssigned = false;

        try
        {
            uint sessionId = GetActiveSessionId();

            if (!OpenProcessToken(GetCurrentProcess(), MAXIMUM_ALLOWED, out currentProcessToken))
            {
                ThrowWin32("OpenProcessToken");
            }

            if (!DuplicateTokenEx(currentProcessToken, MAXIMUM_ALLOWED, IntPtr.Zero, SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation, TOKEN_TYPE.TokenImpersonation, out duplicatedCurrentProcessToken))
            {
                ThrowWin32("DuplicateTokenEx");
            }

            EnablePrivilege(duplicatedCurrentProcessToken, "SeDebugPrivilege");
            if (!SetThreadToken(IntPtr.Zero, duplicatedCurrentProcessToken))
            {
                ThrowWin32("SetThreadToken");
            }
            threadTokenAssigned = true;

            originalSystemToken = CreateSystemToken(MAXIMUM_ALLOWED, sessionId);
            if (!DuplicateTokenEx(originalSystemToken, MAXIMUM_ALLOWED, IntPtr.Zero, SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation, TOKEN_TYPE.TokenImpersonation, out systemToken))
            {
                ThrowWin32("DuplicateTokenEx");
            }

            AdjustTokenAllPrivileges(systemToken, SE_PRIVILEGE_ENABLED);
            if (!SetThreadToken(IntPtr.Zero, systemToken))
            {
                ThrowWin32("SetThreadToken");
            }

            originalToken = GetOriginalToken(userMode, sessionId);
            if (!DuplicateTokenEx(originalToken, MAXIMUM_ALLOWED, IntPtr.Zero, SECURITY_IMPERSONATION_LEVEL.SecurityIdentification, TOKEN_TYPE.TokenPrimary, out primaryToken))
            {
                ThrowWin32("DuplicateTokenEx");
            }

            IntPtr sessionBuffer = Marshal.AllocHGlobal(sizeof(uint));
            try
            {
                Marshal.WriteInt32(sessionBuffer, unchecked((int)sessionId));
                if (!SetTokenInformation(primaryToken, TOKEN_INFORMATION_CLASS.TokenSessionId, sessionBuffer, sizeof(uint)))
                {
                    ThrowWin32("SetTokenInformation(TokenSessionId)");
                }
            }
            finally
            {
                Marshal.FreeHGlobal(sessionBuffer);
            }

            switch (privilegesMode)
            {
                case NSudoPrivilegesModeType.EnableAll:
                    AdjustTokenAllPrivileges(primaryToken, SE_PRIVILEGE_ENABLED);
                    break;
                case NSudoPrivilegesModeType.DisableAll:
                    AdjustTokenAllPrivileges(primaryToken, 0);
                    break;
            }

            SetMandatoryLabel(primaryToken, mandatoryLabel);

            if (!CreateEnvironmentBlock(out environment, primaryToken, true))
            {
                ThrowWin32("CreateEnvironmentBlock");
            }

            STARTUPINFO startupInfo = new STARTUPINFO();
            startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            startupInfo.lpDesktop = @"WinSta0\Default";
            startupInfo.lpTitle = string.IsNullOrWhiteSpace(windowTitle) ? null : windowTitle;
            startupInfo.dwFlags = STARTF_USESHOWWINDOW;
            startupInfo.wShowWindow = GetShowWindowMode(showWindowMode);

            uint creationFlags = CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT;
            if (!useCurrentConsole)
            {
                creationFlags |= CREATE_NEW_CONSOLE;
            }

            StringBuilder mutableCommandLine = new StringBuilder(Environment.ExpandEnvironmentVariables(commandLine));
            
            // Usiamo CreateProcessWithTokenW (moderno e sicuro per i Thread Impersonati) per prevenire l'errore 1314
            uint LOGON_WITH_PROFILE = 1;
            if (!CreateProcessWithTokenW(primaryToken, LOGON_WITH_PROFILE, null, mutableCommandLine, creationFlags, environment, string.IsNullOrWhiteSpace(currentDirectory) ? null : currentDirectory, ref startupInfo, out processInfo))
            {
                ThrowWin32("CreateProcessWithTokenW");
            }
            processCreated = true;

            SetPriorityClass(processInfo.hProcess, GetPriorityClass(priorityClass));
            if (ResumeThread(processInfo.hThread) == WAIT_FAILED)
            {
                ThrowWin32("ResumeThread");
            }

            NSudoLaunchResult result = new NSudoLaunchResult();
            result.ProcessId = unchecked((int)processInfo.dwProcessId);
            result.ExitCode = 0;
            result.Waited = (waitMilliseconds != 0);

            if (waitMilliseconds != 0)
            {
                uint waitResult = WaitForSingleObjectEx(processInfo.hProcess, waitMilliseconds, false);
                if (waitResult == WAIT_FAILED)
                {
                    ThrowWin32("WaitForSingleObjectEx");
                }

                int exitCode;
                if (GetExitCodeProcess(processInfo.hProcess, out exitCode))
                {
                    result.ExitCode = exitCode;
                }
            }

            return result;
        }
        finally
        {
            if (processCreated)
            {
                CloseHandleIfNeeded(ref processInfo.hThread);
                CloseHandleIfNeeded(ref processInfo.hProcess);
            }

            if (environment != IntPtr.Zero)
            {
                DestroyEnvironmentBlock(environment);
                environment = IntPtr.Zero;
            }

            CloseHandleIfNeeded(ref primaryToken);
            CloseHandleIfNeeded(ref originalToken);
            CloseHandleIfNeeded(ref systemToken);
            CloseHandleIfNeeded(ref originalSystemToken);
            CloseHandleIfNeeded(ref duplicatedCurrentProcessToken);
            CloseHandleIfNeeded(ref currentProcessToken);

            if (threadTokenAssigned)
            {
                SetThreadToken(IntPtr.Zero, IntPtr.Zero);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $source
}

function Ensure-TrustedInstallerServiceRunning {
    $restoreDisabled = $false
    $tiService = Get-Service -Name 'TrustedInstaller' -ErrorAction Stop

    if ($tiService.StartType -eq 'Disabled') {
        Set-Service -Name 'TrustedInstaller' -StartupType Manual -ErrorAction Stop
        $restoreDisabled = $true
        $tiService.Refresh()
    }

    if ($tiService.Status -ne 'Running') {
        try { $tiService.Start() } catch {}
        try { $tiService.WaitForStatus('Running', '00:00:15') } catch {}
        $tiService.Refresh()
    }

    if ($tiService.Status -ne 'Running') {
        throw 'TrustedInstaller service is not running.'
    }

    return $restoreDisabled
}

function Resolve-CanonicalUserMode {
    param([string]$Mode)
    switch -Regex ($Mode) {
        '^TrustedInstaller$' { return 'TrustedInstaller' }
        '^System$' { return 'System' }
        '^CurrentUser$' { return 'CurrentUser' }
        '^Current User$' { return 'CurrentUser' }
        '^CurrentUserElevated$' { return 'CurrentUserElevated' }
        '^Current User \(Elevated\)$' { return 'CurrentUserElevated' }
        '^CurrentProcess$' { return 'CurrentProcess' }
        '^Current Process$' { return 'CurrentProcess' }
        '^CurrentProcessDropRight$' { return 'CurrentProcessDropRight' }
        '^Current Process \(Drop Right\)$' { return 'CurrentProcessDropRight' }
        default { throw "Unsupported user mode '$Mode'." }
    }
}

function Invoke-NSudoProcess {
    param(
        [string]$Mode,
        [string]$CommandLine,
        [ValidateSet('Default', 'EnableAll', 'DisableAll')]
        [string]$PrivilegesMode = 'Default',
        [ValidateSet('Default', 'System', 'High', 'Medium', 'Low')]
        [string]$MandatoryLabel = 'Default',
        [ValidateSet('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High', 'RealTime')]
        [string]$Priority = 'Normal',
        [ValidateSet('Default', 'Show', 'Hide', 'Maximize', 'Minimize')]
        [string]$ShowWindowMode = 'Default',
        [bool]$Wait = $false,
        [bool]$UseCurrentConsole = $false,
        [string]$CurrentDirectory = '',
        [string]$WindowTitle = ''
    )

    Ensure-NSudoNative

    $canonicalMode = Resolve-CanonicalUserMode -Mode $Mode
    $cwdToUse = if ([string]::IsNullOrWhiteSpace($CurrentDirectory)) { Get-PreservedWorkingDirectory } else { $CurrentDirectory }

    $restoreDisabledTrustedInstaller = $false
    try {
        if ($canonicalMode -eq 'TrustedInstaller') {
            $restoreDisabledTrustedInstaller = Ensure-TrustedInstallerServiceRunning
        }

        $waitMilliseconds = if ($Wait) { [uint32]::MaxValue } else { [uint32]0 }
        $result = [NSudoNativeBridge]::Launch(
            [NSudoUserModeType]::$canonicalMode,
            [NSudoPrivilegesModeType]::$PrivilegesMode,
            [NSudoMandatoryLabelType]::$MandatoryLabel,
            [NSudoProcessPriorityClassType]::$Priority,
            [NSudoShowWindowModeType]::$ShowWindowMode,
            $waitMilliseconds,
            $UseCurrentConsole,
            $CommandLine,
            $cwdToUse,
            $WindowTitle)

        if ($Wait -and $null -ne $result) {
            $global:LASTEXITCODE = $result.ExitCode
            $global:NSudoExitCode = $result.ExitCode
        }

        return $result
    }
    finally {
        if ($restoreDisabledTrustedInstaller) {
            try { Set-Service -Name 'TrustedInstaller' -StartupType Disabled -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Ensure-WinForms {
    $winFormsReady = Get-Variable -Name WinFormsReady -Scope Script -ErrorAction SilentlyContinue
    if ($winFormsReady -and $winFormsReady.Value) { return }

    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms

    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }

    if (-not ('RunAsTINativeDwm' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RunAsTINativeDwm {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
}
public static class RunAsTIIconNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
    }
    $script:WinFormsReady = $true
}

function Show-LauncherError {
    param([string]$Message)
    Ensure-WinForms
    [void][Windows.Forms.MessageBox]::Show(
        $Message, 'NSudo Launcher Error', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error
    )
}

function Format-ProcessArgumentList {
    param([string[]]$Tokens)
    if (-not $Tokens -or $Tokens.Count -eq 0) { return '' }
    $parts = foreach ($arg in $Tokens) {
        if ($null -eq $arg -or $arg -eq '') { '""' } 
        elseif ($arg -notmatch '[ \t\n\v"\\]') { $arg } 
        else {
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.Append('"')
            $bs = 0
            foreach ($ch in $arg.ToCharArray()) {
                if ($ch -eq '\') { $bs++ } 
                elseif ($ch -eq '"') { [void]$sb.Append(('\' * ($bs * 2 + 1)) + '"'); $bs = 0 } 
                else {
                    if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
                    [void]$sb.Append($ch)
                }
            }
            if ($bs -gt 0) { [void]$sb.Append('\' * ($bs * 2)) }
            [void]$sb.Append('"')
            $sb.ToString()
        }
    }
    return ($parts -join ' ')
}

function Start-SafeProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [string]$WindowStyle = 'Normal',
        [switch]$Wait,
        [string]$Verb = ''
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    if ($ArgumentList.Count -gt 0) { $psi.Arguments = Format-ProcessArgumentList $ArgumentList }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory } 
    else { $psi.WorkingDirectory = Get-PreservedWorkingDirectory }

    if ($WindowStyle -eq 'Hidden') {
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
    }
    $psi.UseShellExecute = $true
    if (-not [string]::IsNullOrWhiteSpace($Verb)) { $psi.Verb = $Verb }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()

    if ($Wait) { $process.WaitForExit() }
    $process.Dispose()
}

function Resolve-LaunchCommandLine {
    param([string]$InputText)
    $text = $InputText.Trim()
    if (-not $text) { return '' }

    $tokens = @(ConvertFrom-CommandLine $text)
    if ($tokens.Count -eq 0) { return $text }

    $exe = $tokens[0]
    $sys32 = "$env:SystemRoot\System32"

    if ($exe -match '^(?i)notepad(?:\.exe)?$') {
        $exe = "$sys32\notepad.exe"
        $tokens[0] = $exe
        $text = Format-ProcessArgumentList $tokens
    }

    if (-not (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue)) {
        $cmd = Get-Command -Name $exe -Type Application -ErrorAction SilentlyContinue
        if ($cmd) {
            if ($cmd.Source -notmatch '(?i)\\WindowsApps\\') {
                $exe = $cmd.Source
                $tokens[0] = $exe
                $text = Format-ProcessArgumentList $tokens
            }
        }
    }

    try {
        if (Test-Path -LiteralPath $exe -ErrorAction Stop) {
            $exePath = (Get-Item -LiteralPath $exe -ErrorAction Stop).FullName
            $extension = [IO.Path]::GetExtension($exePath).ToLowerInvariant()

            if ($extension -eq '.msc') {
                $newTokens = @("$sys32\mmc.exe", $exePath)
                if ($tokens.Count -gt 1) { $newTokens += $tokens[1..($tokens.Count - 1)] }
                return Format-ProcessArgumentList $newTokens
            }
            if ($extension -eq '.cmd' -or $extension -eq '.bat') {
                return "`"$sys32\cmd.exe`" /c `"" + $text + "`""
            }
            if ($extension -eq '.ps1') {
                $newTokens = @("$sys32\WindowsPowerShell\v1.0\powershell.exe", '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $exePath)
                if ($tokens.Count -gt 1) { $newTokens += $tokens[1..($tokens.Count - 1)] }
                return Format-ProcessArgumentList $newTokens
            }
        }
    } catch {}

    return $text
}

function Resolve-PresetCommand {
    param([string]$InputText)
    if ([string]::IsNullOrWhiteSpace($InputText)) { return '' }
    $sys32 = "$env:SystemRoot\System32"

    switch ($InputText.Trim()) {
        '命令提示符' { return "cmd" }
        'Command Prompt' { return "cmd" }
        'PowerShell' { return "powershell" }
        'PowerShell ISE' { return "powershell_ise" }
        'Hosts编辑' { return "notepad `"$sys32\drivers\etc\hosts`"" }
        default { return $InputText }
    }
}

function Get-PresetWindowTitle {
    param([string]$InputText)
    if ([string]::IsNullOrWhiteSpace($InputText)) { return '' }
    $trimmed = $InputText.Trim()

    switch ($trimmed) {
        '命令提示符' { return 'NSudo.Launcher' }
        'Command Prompt' { return 'NSudo.Launcher' }
        'PowerShell' { return 'NSudo.Launcher' }
        default {
            try {
                $tokens = @(ConvertFrom-CommandLine $trimmed)
                if ($tokens.Count -ne 1) { return '' }

                switch -Regex ([System.IO.Path]::GetFileName($tokens[0])) {
                    '^(?i)cmd(?:\.exe)?$' { return 'NSudo.Launcher' }
                    '^(?i)powershell(?:\.exe)?$' { return 'NSudo.Launcher' }
                    default { return '' }
                }
            } catch {
                return ''
            }
        }
    }
}

function Get-StartWrappedConsoleCommandLine {
    param(
        [string]$ResolvedCommandLine,
        [string]$WindowTitle,
        [bool]$Wait,
        [bool]$UseCurrentConsole
    )

    if ($Wait -or $UseCurrentConsole) { return '' }
    if ([string]::IsNullOrWhiteSpace($WindowTitle) -or [string]::IsNullOrWhiteSpace($ResolvedCommandLine)) { return '' }

    try {
        $tokens = @(ConvertFrom-CommandLine $ResolvedCommandLine.Trim())
        if ($tokens.Count -eq 0) { return '' }

        $fileName = [System.IO.Path]::GetFileName($tokens[0])
        
        if ($fileName -match '^(?i)(?:cmd|powershell)(?:\.exe)?$') {
            $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
            return "`"$cmdExe`" /c start `"$WindowTitle`" $ResolvedCommandLine"
        }
        
        return ''
    } catch {
        return ''
    }
}

function Start-ElevatedRun {
    param([string[]]$ArgumentTokens)
    $selfPath = Get-SelfPath
    $cwd = Get-PreservedWorkingDirectory
    
    $b64Cwd = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cwd))
    $relaunchArgs = @('--cwd', $b64Cwd) + @($ArgumentTokens)
    
    Start-SafeProcess -FilePath $selfPath -WindowStyle Hidden -Verb RunAs -ArgumentList $relaunchArgs | Out-Null
}

function Parse-LauncherArguments {
    param([string[]]$Tokens)
    $mode = $null
    $privilegesMode = 'Default'
    $mandatoryLabel = 'Default'
    $priority = 'Normal'
    $showWindowMode = 'Default'
    $wait = $false
    $useCurrentConsole = $false
    $currentDirectory = Get-PreservedWorkingDirectory
    $showHelp = $false
    $showVersion = $false
    $commandTokens = New-Object System.Collections.Generic.List[string]
    $parsingOptions = $true

    foreach ($token in $Tokens) {
        if ($parsingOptions -and $token -eq '--') { $parsingOptions = $false; continue }

        if ($parsingOptions) {
            if ($token -match '^(?:-|/)[Uu]:(.+)$') {
                switch ($matches[1].ToUpperInvariant()) {
                    'T' { $mode = 'TrustedInstaller' }
                    'S' { $mode = 'System' }
                    'C' { $mode = 'CurrentUser' }
                    'E' { $mode = 'CurrentUserElevated' }
                    'P' { $mode = 'CurrentProcess' }
                    'D' { $mode = 'CurrentProcessDropRight' }
                    default { throw "Unsupported -U option '$($matches[1])'." }
                }
                continue
            }

            if ($token -match '^(?:-|/)[Pp]:(.+)$') {
                switch ($matches[1].ToUpperInvariant()) {
                    'E' { $privilegesMode = 'EnableAll' }
                    'D' { $privilegesMode = 'DisableAll' }
                    default { throw "Unsupported -P option '$($matches[1])'." }
                }
                continue
            }

            if ($token -match '^(?:-|/)[Mm]:(.+)$') {
                switch ($matches[1].ToUpperInvariant()) {
                    'S' { $mandatoryLabel = 'System' }
                    'H' { $mandatoryLabel = 'High' }
                    'M' { $mandatoryLabel = 'Medium' }
                    'L' { $mandatoryLabel = 'Low' }
                    default { throw "Unsupported -M option '$($matches[1])'." }
                }
                continue
            }

            if ($token -match '^(?:-|/)(Wait)$') {
                $wait = $true
                continue
            }

            if ($token -match '^(?:-|/)(UseCurrentConsole)$') {
                $useCurrentConsole = $true
                continue
            }

            if ($token -match '^(?:-|/)(CurrentDirectory):(.*)$') {
                $currentDirectory = $matches[2]
                continue
            }

            if ($token -match '^(?:-|/)(Priority):(.*)$') {
                switch ($matches[2].ToUpperInvariant()) {
                    'IDLE' { $priority = 'Idle' }
                    'BELOWNORMAL' { $priority = 'BelowNormal' }
                    'NORMAL' { $priority = 'Normal' }
                    'ABOVENORMAL' { $priority = 'AboveNormal' }
                    'HIGH' { $priority = 'High' }
                    'REALTIME' { $priority = 'RealTime' }
                    default { throw "Unsupported -Priority option '$($matches[2])'." }
                }
                continue
            }

            if ($token -match '^(?:-|/)(ShowWindowMode):(.*)$') {
                switch ($matches[2].ToUpperInvariant()) {
                    'SHOW' { $showWindowMode = 'Show' }
                    'HIDE' { $showWindowMode = 'Hide' }
                    'MAXIMIZE' { $showWindowMode = 'Maximize' }
                    'MINIMIZE' { $showWindowMode = 'Minimize' }
                    default { throw "Unsupported -ShowWindowMode option '$($matches[2])'." }
                }
                continue
            }

            if ($token -match '^(?:-|/)(?:\?|H|Help)$') {
                $showHelp = $true
                continue
            }

            if ($token -match '^(?:-|/)(Version)$') {
                $showVersion = $true
                continue
            }
        }

        if ($parsingOptions) {
            $parsingOptions = $false
        }
        [void]$commandTokens.Add($token)
    }

    [pscustomobject]@{
        Mode = $mode
        PrivilegesMode = $privilegesMode
        MandatoryLabel = $mandatoryLabel
        Priority = $priority
        ShowWindowMode = $showWindowMode
        Wait = $wait
        UseCurrentConsole = $useCurrentConsole
        CurrentDirectory = $currentDirectory
        ShowHelp = $showHelp
        ShowVersion = $showVersion
        CommandLine = Join-CommandLine $commandTokens.ToArray()
    }
}

function Add-KamikazeProfile {
    param(
        [string]$TargetCwd,
        [bool]$IsSystemOrTI,
        [ValidateSet('Console', 'Ise')]
        [string]$HostKind = 'Console'
    )

    $basePath = if ($IsSystemOrTI) {
        Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0'
    } else {
        Join-Path ([Environment]::GetFolderPath('Personal')) 'WindowsPowerShell'
    }

    $targetProfile = if ($HostKind -eq 'Ise') {
        Join-Path $basePath 'Microsoft.PowerShellISE_profile.ps1'
    } else {
        Join-Path $basePath 'Microsoft.PowerShell_profile.ps1'
    }
    
    $markerId = [Guid]::NewGuid().ToString('N')
    $startMarker = "#<NSUDO_KAMIKAZE:$markerId>"
    $endMarker = "#</NSUDO_KAMIKAZE:$markerId>"
    $b64Cwd = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($TargetCwd))
    $b64TargetProfile = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($targetProfile))
    $b64StartMarker = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($startMarker))
    $b64EndMarker = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($endMarker))

    $innerScript = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$cwd = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64Cwd'))
`$targetProfile = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64TargetProfile'))
`$startMarker = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64StartMarker'))
`$endMarker = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64EndMarker'))
try { Set-Location -LiteralPath `$cwd -ErrorAction Stop } catch {}
try {
    if (`$targetProfile -and (Test-Path -LiteralPath `$targetProfile -PathType Leaf)) {
        `$utf8Bom = New-Object System.Text.UTF8Encoding `$true
        `$content = [System.IO.File]::ReadAllText(`$targetProfile, `$utf8Bom)
        `$pattern = '(?s)' + [System.Text.RegularExpressions.Regex]::Escape(`$startMarker) + '.*?' + [System.Text.RegularExpressions.Regex]::Escape(`$endMarker) + '\r?\n?'
        `$content = [System.Text.RegularExpressions.Regex]::Replace(`$content, `$pattern, '')
        if ([string]::IsNullOrWhiteSpace(`$content)) {
            [System.IO.File]::Delete(`$targetProfile)
        } else {
            [System.IO.File]::WriteAllText(`$targetProfile, `$content.TrimStart("``r``n".ToCharArray()), `$utf8Bom)
        }
    }
} catch {}
"@
    $b64Inner = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($innerScript))
    $payload = $startMarker + "`r`n& ([scriptblock]::Create([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$b64Inner'))))`r`n" + $endMarker

    $dir = Split-Path $targetProfile -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }

    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    $existing = ''
    if (Test-Path -LiteralPath $targetProfile -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($targetProfile, $utf8Bom)
        $existing = [Text.RegularExpressions.Regex]::Replace($existing, '(?s)#<NSUDO_KAMIKAZE.*?>.*?#</NSUDO_KAMIKAZE.*?>\r?\n?', '')
    }

    $newContent = $payload + "`r`n" + $existing.TrimStart("`r`n".ToCharArray())
    [System.IO.File]::WriteAllText($targetProfile, $newContent, $utf8Bom)
}

function Invoke-SelectedMode {
    param(
        [string]$Mode,
        [string]$CommandLine,
        [ValidateSet('Default', 'EnableAll', 'DisableAll')]
        [string]$PrivilegesMode = 'Default',
        [ValidateSet('Default', 'System', 'High', 'Medium', 'Low')]
        [string]$MandatoryLabel = 'Default',
        [ValidateSet('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High', 'RealTime')]
        [string]$Priority = 'Normal',
        [ValidateSet('Default', 'Show', 'Hide', 'Maximize', 'Minimize')]
        [string]$ShowWindowMode = 'Default',
        [bool]$Wait = $false,
        [bool]$UseCurrentConsole = $false,
        [string]$CurrentDirectory = ''
    )

    $cwd = if ([string]::IsNullOrWhiteSpace($CurrentDirectory)) { Get-PreservedWorkingDirectory } else { $CurrentDirectory }
    $presetResolved = Resolve-PresetCommand -InputText $CommandLine
    $windowTitle = Get-PresetWindowTitle -InputText $CommandLine
    $resolvedBare = Resolve-LaunchCommandLine -InputText $presetResolved
    $canonicalMode = Resolve-CanonicalUserMode -Mode $Mode
    
    $isPS = $false
    $isISE = $false
    try {
        $tokens = @(ConvertFrom-CommandLine $resolvedBare)
        if ($tokens.Count -gt 0) {
            $exeName = [System.IO.Path]::GetFileName($tokens[0])
            if ($exeName -match '^(?i)powershell(?:\.exe)?$') { $isPS = $true }
            if ($exeName -match '^(?i)powershell_ise(?:\.exe)?$') { $isISE = $true }
        }
    } catch {}

    if ($isPS -or $isISE) {
        $fullExePath = $null
        try { $fullExePath = (Get-Command -Name $tokens[0] -Type Application -ErrorAction Stop).Source } catch {}
        
        if (-not $fullExePath -or -not (Test-Path -LiteralPath $fullExePath -PathType Leaf)) {
            $name = if ($isISE) { "PowerShell ISE" } else { "PowerShell" }
            throw "$name is not installed or cannot be found on this system."
        }

        $isSystemOrTI = ($canonicalMode -eq 'TrustedInstaller' -or $canonicalMode -eq 'System')
        $hostKind = if ($isISE) { 'Ise' } else { 'Console' }
        Add-KamikazeProfile -TargetCwd $cwd -IsSystemOrTI $isSystemOrTI -HostKind $hostKind
        
        $resolvedBare = "`"$fullExePath`""
        if ($tokens.Count -gt 1) {
            $resolvedBare += " " + (Format-ProcessArgumentList @($tokens[1..($tokens.Count-1)]))
        }
    }

    $startWrappedCommand = Get-StartWrappedConsoleCommandLine -ResolvedCommandLine $resolvedBare -WindowTitle $windowTitle -Wait:$Wait -UseCurrentConsole:$UseCurrentConsole
    $resolved = if ([string]::IsNullOrWhiteSpace($startWrappedCommand)) { $resolvedBare } else { $startWrappedCommand }
    $processWindowTitle = if (-not [string]::IsNullOrWhiteSpace($startWrappedCommand)) { '' } else { $windowTitle }

    Invoke-NSudoProcess -Mode $canonicalMode -CommandLine $resolved -PrivilegesMode $PrivilegesMode `
        -MandatoryLabel $MandatoryLabel -Priority $Priority -ShowWindowMode $ShowWindowMode `
        -Wait:$Wait -UseCurrentConsole:$UseCurrentConsole -CurrentDirectory $cwd -WindowTitle $processWindowTitle | Out-Null
}

function Get-LauncherTitle {
    return 'M2-Team NSudo Launcher 9.0 Preview 1 (Build 2676)'
}

function Get-LauncherHelpText {
    return @(
        (Get-LauncherTitle)
        '(c) M2-Team. All rights reserved.'
        ''
        'Format: NSudoL [ Options and parameters ] Command line or ShortCut Command'
        ''
        'Options:'
        ''
        '-U:[ Option ] Create a process with specified user option.'
        'Available options:'
        '    T TrustedInstaller'
        '    S System'
        '    C Current User'
        '    E Current User (Elevated)'
        '    P Current Process'
        '    D Current Process (Drop right)'
        'PS: This is a mandatory parameter.'
        ''
        '-P:[ Option ] Create a process with specified privilege option.'
        'Available options:'
        '    E Enable All Privileges'
        '    D Disable All Privileges'
        'PS: If you want to use the default privileges to create a process, please do'
        'not include the "-P" parameter.'
        ''
        '-M:[ Option ] Create a process with specified Integrity Level option.'
        'Available options:'
        '    S System'
        '    H High'
        '    M Medium'
        '    L Low'
        'PS: If you want to use the default Integrity Level to create a process, please'
        'do not include the "-M" parameter.'
        ''
        '-Priority:[ Option ] Create a process with specified process priority option.'
        'Available options:'
        '    Idle'
        '    BelowNormal'
        '    Normal'
        '    AboveNormal'
        '    High'
        '    RealTime'
        'PS: If you want to use the default Process Priority to create a process, please'
        'do not include the "-Priority" parameter.'
        ''
        '-ShowWindowMode:[ Option ] Create a process with specified window mode option.'
        'Available options:'
        '    Show'
        '    Hide'
        '    Maximize'
        '    Minimize'
        'PS: If you want to use the default window mode to create a process, please do'
        'not include the "-ShowWindowMode" parameter.'
        ''
        '-Wait Make NSudo Launcher wait for the created process to end before exiting.'
        'PS: If you don''t want to wait, please do not include the "-Wait" parameter.'
        ''
        '-CurrentDirectory:[ DirectoryPath ] Set the current directory for the process.'
        'PS: If you want to use the NSudo Launcher''s current directory, please do not'
        'include the "-CurrentDirectory" parameter.'
        ''
        '-UseCurrentConsole Create a process with the current console window.'
        'PS: If you want to create a process with the new console window, please do not'
        'include the "-UseCurrentConsole" parameter.'
        ''
        '-Version Show version information of NSudo Launcher.'
        ''
        '-? Show this content.'
        '-H Show this content.'
        '-Help Show this content.'
        ''
        'Please use https://github.com/Thdub/NSudo_Installer for context menu management.'
        ''
        'PS:'
        '    1. All NSudo Launcher command arguments is case-insensitive.'
    ) -join "`r`n"
}

function Show-AboutBox {
    Ensure-WinForms
    $aboutText = Get-LauncherHelpText

    $isDark = $false
    try { 
        $val = Get-ItemPropertyValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' -EA Stop
        $isDark = ($val -eq 0) 
    } catch {}

    $bg = if ($isDark) { [Drawing.Color]::FromArgb(32, 32, 32) } else { [Drawing.SystemColors]::Control }
    $fg = if ($isDark) { [Drawing.Color]::White } else { [Drawing.SystemColors]::ControlText }
    $ctrlBg = if ($isDark) { [Drawing.Color]::FromArgb(45, 45, 45) } else { [Drawing.SystemColors]::Window }

    $form = New-Object Windows.Forms.Form
    $form.Text = Get-LauncherTitle
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object Drawing.Size(598, 418)
    $form.Font = New-Object Drawing.Font('Segoe UI', 9)
    $form.BackColor = $bg
    $form.ForeColor = $fg

    $textBox = New-Object Windows.Forms.RichTextBox
    $textBox.Location = New-Object Drawing.Point(12, 12)
    $textBox.Size = New-Object Drawing.Size(574, 354)
    $textBox.ReadOnly = $true
    $textBox.BorderStyle = 'FixedSingle'
    $textBox.BackColor = $ctrlBg
    $textBox.ForeColor = $fg
    $textBox.ScrollBars = 'Vertical'
    $textBox.WordWrap = $true
    $textBox.DetectUrls = $false
    $textBox.Text = $aboutText
    $form.Controls.Add($textBox)

    $okButton = New-Object Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Size = New-Object Drawing.Size(75, 27)
    $okButton.Location = New-Object Drawing.Point(511, 379)
    if ($isDark) {
        $okButton.FlatStyle = 'Flat'
        $okButton.BackColor = [Drawing.Color]::FromArgb(51, 51, 51)
        $okButton.ForeColor = $fg
        $okButton.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(100, 100, 100)
        $okButton.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(65, 65, 65)
        $okButton.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(85, 85, 85)
    } else {
        $okButton.FlatStyle = 'System'
    }
    $okButton.Add_Click({ $this.FindForm().Close() })
    $form.AcceptButton = $okButton
    $form.Controls.Add($okButton)

    $null = $form.Handle
    if ($isDark) {
        $darkVal = 1
        try {
            [RunAsTINativeDwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$darkVal, 4) | Out-Null
            [RunAsTINativeDwm]::DwmSetWindowAttribute($form.Handle, 19, [ref]$darkVal, 4) | Out-Null
        } catch {}
    }

    try {
        [void]$form.ShowDialog()
    } finally {
        $form.Dispose()
    }
}

function Show-LauncherUI {
    Ensure-WinForms
    
    $isDark = $false
    try { 
        $val = Get-ItemPropertyValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' -EA Stop
        $isDark = ($val -eq 0) 
    } catch {}

    $bg = if ($isDark) { [Drawing.Color]::FromArgb(32, 32, 32) } else { [Drawing.SystemColors]::Control }
    $fg = if ($isDark) { [Drawing.Color]::White } else { [Drawing.SystemColors]::ControlText }
    $ctrlBg = if ($isDark) { [Drawing.Color]::FromArgb(45, 45, 45) } else { [Drawing.SystemColors]::Window }

    $form = New-Object Windows.Forms.Form
    $form.Text = Get-LauncherTitle
    $form.ClientSize = New-Object Drawing.Size(449, 207)
    $form.FormBorderStyle = 'FixedDialog'
    $form.StartPosition = 'CenterScreen'
    $form.MaximizeBox = $false; $form.MinimizeBox = $true; $form.TopMost = $true
    $form.Font = New-Object Drawing.Font('Segoe UI', 9)
    $form.BackColor = $bg; $form.ForeColor = $fg

    $badge = New-Object Windows.Forms.PictureBox
    $badge.Location = New-Object Drawing.Point(15, 16); $badge.Size = New-Object Drawing.Size(64, 64)
    $badge.SizeMode = 'StretchImage'
    $b64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAABHNCSVQICAgIfAhkiAAAAKR6VFh0UmF3IHByb2ZpbGUgdHlwZSBBUFAxAAAYlX1OWwrDMAz7zyl6BPkxJzlOGNkojG30/h+zlxRaGJNxrAghO937s2/rdXlvr9v66GkJkFrSqpUbgIIBAYhBMf0dmFPIGTvJ889jWi0ZevA1nHBxh4lR9v4K4UUdObqvFfYC4phDlu4h8ltnNI2beOr5vBqmQsZmni3Oi7CpRYtUMVfwvwLpA9aoQLGQ0ZeLAAAGJElEQVR4nO2afWwURRjGn5nd++i11/ba0hYKbQ/bUkCMhRClEgNEQ4hVCaIlSIUohCjGYCAhJkTESIwakyYkVQPKRwMYjCIhERKRNMFUvgJBoCrQHoViC7Sl0N737o5/NNfSu727veveDYb7/XV3uzvzzLMz78w7c6T84wsMjzCUtwDepAzgLYA3KQN4C+BNygDeAniTMoC3AN6IehXkkxmeLLLIlEAI/EYpwcV/XZLC9KtHb3QTNrcsw7tjmd0U/PsP5+6SDw7dBCV61aQvMQ8BBoCpZA9CmJJESgSm8oDykGQgMRkgKQwvTM3Cq1U2+OThFngkBQqDapMIARvwKiNMm1Joxsb5Y+GVlDhl64fmISApDLVVOfj0pSIAgNVMUd90G0tn5GL1M3moLDCb1Z5b+EQ2mVNuxe5TPWg4fhuVBWb8vKoMAFCRb8KSnW0wi/xiMdGSDgc3PkCfW0Z2mhDmKfVyAEB8ICA0Owa4mhC1VoUBtdNDGw8gpsYDgw0Xg6JhtT0D36+YCJ/EJyhENcArKVg7Jz+hIqrtGcjN4DNTRjXAYqCo+eYqPP7EBay6Rgfuu+WElR+JqAYwAPfdMp5vuJIQAR/+chMnHE4QTusETZFHYcAbM3MSImDl02Pg9PGbDjUNPI+kYOWsMVHvu3HXx7b/0U0u3/Yg32rAi49nsecmZUZ8t8U5RswstuCvWx6NkvUlrAE+mcEkEDAA8yoyo3bRht/vKJ8c6aQZpuFOdfBCH6m2p2Pv8okRn11cZcPmw52gZLBeo5C88aC6DmAA1swew9bOLdCk5HjrAJbuakOaIXREMQa8Nt2GLTWh06gaFzvdqPn6KoxickxQjQGMATaLdgVf/Nal2ngAIATYebIHgPpSORiLkUJRSzYShOoQiNX7sx0uWIIM8PiVoYIYAzYf7iTjbYaoZfU4JfgVBuiVJzDAKNKw2aguqw8KwvCAb2kGiqPvVsDtH36TjIXJloIgAF6eZtNDFgDAKBC8s78drd1e1euqBrCAEo08W5aBU+3Ooe+UAMU2I1wcp7cAJpHCECGoqhpACdDSpX1a2rRgHOZu/WdoGHglhlX72iE/BEk/JQQdfb6w18NmgzJjcHoVAAQziy3s0OqyiH2i6Uo/W7HnGhEpgdVEcW7DlNEp15GF21rR0uVWvRZ2JSgQgkyzgEwzxZnrThKtO88pt5K2TdOwpaYIhZnRg10yidQPNS2FrWYBXx67FfU+SoDa6TYUZRu1auOO5lngbIcrrgoudbrxyretMCVxw8PtV/DrmgqU5ER/EZoMmFqYhgMrH4tLjMvP4PYrkJM4IXglBf1ebel1VANcPgXfvV4atxh7jhEb54+DkMR9cb/MUJpjGrE2CUdUA9KMFGt/uo5dy+xxicnLELGqOi+uZ0eJJsejDkwCoLnNibpGR8i1ZscA/4l+lGiKTIQAJxwjTahrdGDJjjay4KsrOPBnHzycNjVHi+ZZIGDCou2toJTgfIcLZgNFa7cX6w/cwLHL97F1cbGmshpP96Ii34SnStIBAHcGJM1BSwsiJSi2aZuKY0qGCBnM1wOfAwiUaN7X33OmFztOdGPfiuGY8tnRLuw/2xuLlIgUZBpwev1kTffqthfd45SGPgcH/Etdbvgkxlq6PGRb8x00vTdpxHWDQGAOs58QD7GUpZsBTVf7MePzFhgECnnwNHTIhqIsI2bX/41CqyGk8QCQly7CnhtysBw3uenam6WbASIl6PcqABSkG0f2gew0AUfeLidFWerjct28AqybV6CXlJhI2nHM+Ic0P3jk/yLDxYBT7U503vMntA6tq5Kkn0ieue7CW3vbsbuuFGOzBvcNNhzswI/n+3SrI98qovn9Sk33JsWAPresSDKjjl4vljdew8n1k2F94ACFUqLrf4hiSbySYoCjx0ve3HMNMkNI44HB/P2eR7+VoMXIYR0QiarxFtJQW4LKfHNI4wGgftEE1C+akAwpISQtBswqTU9WVTHxyE+DCekBDIAkM67n/gFMIoUS4XwiIQY4fQpKPrqQiKLjIs2Q4LPBYAiA9BgiMU/+HyoTSMoA3gJ4kzKAtwDepAzgLYA3KQN4C+DNf2ML5mQUue3tAAAAAElFTkSuQmCC"

    try {
        $ms = New-Object IO.MemoryStream(,[Convert]::FromBase64String($b64))
        $badge.Image = [Drawing.Image]::FromStream($ms)

        $bmpForIcon = New-Object Drawing.Bitmap($badge.Image)
        $iconHandle = $bmpForIcon.GetHicon()
        $bmpForIcon.Dispose()
        try {
            $form.Icon = [Drawing.Icon]::FromHandle($iconHandle)
        } catch {
            [RunAsTIIconNative]::DestroyIcon($iconHandle) | Out-Null
            throw
        }
    } catch {
        $bmp = New-Object Drawing.Bitmap(64, 64)
        $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::FromArgb(47, 120, 204)); $g.Dispose()
        $badge.Image = $bmp
    }
    $form.Controls.Add($badge)

    $grp = New-Object Windows.Forms.GroupBox
    $grp.Text = 'Mode Settings'; $grp.Location = New-Object Drawing.Point(102, 14)
    $grp.Size = New-Object Drawing.Size(336, 100); $grp.ForeColor = $fg
    if ($isDark) {
        $grp.Add_Paint({
            $g = $_.Graphics; $g.Clear($this.BackColor)
            $ts = $g.MeasureString($this.Text, $this.Font)
            $by = [int]($ts.Height / 2)
            $p = New-Object Drawing.Pen([Drawing.Color]::FromArgb(80, 80, 80))
            $g.DrawRectangle($p, 0, $by, $this.Width - 1, $this.Height - $by - 1); $p.Dispose()
            $b = New-Object Drawing.SolidBrush($this.BackColor); $g.FillRectangle($b, 6, 0, $ts.Width + 4, $ts.Height); $b.Dispose()
            $b2 = New-Object Drawing.SolidBrush($this.ForeColor); $g.DrawString($this.Text, $this.Font, $b2, 8, 0); $b2.Dispose()
        })
    }
    $form.Controls.Add($grp)

    $lblUser = New-Object Windows.Forms.Label
    $lblUser.Text = 'User:'; $lblUser.Location = New-Object Drawing.Point(12, 26); $lblUser.AutoSize = $true
    $grp.Controls.Add($lblUser)

    $modeBox = New-Object Windows.Forms.ComboBox
    $modeBox.DropDownStyle = 'DropDownList'; $modeBox.Location = New-Object Drawing.Point(77, 24)
    $modeBox.Size = New-Object Drawing.Size(245, 20); $modeBox.BackColor = $ctrlBg; $modeBox.ForeColor = $fg
    $modeBox.FlatStyle = if ($isDark) { 'Flat' } else { 'System' }
    [void]$modeBox.Items.AddRange(@('Current User', 'Current Process', 'System', 'TrustedInstaller'))
    $modeBox.SelectedItem = 'TrustedInstaller'
    $grp.Controls.Add($modeBox)

    $privBox = New-Object Windows.Forms.CheckBox
    $privBox.Location = New-Object Drawing.Point(14, 61); $privBox.Size = New-Object Drawing.Size(16, 16)
    $privBox.FlatStyle = if ($isDark) { 'Standard' } else { 'System' }
    $grp.Controls.Add($privBox)

    $lblPriv = New-Object Windows.Forms.Label
    $lblPriv.Text = 'Enable All Privileges'; $lblPriv.Location = New-Object Drawing.Point(26, 61); $lblPriv.AutoSize = $true
    $grp.Controls.Add($lblPriv)

    $modeBox.Add_SelectedIndexChanged({ $privBox.Enabled = $true })

    $lblOpen = New-Object Windows.Forms.Label
    $lblOpen.Text = 'Open:'; $lblOpen.Location = New-Object Drawing.Point(18, 131); $lblOpen.AutoSize = $true
    $form.Controls.Add($lblOpen)

    $pathBox = New-Object Windows.Forms.ComboBox
    $pathBox.Location = New-Object Drawing.Point(84, 128)
    $pathBox.Size = New-Object Drawing.Size(277, 23)
    $pathBox.BackColor = $ctrlBg
    $pathBox.ForeColor = $fg
    $pathBox.FlatStyle = if ($isDark) { 'Flat' } else { 'System' }
    [void]$pathBox.Items.AddRange(@('命令提示符', 'PowerShell', 'PowerShell ISE', 'Hosts编辑'))
    $form.Controls.Add($pathBox)

    function New-Btn($txt, $x, $y, $w, $h) {
        $b = New-Object Windows.Forms.Button
        $b.Text = $txt; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, $h)
        if ($isDark) {
            $b.FlatStyle = 'Flat'; $b.BackColor = [Drawing.Color]::FromArgb(51, 51, 51); $b.ForeColor = $fg
            $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(100, 100, 100)
            $b.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(65, 65, 65)
            $b.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(85, 85, 85)
        } else { $b.FlatStyle = 'System' }
        return $b
    }

    $btnBrowse = New-Btn 'Browse' 368 126 70 27
    $btnRun = New-Btn 'Run' 291 168 70 28
    $btnAbout = New-Btn 'About' 368 168 70 28

    $btnRun.Enabled = $false
    $form.AcceptButton = $btnRun
    $form.Controls.Add($btnBrowse); $form.Controls.Add($btnRun); $form.Controls.Add($btnAbout)

    $warnIcon = New-Object Windows.Forms.PictureBox
    $warnIcon.Location = New-Object Drawing.Point(16, 171); $warnIcon.Size = New-Object Drawing.Size(24, 24)
    $warnIcon.SizeMode = 'StretchImage'
    $warnBmp = [Drawing.SystemIcons]::Warning.ToBitmap()
    $warnIcon.Image = $warnBmp
    $form.Controls.Add($warnIcon)

    $lblWarn = New-Object Windows.Forms.Label
    $lblWarn.Text = 'Warning: Please use NSudo CAREFULLY !'; $lblWarn.Location = New-Object Drawing.Point(48, 178); $lblWarn.AutoSize = $true
    $lblWarn.ForeColor = if ($isDark) { [Drawing.Color]::White } else { [Drawing.Color]::Black }
    $lblWarn.Font = New-Object Drawing.Font('Segoe UI', 8)
    $form.Controls.Add($lblWarn)

    $pathBox.Add_TextChanged({ $btnRun.Enabled = -not [string]::IsNullOrWhiteSpace($pathBox.Text) })
    $pathBox.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; $btnRun.PerformClick() } })
    
    $btnBrowse.Add_Click({
        $ofd = New-Object Windows.Forms.OpenFileDialog
        $ofd.Title = 'Select command or files'; $ofd.Filter = 'Programs and Scripts|*.exe;*.cmd;*.bat;*.ps1;*.msc;*.lnk|All Files|*.*'; $ofd.Multiselect = $true
        if ($ofd.ShowDialog($form) -eq 'OK') { $pathBox.Text = Join-CommandLine $ofd.FileNames }
        $ofd.Dispose()
    })

    $btnAbout.Add_Click({ Show-AboutBox })

    $btnRun.Add_Click({
        $commandLine = $pathBox.Text.Trim()
        if (-not $commandLine) { return }
        try {
            $privilegesMode = if ($privBox.Checked) { 'EnableAll' } else { 'Default' }
            Invoke-SelectedMode -Mode $modeBox.SelectedItem -CommandLine $commandLine -PrivilegesMode $privilegesMode
        } catch {
            Show-LauncherError -Message $_.Exception.Message
        }
    })

    $dragEnter = { if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } else { $_.Effect = 'None' } }
    $dragDrop = { $items = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if ($items) { $pathBox.Text = Join-CommandLine $items } }
    $form.AllowDrop = $true; $pathBox.AllowDrop = $true
    $form.Add_DragEnter($dragEnter); $form.Add_DragDrop($dragDrop)
    $pathBox.Add_DragEnter($dragEnter); $pathBox.Add_DragDrop($dragDrop)

    $null = $form.Handle
    
    if ($isDark) {
        $darkVal = 1
        try {
            [RunAsTINativeDwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$darkVal, 4) | Out-Null
            [RunAsTINativeDwm]::DwmSetWindowAttribute($form.Handle, 19, [ref]$darkVal, 4) | Out-Null
        } catch {}
    }

    try {
        [void]$form.ShowDialog()
    } finally {
        if ($form.Icon) {
            $iconHandle = $form.Icon.Handle
            $form.Icon.Dispose()
            if ($iconHandle -ne [IntPtr]::Zero) {
                [RunAsTIIconNative]::DestroyIcon($iconHandle) | Out-Null
            }
        }
        if ($badge.Image) { $badge.Image.Dispose() }
        if ($warnBmp) { $warnBmp.Dispose() }
        if ($ms) { $ms.Dispose() }
        $form.Dispose()
    }
}

function Repair-PowerShellProfiles {
    $profiles = @(
        (Join-Path ([Environment]::GetFolderPath('Personal')) "WindowsPowerShell\Microsoft.PowerShell_profile.ps1"),
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\Microsoft.PowerShell_profile.ps1"),
        (Join-Path ([Environment]::GetFolderPath('Personal')) "WindowsPowerShell\Microsoft.PowerShellISE_profile.ps1"),
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\Microsoft.PowerShellISE_profile.ps1"),
        (Join-Path ([Environment]::GetFolderPath('Personal')) "WindowsPowerShell\profile.ps1"),
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\profile.ps1")
    )
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    foreach ($p in $profiles) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $content = [System.IO.File]::ReadAllText($p, $utf8Bom)
            if ($content -notmatch 'NSUDO_KAMIKAZE') { continue }
            
            $cleaned = [Text.RegularExpressions.Regex]::Replace($content, '(?s)#<NSUDO_KAMIKAZE.*?>.*?#</NSUDO_KAMIKAZE.*?>\r?\n?', '')
            if ([string]::IsNullOrWhiteSpace($cleaned)) {
                [System.IO.File]::Delete($p)
            } else {
                [System.IO.File]::WriteAllText($p, $cleaned.TrimStart("`r`n".ToCharArray()), $utf8Bom)
            }
        } catch {}
    }
}

function Start-Launcher {
    Repair-PowerShellProfiles
    $launchArgs = @(Get-LaunchArgs)

    if ($launchArgs.Count -gt 0) {
        if (-not (Test-IsAdmin)) {
            Start-ElevatedRun -ArgumentTokens ([string[]]$launchArgs)
        }
        else {
            $parsed = Parse-LauncherArguments -Tokens ([string[]]$launchArgs)
            if ($parsed.ShowVersion) {
                Write-Output (Get-LauncherTitle)
                return
            }

            if ($parsed.ShowHelp) {
                Write-Output (Get-LauncherHelpText)
                return
            }

            if ([string]::IsNullOrWhiteSpace($parsed.Mode)) {
                throw 'The -U option is required.'
            }

            if (-not [string]::IsNullOrWhiteSpace($parsed.CommandLine)) {
                Invoke-SelectedMode -Mode $parsed.Mode -CommandLine $parsed.CommandLine `
                    -PrivilegesMode $parsed.PrivilegesMode -MandatoryLabel $parsed.MandatoryLabel `
                    -Priority $parsed.Priority -ShowWindowMode $parsed.ShowWindowMode `
                    -Wait:$parsed.Wait -UseCurrentConsole:$parsed.UseCurrentConsole `
                    -CurrentDirectory $parsed.CurrentDirectory
            }
        }
        return
    }

    Show-LauncherUI
}

Start-Launcher