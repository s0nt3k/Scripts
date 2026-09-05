<#
.SYNOPSIS
    Component Store Manager - a console application for servicing the Windows
    component store (WinSxS) and Windows images through the DISM API / DISM
    PowerShell module.

.DESCRIPTION
    Provides an interactive menu for:
      * Checking / scanning component-store health (online or offline)
      * Repairing corruption with RestoreHealth
      * Advanced repair when RestoreHealth fails (known-good source, overwrite
        of the component-store version by running as SYSTEM / TrustedInstaller)
      * Analyze / Cleanup / ResetBase of the component store
      * Selecting an offline image and downloading matching updates
      * Backing up the online component store and the driver store
      * Adding drivers / updates to boot.wim / install.wim inside an ISO
        (auto-mounting the ISO and the images, then unmounting them)
      * Rebuilding a new, updated, bootable ISO
      * Detecting and switching the active privilege level
        (User / Administrator / SYSTEM / TrustedInstaller) using Sysinternals
        PsExec.

    The most important capability is repairing a *repairable* corrupted
    component store that RestoreHealth alone cannot fix, by escalating to
    SYSTEM / TrustedInstaller and overwriting component-store payloads from a
    known-good source.

.NOTES
    Run in an elevated Windows PowerShell 5.1 (or PowerShell 7) console.
    Requires the DISM PowerShell module (ships with Windows).
    Rebuilding ISOs requires oscdimg.exe (Windows ADK / Deployment Tools).
    Elevation to SYSTEM / TrustedInstaller requires Sysinternals PsExec.

    THIS TOOL MAKES DESTRUCTIVE, LOW-LEVEL CHANGES TO WINDOWS SERVICING STATE.
    Always create a backup before repairing or resetting the base image.
#>

[CmdletBinding()]
param(
    # Internal: which context to (re)launch into. Used by the self-relaunch logic.
    [ValidateSet('','Admin','System','TrustedInstaller')]
    [string]$Elevate = '',

    # Internal marker so a relaunched instance knows it was spawned by us.
    [switch]$Relaunched
)

#region ---------------------------------------------------------------- Globals

$Script:AppName    = 'Component Store Manager'
$Script:AppVersion = '1.0'
$Script:ScriptPath = $MyInvocation.MyCommand.Path
$Script:WorkRoot   = Join-Path $env:ProgramData 'ComponentStoreManager'
$Script:LogFile    = Join-Path $Script:WorkRoot ('CSM_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))

# Target of servicing operations. $null Path means "online".
$Script:Target = [ordered]@{
    Online   = $true
    Path     = $null      # offline mounted/expanded windows dir
    Label    = 'Online (running OS)'
}

# Everything we mount so we can guarantee cleanup on exit.
#   Type = 'ISO' | 'WIM' | 'VHD'
$Script:Mounts = New-Object System.Collections.Generic.List[object]

if (-not (Test-Path $Script:WorkRoot)) {
    New-Item -ItemType Directory -Path $Script:WorkRoot -Force | Out-Null
}

#endregion

#region ---------------------------------------------------------------- Logging / UI helpers

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = '[{0}] [{1}] {2}' -f $stamp, $Level, $Message
    try { Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8 } catch { }

    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $Message -ForegroundColor $color
}

function Write-Banner {
    param([string]$Text)
    $bar = '=' * 74
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ("  " + $Text) -ForegroundColor White
    Write-Host $bar -ForegroundColor DarkCyan
}

function Wait-Menu {
    Write-Host ''
    Write-Host 'Press ENTER to return to the menu...' -ForegroundColor DarkGray
    [void](Read-Host)
}

function Confirm-Action {
    param([string]$Prompt,[switch]$Danger)
    if ($Danger) {
        Write-Host ''
        Write-Host ('  !!! ' + $Prompt) -ForegroundColor Red
    } else {
        Write-Host ''
        Write-Host ('  ' + $Prompt) -ForegroundColor Yellow
    }
    $ans = Read-Host 'Type YES to continue'
    return ($ans -eq 'YES')
}

function Read-PathInput {
    param([string]$Prompt)
    $p = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    return $p.Trim('"').Trim()
}

# Run an external command, stream its output to the console and the log.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [switch]$Quiet
    )
    Write-Log ("RUN: {0} {1}" -f $File, ($Arguments -join ' ')) 'STEP'
    & $File @Arguments 2>&1 | ForEach-Object {
        $text = $_.ToString()
        if (-not $Quiet) { Write-Host $text }
        try { Add-Content -Path $Script:LogFile -Value $text -Encoding UTF8 } catch { }
    }
    return $LASTEXITCODE
}

#endregion

#region ---------------------------------------------------------------- Privilege detection

# The well-known TrustedInstaller service SID.
$Script:TrustedInstallerSid = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'

function Get-PrivilegeLevel {
    <#
        Returns one of: User, Administrator, SYSTEM, TrustedInstaller
    #>
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()

    # SYSTEM?
    if ($id.User.Value -eq 'S-1-5-18') {
        # SYSTEM, but is the TrustedInstaller SID present + enabled in the token?
        $hasTi = $false
        foreach ($g in $id.Groups) {
            if ($g.Value -eq $Script:TrustedInstallerSid) { $hasTi = $true; break }
        }
        if ($id.Owner.Value -eq $Script:TrustedInstallerSid -or $hasTi) {
            return 'TrustedInstaller'
        }
        return 'SYSTEM'
    }

    # TrustedInstaller running as its own service account (rare in interactive)
    if ($id.Name -like '*TrustedInstaller*') { return 'TrustedInstaller' }

    $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
    if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return 'Administrator'
    }
    return 'User'
}

function Get-PrivilegeColor {
    param([string]$Level)
    switch ($Level) {
        'TrustedInstaller' { 'Magenta' }
        'SYSTEM'           { 'Red' }
        'Administrator'    { 'Green' }
        default            { 'Yellow' }
    }
}

function Update-PrivilegeLevel {
    <#
        Single source of truth for the active privilege level. Re-reads the live
        token, caches it in $Script:CurrentPrivilege, and mirrors it into the
        console window title so the indicator is always current. Called on every
        main-menu render and after any privilege switch.
    #>
    $Script:CurrentPrivilege = Get-PrivilegeLevel
    try {
        [Console]::Title = ('{0} v{1}  -  [{2}]  {3}' -f `
            $Script:AppName, $Script:AppVersion, $Script:CurrentPrivilege,
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    } catch { }
    return $Script:CurrentPrivilege
}

#endregion

#region ---------------------------------------------------------------- PsExec (Sysinternals)

function Get-PsExecPath {
    <#
        Locate PsExec. Search PATH, the work folder, then offer to download it
        from the official Sysinternals Live share.
    #>
    $candidates = @('PsExec64.exe','PsExec.exe')
    foreach ($c in $candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        $local = Join-Path $Script:WorkRoot $c
        if (Test-Path $local) { return $local }
    }

    Write-Host ''
    Write-Log 'PsExec was not found on this system.' 'WARN'
    $dl = Read-Host 'Download PsExec from live.sysinternals.com now? (Y/N)'
    if ($dl -notmatch '^[Yy]') { return $null }

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'PsExec64.exe' } else { 'PsExec.exe' }
    $url  = "https://live.sysinternals.com/$arch"
    $dest = Join-Path $Script:WorkRoot $arch
    try {
        Write-Log "Downloading $url ..." 'STEP'
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        # Clear the "downloaded from the internet" mark so EULA/AV do not block it.
        Unblock-File -Path $dest -ErrorAction SilentlyContinue
        Write-Log "Saved to $dest" 'OK'
        return $dest
    } catch {
        Write-Log ("Failed to download PsExec: {0}" -f $_.Exception.Message) 'ERROR'
        return $null
    }
}

#endregion

#region ---------------------------------------------------------------- Relaunch / privilege switch

function Get-RelaunchCommandLine {
    <#
        Builds the argument list used to relaunch this script in a new context.
    #>
    param([string]$Context)
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }
    $scriptArgs = @(
        '-NoProfile','-ExecutionPolicy','Bypass',
        '-File', ('"{0}"' -f $Script:ScriptPath),
        '-Elevate', $Context, '-Relaunched'
    )
    return @{ Exe = $psExe; Args = $scriptArgs }
}

function Confirm-CloseCurrentWindow {
    <#
        After a switch spawns a NEW console at the target level, the indicator in
        THAT window already reflects the new privilege. Offer to close this window
        so the user lands on the console showing the updated level.
    #>
    param([string]$NewLevel)
    Write-Host ''
    Write-Host ("  A new [{0}] console has opened - its header shows the updated level." -f $NewLevel) -ForegroundColor Green
    $a = Read-Host '  Close THIS window now and continue in the new console? (Y/N)'
    if ($a -match '^[Yy]') {
        Write-Log 'Closing this window; continue in the new console.' 'INFO'
        Invoke-CleanupMounts -Silent
        exit
    }
    # Not closing: refresh this window's own (unchanged) indicator anyway.
    Update-PrivilegeLevel | Out-Null
}

function Exit-ToLowerPrivilege {
    <#
        The "vice versa" direction. SYSTEM / TrustedInstaller cannot drop their own
        token in place, so returning to a lower level means closing this elevated
        console and continuing in the Administrator window that launched it.
    #>
    $level = Update-PrivilegeLevel
    Write-Host ''
    if ($level -in @('SYSTEM','TrustedInstaller')) {
        Write-Host ("  This is a {0} console. Lower privilege lives in the" -f $level) -ForegroundColor Yellow
        Write-Host '  Administrator window that launched it.' -ForegroundColor Yellow
        if (Confirm-Action 'Close this elevated window and return to that console?') {
            Write-Log 'Closing elevated window.' 'INFO'
            Invoke-CleanupMounts -Silent
            exit
        }
    } elseif ($level -eq 'Administrator') {
        Write-Host '  To run un-elevated, start a normal (non-admin) PowerShell and' -ForegroundColor Yellow
        Write-Host '  run this script without elevation. Admin cannot self-demote in place.' -ForegroundColor Yellow
        Wait-Menu
    } else {
        Write-Log 'Already at the lowest (User) level.' 'INFO'
        Wait-Menu
    }
}

function Start-AsAdministrator {
    if ((Get-PrivilegeLevel) -in @('Administrator','SYSTEM','TrustedInstaller')) {
        Write-Log 'Already running with Administrator (or higher) rights.' 'OK'
        Wait-Menu; return
    }
    $rl = Get-RelaunchCommandLine -Context 'Admin'
    Write-Log 'Relaunching elevated (UAC prompt)...' 'STEP'
    try {
        Start-Process -FilePath $rl.Exe -ArgumentList $rl.Args -Verb RunAs
        Write-Log 'Elevated instance launched.' 'OK'
        Confirm-CloseCurrentWindow -NewLevel 'Administrator'
    } catch {
        Write-Log ("Elevation cancelled or failed: {0}" -f $_.Exception.Message) 'ERROR'
        Wait-Menu
    }
}

function Start-AsSystem {
    <#
        Uses PsExec -s -i to spawn an interactive SYSTEM console running this
        script. Requires Administrator rights to start.
    #>
    if ((Get-PrivilegeLevel) -eq 'User') {
        Write-Log 'You must be Administrator before switching to SYSTEM.' 'WARN'
        Write-Log 'Choose "Elevate to Administrator" first.' 'WARN'
        Wait-Menu; return
    }
    $psexec = Get-PsExecPath
    if (-not $psexec) { Wait-Menu; return }

    $rl = Get-RelaunchCommandLine -Context 'System'
    $sessionId = (Get-Process -Id $PID).SessionId
    # -d = detached so this window is not blocked while the SYSTEM console runs.
    $psexecArgs = @('-accepteula','-nobanner','-d','-s','-i',$sessionId, $rl.Exe) + $rl.Args
    Write-Log 'Launching interactive SYSTEM console via PsExec...' 'STEP'
    $code = Invoke-Native -File $psexec -Arguments $psexecArgs
    if ($code -gt 0) {
        Write-Log ("SYSTEM console launched (PID {0})." -f $code) 'OK'
        Confirm-CloseCurrentWindow -NewLevel 'SYSTEM'
    } else {
        Write-Log ("PsExec did not report a successful launch (exit {0})." -f $code) 'WARN'
        Wait-Menu
    }
}

function Start-AsTrustedInstaller {
    <#
        Requires an existing SYSTEM context (PsExec -s). From SYSTEM we start the
        TrustedInstaller service, duplicate its primary token, and launch this
        script with that token so servicing operations run with the same rights
        as Windows Update / the servicing stack itself.
    #>
    $level = Get-PrivilegeLevel
    if ($level -ne 'SYSTEM' -and $level -ne 'TrustedInstaller') {
        Write-Log 'TrustedInstaller elevation must be launched from a SYSTEM context.' 'WARN'
        Write-Log 'Switch to SYSTEM first (menu option), then choose TrustedInstaller.' 'WARN'
        Wait-Menu; return
    }

    Add-TrustedInstallerType

    try {
        Write-Log 'Starting the TrustedInstaller service...' 'STEP'
        $rl = Get-RelaunchCommandLine -Context 'TrustedInstaller'
        $cmdLine = '"{0}" {1}' -f $rl.Exe, ($rl.Args -join ' ')
        $ok = [CSM.TokenLauncher]::LaunchAsTrustedInstaller($cmdLine)
        if ($ok) {
            Write-Log 'TrustedInstaller console launched.' 'OK'
            Confirm-CloseCurrentWindow -NewLevel 'TrustedInstaller'
        } else {
            Write-Log 'Failed to launch as TrustedInstaller (see log).' 'ERROR'
            Wait-Menu
        }
    } catch {
        Write-Log ("TrustedInstaller elevation error: {0}" -f $_.Exception.Message) 'ERROR'
        Wait-Menu
    }
}

function Add-TrustedInstallerType {
    if ('CSM.TokenLauncher' -as [type]) { return }
    $code = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.ServiceProcess;

namespace CSM
{
    public static class TokenLauncher
    {
        const uint TOKEN_DUPLICATE          = 0x0002;
        const uint TOKEN_QUERY              = 0x0008;
        const uint TOKEN_ASSIGN_PRIMARY     = 0x0001;
        const uint TOKEN_ADJUST_DEFAULT     = 0x0080;
        const uint TOKEN_ADJUST_SESSIONID   = 0x0100;
        const uint MAXIMUM_ALLOWED          = 0x02000000;
        const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        const uint CREATE_NEW_CONSOLE       = 0x00000010;

        enum SECURITY_IMPERSONATION_LEVEL { SecurityAnonymous, SecurityIdentification, SecurityImpersonation, SecurityDelegation }
        enum TOKEN_TYPE { TokenPrimary = 1, TokenImpersonation }

        [StructLayout(LayoutKind.Sequential)]
        struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
            public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars;
            public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow;
            public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }

        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

        [DllImport("kernel32.dll", SetLastError=true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool DuplicateTokenEx(IntPtr existing, uint access, IntPtr attrs,
            SECURITY_IMPERSONATION_LEVEL level, TOKEN_TYPE type, out IntPtr newToken);
        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        static extern bool CreateProcessAsUser(IntPtr token, string appName, string cmdLine,
            IntPtr procAttr, IntPtr threadAttr, bool inherit, uint flags, IntPtr env,
            string curDir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool CloseHandle(IntPtr h);

        static int StartTrustedInstaller()
        {
            using (var sc = new ServiceController("TrustedInstaller"))
            {
                if (sc.Status != ServiceControllerStatus.Running)
                {
                    sc.Start();
                    sc.WaitForStatus(ServiceControllerStatus.Running, TimeSpan.FromSeconds(30));
                }
                // Find the TrustedInstaller.exe process id.
                foreach (var p in Process.GetProcessesByName("TrustedInstaller"))
                    return p.Id;
            }
            return 0;
        }

        public static bool LaunchAsTrustedInstaller(string commandLine)
        {
            int pid = StartTrustedInstaller();
            if (pid == 0) { Console.Error.WriteLine("TrustedInstaller process not found."); return false; }

            IntPtr hProc = OpenProcess(MAXIMUM_ALLOWED, false, pid);
            if (hProc == IntPtr.Zero) { Console.Error.WriteLine("OpenProcess failed: " + Marshal.GetLastWin32Error()); return false; }

            IntPtr hTok;
            if (!OpenProcessToken(hProc, TOKEN_DUPLICATE | TOKEN_QUERY, out hTok))
            { Console.Error.WriteLine("OpenProcessToken failed: " + Marshal.GetLastWin32Error()); CloseHandle(hProc); return false; }

            IntPtr hDup;
            uint dupAccess = TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT | TOKEN_ADJUST_SESSIONID;
            if (!DuplicateTokenEx(hTok, dupAccess, IntPtr.Zero,
                SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation, TOKEN_TYPE.TokenPrimary, out hDup))
            { Console.Error.WriteLine("DuplicateTokenEx failed: " + Marshal.GetLastWin32Error()); return false; }

            var si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(si);
            si.lpDesktop = "winsta0\\default";
            PROCESS_INFORMATION pi;

            bool ok = CreateProcessAsUser(hDup, null, commandLine, IntPtr.Zero, IntPtr.Zero,
                false, CREATE_UNICODE_ENVIRONMENT | CREATE_NEW_CONSOLE, IntPtr.Zero, null, ref si, out pi);
            if (!ok) { Console.Error.WriteLine("CreateProcessAsUser failed: " + Marshal.GetLastWin32Error()); }
            else { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }

            CloseHandle(hDup); CloseHandle(hTok); CloseHandle(hProc);
            return ok;
        }
    }
}
'@
    Add-Type -TypeDefinition $code -ReferencedAssemblies 'System.ServiceProcess' -ErrorAction Stop
}

function Show-PrivilegeMenu {
    while ($true) {
        Clear-Host
        Write-Banner 'Privilege Level'
        $level = Update-PrivilegeLevel
        Write-Host ''
        Write-Host ('  Current context : ') -NoNewline
        Write-Host $level -ForegroundColor (Get-PrivilegeColor $level)
        Write-Host ('  Identity        : {0}' -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -ForegroundColor Gray
        Write-Host ''
        Write-Host '  Privilege ladder:  User -> Administrator -> SYSTEM -> TrustedInstaller'
        Write-Host '  Switching opens a NEW console at the target level; the indicator at the' -ForegroundColor DarkGray
        Write-Host '  top of that window shows the updated privilege.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '   [1] Elevate to Administrator (UAC)'
        Write-Host '   [2] Switch to SYSTEM            (Sysinternals PsExec -s -i)'
        Write-Host '   [3] Switch to TrustedInstaller  (token from SYSTEM)'
        Write-Host '   [4] Drop back down             (close this elevated window)'
        Write-Host '   [0] Back'
        Write-Host ''
        $c = Read-Host 'Select'
        switch ($c) {
            '1' { Start-AsAdministrator }
            '2' { Start-AsSystem }
            '3' { Start-AsTrustedInstaller }
            '4' { Exit-ToLowerPrivilege }
            '0' { return }
            default { }
        }
    }
}

#endregion

#region ---------------------------------------------------------------- Target selection (online/offline)

function Set-OnlineTarget {
    $Script:Target.Online = $true
    $Script:Target.Path   = $null
    $Script:Target.Label  = 'Online (running OS)'
    Write-Log 'Target set to ONLINE (running OS).' 'OK'
}

function Select-OfflineTarget {
    Clear-Host
    Write-Banner 'Select Offline Component Store Image'
    Write-Host ''
    Write-Host '   [1] Point to an already-expanded offline Windows directory (e.g. D:\Mount)'
    Write-Host '   [2] Mount a WIM/ESD image and target it'
    Write-Host '   [3] Mount a VHD/VHDX and target it'
    Write-Host '   [0] Cancel'
    Write-Host ''
    $c = Read-Host 'Select'
    switch ($c) {
        '1' {
            $p = Read-PathInput 'Path to offline Windows dir (the folder containing \Windows)'
            if ($p -and (Test-Path $p)) {
                $Script:Target.Online = $false
                $Script:Target.Path   = $p
                $Script:Target.Label  = "Offline: $p"
                Write-Log "Offline target set: $p" 'OK'
            } else { Write-Log 'Path not found.' 'ERROR' }
        }
        '2' {
            $wim = Read-PathInput 'Path to .wim/.esd'
            if (-not (Test-Path $wim)) { Write-Log 'File not found.' 'ERROR'; break }
            $idx = Read-Host 'Image index to mount (default 1)'
            if ([string]::IsNullOrWhiteSpace($idx)) { $idx = 1 }
            $mp = New-MountDir 'wim'
            try {
                Mount-WindowsImage -ImagePath $wim -Index ([int]$idx) -Path $mp -ErrorAction Stop | Out-Null
                Register-Mount -Type 'WIM' -Path $mp -Source $wim -Extra @{ Index = [int]$idx }
                $Script:Target.Online = $false
                $Script:Target.Path   = $mp
                $Script:Target.Label  = "Offline WIM: $wim [#$idx] -> $mp"
                Write-Log "Mounted and targeted: $mp" 'OK'
            } catch { Write-Log ("Mount failed: {0}" -f $_.Exception.Message) 'ERROR' }
        }
        '3' {
            $vhd = Read-PathInput 'Path to .vhd/.vhdx'
            if (-not (Test-Path $vhd)) { Write-Log 'File not found.' 'ERROR'; break }
            try {
                $before = (Get-Volume).DriveLetter
                Mount-DiskImage -ImagePath $vhd -ErrorAction Stop | Out-Null
                Start-Sleep -Milliseconds 800
                $after = (Get-Volume).DriveLetter
                $new = ($after | Where-Object { $_ -and ($before -notcontains $_) } | Select-Object -First 1)
                Register-Mount -Type 'VHD' -Path $vhd -Source $vhd
                if ($new) {
                    $winDir = "$($new):\"
                    $Script:Target.Online = $false
                    $Script:Target.Path   = $winDir
                    $Script:Target.Label  = "Offline VHD: $vhd -> $winDir"
                    Write-Log "Mounted VHD at $winDir" 'OK'
                } else { Write-Log 'VHD mounted but no new drive letter detected; set path manually.' 'WARN' }
            } catch { Write-Log ("VHD mount failed: {0}" -f $_.Exception.Message) 'ERROR' }
        }
        default { }
    }
    Wait-Menu
}

# Applies the correct online/offline switch set to DISM-style splatting.
function Get-ImageArgs {
    if ($Script:Target.Online) { return @{ Online = $true } }
    return @{ Path = $Script:Target.Path }
}
function Get-DismScopeArgs {
    if ($Script:Target.Online) { return @('/Online') }
    return @('/Image:{0}' -f $Script:Target.Path)
}

#endregion

#region ---------------------------------------------------------------- Mount tracking / cleanup

function New-MountDir {
    param([string]$Prefix = 'mnt')
    $dir = Join-Path $Script:WorkRoot ('{0}_{1}' -f $Prefix, ([guid]::NewGuid().ToString('N').Substring(0,8)))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Register-Mount {
    param(
        [Parameter(Mandatory)][ValidateSet('ISO','WIM','VHD')] [string]$Type,
        [Parameter(Mandatory)][string]$Path,
        [string]$Source,
        [hashtable]$Extra
    )
    $Script:Mounts.Add([pscustomobject]@{
        Type   = $Type
        Path   = $Path      # for ISO: assigned drive letter; WIM: mount dir; VHD: image path
        Source = $Source
        Extra  = $Extra
        Time   = Get-Date
    })
    Write-Log ("Tracked mount: {0} -> {1}" -f $Type, $Path) 'INFO'
}

function Dismount-One {
    param([object]$M,[switch]$Commit)
    try {
        switch ($M.Type) {
            'ISO' {
                if ($M.Source) { Dismount-DiskImage -ImagePath $M.Source -ErrorAction Stop | Out-Null }
                Write-Log ("Unmounted ISO: {0}" -f $M.Source) 'OK'
            }
            'VHD' {
                Dismount-DiskImage -ImagePath $M.Source -ErrorAction Stop | Out-Null
                Write-Log ("Unmounted VHD: {0}" -f $M.Source) 'OK'
            }
            'WIM' {
                if ($Commit) {
                    Dismount-WindowsImage -Path $M.Path -Save -ErrorAction Stop | Out-Null
                    Write-Log ("Committed + unmounted WIM: {0}" -f $M.Path) 'OK'
                } else {
                    Dismount-WindowsImage -Path $M.Path -Discard -ErrorAction Stop | Out-Null
                    Write-Log ("Discarded + unmounted WIM: {0}" -f $M.Path) 'OK'
                }
                if (Test-Path $M.Path) { Remove-Item $M.Path -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    } catch {
        Write-Log ("Failed to unmount {0} ({1}): {2}" -f $M.Type,$M.Path,$_.Exception.Message) 'ERROR'
    }
}

function Invoke-CleanupMounts {
    param([switch]$Silent)
    if ($Script:Mounts.Count -eq 0) {
        if (-not $Silent) { Write-Log 'No tracked mounts to clean up.' 'INFO' }
        return
    }
    if (-not $Silent) { Write-Log ("Cleaning up {0} tracked mount(s)..." -f $Script:Mounts.Count) 'STEP' }
    # WIM mounts already committed/discarded by their own workflow are still
    # dismounted defensively (Save is only applied to explicit workflow calls).
    for ($i = $Script:Mounts.Count - 1; $i -ge 0; $i--) {
        Dismount-One -M $Script:Mounts[$i]
    }
    $Script:Mounts.Clear()
    # Clear any stale WIM mounts DISM still knows about.
    try {
        Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
            Where-Object { $_.MountStatus -ne 'Ok' } |
            ForEach-Object { Clear-WindowsCorruptMountPoint | Out-Null }
    } catch { }
}

#endregion

#region ---------------------------------------------------------------- DISM: health / repair

function Invoke-CheckHealth {
    Clear-Host
    Write-Banner ("Check Health  -  {0}" -f $Script:Target.Label)
    $img = Get-ImageArgs
    try {
        $r = Repair-WindowsImage @img -CheckHealth -ErrorAction Stop
        Show-HealthResult $r
    } catch { Write-Log ("CheckHealth failed: {0}" -f $_.Exception.Message) 'ERROR' }
    Wait-Menu
}

function Invoke-ScanHealth {
    Clear-Host
    Write-Banner ("Scan Health  -  {0}" -f $Script:Target.Label)
    Write-Log 'Scanning the component store for corruption (this can take several minutes)...' 'STEP'
    $img = Get-ImageArgs
    try {
        $r = Repair-WindowsImage @img -ScanHealth -ErrorAction Stop
        Show-HealthResult $r
    } catch { Write-Log ("ScanHealth failed: {0}" -f $_.Exception.Message) 'ERROR' }
    Wait-Menu
}

function Show-HealthResult {
    param($Result)
    Write-Host ''
    $state = $Result.ImageHealthState
    $color = switch ("$state") {
        'Healthy'          { 'Green' }
        'Repairable'       { 'Yellow' }
        'NonRepairable'    { 'Red' }
        default            { 'Gray' }
    }
    Write-Host '  Image Health State : ' -NoNewline
    Write-Host $state -ForegroundColor $color
    Write-Log ("Health state: {0}" -f $state) 'INFO'
    if ("$state" -eq 'Repairable') {
        Write-Host ''
        Write-Host '  -> Corruption is REPAIRABLE. Use option [3] RestoreHealth,' -ForegroundColor Yellow
        Write-Host '     or [4] Advanced Repair if RestoreHealth cannot fix it.' -ForegroundColor Yellow
    } elseif ("$state" -eq 'NonRepairable') {
        Write-Host ''
        Write-Host '  -> Component store is NON-repairable by servicing.' -ForegroundColor Red
        Write-Host '     Consider an in-place upgrade / reset (see Advanced Repair).' -ForegroundColor Red
    }
}

function Invoke-RestoreHealth {
    param([string]$Source,[switch]$LimitAccess)
    Clear-Host
    Write-Banner ("Restore Health  -  {0}" -f $Script:Target.Label)
    Write-Log 'Attempting RestoreHealth...' 'STEP'
    $img = Get-ImageArgs
    $params = $img.Clone()
    $params['RestoreHealth'] = $true
    if ($Source)      { $params['Source'] = $Source }
    if ($LimitAccess) { $params['LimitAccess'] = $true }

    try {
        $r = Repair-WindowsImage @params -ErrorAction Stop
        Write-Log ("RestoreHealth completed. RestartNeeded={0}" -f $r.RestartNeeded) 'OK'
        # Verify
        $chk = Repair-WindowsImage @img -CheckHealth -ErrorAction SilentlyContinue
        Show-HealthResult $chk
        if ("$($chk.ImageHealthState)" -ne 'Healthy') {
            Write-Host ''
            Write-Log 'RestoreHealth did not fully repair the store.' 'WARN'
            Write-Host '  Proceed to option [4] Advanced Repair.' -ForegroundColor Yellow
        }
        return "$($chk.ImageHealthState)" -eq 'Healthy'
    } catch {
        Write-Log ("RestoreHealth failed: {0}" -f $_.Exception.Message) 'ERROR'
        Write-Host ''
        Write-Log 'RestoreHealth could not repair the store with the current source.' 'WARN'
        Write-Host '  Proceed to option [4] Advanced Repair to specify a known-good' -ForegroundColor Yellow
        Write-Host '  source and/or overwrite the store as SYSTEM/TrustedInstaller.' -ForegroundColor Yellow
        return $false
    }
}

function Invoke-RestoreHealthInteractive {
    Clear-Host
    Write-Banner ("Restore Health  -  {0}" -f $Script:Target.Label)
    Write-Host ''
    Write-Host '  RestoreHealth uses Windows Update by default. You may specify a'
    Write-Host '  known-good source (install.wim / install.esd / expanded WinSxS).'
    Write-Host ''
    $src = Read-PathInput 'Optional Source (e.g. WIM:D:\sources\install.wim:1  or  a WinSxS path) [ENTER=WU]'
    $limit = $false
    if ($src) {
        $la = Read-Host 'Restrict to this source only (LimitAccess, do NOT use Windows Update)? (Y/N)'
        $limit = ($la -match '^[Yy]')
    }
    Invoke-RestoreHealth -Source $src -LimitAccess:$limit | Out-Null
    Wait-Menu
}

#endregion

#region ---------------------------------------------------------------- DISM: advanced repair

function Show-AdvancedRepairMenu {
    while ($true) {
        Clear-Host
        Write-Banner ("Advanced Repair  -  {0}" -f $Script:Target.Label)
        Write-Host ''
        Write-Host '  Use these when RestoreHealth alone cannot repair a REPAIRABLE store.'
        Write-Host ''
        Write-Host '   [1] Repair from a known-good source (install.wim / ESD / WinSxS)'
        Write-Host '   [2] Repair from mounted ISO (auto-detect \sources\install.wim)'
        Write-Host '   [3] OVERWRITE component store from source running as SYSTEM'
        Write-Host '   [4] OVERWRITE component store from source running as TrustedInstaller'
        Write-Host '   [5] SFC /scannow against the target'
        Write-Host '   [6] In-place upgrade guidance (non-repairable stores)'
        Write-Host '   [0] Back'
        Write-Host ''
        $c = Read-Host 'Select'
        switch ($c) {
            '1' {
                $src = Read-PathInput 'Source (e.g. WIM:D:\sources\install.wim:1)'
                Invoke-RestoreHealth -Source $src -LimitAccess | Out-Null
                Wait-Menu
            }
            '2' { Repair-FromMountedIso; Wait-Menu }
            '3' { Invoke-OverwriteRepair -As 'System' }
            '4' { Invoke-OverwriteRepair -As 'TrustedInstaller' }
            '5' {
                if ($Script:Target.Online) { Invoke-Native -File 'sfc.exe' -Arguments @('/scannow') | Out-Null }
                else {
                    $win = Join-Path $Script:Target.Path 'Windows'
                    Invoke-Native -File 'sfc.exe' -Arguments @('/scannow',"/offbootdir=$($Script:Target.Path)","/offwindir=$win") | Out-Null
                }
                Wait-Menu
            }
            '6' { Show-InPlaceGuidance; Wait-Menu }
            '0' { return }
            default { }
        }
    }
}

function Repair-FromMountedIso {
    $iso = Read-PathInput 'Path to installation ISO'
    if (-not (Test-Path $iso)) { Write-Log 'ISO not found.' 'ERROR'; return }
    $drive = Mount-Iso -IsoPath $iso
    if (-not $drive) { return }
    $wim = Join-Path "$drive`:\" 'sources\install.wim'
    $esd = Join-Path "$drive`:\" 'sources\install.esd'
    $srcFile = if (Test-Path $wim) { $wim } elseif (Test-Path $esd) { $esd } else { $null }
    if (-not $srcFile) { Write-Log 'No install.wim/esd found on the ISO.' 'ERROR'; return }

    Write-Host ''
    Write-Log "Editions in $srcFile :" 'STEP'
    Get-WindowsImage -ImagePath $srcFile | Select-Object ImageIndex, ImageName | Format-Table -AutoSize | Out-String | Write-Host
    $idx = Read-Host 'Image index that matches this OS edition'
    if ([string]::IsNullOrWhiteSpace($idx)) { $idx = 1 }
    $srcSpec = "WIM:$srcFile`:$idx"
    Invoke-RestoreHealth -Source $srcSpec -LimitAccess | Out-Null
    # ISO stays tracked; cleaned up on exit or via Cleanup menu.
}

function Invoke-OverwriteRepair {
    <#
        The key capability: when the store is repairable but RestoreHealth
        cannot fix it (e.g. the payload is missing from WU and the local store),
        overwrite the corrupt component-store payloads directly from a known-good
        source, running with the servicing stack's own rights (SYSTEM / TI).
    #>
    param([ValidateSet('System','TrustedInstaller')][string]$As)

    Clear-Host
    Write-Banner ("Overwrite Component Store  (as {0})" -f $As)
    $level = Get-PrivilegeLevel

    $needed = if ($As -eq 'System') { @('SYSTEM','TrustedInstaller') } else { @('TrustedInstaller') }
    if ($level -notin $needed) {
        Write-Host ''
        Write-Log ("This operation must run as {0}. Current context: {1}." -f $As,$level) 'WARN'
        Write-Host ("  Use the Privilege menu to switch to {0} first," -f $As) -ForegroundColor Yellow
        Write-Host '  then re-run this option in that console.' -ForegroundColor Yellow
        Wait-Menu; return
    }

    Write-Host ''
    Write-Host '  This will overwrite the current component-store payload for the'
    Write-Host '  corrupt package(s) with files from a known-good source of the'
    Write-Host '  SAME build/version. Use a matching install.wim / expanded WinSxS.'
    if (-not (Confirm-Action 'Overwriting the component store can break servicing if the source build does not match. Continue?' -Danger)) {
        Wait-Menu; return
    }

    $src = Read-PathInput 'Known-good source: expanded WinSxS folder OR mounted install image \Windows dir'
    if (-not $src -or -not (Test-Path $src)) { Write-Log 'Source not found.' 'ERROR'; Wait-Menu; return }

    # Resolve the source WinSxS.
    $srcWinSxS = if (Test-Path (Join-Path $src 'WinSxS')) { Join-Path $src 'WinSxS' }
                 elseif ($src -match 'WinSxS$') { $src }
                 else { Join-Path $src 'Windows\WinSxS' }
    if (-not (Test-Path $srcWinSxS)) { Write-Log "Could not locate a WinSxS under: $src" 'ERROR'; Wait-Menu; return }

    $tgtRoot = if ($Script:Target.Online) { $env:SystemRoot } else { Join-Path $Script:Target.Path 'Windows' }
    $tgtWinSxS = Join-Path $tgtRoot 'WinSxS'

    Write-Host ''
    Write-Log "Source store : $srcWinSxS" 'INFO'
    Write-Log "Target store : $tgtWinSxS" 'INFO'
    Write-Host ''
    Write-Host '  [1] Targeted overwrite of specific corrupt components (recommended)'
    Write-Host '  [2] Robocopy mirror of missing/changed payload (broad)'
    $mode = Read-Host 'Select overwrite mode'

    if ($mode -eq '1') {
        Write-Host ''
        Write-Host '  Enter the corrupt component folder name(s) from CBS.log /'
        Write-Host '  the ScanHealth output (comma separated), e.g.'
        Write-Host '     amd64_microsoft-windows-...._none_abc123'
        $names = Read-Host 'Component folder name(s)'
        foreach ($n in ($names -split ',')) {
            $n = $n.Trim(); if (-not $n) { continue }
            $s = Join-Path $srcWinSxS $n
            $t = Join-Path $tgtWinSxS $n
            if (Test-Path $s) {
                Write-Log "Overwriting $n ..." 'STEP'
                # takeown/icacls so even TI can replace protected payload, then copy.
                Invoke-Native -File 'takeown.exe' -Arguments @('/F',$t,'/R','/D','Y') -Quiet | Out-Null
                Invoke-Native -File 'icacls.exe'  -Arguments @($t,'/grant','*S-1-5-32-544:F','/T','/C') -Quiet | Out-Null
                Invoke-Native -File 'robocopy.exe' -Arguments @($s,$t,'/MIR','/COPYALL','/R:1','/W:1','/NFL','/NDL') | Out-Null
            } else {
                Write-Log "Source component not found: $n" 'WARN'
            }
        }
    } elseif ($mode -eq '2') {
        if (-not (Confirm-Action 'A broad WinSxS mirror is heavy and only safe for identical builds. Continue?' -Danger)) { Wait-Menu; return }
        Write-Log 'Mirroring payload (missing/newer only, existing preserved)...' 'STEP'
        Invoke-Native -File 'robocopy.exe' -Arguments @($srcWinSxS,$tgtWinSxS,'/E','/XO','/COPYALL','/R:1','/W:1','/XX','/NFL','/NDL') | Out-Null
    } else {
        Write-Log 'Cancelled.' 'INFO'; Wait-Menu; return
    }

    Write-Host ''
    Write-Log 'Overwrite complete. Re-running RestoreHealth to seal the store...' 'STEP'
    Invoke-RestoreHealth -Source $src -LimitAccess | Out-Null
    Wait-Menu
}

function Show-InPlaceGuidance {
    Write-Host ''
    Write-Host '  A NON-repairable component store cannot be fixed by servicing.' -ForegroundColor Red
    Write-Host '  Recommended recovery paths:' -ForegroundColor Yellow
    Write-Host '    1. In-place upgrade / repair install: run setup.exe from a'
    Write-Host '       matching-or-newer ISO with "Keep files and apps".'
    Write-Host '    2. DISM apply of a known-good captured image to a spare volume.'
    Write-Host '    3. Reset this PC (keep files) as a last resort.'
    Write-Host ''
    Write-Host '  Always back up first (main menu -> Backup component store).' -ForegroundColor Yellow
}

#endregion

#region ---------------------------------------------------------------- DISM: analyze / cleanup / resetbase

function Invoke-AnalyzeStore {
    Clear-Host
    Write-Banner ("Analyze Component Store  -  {0}" -f $Script:Target.Label)
    $scope = Get-DismScopeArgs
    Invoke-Native -File 'dism.exe' -Arguments ($scope + @('/Cleanup-Image','/AnalyzeComponentStore')) | Out-Null
    Wait-Menu
}

function Invoke-CleanupStore {
    Clear-Host
    Write-Banner ("Cleanup Component Store  -  {0}" -f $Script:Target.Label)
    Write-Host ''
    Write-Host '   [1] StartComponentCleanup (remove superseded components)'
    Write-Host '   [2] StartComponentCleanup /ResetBase  (WARNING below)'
    Write-Host '   [0] Back'
    Write-Host ''
    $c = Read-Host 'Select'
    $scope = Get-DismScopeArgs
    switch ($c) {
        '1' {
            Invoke-Native -File 'dism.exe' -Arguments ($scope + @('/Cleanup-Image','/StartComponentCleanup')) | Out-Null
            Wait-Menu
        }
        '2' { Invoke-ResetBase }
        default { }
    }
}

function Invoke-ResetBase {
    Clear-Host
    Write-Banner 'RESET BASE  -  /StartComponentCleanup /ResetBase'
    Write-Host ''
    Write-Host '  ****************************  WARNING  ****************************' -ForegroundColor Red
    Write-Host '  ResetBase permanently removes ALL superseded versions of every'    -ForegroundColor Yellow
    Write-Host '  component in the store. After this:'                                 -ForegroundColor Yellow
    Write-Host '    * Installed updates can NO LONGER be uninstalled.'                 -ForegroundColor Yellow
    Write-Host '    * Existing Windows Update packages cannot be removed.'             -ForegroundColor Yellow
    Write-Host '    * The change is IRREVERSIBLE.'                                      -ForegroundColor Yellow
    Write-Host '  Recommended: create a backup first (main menu).'                     -ForegroundColor Yellow
    Write-Host '  *****************************************************************'    -ForegroundColor Red
    if (-not (Confirm-Action 'Proceed with an IRREVERSIBLE ResetBase?' -Danger)) {
        Write-Log 'ResetBase cancelled.' 'INFO'; Wait-Menu; return
    }
    $scope = Get-DismScopeArgs
    Invoke-Native -File 'dism.exe' -Arguments ($scope + @('/Cleanup-Image','/StartComponentCleanup','/ResetBase')) | Out-Null
    Wait-Menu
}

#endregion

#region ---------------------------------------------------------------- Download updates / backups

function Invoke-DownloadMatchingUpdates {
    Clear-Host
    Write-Banner 'Download Updates to Match Current Online Version'
    $cv = Get-CurrentBuild
    Write-Host ''
    Write-Log ("Current online build: {0} (UBR {1})" -f $cv.DisplayVersion, $cv.UBR) 'INFO'
    Write-Host ''
    Write-Host '   [1] Use PSWindowsUpdate module (download only)'
    Write-Host '   [2] Show Microsoft Update Catalog search URL for this build'
    Write-Host '   [3] Trigger Windows Update scan/download (UsoClient)'
    Write-Host '   [0] Back'
    Write-Host ''
    $c = Read-Host 'Select'
    switch ($c) {
        '1' {
            if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
                $i = Read-Host 'PSWindowsUpdate is not installed. Install from PSGallery now? (Y/N)'
                if ($i -match '^[Yy]') {
                    try {
                        Install-Module PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop
                    } catch { Write-Log ("Install failed: {0}" -f $_.Exception.Message) 'ERROR'; Wait-Menu; return }
                } else { Wait-Menu; return }
            }
            Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
            $dir = Read-PathInput 'Download folder [ENTER = work folder]'
            if (-not $dir) { $dir = Join-Path $Script:WorkRoot 'Updates' }
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                Write-Log 'Querying Windows Update for applicable updates (download only)...' 'STEP'
                Get-WindowsUpdate -Download -AcceptAll -NotAutoReboot -Verbose 4>&1 |
                    Tee-Object -FilePath (Join-Path $dir 'pswindowsupdate.log') | Out-Host
                Write-Log "Updates staged. Cache: $env:WinDir\SoftwareDistribution\Download" 'OK'
            } catch { Write-Log ("PSWindowsUpdate error: {0}" -f $_.Exception.Message) 'ERROR' }
        }
        '2' {
            $q = "Windows $($cv.ProductName) $($cv.DisplayVersion) $(if([Environment]::Is64BitOperatingSystem){'x64'}else{'x86'})"
            $url = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($q)
            Write-Host ''
            Write-Host '  Search the Microsoft Update Catalog for the cumulative update'
            Write-Host '  that matches this build, download the .msu/.cab, then use the'
            Write-Host '  "Add drivers/updates to image" menu or Add-WindowsPackage.'
            Write-Host ''
            Write-Host "  $url" -ForegroundColor Cyan
        }
        '3' {
            Invoke-Native -File 'UsoClient.exe' -Arguments @('StartScan')     | Out-Null
            Invoke-Native -File 'UsoClient.exe' -Arguments @('StartDownload') | Out-Null
            Write-Log 'Requested Windows Update scan + download.' 'OK'
        }
        default { }
    }
    Wait-Menu
}

function Get-CurrentBuild {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $p = Get-ItemProperty -Path $k
    [pscustomobject]@{
        ProductName    = $p.ProductName
        DisplayVersion = $p.DisplayVersion
        CurrentBuild   = $p.CurrentBuild
        UBR            = $p.UBR
    }
}

function Invoke-BackupComponentStore {
    Clear-Host
    Write-Banner 'Backup Current Online Component Store'
    Write-Host ''
    Write-Host '  The live WinSxS cannot be copied file-by-file reliably (hardlinks,'
    Write-Host '  locks, ACLs). This creates a consistent capture instead:'
    Write-Host ''
    Write-Host '   [1] Capture a full WIM of the online OS (recommended, VSS-consistent)'
    Write-Host '   [2] Export the servicing state + a shadow-copy of WinSxS via robocopy'
    Write-Host '   [0] Back'
    Write-Host ''
    $c = Read-Host 'Select'
    switch ($c) {
        '1' {
            $dest = Read-PathInput 'Destination .wim path (e.g. E:\Backup\online.wim)'
            if (-not $dest) { Wait-Menu; return }
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force -ErrorAction SilentlyContinue | Out-Null
            try {
                Write-Log 'Capturing online OS to WIM (uses VSS via /CheckIntegrity)...' 'STEP'
                # Native DISM capture supports the live system with a temp scratch.
                Invoke-Native -File 'dism.exe' -Arguments @(
                    '/Capture-Image', "/ImageFile:$dest", "/CaptureDir:$($env:SystemDrive)\",
                    '/Name:OnlineBackup', "/Description:CSM backup $(Get-Date -Format s)",
                    '/Compress:fast','/CheckIntegrity'
                ) | Out-Null
                Write-Log "Backup WIM written: $dest" 'OK'
            } catch { Write-Log ("Backup failed: {0}" -f $_.Exception.Message) 'ERROR' }
        }
        '2' {
            $dest = Read-PathInput 'Destination folder (e.g. E:\Backup\WinSxS)'
            if (-not $dest) { Wait-Menu; return }
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Write-Log 'Creating VSS shadow snapshot for a consistent copy...' 'STEP'
            $shadow = New-VssSnapshot -Volume $env:SystemDrive
            if ($shadow) {
                $srcWinSxS = Join-Path $shadow ('Windows\WinSxS')
                Invoke-Native -File 'robocopy.exe' -Arguments @($srcWinSxS,(Join-Path $dest 'WinSxS'),'/E','/COPYALL','/B','/R:1','/W:1','/NFL','/NDL','/XJ') | Out-Null
                # Also export the CBS/servicing metadata.
                Copy-Item (Join-Path $shadow 'Windows\servicing') (Join-Path $dest 'servicing') -Recurse -Force -ErrorAction SilentlyContinue
                Remove-VssSnapshot
                Write-Log "Backup copied to $dest" 'OK'
            } else {
                Write-Log 'Could not create a VSS snapshot; falling back to a direct /B robocopy.' 'WARN'
                Invoke-Native -File 'robocopy.exe' -Arguments @("$env:SystemRoot\WinSxS",(Join-Path $dest 'WinSxS'),'/E','/COPYALL','/B','/R:1','/W:1','/NFL','/NDL','/XJ') | Out-Null
            }
        }
        default { }
    }
    Wait-Menu
}

$Script:VssShadowId = $null
function New-VssSnapshot {
    param([string]$Volume)
    try {

        $class = [wmiclass]'root\cimv2:Win32_ShadowCopy'
        $out = $class.Create("$Volume\", 'ClientAccessible')
        if ($out.ReturnValue -ne 0) { return $null }
        $Script:VssShadowId = $out.ShadowID
        $sc = Get-CimInstance Win32_ShadowCopy | Where-Object { $_.ID -eq $out.ShadowID }
        return ($sc.DeviceObject + '\')
    } catch { return $null }
}
function Remove-VssSnapshot {
    if ($Script:VssShadowId) {
        try {
            Get-CimInstance Win32_ShadowCopy | Where-Object { $_.ID -eq $Script:VssShadowId } | Remove-CimInstance -ErrorAction SilentlyContinue
        } catch { }
        $Script:VssShadowId = $null
    }
}

function Invoke-BackupDriverStore {
    Clear-Host
    Write-Banner 'Backup Driver Store'
    $dest = Read-PathInput 'Destination folder for exported drivers'
    if (-not $dest) { Wait-Menu; return }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    try {
        if ($Script:Target.Online) {
            Write-Log 'Exporting all third-party drivers (pnputil)...' 'STEP'
            Invoke-Native -File 'pnputil.exe' -Arguments @('/export-driver','*',"$dest") | Out-Null
        } else {
            Write-Log 'Exporting drivers from offline image (Export-WindowsDriver)...' 'STEP'
            Export-WindowsDriver -Path $Script:Target.Path -Destination $dest -ErrorAction Stop | Out-Null
        }
        Write-Log "Driver store backed up to $dest" 'OK'
    } catch { Write-Log ("Driver export failed: {0}" -f $_.Exception.Message) 'ERROR' }
    Wait-Menu
}

#endregion

#region ---------------------------------------------------------------- ISO / image servicing

function Mount-Iso {
    param([string]$IsoPath)
    try {
        $before = (Get-Volume | Where-Object DriveLetter).DriveLetter
        Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -ErrorAction Stop | Out-Null
        Start-Sleep -Milliseconds 700
        $img = Get-DiskImage -ImagePath $IsoPath | Get-Volume
        $drive = $img.DriveLetter
        if (-not $drive) {
            $after = (Get-Volume | Where-Object DriveLetter).DriveLetter
            $drive = ($after | Where-Object { $before -notcontains $_ } | Select-Object -First 1)
        }
        Register-Mount -Type 'ISO' -Path ("$drive`:") -Source $IsoPath
        Write-Log "Mounted ISO $IsoPath at $drive`:" 'OK'
        return $drive
    } catch {
        Write-Log ("Failed to mount ISO: {0}" -f $_.Exception.Message) 'ERROR'
        return $null
    }
}

function Invoke-ServiceImageMenu {
    while ($true) {
        Clear-Host
        Write-Banner 'Add Drivers / Updates to an Installation Image'
        Write-Host ''
        Write-Host '  Auto-mounts the ISO and the chosen boot/install image, applies'
        Write-Host '  drivers/updates, commits + unmounts, and can rebuild a new ISO.'
        Write-Host ''
        Write-Host '   [1] Add drivers to boot.wim and/or install.wim in an ISO'
        Write-Host '   [2] Add updates (.msu/.cab) to boot.wim and/or install.wim in an ISO'
        Write-Host '   [3] Rebuild a new, updated bootable ISO (oscdimg)'
        Write-Host '   [4] Unmount everything I mounted (cleanup now)'
        Write-Host '   [0] Back'
        Write-Host ''
        $c = Read-Host 'Select'
        switch ($c) {
            '1' { Invoke-InjectIntoIso -What 'Drivers' }
            '2' { Invoke-InjectIntoIso -What 'Updates' }
            '3' { Invoke-BuildIso; Wait-Menu }
            '4' { Invoke-CleanupMounts; Wait-Menu }
            '0' { return }
            default { }
        }
    }
}

function Invoke-InjectIntoIso {
    param([ValidateSet('Drivers','Updates')][string]$What)
    Clear-Host
    Write-Banner ("Add {0} to Image" -f $What)

    $iso = Read-PathInput 'Path to source installation ISO'
    if (-not (Test-Path $iso)) { Write-Log 'ISO not found.' 'ERROR'; Wait-Menu; return }

    # ISOs are read-only when mounted. Copy contents to a writable staging tree
    # so images can be serviced and a new ISO rebuilt.
    $stage = Read-PathInput 'Writable staging folder for extracted ISO contents (e.g. E:\ISO_Work)'
    if (-not $stage) { $stage = Join-Path $Script:WorkRoot ('iso_stage_' + [guid]::NewGuid().ToString('N').Substring(0,6)) }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    $drive = Mount-Iso -IsoPath $iso
    if (-not $drive) { Wait-Menu; return }

    Write-Log "Copying ISO contents to staging: $stage" 'STEP'
    Invoke-Native -File 'robocopy.exe' -Arguments @("$drive`:\", $stage, '/E','/COPY:DAT','/R:1','/W:1','/NFL','/NDL') | Out-Null
    # Clear read-only attribute from staged files.
    Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
    # Source ISO no longer needed mounted.
    $isoMount = $Script:Mounts | Where-Object { $_.Type -eq 'ISO' -and $_.Source -eq $iso } | Select-Object -First 1
    if ($isoMount) { Dismount-One -M $isoMount; $Script:Mounts.Remove($isoMount) | Out-Null }

    $Script:LastStage = $stage   # remembered for "Rebuild ISO"

    # Gather payload path.
    if ($What -eq 'Drivers') {
        $payload = Read-PathInput 'Folder containing driver .inf files (searched recursively)'
    } else {
        $payload = Read-PathInput 'Folder OR file with .msu/.cab update package(s)'
    }
    if (-not $payload -or -not (Test-Path $payload)) { Write-Log 'Payload path not found.' 'ERROR'; Wait-Menu; return }

    # Which images to service?
    Write-Host ''
    Write-Host '   [1] boot.wim only        (WinPE / Setup)'
    Write-Host '   [2] install.wim only     (deployed OS)'
    Write-Host '   [3] both'
    $pick = Read-Host 'Service which image(s)?'
    $targets = switch ($pick) { '1' { @('boot') } '2' { @('install') } default { @('boot','install') } }

    foreach ($t in $targets) {
        $wimFile = Join-Path $stage ("sources\{0}.wim" -f $t)
        if (-not (Test-Path $wimFile)) {
            # install may be .esd
            $esd = Join-Path $stage 'sources\install.esd'
            if ($t -eq 'install' -and (Test-Path $esd)) {
                Write-Log 'install.esd found; converting to install.wim for servicing...' 'STEP'
                $wimFile = Join-Path $stage 'sources\install.wim'
                Export-EsdToWim -Esd $esd -Wim $wimFile
            } else {
                Write-Log "Missing $wimFile - skipping." 'WARN'; continue
            }
        }

        # For drivers: back up the existing driver store of each image first.
        $indices = Get-ImageIndices -WimFile $wimFile -ImageKind $t
        foreach ($ix in $indices) {
            $mp = New-MountDir ("{0}_{1}" -f $t,$ix)
            try {
                Write-Log ("Mounting {0}.wim index {1} -> {2}" -f $t,$ix,$mp) 'STEP'
                Mount-WindowsImage -ImagePath $wimFile -Index $ix -Path $mp -ErrorAction Stop | Out-Null
                Register-Mount -Type 'WIM' -Path $mp -Source $wimFile -Extra @{ Index = $ix }

                if ($What -eq 'Drivers') {
                    # Backup the image's existing driver store before injecting.
                    $bk = Join-Path $Script:WorkRoot ("driverbackup_{0}_{1}_{2}" -f $t,$ix,(Get-Date -Format HHmmss))
                    New-Item -ItemType Directory -Path $bk -Force | Out-Null
                    Write-Log "Backing up existing driver store -> $bk" 'STEP'
                    try { Export-WindowsDriver -Path $mp -Destination $bk -ErrorAction Stop | Out-Null } catch { Write-Log "  (no third-party drivers to back up)" 'INFO' }

                    Write-Log 'Adding drivers (recurse, unsigned allowed for boot media)...' 'STEP'
                    Add-WindowsDriver -Path $mp -Driver $payload -Recurse -ForceUnsigned -ErrorAction Stop | Out-Null
                } else {
                    Write-Log 'Adding update package(s)...' 'STEP'
                    Add-WindowsPackage -Path $mp -PackagePath $payload -ErrorAction Stop | Out-Null
                }

                # Commit + unmount this image.
                $m = $Script:Mounts | Where-Object { $_.Type -eq 'WIM' -and $_.Path -eq $mp } | Select-Object -First 1
                Dismount-One -M $m -Commit
                if ($m) { $Script:Mounts.Remove($m) | Out-Null }
            } catch {
                Write-Log ("Servicing {0} index {1} failed: {2}" -f $t,$ix,$_.Exception.Message) 'ERROR'
                $m = $Script:Mounts | Where-Object { $_.Type -eq 'WIM' -and $_.Path -eq $mp } | Select-Object -First 1
                if ($m) { Dismount-One -M $m; $Script:Mounts.Remove($m) | Out-Null }
            }
        }
    }

    Write-Host ''
    Write-Log ("Done. Staged, serviced tree: {0}" -f $stage) 'OK'
    $bld = Read-Host 'Rebuild an updated bootable ISO from this staged tree now? (Y/N)'
    if ($bld -match '^[Yy]') { Invoke-BuildIso -Stage $stage }
    Wait-Menu
}

function Get-ImageIndices {
    param([string]$WimFile,[string]$ImageKind)
    $imgs = Get-WindowsImage -ImagePath $WimFile
    Write-Host ''
    $imgs | Select-Object ImageIndex, ImageName | Format-Table -AutoSize | Out-String | Write-Host
    if ($imgs.Count -eq 1) { return @($imgs[0].ImageIndex) }
    $sel = Read-Host ("Index(es) of {0}.wim to service (comma sep, or ALL)" -f $ImageKind)
    if ($sel -match '^(?i)all$') { return $imgs.ImageIndex }
    return ($sel -split ',' | ForEach-Object { [int]($_.Trim()) } | Where-Object { $_ })
}

function Export-EsdToWim {
    param([string]$Esd,[string]$Wim)
    $imgs = Get-WindowsImage -ImagePath $Esd
    foreach ($i in $imgs) {
        Export-WindowsImage -SourceImagePath $Esd -SourceIndex $i.ImageIndex `
            -DestinationImagePath $Wim -CompressionType Max -ErrorAction Stop | Out-Null
    }
}

function Invoke-BuildIso {
    param([string]$Stage)
    Clear-Host
    Write-Banner 'Create New Updated ISO Package (oscdimg)'
    if (-not $Stage) { $Stage = $Script:LastStage }
    if (-not $Stage) { $Stage = Read-PathInput 'Path to the staged (serviced) ISO tree' }
    if (-not $Stage -or -not (Test-Path $Stage)) { Write-Log 'Staged tree not found.' 'ERROR'; return }

    $oscdimg = Get-OscdimgPath
    if (-not $oscdimg) {
        Write-Log 'oscdimg.exe not found. Install the Windows ADK "Deployment Tools".' 'ERROR'
        Write-Host '  Expected under: %ProgramFiles(x86)%\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\<arch>\Oscdimg' -ForegroundColor Yellow
        return
    }

    $out = Read-PathInput 'Output ISO path (e.g. E:\Windows_Updated.iso)'
    if (-not $out) { return }

    $etfs = Join-Path $Stage 'boot\etfsboot.com'
    $efi  = Join-Path $Stage 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path $etfs)) { $etfs = Join-Path $Stage 'boot\etfsboot.com' }

    if ((Test-Path $etfs) -and (Test-Path $efi)) {
        $bootData = "2#p0,e,b`"$etfs`"#pEF,e,b`"$efi`""
        $oscArgs = @('-m','-o','-u2','-udfver102',"-bootdata:$bootData", $Stage, $out)
    } elseif (Test-Path $efi) {
        $oscArgs = @('-m','-o','-u2','-udfver102',"-b$efi", $Stage, $out)
    } else {
        Write-Log 'No boot sectors found in staged tree; building a non-bootable UDF ISO.' 'WARN'
        $oscArgs = @('-m','-o','-u2','-udfver102', $Stage, $out)
    }
    Invoke-Native -File $oscdimg -Arguments $oscArgs | Out-Null
    if (Test-Path $out) { Write-Log "New ISO created: $out" 'OK' }
}

function Get-OscdimgPath {
    $cmd = Get-Command 'oscdimg.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools"
    )
    foreach ($r in $roots) {
        if (Test-Path $r) {
            $f = Get-ChildItem $r -Recurse -Filter 'oscdimg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
    }
    return $null
}

#endregion

#region ---------------------------------------------------------------- Reporting (PDF / HTML / HTA)

function Convert-SizeToBytes {
    param([string]$Text)
    if (-not $Text) { return 0 }
    if ($Text -match '([\d\.,]+)\s*(KB|MB|GB|TB|bytes|B)') {
        $num  = [double]($Matches[1] -replace ',', '')
        switch ($Matches[2].ToUpper()) {
            'KB'    { return [long]($num * 1KB) }
            'MB'    { return [long]($num * 1MB) }
            'GB'    { return [long]($num * 1GB) }
            'TB'    { return [long]($num * 1TB) }
            default { return [long]$num }
        }
    }
    return 0
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ("$Bytes bytes")
}

function Get-AnalyzeStoreData {
    <#
        Runs (online) AnalyzeComponentStore and parses the DISM report into a
        structured object. Offline images do not support this DISM feature.
    #>
    if (-not $Script:Target.Online) { return $null }
    Write-Log 'Analyzing component store for the report (this can take a minute)...' 'STEP'
    $raw = & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-String
    try { Add-Content -Path $Script:LogFile -Value $raw -Encoding UTF8 } catch { }

    function _grab([string]$label) {
        $m = [regex]::Match($raw, [regex]::Escape($label) + '\s*:\s*(.+)')
        if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $null }
    }

    [pscustomobject]@{
        Raw            = $raw
        ReportedSize   = _grab 'Windows Explorer Reported Size of Component Store'
        ActualSize     = _grab 'Actual Size of Component Store'
        SharedWindows  = _grab 'Shared with Windows'
        BackupsDisabled= _grab 'Backups and Disabled Features'
        CacheTemp      = _grab 'Cache and Temporary Data'
        LastCleanup    = _grab 'Date of Last Cleanup'
        Reclaimable    = _grab 'Number of Reclaimable Packages'
        CleanupRec     = _grab 'Component Store Cleanup Recommended'
    }
}

function Get-ReportData {
    Write-Log 'Collecting report data...' 'STEP'
    $img   = Get-ImageArgs
    $build = Get-CurrentBuild

    # Health (quick CheckHealth)
    $health = 'Unknown'
    try { $health = "$((Repair-WindowsImage @img -CheckHealth -ErrorAction Stop).ImageHealthState)" } catch { }

    # Packages
    $pkgTotal = 0; $pkgByState = @{}
    try {
        $pkgs = if ($Script:Target.Online) { Get-WindowsPackage -Online -ErrorAction Stop }
                else { Get-WindowsPackage -Path $Script:Target.Path -ErrorAction Stop }
        $pkgTotal = @($pkgs).Count
        $pkgs | Group-Object PackageState | ForEach-Object { $pkgByState[$_.Name] = $_.Count }
    } catch { Write-Log ("Package enumeration skipped: {0}" -f $_.Exception.Message) 'WARN' }

    # Features
    $featEnabled = 0; $featDisabled = 0
    try {
        $feats = if ($Script:Target.Online) { Get-WindowsOptionalFeature -Online -ErrorAction Stop }
                 else { Get-WindowsOptionalFeature -Path $Script:Target.Path -ErrorAction Stop }
        $featEnabled  = @($feats | Where-Object State -eq 'Enabled').Count
        $featDisabled = @($feats | Where-Object State -ne 'Enabled').Count
    } catch { Write-Log ("Feature enumeration skipped: {0}" -f $_.Exception.Message) 'WARN' }

    # Third-party drivers
    $drvCount = 0
    try {
        $drv = if ($Script:Target.Online) { Get-WindowsDriver -Online -ErrorAction Stop }
               else { Get-WindowsDriver -Path $Script:Target.Path -ErrorAction Stop }
        $drvCount = @($drv).Count
    } catch { Write-Log ("Driver enumeration skipped: {0}" -f $_.Exception.Message) 'WARN' }

    # Disk (online only, system drive)
    $disk = $null
    try {
        if ($Script:Target.Online) {
            $sysDrive = ($env:SystemDrive).TrimEnd(':')
            $v = Get-Volume -DriveLetter $sysDrive -ErrorAction Stop
            $disk = [pscustomobject]@{
                Drive = $sysDrive; SizeBytes = $v.Size; FreeBytes = $v.SizeRemaining
                UsedBytes = ($v.Size - $v.SizeRemaining)
            }
        }
    } catch { }

    [pscustomobject]@{
        Generated    = Get-Date
        Machine      = $env:COMPUTERNAME
        Identity     = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Privilege    = Get-PrivilegeLevel
        TargetLabel  = $Script:Target.Label
        IsOnline     = $Script:Target.Online
        Build        = $build
        Health       = $health
        Analyze      = Get-AnalyzeStoreData
        PkgTotal     = $pkgTotal
        PkgByState   = $pkgByState
        FeatEnabled  = $featEnabled
        FeatDisabled = $featDisabled
        DriverCount  = $drvCount
        Disk         = $disk
    }
}

# ---- SVG chart helpers -------------------------------------------------------

function New-DonutSvg {
    param([object[]]$Segments,[string]$CenterText='',[int]$Size=190)
    $r = 62; $stroke = 24; $circ = 2 * [math]::PI * $r
    $total = ($Segments | Measure-Object -Property Value -Sum).Sum
    if ($total -le 0) { $total = 1 }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<svg viewBox='0 0 190 190' width='$Size' height='$Size' class='donut' role='img'>")
    [void]$sb.Append("<circle cx='95' cy='95' r='$r' fill='none' stroke='#eef1f6' stroke-width='$stroke'/>")
    $offset = 0.0
    foreach ($s in $Segments) {
        if ($s.Value -le 0) { continue }
        $dash = ($s.Value / $total) * $circ
        $gap  = $circ - $dash
        [void]$sb.Append("<circle cx='95' cy='95' r='$r' fill='none' stroke='$($s.Color)' stroke-width='$stroke' stroke-linecap='butt' stroke-dasharray='$([math]::Round($dash,2)) $([math]::Round($gap,2))' stroke-dashoffset='$([math]::Round(-$offset,2))' transform='rotate(-90 95 95)'/>")
        $offset += $dash
    }
    if ($CenterText) {
        $lines = $CenterText -split '\|'
        $y = 95 - (($lines.Count - 1) * 11)
        foreach ($ln in $lines) {
            [void]$sb.Append("<text x='95' y='$($y+5)' text-anchor='middle' class='donut-c'>$ln</text>")
            $y += 22
        }
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-LegendHtml {
    param([object[]]$Segments)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<ul class='legend'>")
    foreach ($s in $Segments) {
        [void]$sb.Append("<li><span class='sw' style='background:$($s.Color)'></span>$($s.Label) <b>$($s.Display)</b></li>")
    }
    [void]$sb.Append('</ul>')
    return $sb.ToString()
}

function New-BarSvg {
    param([object[]]$Items,[int]$Width=460)
    $max = ($Items | Measure-Object -Property Value -Max).Max
    if ($max -le 0) { $max = 1 }
    $rowH = 40; $labelW = 150; $barMax = $Width - $labelW - 60
    $h = ($Items.Count * $rowH) + 10
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<svg viewBox='0 0 $Width $h' width='100%' height='$h' class='bars' role='img'>")
    $y = 8
    foreach ($it in $Items) {
        $w = [math]::Max(2, [int](($it.Value / $max) * $barMax))
        [void]$sb.Append("<text x='0' y='$($y+20)' class='bar-lbl'>$($it.Label)</text>")
        [void]$sb.Append("<rect x='$labelW' y='$($y+4)' width='$barMax' height='20' rx='5' fill='#eef1f6'/>")
        [void]$sb.Append("<rect x='$labelW' y='$($y+4)' width='$w' height='20' rx='5' fill='$($it.Color)'/>")
        [void]$sb.Append("<text x='$($labelW+$w+8)' y='$($y+20)' class='bar-val'>$($it.Value)</text>")
        $y += $rowH
    }
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function Get-HealthMeta {
    param([string]$State)
    switch ($State) {
        'Healthy'       { @{ Color='#1a9d6b'; Bg='#e6f7f0'; Icon='&#10003;'; Text='HEALTHY' } }
        'Repairable'    { @{ Color='#d98a00'; Bg='#fff5e0'; Icon='&#9888;';  Text='REPAIRABLE' } }
        'NonRepairable' { @{ Color='#d1373a'; Bg='#fdeaea'; Icon='&#10007;'; Text='NON-REPAIRABLE' } }
        default         { @{ Color='#5b6472'; Bg='#eef1f6'; Icon='?';        Text='UNKNOWN' } }
    }
}

function Get-Recommendations {
    param($Data)
    $recs = New-Object System.Collections.Generic.List[string]
    switch ($Data.Health) {
        'Repairable'    { $recs.Add('Component store corruption detected. Run RestoreHealth; if it fails, use Advanced Repair with a matching known-good source.') }
        'NonRepairable' { $recs.Add('Store is non-repairable by servicing. Plan an in-place upgrade / repair install after backing up.') }
        'Healthy'       { $recs.Add('No component-store corruption detected by CheckHealth. A full ScanHealth is still recommended periodically.') }
    }
    if ($Data.Analyze) {
        if ($Data.Analyze.CleanupRec -match 'Yes') {
            $recs.Add("DISM recommends a component-store cleanup. Run StartComponentCleanup to reclaim space ($($Data.Analyze.Reclaimable) reclaimable package(s)).")
        }
        if ($Data.Analyze.Reclaimable -and $Data.Analyze.Reclaimable -notmatch '^0') {
            $recs.Add('Reclaimable packages are present; consider StartComponentCleanup (optionally /ResetBase once you no longer need to uninstall updates).')
        }
    }
    if ($Data.Disk -and $Data.Disk.SizeBytes -gt 0) {
        $freePct = [math]::Round(($Data.Disk.FreeBytes / $Data.Disk.SizeBytes) * 100, 0)
        if ($freePct -lt 15) { $recs.Add("System drive is low on space ($freePct% free). Component-store cleanup and update caches should be reviewed.") }
    }
    $recs.Add('Create a backup of the component store before any ResetBase or overwrite-repair operation.')
    return $recs
}

function ConvertTo-ReportHtml {
    param($Data)
    $hm  = Get-HealthMeta $Data.Health
    $gen = $Data.Generated.ToString('yyyy-MM-dd HH:mm:ss')
    $b   = $Data.Build

    # --- Store composition donut (online analyze only) ---
    $storeSection = ''
    if ($Data.Analyze -and $Data.Analyze.ActualSize) {
        $shared = Convert-SizeToBytes $Data.Analyze.SharedWindows
        $backup = Convert-SizeToBytes $Data.Analyze.BackupsDisabled
        $cache  = Convert-SizeToBytes $Data.Analyze.CacheTemp
        $actual = Convert-SizeToBytes $Data.Analyze.ActualSize
        $unique = [math]::Max(0, $actual - $shared - $backup - $cache)
        $segs = @(
            [pscustomobject]@{ Label='Shared with Windows';    Value=$shared; Color='#2f6fed'; Display=$Data.Analyze.SharedWindows }
            [pscustomobject]@{ Label='Unique store payload';   Value=$unique; Color='#12b5b0'; Display=(Format-Bytes $unique) }
            [pscustomobject]@{ Label='Backups & disabled';     Value=$backup; Color='#d98a00'; Display=$Data.Analyze.BackupsDisabled }
            [pscustomobject]@{ Label='Cache & temporary';      Value=$cache;  Color='#a05bd6'; Display=$Data.Analyze.CacheTemp }
        )
        $donut  = New-DonutSvg -Segments $segs -CenterText ("$($Data.Analyze.ActualSize)|actual")
        $legend = New-LegendHtml -Segments $segs
        $storeSection = @"
      <div class="card span2">
        <h2>Component Store Composition</h2>
        <div class="split">
          <div class="chartbox">$donut</div>
          <div class="chartinfo">
            $legend
            <table class="mini">
              <tr><td>Explorer-reported size</td><td>$($Data.Analyze.ReportedSize)</td></tr>
              <tr><td>Actual size on disk</td><td>$($Data.Analyze.ActualSize)</td></tr>
              <tr><td>Reclaimable packages</td><td>$($Data.Analyze.Reclaimable)</td></tr>
              <tr><td>Last cleanup</td><td>$($Data.Analyze.LastCleanup)</td></tr>
              <tr><td>Cleanup recommended</td><td><b>$($Data.Analyze.CleanupRec)</b></td></tr>
            </table>
          </div>
        </div>
      </div>
"@
    } else {
        $storeSection = @"
      <div class="card span2">
        <h2>Component Store Composition</h2>
        <p class="muted">Detailed store-size analysis (DISM AnalyzeComponentStore) is only available for the <b>online</b> image. This report targets an offline image, so composition metrics are omitted.</p>
      </div>
"@
    }

    # --- Inventory bar chart ---
    $barItems = @(
        [pscustomobject]@{ Label='Packages';          Value=$Data.PkgTotal;     Color='#2f6fed' }
        [pscustomobject]@{ Label='Features enabled';  Value=$Data.FeatEnabled;  Color='#1a9d6b' }
        [pscustomobject]@{ Label='Features disabled'; Value=$Data.FeatDisabled; Color='#9aa4b2' }
        [pscustomobject]@{ Label='3rd-party drivers'; Value=$Data.DriverCount;  Color='#12b5b0' }
    )
    $bars = New-BarSvg -Items $barItems

    # --- Package-state table ---
    $pkgRows = ''
    foreach ($k in ($Data.PkgByState.Keys | Sort-Object)) {
        $pkgRows += "<tr><td>$k</td><td>$($Data.PkgByState[$k])</td></tr>"
    }
    if (-not $pkgRows) { $pkgRows = "<tr><td colspan='2' class='muted'>No package data collected.</td></tr>" }

    # --- Disk donut (online) ---
    $diskSection = ''
    if ($Data.Disk) {
        $usedPct = [math]::Round(($Data.Disk.UsedBytes / $Data.Disk.SizeBytes) * 100, 0)
        $dsegs = @(
            [pscustomobject]@{ Label='Used'; Value=$Data.Disk.UsedBytes; Color='#2f6fed'; Display=(Format-Bytes $Data.Disk.UsedBytes) }
            [pscustomobject]@{ Label='Free'; Value=$Data.Disk.FreeBytes; Color='#1a9d6b'; Display=(Format-Bytes $Data.Disk.FreeBytes) }
        )
        $ddonut = New-DonutSvg -Segments $dsegs -CenterText ("$usedPct%|used")
        $dleg   = New-LegendHtml -Segments $dsegs
        $diskSection = @"
      <div class="card">
        <h2>System Drive ($($Data.Disk.Drive):)</h2>
        <div class="chartbox">$ddonut</div>
        $dleg
      </div>
"@
    }

    # --- Recommendations ---
    $recHtml = ''
    foreach ($r in (Get-Recommendations $Data)) { $recHtml += "<li>$r</li>" }

    $arch = if ([Environment]::Is64BitOperatingSystem) { '64-bit (x64)' } else { '32-bit (x86)' }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Component Store Report - $($Data.Machine)</title>
<style>
  :root { --ink:#1d2530; --muted:#5b6472; --line:#e3e8ef; --accent:#2f6fed; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:'Segoe UI',system-ui,Arial,sans-serif; color:var(--ink); background:#f4f6fa; }
  .wrap { max-width:1000px; margin:0 auto; padding:28px; }
  header.hero { background:linear-gradient(135deg,#1f3a8a 0%,#2f6fed 55%,#12b5b0 100%); color:#fff; border-radius:16px; padding:28px 32px; box-shadow:0 10px 30px rgba(31,58,138,.25); }
  header.hero h1 { margin:0 0 4px; font-size:26px; letter-spacing:.3px; }
  header.hero .sub { opacity:.9; font-size:13px; }
  .herometa { display:flex; flex-wrap:wrap; gap:24px; margin-top:18px; }
  .herometa div span { display:block; font-size:11px; text-transform:uppercase; letter-spacing:.8px; opacity:.8; }
  .herometa div b { font-size:15px; }
  .grid { display:grid; grid-template-columns:1fr 1fr; gap:18px; margin-top:22px; }
  .card { background:#fff; border:1px solid var(--line); border-radius:14px; padding:20px 22px; box-shadow:0 2px 8px rgba(20,30,50,.04); }
  .card.span2 { grid-column:1 / -1; }
  .card h2 { margin:0 0 14px; font-size:15px; text-transform:uppercase; letter-spacing:.6px; color:var(--muted); }
  .statusbig { display:flex; align-items:center; gap:18px; }
  .badge { display:flex; align-items:center; justify-content:center; width:88px; height:88px; border-radius:50%; font-size:40px; font-weight:700; }
  .statusbig .txt b { font-size:24px; display:block; }
  .statusbig .txt span { color:var(--muted); font-size:13px; }
  .tiles { display:flex; flex-wrap:wrap; gap:14px; }
  .tile { flex:1 1 120px; background:#f8fafc; border:1px solid var(--line); border-radius:12px; padding:14px 16px; text-align:center; }
  .tile b { display:block; font-size:26px; color:var(--accent); }
  .tile span { font-size:12px; color:var(--muted); }
  .split { display:flex; gap:24px; align-items:center; flex-wrap:wrap; }
  .chartbox { flex:0 0 auto; }
  .chartinfo { flex:1 1 260px; }
  .donut-c { font-size:17px; font-weight:700; fill:var(--ink); } .donut-c:last-child { font-size:11px; fill:var(--muted); font-weight:500; }
  ul.legend { list-style:none; margin:0 0 12px; padding:0; }
  ul.legend li { font-size:13px; margin:6px 0; color:var(--muted); }
  ul.legend .sw { display:inline-block; width:12px; height:12px; border-radius:3px; margin-right:8px; vertical-align:middle; }
  ul.legend b { color:var(--ink); float:right; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  table.mini td { padding:6px 4px; border-bottom:1px solid var(--line); }
  table.data th, table.data td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); }
  table.data th { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.5px; }
  table.data tr:nth-child(even) td { background:#f8fafc; }
  .bar-lbl { font-size:12px; fill:var(--ink); } .bar-val { font-size:12px; fill:var(--muted); font-weight:600; }
  ul.recs { margin:0; padding-left:20px; } ul.recs li { margin:8px 0; font-size:13px; }
  .muted { color:var(--muted); font-size:13px; }
  footer { text-align:center; color:var(--muted); font-size:11px; margin:26px 0 6px; }
  @media print { body { background:#fff; } .wrap { max-width:100%; padding:0; } .card { break-inside:avoid; box-shadow:none; } header.hero { box-shadow:none; } .grid { gap:12px; } }
</style>
</head>
<body>
  <div class="wrap">
    <header class="hero">
      <h1>Windows Component Store Report</h1>
      <div class="sub">Generated by $Script:AppName v$Script:AppVersion &middot; $gen</div>
      <div class="herometa">
        <div><span>Machine</span><b>$($Data.Machine)</b></div>
        <div><span>Target</span><b>$(if($Data.IsOnline){'Online (running OS)'}else{'Offline image'})</b></div>
        <div><span>Privilege context</span><b>$($Data.Privilege)</b></div>
        <div><span>Edition</span><b>$($b.ProductName)</b></div>
        <div><span>Version / Build</span><b>$($b.DisplayVersion) &middot; $($b.CurrentBuild).$($b.UBR)</b></div>
        <div><span>Architecture</span><b>$arch</b></div>
      </div>
    </header>

    <div class="grid">
      <div class="card">
        <h2>Store Health (CheckHealth)</h2>
        <div class="statusbig">
          <div class="badge" style="background:$($hm.Bg);color:$($hm.Color)">$($hm.Icon)</div>
          <div class="txt"><b style="color:$($hm.Color)">$($hm.Text)</b><span>DISM image health state: $($Data.Health)</span></div>
        </div>
      </div>

      <div class="card">
        <h2>Servicing Inventory</h2>
        <div class="tiles">
          <div class="tile"><b>$($Data.PkgTotal)</b><span>Packages</span></div>
          <div class="tile"><b>$($Data.FeatEnabled)</b><span>Features on</span></div>
          <div class="tile"><b>$($Data.DriverCount)</b><span>3rd-party drivers</span></div>
        </div>
      </div>

$storeSection

      <div class="card">
        <h2>Inventory Overview</h2>
        $bars
      </div>

$diskSection

      <div class="card">
        <h2>Packages by State</h2>
        <table class="data"><thead><tr><th>Package state</th><th>Count</th></tr></thead>
        <tbody>$pkgRows</tbody></table>
      </div>

      <div class="card span2">
        <h2>Recommendations</h2>
        <ul class="recs">$recHtml</ul>
      </div>

      <div class="card span2">
        <h2>Target Details</h2>
        <table class="mini">
          <tr><td>Report target</td><td>$($Data.TargetLabel)</td></tr>
          <tr><td>Running identity</td><td>$($Data.Identity)</td></tr>
          <tr><td>Active privilege level</td><td>$($Data.Privilege)</td></tr>
          <tr><td>OS install product</td><td>$($b.ProductName)</td></tr>
        </table>
      </div>
    </div>

    <footer>
      $Script:AppName v$Script:AppVersion &middot; Report generated $gen &middot; This report is informational; verify with a full ScanHealth before servicing decisions.
    </footer>
  </div>
</body>
</html>
"@
    return $html
}

function Get-HtmlToPdfEngine {
    $paths = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    $c = Get-Command msedge.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Export-ReportPdf {
    param([string]$HtmlPath,[string]$PdfPath)
    $engine = Get-HtmlToPdfEngine
    if (-not $engine) {
        Write-Log 'No Edge/Chrome engine found for PDF rendering. HTML/HTA still produced.' 'WARN'
        return $false
    }
    $uri = ([System.Uri]$HtmlPath).AbsoluteUri
    $profileDir = Join-Path $env:TEMP ('csm_pdf_' + [guid]::NewGuid().ToString('N').Substring(0,6))
    $pdfArgs = @(
        '--headless=new','--disable-gpu','--no-first-run','--disable-extensions',
        "--user-data-dir=$profileDir",
        '--no-pdf-header-footer',
        "--print-to-pdf=$PdfPath",
        $uri
    )
    try {
        Write-Log ("Rendering PDF via {0} ..." -f (Split-Path $engine -Leaf)) 'STEP'
        Start-Process -FilePath $engine -ArgumentList $pdfArgs -WindowStyle Hidden -Wait
        Start-Sleep -Milliseconds 400
        Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $PdfPath) { return $true }
        # Older builds: retry with legacy --headless and --print-to-pdf-no-header
        $pdfArgs2 = @('--headless','--disable-gpu',"--user-data-dir=$profileDir",'--print-to-pdf-no-header',"--print-to-pdf=$PdfPath",$uri)
        Start-Process -FilePath $engine -ArgumentList $pdfArgs2 -WindowStyle Hidden -Wait | Out-Null
        Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue
        return (Test-Path $PdfPath)
    } catch {
        Write-Log ("PDF render failed: {0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

function ConvertTo-HtaContent {
    param([string]$Html,[string]$Title)
    $htaHeader = @"
<hta:application id="csmReport"
  applicationname="Component Store Report"
  caption="yes" border="thin" sysmenu="yes" maximizebutton="yes"
  minimizebutton="yes" showintaskbar="yes" singleinstance="yes"
  scroll="yes" innerborder="no" contextmenu="no" />
<meta http-equiv="x-ua-compatible" content="ie=edge">
"@
    # Inject the HTA application tag right after <head>.
    return ($Html -replace '(?i)<head>', "<head>`r`n$htaHeader")
}

function Invoke-CreateReport {
    Clear-Host
    Write-Banner ("Create Detailed Report  -  {0}" -f $Script:Target.Label)
    Write-Host ''
    Write-Host '  Produces a professional report of the selected component store as:'
    Write-Host '    * .html  (portable, opens in any browser)'
    Write-Host '    * .hta   (standalone HTML Application, double-click to run)'
    Write-Host '    * .pdf   (rendered with graphics via Edge/Chrome headless)'
    Write-Host ''

    $outDir = Read-PathInput 'Output folder [ENTER = work folder\Reports]'
    if (-not $outDir) { $outDir = Join-Path $Script:WorkRoot 'Reports' }
    New-Item -ItemType Directory -Path $outDir -Force -ErrorAction SilentlyContinue | Out-Null

    $stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $scope    = if ($Script:Target.Online) { 'Online' } else { 'Offline' }
    $baseName = "ComponentStoreReport_{0}_{1}_{2}" -f $env:COMPUTERNAME, $scope, $stamp
    $htmlPath = Join-Path $outDir "$baseName.html"
    $htaPath  = Join-Path $outDir "$baseName.hta"
    $pdfPath  = Join-Path $outDir "$baseName.pdf"

    $data = Get-ReportData
    Write-Log 'Rendering HTML...' 'STEP'
    $html = ConvertTo-ReportHtml -Data $data

    Set-Content -Path $htmlPath -Value $html -Encoding UTF8
    Write-Log "HTML written: $htmlPath" 'OK'

    $hta = ConvertTo-HtaContent -Html $html -Title 'Component Store Report'
    Set-Content -Path $htaPath -Value $hta -Encoding UTF8
    Write-Log "HTA written : $htaPath" 'OK'

    if (Export-ReportPdf -HtmlPath $htmlPath -PdfPath $pdfPath) {
        Write-Log "PDF written : $pdfPath" 'OK'
    }

    Write-Host ''
    $open = Read-Host 'Open the report now? (P=PDF, H=HTML, N=No)'
    switch -Regex ($open) {
        '^[Pp]' { if (Test-Path $pdfPath) { Start-Process $pdfPath } else { Start-Process $htmlPath } }
        '^[Hh]' { Start-Process $htmlPath }
        default { }
    }
    Wait-Menu
}

#endregion

#region ---------------------------------------------------------------- Performance & Memory

function Add-MemToolsType {
    if ('CSM.MemTools' -as [type]) { return }
    $code = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CSM
{
    public static class MemTools
    {
        [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr hProcess);
        [DllImport("ntdll.dll")] static extern int  NtSetSystemInformation(int infoClass, ref int info, int length);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetSystemFileCacheSize(IntPtr min, IntPtr max, int flags);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool LookupPrivilegeValue(string system, string name, out long luid);
        [DllImport("advapi32.dll", SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES newState, int len, IntPtr prev, IntPtr retLen);

        [StructLayout(LayoutKind.Sequential)]
        struct TOKEN_PRIVILEGES { public int Count; public long Luid; public int Attributes; }

        const int  SystemMemoryListInformation = 0x50; // 80
        const uint TOKEN_ADJUST_PRIVILEGES = 0x20, TOKEN_QUERY = 0x8;
        const int  SE_PRIVILEGE_ENABLED = 0x2;

        // MEMORY_LIST_COMMAND values
        const int MemoryFlushModifiedList        = 3;
        const int MemoryPurgeStandbyList         = 4;
        const int MemoryPurgeLowPriorityStandby  = 5;

        static bool EnablePrivilege(string name)
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token)) return false;
            long luid;
            if (!LookupPrivilegeValue(null, name, out luid)) return false;
            var tp = new TOKEN_PRIVILEGES { Count = 1, Luid = luid, Attributes = SE_PRIVILEGE_ENABLED };
            return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }

        // Trim the working set of every accessible process.
        public static int EmptyWorkingSets()
        {
            int count = 0;
            foreach (var p in Process.GetProcesses())
            {
                try { if (EmptyWorkingSet(p.Handle)) count++; } catch { }
                finally { try { p.Dispose(); } catch { } }
            }
            return count;
        }

        public static bool PurgeStandbyList()
        {
            EnablePrivilege("SeProfileSingleProcessPrivilege");
            int cmd = MemoryPurgeStandbyList;
            return NtSetSystemInformation(SystemMemoryListInformation, ref cmd, sizeof(int)) == 0;
        }
        public static bool PurgeLowPriorityStandby()
        {
            EnablePrivilege("SeProfileSingleProcessPrivilege");
            int cmd = MemoryPurgeLowPriorityStandby;
            return NtSetSystemInformation(SystemMemoryListInformation, ref cmd, sizeof(int)) == 0;
        }
        public static bool FlushModifiedList()
        {
            EnablePrivilege("SeProfileSingleProcessPrivilege");
            int cmd = MemoryFlushModifiedList;
            return NtSetSystemInformation(SystemMemoryListInformation, ref cmd, sizeof(int)) == 0;
        }
        public static bool ClearFileCache()
        {
            EnablePrivilege("SeIncreaseQuotaPrivilege");
            return SetSystemFileCacheSize(new IntPtr(-1), new IntPtr(-1), 0);
        }
    }
}
'@
    Add-Type -TypeDefinition $code -ErrorAction Stop
}

function Get-MemoryStatus {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalB = [long]$os.TotalVisibleMemorySize * 1KB
    $freeB  = [long]$os.FreePhysicalMemory   * 1KB
    $usedB  = $totalB - $freeB

    $cachedB = 0; $standbyB = 0; $modifiedB = 0
    try { $cachedB   = [long](Get-Counter '\Memory\Cache Bytes' -ErrorAction Stop).CounterSamples[0].CookedValue } catch { }
    try {
        $s = 0
        foreach ($ctr in '\Memory\Standby Cache Core Bytes','\Memory\Standby Cache Normal Priority Bytes','\Memory\Standby Cache Reserve Bytes') {
            try { $s += [long](Get-Counter $ctr -ErrorAction Stop).CounterSamples[0].CookedValue } catch { }
        }
        $standbyB = $s
    } catch { }
    try { $modifiedB = [long](Get-Counter '\Memory\Modified Page List Bytes' -ErrorAction Stop).CounterSamples[0].CookedValue } catch { }

    [pscustomobject]@{
        TotalB=$totalB; UsedB=$usedB; FreeB=$freeB; CachedB=$cachedB; StandbyB=$standbyB; ModifiedB=$modifiedB
        UsedPct = if ($totalB) { [math]::Round(($usedB/$totalB)*100,1) } else { 0 }
    }
}

function Show-MemoryStatus {
    param($M,[string]$Header='Memory Status')
    if (-not $M) { $M = Get-MemoryStatus }
    Write-Host ''
    Write-Host ("  {0}" -f $Header) -ForegroundColor White
    $barLen = 40
    $fill = [int]([math]::Round(($M.UsedPct/100)*$barLen))
    $bar = ('#' * $fill) + ('.' * ($barLen - $fill))
    $barColor = if ($M.UsedPct -ge 85) { 'Red' } elseif ($M.UsedPct -ge 65) { 'Yellow' } else { 'Green' }
    Write-Host ('  [' ) -NoNewline; Write-Host $bar -ForegroundColor $barColor -NoNewline
    Write-Host ('] {0}%' -f $M.UsedPct)
    Write-Host ('    Total     : {0}' -f (Format-Bytes $M.TotalB)) -ForegroundColor Gray
    Write-Host ('    In use    : {0}' -f (Format-Bytes $M.UsedB))  -ForegroundColor Gray
    Write-Host ('    Available : {0}' -f (Format-Bytes $M.FreeB))  -ForegroundColor Gray
    Write-Host ('    Cached    : {0}' -f (Format-Bytes $M.CachedB)) -ForegroundColor Gray
    Write-Host ('    Standby   : {0}' -f (Format-Bytes $M.StandbyB)) -ForegroundColor Gray
    Write-Host ('    Modified  : {0}' -f (Format-Bytes $M.ModifiedB)) -ForegroundColor Gray
}

function Invoke-OptimizeRam {
    param([switch]$WorkingSets,[switch]$Standby,[switch]$Modified,[switch]$FileCache,[switch]$LowPriority)
    Add-MemToolsType
    $before = Get-MemoryStatus
    Show-MemoryStatus -M $before -Header 'Before optimization'

    $needAdmin = $Standby -or $Modified -or $FileCache -or $LowPriority
    if ($needAdmin -and (Get-PrivilegeLevel) -eq 'User') {
        Write-Host ''
        Write-Log 'Clearing standby / modified / file cache requires Administrator (or higher).' 'WARN'
        Write-Log 'Working-set trimming will still run; elevate for the rest.' 'WARN'
    }

    Write-Host ''
    if ($WorkingSets) {
        Write-Log 'Trimming process working sets...' 'STEP'
        $n = [CSM.MemTools]::EmptyWorkingSets()
        Write-Log ("  Trimmed {0} process(es)." -f $n) 'OK'
    }
    if ($Modified) {
        Write-Log 'Flushing modified page list...' 'STEP'
        if ([CSM.MemTools]::FlushModifiedList()) { Write-Log '  Modified page list flushed.' 'OK' } else { Write-Log '  Flush failed (needs admin).' 'WARN' }
    }
    if ($Standby) {
        Write-Log 'Purging standby (cached) memory list...' 'STEP'
        if ([CSM.MemTools]::PurgeStandbyList()) { Write-Log '  Standby list purged.' 'OK' } else { Write-Log '  Purge failed (needs admin).' 'WARN' }
    } elseif ($LowPriority) {
        Write-Log 'Purging low-priority standby list...' 'STEP'
        if ([CSM.MemTools]::PurgeLowPriorityStandby()) { Write-Log '  Low-priority standby purged.' 'OK' } else { Write-Log '  Purge failed (needs admin).' 'WARN' }
    }
    if ($FileCache) {
        Write-Log 'Clearing system file cache...' 'STEP'
        if ([CSM.MemTools]::ClearFileCache()) { Write-Log '  System file cache cleared.' 'OK' } else { Write-Log '  Clear failed (needs admin).' 'WARN' }
    }

    Start-Sleep -Milliseconds 600
    $after = Get-MemoryStatus
    Show-MemoryStatus -M $after -Header 'After optimization'
    $reclaimed = $after.FreeB - $before.FreeB
    Write-Host ''
    if ($reclaimed -gt 0) {
        Write-Log ("Reclaimed approximately {0} of available RAM." -f (Format-Bytes $reclaimed)) 'OK'
    } else {
        Write-Log 'No net increase in available RAM (system may re-cache immediately).' 'INFO'
    }
}

function Show-MemoryMenu {
    while ($true) {
        Clear-Host
        Write-Banner 'RAM Optimization & Cache'
        Show-MemoryStatus -Header 'Current'
        Write-Host ''
        Write-Host '   [1] Optimize RAM  (trim all process working sets)'
        Write-Host '   [2] Clear standby / cached memory  (RAMMap-style purge)   *admin'
        Write-Host '   [3] Flush modified page list                              *admin'
        Write-Host '   [4] Clear system file cache                               *admin'
        Write-Host '   [5] Full optimization (all of the above)                  *admin'
        Write-Host '   [6] Purge low-priority standby only                       *admin'
        Write-Host '   [7] Refresh status'
        Write-Host '   [0] Back'
        Write-Host ''
        $c = Read-Host 'Select'
        switch ($c) {
            '1' { Invoke-OptimizeRam -WorkingSets; Wait-Menu }
            '2' { Invoke-OptimizeRam -Standby; Wait-Menu }
            '3' { Invoke-OptimizeRam -Modified; Wait-Menu }
            '4' { Invoke-OptimizeRam -FileCache; Wait-Menu }
            '5' { Invoke-OptimizeRam -WorkingSets -Modified -Standby -FileCache; Wait-Menu }
            '6' { Invoke-OptimizeRam -LowPriority; Wait-Menu }
            '7' { }
            '0' { return }
            default { }
        }
    }
}

# ---- Power / performance profile --------------------------------------------

$Script:KnownSchemes = [ordered]@{
    'Balanced'             = '381b4222-f694-41f0-9685-ff5bb260df2e'
    'High performance'     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    'Power saver'          = 'a1841308-3541-4fab-bc81-f71556f20b4a'
    'Ultimate Performance' = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
}

function Get-PowerSchemes {
    $out = & powercfg.exe /list 2>&1 | Out-String
    $active = ''
    $am = [regex]::Match((& powercfg.exe /getactivescheme 2>&1 | Out-String), '([0-9a-fA-F-]{36})')
    if ($am.Success) { $active = $am.Groups[1].Value }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($m in [regex]::Matches($out, 'GUID:\s*([0-9a-fA-F-]{36})\s*\(([^)]+)\)')) {
        $g = $m.Groups[1].Value
        $list.Add([pscustomobject]@{ Guid=$g; Name=$m.Groups[2].Value.Trim(); Active=($g -eq $active) })
    }
    return $list
}

function Show-PowerProfileMenu {
    while ($true) {
        Clear-Host
        Write-Banner 'Power / Performance Profile'
        $schemes = Get-PowerSchemes
        Write-Host ''
        Write-Host '  Installed power schemes:' -ForegroundColor White
        $i = 1; $map = @{}
        foreach ($s in $schemes) {
            $mark = if ($s.Active) { '  <== ACTIVE' } else { '' }
            $col  = if ($s.Active) { 'Green' } else { 'Gray' }
            Write-Host ('   [{0}] {1}{2}' -f $i, $s.Name.PadRight(28), $mark) -ForegroundColor $col
            $map[[string]$i] = $s; $i++
        }
        Write-Host ''
        Write-Host '   [U] Add + activate the "Ultimate Performance" scheme'
        Write-Host '   [0] Back'
        Write-Host ''
        $c = Read-Host 'Select a scheme number to activate'
        if ($c -eq '0') { return }
        if ($c -match '^[Uu]$') {
            Write-Log 'Duplicating the Ultimate Performance scheme...' 'STEP'
            & powercfg.exe -duplicatescheme $Script:KnownSchemes['Ultimate Performance'] 2>&1 | Out-Null
            & powercfg.exe /setactive $Script:KnownSchemes['Ultimate Performance'] 2>&1 | Out-Null
            Write-Log 'Ultimate Performance activated (if supported on this SKU).' 'OK'
            Wait-Menu; continue
        }
        if ($map.ContainsKey($c)) {
            $sel = $map[$c]
            & powercfg.exe /setactive $sel.Guid 2>&1 | Out-Null
            Write-Log ("Activated power scheme: {0}" -f $sel.Name) 'OK'
            Wait-Menu
        }
    }
}

function Set-VisualEffects {
    param([ValidateSet('Performance','Appearance','Custom')][string]$Mode)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    $val = switch ($Mode) { 'Appearance' {1} 'Performance' {2} default {3} }
    Set-ItemProperty -Path $key -Name 'VisualFXSetting' -Value $val -Type DWord
    Write-Log ("Visual effects set to: {0}. Sign out/in or restart Explorer to fully apply." -f $Mode) 'OK'
}

function Set-ProcessorScheduling {
    param([ValidateSet('Programs','Background')][string]$Mode)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
    $val = if ($Mode -eq 'Programs') { 0x26 } else { 0x18 }
    Set-ItemProperty -Path $key -Name 'Win32PrioritySeparation' -Value $val -Type DWord
    Write-Log ("Processor scheduling optimized for: {0}." -f $Mode) 'OK'
}

function Show-PagefileInfo {
    Write-Host ''
    Write-Host '  Pagefile (virtual memory) settings:' -ForegroundColor White
    try {
        $auto = (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile
        Write-Host ('    Automatically managed : {0}' -f $auto) -ForegroundColor Gray
        Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host ('    Setting  : {0}  Initial={1}MB  Maximum={2}MB' -f $_.Name, $_.InitialSize, $_.MaximumSize) -ForegroundColor Gray
        }
        Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host ('    In use   : {0}  Allocated={1}MB  PeakUsage={2}MB  CurrentUsage={3}MB' -f $_.Name, $_.AllocatedBaseSize, $_.PeakUsage, $_.CurrentUsage) -ForegroundColor Gray
        }
    } catch { Write-Log ("Could not read pagefile info: {0}" -f $_.Exception.Message) 'WARN' }
}

function Show-PerformanceMenu {
    while ($true) {
        Clear-Host
        $level = Get-PrivilegeLevel
        Write-Banner 'Performance & Memory'
        Write-Host ('  Privilege : ' ) -NoNewline
        Write-Host $level -ForegroundColor (Get-PrivilegeColor $level)
        Write-Host ''
        Write-Host '   MEMORY' -ForegroundColor White
        Write-Host '    [1] RAM optimization & cache clearing'
        Write-Host ''
        Write-Host '   PERFORMANCE PROFILE' -ForegroundColor White
        Write-Host '    [2] View / change power (performance) profile'
        Write-Host '    [3] Visual effects: adjust for best PERFORMANCE'
        Write-Host '    [4] Visual effects: adjust for best APPEARANCE'
        Write-Host '    [5] Visual effects: let Windows choose (custom/default)'
        Write-Host '    [6] Processor scheduling: favor PROGRAMS (foreground)'
        Write-Host '    [7] Processor scheduling: favor BACKGROUND services'
        Write-Host '    [8] View virtual memory (pagefile) settings'
        Write-Host '    [0] Back'
        Write-Host ''
        $c = Read-Host 'Select'
        switch ($c) {
            '1' { Show-MemoryMenu }
            '2' { Show-PowerProfileMenu }
            '3' { Set-VisualEffects -Mode Performance; Wait-Menu }
            '4' { Set-VisualEffects -Mode Appearance;  Wait-Menu }
            '5' { Set-VisualEffects -Mode Custom;       Wait-Menu }
            '6' { Set-ProcessorScheduling -Mode Programs;   Wait-Menu }
            '7' { Set-ProcessorScheduling -Mode Background; Wait-Menu }
            '8' { Show-PagefileInfo; Wait-Menu }
            '0' { return }
            default { }
        }
    }
}

#endregion

#region ---------------------------------------------------------------- In-place repair / reinstall

function Get-CurrentEdition {
    $p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    [pscustomobject]@{
        EditionID   = $p.EditionID
        ProductName = $p.ProductName
        Build       = [int]$p.CurrentBuild
        UBR         = $p.UBR
        Arch        = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { 'x86' }
    }
}

function Test-UpgradeMedia {
    <#
        Inspects the media's install.wim/esd and compares to the running OS to
        determine whether an in-place upgrade that KEEPS apps + data is allowed.
        Rules: same architecture, matching edition present on media, and the
        media build must be >= the installed build (you cannot down-level and
        keep apps/data).
    #>
    param([string]$SetupRoot)

    $cur = Get-CurrentEdition
    $wim = Join-Path $SetupRoot 'sources\install.wim'
    $esd = Join-Path $SetupRoot 'sources\install.esd'
    $src = if (Test-Path $wim) { $wim } elseif (Test-Path $esd) { $esd } else { $null }

    $result = [pscustomobject]@{
        SetupExe       = (Join-Path $SetupRoot 'setup.exe')
        ImageFile      = $src
        MediaBuild     = $null
        MediaArch      = $null
        Editions       = @()
        CurrentEdition = $cur
        ArchOk         = $false
        BuildOk        = $false
        EditionOk      = $false
        CanKeepData    = $false
        Notes          = New-Object System.Collections.Generic.List[string]
    }

    if (-not (Test-Path $result.SetupExe)) { $result.Notes.Add('setup.exe not found at the media root.'); return $result }
    if (-not $src) { $result.Notes.Add('No install.wim/esd found under \sources; cannot validate compatibility.'); return $result }

    try {
        $imgs = Get-WindowsImage -ImagePath $src -ErrorAction Stop
        $result.Editions = @($imgs | Select-Object ImageIndex, ImageName)
        # Highest build present on the media.
        $builds = foreach ($i in $imgs) {
            $v = "$($i.Version)"  # e.g. 10.0.26100.1
            if ($v -match '^\d+\.\d+\.(\d+)') { [int]$Matches[1] }
        }
        if ($builds) { $result.MediaBuild = ($builds | Measure-Object -Maximum).Maximum }
        $archMap = @{ 0='x86'; 9='amd64'; 12='arm64' }
        $result.MediaArch = $archMap[[int]$imgs[0].Architecture]

        $result.ArchOk    = ($result.MediaArch -eq $cur.Arch)
        $result.BuildOk   = ($result.MediaBuild -ge $cur.Build)
        $result.EditionOk = [bool](@($imgs | Where-Object { $_.ImageName -match [regex]::Escape($cur.EditionID) -or $_.ImageName -match ([regex]::Escape(($cur.ProductName -replace '^Windows( 1[01])?\s*','').Trim())) }).Count)

        if (-not $result.ArchOk)    { $result.Notes.Add("Architecture mismatch: media=$($result.MediaArch), OS=$($cur.Arch). Keep-apps upgrade is NOT possible.") }
        if (-not $result.BuildOk)   { $result.Notes.Add("Media build ($($result.MediaBuild)) is older than the installed build ($($cur.Build)). You cannot keep apps/data while down-leveling.") }
        if (-not $result.EditionOk) { $result.Notes.Add("Could not confirm your edition ($($cur.EditionID)) is present on the media. Setup will refuse if the edition differs.") }

        $result.CanKeepData = ($result.ArchOk -and $result.BuildOk)
    } catch {
        $result.Notes.Add("Could not read media image: $($_.Exception.Message)")
    }
    return $result
}

function Invoke-InPlaceRepair {
    Clear-Host
    Write-Banner 'In-Place Reinstall / Repair Install  (keep apps + data)'
    Write-Host ''
    Write-Host '  Reinstalls Windows over itself from installation media, keeping:'
    Write-Host '    * All user accounts, files and data'
    Write-Host '    * All installed applications and their settings'
    Write-Host '    * Windows settings'
    Write-Host '  This replaces core OS + component-store files, fixing corruption that'
    Write-Host '  even RestoreHealth / overwrite-repair cannot resolve.'
    Write-Host ''
    Write-Host '  REQUIREMENTS to keep apps AND data:' -ForegroundColor Yellow
    Write-Host '    - Media must be the SAME edition, architecture and language.' -ForegroundColor Yellow
    Write-Host '    - Media build must be the SAME or NEWER than the installed build.' -ForegroundColor Yellow
    Write-Host '    - Must run from within the running Windows (online), not from boot.' -ForegroundColor Yellow
    Write-Host ''

    # Requires elevation.
    $level = Get-PrivilegeLevel
    if ($level -eq 'User') {
        Write-Log 'An in-place upgrade must run as Administrator (or higher).' 'WARN'
        Write-Log 'Use the Privilege menu to elevate first.' 'WARN'
        Wait-Menu; return
    }
    if (-not $Script:Target.Online) {
        Write-Log 'In-place repair applies to the ONLINE OS only; ignoring the offline target.' 'WARN'
    }

    # --- Source selection ---
    Write-Host '   [1] From an installation ISO (auto-mounted)'
    Write-Host '   [2] From a drive / folder that contains setup.exe'
    Write-Host '   [0] Cancel'
    Write-Host ''
    $s = Read-Host 'Select media source'
    $setupRoot = $null
    $isoDrive  = $null
    switch ($s) {
        '1' {
            $iso = Read-PathInput 'Path to Windows installation ISO'
            if (-not $iso -or -not (Test-Path $iso)) { Write-Log 'ISO not found.' 'ERROR'; Wait-Menu; return }
            try {
                # Mounted directly (NOT auto-cleanup tracked) so it survives while
                # setup runs and after this tool exits, until reboot.
                Mount-DiskImage -ImagePath $iso -StorageType ISO -ErrorAction Stop | Out-Null
                Start-Sleep -Milliseconds 800
                $isoDrive = (Get-DiskImage -ImagePath $iso | Get-Volume).DriveLetter
                $setupRoot = "$isoDrive`:\"
                Write-Log "ISO mounted at $isoDrive`: (kept mounted for setup)" 'OK'
            } catch { Write-Log ("Failed to mount ISO: {0}" -f $_.Exception.Message) 'ERROR'; Wait-Menu; return }
        }
        '2' {
            $setupRoot = Read-PathInput 'Path to media root (folder containing setup.exe)'
            if (-not $setupRoot -or -not (Test-Path (Join-Path $setupRoot 'setup.exe'))) {
                Write-Log 'setup.exe not found at that location.' 'ERROR'; Wait-Menu; return
            }
        }
        default { return }
    }

    # --- Compatibility validation ---
    Write-Log 'Validating media compatibility...' 'STEP'
    $chk = Test-UpgradeMedia -SetupRoot $setupRoot
    $cur = $chk.CurrentEdition
    Write-Host ''
    Write-Host '  Compatibility check:' -ForegroundColor White
    Write-Host ("    Installed : {0}  build {1}.{2}  ({3})" -f $cur.ProductName,$cur.Build,$cur.UBR,$cur.Arch) -ForegroundColor Gray
    Write-Host ("    Media     : build {0}  ({1})" -f $chk.MediaBuild,$chk.MediaArch) -ForegroundColor Gray
    $cArch = if ($chk.ArchOk)    { 'Green' } else { 'Red' }
    $cBld  = if ($chk.BuildOk)   { 'Green' } else { 'Red' }
    $cEd   = if ($chk.EditionOk) { 'Green' } else { 'Yellow' }
    Write-Host ("    Arch match       : {0}" -f $chk.ArchOk)    -ForegroundColor $cArch
    Write-Host ("    Build same/newer : {0}" -f $chk.BuildOk)   -ForegroundColor $cBld
    Write-Host ("    Edition present  : {0}" -f $chk.EditionOk) -ForegroundColor $cEd
    if ($chk.Editions) {
        Write-Host '    Editions on media:' -ForegroundColor Gray
        $chk.Editions | ForEach-Object { Write-Host ("       [{0}] {1}" -f $_.ImageIndex,$_.ImageName) -ForegroundColor DarkGray }
    }
    foreach ($n in $chk.Notes) { Write-Host ("    ! {0}" -f $n) -ForegroundColor Yellow }

    if (-not $chk.CanKeepData) {
        Write-Host ''
        Write-Log 'This media CANNOT perform a keep-apps-and-data upgrade (see notes above).' 'ERROR'
        $force = Read-Host 'Continue anyway? Setup may only offer "keep nothing" or refuse. (Y/N)'
        if ($force -notmatch '^[Yy]') {
            if ($isoDrive) { Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null }
            Wait-Menu; return
        }
    }

    # --- Options ---
    Write-Host ''
    Write-Host '  Setup options:' -ForegroundColor White
    $qa = Read-Host '   Run silently with no setup UI (quiet)? (Y/N, default N = show progress)'
    $quiet = ($qa -match '^[Yy]')
    $du = Read-Host '   Download latest updates during setup (DynamicUpdate)? (Y/N, default N = faster/offline)'
    $dynamic = if ($du -match '^[Yy]') { 'enable' } else { 'disable' }
    $rb = Read-Host '   Reboot automatically when the down-level phase completes? (Y/N, default N = you reboot)'
    $reboot = ($rb -match '^[Yy]')

    $logDir = Join-Path $Script:WorkRoot ('SetupLogs_{0:yyyyMMdd_HHmmss}' -f (Get-Date))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    # /auto upgrade is the flag that preserves apps + data + settings.
    $setupArgs = @(
        '/auto','upgrade',
        '/migratedrivers','all',
        '/dynamicupdate', $dynamic,
        '/eula','accept',
        '/compat','ignorewarning',
        '/showoobe','none',
        '/bitlocker','alwayssuspend',
        '/telemetry','disable',
        '/copylogs', $logDir
    )
    if ($quiet)        { $setupArgs += '/quiet' }
    if (-not $reboot)  { $setupArgs += '/noreboot' }

    Write-Host ''
    Write-Host ('  Command: {0} {1}' -f $chk.SetupExe, ($setupArgs -join ' ')) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  ****************************  WARNING  ****************************' -ForegroundColor Red
    Write-Host '  This will REINSTALL Windows. The machine will restart one or more' -ForegroundColor Yellow
    Write-Host '  times and be unusable for 20-90 minutes. Save all work and close'  -ForegroundColor Yellow
    Write-Host '  other apps first. A recent BACKUP is strongly recommended'          -ForegroundColor Yellow
    Write-Host '  (main menu -> Backup component store, plus your own file backup).'  -ForegroundColor Yellow
    Write-Host '  *****************************************************************'    -ForegroundColor Red
    if (-not (Confirm-Action 'Start the in-place reinstall now?' -Danger)) {
        Write-Log 'In-place reinstall cancelled.' 'INFO'
        if ($isoDrive) {
            $u = Read-Host 'Unmount the ISO that was mounted? (Y/N)'
            if ($u -match '^[Yy]') { Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null }
        }
        Wait-Menu; return
    }

    Write-Log ("Launching Windows Setup for in-place upgrade. Logs -> {0}" -f $logDir) 'STEP'
    try {
        Start-Process -FilePath $chk.SetupExe -ArgumentList $setupArgs -Verb RunAs
        Write-Log 'Windows Setup started. It runs independently of this tool.' 'OK'
        Write-Host ''
        Write-Host '  * Do NOT unmount the ISO or shut down until Setup reboots the PC.' -ForegroundColor Yellow
        Write-Host ('  * Setup logs will be copied to: {0}' -f $logDir) -ForegroundColor Gray
        Write-Host '  * If Setup rolls back, review $WINDOWS.~BT\Sources\Panther\setupact.log.' -ForegroundColor Gray
    } catch {
        Write-Log ("Failed to start setup: {0}" -f $_.Exception.Message) 'ERROR'
        if ($isoDrive) { Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null }
    }
    Wait-Menu
}

#endregion

#region ---------------------------------------------------------------- Main menu

function Show-MainMenu {
    Clear-Host
    $level = Update-PrivilegeLevel
    $bar = '=' * 74
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ("  {0}  v{1}" -f $Script:AppName, $Script:AppVersion) -ForegroundColor White
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host '  Privilege : ' -NoNewline
    Write-Host $level.PadRight(16) -ForegroundColor (Get-PrivilegeColor $level) -NoNewline
    Write-Host '  Target : ' -NoNewline
    Write-Host $Script:Target.Label -ForegroundColor Cyan
    Write-Host ("  Mounts    : {0} tracked        Log : {1}" -f $Script:Mounts.Count, $Script:LogFile) -ForegroundColor DarkGray
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '   HEALTH & REPAIR' -ForegroundColor White
    Write-Host '    [1] Check health          (CheckHealth)'
    Write-Host '    [2] Scan health           (ScanHealth)'
    Write-Host '    [3] Repair                (RestoreHealth, optional source)'
    Write-Host '    [4] Advanced repair       (source / overwrite as SYSTEM/TI / in-place)'
    Write-Host ''
    Write-Host '   COMPONENT STORE MAINTENANCE' -ForegroundColor White
    Write-Host '    [5] Analyze component store'
    Write-Host '    [6] Cleanup component store  (StartComponentCleanup / ResetBase*)'
    Write-Host ''
    Write-Host '   TARGET & SOURCES' -ForegroundColor White
    Write-Host '    [7] Set target = ONLINE'
    Write-Host '    [8] Select OFFLINE component store image'
    Write-Host '    [9] Download updates to match current online version'
    Write-Host ''
    Write-Host '   BACKUP' -ForegroundColor White
    Write-Host '    [10] Backup current online component store'
    Write-Host '    [11] Backup the driver store'
    Write-Host ''
    Write-Host '   IMAGE / ISO SERVICING' -ForegroundColor White
    Write-Host '    [12] Add drivers/updates to boot/install image in an ISO, rebuild ISO'
    Write-Host ''
    Write-Host '   REPORTING' -ForegroundColor White
    Write-Host '    [15] Create detailed report  (PDF + HTML + HTA, with graphics)'
    Write-Host ''
    Write-Host '   PERFORMANCE' -ForegroundColor White
    Write-Host '    [16] Performance & memory  (optimize RAM, cache, power profile)'
    Write-Host ''
    Write-Host '   RECOVERY' -ForegroundColor White
    Write-Host '    [17] In-place reinstall Windows  (keep apps + data, repair install)'
    Write-Host ''
    Write-Host '   SYSTEM' -ForegroundColor White
    Write-Host '    [13] Privilege level  (switch User/Admin/SYSTEM/TrustedInstaller)'
    Write-Host '    [14] Unmount everything I mounted (cleanup now)'
    Write-Host '    [0]  Exit'
    Write-Host ''
    return (Read-Host 'Select option')
}

function Start-App {
    # Announce context of a relaunched instance.
    if ($Relaunched) {
        Write-Log ("Relaunched into context: {0}" -f (Get-PrivilegeLevel)) 'OK'
        Start-Sleep -Milliseconds 400
    }

    try {
        [Console]::Title = "$Script:AppName [$([Security.Principal.WindowsIdentity]::GetCurrent().Name)]"
    } catch { }

    # Verify the DISM module is present.
    if (-not (Get-Module -ListAvailable -Name Dism)) {
        Write-Log 'The DISM PowerShell module is not available. Some features require it.' 'WARN'
    } else {
        Import-Module Dism -ErrorAction SilentlyContinue
    }

    while ($true) {
        $choice = Show-MainMenu
        switch ($choice) {
            '1'  { Invoke-CheckHealth }
            '2'  { Invoke-ScanHealth }
            '3'  { Invoke-RestoreHealthInteractive }
            '4'  { Show-AdvancedRepairMenu }
            '5'  { Invoke-AnalyzeStore }
            '6'  { Invoke-CleanupStore }
            '7'  { Set-OnlineTarget; Wait-Menu }
            '8'  { Select-OfflineTarget }
            '9'  { Invoke-DownloadMatchingUpdates }
            '10' { Invoke-BackupComponentStore }
            '11' { Invoke-BackupDriverStore }
            '12' { Invoke-ServiceImageMenu }
            '15' { Invoke-CreateReport }
            '16' { Show-PerformanceMenu }
            '17' { Invoke-InPlaceRepair }
            '13' { Show-PrivilegeMenu }
            '14' { Invoke-CleanupMounts; Wait-Menu }
            '0'  {
                if ($Script:Mounts.Count -gt 0) {
                    Write-Host ''
                    Write-Log ("{0} mount(s) still tracked - cleaning up before exit." -f $Script:Mounts.Count) 'STEP'
                    Invoke-CleanupMounts
                }
                Write-Log 'Goodbye.' 'INFO'
                return
            }
            default { }
        }
    }
}

#endregion

# ---------------------------------------------------------------------- Entry point
try {
    Write-Log ("{0} v{1} starting. PID {2}. Context {3}." -f $Script:AppName,$Script:AppVersion,$PID,(Get-PrivilegeLevel)) 'INFO'
    Start-App
}
finally {
    # Guarantee no mount is left behind even on Ctrl-C / error.
    Invoke-CleanupMounts -Silent
    Remove-VssSnapshot
}
