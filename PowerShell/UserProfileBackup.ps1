#Requires -Version 5.1

<#
.SYNOPSIS
    Backs up and restores one or more Windows user profiles, from an interactive
    console, a WPF window, saved configuration profiles, or the command line.

.DESCRIPTION
    UserProfileBackup.ps1 copies files from Windows user profiles into a
    self-describing backup set and restores them later, to the original profile,
    another existing profile, or a custom folder.

    Both interfaces (Console and WPF) call the same backup, restore, validation
    and configuration functions, so they offer the same features.

    BACKUP SCOPES
      Complete         Every accessible file and folder inside the profile folder,
                       including hidden content and AppData. Known folders that are
                       redirected outside the profile folder are added as well.
      UserData         Documents, Pictures, Music, Videos, Contacts, Desktop,
                       Downloads and Bookmarks.
      SelectedFolders  Any of the user data folders, plus custom folders. A custom
                       folder can be an absolute path or a path relative to each
                       profile folder (for example "Source\Repos").

    Folder locations are resolved per profile from the user's own registry hive
    (User Shell Folders), so redirected folders and OneDrive Known Folder Move are
    honoured. When a hive cannot be read, the script falls back to the default
    location and then to OneDrive folders inside the profile.

    Bookmarks covers the Windows Favorites folder and the bookmark files of
    Microsoft Edge, Google Chrome and Mozilla Firefox. Close the browsers first:
    open browsers lock or continuously rewrite these files, so copies taken while
    they run can fail or be inconsistent.

    A complete-profile backup is a FILE backup. It does not make account
    credentials, EFS-encrypted files, DPAPI-protected secrets (saved browser
    passwords, Wi-Fi keys), or every application setting portable to another
    account or computer.

    DATE FILTERS (local time zone; relative periods are evaluated once, when the
    operation starts, and the boundaries are shown before anything runs)
      All           Every file.
      On            The whole local calendar day of -Date.
      After         Date only: from the start of the NEXT day (the day itself is
                    excluded). Date and time: strictly later than that instant.
      Before        Date only: before the start of that day (the day is excluded).
                    Date and time: strictly earlier than that instant.
      CurrentWeek   From Monday 00:00 of this week to next Monday 00:00.
      CurrentMonth  From the 1st of this month 00:00 to the 1st of next month.
      Range         Date-only endpoints include both whole days. Date and time
                    endpoints are inclusive.
    The filter uses CreationTime unless -DateField LastWriteTime is given. Folders
    are recreated as needed so filtered files restore to their original places.

    BACKUP SET LAYOUT
      <Destination>\UPB_<COMPUTER>_<yyyyMMdd-HHmmss>\
          manifest.json          Versioned manifest (see below)
          UserProfileBackup.log  Copy of the operation log
          INCOMPLETE.txt         Present while running / after a failure
          CANCELED.txt           Present when the backup was canceled
          Profiles\<account>\<folder>\...   Copied files, relative paths preserved

    The manifest records the backup id, creation time, source computer, selected
    profiles, original folder paths, scope, the resolved date filter, every copied
    file (relative path, size, creation/last-write/last-access times, attributes
    and optional SHA-256), skipped files and errors.

    RESTORE
      Each restored profile gets its own destination mapping: Original (the paths
      recorded in the manifest), Profile (another existing user profile on this
      computer, with folders resolved for that user), or Folder (a custom folder).
      Conflict policies: Skip (default), Overwrite, KeepBoth. Files that exist only
      at the destination are never deleted. Every manifest path is validated so
      nothing can be written outside the selected destination. Accounts are never
      created, and ownership/permissions are never changed: restored files inherit
      the destination folder's permissions and are owned by the account running
      the restore.

    SETTINGS AND PRECEDENCE
      Values are applied in this order, later ones winning:
        1. Built-in defaults
        2. Saved application settings (-Settings)
        3. The configuration profile (-ConfigurationPath)
        4. Parameters typed on the command line
      Settings are stored in %APPDATA%\UserProfileBackup\settings.json and named
      configurations in %APPDATA%\UserProfileBackup\Configurations. Set the
      environment variable UPB_HOME to keep them somewhere else (portable use).
      Logs default to %LOCALAPPDATA%\UserProfileBackup\Logs (or UPB_HOME\Logs).

    CONSOLE KEYS
      Menus     Press an option's number/letter to choose it immediately. Press
                Up/Down to start highlighted navigation, then Enter or Space.
      Lists     Up/Down move, Space toggles, A selects all, N clears, C (or the
                Continue row) continues.
      Anywhere  Esc returns to the previous screen.
      Running   Esc or Ctrl+C cancels between files.

.PARAMETER Operation
    Backup or Restore. With enough information (from parameters and/or the
    configuration profile) the operation runs immediately; otherwise the matching
    interactive wizard opens prefilled.

.PARAMETER Interface
    Console (default) or WPF. Overrides the interface saved in settings or in the
    configuration profile.

.PARAMETER Settings
    Opens application settings in the selected interface, where the preferred
    interface and default values can be chosen and saved.

.PARAMETER Profiles
    Source profiles to back up, by account name (DOMAIN\user or user) or by profile
    folder path. A folder that is not a registered profile is accepted as an
    ad-hoc profile.

.PARAMETER IncludeSystemProfiles
    Shows and allows system and service profiles, which are excluded by default.

.PARAMETER BackupScope
    Complete, UserData or SelectedFolders. Supplying -Folders alone implies
    SelectedFolders.

.PARAMETER Folders
    User data folder names (Documents, Pictures, Music, Videos, Contacts, Desktop,
    Downloads, Bookmarks) and/or custom paths. Relative custom paths are resolved
    inside each profile folder.

.PARAMETER Destination
    Backup: the folder (local, external drive or UNC share) that receives the new
    backup set. Restore: the custom destination folder for a single restored
    profile.

.PARAMETER BackupPath
    Restore: the backup set folder (or its manifest.json).

.PARAMETER RestoreProfiles
    Restore: which profiles from the backup set to restore, by account name or
    backup folder name. Required when the set contains more than one profile and
    the run is non-interactive.

.PARAMETER RestoreMapPath
    Restore: a JSON file mapping each restored profile to a destination. See
    Examples\restore-map.example.json.

.PARAMETER DateFilter
    All, On, After, Before, CurrentWeek, CurrentMonth or Range.

.PARAMETER Date
    The date or date/time for On, After and Before. A value without a time
    (for example 2026-03-15) is a date-only value; one with a time
    (2026-03-15 14:30) is a date/time value.

.PARAMETER StartDate
    Range start (date or date/time).

.PARAMETER EndDate
    Range end (date or date/time).

.PARAMETER DateField
    CreationTime (default) or LastWriteTime.

.PARAMETER ConflictAction
    Restore: Skip (default), Overwrite or KeepBoth. Overwrite is only accepted in a
    non-interactive run when it is typed on the command line; interactive runs ask
    for confirmation.

.PARAMETER ConfigurationPath
    Loads a saved configuration profile. With -NewConfiguration the profile is
    opened for editing.

.PARAMETER NewConfiguration
    Opens the configuration profile generator in the selected interface.

.PARAMETER ConfigurationOutputPath
    Where the generator saves the configuration. Defaults to
    %APPDATA%\UserProfileBackup\Configurations\<name>.json.

.PARAMETER Verify
    Computes SHA-256 hashes. Backups record the hash of every copied file and check
    the copy; restores check every restored file against the manifest.

.PARAMETER LogPath
    A log file (*.log or *.txt) or a folder that receives a timestamped log.

.PARAMETER NonInteractive
    Never prompts. Everything comes from parameters, the configuration profile and
    settings; missing or invalid information ends the run with exit code 2.

.PARAMETER WhatIf
    Shows the planned work (resolved folders, date boundaries, file counts and
    sizes, restore actions) without creating, changing or deleting any file.

.EXAMPLE
    .\UserProfileBackup.ps1
    Opens the interactive console menu.

.EXAMPLE
    .\UserProfileBackup.ps1 -Interface WPF
    Opens the WPF window.

.EXAMPLE
    .\UserProfileBackup.ps1 -Settings -Interface WPF
    Opens settings in the WPF window (choose and save the preferred interface there).

.EXAMPLE
    .\UserProfileBackup.ps1 -NewConfiguration -ConfigurationOutputPath D:\Configs\nightly.json
    Runs the console configuration wizard and saves the result to D:\Configs\nightly.json.

.EXAMPLE
    .\UserProfileBackup.ps1 -Operation Backup -Profiles alice,bob -BackupScope UserData -Destination \\nas\backups -Verify -NonInteractive
    Backs up the user data of two profiles to a share, with SHA-256 verification.

.EXAMPLE
    .\UserProfileBackup.ps1 -Operation Backup -Profiles alice -Folders Documents,Desktop,'Source\Repos' -DateFilter After -Date 2026-09-01 -Destination E:\Backups -NonInteractive
    Backs up files created from 2026-09-02 00:00 onward (date-only "after" excludes the day itself).

.EXAMPLE
    .\UserProfileBackup.ps1 -Operation Backup -Profiles C:\Users\alice -BackupScope Complete -DateFilter Range -StartDate '2026-09-01 08:00' -EndDate '2026-09-30 18:00' -DateField LastWriteTime -Destination E:\Backups -WhatIf
    Previews a complete-profile backup of files modified within an inclusive date/time range.

.EXAMPLE
    .\UserProfileBackup.ps1 -Operation Restore -BackupPath E:\Backups\UPB_PC01_20261001-120000 -RestoreProfiles alice -Destination D:\Restored\alice -ConflictAction KeepBoth -NonInteractive
    Restores one profile into a custom folder, keeping both copies when names collide.

.EXAMPLE
    .\UserProfileBackup.ps1 -Operation Restore -BackupPath E:\Backups\UPB_PC01_20261001-120000 -RestoreProfiles alice,bob -RestoreMapPath .\Examples\restore-map.example.json -NonInteractive
    Restores two profiles using a per-profile destination mapping file.

.EXAMPLE
    .\UserProfileBackup.ps1 -ConfigurationPath .\Examples\backup-userdata.example.json -NonInteractive
    Runs the operation stored in a configuration profile without prompts.

.EXAMPLE
    .\UserProfileBackup.ps1 -ConfigurationPath .\Examples\backup-userdata.example.json -Interface WPF
    Opens the WPF window prefilled from a configuration profile.

.INPUTS
    None.

.OUTPUTS
    None. The process exit code reports the result.

.NOTES
    Exit codes
        0  Completed successfully.
        1  Completed with failed or skipped-by-error files, or other partial results.
        2  Validation or fatal error (nothing, or not everything, could start).
        3  Canceled.

    Requirements
        Windows PowerShell 5.1 or PowerShell 7+, on Windows. The WPF interface needs
        a desktop session and an STA thread; when the current thread is MTA the
        window is started on a dedicated STA thread automatically.
        Backing up or restoring OTHER users' profiles normally requires an elevated
        (Run as administrator) session. Reading another user's folder locations
        while they are signed out temporarily loads their NTUSER.DAT hive, which
        also requires elevation.

    Files that are skipped by design (not counted as failures)
        Junctions and symbolic links (never followed, which prevents loops), OneDrive
        online-only placeholders (not downloaded), and app execution aliases.

    Version 1.0.0
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('Backup', 'Restore')]
    [string]$Operation,

    [ValidateSet('Console', 'WPF')]
    [string]$Interface,

    [Parameter(ParameterSetName = 'Settings', Mandatory = $true)]
    [switch]$Settings,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Profiles,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$IncludeSystemProfiles,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('Complete', 'UserData', 'SelectedFolders')]
    [string]$BackupScope,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Folders,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$Destination,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$BackupPath,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string[]]$RestoreProfiles,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$RestoreMapPath,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('All', 'On', 'After', 'Before', 'CurrentWeek', 'CurrentMonth', 'Range')]
    [string]$DateFilter,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$Date,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$StartDate,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$EndDate,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('CreationTime', 'LastWriteTime')]
    [string]$DateField,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('Skip', 'Overwrite', 'KeepBoth')]
    [string]$ConflictAction,

    [Parameter(ParameterSetName = 'Run')]
    [Parameter(ParameterSetName = 'NewConfiguration')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigurationPath,

    [Parameter(ParameterSetName = 'NewConfiguration', Mandatory = $true)]
    [switch]$NewConfiguration,

    [Parameter(ParameterSetName = 'NewConfiguration')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigurationOutputPath,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$Verify,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$NonInteractive
)

#region Constants and native helpers

$script:UpbVersion = '1.0.0'
$script:UpbScriptPath = $MyInvocation.MyCommand.Path
$script:UpbManifestVersion = 1
$script:UpbConfigSchemaVersion = 1
$script:UpbSettingsSchemaVersion = 1
$script:UpbRestoreMapSchemaVersion = 1

$script:UpbOptionKeys = @(
    'Operation', 'Interface', 'Profiles', 'IncludeSystemProfiles', 'BackupScope', 'Folders',
    'Destination', 'BackupPath', 'RestoreProfiles', 'RestoreMappings', 'RestoreMapPath',
    'DateFilter', 'Date', 'StartDate', 'EndDate', 'DateField', 'ConflictAction',
    'Verify', 'LogPath'
)
$script:UpbSettingKeys = @(
    'Interface', 'Destination', 'BackupScope', 'Folders', 'DateField', 'ConflictAction',
    'Verify', 'LogPath', 'IncludeSystemProfiles'
)
$script:UpbUserDataFolders = @('Documents', 'Pictures', 'Music', 'Videos', 'Contacts', 'Desktop', 'Downloads', 'Bookmarks')
$script:UpbDateFilters = @('All', 'On', 'After', 'Before', 'CurrentWeek', 'CurrentMonth', 'Range')

# Registry value names in "User Shell Folders" (legacy name first, then the known-folder GUID).
$script:UpbKnownFolderDefs = [ordered]@{
    Documents      = @{ Values = @('Personal', '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'); Default = 'Documents' }
    Pictures       = @{ Values = @('My Pictures', '{0DDD015D-B06C-45D5-8C4C-F59713854639}'); Default = 'Pictures' }
    Music          = @{ Values = @('My Music', '{A0C69A99-21C8-4671-8703-7934162FCF1D}'); Default = 'Music' }
    Videos         = @{ Values = @('My Video', '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}'); Default = 'Videos' }
    Contacts       = @{ Values = @('{56784854-C6CB-462B-8169-88E350ACB882}'); Default = 'Contacts' }
    Desktop        = @{ Values = @('Desktop', '{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}'); Default = 'Desktop' }
    Downloads      = @{ Values = @('{374DE290-123F-4565-9164-39C4925E467B}', '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}'); Default = 'Downloads' }
    Favorites      = @{ Values = @('Favorites', '{1777F761-68AD-4D8A-87BD-30B759FA33DD}'); Default = 'Favorites' }
    LocalAppData   = @{ Values = @('Local AppData', '{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}'); Default = 'AppData\Local' }
    RoamingAppData = @{ Values = @('AppData', '{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}'); Default = 'AppData\Roaming' }
}

$script:UpbDifferentAccountNotes = @(
    'Restored files are owned by the account running the restore and inherit the permissions of the destination folder; the source account''s permissions are not applied.',
    'No user account is created. EFS-encrypted files stay encrypted to the original account''s certificate and cannot be opened by another account.',
    'Application settings in AppData may contain paths, SIDs or machine-bound secrets (DPAPI: saved passwords, tokens) that do not work under another account or on another computer.',
    'Close the target user''s browsers and applications before restoring their data, and sign that user out when restoring into their profile.'
)

if (-not ('UpbIo' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

public class UpbValidationException : Exception
{
    public UpbValidationException(string message) : base(message) { }
}

public class UpbIoException : IOException
{
    public int Win32Code;
    public string TargetPath;
    public UpbIoException(int code, string path)
        : base(new Win32Exception(code).Message.TrimEnd('.', ' ') + " (Win32 error " + code + "): " + path)
    {
        Win32Code = code;
        TargetPath = path;
    }
}

public class UpbEntry
{
    public string Name;
    public uint Attributes;
    public long Size;
    public DateTime CreationTimeUtc;
    public DateTime LastAccessTimeUtc;
    public DateTime LastWriteTimeUtc;
    public uint ReparseTag;
    public bool IsDirectory { get { return (Attributes & 0x10) != 0; } }
    public bool IsReparsePoint { get { return (Attributes & 0x400) != 0; } }
    // Junctions, symbolic links and other "name surrogate" reparse points point elsewhere.
    public bool IsNameSurrogate { get { return IsReparsePoint && (ReparseTag & 0x20000000) != 0; } }
    // FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: cloud placeholder whose data is not on disk.
    public bool IsOnlineOnly { get { return (Attributes & 0x400000) != 0; } }
    public bool IsAppExecLink { get { return IsReparsePoint && ReparseTag == 0x8000001B; } }
    public bool IsEncrypted { get { return (Attributes & 0x4000) != 0; } }
}

// Win32 file operations with \\?\ paths, so long paths work on Windows PowerShell 5.1 too.
public static class UpbIo
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WIN32_FIND_DATA
    {
        public uint dwFileAttributes;
        public uint ftCreationLow; public uint ftCreationHigh;
        public uint ftAccessLow; public uint ftAccessHigh;
        public uint ftWriteLow; public uint ftWriteHigh;
        public uint nFileSizeHigh; public uint nFileSizeLow;
        public uint dwReserved0; public uint dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string cAlternateFileName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WIN32_FILE_ATTRIBUTE_DATA
    {
        public uint dwFileAttributes;
        public uint ftCreationLow; public uint ftCreationHigh;
        public uint ftAccessLow; public uint ftAccessHigh;
        public uint ftWriteLow; public uint ftWriteHigh;
        public uint nFileSizeHigh; public uint nFileSizeLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstFileExW(string lpFileName, int fInfoLevelId, out WIN32_FIND_DATA lpFindFileData, int fSearchOp, IntPtr lpSearchFilter, int dwAdditionalFlags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool FindNextFileW(IntPtr hFindFile, out WIN32_FIND_DATA lpFindFileData);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FindClose(IntPtr hFindFile);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetFileAttributesExW(string lpFileName, int fInfoLevelId, out WIN32_FILE_ATTRIBUTE_DATA lpFileInformation);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CopyFileW(string lpExistingFileName, string lpNewFileName, bool bFailIfExists);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateDirectoryW(string lpPathName, IntPtr lpSecurityAttributes);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetFileAttributesW(string lpFileName, uint dwFileAttributes);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DeleteFileW(string lpFileName);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileTime(SafeFileHandle hFile, ref long lpCreationTime, ref long lpLastAccessTime, ref long lpLastWriteTime);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetDiskFreeSpaceExW(string lpDirectoryName, out ulong lpFreeBytesAvailable, out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);

    private static readonly IntPtr InvalidHandle = new IntPtr(-1);
    public const uint InvalidAttributes = 0xFFFFFFFF;

    public static string Long(string path)
    {
        if (string.IsNullOrEmpty(path)) return path;
        if (path.StartsWith(@"\\?\") || path.StartsWith(@"\\.\")) return path;
        if (path.StartsWith(@"\\")) return @"\\?\UNC\" + path.Substring(2);
        return @"\\?\" + path;
    }

    private static DateTime FromFt(uint low, uint high)
    {
        long ft = ((long)high << 32) | low;
        if (ft <= 0) return DateTime.FromFileTimeUtc(0);
        try { return DateTime.FromFileTimeUtc(ft); } catch { return DateTime.FromFileTimeUtc(0); }
    }

    public static List<UpbEntry> List(string directory)
    {
        List<UpbEntry> result = new List<UpbEntry>();
        WIN32_FIND_DATA d;
        string pattern = Long(directory.TrimEnd('\\') + @"\*");
        IntPtr h = FindFirstFileExW(pattern, 1, out d, 0, IntPtr.Zero, 2);
        if (h == InvalidHandle)
        {
            int e = Marshal.GetLastWin32Error();
            if (e == 2 || e == 18) return result;
            throw new UpbIoException(e, directory);
        }
        try
        {
            do
            {
                if (d.cFileName == "." || d.cFileName == "..") continue;
                UpbEntry entry = new UpbEntry();
                entry.Name = d.cFileName;
                entry.Attributes = d.dwFileAttributes;
                entry.Size = ((long)d.nFileSizeHigh << 32) | d.nFileSizeLow;
                entry.CreationTimeUtc = FromFt(d.ftCreationLow, d.ftCreationHigh);
                entry.LastAccessTimeUtc = FromFt(d.ftAccessLow, d.ftAccessHigh);
                entry.LastWriteTimeUtc = FromFt(d.ftWriteLow, d.ftWriteHigh);
                entry.ReparseTag = (d.dwFileAttributes & 0x400) != 0 ? d.dwReserved0 : 0;
                result.Add(entry);
            } while (FindNextFileW(h, out d));
            int last = Marshal.GetLastWin32Error();
            if (last != 18 && last != 0) throw new UpbIoException(last, directory);
        }
        finally { FindClose(h); }
        return result;
    }

    // Returns null when the path does not exist.
    public static UpbEntry GetInfo(string path)
    {
        WIN32_FILE_ATTRIBUTE_DATA a;
        if (!GetFileAttributesExW(Long(path), 0, out a))
        {
            int e = Marshal.GetLastWin32Error();
            if (e == 2 || e == 3 || e == 123 || e == 161) return null;
            throw new UpbIoException(e, path);
        }
        UpbEntry entry = new UpbEntry();
        int cut = path.TrimEnd('\\').LastIndexOf('\\');
        entry.Name = cut >= 0 ? path.TrimEnd('\\').Substring(cut + 1) : path;
        entry.Attributes = a.dwFileAttributes;
        entry.Size = ((long)a.nFileSizeHigh << 32) | a.nFileSizeLow;
        entry.CreationTimeUtc = FromFt(a.ftCreationLow, a.ftCreationHigh);
        entry.LastAccessTimeUtc = FromFt(a.ftAccessLow, a.ftAccessHigh);
        entry.LastWriteTimeUtc = FromFt(a.ftWriteLow, a.ftWriteHigh);
        if ((a.dwFileAttributes & 0x400) != 0 && path.TrimEnd('\\').Length > 3)
        {
            WIN32_FIND_DATA d;
            IntPtr h = FindFirstFileExW(Long(path.TrimEnd('\\')), 1, out d, 0, IntPtr.Zero, 0);
            if (h != InvalidHandle) { entry.ReparseTag = d.dwReserved0; FindClose(h); }
        }
        return entry;
    }

    public static bool FileExists(string path)
    {
        UpbEntry e = GetInfo(path);
        return e != null && !e.IsDirectory;
    }

    public static bool DirectoryExists(string path)
    {
        UpbEntry e = GetInfo(path);
        return e != null && e.IsDirectory;
    }

    public static void CopyFile(string source, string destination, bool overwrite)
    {
        if (!CopyFileW(Long(source), Long(destination), !overwrite))
        {
            int e = Marshal.GetLastWin32Error();
            throw new UpbIoException(e, source);
        }
    }

    // Creates the directory and any missing parents. Returns true when the leaf was created.
    public static bool CreateDirectory(string path)
    {
        string p = path.TrimEnd('\\');
        if (DirectoryExists(p)) return false;
        int cut = p.LastIndexOf('\\');
        if (cut > 2)
        {
            string parent = p.Substring(0, cut);
            bool isUncRoot = parent.StartsWith(@"\\") && parent.Substring(2).Split('\\').Length <= 2;
            if (!isUncRoot && !DirectoryExists(parent)) CreateDirectory(parent);
        }
        if (!CreateDirectoryW(Long(p), IntPtr.Zero))
        {
            int e = Marshal.GetLastWin32Error();
            if (e == 183 && DirectoryExists(p)) return false;
            throw new UpbIoException(e, path);
        }
        return true;
    }

    public static void SetTimes(string path, DateTime creationUtc, DateTime lastAccessUtc, DateTime lastWriteUtc, bool isDirectory)
    {
        uint flags = isDirectory ? 0x02000000u : 0u;
        using (SafeFileHandle h = CreateFileW(Long(path), 0x100, 7, IntPtr.Zero, 3, flags, IntPtr.Zero))
        {
            if (h.IsInvalid) throw new UpbIoException(Marshal.GetLastWin32Error(), path);
            long c = creationUtc.ToUniversalTime().ToFileTimeUtc();
            long a = lastAccessUtc.ToUniversalTime().ToFileTimeUtc();
            long w = lastWriteUtc.ToUniversalTime().ToFileTimeUtc();
            if (!SetFileTime(h, ref c, ref a, ref w)) throw new UpbIoException(Marshal.GetLastWin32Error(), path);
        }
    }

    public static uint GetAttributes(string path)
    {
        UpbEntry e = GetInfo(path);
        return e == null ? InvalidAttributes : e.Attributes;
    }

    public static void SetAttributes(string path, uint attributes)
    {
        if (!SetFileAttributesW(Long(path), attributes)) throw new UpbIoException(Marshal.GetLastWin32Error(), path);
    }

    public static void DeleteFile(string path)
    {
        if (!DeleteFileW(Long(path))) throw new UpbIoException(Marshal.GetLastWin32Error(), path);
    }

    public static string HashFile(string path)
    {
        SafeFileHandle h = CreateFileW(Long(path), 0x80000000, 7, IntPtr.Zero, 3, 0x08000000, IntPtr.Zero);
        if (h.IsInvalid) throw new UpbIoException(Marshal.GetLastWin32Error(), path);
        using (FileStream fs = new FileStream(h, FileAccess.Read, 1 << 20))
        using (SHA256 sha = SHA256.Create())
        {
            byte[] hash = sha.ComputeHash(fs);
            return BitConverter.ToString(hash).Replace("-", "");
        }
    }

    // Free bytes available to the caller, or -1 when unknown.
    public static long GetFreeBytes(string directory)
    {
        ulong avail, total, free;
        if (string.IsNullOrEmpty(directory)) return -1;
        string d =directory.EndsWith("\\") ? directory : directory + "\\";
        if (!GetDiskFreeSpaceExW(d, out avail, out total, out free)) return -1;
        return (long)avail;
    }
}
'@
}

#endregion

#region General helpers

function Stop-UpbValidation {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw (New-Object UpbValidationException $Message)
}

function Get-UpbInnerException {
    param($ErrorOrException)
    $ex = $ErrorOrException
    if ($ex -is [System.Management.Automation.ErrorRecord]) { $ex = $ex.Exception }
    # Unwrap the wrappers PowerShell adds around .NET exceptions (method calls, rethrows).
    while ($ex -and $ex.InnerException) {
        if ($ex -is [UpbValidationException] -or $ex -is [UpbIoException]) { break }
        $isWrapper = ($ex -is [System.Management.Automation.MethodInvocationException]) -or
            ($ex -is [System.Management.Automation.ActionPreferenceStopException]) -or
            ($ex.GetType().FullName -eq 'System.Management.Automation.RuntimeException')
        if (-not $isWrapper) { break }
        $ex = $ex.InnerException
    }
    return $ex
}

function Test-UpbIsAdmin {
    if ($null -eq $script:UpbIsAdminCache) {
        try {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $script:UpbIsAdminCache = (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { $script:UpbIsAdminCache = $false }
    }
    return [bool]$script:UpbIsAdminCache
}

function Get-UpbCurrentUserSid {
    try { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return $null }
}

function Format-UpbBytes {
    param([double]$Bytes)
    if ($Bytes -lt 0) { return 'unknown' }
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes = $Bytes / 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} {1}' -f $Bytes, $units[$i]) }
    return ('{0:N2} {1}' -f $Bytes, $units[$i])
}

function Format-UpbDuration {
    param([TimeSpan]$Span)
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
}

function Format-UpbLocalTime {
    param($Value)
    if ($null -eq $Value) { return '(none)' }
    return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm:ss')
}

# Normalises a user-supplied absolute path (no trailing separator except for drive roots).
function ConvertTo-UpbFullPath {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$BasePath)
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if (-not [IO.Path]::IsPathRooted($p)) {
        if ($BasePath) { $p = [IO.Path]::Combine($BasePath, $p) }
        else { $p = [IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $p) }
    }
    $p = [IO.Path]::GetFullPath($p)
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    return $p
}

function Test-UpbPathUnder {
    # True when $Path equals $Root or lies inside it (case-insensitive, separator-aware).
    param([string]$Path, [string]$Root, [switch]$Strict)
    if (-not $Path -or -not $Root) { return $false }
    $p = $Path.TrimEnd('\')
    $r = $Root.TrimEnd('\')
    if ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return (-not $Strict) }
    return $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-UpbRelativePath {
    param([string]$Path, [string]$Root)
    if (-not (Test-UpbPathUnder -Path $Path -Root $Root)) { return $null }
    $p = $Path.TrimEnd('\'); $r = $Root.TrimEnd('\')
    if ($p.Length -eq $r.Length) { return '' }
    return $p.Substring($r.Length + 1)
}

function Join-UpbPath {
    param([string]$Base, [string]$Child)
    if ([string]::IsNullOrEmpty($Child)) { return $Base }
    return ($Base.TrimEnd('\') + '\' + $Child.TrimStart('\'))
}

function Get-UpbSafeName {
    param([string]$Name)
    $leaf = $Name
    if ($leaf -match '\\') { $leaf = $leaf.Substring($leaf.LastIndexOf('\') + 1) }
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $chars = foreach ($c in $leaf.ToCharArray()) { if ($invalid -contains $c) { '_' } else { $c } }
    $safe = (-join $chars).Trim().TrimEnd('.')
    if (-not $safe) { $safe = 'Profile' }
    return $safe
}

# Validates a relative path taken from a manifest so it can never escape its root.
function Test-UpbSafeRelativePath {
    param([string]$RelativePath, [switch]$AllowEmpty)
    if ([string]::IsNullOrEmpty($RelativePath)) { return [bool]$AllowEmpty }
    if ($RelativePath.Contains('/') -or $RelativePath.Contains(':')) { return $false }
    if ($RelativePath.StartsWith('\') -or $RelativePath.EndsWith('\')) { return $false }
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    foreach ($segment in $RelativePath.Split('\')) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') { return $false }
        if ($segment.IndexOfAny($invalid) -ge 0) { return $false }
        if ($segment -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { return $false }
    }
    return $true
}

function Get-UpbUniqueFilePath {
    param([string]$Path)
    if (-not [UpbIo]::FileExists($Path) -and -not [UpbIo]::DirectoryExists($Path)) { return $Path }
    $cut = $Path.LastIndexOf('\')
    $dir = $Path.Substring(0, $cut)
    $name = $Path.Substring($cut + 1)
    $dot = $name.LastIndexOf('.')
    if ($dot -gt 0) { $base = $name.Substring(0, $dot); $ext = $name.Substring($dot) } else { $base = $name; $ext = '' }
    for ($n = 2; $n -lt 100000; $n++) {
        $candidate = '{0}\{1} ({2}){3}' -f $dir, $base, $n, $ext
        if (-not [UpbIo]::FileExists($candidate) -and -not [UpbIo]::DirectoryExists($candidate)) { return $candidate }
    }
    throw "Could not find a unique name for $Path"
}

function Get-UpbNearestExistingDirectory {
    param([string]$Path)
    $p = $Path.TrimEnd('\')
    while ($p) {
        if ([UpbIo]::DirectoryExists($p)) { return $p }
        $cut = $p.LastIndexOf('\')
        if ($cut -le 1) { break }
        $p = $p.Substring(0, $cut)
        if ($p.Length -eq 2 -and $p[1] -eq ':') { $p = $p + '\' ; if ([UpbIo]::DirectoryExists($p)) { return $p }; break }
    }
    return $null
}

# Creates and deletes a probe file. Returns $null on success or an explanation.
function Test-UpbWriteAccess {
    param([string]$Directory)
    $probe = Join-UpbPath $Directory ('.upb-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($probe, 'UserProfileBackup write test')
        [IO.File]::Delete($probe)
        return $null
    } catch {
        $inner = Get-UpbInnerException $_
        if ($inner -is [UnauthorizedAccessException]) {
            if (Test-UpbIsAdmin) { return "Access to '$Directory' is denied." }
            return "Access to '$Directory' is denied. Run PowerShell as Administrator (elevated) to write there."
        }
        return "Cannot write to '$Directory': $($inner.Message)"
    }
}

function ConvertTo-UpbHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-UpbHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-UpbHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($i in $InputObject) { $list.Add((ConvertTo-UpbHashtable $i)) }
        return , $list.ToArray()
    }
    return $InputObject
}

function Read-UpbJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Raw)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-UpbValidation "File not found: $Path" }
    try {
        $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath)
        $obj = $text | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Stop-UpbValidation "'$Path' is not valid JSON: $((Get-UpbInnerException $_).Message)"
    }
    if ($Raw) { return $obj }
    return (ConvertTo-UpbHashtable $obj)
}

function Write-UpbJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$InputObject, [int]$Depth = 12)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function ConvertTo-UpbUtc {
    # Accepts DateTime or ISO-8601 strings (PowerShell 7 turns JSON dates into DateTime).
    param($Value)
    if ($null -eq $Value -or ($Value -is [string] -and -not $Value)) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    $dto = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) {
        return $dto.UtcDateTime
    }
    return $null
}

function ConvertTo-UpbIsoUtc {
    param([datetime]$Value)
    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-UpbIsoLocal {
    param([datetime]$Value)
    return $Value.ToString('yyyy-MM-ddTHH:mm:ss.fffffffzzz', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-UpbAppDataRoot {
    if ($env:UPB_HOME) { return $env:UPB_HOME }
    return (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'UserProfileBackup')
}

function Get-UpbConfigurationDirectory { return (Join-Path (Get-UpbAppDataRoot) 'Configurations') }

function Get-UpbDefaultLogDirectory {
    if ($env:UPB_HOME) { return (Join-Path $env:UPB_HOME 'Logs') }
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'UserProfileBackup\Logs')
}

#endregion

#region Logging and progress state

function New-UpbState {
    param([switch]$ConsoleOutput, [switch]$ConsoleProgress, [switch]$ConsoleCancel)
    $state = [hashtable]::Synchronized(@{})
    $state.CancelRequested = $false
    $state.Phase = 'Idle'
    $state.Activity = ''
    $state.Profile = ''
    $state.CurrentFile = ''
    $state.FilesDone = 0
    $state.FilesTotal = 0
    $state.BytesDone = [long]0
    $state.BytesTotal = [long]0
    $state.FilesCopied = 0
    $state.FilesSkipped = 0
    $state.FilesFailed = 0
    $state.Started = Get-Date
    $state.Percent = 0
    $state.Messages = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $state.ConsoleOutput = [bool]$ConsoleOutput
    $state.ConsoleProgress = [bool]$ConsoleProgress
    $state.ConsoleCancel = [bool]$ConsoleCancel
    $state.OnProgress = $null
    $state.Completed = $false
    $state.Result = $null
    return $state
}

function Resolve-UpbLogFile {
    param([string]$LogPath, [string]$OperationName)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $fileName = 'UserProfileBackup_{0}_{1}.log' -f $OperationName, $stamp
    if (-not $LogPath) { return (Join-Path (Get-UpbDefaultLogDirectory) $fileName) }
    $full = ConvertTo-UpbFullPath $LogPath
    if ((Test-Path -LiteralPath $full -PathType Container) -or -not ([IO.Path]::GetExtension($full))) {
        return (Join-Path $full $fileName)
    }
    return $full
}

function Open-UpbLog {
    param([string]$LogPath, [string]$OperationName, [switch]$WhatIfMode)
    Close-UpbLog
    $script:UpbLogFile = $null
    if ($WhatIfMode) { return $null }
    $file = Resolve-UpbLogFile -LogPath $LogPath -OperationName $OperationName
    $dir = Split-Path -Parent $file
    try {
        if (-not (Test-Path -LiteralPath $dir)) { [void][IO.Directory]::CreateDirectory($dir) }
        $script:UpbLog = New-Object IO.StreamWriter($file, $true, (New-Object Text.UTF8Encoding($true)))
        $script:UpbLog.AutoFlush = $true
        $script:UpbLogFile = $file
    } catch {
        Stop-UpbValidation "Cannot open the log file '$file': $((Get-UpbInnerException $_).Message)"
    }
    return $file
}

function Close-UpbLog {
    if ($script:UpbLog) {
        try { $script:UpbLog.Flush(); $script:UpbLog.Dispose() } catch { }
        $script:UpbLog = $null
    }
}

function Write-UpbLog {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DETAIL', 'OK')][string]$Level = 'INFO',
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.PadRight(6), $Message
    if ($script:UpbLog) { try { $script:UpbLog.WriteLine($line) } catch { } }
    $state = $script:UpbState
    if ($Level -eq 'DETAIL') { return }
    if ($state -and $state.Messages) { [void]$state.Messages.Add(('[{0}] {1}' -f $Level, $Message)) }
    if ($state -and $state.ConsoleOutput) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'OK' { 'Green' } default { 'Gray' } }
        Write-Host ('[{0}] {1}' -f $Level, $Message) -ForegroundColor $color
    }
}

function Update-UpbProgress {
    param([System.Collections.IDictionary]$State, [switch]$Force)
    if (-not $State) { return }
    if ($State.BytesTotal -gt 0) { $State.Percent = [int][math]::Min(100, ($State.BytesDone * 100.0 / $State.BytesTotal)) }
    elseif ($State.FilesTotal -gt 0) { $State.Percent = [int][math]::Min(100, ($State.FilesDone * 100.0 / $State.FilesTotal)) }
    if ($State.OnProgress) { & $State.OnProgress $State }
    if (-not $script:UpbProgressClock) { $script:UpbProgressClock = [Diagnostics.Stopwatch]::StartNew() }
    if (-not $Force -and $script:UpbProgressClock.ElapsedMilliseconds -lt 200) { return }
    $script:UpbProgressClock.Restart()
    if ($State.ConsoleCancel) {
        try {
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Escape -or ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control))) {
                    if (-not $State.CancelRequested) {
                        $State.CancelRequested = $true
                        Write-UpbLog WARN 'Cancellation requested. Stopping after the current file...'
                    }
                }
            }
        } catch { $State.ConsoleCancel = $false }
    }
    if ($State.ConsoleProgress) {
        $elapsed = (Get-Date) - $State.Started
        $status = '{0} | files {1:N0}/{2:N0} | {3} of {4} | elapsed {5} | Esc = cancel' -f $State.Profile, $State.FilesDone, $State.FilesTotal,
            (Format-UpbBytes $State.BytesDone), (Format-UpbBytes $State.BytesTotal), (Format-UpbDuration $elapsed)
        $current = [string]$State.CurrentFile
        if (-not $current) { $current = ' ' }
        Write-Progress -Id 1 -Activity $State.Activity -Status $status -CurrentOperation $current -PercentComplete $State.Percent
    }
}

function Complete-UpbProgress {
    param([System.Collections.IDictionary]$State)
    if ($State -and $State.ConsoleProgress) { Write-Progress -Id 1 -Activity $State.Activity -Completed }
}

function Get-UpbFailureInfo {
    param($ErrorRecord, [uint32]$Attributes = 0)
    $ex = Get-UpbInnerException $ErrorRecord
    $code = 0
    if ($ex -is [UpbIoException]) { $code = $ex.Win32Code }
    elseif ($ex -is [UnauthorizedAccessException]) { $code = 5 }
    $category = 'Error'
    $fatal = $false
    $message = $ex.Message
    switch ($code) {
        5 {
            $category = 'AccessDenied'
            if ($Attributes -band 0x4000) {
                $category = 'Encrypted'
                $message = 'Access denied to an EFS-encrypted file. Only the owning account, with its encryption certificate, can read it.'
            } elseif (-not (Test-UpbIsAdmin)) {
                $message = 'Access denied. Run PowerShell as Administrator (elevated) to read or write files that belong to another user.'
            } else {
                $message = 'Access denied (the file''s permissions exclude administrators, or it is protected by the system).'
            }
        }
        { $_ -eq 32 -or $_ -eq 33 } {
            $category = 'Locked'
            $message = 'The file is locked by another process. Close the program using it (or sign the user out) and run again.'
        }
        { $_ -ge 6000 -and $_ -le 6023 } {
            $category = 'Encrypted'
            $message = 'EFS-encrypted file could not be copied: ' + $ex.Message
        }
        { $_ -eq 112 -or $_ -eq 39 } { $category = 'DiskFull'; $fatal = $true; $message = 'The destination is full.' }
        1920 { $category = 'Inaccessible'; $message = 'The system cannot access this file (protected system file or app execution alias).' }
        206 { $category = 'PathTooLong'; $message = 'The path is too long for the destination file system.' }
        { $_ -eq 2 -or $_ -eq 3 } { $category = 'NotFound'; $message = 'The file disappeared before it could be copied.' }
        362 { $category = 'CloudFile'; $message = 'The cloud sync provider (OneDrive) is not running, so this file cannot be downloaded.' }
    }
    return [pscustomobject]@{ Code = $code; Category = $category; Message = $message; Fatal = $fatal }
}

#endregion

#region Date filtering

function ConvertTo-UpbDateInput {
    param([AllowNull()]$Value, [string]$Name = 'date')
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -is [datetime]) {
        $dt = $Value
        if ($dt.Kind -eq [DateTimeKind]::Utc) { $dt = $dt.ToLocalTime() }
        $dt = [datetime]::SpecifyKind($dt, [DateTimeKind]::Local)
        return [pscustomobject]@{ Value = $dt; DateOnly = $false; Text = $dt.ToString('yyyy-MM-dd HH:mm:ss') }
    }
    $text = ([string]$Value).Trim()
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [Globalization.DateTimeStyles]::AssumeLocal
    $iso = [string[]]@(
        'yyyy-MM-dd', 'yyyy-MM-ddTHH:mm', 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm:ss.FFFFFFF',
        'yyyy-MM-ddTHH:mmK', 'yyyy-MM-ddTHH:mm:ssK', 'yyyy-MM-ddTHH:mm:ss.FFFFFFFK',
        'yyyy-MM-dd HH:mm', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd H:mm', 'yyyy-MM-dd H:mm:ss'
    )
    $dt = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($text, $iso, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)
    if (-not $ok) { $ok = [datetime]::TryParse($text, [Globalization.CultureInfo]::CurrentCulture, $styles, [ref]$dt) }
    if (-not $ok) { $ok = [datetime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt) }
    if (-not $ok) {
        Stop-UpbValidation ("'{0}' is not a valid {1}. Use a date such as {2} or a date and time such as {2} 14:30." -f $text, $Name, (Get-Date -Format 'yyyy-MM-dd'))
    }
    if ($dt.Kind -eq [DateTimeKind]::Utc) { $dt = $dt.ToLocalTime() }
    if ($dt.Year -lt 1601) { Stop-UpbValidation "The $Name '$text' is earlier than the year 1601, which Windows file times cannot represent." }
    $dt = [datetime]::SpecifyKind($dt, [DateTimeKind]::Local)
    $dateOnly = ($text -notmatch ':') -and ($dt.TimeOfDay -eq [TimeSpan]::Zero)
    return [pscustomobject]@{ Value = $dt; DateOnly = $dateOnly; Text = $text }
}

function Resolve-UpbDateFilter {
    [CmdletBinding()]
    param(
        [string]$Filter = 'All',
        $Date, $StartDate, $EndDate,
        [string]$DateField = 'CreationTime',
        [datetime]$Now = (Get-Date)
    )
    if (-not $Filter) { $Filter = 'All' }
    if ($script:UpbDateFilters -notcontains $Filter) { Stop-UpbValidation "Unknown date filter '$Filter'. Use: $($script:UpbDateFilters -join ', ')." }
    if (-not $DateField) { $DateField = 'CreationTime' }
    if ('CreationTime', 'LastWriteTime' -notcontains $DateField) { Stop-UpbValidation "Unknown date field '$DateField'. Use CreationTime or LastWriteTime." }

    $d = ConvertTo-UpbDateInput $Date 'date'
    $s = ConvertTo-UpbDateInput $StartDate 'start date'
    $e = ConvertTo-UpbDateInput $EndDate 'end date'
    $needsDate = 'On', 'After', 'Before'
    if ($needsDate -contains $Filter) {
        if (-not $d) { Stop-UpbValidation "The '$Filter' date filter needs a date (-Date)." }
        if ($s -or $e) { Stop-UpbValidation "Start and end dates apply only to the Range filter." }
    } elseif ($Filter -eq 'Range') {
        if (-not $s -or -not $e) { Stop-UpbValidation 'The Range date filter needs both a start date (-StartDate) and an end date (-EndDate).' }
        if ($d) { Stop-UpbValidation 'A single date (-Date) applies only to the On, After and Before filters.' }
    } elseif ($d -or $s -or $e) {
        Stop-UpbValidation "The '$Filter' date filter does not take a date."
    }

    $lower = $null; $lowerInc = $true; $upper = $null; $upperInc = $false
    $notes = New-Object System.Collections.Generic.List[string]
    switch ($Filter) {
        'On' {
            $lower = $d.Value.Date; $upper = $d.Value.Date.AddDays(1)
            if (-not $d.DateOnly) { $notes.Add('"On" uses the whole calendar day; the time part was ignored.') }
        }
        'After' {
            if ($d.DateOnly) { $lower = $d.Value.Date.AddDays(1); $lowerInc = $true }
            else { $lower = $d.Value; $lowerInc = $false }
        }
        'Before' {
            if ($d.DateOnly) { $upper = $d.Value.Date } else { $upper = $d.Value }
            $upperInc = $false
        }
        'CurrentWeek' {
            $monday = $Now.Date.AddDays( - ((([int]$Now.DayOfWeek) + 6) % 7))
            $lower = $monday; $upper = $monday.AddDays(7)
        }
        'CurrentMonth' {
            $first = New-Object DateTime($Now.Year, $Now.Month, 1, 0, 0, 0, [DateTimeKind]::Local)
            $lower = $first; $upper = $first.AddMonths(1)
        }
        'Range' {
            if ($s.DateOnly) { $lower = $s.Value.Date } else { $lower = $s.Value }
            $lowerInc = $true
            if ($e.DateOnly) { $upper = $e.Value.Date.AddDays(1); $upperInc = $false } else { $upper = $e.Value; $upperInc = $true }
            $startCompare = $s.Value; $endCompare = $e.Value
            if ($s.DateOnly -and $e.DateOnly) { $startCompare = $s.Value.Date; $endCompare = $e.Value.Date }
            if ($startCompare -gt $endCompare -or $lower -gt $upper -or ($lower -eq $upper -and -not $upperInc)) {
                Stop-UpbValidation ("The date range is reversed: the start ({0}) is after the end ({1})." -f $s.Text, $e.Text)
            }
        }
    }

    $offset = [TimeZoneInfo]::Local.GetUtcOffset($Now)
    $sign = '+'; if ($offset -lt [TimeSpan]::Zero) { $sign = '-' }
    $tz = 'local time, UTC{0}{1:hh\:mm} ({2})' -f $sign, $offset.Duration(), [TimeZoneInfo]::Local.Id
    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $lower) {
        if ($lowerInc) { $parts.Add('on or after ' + (Format-UpbLocalTime $lower)) } else { $parts.Add('strictly after ' + (Format-UpbLocalTime $lower)) }
    }
    if ($null -ne $upper) {
        if ($upperInc) { $parts.Add('on or before ' + (Format-UpbLocalTime $upper)) } else { $parts.Add('strictly before ' + (Format-UpbLocalTime $upper)) }
    }
    if ($parts.Count -eq 0) { $description = 'All files (no date filter).' }
    else { $description = ('Files whose {0} is {1} [{2}].' -f $DateField, ($parts -join ' and '), $tz) }

    $inputs = [ordered]@{}
    if ($d) { $inputs.Date = $d.Text; $inputs.DateOnly = $d.DateOnly }
    if ($s) { $inputs.StartDate = $s.Text; $inputs.StartDateOnly = $s.DateOnly }
    if ($e) { $inputs.EndDate = $e.Text; $inputs.EndDateOnly = $e.DateOnly }

    return [pscustomobject]@{
        Filter         = $Filter
        DateField      = $DateField
        Lower          = $lower
        LowerInclusive = $lowerInc
        Upper          = $upper
        UpperInclusive = $upperInc
        EvaluatedAt    = $Now
        Description    = $description
        Notes          = $notes.ToArray()
        Inputs         = $inputs
    }
}

function Test-UpbDateInFilter {
    param($Filter, [datetime]$Value)
    if ($null -ne $Filter.Lower) {
        if ($Filter.LowerInclusive) { if ($Value -lt $Filter.Lower) { return $false } }
        elseif ($Value -le $Filter.Lower) { return $false }
    }
    if ($null -ne $Filter.Upper) {
        if ($Filter.UpperInclusive) { if ($Value -gt $Filter.Upper) { return $false } }
        elseif ($Value -ge $Filter.Upper) { return $false }
    }
    return $true
}

function ConvertTo-UpbManifestDateFilter {
    param($Filter)
    $h = [ordered]@{
        Filter         = $Filter.Filter
        DateField      = $Filter.DateField
        Lower          = $null
        LowerInclusive = $Filter.LowerInclusive
        Upper          = $null
        UpperInclusive = $Filter.UpperInclusive
        EvaluatedAt    = ConvertTo-UpbIsoLocal $Filter.EvaluatedAt
        TimeZone       = [TimeZoneInfo]::Local.Id
        Description    = $Filter.Description
        Inputs         = $Filter.Inputs
    }
    if ($null -ne $Filter.Lower) { $h.Lower = ConvertTo-UpbIsoLocal $Filter.Lower }
    if ($null -ne $Filter.Upper) { $h.Upper = ConvertTo-UpbIsoLocal $Filter.Upper }
    return $h
}

#endregion

#region Options, settings and configuration profiles

function New-UpbDefaultOptions {
    $o = [ordered]@{
        Operation             = $null
        Interface             = 'Console'
        Profiles              = @()
        IncludeSystemProfiles = $false
        BackupScope           = 'UserData'
        Folders               = @()
        Destination           = $null
        BackupPath            = $null
        RestoreProfiles       = @()
        RestoreMappings       = @()
        RestoreMapPath        = $null
        DateFilter            = 'All'
        Date                  = $null
        StartDate             = $null
        EndDate               = $null
        DateField             = 'CreationTime'
        ConflictAction        = 'Skip'
        Verify                = $false
        LogPath               = $null
        # Run-time values (not saved in configurations)
        Name                  = $null
        Description           = $null
        WhatIf                = $false
        NonInteractive        = $false
        OverwriteConfirmed    = $false
        ResolvedDateFilter    = $null
        Sources               = @{}
    }
    foreach ($k in $script:UpbOptionKeys) { $o.Sources[$k] = 'Default' }
    return $o
}

function Copy-UpbOptions {
    param([System.Collections.IDictionary]$Options)
    $copy = [ordered]@{}
    foreach ($k in $Options.Keys) {
        $v = $Options[$k]
        if ($k -eq 'Sources') { $copy[$k] = @{} + $v }
        elseif ($v -is [array]) { $copy[$k] = @($v) }
        else { $copy[$k] = $v }
    }
    return $copy
}

function Set-UpbOptionLayer {
    param([System.Collections.IDictionary]$Options, [System.Collections.IDictionary]$Layer, [string]$Source)
    if (-not $Layer) { return }
    $has = { param($k) $Layer.Contains($k) -and $null -ne $Layer[$k] -and -not ($Layer[$k] -is [string] -and $Layer[$k] -eq '') }
    # A layer that changes the filter, scope or restore mapping replaces the dependent values beneath it.
    if (& $has 'DateFilter') { $Options.Date = $null; $Options.StartDate = $null; $Options.EndDate = $null }
    if ((& $has 'BackupScope') -and -not (& $has 'Folders')) { $Options.Folders = @() }
    if ((& $has 'RestoreMapPath') -or (& $has 'RestoreMappings')) { $Options.RestoreMappings = @(); $Options.RestoreMapPath = $null }
    foreach ($k in $script:UpbOptionKeys) {
        if (& $has $k) {
            $v = $Layer[$k]
            if ('Profiles', 'Folders', 'RestoreProfiles', 'RestoreMappings' -contains $k) { $v = @($v) }
            $Options[$k] = $v
            $Options.Sources[$k] = $Source
        }
    }
    if ($Layer.Contains('Name') -and $Layer.Name) { $Options.Name = $Layer.Name }
    if ($Layer.Contains('Description') -and $Layer.Description) { $Options.Description = $Layer.Description }
}

function Test-UpbValueIn {
    param($Errors, [System.Collections.IDictionary]$Data, [string]$Key, [string[]]$Allowed)
    if ($Data.Contains($Key) -and $null -ne $Data[$Key] -and $Data[$Key] -ne '') {
        if ($Allowed -notcontains [string]$Data[$Key]) { $Errors.Add("$Key '$($Data[$Key])' is not valid. Use one of: $($Allowed -join ', ').") }
    }
}

function Test-UpbStringArray {
    param($Errors, [System.Collections.IDictionary]$Data, [string]$Key)
    if ($Data.Contains($Key) -and $null -ne $Data[$Key]) {
        foreach ($item in @($Data[$Key])) {
            if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace($item)) { $Errors.Add("$Key must be a list of non-empty strings."); break }
        }
    }
}

function Test-UpbRestoreMappingList {
    param($Errors, $Mappings, [string]$Context = 'RestoreMappings')
    $seen = @{}
    foreach ($m in @($Mappings)) {
        if (-not ($m -is [System.Collections.IDictionary])) { $Errors.Add("$Context entries must be objects with Profile, Target and Value."); continue }
        foreach ($k in $m.Keys) { if ('Profile', 'Target', 'Value' -notcontains $k) { $Errors.Add("$Context entry has an unknown property '$k'.") } }
        if (-not $m.Profile) { $Errors.Add("$Context entry is missing 'Profile'."); continue }
        if ($seen.ContainsKey(([string]$m.Profile).ToLowerInvariant())) { $Errors.Add("$Context lists profile '$($m.Profile)' more than once.") }
        $seen[([string]$m.Profile).ToLowerInvariant()] = $true
        $target = [string]$m.Target
        if ('Original', 'Profile', 'Folder' -notcontains $target) { $Errors.Add("$Context entry for '$($m.Profile)': Target must be Original, Profile or Folder."); continue }
        if ($target -ne 'Original' -and -not $m.Value) { $Errors.Add("$Context entry for '$($m.Profile)': Target '$target' needs a Value (a profile name/path or a folder).") }
        if ($target -eq 'Folder' -and $m.Value -and -not [IO.Path]::IsPathRooted([string]$m.Value)) { $Errors.Add("$Context entry for '$($m.Profile)': the folder '$($m.Value)' must be an absolute path.") }
    }
}

# Shared validation for configuration files and settings. Returns a list of error strings.
function Test-UpbConfigurationData {
    param([System.Collections.IDictionary]$Data, [ValidateSet('Configuration', 'Settings')][string]$Kind = 'Configuration')
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $Data) { $errors.Add('The file is empty or is not a JSON object.'); return , $errors.ToArray() }
    $credentialWords = 'Password', 'Passwd', 'Credential', 'Credentials', 'Secret', 'Token', 'ApiKey', 'PrivateKey'
    if ($Kind -eq 'Settings') { $allowed = @('SchemaVersion', 'Modified') + $script:UpbSettingKeys; $expected = $script:UpbSettingsSchemaVersion }
    else { $allowed = @('SchemaVersion', 'Name', 'Description', 'Created', 'Modified') + $script:UpbOptionKeys; $expected = $script:UpbConfigSchemaVersion }
    foreach ($k in $Data.Keys) {
        if ($credentialWords | Where-Object { $k -like "*$_*" }) { $errors.Add("'$k' looks like a credential. Configuration files must not contain passwords or other credentials; connect to shares with your own sign-in instead.") }
        elseif ($allowed -notcontains $k) { $errors.Add("Unknown property '$k'.") }
    }
    if (-not $Data.Contains('SchemaVersion')) { $errors.Add('SchemaVersion is missing.') }
    else {
        $sv = $Data.SchemaVersion
        $svInt = 0
        if (-not [int]::TryParse([string]$sv, [ref]$svInt)) { $errors.Add('SchemaVersion must be a number.') }
        elseif ($svInt -gt $expected) { $errors.Add("SchemaVersion $svInt is newer than this script supports ($expected). Update UserProfileBackup.ps1.") }
        elseif ($svInt -lt 1) { $errors.Add('SchemaVersion must be 1 or higher.') }
    }
    Test-UpbValueIn $errors $Data 'Operation' @('Backup', 'Restore')
    Test-UpbValueIn $errors $Data 'Interface' @('Console', 'WPF')
    Test-UpbValueIn $errors $Data 'BackupScope' @('Complete', 'UserData', 'SelectedFolders')
    Test-UpbValueIn $errors $Data 'DateFilter' $script:UpbDateFilters
    Test-UpbValueIn $errors $Data 'DateField' @('CreationTime', 'LastWriteTime')
    Test-UpbValueIn $errors $Data 'ConflictAction' @('Skip', 'Overwrite', 'KeepBoth')
    foreach ($k in 'Profiles', 'Folders', 'RestoreProfiles') { Test-UpbStringArray $errors $Data $k }
    foreach ($k in 'Verify', 'IncludeSystemProfiles') {
        if ($Data.Contains($k) -and $null -ne $Data[$k] -and -not ($Data[$k] -is [bool])) { $errors.Add("$k must be true or false.") }
    }
    foreach ($k in 'Name', 'Description', 'Destination', 'BackupPath', 'RestoreMapPath', 'LogPath') {
        if ($Data.Contains($k) -and $null -ne $Data[$k] -and -not ($Data[$k] -is [string])) { $errors.Add("$k must be a string.") }
    }
    if ($Data.Contains('Destination') -and $Data.Destination -is [string] -and $Data.Destination -match '^[^\\/]*:[^\\/]*@') {
        $errors.Add('Destination must not embed a user name or password.')
    }
    if ($Data.Contains('RestoreMappings') -and $null -ne $Data.RestoreMappings) { Test-UpbRestoreMappingList $errors $Data.RestoreMappings }
    if ($Data.RestoreMappings -and $Data.RestoreMapPath) { $errors.Add('Use either RestoreMappings or RestoreMapPath, not both.') }
    $scope = [string]$Data.BackupScope
    if ($Data.Folders -and @($Data.Folders).Count -gt 0 -and $scope -and $scope -ne 'SelectedFolders' -and $Kind -eq 'Configuration') {
        $errors.Add("Folders can only be used with BackupScope 'SelectedFolders' (the scope is '$scope').")
    }
    if ($Data.Contains('DateFilter') -or $Data.Date -or $Data.StartDate -or $Data.EndDate) {
        $filter = [string]$Data.DateFilter
        if (-not $filter) { $filter = 'All' }
        if ($script:UpbDateFilters -contains $filter) {
            $dateText = $Data.Date; $startText = $Data.StartDate; $endText = $Data.EndDate
            # PowerShell 7 converts ISO strings in JSON to DateTime; keep the time component.
            try { [void](Resolve-UpbDateFilter -Filter $filter -Date $dateText -StartDate $startText -EndDate $endText -DateField 'CreationTime') }
            catch { $errors.Add((Get-UpbInnerException $_).Message) }
        }
    }
    return , $errors.ToArray()
}

function Get-UpbSettingsPath { return (Join-Path (Get-UpbAppDataRoot) 'settings.json') }

function Get-UpbSettings {
    param([switch]$Quiet)
    $settings = [ordered]@{ SchemaVersion = $script:UpbSettingsSchemaVersion }
    $path = Get-UpbSettingsPath
    $script:UpbSettingsWarning = $null
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $data = Read-UpbJsonFile -Path $path
            $errors = Test-UpbConfigurationData -Data $data -Kind Settings
            if ($errors.Count -gt 0) { throw ($errors -join ' ') }
            foreach ($k in $script:UpbSettingKeys) { if ($data.Contains($k) -and $null -ne $data[$k]) { $settings[$k] = $data[$k] } }
        } catch {
            $script:UpbSettingsWarning = "Saved settings in '$path' were ignored: $((Get-UpbInnerException $_).Message)"
            if (-not $Quiet) { Write-Warning $script:UpbSettingsWarning }
        }
    }
    return $settings
}

function Save-UpbSettings {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$AppSettings)
    $out = [ordered]@{ SchemaVersion = $script:UpbSettingsSchemaVersion; Modified = (ConvertTo-UpbIsoLocal (Get-Date)) }
    foreach ($k in $script:UpbSettingKeys) {
        if ($AppSettings.Contains($k) -and $null -ne $AppSettings[$k] -and $AppSettings[$k] -ne '') { $out[$k] = $AppSettings[$k] }
    }
    if ($out.Contains('Folders')) { $out.Folders = @($out.Folders) }
    $errors = Test-UpbConfigurationData -Data $out -Kind Settings
    if ($errors.Count -gt 0) { Stop-UpbValidation ("Settings were not saved: " + ($errors -join ' ')) }
    $path = Get-UpbSettingsPath
    Write-UpbJsonFile -Path $path -InputObject $out
    return $path
}

function Import-UpbConfiguration {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = ConvertTo-UpbFullPath $Path
    $data = Read-UpbJsonFile -Path $full
    if (-not ($data -is [System.Collections.IDictionary])) { Stop-UpbValidation "'$full' does not contain a configuration object." }
    foreach ($k in 'Date', 'StartDate', 'EndDate') {
        if ($data[$k] -is [datetime]) { $data[$k] = ([datetime]$data[$k]).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') }
    }
    $errors = Test-UpbConfigurationData -Data $data -Kind Configuration
    if ($errors.Count -gt 0) {
        Stop-UpbValidation ("The configuration '$full' is not valid:" + [Environment]::NewLine + (($errors | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine))
    }
    if ($data.RestoreMapPath -and -not [IO.Path]::IsPathRooted($data.RestoreMapPath)) {
        $data.RestoreMapPath = ConvertTo-UpbFullPath $data.RestoreMapPath -BasePath (Split-Path -Parent $full)
    }
    $data['__Path'] = $full
    return $data
}

function ConvertTo-UpbConfiguration {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Options, [string]$Name, [string]$Description)
    if (-not $Name) { $Name = $Options.Name }
    if (-not $Description) { $Description = $Options.Description }
    $c = [ordered]@{
        SchemaVersion = $script:UpbConfigSchemaVersion
        Name          = $Name
        Description   = $Description
        Modified      = (ConvertTo-UpbIsoLocal (Get-Date))
        Operation     = $Options.Operation
        Interface     = $Options.Interface
    }
    if ($Options.Operation -ne 'Restore') {
        $c.Profiles = @($Options.Profiles)
        $c.IncludeSystemProfiles = [bool]$Options.IncludeSystemProfiles
        $c.BackupScope = $Options.BackupScope
        if ($Options.BackupScope -eq 'SelectedFolders') { $c.Folders = @($Options.Folders) }
        $c.Destination = $Options.Destination
        $c.DateFilter = $Options.DateFilter
        switch ($Options.DateFilter) {
            { 'On', 'After', 'Before' -contains $_ } { $c.Date = [string]$Options.Date }
            'Range' { $c.StartDate = [string]$Options.StartDate; $c.EndDate = [string]$Options.EndDate }
        }
        $c.DateField = $Options.DateField
    }
    if ($Options.Operation -ne 'Backup') {
        $c.BackupPath = $Options.BackupPath
        $c.RestoreProfiles = @($Options.RestoreProfiles)
        if ($Options.RestoreMapPath) { $c.RestoreMapPath = $Options.RestoreMapPath }
        elseif (@($Options.RestoreMappings).Count -gt 0) {
            $c.RestoreMappings = @(foreach ($m in $Options.RestoreMappings) {
                    $e = [ordered]@{ Profile = $m.Profile; Target = $m.Target }
                    if ($m.Target -ne 'Original') { $e.Value = $m.Value }
                    $e
                })
        }
        $c.ConflictAction = $Options.ConflictAction
    }
    $c.Verify = [bool]$Options.Verify
    $c.LogPath = $Options.LogPath
    $clean = [ordered]@{}
    foreach ($k in $c.Keys) {
        $v = $c[$k]
        if ($null -eq $v) { continue }
        if ($v -is [string] -and $v -eq '' -and $k -ne 'Name') { continue }
        $clean[$k] = $v
    }
    return $clean
}

function Export-UpbConfiguration {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Options, [Parameter(Mandatory = $true)][string]$Path, [string]$Name, [string]$Description)
    $config = ConvertTo-UpbConfiguration -Options $Options -Name $Name -Description $Description
    $errors = Test-UpbConfigurationData -Data $config -Kind Configuration
    if ($errors.Count -gt 0) { Stop-UpbValidation ("The configuration is not valid and was not saved:" + [Environment]::NewLine + (($errors | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine)) }
    $full = ConvertTo-UpbFullPath $Path
    Write-UpbJsonFile -Path $full -InputObject $config
    return $full
}

function Get-UpbDefaultConfigurationPath {
    param([string]$Name)
    if (-not $Name) { $Name = 'Configuration' }
    return (Join-Path (Get-UpbConfigurationDirectory) ((Get-UpbSafeName $Name) + '.json'))
}

function Get-UpbSavedConfigurations {
    $dir = Get-UpbConfigurationDirectory
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $list = foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object LastWriteTime -Descending)) {
        $name = $f.BaseName; $op = ''; $valid = $true; $problem = ''
        try { $c = Import-UpbConfiguration -Path $f.FullName; if ($c.Name) { $name = $c.Name }; $op = $c.Operation }
        catch { $valid = $false; $problem = (Get-UpbInnerException $_).Message }
        [pscustomobject]@{ Path = $f.FullName; Name = $name; Operation = $op; Modified = $f.LastWriteTime; Valid = $valid; Problem = $problem }
    }
    return @($list)
}

function Import-UpbRestoreMap {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = ConvertTo-UpbFullPath $Path
    $data = Read-UpbJsonFile -Path $full
    $errors = New-Object System.Collections.Generic.List[string]
    $mappings = $null
    if ($data -is [System.Collections.IDictionary]) {
        foreach ($k in $data.Keys) { if ('SchemaVersion', 'Mappings', 'Description' -notcontains $k) { $errors.Add("Unknown property '$k'.") } }
        $sv = 0
        if (-not [int]::TryParse([string]$data.SchemaVersion, [ref]$sv) -or $sv -lt 1 -or $sv -gt $script:UpbRestoreMapSchemaVersion) { $errors.Add("SchemaVersion must be $($script:UpbRestoreMapSchemaVersion).") }
        $mappings = $data.Mappings
    } else { $errors.Add('The restore map must be a JSON object with SchemaVersion and Mappings.') }
    if (-not $mappings -or @($mappings).Count -eq 0) { $errors.Add('Mappings is empty.') }
    else { Test-UpbRestoreMappingList $errors $mappings 'Mappings' }
    if ($errors.Count -gt 0) {
        Stop-UpbValidation ("The restore map '$full' is not valid:" + [Environment]::NewLine + (($errors | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine))
    }
    return @($mappings)
}

# Parameter combinations that are wrong no matter what the configuration says.
function Test-UpbParameterCombination {
    param([System.Collections.IDictionary]$Bound)
    $errors = New-Object System.Collections.Generic.List[string]
    $b = $Bound
    $op = $b['Operation']
    if ($b.ContainsKey('Date') -and -not $b.ContainsKey('DateFilter')) { $errors.Add('-Date needs -DateFilter On, After or Before.') }
    if (($b.ContainsKey('StartDate') -or $b.ContainsKey('EndDate')) -and -not $b.ContainsKey('DateFilter')) { $errors.Add('-StartDate and -EndDate need -DateFilter Range.') }
    if ($b.ContainsKey('DateFilter')) {
        $f = $b['DateFilter']
        if ($b.ContainsKey('Date') -and 'On', 'After', 'Before' -notcontains $f) { $errors.Add("-Date cannot be used with -DateFilter $f (only On, After or Before).") }
        if (($b.ContainsKey('StartDate') -or $b.ContainsKey('EndDate')) -and $f -ne 'Range') { $errors.Add("-StartDate/-EndDate cannot be used with -DateFilter $f (only Range).") }
        if ('On', 'After', 'Before' -contains $f -and -not $b.ContainsKey('Date') -and -not $b.ContainsKey('ConfigurationPath')) { $errors.Add("-DateFilter $f needs -Date.") }
        if ($f -eq 'Range' -and -not ($b.ContainsKey('StartDate') -and $b.ContainsKey('EndDate')) -and -not $b.ContainsKey('ConfigurationPath')) { $errors.Add('-DateFilter Range needs both -StartDate and -EndDate.') }
    }
    if ($b.ContainsKey('Folders') -and $b.ContainsKey('BackupScope') -and $b['BackupScope'] -ne 'SelectedFolders') {
        $errors.Add("-Folders can only be used with -BackupScope SelectedFolders (you chose $($b['BackupScope'])).")
    }
    if ($op -eq 'Backup') {
        foreach ($k in 'BackupPath', 'RestoreProfiles', 'RestoreMapPath', 'ConflictAction') {
            if ($b.ContainsKey($k)) { $errors.Add("-$k applies to restores and cannot be used with -Operation Backup.") }
        }
    }
    if ($op -eq 'Restore') {
        foreach ($k in 'Profiles', 'BackupScope', 'Folders', 'DateFilter', 'Date', 'StartDate', 'EndDate', 'DateField', 'IncludeSystemProfiles') {
            if ($b.ContainsKey($k)) {
                $hint = ''
                if ($k -eq 'Profiles') { $hint = ' Use -RestoreProfiles to choose profiles from the backup set.' }
                $errors.Add("-$k applies to backups and cannot be used with -Operation Restore.$hint")
            }
        }
        if ($b.ContainsKey('RestoreMapPath') -and $b.ContainsKey('Destination')) { $errors.Add('Use either -Destination (one profile) or -RestoreMapPath (several profiles), not both.') }
        if ($b.ContainsKey('Destination') -and $b.ContainsKey('RestoreProfiles') -and @(Split-UpbListArgument $b['RestoreProfiles']).Count -gt 1) {
            $errors.Add('-Destination maps a single restored profile. For several profiles use -RestoreMapPath.')
        }
    }
    if ($b.ContainsKey('NonInteractive') -and $b['NonInteractive'] -and $b['Interface'] -eq 'WPF') {
        $errors.Add('-NonInteractive cannot be combined with -Interface WPF; a window is interactive.')
    }
    return , $errors.ToArray()
}

# "powershell -File" and scheduled tasks pass "a,b" as one string; split it unless it is an existing path.
function Split-UpbListArgument {
    param([string[]]$Values)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($v in @($Values)) {
        if ($null -eq $v) { continue }
        if ($v.Contains(',') -and -not (Test-Path -LiteralPath $v)) {
            foreach ($part in $v.Split(',')) { if ($part.Trim()) { $out.Add($part.Trim()) } }
        } elseif ($v.Trim()) { $out.Add($v.Trim()) }
    }
    return , $out.ToArray()
}

function Get-UpbEffectiveOptions {
    param([System.Collections.IDictionary]$Bound, [System.Collections.IDictionary]$AppSettings, [System.Collections.IDictionary]$Configuration)
    $o = New-UpbDefaultOptions
    $settingsLayer = @{}
    foreach ($k in $script:UpbSettingKeys) { if ($AppSettings -and $AppSettings.Contains($k)) { $settingsLayer[$k] = $AppSettings[$k] } }
    Set-UpbOptionLayer -Options $o -Layer $settingsLayer -Source 'Settings'
    if ($Configuration) { Set-UpbOptionLayer -Options $o -Layer $Configuration -Source 'Configuration' }
    $paramLayer = @{}
    foreach ($k in $script:UpbOptionKeys) {
        if ($Bound.ContainsKey($k)) {
            $v = $Bound[$k]
            if ($v -is [System.Management.Automation.SwitchParameter]) { $v = $v.IsPresent }
            if ('Profiles', 'Folders', 'RestoreProfiles' -contains $k) { $v = Split-UpbListArgument $v }
            $paramLayer[$k] = $v
        }
    }
    if ($paramLayer.ContainsKey('Folders') -and -not $paramLayer.ContainsKey('BackupScope')) { $paramLayer.BackupScope = 'SelectedFolders' }
    # A restore -Destination typed on the command line replaces mappings from the configuration.
    $restoreOperation = ($paramLayer['Operation'] -eq 'Restore') -or (-not $paramLayer.ContainsKey('Operation') -and $o.Operation -eq 'Restore')
    if ($restoreOperation -and $paramLayer.ContainsKey('Destination')) {
        $o.RestoreMappings = @(); $o.RestoreMapPath = $null
    }
    Set-UpbOptionLayer -Options $o -Layer $paramLayer -Source 'Parameter'
    if ($Configuration) { $o.ConfigurationPath = $Configuration['__Path'] }
    return $o
}

#endregion

#region Profiles and folder resolution

function Resolve-UpbSidName {
    param([string]$Sid)
    if (-not $Sid) { return $null }
    try { return (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value } catch { return $null }
}

function Get-UpbProfileAvailability {
    param([string]$Path, [bool]$Loaded)
    try {
        $entry = $null
        if ($Path) { $entry = [UpbIo]::GetInfo($Path) }
        if (-not $entry -or -not $entry.IsDirectory) { return [pscustomobject]@{ Available = $false; Text = 'Profile folder missing' } }
        [void][UpbIo]::List($Path)
        if ($Loaded) { return [pscustomobject]@{ Available = $true; Text = 'Available (user signed in - some files may be locked)' } }
        return [pscustomobject]@{ Available = $true; Text = 'Available' }
    } catch {
        $info = Get-UpbFailureInfo $_
        if ($info.Category -eq 'AccessDenied') { return [pscustomobject]@{ Available = $false; Text = 'Access denied - run elevated' } }
        return [pscustomobject]@{ Available = $false; Text = 'Unavailable: ' + $info.Message }
    }
}

function New-UpbProfileObject {
    param([string]$AccountName, [string]$Sid, [string]$Path, [bool]$Loaded, [bool]$IsSystem, [bool]$AdHoc)
    $availability = Get-UpbProfileAvailability -Path $Path -Loaded $Loaded
    $userName = $AccountName
    if ($userName -match '\\') { $userName = $userName.Substring($userName.LastIndexOf('\') + 1) }
    return [pscustomobject]@{
        AccountName  = $AccountName
        UserName     = $userName
        Sid          = $Sid
        Path         = $Path
        Loaded       = $Loaded
        IsSystem     = $IsSystem
        AdHoc        = $AdHoc
        Available    = $availability.Available
        Availability = $availability.Text
    }
}

function Get-UpbUserProfiles {
    param([switch]$IncludeSystem)
    $raw = New-Object System.Collections.Generic.List[object]
    $cim = $null
    try { $cim = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop } catch { $cim = $null }
    if ($cim) {
        foreach ($p in $cim) { $raw.Add([pscustomobject]@{ Sid = $p.SID; Path = $p.LocalPath; Special = [bool]$p.Special; Loaded = [bool]$p.Loaded }) }
    } else {
        $listKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList')
        if ($listKey) {
            try {
                foreach ($sid in $listKey.GetSubKeyNames()) {
                    $k = $listKey.OpenSubKey($sid)
                    try {
                        $path = [Environment]::ExpandEnvironmentVariables([string]$k.GetValue('ProfileImagePath'))
                        $loaded = $null -ne ([Microsoft.Win32.Registry]::Users.OpenSubKey($sid))
                        $raw.Add([pscustomobject]@{ Sid = $sid; Path = $path; Special = $false; Loaded = $loaded })
                    } finally { if ($k) { $k.Close() } }
                }
            } finally { $listKey.Close() }
        }
    }
    $profiles = New-Object System.Collections.Generic.List[object]
    foreach ($e in $raw) {
        if (-not $e.Path) { continue }
        $sid = [string]$e.Sid
        $isSystem = $e.Special -or ('S-1-5-18', 'S-1-5-19', 'S-1-5-20' -contains $sid) -or
            ($sid -notmatch '^S-1-5-21-' -and $sid -notmatch '^S-1-12-1-') -or
            ($e.Path -match '\\(system32|ServiceProfiles)(\\|$)')
        if ($isSystem -and -not $IncludeSystem) { continue }
        $account = Resolve-UpbSidName $sid
        if (-not $account) { $account = Split-Path -Leaf $e.Path }
        $profiles.Add((New-UpbProfileObject -AccountName $account -Sid $sid -Path $e.Path.TrimEnd('\') -Loaded $e.Loaded -IsSystem $isSystem -AdHoc $false))
    }
    return @($profiles.ToArray() | Sort-Object AccountName)
}

function Find-UpbProfile {
    param([string]$Name, [object[]]$AllProfiles)
    $n = $Name.Trim().TrimEnd('\')
    foreach ($p in $AllProfiles) {
        if ($p.AccountName -ieq $n -or $p.UserName -ieq $n -or $p.Path -ieq $n -or (Split-Path -Leaf $p.Path) -ieq $n) { return $p }
    }
    return $null
}

# Resolves names or paths to profile objects. Unregistered existing folders become ad-hoc profiles.
function Resolve-UpbProfileSelection {
    param([string[]]$Names, [object[]]$AllProfiles)
    $result = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($name in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $p = Find-UpbProfile -Name $name -AllProfiles $AllProfiles
        if (-not $p -and ([IO.Path]::IsPathRooted($name)) -and (Test-Path -LiteralPath $name -PathType Container)) {
            $full = ConvertTo-UpbFullPath $name
            $p = Find-UpbProfile -Name $full -AllProfiles $AllProfiles
            if (-not $p) { $p = New-UpbProfileObject -AccountName (Split-Path -Leaf $full) -Sid $null -Path $full -Loaded $false -IsSystem $false -AdHoc $true }
        }
        if (-not $p) {
            $known = ($AllProfiles | ForEach-Object { $_.UserName }) -join ', '
            Stop-UpbValidation "Profile '$name' was not found. Use an account name or a profile folder path. Known profiles: $known"
        }
        $key = $p.Path.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $result.Add($p) }
    }
    return @($result.ToArray())
}

function Open-UpbProfileHive {
    param($UserProfile)
    if (-not $UserProfile.Sid) { return $null }
    $users = [Microsoft.Win32.Registry]::Users
    $key = $users.OpenSubKey($UserProfile.Sid)
    if ($key) { return @{ Root = $key; Mounted = $null } }
    if (-not (Test-UpbIsAdmin)) { return $null }
    $dat = Join-Path $UserProfile.Path 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $dat -PathType Leaf)) { return $null }
    $mount = 'UPB_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $null = & reg.exe load "HKU\$mount" "$dat" 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $key = $users.OpenSubKey($mount)
    if (-not $key) { $null = & reg.exe unload "HKU\$mount" 2>&1; return $null }
    return @{ Root = $key; Mounted = $mount }
}

function Close-UpbProfileHive {
    param($Hive)
    if (-not $Hive) { return }
    try { $Hive.Root.Close() } catch { }
    if ($Hive.Mounted) {
        $ok = $false
        for ($i = 0; $i -lt 6 -and -not $ok; $i++) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            $null = & reg.exe unload "HKU\$($Hive.Mounted)" 2>&1
            $ok = ($LASTEXITCODE -eq 0)
            if (-not $ok) { Start-Sleep -Milliseconds 400 }
        }
        if (-not $ok) { Write-UpbLog WARN "Could not unload the temporary registry hive HKU\$($Hive.Mounted). Unload it with 'reg unload HKU\$($Hive.Mounted)' before that user signs in." }
    }
}

function Read-UpbRegistryValues {
    param([Microsoft.Win32.RegistryKey]$Key)
    $values = @{}
    if (-not $Key) { return $values }
    foreach ($name in $Key.GetValueNames()) {
        $values[$name] = [string]$Key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    return $values
}

function Expand-UpbProfilePath {
    param([string]$Raw, $UserProfile, [hashtable]$UserEnvironment, [bool]$IsCurrentUser)
    if (-not $Raw) { return $null }
    $profilePath = $UserProfile.Path
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $n = $m.Groups[1].Value
        switch ($n.ToUpperInvariant()) {
            'USERPROFILE' { return $profilePath }
            'HOMEDRIVE' { if ($IsCurrentUser) { return $env:HOMEDRIVE } else { return $profilePath.Substring(0, 2) } }
            'HOMEPATH' { if ($IsCurrentUser) { return $env:HOMEPATH } else { return $profilePath.Substring(2) } }
            'USERNAME' { return (Split-Path -Leaf $profilePath) }
            default {
                if ($UserEnvironment -and $UserEnvironment.ContainsKey($n)) { return [Environment]::ExpandEnvironmentVariables($UserEnvironment[$n]) }
                if ($IsCurrentUser -or $n -match '^(SystemDrive|SystemRoot|windir|ProgramData|PUBLIC|ALLUSERSPROFILE)$') {
                    $v = [Environment]::GetEnvironmentVariable($n)
                    if ($v) { return $v }
                }
                return $m.Value
            }
        }
    }
    $expanded = [regex]::Replace($Raw, '%([^%]+)%', $evaluator)
    if ($expanded -match '%[^%]+%' -or -not [IO.Path]::IsPathRooted($expanded)) { return $null }
    try { return (ConvertTo-UpbFullPath $expanded) } catch { return $null }
}

# Returns an ordered map Name -> [pscustomobject]@{ Name; Path; Source; Exists; Redirected }.
# -ShellFoldersKey (e.g. 'HKEY_CURRENT_USER\Software\Test\User Shell Folders') overrides the hive lookup.
function Get-UpbKnownFolders {
    param([Parameter(Mandatory = $true)]$UserProfile, [string]$ShellFoldersKey, [switch]$NoCache)
    if (-not $script:UpbKnownFolderCache) { $script:UpbKnownFolderCache = @{} }
    $cacheKey = $UserProfile.Path.ToLowerInvariant() + '|' + $ShellFoldersKey
    if (-not $NoCache -and $script:UpbKnownFolderCache.ContainsKey($cacheKey)) { return $script:UpbKnownFolderCache[$cacheKey] }

    $shell = @{}; $userEnv = @{}; $registrySource = $null
    $isCurrent = $UserProfile.Sid -and ($UserProfile.Sid -eq (Get-UpbCurrentUserSid))
    if ($ShellFoldersKey) {
        $hiveName, $subPath = $ShellFoldersKey -split '\\', 2
        $root = switch -Regex ($hiveName) { '^(HKCU|HKEY_CURRENT_USER)$' { [Microsoft.Win32.Registry]::CurrentUser } '^(HKLM|HKEY_LOCAL_MACHINE)$' { [Microsoft.Win32.Registry]::LocalMachine } '^(HKU|HKEY_USERS)$' { [Microsoft.Win32.Registry]::Users } }
        if ($root) {
            $k = $root.OpenSubKey($subPath)
            if ($k) { try { $shell = Read-UpbRegistryValues $k; $registrySource = 'Registry (override)' } finally { $k.Close() } }
        }
    } else {
        $hive = $null
        try {
            $hive = Open-UpbProfileHive -UserProfile $UserProfile
            if ($hive) {
                $k = $hive.Root.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders')
                if ($k) { try { $shell = Read-UpbRegistryValues $k } finally { $k.Close() } }
                $k = $hive.Root.OpenSubKey('Environment')
                if ($k) { try { $userEnv = Read-UpbRegistryValues $k } finally { $k.Close() } }
                if ($hive.Mounted) { $registrySource = 'Registry (hive loaded)' } else { $registrySource = 'Registry' }
            }
        } catch {
            Write-UpbLog WARN "Could not read the folder locations of $($UserProfile.AccountName) from the registry: $((Get-UpbInnerException $_).Message)"
        } finally { Close-UpbProfileHive $hive }
    }

    $oneDriveRoots = @()
    try { $oneDriveRoots = @(Get-ChildItem -LiteralPath $UserProfile.Path -Directory -Force -Filter 'OneDrive*' -ErrorAction Stop | ForEach-Object { $_.FullName }) } catch { }

    $result = [ordered]@{}
    foreach ($name in $script:UpbKnownFolderDefs.Keys) {
        $def = $script:UpbKnownFolderDefs[$name]
        $path = $null; $source = $null
        foreach ($valueName in $def.Values) {
            if ($shell.ContainsKey($valueName) -and $shell[$valueName]) {
                $path = Expand-UpbProfilePath -Raw $shell[$valueName] -UserProfile $UserProfile -UserEnvironment $userEnv -IsCurrentUser $isCurrent
                if ($path) { $source = $registrySource; break }
            }
        }
        if (-not $path) {
            $default = Join-UpbPath $UserProfile.Path $def.Default
            $path = $default; $source = 'Default location'
            if (-not [UpbIo]::DirectoryExists($default) -and $name -notmatch 'AppData') {
                foreach ($od in $oneDriveRoots) {
                    $candidate = Join-UpbPath $od $def.Default
                    if ([UpbIo]::DirectoryExists($candidate)) { $path = $candidate; $source = 'OneDrive (detected)'; break }
                }
            }
        }
        $redirected = -not (Test-UpbPathUnder -Path $path -Root (Join-UpbPath $UserProfile.Path $def.Default))
        $result[$name] = [pscustomobject]@{ Name = $name; Path = $path; Source = $source; Exists = [UpbIo]::DirectoryExists($path); Redirected = $redirected }
    }
    $script:UpbKnownFolderCache[$cacheKey] = $result
    return $result
}

function Get-UpbBrowserSources {
    param($UserProfile, $KnownFolders)
    $sources = New-Object System.Collections.Generic.List[object]
    $local = $KnownFolders.LocalAppData.Path
    $roaming = $KnownFolders.RoamingAppData.Path
    $chromium = @(
        @{ Key = 'Browser-Edge'; Name = 'Microsoft Edge bookmarks'; Sub = 'Bookmarks\Edge'; Root = (Join-UpbPath $local 'Microsoft\Edge\User Data') },
        @{ Key = 'Browser-Chrome'; Name = 'Google Chrome bookmarks'; Sub = 'Bookmarks\Chrome'; Root = (Join-UpbPath $local 'Google\Chrome\User Data') }
    )
    foreach ($b in $chromium) {
        if (-not [UpbIo]::DirectoryExists($b.Root)) { continue }
        $include = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($d in [UpbIo]::List($b.Root)) {
                if (-not $d.IsDirectory -or -not ($d.Name -eq 'Default' -or $d.Name -like 'Profile *')) { continue }
                foreach ($f in 'Bookmarks', 'Bookmarks.bak') {
                    if ([UpbIo]::FileExists((Join-UpbPath $b.Root "$($d.Name)\$f"))) { $include.Add("$($d.Name)\$f") }
                }
            }
        } catch { Write-UpbLog WARN "Could not read $($b.Root): $((Get-UpbInnerException $_).Message)" }
        if ($include.Count -gt 0) {
            $sources.Add([pscustomobject]@{ Key = $b.Key; Kind = 'Browser'; Name = $b.Name; Path = $b.Root; ProfileRelativePath = (Get-UpbRelativePath $b.Root $UserProfile.Path); BackupSubPath = $b.Sub; IncludeFiles = $include.ToArray() })
        }
    }
    $ffRoot = Join-UpbPath $roaming 'Mozilla\Firefox'
    $ffProfiles = Join-UpbPath $ffRoot 'Profiles'
    if ([UpbIo]::DirectoryExists($ffProfiles)) {
        $include = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($d in [UpbIo]::List($ffProfiles)) {
                if (-not $d.IsDirectory) { continue }
                foreach ($f in 'places.sqlite', 'places.sqlite-wal', 'favicons.sqlite', 'favicons.sqlite-wal') {
                    if ([UpbIo]::FileExists((Join-UpbPath $ffProfiles "$($d.Name)\$f"))) { $include.Add("Profiles\$($d.Name)\$f") }
                }
                $bb = Join-UpbPath $ffProfiles "$($d.Name)\bookmarkbackups"
                if ([UpbIo]::DirectoryExists($bb)) {
                    foreach ($f in [UpbIo]::List($bb)) { if (-not $f.IsDirectory) { $include.Add("Profiles\$($d.Name)\bookmarkbackups\$($f.Name)") } }
                }
            }
        } catch { Write-UpbLog WARN "Could not read $ffProfiles`: $((Get-UpbInnerException $_).Message)" }
        if ($include.Count -gt 0) {
            $sources.Add([pscustomobject]@{ Key = 'Browser-Firefox'; Kind = 'Browser'; Name = 'Mozilla Firefox bookmarks'; Path = $ffRoot; ProfileRelativePath = (Get-UpbRelativePath $ffRoot $UserProfile.Path); BackupSubPath = 'Bookmarks\Firefox'; IncludeFiles = $include.ToArray() })
        }
    }
    return @($sources.ToArray())
}

function Get-UpbRunningBrowsers {
    $names = @{ msedge = 'Microsoft Edge'; chrome = 'Google Chrome'; firefox = 'Mozilla Firefox' }
    $running = foreach ($n in $names.Keys) { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { $names[$n] } }
    return @($running)
}

function New-UpbSource {
    param([string]$Key, [string]$Kind, [string]$Name, [string]$Path, $UserProfile, [string]$BackupSubPath, [string]$Note)
    return [pscustomobject]@{
        Key = $Key; Kind = $Kind; Name = $Name; Path = $Path
        ProfileRelativePath = (Get-UpbRelativePath $Path $UserProfile.Path)
        BackupSubPath = $BackupSubPath; IncludeFiles = $null; Note = $Note
    }
}

# Builds the list of source folders for one profile. Missing folders are reported in -Warnings.
function Get-UpbBackupSources {
    param([Parameter(Mandatory = $true)]$UserProfile, [string]$Scope = 'UserData', [string[]]$Folders, $KnownFolders, $Warnings)
    if (-not $KnownFolders) { $KnownFolders = Get-UpbKnownFolders -UserProfile $UserProfile }
    if (-not $Warnings) { $Warnings = New-Object System.Collections.Generic.List[string] }
    $sources = New-Object System.Collections.Generic.List[object]
    $usedSub = @{}
    $addKnown = {
        param([string]$FolderName, [string]$SubPath, [string]$Kind)
        $kf = $KnownFolders[$FolderName]
        if (-not $kf -or -not $kf.Exists) { $Warnings.Add("$($UserProfile.UserName): the $FolderName folder was not found ($($kf.Path)); skipped."); return }
        $note = $kf.Source
        $sources.Add((New-UpbSource -Key $FolderName -Kind $Kind -Name $FolderName -Path $kf.Path -UserProfile $UserProfile -BackupSubPath $SubPath -Note $note))
        $usedSub[$SubPath.ToLowerInvariant()] = $true
    }
    $wanted = @()
    switch ($Scope) {
        'Complete' {
            $sources.Add((New-UpbSource -Key 'Profile' -Kind 'Profile' -Name 'Complete profile' -Path $UserProfile.Path -UserProfile $UserProfile -BackupSubPath 'Profile'))
            foreach ($name in @('Documents', 'Pictures', 'Music', 'Videos', 'Contacts', 'Desktop', 'Downloads', 'Favorites')) {
                $kf = $KnownFolders[$name]
                if ($kf.Exists -and -not (Test-UpbPathUnder -Path $kf.Path -Root $UserProfile.Path)) {
                    & $addKnown $name ("Redirected\$name") 'Redirected'
                }
            }
            return @($sources.ToArray())
        }
        'UserData' { $wanted = $script:UpbUserDataFolders }
        'SelectedFolders' { $wanted = @($Folders) }
    }
    foreach ($w in $wanted) {
        if ([string]::IsNullOrWhiteSpace($w)) { continue }
        $std = $script:UpbUserDataFolders | Where-Object { $_ -ieq $w.Trim() } | Select-Object -First 1
        if ($std -eq 'Bookmarks') {
            & $addKnown 'Favorites' 'Favorites' 'KnownFolder'
            foreach ($b in (Get-UpbBrowserSources -UserProfile $UserProfile -KnownFolders $KnownFolders)) { $sources.Add($b) }
        } elseif ($std) {
            & $addKnown $std $std 'KnownFolder'
        } else {
            $custom = $w.Trim()
            try { $full = ConvertTo-UpbFullPath $custom -BasePath $UserProfile.Path } catch { $Warnings.Add("Custom folder '$custom' is not a valid path."); continue }
            if (-not [UpbIo]::DirectoryExists($full)) { $Warnings.Add("$($UserProfile.UserName): custom folder '$full' was not found; skipped."); continue }
            $leaf = Get-UpbSafeName (Split-Path -Leaf $full)
            if ($full.Length -le 3) { $leaf = 'Drive_' + $full.Substring(0, 1) }
            $sub = "Custom\$leaf"; $n = 2
            while ($usedSub.ContainsKey($sub.ToLowerInvariant())) { $sub = "Custom\$leaf`_$n"; $n++ }
            $usedSub[$sub.ToLowerInvariant()] = $true
            $sources.Add((New-UpbSource -Key 'Custom' -Kind 'Custom' -Name $full -Path $full -UserProfile $UserProfile -BackupSubPath $sub))
        }
    }
    # Drop exact duplicates (the same folder selected twice).
    $unique = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($s in $sources) {
        $k = $s.Path.ToLowerInvariant() + '|' + (@($s.IncludeFiles) -join '|')
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true; $unique.Add($s)
    }
    return @($unique.ToArray())
}

#endregion

#region Backup engine

function New-UpbResult {
    param([string]$OperationName)
    return [pscustomobject]@{
        Operation     = $OperationName
        Status        = 'NotStarted'
        ExitCode      = 2
        WhatIf        = $false
        BackupSetPath = $null
        ManifestPath  = $null
        LogPath       = $null
        FilesCopied   = 0
        BytesCopied   = [long]0
        FilesSkipped  = 0
        FilesFailed   = 0
        FilesFiltered = 0
        Elapsed       = [TimeSpan]::Zero
        Message       = ''
        Warnings      = (New-Object System.Collections.Generic.List[string])
        Details       = (New-Object System.Collections.Generic.List[string])
    }
}

# Walks one source folder and returns the files and directories that pass the filter.
function Get-UpbSourcePlan {
    param($Source, $Filter, [string[]]$ExcludePaths, [System.Collections.IDictionary]$State)
    $files = New-Object System.Collections.Generic.List[object]
    $dirInfo = @{}
    $skipped = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[object]
    $filtered = 0
    $useCreation = ($Filter.DateField -ne 'LastWriteTime')
    $lo = $Filter.Lower; $loInc = $Filter.LowerInclusive; $hi = $Filter.Upper; $hiInc = $Filter.UpperInclusive
    $hasLo = $null -ne $lo; $hasHi = $null -ne $hi
    $root = $Source.Path.TrimEnd('\')
    if ($root.Length -eq 2) { $root = $root }   # drive root such as "D:" (children become "D:\name")

    $consider = {
        param([string]$Rel, $Entry)
        if ($Entry.IsNameSurrogate) { $skipped.Add([ordered]@{ Path = $Rel; Reason = 'Symbolic link or junction (not followed)' }); return }
        if ($Entry.IsAppExecLink) { $skipped.Add([ordered]@{ Path = $Rel; Reason = 'App execution alias (recreated by Windows)' }); return }
        if ($Entry.IsOnlineOnly) { $skipped.Add([ordered]@{ Path = $Rel; Reason = 'Online-only cloud file (not downloaded; it is stored in the cloud)' }); return }
        if ($useCreation) { $t = $Entry.CreationTimeUtc.ToLocalTime() } else { $t = $Entry.LastWriteTimeUtc.ToLocalTime() }
        if ($hasLo) { if ($loInc) { if ($t -lt $lo) { $script:UpbPlanFiltered++; return } } elseif ($t -le $lo) { $script:UpbPlanFiltered++; return } }
        if ($hasHi) { if ($hiInc) { if ($t -gt $hi) { $script:UpbPlanFiltered++; return } } elseif ($t -ge $hi) { $script:UpbPlanFiltered++; return } }
        $files.Add([pscustomobject]@{ Rel = $Rel; Size = $Entry.Size; CreationTimeUtc = $Entry.CreationTimeUtc; LastWriteTimeUtc = $Entry.LastWriteTimeUtc; LastAccessTimeUtc = $Entry.LastAccessTimeUtc; Attributes = $Entry.Attributes })
    }
    $script:UpbPlanFiltered = 0

    if ($Source.IncludeFiles) {
        foreach ($rel in $Source.IncludeFiles) {
            $full = Join-UpbPath $root $rel
            try {
                $e = [UpbIo]::GetInfo($full)
                if ($e -and -not $e.IsDirectory) { & $consider $rel $e }
            } catch { $errors.Add([ordered]@{ Path = $rel; Message = (Get-UpbFailureInfo $_).Message }) }
        }
    } else {
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push('')
        $counter = 0
        while ($stack.Count -gt 0) {
            if ($State -and $State.CancelRequested) { break }
            $rel = $stack.Pop()
            if ($rel) { $abs = $root + '\' + $rel } else { $abs = $root }
            try { $entries = [UpbIo]::List($abs) }
            catch {
                $info = Get-UpbFailureInfo $_
                $shown = $rel; if (-not $shown) { $shown = '(folder root)' }
                $errors.Add([ordered]@{ Path = $shown; Message = 'Folder could not be read: ' + $info.Message })
                continue
            }
            foreach ($e in $entries) {
                if ($rel) { $childRel = $rel + '\' + $e.Name } else { $childRel = $e.Name }
                if ($e.IsDirectory) {
                    $childAbs = $root + '\' + $childRel
                    $excluded = $false
                    foreach ($x in $ExcludePaths) { if ($x -and (Test-UpbPathUnder -Path $childAbs -Root $x)) { $excluded = $true; break } }
                    if ($excluded) { $skipped.Add([ordered]@{ Path = $childRel; Reason = 'Excluded: the backup destination or another selected folder lives here' }); continue }
                    if ($e.IsNameSurrogate) { $skipped.Add([ordered]@{ Path = $childRel; Reason = 'Junction or symbolic link (not followed, prevents loops)' }); continue }
                    $dirInfo[$childRel] = $e
                    $stack.Push($childRel)
                } else {
                    & $consider $childRel $e
                }
            }
            $counter++
            if ($State -and ($counter % 200 -eq 0)) { $State.CurrentFile = $abs; Update-UpbProgress -State $State }
        }
    }
    $filtered = $script:UpbPlanFiltered

    # Directories: all of them for an unfiltered walk; otherwise only those that hold selected files.
    $dirs = New-Object System.Collections.Generic.List[object]
    $needed = @{}
    if ($Filter.Filter -eq 'All' -and -not $Source.IncludeFiles) {
        foreach ($k in $dirInfo.Keys) { $needed[$k] = $true }
    } else {
        foreach ($f in $files) {
            $p = $f.Rel
            while ($p.Contains('\')) { $p = $p.Substring(0, $p.LastIndexOf('\')); if ($needed.ContainsKey($p)) { break }; $needed[$p] = $true }
        }
    }
    foreach ($k in $needed.Keys) {
        $e = $dirInfo[$k]
        if ($e) { $dirs.Add([pscustomobject]@{ Rel = $k; CreationTimeUtc = $e.CreationTimeUtc; LastWriteTimeUtc = $e.LastWriteTimeUtc; LastAccessTimeUtc = $e.LastAccessTimeUtc }) }
        else { $dirs.Add([pscustomobject]@{ Rel = $k; CreationTimeUtc = $null; LastWriteTimeUtc = $null; LastAccessTimeUtc = $null }) }
    }
    $bytes = [long]0
    foreach ($f in $files) { $bytes += $f.Size }
    return [pscustomobject]@{
        Source = $Source; Files = $files; Directories = @($dirs.ToArray() | Sort-Object { $_.Rel.Split('\').Count }, Rel)
        Skipped = $skipped; Errors = $errors; Filtered = $filtered; Bytes = $bytes
    }
}

function Test-UpbBackupOptions {
    param([System.Collections.IDictionary]$Options)
    $errors = New-Object System.Collections.Generic.List[string]
    if (@($Options.Profiles).Count -eq 0) { $errors.Add('No source profiles were selected (-Profiles).') }
    if (-not $Options.Destination) { $errors.Add('No backup destination was given (-Destination).') }
    elseif (-not ([IO.Path]::IsPathRooted([string]$Options.Destination))) { $errors.Add("The destination '$($Options.Destination)' must be an absolute local, external-drive or UNC path.") }
    if ($Options.BackupScope -eq 'SelectedFolders' -and @($Options.Folders).Count -eq 0) { $errors.Add('The SelectedFolders scope needs at least one folder (-Folders).') }
    if ('Complete', 'UserData', 'SelectedFolders' -notcontains $Options.BackupScope) { $errors.Add("Unknown backup scope '$($Options.BackupScope)'.") }
    try { [void](Resolve-UpbDateFilter -Filter $Options.DateFilter -Date $Options.Date -StartDate $Options.StartDate -EndDate $Options.EndDate -DateField $Options.DateField) }
    catch { $errors.Add((Get-UpbInnerException $_).Message) }
    return , $errors.ToArray()
}

# Resolves everything a backup needs without copying anything. Used for previews and for the run itself.
function Get-UpbBackupPreparation {
    param([System.Collections.IDictionary]$Options, [object[]]$AllProfiles)
    $errors = Test-UpbBackupOptions $Options
    if ($errors.Count -gt 0) { Stop-UpbValidation ($errors -join [Environment]::NewLine) }
    $filter = $Options.ResolvedDateFilter
    if (-not $filter) { $filter = Resolve-UpbDateFilter -Filter $Options.DateFilter -Date $Options.Date -StartDate $Options.StartDate -EndDate $Options.EndDate -DateField $Options.DateField }
    if (-not $AllProfiles) { $AllProfiles = Get-UpbUserProfiles -IncludeSystem:([bool]$Options.IncludeSystemProfiles) }
    $selected = Resolve-UpbProfileSelection -Names $Options.Profiles -AllProfiles $AllProfiles
    $destination = ConvertTo-UpbFullPath ([string]$Options.Destination)
    $warnings = New-Object System.Collections.Generic.List[string]
    $isAdmin = Test-UpbIsAdmin
    $currentSid = Get-UpbCurrentUserSid
    foreach ($p in $selected) {
        if (-not $p.Available) {
            if ($p.Availability -like 'Access denied*') {
                Stop-UpbValidation "The profile folder '$($p.Path)' cannot be read. Run PowerShell as Administrator (elevated) to back up other users' profiles."
            }
            Stop-UpbValidation "The profile '$($p.AccountName)' cannot be backed up: $($p.Availability)."
        }
        if (-not $isAdmin -and $p.Sid -ne $currentSid -and -not $p.AdHoc) {
            $warnings.Add("Not elevated: files in $($p.UserName)'s profile that only that user can read will fail. Run as Administrator for a complete backup.")
        }
        if ($p.Loaded -and $p.Sid -ne $currentSid -and $Options.BackupScope -eq 'Complete') {
            $warnings.Add("$($p.UserName) is signed in: the registry hive (NTUSER.DAT) and files held open by their programs will be reported as locked.")
        }
    }
    $profilesPlan = New-Object System.Collections.Generic.List[object]
    $usedFolders = @{}
    foreach ($p in $selected) {
        $kf = Get-UpbKnownFolders -UserProfile $p
        $sources = Get-UpbBackupSources -UserProfile $p -Scope $Options.BackupScope -Folders $Options.Folders -KnownFolders $kf -Warnings $warnings
        $folderName = Get-UpbSafeName $p.UserName
        $n = 2
        while ($usedFolders.ContainsKey($folderName.ToLowerInvariant())) { $folderName = (Get-UpbSafeName $p.UserName) + "_$n"; $n++ }
        $usedFolders[$folderName.ToLowerInvariant()] = $true
        foreach ($s in $sources) {
            if (Test-UpbPathUnder -Path $destination -Root $s.Path) {
                $warnings.Add("The destination '$destination' is inside the source folder '$($s.Path)'. It will be excluded from the backup to prevent recursive copying.")
            }
        }
        $profilesPlan.Add([pscustomobject]@{ Profile = $p; BackupFolder = "Profiles\$folderName"; Sources = $sources; KnownFolders = $kf })
    }
    if ($Options.BackupScope -ne 'Complete' -and ($Options.BackupScope -eq 'UserData' -or (@($Options.Folders) -contains 'Bookmarks'))) {
        $running = Get-RunningBrowsersSafe
        if ($running.Count -gt 0) { $warnings.Add("Close $($running -join ', ') before backing up bookmarks: open browsers lock or keep rewriting their bookmark files.") }
    }
    if ($Options.BackupScope -eq 'Complete') {
        $warnings.Add('A complete-profile backup is a file backup. Credentials, EFS-encrypted files, DPAPI-protected secrets and many application settings are not portable to another account or computer.')
        $running = Get-RunningBrowsersSafe
        if ($running.Count -gt 0) { $warnings.Add("Running programs ($($running -join ', ')) keep some AppData files locked or changing; close them for a consistent copy.") }
    }
    return [pscustomobject]@{
        Filter = $filter; Profiles = $profilesPlan.ToArray(); Destination = $destination; Warnings = $warnings
    }
}

function Get-RunningBrowsersSafe {
    try { return @(Get-UpbRunningBrowsers) } catch { return @() }
}

function Format-UpbBackupPreview {
    param($Preparation, [System.Collections.IDictionary]$Options)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Destination : $($Preparation.Destination)")
    $near = Get-UpbNearestExistingDirectory $Preparation.Destination
    if ($near) {
        $free = [UpbIo]::GetFreeBytes($near)
        if ($free -ge 0) { $lines.Add("Free space  : $(Format-UpbBytes $free)") }
    } else { $lines.Add('Free space  : (destination not reachable)') }
    $lines.Add("Scope       : $($Options.BackupScope)")
    $lines.Add("Date filter : $($Preparation.Filter.Filter) on $($Preparation.Filter.DateField)")
    $lines.Add("              Lower bound: $(if ($null -ne $Preparation.Filter.Lower) { (Format-UpbLocalTime $Preparation.Filter.Lower) + $(if ($Preparation.Filter.LowerInclusive) { ' (inclusive)' } else { ' (exclusive)' }) } else { '(none)' })")
    $lines.Add("              Upper bound: $(if ($null -ne $Preparation.Filter.Upper) { (Format-UpbLocalTime $Preparation.Filter.Upper) + $(if ($Preparation.Filter.UpperInclusive) { ' (inclusive)' } else { ' (exclusive)' }) } else { '(none)' })")
    $lines.Add("              $($Preparation.Filter.Description)")
    foreach ($n in $Preparation.Filter.Notes) { $lines.Add("              Note: $n") }
    $lines.Add("Verify      : $(if ($Options.Verify) { 'SHA-256 hashes recorded and checked' } else { 'No' })")
    foreach ($pp in $Preparation.Profiles) {
        $lines.Add('')
        $lines.Add("Profile $($pp.Profile.AccountName)  [$($pp.Profile.Path)]  -> $($pp.BackupFolder)")
        if ($pp.Sources.Count -eq 0) { $lines.Add('    (no folders found)') }
        foreach ($s in $pp.Sources) {
            $extra = ''
            if ($s.Note -and $s.Note -ne 'Default location') { $extra = "  ($($s.Note))" }
            if ($s.IncludeFiles) { $extra += "  ($(@($s.IncludeFiles).Count) file(s))" }
            $lines.Add(('    {0,-18} {1}{2}' -f $s.Key, $s.Path, $extra))
        }
    }
    if ($Preparation.Warnings.Count -gt 0) {
        $lines.Add('')
        foreach ($w in $Preparation.Warnings) { $lines.Add("WARNING: $w") }
    }
    return $lines.ToArray()
}

function New-UpbBackupManifest {
    param($Preparation, [System.Collections.IDictionary]$Options, [string]$BackupId, [datetime]$Created)
    $profilesOut = New-Object System.Collections.Generic.List[object]
    foreach ($pp in $Preparation.Profiles) {
        $profilesOut.Add([ordered]@{
                AccountName  = $pp.Profile.AccountName
                UserName     = $pp.Profile.UserName
                Sid          = $pp.Profile.Sid
                ProfilePath  = $pp.Profile.Path
                BackupFolder = $pp.BackupFolder
                Status       = 'Pending'
                Folders      = @()
                Totals       = $null
            })
    }
    return [ordered]@{
        ManifestVersion = $script:UpbManifestVersion
        Tool            = 'UserProfileBackup'
        ToolVersion     = $script:UpbVersion
        BackupId        = $BackupId
        Created         = ConvertTo-UpbIsoLocal $Created
        CreatedUtc      = ConvertTo-UpbIsoUtc $Created
        Completed       = $null
        Status          = 'InProgress'
        SourceComputer  = $env:COMPUTERNAME
        CreatedBy       = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Elevated        = (Test-UpbIsAdmin)
        PowerShell      = $PSVersionTable.PSVersion.ToString()
        Scope           = $Options.BackupScope
        SelectedFolders = @($Options.Folders)
        SelectedProfiles = @($Preparation.Profiles | ForEach-Object { $_.Profile.AccountName })
        DateFilter      = ConvertTo-UpbManifestDateFilter $Preparation.Filter
        Verify          = [bool]$Options.Verify
        HashAlgorithm   = $(if ($Options.Verify) { 'SHA256' } else { $null })
        Totals          = $null
        Warnings        = @($Preparation.Warnings)
        Profiles        = $profilesOut.ToArray()
    }
}

function Write-UpbMarker {
    param([string]$SetPath, [string]$Name, [string]$Text)
    try { [IO.File]::WriteAllText((Join-Path $SetPath $Name), $Text + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false))) } catch { }
}

function Remove-UpbMarker {
    param([string]$SetPath, [string]$Name)
    $p = Join-Path $SetPath $Name
    if (Test-Path -LiteralPath $p) { try { [IO.File]::Delete($p) } catch { } }
}

function Invoke-UpbBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Options, [System.Collections.IDictionary]$State, [object[]]$AllProfiles)
    $ErrorActionPreference = 'Stop'
    if (-not $State) { $State = New-UpbState }
    $script:UpbState = $State
    $result = New-UpbResult 'Backup'
    $result.WhatIf = [bool]$Options.WhatIf
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $State.Started = Get-Date
    $State.Activity = 'Backing up user profiles'
    $State.Phase = 'Preparing'
    $setPath = $null
    $manifest = $null
    $manifestPath = $null
    try {
        $result.LogPath = Open-UpbLog -LogPath $Options.LogPath -OperationName 'Backup' -WhatIfMode:$result.WhatIf
        Write-UpbLog INFO "UserProfileBackup $($script:UpbVersion) backup started on $env:COMPUTERNAME by $([Security.Principal.WindowsIdentity]::GetCurrent().Name) (elevated: $(Test-UpbIsAdmin))."
        if ($result.WhatIf) { Write-UpbLog INFO 'WhatIf: nothing will be created or changed.' }
        $prep = Get-UpbBackupPreparation -Options $Options -AllProfiles $AllProfiles
        foreach ($line in (Format-UpbBackupPreview -Preparation $prep -Options $Options)) {
            if ($line -like 'WARNING: *') { Write-UpbLog WARN $line.Substring(9); $result.Warnings.Add($line.Substring(9)) } elseif ($line) { Write-UpbLog INFO $line }
        }
        $destination = $prep.Destination
        $created = Get-Date
        $setName = 'UPB_{0}_{1}' -f (Get-UpbSafeName $env:COMPUTERNAME), $created.ToString('yyyyMMdd-HHmmss')
        $setPath = Join-UpbPath $destination $setName
        $n = 2
        while (Test-Path -LiteralPath $setPath) { $setPath = Join-UpbPath $destination ("$setName`_$n"); $n++ }

        # Destination checks.
        if (-not $result.WhatIf) {
            if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
                try { [void][UpbIo]::CreateDirectory($destination) }
                catch { Stop-UpbValidation "The destination '$destination' does not exist and could not be created: $((Get-UpbFailureInfo $_).Message)" }
            }
            $problem = Test-UpbWriteAccess $destination
            if ($problem) { Stop-UpbValidation $problem }
        } else {
            $existing = Get-UpbNearestExistingDirectory $destination
            if (-not $existing) { Stop-UpbValidation "The destination '$destination' is not reachable (no existing parent folder or share)." }
        }

        # Scan.
        $State.Phase = 'Scanning'
        $exclude = @($destination, $setPath)
        $plans = New-Object System.Collections.Generic.List[object]
        foreach ($pp in $prep.Profiles) {
            $State.Profile = $pp.Profile.AccountName
            foreach ($s in $pp.Sources) {
                if ($State.CancelRequested) { break }
                $nested = @($pp.Sources | Where-Object { $_ -ne $s -and -not $_.IncludeFiles -and (Test-UpbPathUnder -Path $_.Path -Root $s.Path -Strict) } | ForEach-Object { $_.Path })
                Write-UpbLog INFO "Scanning $($pp.Profile.UserName)\$($s.Key): $($s.Path)"
                $plan = Get-UpbSourcePlan -Source $s -Filter $prep.Filter -ExcludePaths ($exclude + $nested) -State $State
                $plans.Add([pscustomobject]@{ ProfilePlan = $pp; Plan = $plan })
                $State.FilesTotal += $plan.Files.Count
                $State.BytesTotal += $plan.Bytes
                Write-UpbLog INFO ("  {0:N0} file(s), {1} selected; {2:N0} outside the date filter; {3:N0} skipped; {4:N0} unreadable." -f $plan.Files.Count, (Format-UpbBytes $plan.Bytes), $plan.Filtered, $plan.Skipped.Count, $plan.Errors.Count)
            }
        }
        if ($State.CancelRequested) {
            $result.Status = 'Canceled'; $result.ExitCode = 3; $result.Message = 'Canceled while scanning; nothing was copied.'
            Write-UpbLog WARN $result.Message
            return $result
        }
        Write-UpbLog INFO ("Total to copy: {0:N0} file(s), {1}." -f $State.FilesTotal, (Format-UpbBytes $State.BytesTotal))

        $free = [UpbIo]::GetFreeBytes((Get-UpbNearestExistingDirectory $destination))
        if ($free -ge 0) {
            $needed = [long]($State.BytesTotal * 1.02) + 50MB
            if ($free -lt $needed) {
                $msg = "Not enough free space at '$destination': $(Format-UpbBytes $free) free, about $(Format-UpbBytes $needed) needed."
                if ($result.WhatIf) { Write-UpbLog WARN $msg; $result.Warnings.Add($msg) } else { Stop-UpbValidation $msg }
            }
        } else { Write-UpbLog WARN "Free space at '$destination' could not be determined; continuing." }

        if ($result.WhatIf) {
            foreach ($entry in $plans) {
                $sample = @($entry.Plan.Files | Select-Object -First 10)
                foreach ($f in $sample) { Write-UpbLog INFO ("What if: copy {0}\{1}\{2}  ({3})" -f $entry.ProfilePlan.Profile.UserName, $entry.Plan.Source.BackupSubPath, $f.Rel, (Format-UpbBytes $f.Size)) }
                if ($entry.Plan.Files.Count -gt $sample.Count) { Write-UpbLog INFO ("What if: ... and {0:N0} more file(s) from {1}" -f ($entry.Plan.Files.Count - $sample.Count), $entry.Plan.Source.Path) }
                foreach ($e in $entry.Plan.Errors) { Write-UpbLog WARN "Unreadable: $($entry.Plan.Source.Path)\$($e.Path): $($e.Message)" }
            }
            $result.Status = 'WhatIf'; $result.ExitCode = 0; $result.BackupSetPath = $setPath
            $result.FilesCopied = 0; $result.Message = ("What if: would create {0} with {1:N0} file(s) ({2})." -f $setPath, $State.FilesTotal, (Format-UpbBytes $State.BytesTotal))
            Write-UpbLog OK $result.Message
            return $result
        }

        # Create the backup set.
        [void][UpbIo]::CreateDirectory($setPath)
        $result.BackupSetPath = $setPath
        Write-UpbMarker $setPath 'INCOMPLETE.txt' 'This backup set is incomplete: the backup is still running, or it stopped before finishing. See manifest.json.'
        $backupId = [guid]::NewGuid().ToString()
        $manifest = New-UpbBackupManifest -Preparation $prep -Options $Options -BackupId $backupId -Created $created
        $manifestPath = Join-Path $setPath 'manifest.json'
        $result.ManifestPath = $manifestPath
        Write-UpbJsonFile -Path $manifestPath -InputObject $manifest
        Write-UpbLog INFO "Backup set: $setPath (id $backupId)"

        # Copy.
        $State.Phase = 'Copying'
        $fatal = $null
        $profileIndex = @{}
        for ($i = 0; $i -lt $prep.Profiles.Count; $i++) { $profileIndex[$prep.Profiles[$i].BackupFolder] = $i }
        foreach ($entry in $plans) {
            if ($State.CancelRequested -or $fatal) { break }
            $pp = $entry.ProfilePlan; $plan = $entry.Plan; $src = $plan.Source
            $mp = $manifest.Profiles[$profileIndex[$pp.BackupFolder]]
            $mp.Status = 'InProgress'
            $State.Profile = $pp.Profile.AccountName
            $destRoot = Join-UpbPath (Join-UpbPath $setPath $pp.BackupFolder) $src.BackupSubPath
            Write-UpbLog INFO "Copying $($pp.Profile.UserName)\$($src.Key) from $($src.Path)"
            $filesOut = New-Object System.Collections.Generic.List[object]
            $errorsOut = New-Object System.Collections.Generic.List[object]
            foreach ($e in $plan.Errors) { $errorsOut.Add($e); Write-UpbLog ERROR "$($src.Path)\$($e.Path): $($e.Message)" }
            foreach ($s in $plan.Skipped) { Write-UpbLog DETAIL "Skipped $($src.Path)\$($s.Path): $($s.Reason)" }
            $result.FilesSkipped += $plan.Skipped.Count
            $result.FilesFailed += $plan.Errors.Count
            $result.FilesFiltered += $plan.Filtered
            $State.FilesFailed += $plan.Errors.Count
            $State.FilesSkipped += $plan.Skipped.Count
            try { [void][UpbIo]::CreateDirectory($destRoot) } catch { $fatal = Get-UpbFailureInfo $_; break }
            foreach ($d in $plan.Directories) { try { [void][UpbIo]::CreateDirectory((Join-UpbPath $destRoot $d.Rel)) } catch { $errorsOut.Add([ordered]@{ Path = $d.Rel; Message = 'Folder could not be created: ' + (Get-UpbFailureInfo $_).Message }) } }
            foreach ($f in $plan.Files) {
                if ($State.CancelRequested) { break }
                $srcFile = Join-UpbPath $src.Path $f.Rel
                $dstFile = Join-UpbPath $destRoot $f.Rel
                $State.CurrentFile = $srcFile
                try {
                    $parentCut = $dstFile.LastIndexOf('\')
                    [void][UpbIo]::CreateDirectory($dstFile.Substring(0, $parentCut))
                    [UpbIo]::CopyFile($srcFile, $dstFile, $false)
                    [UpbIo]::SetTimes($dstFile, $f.CreationTimeUtc, $f.LastAccessTimeUtc, $f.LastWriteTimeUtc, $false)
                    $record = [ordered]@{
                        Path = $f.Rel; Size = $f.Size
                        CreationTimeUtc = ConvertTo-UpbIsoUtc $f.CreationTimeUtc
                        LastWriteTimeUtc = ConvertTo-UpbIsoUtc $f.LastWriteTimeUtc
                        LastAccessTimeUtc = ConvertTo-UpbIsoUtc $f.LastAccessTimeUtc
                        Attributes = [int]($f.Attributes -band 0x1FFFF)
                    }
                    if ($Options.Verify) {
                        $h1 = [UpbIo]::HashFile($srcFile)
                        $h2 = [UpbIo]::HashFile($dstFile)
                        if ($h1 -ne $h2) { throw (New-Object UpbValidationException "Verification failed: the copy's SHA-256 ($h2) differs from the source ($h1). The source may have changed while it was copied.") }
                        $record.Sha256 = $h1
                    }
                    $filesOut.Add($record)
                    $result.FilesCopied++; $result.BytesCopied += $f.Size
                    $State.FilesCopied++
                    Write-UpbLog DETAIL "Copied $srcFile"
                } catch {
                    $info = Get-UpbFailureInfo $_ $f.Attributes
                    $errorsOut.Add([ordered]@{ Path = $f.Rel; Message = $info.Message; Code = $info.Code; Category = $info.Category })
                    $result.FilesFailed++; $State.FilesFailed++
                    Write-UpbLog ERROR "$srcFile`: $($info.Message)"
                    if ($info.Fatal) { $fatal = $info; break }
                }
                $State.FilesDone++
                $State.BytesDone += $f.Size
                Update-UpbProgress -State $State
            }
            # Folder timestamps last, deepest first, so file copies do not change them again.
            foreach ($d in ($plan.Directories | Sort-Object { $_.Rel.Split('\').Count } -Descending)) {
                if ($null -ne $d.CreationTimeUtc) { try { [UpbIo]::SetTimes((Join-UpbPath $destRoot $d.Rel), $d.CreationTimeUtc, $d.LastAccessTimeUtc, $d.LastWriteTimeUtc, $true) } catch { } }
            }
            $folderRecord = [ordered]@{
                Key = $src.Key; Kind = $src.Kind; Name = $src.Name
                OriginalPath = $src.Path; ProfileRelativePath = $src.ProfileRelativePath
                BackupSubPath = $src.BackupSubPath; ResolvedFrom = $src.Note
                FileCount = $filesOut.Count
                Directories = @($plan.Directories | ForEach-Object {
                        $o = [ordered]@{ Path = $_.Rel }
                        if ($null -ne $_.CreationTimeUtc) { $o.CreationTimeUtc = ConvertTo-UpbIsoUtc $_.CreationTimeUtc; $o.LastWriteTimeUtc = ConvertTo-UpbIsoUtc $_.LastWriteTimeUtc }
                        $o })
                Files = $filesOut.ToArray()
                Skipped = $plan.Skipped.ToArray()
                Errors = $errorsOut.ToArray()
                FilteredOut = $plan.Filtered
            }
            $mp.Folders = @($mp.Folders) + @($folderRecord)
        }
        Update-UpbProgress -State $State -Force

        # Finish.
        foreach ($mp in $manifest.Profiles) {
            $copied = 0; $bytes = [long]0; $skip = 0; $fail = 0
            foreach ($fr in $mp.Folders) { $copied += @($fr.Files).Count; foreach ($x in $fr.Files) { $bytes += $x.Size }; $skip += @($fr.Skipped).Count; $fail += @($fr.Errors).Count }
            $mp.Totals = [ordered]@{ FilesCopied = $copied; BytesCopied = $bytes; FilesSkipped = $skip; FilesFailed = $fail }
            if ($mp.Status -eq 'Pending') { $mp.Status = 'NotStarted' }
            elseif ($fail -gt 0) { $mp.Status = 'CompletedWithErrors' } else { $mp.Status = 'Completed' }
        }
        if ($fatal) {
            $result.Status = 'Failed'; $result.ExitCode = 2
            $result.Message = "Backup stopped: $($fatal.Message)"
        } elseif ($State.CancelRequested) {
            $result.Status = 'Canceled'; $result.ExitCode = 3
            $result.Message = 'Backup canceled. The backup set is incomplete and is marked as canceled.'
            foreach ($mp in $manifest.Profiles) { if ($mp.Status -ne 'NotStarted') { $mp.Status = 'Canceled' } }
        } elseif ($result.FilesFailed -gt 0) {
            $result.Status = 'CompletedWithErrors'; $result.ExitCode = 1
            $result.Message = 'Backup completed with errors: some files could not be copied.'
        } else {
            $result.Status = 'Completed'; $result.ExitCode = 0
            $result.Message = 'Backup completed successfully.'
        }
        $manifest.Status = $result.Status
        $manifest.Completed = ConvertTo-UpbIsoLocal (Get-Date)
        $manifest.Totals = [ordered]@{ FilesCopied = $result.FilesCopied; BytesCopied = $result.BytesCopied; FilesSkipped = $result.FilesSkipped; FilesFailed = $result.FilesFailed; FilesOutsideDateFilter = $result.FilesFiltered }
        Write-UpbJsonFile -Path $manifestPath -InputObject $manifest -Depth 14
        if ($result.Status -eq 'Canceled') {
            Write-UpbMarker $setPath 'CANCELED.txt' ("This backup was canceled at {0}. Only part of the selected data was copied; see manifest.json." -f (Get-Date))
        }
        if ($result.Status -ne 'Failed' -and $result.Status -ne 'Canceled') { Remove-UpbMarker $setPath 'INCOMPLETE.txt' }
        $result.Elapsed = $clock.Elapsed
        $summary = "{0} Copied {1:N0} file(s) ({2}); skipped {3:N0}; failed {4:N0}; outside date filter {5:N0}; elapsed {6}." -f $result.Message, $result.FilesCopied, (Format-UpbBytes $result.BytesCopied), $result.FilesSkipped, $result.FilesFailed, $result.FilesFiltered, (Format-UpbDuration $result.Elapsed)
        $level = 'OK'; if ($result.ExitCode -ne 0) { $level = 'WARN' }
        Write-UpbLog $level $summary
        Write-UpbLog INFO "Backup set: $setPath"
        $result.Message = $summary
    } catch {
        $inner = Get-UpbInnerException $_
        $result.ExitCode = 2
        if ($inner -is [UpbValidationException]) { $result.Status = 'ValidationFailed'; $result.Message = $inner.Message }
        else { $result.Status = 'Failed'; $result.Message = "Unexpected error: $($inner.Message)"; Write-UpbLog DETAIL $_.ScriptStackTrace }
        Write-UpbLog ERROR $result.Message
        if ($manifest -and $manifestPath) {
            try { $manifest.Status = 'Failed'; $manifest.Completed = ConvertTo-UpbIsoLocal (Get-Date); $manifest.Error = $result.Message; Write-UpbJsonFile -Path $manifestPath -InputObject $manifest -Depth 14 } catch { }
        }
    } finally {
        $result.Elapsed = $clock.Elapsed
        Complete-UpbProgress $State
        $State.Phase = 'Done'
        Close-UpbLog
        if ($setPath -and $result.LogPath -and (Test-Path -LiteralPath $setPath) -and (Test-Path -LiteralPath $result.LogPath)) {
            try { Copy-Item -LiteralPath $result.LogPath -Destination (Join-Path $setPath 'UserProfileBackup.log') -Force -WhatIf:$false } catch { }
        }
        $State.Result = $result
        $State.Completed = $true
    }
    return $result
}

#endregion

#region Manifest and restore engine

function Read-UpbBackupManifest {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = ConvertTo-UpbFullPath $Path
    if (Test-Path -LiteralPath $full -PathType Leaf) { $manifestPath = $full; $setPath = Split-Path -Parent $full }
    elseif (Test-Path -LiteralPath $full -PathType Container) { $setPath = $full; $manifestPath = Join-Path $full 'manifest.json' }
    else { Stop-UpbValidation "The backup set '$full' was not found." }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Stop-UpbValidation "'$setPath' is not a backup set: manifest.json is missing." }
    $m = Read-UpbJsonFile -Path $manifestPath -Raw
    $errors = New-Object System.Collections.Generic.List[string]
    if ($m.Tool -ne 'UserProfileBackup') { $errors.Add('The manifest was not written by UserProfileBackup.') }
    $mv = 0
    if (-not [int]::TryParse([string]$m.ManifestVersion, [ref]$mv)) { $errors.Add('ManifestVersion is missing.') }
    elseif ($mv -gt $script:UpbManifestVersion) { $errors.Add("ManifestVersion $mv is newer than this script supports ($($script:UpbManifestVersion)).") }
    if (-not $m.Profiles -or @($m.Profiles).Count -eq 0) { $errors.Add('The manifest lists no profiles.') }
    foreach ($p in @($m.Profiles)) {
        if (-not $p.AccountName) { $errors.Add('A profile entry has no AccountName.') }
        if (-not (Test-UpbSafeRelativePath $p.BackupFolder)) { $errors.Add("Profile '$($p.AccountName)' has an unsafe BackupFolder '$($p.BackupFolder)'.") }
        foreach ($f in @($p.Folders)) {
            if (-not $f) { continue }
            if (-not (Test-UpbSafeRelativePath $f.BackupSubPath)) { $errors.Add("Profile '$($p.AccountName)' has an unsafe folder path '$($f.BackupSubPath)'.") }
            if ($f.ProfileRelativePath -and -not (Test-UpbSafeRelativePath $f.ProfileRelativePath)) { $errors.Add("Profile '$($p.AccountName)' has an unsafe profile-relative path '$($f.ProfileRelativePath)'.") }
        }
    }
    if ($errors.Count -gt 0) { Stop-UpbValidation ("The manifest '$manifestPath' is not valid: " + ($errors -join ' ')) }
    return [pscustomobject]@{ Manifest = $m; SetPath = $setPath.TrimEnd('\'); ManifestPath = $manifestPath }
}

function Get-UpbManifestSummary {
    param($ManifestInfo)
    $m = $ManifestInfo.Manifest
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Backup set   : $($ManifestInfo.SetPath)")
    $lines.Add("Backup id    : $($m.BackupId)")
    $created = ConvertTo-UpbUtc $m.CreatedUtc
    if ($created) { $lines.Add("Created      : $(Format-UpbLocalTime $created.ToLocalTime()) on $($m.SourceComputer) by $($m.CreatedBy)") }
    $lines.Add("Status       : $($m.Status)")
    $lines.Add("Scope        : $($m.Scope)")
    if ($m.DateFilter) { $lines.Add("Date filter  : $($m.DateFilter.Description)") }
    $lines.Add("Verified     : $(if ($m.Verify) { 'Yes (SHA-256 recorded)' } else { 'No' })")
    if ($m.Totals) { $lines.Add(("Totals       : {0:N0} file(s), {1}; {2:N0} skipped; {3:N0} failed" -f $m.Totals.FilesCopied, (Format-UpbBytes $m.Totals.BytesCopied), $m.Totals.FilesSkipped, $m.Totals.FilesFailed)) }
    if ($m.Status -eq 'Canceled' -or $m.Status -eq 'InProgress' -or $m.Status -eq 'Failed') {
        $lines.Add("WARNING      : This backup set is incomplete ($($m.Status)). Only the files listed in the manifest can be restored.")
    }
    foreach ($p in @($m.Profiles)) {
        $count = 0; $bytes = [long]0
        foreach ($f in @($p.Folders)) { if ($f) { $count += @($f.Files).Count; foreach ($x in @($f.Files)) { if ($x) { $bytes += [long]$x.Size } } } }
        $lines.Add('')
        $lines.Add(("Profile {0}  ({1:N0} file(s), {2})  status {3}" -f $p.AccountName, $count, (Format-UpbBytes $bytes), $p.Status))
        $lines.Add("    Original path: $($p.ProfilePath)")
        foreach ($f in @($p.Folders)) { if ($f) { $lines.Add(('    {0,-18} {1}  ({2:N0} file(s))' -f $f.Key, $f.OriginalPath, @($f.Files).Count)) } }
    }
    return $lines.ToArray()
}

function Find-UpbManifestProfile {
    param($Manifest, [string]$Name)
    foreach ($p in @($Manifest.Profiles)) {
        $leaf = $p.BackupFolder.Substring($p.BackupFolder.LastIndexOf('\') + 1)
        if ($p.AccountName -ieq $Name -or $p.UserName -ieq $Name -or $leaf -ieq $Name -or ($p.ProfilePath -and $p.ProfilePath.TrimEnd('\') -ieq $Name.TrimEnd('\'))) { return $p }
    }
    return $null
}

function Find-UpbBackupSets {
    param([string]$Root)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    $sets = foreach ($d in (Get-ChildItem -LiteralPath $Root -Directory -Filter 'UPB_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $mp = Join-Path $d.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $mp)) { continue }
        $status = '?'; $profilesText = ''; $created = $d.CreationTime
        try {
            $raw = [IO.File]::ReadAllText($mp)
            $m = $raw | ConvertFrom-Json
            $status = $m.Status
            $profilesText = (@($m.Profiles) | ForEach-Object { $_.UserName }) -join ', '
            $c = ConvertTo-UpbUtc $m.CreatedUtc; if ($c) { $created = $c.ToLocalTime() }
        } catch { $status = 'Unreadable manifest' }
        [pscustomobject]@{ Path = $d.FullName; Name = $d.Name; Created = $created; Status = $status; Profiles = $profilesText }
    }
    return @($sets)
}

function Get-UpbRestoreMappingsFromOptions {
    param([System.Collections.IDictionary]$Options, [object[]]$SelectedEntries)
    if (@($Options.RestoreMappings).Count -gt 0) { return @($Options.RestoreMappings) }
    if ($Options.RestoreMapPath) { return @(Import-UpbRestoreMap -Path $Options.RestoreMapPath) }
    $destSource = $Options.Sources['Destination']
    if ($Options.Destination -and ($destSource -eq 'Parameter' -or $destSource -eq 'Configuration')) {
        if ($SelectedEntries.Count -ne 1) { Stop-UpbValidation '-Destination maps exactly one restored profile. Use -RestoreMapPath (or the interactive mapping step) for several profiles.' }
        return @(@{ Profile = $SelectedEntries[0].AccountName; Target = 'Folder'; Value = [string]$Options.Destination })
    }
    return @()
}

function Get-UpbRestoreFolderTarget {
    param($Folder, $Mapping, $SourceEntry, $TargetProfile, $TargetKnown)
    switch ($Mapping.Target) {
        'Original' { return $Folder.OriginalPath }
        'Folder' { return (Join-UpbPath (ConvertTo-UpbFullPath $Mapping.Value) $Folder.BackupSubPath) }
        'Profile' {
            if ($Folder.Kind -eq 'Profile') { return $TargetProfile.Path }
            if (('KnownFolder', 'Redirected' -contains $Folder.Kind) -and $TargetKnown.Contains([string]$Folder.Key)) { return $TargetKnown[[string]$Folder.Key].Path }
            if ($Folder.Kind -eq 'Browser') {
                switch ($Folder.Key) {
                    'Browser-Edge' { return (Join-UpbPath $TargetKnown.LocalAppData.Path 'Microsoft\Edge\User Data') }
                    'Browser-Chrome' { return (Join-UpbPath $TargetKnown.LocalAppData.Path 'Google\Chrome\User Data') }
                    'Browser-Firefox' { return (Join-UpbPath $TargetKnown.RoamingAppData.Path 'Mozilla\Firefox') }
                }
            }
            if ($Folder.ProfileRelativePath) { return (Join-UpbPath $TargetProfile.Path $Folder.ProfileRelativePath) }
            $leaf = $Folder.BackupSubPath.Substring($Folder.BackupSubPath.LastIndexOf('\') + 1)
            return (Join-UpbPath $TargetProfile.Path "Restored Folders\$leaf")
        }
    }
}

# Resolves the selected profiles and their destination mapping into concrete folder pairs.
function Get-UpbRestorePlan {
    param([System.Collections.IDictionary]$Options, $ManifestInfo, [object[]]$AllProfiles)
    $m = $ManifestInfo.Manifest
    $selected = New-Object System.Collections.Generic.List[object]
    if (@($Options.RestoreProfiles).Count -gt 0) {
        foreach ($n in $Options.RestoreProfiles) {
            $e = Find-UpbManifestProfile -Manifest $m -Name $n
            if (-not $e) { Stop-UpbValidation "Profile '$n' is not in this backup set. It contains: $((@($m.Profiles) | ForEach-Object { $_.AccountName }) -join ', ')." }
            if (-not $selected.Contains($e)) { $selected.Add($e) }
        }
    } elseif (@($m.Profiles).Count -eq 1) {
        $selected.Add(@($m.Profiles)[0])
    } else {
        Stop-UpbValidation "The backup set contains $(@($m.Profiles).Count) profiles ($((@($m.Profiles) | ForEach-Object { $_.AccountName }) -join ', ')). Choose which to restore with -RestoreProfiles."
    }
    $selectedArray = $selected.ToArray()
    $mappings = Get-UpbRestoreMappingsFromOptions -Options $Options -SelectedEntries $selectedArray
    foreach ($map in $mappings) {
        if (-not (Find-UpbManifestProfile -Manifest $m -Name $map.Profile)) { Stop-UpbValidation "The restore mapping names '$($map.Profile)', which is not in this backup set." }
    }
    if (-not $AllProfiles) { $AllProfiles = Get-UpbUserProfiles -IncludeSystem }
    $isAdmin = Test-UpbIsAdmin
    $currentSid = Get-UpbCurrentUserSid
    $sameComputer = ($m.SourceComputer -ieq $env:COMPUTERNAME)
    $plans = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $selectedArray) {
        $map = $null
        foreach ($candidate in $mappings) { if ((Find-UpbManifestProfile -Manifest $m -Name $candidate.Profile) -eq $entry) { $map = $candidate; break } }
        if (-not $map) { $map = @{ Profile = $entry.AccountName; Target = 'Original'; Value = $null } }
        $targetProfile = $null; $targetKnown = $null; $description = ''
        $differentAccount = $false
        switch ($map.Target) {
            'Original' {
                $description = "original location ($($entry.ProfilePath))"
                if (-not $sameComputer) { $differentAccount = $true; $notes.Add("$($entry.UserName): the backup came from $($m.SourceComputer); restoring to the original paths on $env:COMPUTERNAME.") }
                $origProfile = $null
                if ($entry.Sid) { $origProfile = $AllProfiles | Where-Object { $_.Sid -eq $entry.Sid } | Select-Object -First 1 }
                if (-not $origProfile -and $entry.ProfilePath -and -not (Test-Path -LiteralPath $entry.ProfilePath -PathType Container)) {
                    Stop-UpbValidation "The original profile folder '$($entry.ProfilePath)' of $($entry.AccountName) does not exist on this computer. Map it to another profile or to a custom folder."
                }
                $targetProfile = $origProfile
            }
            'Profile' {
                $targetProfile = Find-UpbProfile -Name ([string]$map.Value) -AllProfiles $AllProfiles
                if (-not $targetProfile -and [IO.Path]::IsPathRooted([string]$map.Value) -and (Test-Path -LiteralPath $map.Value -PathType Container)) {
                    $full = ConvertTo-UpbFullPath $map.Value
                    $targetProfile = New-UpbProfileObject -AccountName (Split-Path -Leaf $full) -Sid $null -Path $full -Loaded $false -IsSystem $false -AdHoc $true
                }
                if (-not $targetProfile) { Stop-UpbValidation "The target profile '$($map.Value)' for $($entry.AccountName) was not found on this computer. Accounts are never created automatically; create and sign in to the account first, or restore to a folder." }
                $targetKnown = Get-UpbKnownFolders -UserProfile $targetProfile
                $description = "profile $($targetProfile.AccountName) ($($targetProfile.Path))"
                if (($entry.Sid -and $targetProfile.Sid -ne $entry.Sid) -or (-not $entry.Sid -and $targetProfile.Path -ine $entry.ProfilePath) -or -not $sameComputer) { $differentAccount = $true }
                if ($targetProfile.Loaded -and $targetProfile.Sid -ne $currentSid) { $notes.Add("$($targetProfile.UserName) is signed in. Ask them to sign out (or close their programs) so restored files are not overwritten by running applications.") }
            }
            'Folder' {
                $description = "folder $(ConvertTo-UpbFullPath $map.Value)"
                $differentAccount = $true
            }
        }
        $folders = New-Object System.Collections.Generic.List[object]
        foreach ($f in @($entry.Folders)) {
            if (-not $f) { continue }
            $destRoot = Get-UpbRestoreFolderTarget -Folder $f -Mapping $map -SourceEntry $entry -TargetProfile $targetProfile -TargetKnown $targetKnown
            if (-not $destRoot -or -not [IO.Path]::IsPathRooted($destRoot)) { Stop-UpbValidation "No destination could be determined for $($entry.UserName)\$($f.Key)." }
            $destRoot = ConvertTo-UpbFullPath $destRoot
            $sourceRoot = Join-UpbPath (Join-UpbPath $ManifestInfo.SetPath $entry.BackupFolder) $f.BackupSubPath
            $bytes = [long]0; foreach ($x in @($f.Files)) { if ($x) { $bytes += [long]$x.Size } }
            $folders.Add([pscustomobject]@{ Folder = $f; SourceRoot = $sourceRoot; DestinationRoot = $destRoot; FileCount = @($f.Files).Count; Bytes = $bytes })
        }
        if ($differentAccount -and $map.Target -ne 'Folder') {
            if ($folders | Where-Object { $_.Folder.Kind -eq 'Browser' -and $_.Folder.Key -eq 'Browser-Firefox' }) {
                $notes.Add("$($entry.UserName): Firefox keeps bookmarks inside randomly named profile folders. In a different account, copy places.sqlite into that account's active Firefox profile folder instead (with Firefox closed).")
            }
        }
        $plans.Add([pscustomobject]@{ Entry = $entry; Mapping = $map; Description = $description; TargetProfile = $targetProfile; DifferentAccount = $differentAccount; Folders = $folders.ToArray() })
    }
    if ($plans | Where-Object { $_.DifferentAccount }) { foreach ($n in $script:UpbDifferentAccountNotes) { $notes.Add($n) } }
    if ($plans | Where-Object { $_.Folders | Where-Object { $_.Folder.Kind -eq 'Browser' } }) {
        $running = Get-RunningBrowsersSafe
        if ($running.Count -gt 0) { $notes.Add("Close $($running -join ', ') before restoring bookmarks: a running browser overwrites its bookmark file when it exits.") }
    }
    if (-not $isAdmin) {
        foreach ($p in $plans) {
            if ($p.TargetProfile -and $p.TargetProfile.Sid -and $p.TargetProfile.Sid -ne $currentSid) { $notes.Add("Not elevated: writing into $($p.TargetProfile.UserName)'s profile normally requires running PowerShell as Administrator.") }
        }
    }
    return [pscustomobject]@{ ManifestInfo = $ManifestInfo; Profiles = $plans.ToArray(); Notes = $notes.ToArray() }
}

function Format-UpbRestorePreview {
    param($Plan, [System.Collections.IDictionary]$Options)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Backup set     : $($Plan.ManifestInfo.SetPath)")
    $lines.Add("Conflict policy: $($Options.ConflictAction)$(switch ($Options.ConflictAction) { 'Skip' { ' (existing files are left unchanged)' } 'Overwrite' { ' (existing files are REPLACED)' } 'KeepBoth' { ' (restored copies get a unique name)' } })")
    $lines.Add("Verify         : $(if ($Options.Verify) { 'SHA-256 of every restored file is checked' } else { 'No' })")
    $lines.Add('Files that exist only at the destination are never deleted.')
    foreach ($p in $Plan.Profiles) {
        $lines.Add('')
        $lines.Add("$($p.Entry.AccountName)  ->  $($p.Description)")
        foreach ($f in $p.Folders) {
            $lines.Add(('    {0,-18} {1}' -f $f.Folder.Key, $f.SourceRoot))
            $lines.Add(('    {0,-18} -> {1}  ({2:N0} file(s), {3})' -f '', $f.DestinationRoot, $f.FileCount, (Format-UpbBytes $f.Bytes)))
        }
    }
    if ($Plan.Notes.Count -gt 0) {
        $lines.Add('')
        foreach ($n in ($Plan.Notes | Select-Object -Unique)) { $lines.Add("NOTE: $n") }
    }
    return $lines.ToArray()
}

function Test-UpbRestoreOptions {
    param([System.Collections.IDictionary]$Options)
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $Options.BackupPath) { $errors.Add('No backup set was given (-BackupPath).') }
    if ('Skip', 'Overwrite', 'KeepBoth' -notcontains $Options.ConflictAction) { $errors.Add("Unknown conflict action '$($Options.ConflictAction)'.") }
    if ($Options.ConflictAction -eq 'Overwrite' -and -not $Options.OverwriteConfirmed) {
        if ($Options.NonInteractive) {
            if ($Options.Sources['ConflictAction'] -ne 'Parameter') { $errors.Add("Overwrite came from the $($Options.Sources['ConflictAction'].ToLower()). Non-interactive runs replace files only when -ConflictAction Overwrite is typed on the command line.") }
        } else { $errors.Add('Overwriting existing files needs explicit confirmation.') }
    }
    return , $errors.ToArray()
}

function Invoke-UpbRestore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Options, [System.Collections.IDictionary]$State, [object[]]$AllProfiles)
    $ErrorActionPreference = 'Stop'
    if (-not $State) { $State = New-UpbState }
    $script:UpbState = $State
    $result = New-UpbResult 'Restore'
    $result.WhatIf = [bool]$Options.WhatIf
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $State.Started = Get-Date
    $State.Activity = 'Restoring user profiles'
    $State.Phase = 'Preparing'
    try {
        $result.LogPath = Open-UpbLog -LogPath $Options.LogPath -OperationName 'Restore' -WhatIfMode:$result.WhatIf
        Write-UpbLog INFO "UserProfileBackup $($script:UpbVersion) restore started on $env:COMPUTERNAME by $([Security.Principal.WindowsIdentity]::GetCurrent().Name) (elevated: $(Test-UpbIsAdmin))."
        if ($result.WhatIf) { Write-UpbLog INFO 'WhatIf: nothing will be created or changed.' }
        $errors = Test-UpbRestoreOptions $Options
        if ($errors.Count -gt 0) { Stop-UpbValidation ($errors -join [Environment]::NewLine) }
        $info = Read-UpbBackupManifest -Path $Options.BackupPath
        $result.BackupSetPath = $info.SetPath
        $plan = Get-UpbRestorePlan -Options $Options -ManifestInfo $info -AllProfiles $AllProfiles
        foreach ($line in (Get-UpbManifestSummary $info | Select-Object -First 8)) { if ($line) { Write-UpbLog INFO $line } }
        foreach ($line in (Format-UpbRestorePreview -Plan $plan -Options $Options)) {
            if ($line -like 'NOTE: *') { Write-UpbLog WARN $line.Substring(6); $result.Warnings.Add($line.Substring(6)) } elseif ($line) { Write-UpbLog INFO $line }
        }
        if ('Canceled', 'InProgress', 'Failed' -contains $info.Manifest.Status) {
            $w = "The backup set is incomplete ($($info.Manifest.Status)); only the files it lists will be restored."
            Write-UpbLog WARN $w; $result.Warnings.Add($w)
        }
        # Destination access and space.
        $totalBytes = [long]0; $totalFiles = 0
        foreach ($p in $plan.Profiles) { foreach ($f in $p.Folders) { $totalBytes += $f.Bytes; $totalFiles += $f.FileCount } }
        $State.FilesTotal = $totalFiles; $State.BytesTotal = $totalBytes
        $checked = @{}
        foreach ($p in $plan.Profiles) {
            foreach ($f in $p.Folders) {
                $existing = Get-UpbNearestExistingDirectory $f.DestinationRoot
                if (-not $existing) { Stop-UpbValidation "The destination '$($f.DestinationRoot)' is not reachable." }
                if ($checked.ContainsKey($existing.ToLowerInvariant())) { continue }
                $checked[$existing.ToLowerInvariant()] = $true
                if (-not $result.WhatIf) { $problem = Test-UpbWriteAccess $existing; if ($problem) { Stop-UpbValidation $problem } }
            }
        }
        $roots = @{}
        foreach ($k in $checked.Keys) { $q = [IO.Path]::GetPathRoot($k); if ($q) { $roots[$q] = $true } }
        foreach ($r in $roots.Keys) {
            $free = [UpbIo]::GetFreeBytes($r)
            if ($free -ge 0 -and $free -lt $totalBytes) {
                $msg = "Free space on $r ($(Format-UpbBytes $free)) may be less than the data to restore ($(Format-UpbBytes $totalBytes))."
                Write-UpbLog WARN $msg; $result.Warnings.Add($msg)
            }
        }

        $State.Phase = 'Restoring'
        $fatal = $null
        $counts = @{ New = 0; Skipped = 0; Overwritten = 0; Renamed = 0 }
        foreach ($p in $plan.Profiles) {
            if ($State.CancelRequested -or $fatal) { break }
            $State.Profile = $p.Entry.AccountName
            foreach ($pf in $p.Folders) {
                if ($State.CancelRequested -or $fatal) { break }
                $folder = $pf.Folder
                $destRoot = $pf.DestinationRoot
                Write-UpbLog INFO "Restoring $($p.Entry.UserName)\$($folder.Key) -> $destRoot"
                $whatIfShown = 0
                $createdDirs = New-Object System.Collections.Generic.List[object]
                if (-not $result.WhatIf) {
                    try { if ([UpbIo]::CreateDirectory($destRoot)) { } }
                    catch { $fatalInfo = Get-UpbFailureInfo $_; Write-UpbLog ERROR "Cannot create $destRoot`: $($fatalInfo.Message)"; $result.FilesFailed += $pf.FileCount; continue }
                    foreach ($d in @($folder.Directories)) {
                        if (-not $d -or -not (Test-UpbSafeRelativePath $d.Path)) { continue }
                        $dp = Join-UpbPath $destRoot $d.Path
                        try { if ([UpbIo]::CreateDirectory($dp) -and $d.CreationTimeUtc) { $createdDirs.Add([pscustomobject]@{ Path = $dp; Dir = $d }) } } catch { }
                    }
                }
                foreach ($file in @($folder.Files)) {
                    if (-not $file) { continue }
                    if ($State.CancelRequested) { break }
                    $rel = [string]$file.Path
                    $size = [long]$file.Size
                    $State.CurrentFile = $rel
                    if (-not (Test-UpbSafeRelativePath $rel)) {
                        $result.FilesFailed++; $State.FilesFailed++
                        Write-UpbLog ERROR "Rejected unsafe path in manifest: '$rel' (it would resolve outside the destination)."
                        $State.FilesDone++; $State.BytesDone += $size; continue
                    }
                    $src = Join-UpbPath $pf.SourceRoot $rel
                    $dst = Join-UpbPath $destRoot $rel
                    if (-not (Test-UpbPathUnder -Path $dst -Root $destRoot -Strict)) {
                        $result.FilesFailed++; $State.FilesFailed++
                        Write-UpbLog ERROR "Rejected path '$rel': it resolves outside '$destRoot'."
                        $State.FilesDone++; $State.BytesDone += $size; continue
                    }
                    try {
                        if (-not [UpbIo]::FileExists($src)) { throw (New-Object UpbValidationException "Missing from the backup set: $src") }
                        $action = 'New'
                        if ([UpbIo]::DirectoryExists($dst)) { throw (New-Object UpbValidationException "A folder with the same name already exists at $dst") }
                        if ([UpbIo]::FileExists($dst)) {
                            switch ($Options.ConflictAction) {
                                'Skip' { $action = 'Skip' }
                                'Overwrite' { $action = 'Overwrite' }
                                'KeepBoth' { $action = 'Rename'; $dst = Get-UpbUniqueFilePath $dst }
                            }
                        }
                        if ($result.WhatIf) {
                            if ($whatIfShown -lt 10) {
                                $verb = switch ($action) { 'New' { 'restore' } 'Skip' { 'skip (exists)' } 'Overwrite' { 'OVERWRITE' } 'Rename' { 'restore as' } }
                                Write-UpbLog INFO "What if: $verb $dst"
                                $whatIfShown++
                            }
                            switch ($action) { 'New' { $counts.New++ } 'Skip' { $counts.Skipped++ } 'Overwrite' { $counts.Overwritten++ } 'Rename' { $counts.Renamed++ } }
                            if ($action -eq 'Skip') { $result.FilesSkipped++ } else { $result.FilesCopied++; $result.BytesCopied += $size }
                        } elseif ($action -eq 'Skip') {
                            $counts.Skipped++; $result.FilesSkipped++; $State.FilesSkipped++
                            Write-UpbLog DETAIL "Skipped (exists): $dst"
                        } else {
                            $parent = $dst.Substring(0, $dst.LastIndexOf('\'))
                            [void][UpbIo]::CreateDirectory($parent)
                            if ($action -eq 'Overwrite') {
                                $attrs = [UpbIo]::GetAttributes($dst)
                                if ($attrs -ne [UpbIo]::InvalidAttributes -and ($attrs -band 0x7)) { [UpbIo]::SetAttributes($dst, 0x80) }
                                [UpbIo]::CopyFile($src, $dst, $true)
                            } else {
                                [UpbIo]::CopyFile($src, $dst, $false)
                            }
                            $c = ConvertTo-UpbUtc $file.CreationTimeUtc; $w = ConvertTo-UpbUtc $file.LastWriteTimeUtc; $a = ConvertTo-UpbUtc $file.LastAccessTimeUtc
                            if (-not $a) { $a = $w }
                            if ($c -and $w) { [UpbIo]::SetTimes($dst, $c, $a, $w, $false) }
                            if ($Options.Verify) {
                                $expected = [string]$file.Sha256
                                if (-not $expected) { $expected = [UpbIo]::HashFile($src) }
                                $actual = [UpbIo]::HashFile($dst)
                                if ($actual -ne $expected.ToUpperInvariant()) { throw (New-Object UpbValidationException "Verification failed for $dst`: SHA-256 $actual does not match the backup ($expected).") }
                            }
                            switch ($action) { 'New' { $counts.New++ } 'Overwrite' { $counts.Overwritten++ } 'Rename' { $counts.Renamed++ } }
                            $result.FilesCopied++; $result.BytesCopied += $size; $State.FilesCopied++
                            Write-UpbLog DETAIL "Restored ($action): $dst"
                        }
                    } catch {
                        $fi = Get-UpbFailureInfo $_ ([uint32]([int]$file.Attributes))
                        $result.FilesFailed++; $State.FilesFailed++
                        Write-UpbLog ERROR "$dst`: $($fi.Message)"
                        if ($fi.Fatal) { $fatal = $fi; break }
                    }
                    $State.FilesDone++; $State.BytesDone += $size
                    Update-UpbProgress -State $State
                }
                if ($result.WhatIf -and $pf.FileCount -gt 10) { Write-UpbLog INFO ("What if: ... {0:N0} more file(s) in this folder" -f ($pf.FileCount - 10)) }
                foreach ($cd in ($createdDirs.ToArray() | Sort-Object { $_.Path.Length } -Descending)) {
                    $c = ConvertTo-UpbUtc $cd.Dir.CreationTimeUtc; $w = ConvertTo-UpbUtc $cd.Dir.LastWriteTimeUtc
                    if ($c -and $w) { try { [UpbIo]::SetTimes($cd.Path, $c, $w, $w, $true) } catch { } }
                }
            }
        }
        Update-UpbProgress -State $State -Force
        $result.Elapsed = $clock.Elapsed
        if ($fatal) { $result.Status = 'Failed'; $result.ExitCode = 2; $head = "Restore stopped: $($fatal.Message)" }
        elseif ($State.CancelRequested) { $result.Status = 'Canceled'; $result.ExitCode = 3; $head = 'Restore canceled; the files restored so far were kept.' }
        elseif ($result.WhatIf) { $result.Status = 'WhatIf'; $result.ExitCode = 0; $head = 'What if: no files were changed.' }
        elseif ($result.FilesFailed -gt 0) { $result.Status = 'CompletedWithErrors'; $result.ExitCode = 1; $head = 'Restore completed with errors.' }
        else { $result.Status = 'Completed'; $result.ExitCode = 0; $head = 'Restore completed successfully.' }
        $result.Message = "{0} New {1:N0}, overwritten {2:N0}, kept both {3:N0}, skipped (existing) {4:N0}, failed {5:N0}; {6}; elapsed {7}." -f $head, $counts.New, $counts.Overwritten, $counts.Renamed, $counts.Skipped, $result.FilesFailed, (Format-UpbBytes $result.BytesCopied), (Format-UpbDuration $result.Elapsed)
        $level = 'OK'; if ($result.ExitCode -ne 0) { $level = 'WARN' }
        Write-UpbLog $level $result.Message
    } catch {
        $inner = Get-UpbInnerException $_
        $result.ExitCode = 2
        if ($inner -is [UpbValidationException]) { $result.Status = 'ValidationFailed'; $result.Message = $inner.Message }
        else { $result.Status = 'Failed'; $result.Message = "Unexpected error: $($inner.Message)"; Write-UpbLog DETAIL $_.ScriptStackTrace }
        Write-UpbLog ERROR $result.Message
    } finally {
        $result.Elapsed = $clock.Elapsed
        Complete-UpbProgress $State
        $State.Phase = 'Done'
        Close-UpbLog
        $State.Result = $result
        $State.Completed = $true
    }
    return $result
}

#endregion

#region Console interface - primitives

function Test-UpbConsoleAvailable {
    try { return (-not [Console]::IsInputRedirected) -and [Environment]::UserInteractive } catch { return $false }
}

function Clear-UpbScreen { try { Clear-Host } catch { Write-Host '' } }

# Every interactive key press goes through here (tests replace this function with scripted keys).
function Read-UpbKey { return [Console]::ReadKey($true) }

function Get-UpbConsoleWidth { try { return [Math]::Max(60, [Console]::WindowWidth) } catch { return 100 } }
function Get-UpbConsoleHeight { try { return [Math]::Max(15, [Console]::WindowHeight) } catch { return 30 } }

function Limit-UpbText {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text) { return '' }
    if ($Max -lt 8) { $Max = 8 }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 3) + '...'
}

function Write-UpbScreenHeader {
    param([string]$Title, [string[]]$Lines)
    Clear-UpbScreen
    $w = (Get-UpbConsoleWidth) - 1
    Write-Host ('=' * $w) -ForegroundColor DarkCyan
    Write-Host (Limit-UpbText (" UserProfileBackup $($script:UpbVersion)  |  $Title") $w) -ForegroundColor Cyan
    if ($script:UpbConsoleSession -and $script:UpbConsoleSession.ConfigName) {
        Write-Host (Limit-UpbText (" Configuration: $($script:UpbConsoleSession.ConfigName)") $w) -ForegroundColor DarkGray
    }
    Write-Host ('=' * $w) -ForegroundColor DarkCyan
    foreach ($l in $Lines) {
        $color = 'Gray'
        if ($l -like 'WARNING*' -or $l -like 'NOTE*') { $color = 'Yellow' } elseif ($l -like 'ERROR*') { $color = 'Red' }
        Write-Host (Limit-UpbText (' ' + $l) $w) -ForegroundColor $color
    }
    if ($Lines -and @($Lines).Count -gt 0) { Write-Host '' }
}

function Get-UpbNextSelectable {
    param([object[]]$Items, [int]$From, [int]$Step)
    $n = $Items.Count
    if ($n -eq 0) { return -1 }
    $i = $From
    for ($tries = 0; $tries -lt $n; $tries++) {
        $i = $i + $Step
        if ($i -lt 0) { $i = $n - 1 } elseif ($i -ge $n) { $i = 0 }
        if (-not $Items[$i].Disabled -and -not $Items[$i].Separator) { return $i }
    }
    return -1
}

# Single-choice menu. Items: @{ Key='1'; Label='...'; Value=...; Detail='...'; Disabled=$false; Separator=$false }
# A shortcut key selects immediately; arrows start highlighted navigation; Enter/Space activate; Esc returns $null.
function Show-UpbMenu {
    param([string]$Title, [object[]]$Items, [string[]]$Header, [string]$Footer)
    $highlight = -1
    $top = 0
    while ($true) {
        Write-UpbScreenHeader -Title $Title -Lines $Header
        $w = (Get-UpbConsoleWidth) - 1
        $headerLines = 4 + @($Header).Count + 1
        $room = [Math]::Max(5, (Get-UpbConsoleHeight) - $headerLines - 4)
        if ($highlight -ge 0) {
            if ($highlight -lt $top) { $top = $highlight }
            if ($highlight -ge $top + $room) { $top = $highlight - $room + 1 }
        }
        $end = [Math]::Min($Items.Count, $top + $room)
        if ($top -gt 0) { Write-Host '   ^ more above' -ForegroundColor DarkGray }
        for ($i = $top; $i -lt $end; $i++) {
            $it = $Items[$i]
            if ($it.Separator) { Write-Host (Limit-UpbText ('   ' + [string]$it.Label) $w) -ForegroundColor DarkCyan; continue }
            $key = '   '
            if ($it.Key) { $key = '[' + $it.Key + ']' }
            $text = '  {0} {1}' -f $key, $it.Label
            if ($it.Detail) { $text += '   ' + $it.Detail }
            $text = Limit-UpbText $text $w
            if ($i -eq $highlight) { Write-Host ($text.PadRight([Math]::Min($w, $text.Length + 2))) -ForegroundColor Black -BackgroundColor Cyan }
            elseif ($it.Disabled) { Write-Host $text -ForegroundColor DarkGray }
            else { Write-Host $text }
        }
        if ($end -lt $Items.Count) { Write-Host '   v more below' -ForegroundColor DarkGray }
        Write-Host ''
        if ($Footer) { Write-Host (Limit-UpbText (' ' + $Footer) $w) -ForegroundColor Yellow }
        Write-Host ' Press a key shown in [ ] to choose. Up/Down highlight, Enter/Space select, Esc back.' -ForegroundColor DarkGray
        $k = Read-UpbKey
        if ($k.Key -eq [ConsoleKey]::UpArrow) { if ($highlight -lt 0) { $highlight = Get-UpbNextSelectable $Items $Items.Count -1 } else { $highlight = Get-UpbNextSelectable $Items $highlight -1 } }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $highlight = Get-UpbNextSelectable $Items $highlight 1 }
        elseif ($k.Key -eq [ConsoleKey]::PageDown) { for ($j = 0; $j -lt $room; $j++) { $next = Get-UpbNextSelectable $Items $highlight 1; if ($next -le $highlight) { break }; $highlight = $next } }
        elseif ($k.Key -eq [ConsoleKey]::PageUp) { if ($highlight -lt 0) { $highlight = 0 }; for ($j = 0; $j -lt $room; $j++) { $prev = Get-UpbNextSelectable $Items $highlight -1; if ($prev -ge $highlight) { break }; $highlight = $prev } }
        elseif ($k.Key -eq [ConsoleKey]::Home) { $highlight = Get-UpbNextSelectable $Items -1 1 }
        elseif ($k.Key -eq [ConsoleKey]::End) { $highlight = Get-UpbNextSelectable $Items $Items.Count -1 }
        elseif ($k.Key -eq [ConsoleKey]::Escape) { return $null }
        elseif ($k.Key -eq [ConsoleKey]::Enter -or $k.Key -eq [ConsoleKey]::Spacebar) {
            if ($highlight -ge 0 -and -not $Items[$highlight].Disabled) { return $Items[$highlight].Value }
        } else {
            $ch = [string]$k.KeyChar
            if ($ch -and -not [char]::IsControl($k.KeyChar)) {
                foreach ($it in $Items) {
                    if ($it.Key -and -not $it.Disabled -and -not $it.Separator -and ([string]$it.Key -ieq $ch)) { return $it.Value }
                }
            }
        }
    }
}

# Multiple-choice list. Items are hashtables with Label, Detail, Value and Selected (updated in place).
# Returns @{ Action='Continue'; Selected=@(values) }, @{ Action=<extra action value> } or $null for Esc.
function Show-UpbChecklist {
    param([string]$Title, [System.Collections.IList]$Items, [string[]]$Header, [object[]]$Actions, [int]$MinSelected = 1, [string]$ContinueLabel = 'Continue', [string]$What = 'item')
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Items.Count; $i++) { $rows.Add(@{ Type = 'Item'; Index = $i }) }
    foreach ($a in @($Actions)) { if ($a) { $rows.Add(@{ Type = 'Action'; Action = $a }) } }
    $rows.Add(@{ Type = 'Continue' })
    $cursor = 0
    $top = 0
    $message = ''
    while ($true) {
        Write-UpbScreenHeader -Title $Title -Lines $Header
        $w = (Get-UpbConsoleWidth) - 1
        $room = [Math]::Max(5, (Get-UpbConsoleHeight) - (4 + @($Header).Count + 1) - 5)
        if ($cursor -lt $top) { $top = $cursor }
        if ($cursor -ge $top + $room) { $top = $cursor - $room + 1 }
        $end = [Math]::Min($rows.Count, $top + $room)
        if ($top -gt 0) { Write-Host '   ^ more above' -ForegroundColor DarkGray }
        for ($r = $top; $r -lt $end; $r++) {
            $row = $rows[$r]
            switch ($row.Type) {
                'Item' {
                    $it = $Items[$row.Index]
                    $box = '[ ]'; if ($it.Selected) { $box = '[x]' }
                    $num = '   '; if ($row.Index -lt 9) { $num = ('{0}.' -f ($row.Index + 1)).PadRight(3) }
                    $text = '  {0} {1} {2}' -f $box, $num, $it.Label
                    if ($it.Detail) { $text += '   ' + $it.Detail }
                    $color = 'Gray'; if ($it.Selected) { $color = 'White' }
                }
                'Action' { $text = '      [{0}] {1}' -f $row.Action.Key, $row.Action.Label; $color = 'Cyan' }
                'Continue' { $text = "      [C] $ContinueLabel  >>"; $color = 'Green' }
            }
            $text = Limit-UpbText $text $w
            if ($r -eq $cursor) { Write-Host $text -ForegroundColor Black -BackgroundColor Cyan } else { Write-Host $text -ForegroundColor $color }
        }
        if ($end -lt $rows.Count) { Write-Host '   v more below' -ForegroundColor DarkGray }
        $count = @($Items | Where-Object { $_.Selected }).Count
        Write-Host ''
        Write-Host (" {0} {1}(s) selected." -f $count, $What) -ForegroundColor Gray
        if ($message) { Write-Host (' ' + $message) -ForegroundColor Yellow; $message = '' }
        Write-Host ' Up/Down move, Space toggle (1-9 toggle directly), A all, N none, C continue, Esc back.' -ForegroundColor DarkGray
        $k = Read-UpbKey
        $activate = $false
        if ($k.Key -eq [ConsoleKey]::UpArrow) { $cursor = ($cursor - 1 + $rows.Count) % $rows.Count; continue }
        if ($k.Key -eq [ConsoleKey]::DownArrow) { $cursor = ($cursor + 1) % $rows.Count; continue }
        if ($k.Key -eq [ConsoleKey]::PageDown) { $cursor = [Math]::Min($rows.Count - 1, $cursor + $room); continue }
        if ($k.Key -eq [ConsoleKey]::PageUp) { $cursor = [Math]::Max(0, $cursor - $room); continue }
        if ($k.Key -eq [ConsoleKey]::Home) { $cursor = 0; continue }
        if ($k.Key -eq [ConsoleKey]::End) { $cursor = $rows.Count - 1; continue }
        if ($k.Key -eq [ConsoleKey]::Escape) { return $null }
        $target = $null
        if ($k.Key -eq [ConsoleKey]::Spacebar -or $k.Key -eq [ConsoleKey]::Enter) { $target = $rows[$cursor] }
        else {
            $ch = ([string]$k.KeyChar).ToUpperInvariant()
            if ($ch -match '^[1-9]$') { $idx = [int]$ch - 1; if ($idx -lt $Items.Count) { $target = $rows[$idx]; $cursor = $idx } }
            elseif ($ch -eq 'A') { foreach ($it in $Items) { $it.Selected = $true }; continue }
            elseif ($ch -eq 'N') { foreach ($it in $Items) { $it.Selected = $false }; continue }
            elseif ($ch -eq 'C') { $target = $rows[$rows.Count - 1] }
            else { foreach ($a in @($Actions)) { if ($a -and ([string]$a.Key).ToUpperInvariant() -eq $ch) { return @{ Action = $a.Value } } } }
        }
        if (-not $target) { continue }
        switch ($target.Type) {
            'Item' { $Items[$target.Index].Selected = -not $Items[$target.Index].Selected }
            'Action' { return @{ Action = $target.Action.Value } }
            'Continue' {
                $selectedValues = @($Items | Where-Object { $_.Selected } | ForEach-Object { $_.Value })
                if ($selectedValues.Count -lt $MinSelected) { $message = "Select at least $MinSelected $What(s) before continuing."; continue }
                return @{ Action = 'Continue'; Selected = $selectedValues }
            }
        }
    }
}

# Line editor: Enter accepts, Esc cancels (returns $null), Backspace edits. The default is prefilled.
function Read-UpbLine {
    param([string]$Prompt, [string]$Default = '', [switch]$AllowEmpty)
    Write-Host ''
    Write-Host (' ' + $Prompt) -ForegroundColor Cyan
    Write-Host ' Enter = accept, Esc = cancel' -ForegroundColor DarkGray
    while ($true) {
        Write-Host ' > ' -NoNewline
        $sb = New-Object Text.StringBuilder
        if ($Default) { [void]$sb.Append($Default); Write-Host $Default -NoNewline }
        while ($true) {
            $k = Read-UpbKey
            if ($k.Key -eq [ConsoleKey]::Enter) { Write-Host ''; break }
            if ($k.Key -eq [ConsoleKey]::Escape) { Write-Host ''; return $null }
            if ($k.Key -eq [ConsoleKey]::Backspace) {
                if ($sb.Length -gt 0) { $sb.Length = $sb.Length - 1; Write-Host "`b `b" -NoNewline }
                continue
            }
            if (-not [char]::IsControl($k.KeyChar)) { [void]$sb.Append($k.KeyChar); Write-Host $k.KeyChar -NoNewline }
        }
        $value = $sb.ToString().Trim()
        if ($value -or $AllowEmpty) { return $value }
        Write-Host ' A value is required (Esc to cancel).' -ForegroundColor Yellow
        $Default = ''
    }
}

function Read-UpbDateValue {
    param([string]$Prompt, [string]$Default)
    while ($true) {
        $text = Read-UpbLine -Prompt "$Prompt  (date: yyyy-MM-dd, or date and time: yyyy-MM-dd HH:mm)" -Default $Default
        if ($null -eq $text) { return $null }
        try {
            $d = ConvertTo-UpbDateInput $text
            $kind = 'date and time'; if ($d.DateOnly) { $kind = 'date only (whole day)' }
            Write-Host (" Understood as {0}: {1}" -f $kind, (Format-UpbLocalTime $d.Value)) -ForegroundColor Green
            return $text
        } catch {
            Write-Host (' ' + (Get-UpbInnerException $_).Message) -ForegroundColor Red
            $Default = $text
        }
    }
}

function Wait-UpbKey {
    param([string]$Text = 'Press any key to continue...')
    Write-Host ''
    Write-Host (' ' + $Text) -ForegroundColor DarkGray
    [void](Read-UpbKey)
}

function Show-UpbMessage {
    param([string]$Title, [string[]]$Lines)
    Write-UpbScreenHeader -Title $Title -Lines $Lines
    Wait-UpbKey
}

function Show-UpbPager {
    param([string]$Title, [string[]]$Lines, [string[]]$Header)
    $top = 0
    $Lines = @($Lines)
    while ($true) {
        Write-UpbScreenHeader -Title $Title -Lines $Header
        $w = (Get-UpbConsoleWidth) - 1
        $room = [Math]::Max(5, (Get-UpbConsoleHeight) - (4 + @($Header).Count + 1) - 3)
        $end = [Math]::Min($Lines.Count, $top + $room)
        for ($i = $top; $i -lt $end; $i++) {
            $l = $Lines[$i]; $color = 'Gray'
            if ($l -like 'WARNING*' -or $l -like 'NOTE*') { $color = 'Yellow' } elseif ($l -like 'ERROR*') { $color = 'Red' }
            Write-Host (Limit-UpbText (' ' + $l) $w) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host (" Lines {0}-{1} of {2}. Up/Down/PgUp/PgDn scroll, Esc or Enter to close." -f ([Math]::Min($top + 1, $Lines.Count)), $end, $Lines.Count) -ForegroundColor DarkGray
        $k = Read-UpbKey
        switch ($k.Key) {
            'UpArrow' { $top = [Math]::Max(0, $top - 1) }
            'DownArrow' { if ($end -lt $Lines.Count) { $top++ } }
            'PageUp' { $top = [Math]::Max(0, $top - $room) }
            'PageDown' { if ($end -lt $Lines.Count) { $top = [Math]::Min($Lines.Count - 1, $top + $room) } }
            'Home' { $top = 0 }
            'End' { $top = [Math]::Max(0, $Lines.Count - $room) }
            'Escape' { return }
            'Enter' { return }
            'Q' { return }
        }
    }
}

function Read-UpbConfirmWord {
    param([string]$Title, [string[]]$Lines, [string]$Word)
    Write-UpbScreenHeader -Title $Title -Lines $Lines
    $typed = Read-UpbLine -Prompt "Type $Word to confirm, or press Esc to cancel." -AllowEmpty
    return ($typed -ceq $Word)
}

function Show-UpbYesNo {
    param([string]$Title, [string[]]$Lines, [string]$YesLabel = 'Yes', [string]$NoLabel = 'No')
    $r = Show-UpbMenu -Title $Title -Header $Lines -Items @(
        @{ Key = 'Y'; Label = $YesLabel; Value = 'Y' },
        @{ Key = 'N'; Label = $NoLabel; Value = 'N' })
    return ($r -eq 'Y')
}

# Console folder browser (drives, then folders). Returns the chosen path or $null.
function Select-UpbConsoleFolder {
    param([string]$Title = 'Choose a folder', [string]$Start, [switch]$AllowNew)
    $current = $null
    if ($Start) { $existing = Get-UpbNearestExistingDirectory (ConvertTo-UpbFullPath $Start); if ($existing) { $current = $existing } }
    while ($true) {
        $items = New-Object System.Collections.Generic.List[object]
        if (-not $current) {
            $header = @('Choose a drive. Network shares can be typed with [P] (\\server\share\folder).')
            $n = 0
            foreach ($d in [IO.DriveInfo]::GetDrives()) {
                $label = $d.Name
                $detail = ''
                try { if ($d.IsReady) { $detail = '{0}  {1}  free {2}' -f $d.DriveType, $d.VolumeLabel, (Format-UpbBytes $d.AvailableFreeSpace) } else { $detail = "$($d.DriveType) (not ready)" } } catch { }
                $key = $null; if ($n -lt 9) { $key = [string]($n + 1) }
                $items.Add(@{ Key = $key; Label = $label; Detail = $detail; Value = 'D:' + $d.RootDirectory.FullName; Disabled = -not $d.IsReady })
                $n++
            }
        } else {
            $header = @("Current folder: $current")
            $items.Add(@{ Key = 'U'; Label = 'Use this folder'; Value = 'USE' })
            if ($AllowNew) { $items.Add(@{ Key = 'M'; Label = 'Make a new folder here'; Value = 'NEW' }) }
            $items.Add(@{ Key = 'P'; Label = 'Type a path'; Value = 'TYPE' })
            $items.Add(@{ Key = '0'; Label = '.. (up one level)'; Value = 'UP' })
            $items.Add(@{ Separator = $true; Label = 'Folders:' })
            $n = 0
            try {
                $children = [UpbIo]::List($current) | Where-Object { $_.IsDirectory -and -not $_.IsNameSurrogate } | Sort-Object Name
                foreach ($c in $children) {
                    $key = $null; if ($n -lt 9) { $key = [string]($n + 1) }
                    $items.Add(@{ Key = $key; Label = $c.Name; Value = 'D:' + (Join-UpbPath $current $c.Name) })
                    $n++
                }
                if ($n -eq 0) { $items.Add(@{ Separator = $true; Label = '  (no subfolders)' }) }
            } catch { $items.Add(@{ Separator = $true; Label = '  (cannot list: ' + (Get-UpbFailureInfo $_).Message + ')' }) }
        }
        if (-not $current) { $items.Add(@{ Key = 'P'; Label = 'Type a path'; Value = 'TYPE' }) }
        $choice = Show-UpbMenu -Title $Title -Header $header -Items $items.ToArray()
        if ($null -eq $choice) { if ($current) { $current = $null; continue } else { return $null } }
        switch -Regex ($choice) {
            '^D:(.*)$' { $current = $Matches[1].TrimEnd('\'); if ($current.Length -eq 2) { $current += '\' } }
            '^USE$' { return $current }
            '^UP$' {
                $parent = $null
                try { $parent = [IO.Directory]::GetParent($current) } catch { }
                if ($parent) { $current = $parent.FullName } else { $current = $null }
            }
            '^TYPE$' {
                $typed = Read-UpbLine -Prompt 'Folder path (local, external drive or \\server\share\folder):' -Default $current
                if ($typed) {
                    try { $full = ConvertTo-UpbFullPath $typed; if ([UpbIo]::DirectoryExists($full)) { $current = $full } else { return $full } }
                    catch { Show-UpbMessage -Title $Title -Lines @("ERROR: '$typed' is not a valid path.") }
                }
            }
            '^NEW$' {
                $name = Read-UpbLine -Prompt 'New folder name:'
                if ($name) {
                    try { $newPath = Join-UpbPath $current (Get-UpbSafeName $name); [void][UpbIo]::CreateDirectory($newPath); $current = $newPath }
                    catch { Show-UpbMessage -Title $Title -Lines @("ERROR: $((Get-UpbFailureInfo $_).Message)") }
                }
            }
        }
    }
}

#endregion

#region Console interface - running operations

function Show-UpbResultSummary {
    param($Result)
    $color = switch ($Result.ExitCode) { 0 { 'Green' } 1 { 'Yellow' } 3 { 'Yellow' } default { 'Red' } }
    Write-Host ''
    Write-Host ('-' * ((Get-UpbConsoleWidth) - 1)) -ForegroundColor DarkCyan
    Write-Host (" Result     : {0} (exit code {1})" -f $Result.Status, $Result.ExitCode) -ForegroundColor $color
    Write-Host (" Summary    : {0}" -f $Result.Message) -ForegroundColor $color
    if ($Result.Operation -eq 'Backup' -and $Result.BackupSetPath) { Write-Host " Backup set : $($Result.BackupSetPath)" }
    if ($Result.Operation -eq 'Restore' -and $Result.BackupSetPath) { Write-Host " From set   : $($Result.BackupSetPath)" }
    if ($Result.LogPath) { Write-Host " Log        : $($Result.LogPath)" }
    if ($Result.Warnings.Count -gt 0) { Write-Host (" Warnings   : {0} (see above and in the log)" -f $Result.Warnings.Count) -ForegroundColor Yellow }
    Write-Host ('-' * ((Get-UpbConsoleWidth) - 1)) -ForegroundColor DarkCyan
}

# Runs Backup or Restore in the console with progress and Esc/Ctrl+C cancellation.
function Invoke-UpbConsoleRun {
    param([System.Collections.IDictionary]$Options, [switch]$Interactive)
    $keys = Test-UpbConsoleAvailable
    $state = New-UpbState -ConsoleOutput -ConsoleProgress -ConsoleCancel:$keys
    $previous = $null
    if ($keys) { try { $previous = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } catch { $previous = $null } }
    if ($Interactive) {
        Clear-UpbScreen
        Write-Host (" UserProfileBackup - {0}{1}" -f $Options.Operation, $(if ($Options.WhatIf) { ' (preview, no changes)' } else { '' })) -ForegroundColor Cyan
        if ($keys) { Write-Host ' Press Esc or Ctrl+C to cancel between files.' -ForegroundColor DarkGray }
        Write-Host ''
    }
    try {
        if ($Options.Operation -eq 'Backup') { $result = Invoke-UpbBackup -Options $Options -State $state }
        else { $result = Invoke-UpbRestore -Options $Options -State $state }
    } finally {
        if ($null -ne $previous) { try { [Console]::TreatControlCAsInput = $previous } catch { } }
    }
    Show-UpbResultSummary $result
    if ($Interactive) { Wait-UpbKey }
    $script:UpbLastExitCode = $result.ExitCode
    return $result
}

#endregion

#region Console interface - backup wizard

function Get-UpbProfileChecklistItems {
    param([object[]]$AllProfiles, [string[]]$Selected)
    $items = New-Object System.Collections.Generic.List[object]
    $matched = @{}
    foreach ($p in $AllProfiles) {
        $isSel = $false
        foreach ($s in @($Selected)) { if ($s -and ($p.AccountName -ieq $s -or $p.UserName -ieq $s -or $p.Path -ieq $s.TrimEnd('\'))) { $isSel = $true; $matched[$s.ToLowerInvariant()] = $true } }
        $flag = ''; if ($p.IsSystem) { $flag = ' (system)' }
        $items.Add(@{ Label = ('{0,-28}' -f ($p.AccountName + $flag)); Detail = ('{0,-32} {1}' -f $p.Path, $p.Availability); Value = $p.AccountName; Selected = $isSel })
    }
    foreach ($s in @($Selected)) {
        if ($s -and -not $matched.ContainsKey($s.ToLowerInvariant())) { $items.Add(@{ Label = ('{0,-28}' -f $s); Detail = '(typed - resolved when the operation runs)'; Value = $s; Selected = $true }) }
    }
    return , $items
}

function Step-UpbConsoleProfiles {
    param([System.Collections.IDictionary]$O, [switch]$ConfigMode)
    $profiles = Get-UpbUserProfiles -IncludeSystem:([bool]$O.IncludeSystemProfiles)
    $items = Get-UpbProfileChecklistItems -AllProfiles $profiles -Selected $O.Profiles
    while ($true) {
        $sysLabel = 'Show system and service profiles'; if ($O.IncludeSystemProfiles) { $sysLabel = 'Hide system and service profiles' }
        $header = @('Step 1 - Select the profiles to back up.', 'System and service profiles are hidden unless you show them.')
        if (-not (Test-UpbIsAdmin)) { $header += 'WARNING: Not elevated. Other users'' files usually need "Run as administrator".' }
        $r = Show-UpbChecklist -Title 'Back up: profiles' -Items $items -Header $header -What 'profile' -Actions @(
            @{ Key = 'P'; Label = 'Add a profile by account name or folder path'; Value = 'Add' },
            @{ Key = 'S'; Label = $sysLabel; Value = 'System' },
            @{ Key = 'R'; Label = 'Refresh the profile list'; Value = 'Refresh' })
        if ($null -eq $r) { return 'back' }
        switch ($r.Action) {
            'Continue' { $O.Profiles = @($r.Selected); return 'next' }
            'Add' {
                $typed = Read-UpbLine -Prompt 'Account name (DOMAIN\user or user) or profile folder path:'
                if ($typed) {
                    if (-not $ConfigMode) {
                        try { [void](Resolve-UpbProfileSelection -Names @($typed) -AllProfiles $profiles) }
                        catch { Show-UpbMessage -Title 'Back up: profiles' -Lines @("ERROR: $((Get-UpbInnerException $_).Message)"); continue }
                    }
                    $items.Add(@{ Label = ('{0,-28}' -f $typed); Detail = '(added)'; Value = $typed; Selected = $true })
                }
            }
            { $_ -eq 'System' -or $_ -eq 'Refresh' } {
                if ($r.Action -eq 'System') { $O.IncludeSystemProfiles = -not $O.IncludeSystemProfiles }
                $current = @($items | Where-Object { $_.Selected } | ForEach-Object { $_.Value })
                $profiles = Get-UpbUserProfiles -IncludeSystem:([bool]$O.IncludeSystemProfiles)
                $items = Get-UpbProfileChecklistItems -AllProfiles $profiles -Selected $current
            }
        }
    }
}

function Step-UpbConsoleScope {
    param([System.Collections.IDictionary]$O)
    $r = Show-UpbMenu -Title 'Back up: scope' -Header @('Step 2 - What should be backed up?', "Current: $($O.BackupScope)") -Items @(
        @{ Key = '1'; Label = 'Complete profile'; Detail = 'every accessible file incl. hidden items and AppData (a file backup only)'; Value = 'Complete' },
        @{ Key = '2'; Label = 'User data'; Detail = 'Documents, Pictures, Music, Videos, Contacts, Desktop, Downloads, Bookmarks'; Value = 'UserData' },
        @{ Key = '3'; Label = 'Selected folders'; Detail = 'choose user data folders and add custom folders'; Value = 'SelectedFolders' })
    if ($null -eq $r) { return 'back' }
    $O.BackupScope = $r
    if ($r -eq 'Complete') {
        Show-UpbMessage -Title 'Back up: complete profile' -Lines @(
            'A complete-profile backup copies every file it can read inside the profile folder,',
            'including hidden files and AppData. It is a FILE backup:',
            '',
            ' - Account credentials and saved passwords (DPAPI) are not portable to another account or computer.',
            ' - EFS-encrypted files remain readable only by the original account''s certificate.',
            ' - Many application settings depend on the account, SID, or machine and may not work elsewhere.',
            ' - Files held open (NTUSER.DAT of a signed-in user, running programs) are reported as locked.')
    }
    return 'next'
}

function Step-UpbConsoleFolders {
    param([System.Collections.IDictionary]$O, [switch]$ConfigMode)
    $kf = $null
    $firstProfile = $null
    if (-not $ConfigMode -and @($O.Profiles).Count -gt 0) {
        try { $firstProfile = @(Resolve-UpbProfileSelection -Names @($O.Profiles)[0] -AllProfiles (Get-UpbUserProfiles -IncludeSystem))[0]; $kf = Get-UpbKnownFolders -UserProfile $firstProfile } catch { $kf = $null }
    }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($name in $script:UpbUserDataFolders) {
        $detail = ''
        if ($kf) {
            if ($name -eq 'Bookmarks') { $detail = 'Favorites + Edge, Chrome and Firefox bookmark files' }
            else { $k = $kf[$name]; $detail = $k.Path; if ($k.Source -and $k.Source -ne 'Default location' -and $k.Source -notlike 'Registry*' -or $k.Redirected) { $detail += "  ($($k.Source))" }; if (-not $k.Exists) { $detail += '  (not found)' } }
        } elseif ($name -eq 'Bookmarks') { $detail = 'Favorites + Edge, Chrome and Firefox bookmark files' }
        $sel = @($O.Folders | Where-Object { $_ -ieq $name }).Count -gt 0
        $items.Add(@{ Label = ('{0,-10}' -f $name); Detail = $detail; Value = $name; Selected = $sel })
    }
    foreach ($f in @($O.Folders)) {
        if ($script:UpbUserDataFolders -notcontains $f) { $items.Add(@{ Label = $f; Detail = '(custom)'; Value = $f; Selected = $true }) }
    }
    while ($true) {
        $header = @('Step 3 - Select folders. Custom folders can be absolute paths, or paths relative to each profile folder (e.g. Source\Repos).')
        if ($firstProfile) { $header += "Paths shown for $($firstProfile.UserName); each profile's own locations are resolved when the backup runs." }
        $header += 'Bookmarks: close Edge, Chrome and Firefox first - running browsers lock or keep rewriting these files.'
        $r = Show-UpbChecklist -Title 'Back up: folders' -Items $items -Header $header -What 'folder' -Actions @(
            @{ Key = 'F'; Label = 'Add a custom folder by typing its path'; Value = 'Type' },
            @{ Key = 'B'; Label = 'Browse for a custom folder'; Value = 'Browse' })
        if ($null -eq $r) { return 'back' }
        if ($r.Action -eq 'Continue') { $O.Folders = @($r.Selected); return 'next' }
        $path = $null
        if ($r.Action -eq 'Type') { $path = Read-UpbLine -Prompt 'Custom folder (absolute path, or relative to each profile folder):' }
        else { $path = Select-UpbConsoleFolder -Title 'Choose a custom folder' -Start $(if ($firstProfile) { $firstProfile.Path } else { $env:USERPROFILE }) }
        if ($path) {
            if ($firstProfile -and (Test-UpbPathUnder -Path $path -Root $firstProfile.Path) -and @($O.Profiles).Count -gt 1) {
                $rel = Get-UpbRelativePath $path $firstProfile.Path
                if ($rel -and (Show-UpbYesNo -Title 'Custom folder' -Lines @("'$path' is inside $($firstProfile.UserName)'s profile.", "Store it as '$rel' so the same folder is backed up from every selected profile?") -YesLabel "Yes, use '$rel' for each profile" -NoLabel 'No, keep the absolute path')) { $path = $rel }
            }
            $items.Add(@{ Label = $path; Detail = '(custom)'; Value = $path; Selected = $true })
        }
    }
}

function Step-UpbConsoleDate {
    param([System.Collections.IDictionary]$O)
    while ($true) {
        $desc = ''
        try { $desc = (Resolve-UpbDateFilter -Filter $O.DateFilter -Date $O.Date -StartDate $O.StartDate -EndDate $O.EndDate -DateField $O.DateField).Description } catch { $desc = 'ERROR: ' + (Get-UpbInnerException $_).Message }
        $header = @('Step 4 - Date filter (local time). Relative periods are evaluated when the backup starts.', "Current: $($O.DateFilter) on $($O.DateField)", $desc)
        $r = Show-UpbMenu -Title 'Back up: date filter' -Header $header -Items @(
            @{ Key = '1'; Label = 'All files'; Value = 'All' },
            @{ Key = '2'; Label = 'Created on a specific date'; Detail = 'the whole local calendar day'; Value = 'On' },
            @{ Key = '3'; Label = 'Created after a date or date/time'; Detail = 'date only: the day itself is excluded'; Value = 'After' },
            @{ Key = '4'; Label = 'Created before a date or date/time'; Detail = 'date only: the day itself is excluded'; Value = 'Before' },
            @{ Key = '5'; Label = 'Created during the current week'; Detail = 'from Monday 00:00'; Value = 'CurrentWeek' },
            @{ Key = '6'; Label = 'Created during the current month'; Detail = 'from the 1st at 00:00'; Value = 'CurrentMonth' },
            @{ Key = '7'; Label = 'Created within a date or date/time range'; Detail = 'endpoints included'; Value = 'Range' },
            @{ Separator = $true; Label = '' },
            @{ Key = 'T'; Label = "Timestamp used: $($O.DateField)"; Detail = 'press T to switch between CreationTime and LastWriteTime (modified)'; Value = 'Toggle' },
            @{ Key = 'C'; Label = 'Continue with the current filter'; Value = 'Keep' })
        if ($null -eq $r) { return 'back' }
        if ($r -eq 'Toggle') { if ($O.DateField -eq 'CreationTime') { $O.DateField = 'LastWriteTime' } else { $O.DateField = 'CreationTime' }; continue }
        if ($r -eq 'Keep') { if ($desc -like 'ERROR*') { continue }; return 'next' }
        $date = $null; $start = $null; $end = $null
        switch ($r) {
            { 'On', 'After', 'Before' -contains $_ } {
                $default = [string]$O.Date; if (-not $default) { $default = (Get-Date).ToString('yyyy-MM-dd') }
                $date = Read-UpbDateValue -Prompt "Date for '$r'" -Default $default
                if ($null -eq $date) { continue }
            }
            'Range' {
                $default = [string]$O.StartDate; if (-not $default) { $default = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd') }
                $start = Read-UpbDateValue -Prompt 'Range start' -Default $default
                if ($null -eq $start) { continue }
                $default = [string]$O.EndDate; if (-not $default) { $default = (Get-Date).ToString('yyyy-MM-dd') }
                $end = Read-UpbDateValue -Prompt 'Range end' -Default $default
                if ($null -eq $end) { continue }
            }
        }
        try {
            $f = Resolve-UpbDateFilter -Filter $r -Date $date -StartDate $start -EndDate $end -DateField $O.DateField
            $O.DateFilter = $r; $O.Date = $date; $O.StartDate = $start; $O.EndDate = $end
            $lines = @($f.Description, '', ('Lower bound: ' + $(if ($null -ne $f.Lower) { (Format-UpbLocalTime $f.Lower) + $(if ($f.LowerInclusive) { ' (included)' } else { ' (excluded)' }) } else { 'none' })),
                ('Upper bound: ' + $(if ($null -ne $f.Upper) { (Format-UpbLocalTime $f.Upper) + $(if ($f.UpperInclusive) { ' (included)' } else { ' (excluded)' }) } else { 'none' })))
            foreach ($n in $f.Notes) { $lines += "NOTE: $n" }
            Show-UpbMessage -Title 'Back up: date filter' -Lines $lines
            return 'next'
        } catch {
            Show-UpbMessage -Title 'Back up: date filter' -Lines @("ERROR: $((Get-UpbInnerException $_).Message)")
        }
    }
}

function Step-UpbConsoleDestination {
    param([System.Collections.IDictionary]$O, [switch]$ConfigMode)
    $message = $null
    while ($true) {
        $header = @('Step 5 - Where should the backup set be created? (local folder, external drive, or \\server\share\folder)')
        if ($O.Destination) {
            $header += "Current: $($O.Destination)"
            $near = Get-UpbNearestExistingDirectory ([string]$O.Destination)
            if ($near) { $free = [UpbIo]::GetFreeBytes($near); if ($free -ge 0) { $header += "Free space: $(Format-UpbBytes $free)" } }
            elseif (-not $ConfigMode) { $header += 'WARNING: this location is not reachable right now.' }
        } else { $header += 'Current: (not set)' }
        if ($message) { $header += $message; $message = $null }
        $items = @(
            @{ Key = '1'; Label = 'Type a destination path'; Value = 'Type' },
            @{ Key = '2'; Label = 'Browse drives and folders'; Value = 'Browse' })
        if ($O.Destination) { $items += @{ Key = 'C'; Label = 'Continue with the current destination'; Value = 'Keep' } }
        $r = Show-UpbMenu -Title 'Back up: destination' -Header $header -Items $items
        if ($null -eq $r) { return 'back' }
        $path = $null
        switch ($r) {
            'Keep' { return 'next' }
            'Type' { $path = Read-UpbLine -Prompt 'Destination folder:' -Default ([string]$O.Destination) }
            'Browse' { $path = Select-UpbConsoleFolder -Title 'Choose the backup destination' -Start ([string]$O.Destination) -AllowNew }
        }
        if (-not $path) { continue }
        try {
            $full = ConvertTo-UpbFullPath $path
            if (-not $ConfigMode -and -not (Get-UpbNearestExistingDirectory $full)) { $message = "ERROR: '$full' is not reachable."; continue }
            $O.Destination = $full
            return 'next'
        } catch { $message = "ERROR: '$path' is not a valid path." }
    }
}

function Step-UpbConsoleExtras {
    param([System.Collections.IDictionary]$O, [string]$Title, [string]$StepText)
    while ($true) {
        $log = $O.LogPath; if (-not $log) { $log = "(default: $(Get-UpbDefaultLogDirectory))" }
        $r = Show-UpbMenu -Title $Title -Header @($StepText) -Items @(
            @{ Key = 'V'; Label = "SHA-256 verification: $(if ($O.Verify) { 'On' } else { 'Off' })"; Detail = 'slower; records and checks a hash for every file'; Value = 'Verify' },
            @{ Key = 'L'; Label = "Log location: $log"; Value = 'Log' },
            @{ Key = 'C'; Label = 'Continue'; Value = 'Next' })
        if ($null -eq $r) { return 'back' }
        switch ($r) {
            'Verify' { $O.Verify = -not $O.Verify }
            'Log' {
                $v = Read-UpbLine -Prompt 'Log file (*.log) or folder. Leave empty for the default:' -Default ([string]$O.LogPath) -AllowEmpty
                if ($null -ne $v) { if ($v) { $O.LogPath = $v } else { $O.LogPath = $null } }
            }
            'Next' { return 'next' }
        }
    }
}

function Save-UpbConsoleConfiguration {
    param([System.Collections.IDictionary]$O, [string]$DefaultPath)
    $name = $O.Name
    if (-not $name) { $name = Read-UpbLine -Prompt 'Configuration name:' -Default ("{0} {1}" -f $O.Operation, (Get-Date -Format 'yyyy-MM-dd')) }
    if (-not $name) { return $null }
    $O.Name = $name
    if (-not $DefaultPath) { $DefaultPath = Get-UpbDefaultConfigurationPath $name }
    $path = Read-UpbLine -Prompt 'Save the configuration to:' -Default $DefaultPath
    if (-not $path) { return $null }
    try {
        $full = ConvertTo-UpbFullPath $path
        if ((Test-Path -LiteralPath $full) -and -not (Show-UpbYesNo -Title 'Save configuration' -Lines @("'$full' already exists.") -YesLabel 'Replace it' -NoLabel 'Cancel')) { return $null }
        $saved = Export-UpbConfiguration -Options $O -Path $full
        Show-UpbMessage -Title 'Save configuration' -Lines @("Saved: $saved", '', 'No passwords or other credentials are stored in configuration files.')
        return $saved
    } catch {
        Show-UpbMessage -Title 'Save configuration' -Lines @('ERROR: ' + (Get-UpbInnerException $_).Message)
        return $null
    }
}

function Step-UpbConsoleBackupReview {
    param([System.Collections.IDictionary]$O)
    $o2 = Copy-UpbOptions $O
    $o2.ResolvedDateFilter = $null
    $lines = @(); $ok = $true
    try {
        $prep = Get-UpbBackupPreparation -Options $o2
        $lines = @(Format-UpbBackupPreview -Preparation $prep -Options $o2)
        $O.ResolvedDateFilter = $prep.Filter
    } catch { $ok = $false; $lines = @('ERROR: ' + (Get-UpbInnerException $_).Message, '', 'Press Esc to go back and change the selection.') }
    while ($true) {
        $items = @()
        if ($ok) {
            $items += @{ Key = 'R'; Label = 'Run the backup now'; Value = 'Run' }
            $items += @{ Key = 'P'; Label = 'Preview only (WhatIf: list what would be copied, change nothing)'; Value = 'WhatIf' }
            $items += @{ Key = 'V'; Label = 'View the full summary'; Value = 'View' }
        }
        $items += @{ Key = 'S'; Label = 'Save these choices as a configuration profile'; Value = 'Save' }
        $shown = $lines
        $room = (Get-UpbConsoleHeight) - 14
        if ($lines.Count -gt $room) { $shown = @($lines | Select-Object -First $room) + @('... (press V to view everything)') }
        $r = Show-UpbMenu -Title 'Back up: review' -Header (@('Step 6 - Review. The date boundaries below were evaluated now and are used as shown.', '') + $shown) -Items $items
        switch ($r) {
            $null { $O.ResolvedDateFilter = $null; return 'back' }
            'View' { Show-UpbPager -Title 'Back up: review' -Lines $lines }
            'Save' { [void](Save-UpbConsoleConfiguration -O $O) }
            'Run' { return 'run' }
            'WhatIf' { return 'whatif' }
        }
    }
}

function Invoke-UpbConsoleBackupWizard {
    param([System.Collections.IDictionary]$Options, [switch]$ConfigMode, [string]$StartStep)
    $o = Copy-UpbOptions $Options
    $o.Operation = 'Backup'
    $steps = @('Profiles', 'Scope', 'Folders', 'Date', 'Destination', 'Extras')
    if (-not $ConfigMode) { $steps += 'Review' }
    $i = 0
    if ($StartStep) { $i = [Array]::IndexOf($steps, $StartStep); if ($i -lt 0) { $i = 0 } }
    $direction = 1
    while ($true) {
        if ($i -lt 0) { return $null }
        if ($i -ge $steps.Count) { return $o }
        $step = $steps[$i]
        if ($step -eq 'Folders' -and $o.BackupScope -ne 'SelectedFolders') { $i += $direction; continue }
        switch ($step) {
            'Profiles' { $r = Step-UpbConsoleProfiles -O $o -ConfigMode:$ConfigMode }
            'Scope' { $r = Step-UpbConsoleScope -O $o }
            'Folders' { $r = Step-UpbConsoleFolders -O $o -ConfigMode:$ConfigMode }
            'Date' { $r = Step-UpbConsoleDate -O $o }
            'Destination' { $r = Step-UpbConsoleDestination -O $o -ConfigMode:$ConfigMode }
            'Extras' { $r = Step-UpbConsoleExtras -O $o -Title 'Back up: options' -StepText 'Step 5b - Verification and logging.' }
            'Review' { $r = Step-UpbConsoleBackupReview -O $o }
        }
        if ($r -eq 'back') { $direction = -1; $i--; continue }
        if ($r -eq 'next') { $direction = 1; $i++; continue }
        if ($r -eq 'run' -or $r -eq 'whatif') {
            $run = Copy-UpbOptions $o
            $run.WhatIf = ($r -eq 'whatif')
            $run.ResolvedDateFilter = $o.ResolvedDateFilter
            [void](Invoke-UpbConsoleRun -Options $run -Interactive)
            if ($r -eq 'whatif') { continue }
            return $o
        }
    }
}

#endregion

#region Console interface - restore wizard

function Step-UpbConsoleBackupSet {
    param([System.Collections.IDictionary]$O, [switch]$ConfigMode, [ref]$ManifestInfo)
    $message = $null
    while ($true) {
        $roots = @()
        $appSettings = Get-UpbSettings -Quiet
        foreach ($c in @($appSettings.Destination, $O.Destination)) { if ($c -and ($roots -notcontains $c)) { $roots += $c } }
        if ($O.BackupPath) { $parent = Split-Path -Parent ([string]$O.BackupPath); if ($parent -and ($roots -notcontains $parent)) { $roots += $parent } }
        $sets = @(); foreach ($root in $roots) { $sets += @(Find-UpbBackupSets -Root $root) }
        $header = @('Step 1 - Choose the backup set to restore from.')
        if ($O.BackupPath) { $header += "Current: $($O.BackupPath)" }
        if ($message) { $header += $message; $message = $null }
        $items = New-Object System.Collections.Generic.List[object]
        $items.Add(@{ Key = 'P'; Label = 'Type the path of a backup set'; Value = 'Type' })
        $items.Add(@{ Key = 'B'; Label = 'Browse for a backup set folder'; Value = 'Browse' })
        if ($O.BackupPath) { $items.Add(@{ Key = 'C'; Label = 'Continue with the current backup set'; Value = 'Keep' }) }
        if ($ConfigMode) { $items.Add(@{ Key = 'L'; Label = 'Leave empty (choose the backup set each time the configuration runs)'; Value = 'Blank' }) }
        if ($sets.Count -gt 0) {
            $items.Add(@{ Separator = $true; Label = 'Backup sets found in the default locations:' })
            $n = 0
            foreach ($s in $sets) {
                $key = $null; if ($n -lt 9) { $key = [string]($n + 1) }
                $items.Add(@{ Key = $key; Label = ('{0}  {1}' -f $s.Created.ToString('yyyy-MM-dd HH:mm'), $s.Name); Detail = ('{0}  [{1}]' -f $s.Status, $s.Profiles); Value = 'Set:' + $s.Path })
                $n++
            }
        }
        $r = Show-UpbMenu -Title 'Restore: backup set' -Header $header -Items $items.ToArray()
        if ($null -eq $r) { return 'back' }
        $path = $null
        switch -Regex ($r) {
            '^Keep$' { $path = [string]$O.BackupPath }
            '^Blank$' { $O.BackupPath = $null; $ManifestInfo.Value = $null; return 'next' }
            '^Type$' { $path = Read-UpbLine -Prompt 'Backup set folder (or its manifest.json):' -Default ([string]$O.BackupPath) }
            '^Browse$' { $path = Select-UpbConsoleFolder -Title 'Choose a backup set folder (UPB_...)' -Start $(if ($O.BackupPath) { [string]$O.BackupPath } elseif ($roots) { $roots[0] } else { $null }) }
            '^Set:(.*)$' { $path = $Matches[1] }
        }
        if (-not $path) { continue }
        try {
            $info = Read-UpbBackupManifest -Path $path
            if ($O.BackupPath -ne $info.SetPath) { $O.RestoreProfiles = @() }
            $O.BackupPath = $info.SetPath
            $ManifestInfo.Value = $info
            return 'next'
        } catch {
            if ($ConfigMode -and (Show-UpbYesNo -Title 'Restore: backup set' -Lines @("ERROR: $((Get-UpbInnerException $_).Message)", '', 'The configuration can still store this path.') -YesLabel 'Store the path anyway' -NoLabel 'Choose again')) {
                $O.BackupPath = $path; $ManifestInfo.Value = $null; return 'next'
            }
            $message = 'ERROR: ' + (Get-UpbInnerException $_).Message
        }
    }
}

function Step-UpbConsoleInspect {
    param([System.Collections.IDictionary]$O, $ManifestInfo)
    if (-not $ManifestInfo) { return 'skip' }
    $summary = @(Get-UpbManifestSummary $ManifestInfo)
    while ($true) {
        $items = @(@{ Key = 'C'; Label = 'Continue'; Value = 'Next' }, @{ Key = 'V'; Label = 'View the whole manifest summary'; Value = 'View' })
        $n = 0
        foreach ($p in @($ManifestInfo.Manifest.Profiles)) {
            $n++; if ($n -gt 9) { break }
            $items += @{ Key = [string]$n; Label = "List the files backed up for $($p.AccountName)"; Value = "Files:$($n - 1)" }
        }
        $room = (Get-UpbConsoleHeight) - 12 - $items.Count
        $shown = $summary; if ($summary.Count -gt $room) { $shown = @($summary | Select-Object -First ([Math]::Max(3, $room))) + @('... (press V for everything)') }
        $r = Show-UpbMenu -Title 'Restore: inspect backup set' -Header (@('Step 2 - Manifest of the selected backup set.') + $shown) -Items $items
        if ($null -eq $r) { return 'back' }
        if ($r -eq 'Next') { return 'next' }
        if ($r -eq 'View') { Show-UpbPager -Title 'Restore: manifest' -Lines $summary; continue }
        if ($r -like 'Files:*') {
            $p = @($ManifestInfo.Manifest.Profiles)[[int]$r.Substring(6)]
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($f in @($p.Folders)) {
                if (-not $f) { continue }
                $lines.Add("[$($f.Key)]  $($f.OriginalPath)")
                foreach ($x in @($f.Files)) { if ($x) { $t = ConvertTo-UpbUtc $x.LastWriteTimeUtc; $lines.Add(('    {0}   {1,12}   {2}' -f $x.Path, (Format-UpbBytes $x.Size), $(if ($t) { Format-UpbLocalTime $t.ToLocalTime() }))) } }
                foreach ($e in @($f.Errors)) { if ($e) { $lines.Add("    ERROR $($e.Path): $($e.Message)") } }
            }
            if ($lines.Count -eq 0) { $lines.Add('(no files)') }
            Show-UpbPager -Title "Restore: files of $($p.AccountName)" -Lines $lines.ToArray()
        }
    }
}

function Step-UpbConsoleRestoreProfiles {
    param([System.Collections.IDictionary]$O, $ManifestInfo)
    if (-not $ManifestInfo) {
        $typed = Read-UpbLine -Prompt 'Profiles to restore (comma-separated account names; empty = decide when it runs):' -Default (@($O.RestoreProfiles) -join ', ') -AllowEmpty
        if ($null -eq $typed) { return 'back' }
        $O.RestoreProfiles = @($typed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        return 'next'
    }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($ManifestInfo.Manifest.Profiles)) {
        $count = 0; foreach ($f in @($p.Folders)) { if ($f) { $count += @($f.Files).Count } }
        $sel = (@($O.RestoreProfiles) | Where-Object { $_ -ieq $p.AccountName -or $_ -ieq $p.UserName }).Count -gt 0
        if (@($ManifestInfo.Manifest.Profiles).Count -eq 1) { $sel = $true }
        $items.Add(@{ Label = ('{0,-28}' -f $p.AccountName); Detail = ('{0:N0} file(s)   from {1}' -f $count, $p.ProfilePath); Value = $p.AccountName; Selected = $sel })
    }
    $r = Show-UpbChecklist -Title 'Restore: profiles' -Items $items -Header @('Step 3 - Select the backed-up profiles to restore.') -What 'profile'
    if ($null -eq $r) { return 'back' }
    $O.RestoreProfiles = @($r.Selected)
    return 'next'
}

function Get-UpbMappingText {
    param($Mapping)
    if (-not $Mapping) { return 'Original location' }
    switch ($Mapping.Target) {
        'Original' { return 'Original location' }
        'Profile' { return "Existing profile: $($Mapping.Value)" }
        'Folder' { return "Custom folder: $($Mapping.Value)" }
    }
}

function Step-UpbConsoleMapping {
    param([System.Collections.IDictionary]$O, $ManifestInfo)
    $names = @($O.RestoreProfiles)
    if ($names.Count -eq 0 -and $ManifestInfo -and @($ManifestInfo.Manifest.Profiles).Count -eq 1) { $names = @(@($ManifestInfo.Manifest.Profiles)[0].AccountName) }
    if ($names.Count -eq 0) { return 'skip' }
    # Start from a mapping file or -Destination when present.
    $map = @{}
    $existing = @()
    try {
        if (@($O.RestoreMappings).Count -gt 0) { $existing = @($O.RestoreMappings) }
        elseif ($O.RestoreMapPath) { $existing = @(Import-UpbRestoreMap -Path $O.RestoreMapPath) }
        elseif ($O.Destination -and ($O.Sources['Destination'] -eq 'Parameter' -or $O.Sources['Destination'] -eq 'Configuration') -and $names.Count -eq 1) { $existing = @(@{ Profile = $names[0]; Target = 'Folder'; Value = [string]$O.Destination }) }
    } catch { Show-UpbMessage -Title 'Restore: destinations' -Lines @('ERROR: ' + (Get-UpbInnerException $_).Message) }
    foreach ($n in $names) {
        $m = $existing | Where-Object { $_.Profile -ieq $n } | Select-Object -First 1
        if (-not $m -and $ManifestInfo) {
            $entry = Find-UpbManifestProfile -Manifest $ManifestInfo.Manifest -Name $n
            if ($entry) { $m = $existing | Where-Object { (Find-UpbManifestProfile -Manifest $ManifestInfo.Manifest -Name $_.Profile) -eq $entry } | Select-Object -First 1 }
        }
        if ($m) { $map[$n] = @{ Profile = $n; Target = $m.Target; Value = $m.Value } } else { $map[$n] = @{ Profile = $n; Target = 'Original'; Value = $null } }
    }
    $allProfiles = $null
    while ($true) {
        $items = New-Object System.Collections.Generic.List[object]
        $i = 0
        foreach ($n in $names) {
            $i++
            $key = $null; if ($i -le 9) { $key = [string]$i }
            $orig = ''
            if ($ManifestInfo) { $e = Find-UpbManifestProfile -Manifest $ManifestInfo.Manifest -Name $n; if ($e) { $orig = "  (originally $($e.ProfilePath))" } }
            $items.Add(@{ Key = $key; Label = ('{0,-24} -> {1}' -f $n, (Get-UpbMappingText $map[$n])); Detail = $orig; Value = "Edit:$n" })
        }
        $items.Add(@{ Separator = $true; Label = '' })
        $items.Add(@{ Key = 'C'; Label = 'Continue with these destinations'; Value = 'Next' })
        $r = Show-UpbMenu -Title 'Restore: destinations' -Header @('Step 4 - Choose a destination for each profile. Select a profile to change it.', 'Accounts are never created, and ownership and permissions are never changed.') -Items $items.ToArray()
        if ($null -eq $r) { return 'back' }
        if ($r -eq 'Next') {
            $O.RestoreMappings = @($names | ForEach-Object { $m = $map[$_]; $h = [ordered]@{ Profile = $m.Profile; Target = $m.Target }; if ($m.Target -ne 'Original') { $h.Value = $m.Value }; $h })
            $O.RestoreMapPath = $null
            return 'next'
        }
        $name = $r.Substring(5)
        $choice = Show-UpbMenu -Title "Restore: destination for $name" -Header @("Current: $(Get-UpbMappingText $map[$name])") -Items @(
            @{ Key = '1'; Label = 'Original location'; Detail = 'the folders recorded in the manifest'; Value = 'Original' },
            @{ Key = '2'; Label = 'Another existing user profile on this computer'; Detail = 'folders are resolved for that user'; Value = 'Profile' },
            @{ Key = '3'; Label = 'A custom folder'; Detail = 'each backed-up folder becomes a subfolder'; Value = 'Folder' })
        switch ($choice) {
            'Original' { $map[$name] = @{ Profile = $name; Target = 'Original'; Value = $null } }
            'Profile' {
                if (-not $allProfiles) { $allProfiles = Get-UpbUserProfiles }
                $pi = New-Object System.Collections.Generic.List[object]
                $k = 0
                foreach ($p in $allProfiles) { $k++; $key = $null; if ($k -le 9) { $key = [string]$k }; $pi.Add(@{ Key = $key; Label = ('{0,-28}' -f $p.AccountName); Detail = ('{0}  {1}' -f $p.Path, $p.Availability); Value = $p.AccountName }) }
                $pi.Add(@{ Key = 'P'; Label = 'Type an account name or profile path'; Value = '__type' })
                $target = Show-UpbMenu -Title "Restore $name into which profile?" -Header @('Restoring into another account copies files only. See the notes on the review screen.') -Items $pi.ToArray()
                if ($target -eq '__type') { $target = Read-UpbLine -Prompt 'Account name or profile folder:' }
                if ($target) { $map[$name] = @{ Profile = $name; Target = 'Profile'; Value = $target } }
            }
            'Folder' {
                $how = Show-UpbMenu -Title "Restore $name into a folder" -Items @(@{ Key = '1'; Label = 'Type a folder path'; Value = 'Type' }, @{ Key = '2'; Label = 'Browse'; Value = 'Browse' })
                $folder = $null
                if ($how -eq 'Type') { $folder = Read-UpbLine -Prompt 'Destination folder:' -Default ([string]$map[$name].Value) }
                elseif ($how -eq 'Browse') { $folder = Select-UpbConsoleFolder -Title "Destination folder for $name" -AllowNew }
                if ($folder) { try { $map[$name] = @{ Profile = $name; Target = 'Folder'; Value = (ConvertTo-UpbFullPath $folder) } } catch { Show-UpbMessage -Title 'Restore' -Lines @("ERROR: '$folder' is not a valid path.") } }
            }
        }
    }
}

function Step-UpbConsoleConflict {
    param([System.Collections.IDictionary]$O)
    $r = Show-UpbMenu -Title 'Restore: existing files' -Header @('Step 5 - What should happen when a file already exists at the destination?', "Current: $($O.ConflictAction)", 'Files that exist only at the destination are never deleted.') -Items @(
        @{ Key = '1'; Label = 'Skip'; Detail = 'leave existing files unchanged (default)'; Value = 'Skip' },
        @{ Key = '2'; Label = 'Overwrite'; Detail = 'replace existing files (asks for confirmation before running)'; Value = 'Overwrite' },
        @{ Key = '3'; Label = 'Keep both'; Detail = 'restore under a unique name such as "report (2).docx"'; Value = 'KeepBoth' })
    if ($null -eq $r) { return 'back' }
    $O.ConflictAction = $r
    $O.OverwriteConfirmed = $false
    return 'next'
}

function Step-UpbConsoleRestoreReview {
    param([System.Collections.IDictionary]$O, $ManifestInfo)
    $lines = @(); $ok = $true
    try {
        if (-not $ManifestInfo) { $ManifestInfo = Read-UpbBackupManifest -Path $O.BackupPath }
        $plan = Get-UpbRestorePlan -Options $O -ManifestInfo $ManifestInfo
        $lines = @(Format-UpbRestorePreview -Plan $plan -Options $O)
    } catch { $ok = $false; $lines = @('ERROR: ' + (Get-UpbInnerException $_).Message, '', 'Press Esc to go back and change the selection.') }
    while ($true) {
        $items = @()
        if ($ok) {
            $items += @{ Key = 'R'; Label = 'Run the restore now'; Value = 'Run' }
            $items += @{ Key = 'P'; Label = 'Preview only (WhatIf: show what would happen, change nothing)'; Value = 'WhatIf' }
            $items += @{ Key = 'V'; Label = 'View the full mapping and notes'; Value = 'View' }
        }
        $items += @{ Key = 'S'; Label = 'Save these choices as a configuration profile'; Value = 'Save' }
        $room = (Get-UpbConsoleHeight) - 14
        $shown = $lines; if ($lines.Count -gt $room) { $shown = @($lines | Select-Object -First $room) + @('... (press V to view everything)') }
        $r = Show-UpbMenu -Title 'Restore: review' -Header (@('Step 7 - Review every source -> destination mapping before anything is written.', '') + $shown) -Items $items
        switch ($r) {
            $null { return 'back' }
            'View' { Show-UpbPager -Title 'Restore: review' -Lines $lines }
            'Save' { [void](Save-UpbConsoleConfiguration -O $O) }
            'Run' {
                if ($O.ConflictAction -eq 'Overwrite' -and -not $O.OverwriteConfirmed) {
                    if (-not (Read-UpbConfirmWord -Title 'Confirm overwrite' -Lines @('Existing files at the destinations will be REPLACED by the backed-up versions.', 'This cannot be undone.') -Word 'OVERWRITE')) { continue }
                    $O.OverwriteConfirmed = $true
                }
                return 'run'
            }
            'WhatIf' { return 'whatif' }
        }
    }
}

function Invoke-UpbConsoleRestoreWizard {
    param([System.Collections.IDictionary]$Options, [switch]$ConfigMode, [string]$StartStep)
    $o = Copy-UpbOptions $Options
    $o.Operation = 'Restore'
    $manifestInfo = $null
    if ($o.BackupPath) { try { $manifestInfo = Read-UpbBackupManifest -Path $o.BackupPath } catch { $manifestInfo = $null } }
    $steps = @('BackupSet', 'Inspect', 'Profiles', 'Mapping', 'Conflict', 'Extras')
    if (-not $ConfigMode) { $steps += 'Review' }
    $i = 0
    if ($StartStep) { $i = [Array]::IndexOf($steps, $StartStep); if ($i -lt 0) { $i = 0 } }
    if ($StartStep -eq 'Review' -and -not $manifestInfo) { $i = 0 }
    $direction = 1
    while ($true) {
        if ($i -lt 0) { return $null }
        if ($i -ge $steps.Count) { return $o }
        switch ($steps[$i]) {
            'BackupSet' { $r = Step-UpbConsoleBackupSet -O $o -ConfigMode:$ConfigMode -ManifestInfo ([ref]$manifestInfo) }
            'Inspect' { $r = Step-UpbConsoleInspect -O $o -ManifestInfo $manifestInfo }
            'Profiles' { $r = Step-UpbConsoleRestoreProfiles -O $o -ManifestInfo $manifestInfo }
            'Mapping' { $r = Step-UpbConsoleMapping -O $o -ManifestInfo $manifestInfo }
            'Conflict' { $r = Step-UpbConsoleConflict -O $o }
            'Extras' { $r = Step-UpbConsoleExtras -O $o -Title 'Restore: options' -StepText 'Step 6 - Verification and logging.' }
            'Review' { $r = Step-UpbConsoleRestoreReview -O $o -ManifestInfo $manifestInfo }
        }
        if ($r -eq 'skip') { $i += $direction; continue }
        if ($r -eq 'back') { $direction = -1; $i--; continue }
        if ($r -eq 'next') { $direction = 1; $i++; continue }
        if ($r -eq 'run' -or $r -eq 'whatif') {
            $run = Copy-UpbOptions $o
            $run.WhatIf = ($r -eq 'whatif')
            [void](Invoke-UpbConsoleRun -Options $run -Interactive)
            if ($r -eq 'whatif') { continue }
            return $o
        }
    }
}

#endregion

#region Console interface - configuration generator, loader and settings

function Get-UpbConfigurationPreviewLines {
    param([System.Collections.IDictionary]$O)
    $config = ConvertTo-UpbConfiguration -Options $O
    $json = ConvertTo-Json -InputObject $config -Depth 8
    $lines = @($json -split "`r?`n")
    $errors = Test-UpbConfigurationData -Data $config -Kind Configuration
    if (-not $O.Operation) { $errors = @($errors) + @('Operation is not set (choose Backup or Restore).') }
    if ($errors.Count -eq 0) { $lines += ''; $lines += 'Validation: OK' }
    else { $lines += ''; foreach ($e in $errors) { $lines += "ERROR: $e" } }
    return $lines
}

function Invoke-UpbConsoleConfigurationWizard {
    param([System.Collections.IDictionary]$Options, [string]$OutputPath, [string]$ExistingPath)
    $o = Copy-UpbOptions $Options
    $savePath = $OutputPath
    if (-not $savePath -and $ExistingPath) { $savePath = $ExistingPath }
    $dirty = $false
    if (-not $ExistingPath) {
        # Guided pass for a new configuration.
        $name = Read-UpbLine -Prompt 'Name of the new configuration profile:' -Default $(if ($o.Name) { $o.Name } else { 'My backup' })
        if ($null -eq $name) { return }
        $o.Name = $name
        $op = Show-UpbMenu -Title 'New configuration: operation' -Header @("Configuration: $name", 'Which operation does this configuration run?') -Items @(
            @{ Key = '1'; Label = 'Backup'; Value = 'Backup' }, @{ Key = '2'; Label = 'Restore'; Value = 'Restore' })
        if ($null -eq $op) { return }
        $o.Operation = $op
        if ($op -eq 'Backup') { $r = Invoke-UpbConsoleBackupWizard -Options $o -ConfigMode } else { $r = Invoke-UpbConsoleRestoreWizard -Options $o -ConfigMode }
        if ($r) { $o = $r }
        $dirty = $true
    }
    while ($true) {
        $summary = @("Name: $($o.Name)", "Operation: $($o.Operation)    Interface: $($o.Interface)")
        if ($savePath) { $summary += "File: $savePath" }
        if ($dirty) { $summary += 'Unsaved changes.' }
        $choice = Show-UpbMenu -Title 'Configuration profile generator' -Header $summary -Items @(
            @{ Key = 'N'; Label = 'Name and description'; Detail = $o.Description; Value = 'Name' },
            @{ Key = 'O'; Label = "Operation: $($o.Operation)"; Value = 'Operation' },
            @{ Key = 'D'; Label = 'Edit operation details'; Detail = 'profiles, scope, folders, dates, destinations, mappings, conflicts'; Value = 'Details' },
            @{ Key = 'I'; Label = "Interface preference: $($o.Interface)"; Value = 'Interface' },
            @{ Key = 'L'; Label = "Verification: $(if ($o.Verify) { 'On' } else { 'Off' });  log: $(if ($o.LogPath) { $o.LogPath } else { 'default' })"; Value = 'Extras' },
            @{ Key = 'R'; Label = 'Review and validate the complete configuration'; Value = 'Review' },
            @{ Key = 'S'; Label = 'Save'; Value = 'Save' },
            @{ Key = 'F'; Label = 'Open another configuration file to edit'; Value = 'Open' })
        switch ($choice) {
            $null {
                if ($dirty -and -not (Show-UpbYesNo -Title 'Configuration profile generator' -Lines @('There are unsaved changes.') -YesLabel 'Discard them and go back' -NoLabel 'Stay here')) { continue }
                return
            }
            'Name' {
                $v = Read-UpbLine -Prompt 'Name:' -Default ([string]$o.Name); if ($v) { $o.Name = $v; $dirty = $true }
                $v = Read-UpbLine -Prompt 'Description (optional):' -Default ([string]$o.Description) -AllowEmpty; if ($null -ne $v) { $o.Description = $v; $dirty = $true }
            }
            'Operation' {
                $op = Show-UpbMenu -Title 'Operation' -Items @(@{ Key = '1'; Label = 'Backup'; Value = 'Backup' }, @{ Key = '2'; Label = 'Restore'; Value = 'Restore' })
                if ($op) { $o.Operation = $op; $dirty = $true }
            }
            'Details' {
                if (-not $o.Operation) { Show-UpbMessage -Title 'Configuration' -Lines @('Choose the operation first.'); continue }
                if ($o.Operation -eq 'Backup') { $r = Invoke-UpbConsoleBackupWizard -Options $o -ConfigMode } else { $r = Invoke-UpbConsoleRestoreWizard -Options $o -ConfigMode }
                if ($r) { $o = $r; $dirty = $true }
            }
            'Interface' {
                $v = Show-UpbMenu -Title 'Interface preference' -Header @('Interface used when this configuration is loaded without -Interface.') -Items @(@{ Key = '1'; Label = 'Console'; Value = 'Console' }, @{ Key = '2'; Label = 'WPF window'; Value = 'WPF' })
                if ($v) { $o.Interface = $v; $dirty = $true }
            }
            'Extras' { if ((Step-UpbConsoleExtras -O $o -Title 'Configuration: verification and logging' -StepText 'Verification and logging preferences.') -eq 'next') { $dirty = $true } }
            'Review' { Show-UpbPager -Title 'Configuration review' -Lines (Get-UpbConfigurationPreviewLines $o) -Header @('This is exactly what will be saved. No passwords or credentials are stored.') }
            'Save' {
                if (-not $o.Operation) { Show-UpbMessage -Title 'Configuration' -Lines @('ERROR: Choose the operation before saving.'); continue }
                $saved = Save-UpbConsoleConfiguration -O $o -DefaultPath $savePath
                if ($saved) { $savePath = $saved; $dirty = $false }
            }
            'Open' {
                $path = Read-UpbLine -Prompt 'Configuration file to open:' -Default (Get-UpbConfigurationDirectory)
                if ($path) {
                    try {
                        $cfg = Import-UpbConfiguration -Path $path
                        $o = Get-UpbEffectiveOptions -Bound @{} -AppSettings (Get-UpbSettings -Quiet) -Configuration $cfg
                        $savePath = $cfg['__Path']; $dirty = $false
                    } catch { Show-UpbMessage -Title 'Open configuration' -Lines @('ERROR: ' + (Get-UpbInnerException $_).Message) }
                }
            }
        }
    }
}

function Invoke-UpbConsoleLoadConfiguration {
    $message = $null
    while ($true) {
        $configs = Get-UpbSavedConfigurations
        $items = New-Object System.Collections.Generic.List[object]
        $items.Add(@{ Key = 'P'; Label = 'Type the path of a configuration file'; Value = 'Type' })
        if ($configs.Count -gt 0) {
            $items.Add(@{ Separator = $true; Label = "Saved in $(Get-UpbConfigurationDirectory):" })
            $n = 0
            foreach ($c in $configs) {
                $n++; $key = $null; if ($n -le 9) { $key = [string]$n }
                $detail = '{0}  modified {1}' -f $c.Operation, $c.Modified.ToString('yyyy-MM-dd HH:mm')
                if (-not $c.Valid) { $detail = 'INVALID: ' + $c.Problem }
                $items.Add(@{ Key = $key; Label = ('{0,-30}' -f $c.Name); Detail = $detail; Value = 'File:' + $c.Path })
            }
        }
        $header = @('Choose a configuration profile to load.')
        if ($message) { $header += $message; $message = $null }
        $r = Show-UpbMenu -Title 'Load a configuration profile' -Header $header -Items $items.ToArray()
        if ($null -eq $r) { return $null }
        $path = $null
        if ($r -eq 'Type') { $path = Read-UpbLine -Prompt 'Configuration file:' } else { $path = $r.Substring(5) }
        if (-not $path) { continue }
        try {
            $cfg = Import-UpbConfiguration -Path $path
            return $cfg
        } catch { $message = 'ERROR: ' + (Get-UpbInnerException $_).Message }
    }
}

function Invoke-UpbConsoleSettings {
    $s = Get-UpbSettings -Quiet
    $dirty = $false
    $message = $null
    if ($script:UpbSettingsWarning) { $message = 'WARNING: ' + $script:UpbSettingsWarning }
    while ($true) {
        $d = New-UpbDefaultOptions
        $val = { param($k) if ($s.Contains($k) -and $null -ne $s[$k] -and $s[$k] -ne '') { $s[$k] } else { $d[$k] } }
        $folders = @(& $val 'Folders'); $foldersText = '(none)'; if ($folders.Count -gt 0) { $foldersText = $folders -join ', ' }
        $header = @("Saved in $(Get-UpbSettingsPath)", 'Precedence: built-in defaults < these settings < configuration profile < command-line parameters.')
        if ($dirty) { $header += 'Unsaved changes.' }
        if ($message) { $header += $message; $message = $null }
        $r = Show-UpbMenu -Title 'Settings' -Header $header -Items @(
            @{ Key = 'I'; Label = "Preferred interface: $(& $val 'Interface')"; Value = 'Interface' },
            @{ Key = 'D'; Label = "Default backup destination: $(if (& $val 'Destination') { & $val 'Destination' } else { '(none)' })"; Value = 'Destination' },
            @{ Key = 'S'; Label = "Default backup scope: $(& $val 'BackupScope')"; Value = 'Scope' },
            @{ Key = 'F'; Label = "Default folders for Selected folders: $foldersText"; Value = 'Folders' },
            @{ Key = 'T'; Label = "Default date field: $(& $val 'DateField')"; Value = 'DateField' },
            @{ Key = 'C'; Label = "Default restore conflict policy: $(& $val 'ConflictAction')"; Value = 'Conflict' },
            @{ Key = 'V'; Label = "SHA-256 verification by default: $(if (& $val 'Verify') { 'On' } else { 'Off' })"; Value = 'Verify' },
            @{ Key = 'L'; Label = "Log location: $(if (& $val 'LogPath') { & $val 'LogPath' } else { Get-UpbDefaultLogDirectory })"; Value = 'Log' },
            @{ Key = 'Y'; Label = "Show system and service profiles: $(if (& $val 'IncludeSystemProfiles') { 'Yes' } else { 'No' })"; Value = 'System' },
            @{ Separator = $true; Label = '' },
            @{ Key = 'W'; Label = 'Save settings'; Value = 'Save' },
            @{ Key = 'R'; Label = 'Reset to built-in defaults'; Value = 'Reset' })
        switch ($r) {
            $null {
                if ($dirty) {
                    $c = Show-UpbMenu -Title 'Settings' -Header @('There are unsaved changes.') -Items @(@{ Key = 'W'; Label = 'Save and go back'; Value = 'Save' }, @{ Key = 'D'; Label = 'Discard and go back'; Value = 'Discard' }, @{ Key = 'S'; Label = 'Stay here'; Value = 'Stay' })
                    if ($c -eq 'Save') { try { [void](Save-UpbSettings $s); return $true } catch { $message = 'ERROR: ' + (Get-UpbInnerException $_).Message; continue } }
                    if ($c -ne 'Discard') { continue }
                }
                return $false
            }
            'Interface' { $v = Show-UpbMenu -Title 'Preferred interface' -Items @(@{ Key = '1'; Label = 'Console'; Value = 'Console' }, @{ Key = '2'; Label = 'WPF window'; Value = 'WPF' }); if ($v) { $s.Interface = $v; $dirty = $true } }
            'Destination' {
                $how = Show-UpbMenu -Title 'Default backup destination' -Items @(@{ Key = '1'; Label = 'Type a path'; Value = 'Type' }, @{ Key = '2'; Label = 'Browse'; Value = 'Browse' }, @{ Key = '3'; Label = 'Clear'; Value = 'Clear' })
                if ($how -eq 'Type') { $v = Read-UpbLine -Prompt 'Default destination:' -Default ([string]$s.Destination); if ($v) { $s.Destination = (ConvertTo-UpbFullPath $v); $dirty = $true } }
                elseif ($how -eq 'Browse') { $v = Select-UpbConsoleFolder -Title 'Default backup destination' -Start ([string]$s.Destination) -AllowNew; if ($v) { $s.Destination = $v; $dirty = $true } }
                elseif ($how -eq 'Clear') { $s.Remove('Destination'); $dirty = $true }
            }
            'Scope' { $v = Show-UpbMenu -Title 'Default backup scope' -Items @(@{ Key = '1'; Label = 'Complete'; Value = 'Complete' }, @{ Key = '2'; Label = 'UserData'; Value = 'UserData' }, @{ Key = '3'; Label = 'SelectedFolders'; Value = 'SelectedFolders' }); if ($v) { $s.BackupScope = $v; $dirty = $true } }
            'Folders' {
                $items = New-Object System.Collections.Generic.List[object]
                foreach ($n in $script:UpbUserDataFolders) { $items.Add(@{ Label = $n; Value = $n; Selected = ($folders -contains $n) }) }
                $cl = Show-UpbChecklist -Title 'Default folders' -Items $items -Header @('Folders preselected for the Selected folders scope.') -MinSelected 0 -What 'folder'
                if ($cl) { $s.Folders = @($cl.Selected); $dirty = $true }
            }
            'DateField' { $v = Show-UpbMenu -Title 'Default date field' -Items @(@{ Key = '1'; Label = 'CreationTime'; Value = 'CreationTime' }, @{ Key = '2'; Label = 'LastWriteTime (modified)'; Value = 'LastWriteTime' }); if ($v) { $s.DateField = $v; $dirty = $true } }
            'Conflict' { $v = Show-UpbMenu -Title 'Default conflict policy' -Header @('Overwrite always asks for confirmation interactively, and is never applied by non-interactive runs unless typed on the command line.') -Items @(@{ Key = '1'; Label = 'Skip'; Value = 'Skip' }, @{ Key = '2'; Label = 'Overwrite'; Value = 'Overwrite' }, @{ Key = '3'; Label = 'KeepBoth'; Value = 'KeepBoth' }); if ($v) { $s.ConflictAction = $v; $dirty = $true } }
            'Verify' { $s.Verify = -not [bool](& $val 'Verify'); $dirty = $true }
            'Log' { $v = Read-UpbLine -Prompt 'Log file or folder (empty = default):' -Default ([string]$s.LogPath) -AllowEmpty; if ($null -ne $v) { if ($v) { $s.LogPath = $v } else { $s.Remove('LogPath') }; $dirty = $true } }
            'System' { $s.IncludeSystemProfiles = -not [bool](& $val 'IncludeSystemProfiles'); $dirty = $true }
            'Save' { try { $p = Save-UpbSettings $s; $dirty = $false; $message = "Saved to $p" } catch { $message = 'ERROR: ' + (Get-UpbInnerException $_).Message } }
            'Reset' { $s = [ordered]@{ SchemaVersion = $script:UpbSettingsSchemaVersion }; $dirty = $true }
        }
    }
}

#endregion

#region Console interface - main menu

function Start-UpbConsole {
    param([System.Collections.IDictionary]$Options, [System.Collections.IDictionary]$Bound, $Configuration, [switch]$AutoRun, [ValidateSet('Menu', 'Settings', 'NewConfiguration')][string]$Page = 'Menu', [string]$ConfigurationOutputPath)
    if (-not (Test-UpbConsoleAvailable)) {
        Write-Host 'ERROR: The interactive console needs a keyboard (input is redirected or the session is not interactive). Use -NonInteractive with parameters or a configuration profile.' -ForegroundColor Red
        return 2
    }
    $script:UpbLastExitCode = 0
    $script:UpbConsoleSession = @{ Options = $Options; Bound = $Bound; Configuration = $Configuration; ConfigName = $null }
    if ($Configuration) { $script:UpbConsoleSession.ConfigName = $Configuration.Name; if (-not $script:UpbConsoleSession.ConfigName) { $script:UpbConsoleSession.ConfigName = $Configuration['__Path'] } }
    $refresh = {
        $script:UpbConsoleSession.Options = Get-UpbEffectiveOptions -Bound $script:UpbConsoleSession.Bound -AppSettings (Get-UpbSettings -Quiet) -Configuration $script:UpbConsoleSession.Configuration
        $script:UpbConsoleSession.Options.WhatIf = $Options.WhatIf
    }
    try {
        if ($Page -eq 'Settings') { [void](Invoke-UpbConsoleSettings); return 0 }
        if ($Page -eq 'NewConfiguration') {
            $existing = $null; if ($Configuration) { $existing = $Configuration['__Path'] }
            Invoke-UpbConsoleConfigurationWizard -Options $Options -OutputPath $ConfigurationOutputPath -ExistingPath $existing
            return 0
        }
        if ($AutoRun) {
            $run = Copy-UpbOptions $Options
            if ($run.Operation -eq 'Restore' -and $run.ConflictAction -eq 'Overwrite' -and -not $run.WhatIf) {
                if (-not (Read-UpbConfirmWord -Title 'Confirm overwrite' -Lines @('The restore will REPLACE existing files at the destinations.') -Word 'OVERWRITE')) { Write-Host 'Canceled.' -ForegroundColor Yellow; return 3 }
                $run.OverwriteConfirmed = $true
            }
            $result = Invoke-UpbConsoleRun -Options $run
            return $result.ExitCode
        }
        if ($Options.Operation -eq 'Backup') { [void](Invoke-UpbConsoleBackupWizard -Options $Options -StartStep $(if (@($Options.Profiles).Count -gt 0 -and $Options.Destination) { 'Review' } else { $null })) }
        elseif ($Options.Operation -eq 'Restore') { [void](Invoke-UpbConsoleRestoreWizard -Options $Options -StartStep $(if ($Options.BackupPath) { 'Review' } else { $null })) }
        while ($true) {
            $header = @()
            if ($script:UpbSettingsWarning) { $header += 'WARNING: ' + $script:UpbSettingsWarning }
            if (-not (Test-UpbIsAdmin)) { $header += 'Not elevated: backing up or restoring other users'' profiles usually needs "Run as administrator".' }
            $choice = Show-UpbMenu -Title 'Main menu' -Header $header -Items @(
                @{ Key = '1'; Label = 'Back up profiles'; Value = 'Backup' },
                @{ Key = '2'; Label = 'Restore profiles'; Value = 'Restore' },
                @{ Key = '3'; Label = 'Create or edit a configuration profile'; Value = 'Config' },
                @{ Key = '4'; Label = 'Load a configuration profile'; Detail = $(if ($script:UpbConsoleSession.ConfigName) { "(loaded: $($script:UpbConsoleSession.ConfigName))" } else { '' }); Value = 'Load' },
                @{ Key = '5'; Label = 'Settings'; Value = 'Settings' },
                @{ Key = '6'; Label = 'Exit'; Value = 'Exit' })
            $o = $script:UpbConsoleSession.Options
            switch ($choice) {
                $null { return $script:UpbLastExitCode }
                'Exit' { return $script:UpbLastExitCode }
                'Backup' { [void](Invoke-UpbConsoleBackupWizard -Options $o) }
                'Restore' { [void](Invoke-UpbConsoleRestoreWizard -Options $o) }
                'Config' {
                    $existing = $null
                    if ($script:UpbConsoleSession.Configuration) {
                        $which = Show-UpbMenu -Title 'Configuration profile generator' -Items @(
                            @{ Key = '1'; Label = 'Create a new configuration'; Value = 'New' },
                            @{ Key = '2'; Label = "Edit the loaded configuration ($($script:UpbConsoleSession.ConfigName))"; Value = 'Edit' })
                        if ($null -eq $which) { continue }
                        if ($which -eq 'Edit') { $existing = $script:UpbConsoleSession.Configuration['__Path'] }
                    }
                    if ($existing) { Invoke-UpbConsoleConfigurationWizard -Options $o -ExistingPath $existing }
                    else { Invoke-UpbConsoleConfigurationWizard -Options (Get-UpbEffectiveOptions -Bound @{} -AppSettings (Get-UpbSettings -Quiet) -Configuration $null) }
                }
                'Load' {
                    $cfg = Invoke-UpbConsoleLoadConfiguration
                    if ($cfg) {
                        $script:UpbConsoleSession.Configuration = $cfg
                        $script:UpbConsoleSession.ConfigName = $(if ($cfg.Name) { $cfg.Name } else { $cfg['__Path'] })
                        $script:UpbConsoleSession.Bound = @{}
                        & $refresh
                        $o = $script:UpbConsoleSession.Options
                        $lines = @("Loaded: $($cfg['__Path'])", '') + @(Get-UpbConfigurationPreviewLines $o)
                        $next = Show-UpbMenu -Title 'Configuration loaded' -Header (@($lines | Select-Object -First ((Get-UpbConsoleHeight) - 12))) -Items @(
                            @{ Key = 'R'; Label = "Review and run this $($o.Operation)"; Value = 'Run'; Disabled = -not $o.Operation },
                            @{ Key = 'E'; Label = 'Edit it in the configuration generator'; Value = 'Edit' },
                            @{ Key = 'M'; Label = 'Back to the main menu (its values become the defaults)'; Value = 'Menu' })
                        if ($next -eq 'Run') {
                            if ($o.Operation -eq 'Backup') { [void](Invoke-UpbConsoleBackupWizard -Options $o -StartStep 'Review') }
                            else { [void](Invoke-UpbConsoleRestoreWizard -Options $o -StartStep 'Review') }
                        } elseif ($next -eq 'Edit') { Invoke-UpbConsoleConfigurationWizard -Options $o -ExistingPath $cfg['__Path'] }
                    }
                }
                'Settings' { [void](Invoke-UpbConsoleSettings); & $refresh }
            }
        }
    } finally {
        # Keep the result summary of a direct run on screen; clear only after menu screens.
        if (-not $AutoRun) { Clear-UpbScreen }
    }
}

#endregion

#region WPF interface

$script:UpbWpfXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UserProfileBackup" Width="1120" Height="800" MinWidth="900" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#F4F6F9" FontFamily="Segoe UI" FontSize="12.5">
  <Window.Resources>
    <Style TargetType="GroupBox">
      <Setter Property="Margin" Value="6"/>
      <Setter Property="Padding" Value="6"/>
      <Setter Property="BorderBrush" Value="#C9D1DC"/>
      <Setter Property="Background" Value="White"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="Margin" Value="4"/>
      <Setter Property="MinWidth" Value="80"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Padding" Value="3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="MinWidth" Value="140"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Margin" Value="4,3"/>
    </Style>
    <Style TargetType="DatePicker">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Width" Value="160"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#5A6473"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="4,2"/>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#1F6FEB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Bottom" Background="#E3E8EF" Padding="8,4">
      <TextBlock x:Name="txtStatus" Text="Ready." TextTrimming="CharacterEllipsis"/>
    </Border>
    <TabControl x:Name="Tabs" Margin="6">
      <TabItem x:Name="TabBackup" Header="  Back up  ">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
              <GroupBox Header="1. Profiles">
                <StackPanel>
                  <ListBox x:Name="lstBkProfiles" Height="150" Margin="4"/>
                  <WrapPanel>
                    <Button x:Name="btnBkRefresh" Content="Refresh"/>
                    <Button x:Name="btnBkAddProfile" Content="Add profile folder..."/>
                    <CheckBox x:Name="chkBkSystem" Content="Show system and service profiles"/>
                  </WrapPanel>
                  <TextBlock x:Name="txtBkElevation" Style="{StaticResource Hint}"/>
                </StackPanel>
              </GroupBox>
              <GroupBox Header="2. Scope">
                <StackPanel>
                  <RadioButton x:Name="rbScopeComplete" GroupName="Scope">
                    <TextBlock TextWrapping="Wrap"><Bold>Complete profile</Bold> - every accessible file, including hidden items and AppData. A file backup only: credentials, EFS-encrypted files and many app settings are not portable to another account or PC.</TextBlock>
                  </RadioButton>
                  <RadioButton x:Name="rbScopeUserData" GroupName="Scope">
                    <TextBlock TextWrapping="Wrap"><Bold>User data</Bold> - Documents, Pictures, Music, Videos, Contacts, Desktop, Downloads and Bookmarks.</TextBlock>
                  </RadioButton>
                  <RadioButton x:Name="rbScopeSelected" GroupName="Scope">
                    <TextBlock TextWrapping="Wrap"><Bold>Selected folders</Bold> - choose folders below and add custom folders.</TextBlock>
                  </RadioButton>
                </StackPanel>
              </GroupBox>
              <GroupBox Header="3. Folders (Selected folders scope)">
                <StackPanel>
                  <ListBox x:Name="lstBkFolders" Height="175" Margin="4"/>
                  <WrapPanel>
                    <Button x:Name="btnBkAddFolder" Content="Add custom folder..."/>
                    <Button x:Name="btnBkAddRelative" Content="Add relative path..."/>
                    <Button x:Name="btnBkRemoveFolder" Content="Remove selected custom"/>
                  </WrapPanel>
                  <TextBlock Style="{StaticResource Hint}" Text="Paths are shown for the first selected profile; every profile's own folders (redirected or OneDrive) are resolved when the backup runs. Bookmarks: close Edge, Chrome and Firefox first - running browsers lock or keep rewriting their files."/>
                </StackPanel>
              </GroupBox>
            </StackPanel>
            <StackPanel Grid.Column="1">
              <GroupBox Header="4. Date filter (local time)">
                <StackPanel>
                  <WrapPanel>
                    <TextBlock Text="Filter:" VerticalAlignment="Center" Margin="4"/>
                    <ComboBox x:Name="cmbDateFilter"/>
                    <TextBlock Text="Timestamp:" VerticalAlignment="Center" Margin="12,4,4,4"/>
                    <ComboBox x:Name="cmbDateField"/>
                  </WrapPanel>
                  <WrapPanel x:Name="pnlDateSingle">
                    <TextBlock Text="Date:" VerticalAlignment="Center" Margin="4" Width="44"/>
                    <DatePicker x:Name="dpDate"/>
                    <TextBlock Text="Time (optional):" VerticalAlignment="Center" Margin="8,4,4,4"/>
                    <TextBox x:Name="txtTime" Width="80" ToolTip="HH:mm or HH:mm:ss. Leave empty to use the whole day."/>
                  </WrapPanel>
                  <StackPanel x:Name="pnlDateRange">
                    <WrapPanel>
                      <TextBlock Text="From:" VerticalAlignment="Center" Margin="4" Width="44"/>
                      <DatePicker x:Name="dpStart"/>
                      <TextBlock Text="Time (optional):" VerticalAlignment="Center" Margin="8,4,4,4"/>
                      <TextBox x:Name="txtStartTime" Width="80"/>
                    </WrapPanel>
                    <WrapPanel>
                      <TextBlock Text="To:" VerticalAlignment="Center" Margin="4" Width="44"/>
                      <DatePicker x:Name="dpEnd"/>
                      <TextBlock Text="Time (optional):" VerticalAlignment="Center" Margin="8,4,4,4"/>
                      <TextBox x:Name="txtEndTime" Width="80"/>
                    </WrapPanel>
                  </StackPanel>
                  <TextBlock x:Name="txtFilterHelp" Style="{StaticResource Hint}"/>
                  <Border Background="#EEF4FF" BorderBrush="#B9CDF5" BorderThickness="1" Margin="4" Padding="6">
                    <TextBlock x:Name="txtBoundaries" TextWrapping="Wrap"/>
                  </Border>
                </StackPanel>
              </GroupBox>
              <GroupBox Header="5. Destination">
                <StackPanel>
                  <DockPanel>
                    <Button x:Name="btnBkBrowse" DockPanel.Dock="Right" Content="Browse..."/>
                    <TextBox x:Name="txtBkDest" ToolTip="Local folder, external drive, or \\server\share\folder"/>
                  </DockPanel>
                  <TextBlock x:Name="txtBkFree" Style="{StaticResource Hint}"/>
                </StackPanel>
              </GroupBox>
              <GroupBox Header="6. Options">
                <StackPanel>
                  <CheckBox x:Name="chkBkVerify" Content="Verify with SHA-256 (records a hash for every file and checks each copy)"/>
                  <DockPanel>
                    <TextBlock Text="Log:" VerticalAlignment="Center" Margin="4" DockPanel.Dock="Left"/>
                    <Button x:Name="btnBkLog" DockPanel.Dock="Right" Content="Browse..."/>
                    <TextBox x:Name="txtBkLog" ToolTip="Log file (*.log) or folder. Empty = default location."/>
                  </DockPanel>
                </StackPanel>
              </GroupBox>
              <WrapPanel HorizontalAlignment="Right" Margin="6">
                <Button x:Name="btnBkSaveConfig" Content="Save as configuration..."/>
                <Button x:Name="btnBkPreview" Content="Preview (WhatIf)"/>
                <Button x:Name="btnBkStart" Content="Review and start backup" Style="{StaticResource Primary}"/>
              </WrapPanel>
            </StackPanel>
          </Grid>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabRestore" Header="  Restore  ">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <GroupBox Header="1. Backup set" Grid.Row="0">
            <StackPanel>
              <DockPanel>
                <Button x:Name="btnRsLoad" DockPanel.Dock="Right" Content="Load manifest"/>
                <Button x:Name="btnRsBrowse" DockPanel.Dock="Right" Content="Browse..."/>
                <TextBox x:Name="txtRsPath" ToolTip="Backup set folder (UPB_...) or its manifest.json"/>
              </DockPanel>
              <DockPanel>
                <TextBlock Text="Found in the default destination:" VerticalAlignment="Center" Margin="4" DockPanel.Dock="Left"/>
                <ComboBox x:Name="cmbRsSets"/>
              </DockPanel>
            </StackPanel>
          </GroupBox>
          <Grid Grid.Row="1">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <GroupBox Header="2. Manifest" Grid.Column="0">
              <TextBox x:Name="txtRsManifest" IsReadOnly="True" FontFamily="Consolas" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
            </GroupBox>
            <GroupBox Header="3. Profiles and destinations" Grid.Column="1">
              <DockPanel>
                <StackPanel DockPanel.Dock="Bottom">
                  <TextBlock Style="{StaticResource Hint}" Text="Select a profile row, choose its destination, then click Apply. Accounts are never created and permissions are never changed."/>
                  <RadioButton x:Name="rbMapOriginal" GroupName="Map" Content="Original location (paths recorded in the manifest)"/>
                  <DockPanel>
                    <RadioButton x:Name="rbMapProfile" GroupName="Map" Content="Another existing profile:" VerticalAlignment="Center"/>
                    <ComboBox x:Name="cmbMapProfile"/>
                  </DockPanel>
                  <DockPanel>
                    <RadioButton x:Name="rbMapFolder" GroupName="Map" Content="Custom folder:" VerticalAlignment="Center" DockPanel.Dock="Left"/>
                    <Button x:Name="btnMapBrowse" DockPanel.Dock="Right" Content="Browse..."/>
                    <TextBox x:Name="txtMapFolder"/>
                  </DockPanel>
                  <WrapPanel HorizontalAlignment="Right">
                    <Button x:Name="btnRsLoadMap" Content="Load mapping file..."/>
                    <Button x:Name="btnMapApply" Content="Apply to selected profile"/>
                  </WrapPanel>
                </StackPanel>
                <ListBox x:Name="lstRsProfiles" Margin="4"/>
              </DockPanel>
            </GroupBox>
          </Grid>
          <GroupBox Header="4. Options" Grid.Row="2">
            <DockPanel>
              <WrapPanel DockPanel.Dock="Right" VerticalAlignment="Bottom">
                <Button x:Name="btnRsSaveConfig" Content="Save as configuration..."/>
                <Button x:Name="btnRsPreview" Content="Preview (WhatIf)"/>
                <Button x:Name="btnRsStart" Content="Review and start restore" Style="{StaticResource Primary}"/>
              </WrapPanel>
              <StackPanel>
                <WrapPanel>
                  <TextBlock Text="When a file already exists:" VerticalAlignment="Center" Margin="4"/>
                  <ComboBox x:Name="cmbConflict"/>
                  <TextBlock x:Name="txtConflictHelp" Style="{StaticResource Hint}" VerticalAlignment="Center"/>
                </WrapPanel>
                <CheckBox x:Name="chkRsVerify" Content="Verify every restored file with SHA-256"/>
                <DockPanel>
                  <TextBlock Text="Log:" VerticalAlignment="Center" Margin="4" DockPanel.Dock="Left"/>
                  <TextBox x:Name="txtRsLog" MaxWidth="520" HorizontalAlignment="Left" MinWidth="360"/>
                </DockPanel>
              </StackPanel>
            </DockPanel>
          </GroupBox>
        </Grid>
      </TabItem>
      <TabItem x:Name="TabConfig" Header="  Configuration profiles  ">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="380"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <StackPanel Grid.Column="0">
            <GroupBox Header="Configuration">
              <StackPanel>
                <TextBlock Text="Name" Margin="4,4,4,0"/>
                <TextBox x:Name="txtCfgName"/>
                <TextBlock Text="Description" Margin="4,4,4,0"/>
                <TextBox x:Name="txtCfgDesc" Height="54" TextWrapping="Wrap" AcceptsReturn="True" VerticalContentAlignment="Top"/>
                <WrapPanel>
                  <TextBlock Text="Operation:" VerticalAlignment="Center" Margin="4" Width="72"/>
                  <ComboBox x:Name="cmbCfgOperation"/>
                </WrapPanel>
                <WrapPanel>
                  <TextBlock Text="Interface:" VerticalAlignment="Center" Margin="4" Width="72"/>
                  <ComboBox x:Name="cmbCfgInterface"/>
                </WrapPanel>
                <TextBlock Text="File" Margin="4,4,4,0"/>
                <DockPanel>
                  <Button x:Name="btnCfgBrowse" DockPanel.Dock="Right" Content="..." MinWidth="30"/>
                  <TextBox x:Name="txtCfgPath"/>
                </DockPanel>
                <TextBlock Style="{StaticResource Hint}" Text="Operation details (profiles, scope, folders, dates, destination, restore mappings, conflict policy, verification and logging) come from the Back up or Restore tab. No passwords or credentials are ever stored."/>
              </StackPanel>
            </GroupBox>
            <WrapPanel Margin="6">
              <Button x:Name="btnCfgNew" Content="New"/>
              <Button x:Name="btnCfgOpen" Content="Open..."/>
              <Button x:Name="btnCfgRefresh" Content="Refresh preview"/>
              <Button x:Name="btnCfgValidate" Content="Validate"/>
              <Button x:Name="btnCfgSave" Content="Save" Style="{StaticResource Primary}"/>
            </WrapPanel>
            <TextBlock x:Name="txtCfgStatus" Style="{StaticResource Hint}" Margin="10,4"/>
          </StackPanel>
          <GroupBox Header="Review: exactly what will be saved" Grid.Column="1">
            <TextBox x:Name="txtCfgJson" IsReadOnly="True" FontFamily="Consolas" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
          </GroupBox>
        </Grid>
      </TabItem>
      <TabItem x:Name="TabSettings" Header="  Settings  ">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel MaxWidth="760" HorizontalAlignment="Left">
            <GroupBox Header="Application settings">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="230"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Text="Preferred interface" VerticalAlignment="Center" Margin="4"/>
                <ComboBox Grid.Row="0" Grid.Column="1" x:Name="cmbSetInterface" HorizontalAlignment="Left"/>
                <TextBlock Grid.Row="1" Text="Default backup destination" VerticalAlignment="Center" Margin="4"/>
                <DockPanel Grid.Row="1" Grid.Column="1">
                  <Button x:Name="btnSetDest" DockPanel.Dock="Right" Content="Browse..."/>
                  <TextBox x:Name="txtSetDest"/>
                </DockPanel>
                <TextBlock Grid.Row="2" Text="Default backup scope" VerticalAlignment="Center" Margin="4"/>
                <ComboBox Grid.Row="2" Grid.Column="1" x:Name="cmbSetScope" HorizontalAlignment="Left"/>
                <TextBlock Grid.Row="3" Text="Default folders (Selected folders)" VerticalAlignment="Top" Margin="4"/>
                <ListBox Grid.Row="3" Grid.Column="1" x:Name="lstSetFolders" Height="120" Margin="4"/>
                <TextBlock Grid.Row="4" Text="Default date field" VerticalAlignment="Center" Margin="4"/>
                <ComboBox Grid.Row="4" Grid.Column="1" x:Name="cmbSetDateField" HorizontalAlignment="Left"/>
                <TextBlock Grid.Row="5" Text="Default restore conflict policy" VerticalAlignment="Center" Margin="4"/>
                <ComboBox Grid.Row="5" Grid.Column="1" x:Name="cmbSetConflict" HorizontalAlignment="Left"/>
                <TextBlock Grid.Row="6" Text="Verification" VerticalAlignment="Center" Margin="4"/>
                <CheckBox Grid.Row="6" Grid.Column="1" x:Name="chkSetVerify" Content="Verify with SHA-256 by default"/>
                <TextBlock Grid.Row="7" Text="Log location" VerticalAlignment="Center" Margin="4"/>
                <DockPanel Grid.Row="7" Grid.Column="1">
                  <Button x:Name="btnSetLog" DockPanel.Dock="Right" Content="Browse..."/>
                  <TextBox x:Name="txtSetLog"/>
                </DockPanel>
                <TextBlock Grid.Row="8" Text="Profiles" VerticalAlignment="Center" Margin="4"/>
                <CheckBox Grid.Row="8" Grid.Column="1" x:Name="chkSetSystem" Content="Show system and service profiles"/>
              </Grid>
            </GroupBox>
            <TextBlock x:Name="txtSetInfo" Style="{StaticResource Hint}" Margin="10,2"/>
            <WrapPanel Margin="6">
              <Button x:Name="btnSetSave" Content="Save settings" Style="{StaticResource Primary}"/>
              <Button x:Name="btnSetReload" Content="Reload"/>
              <Button x:Name="btnSetDefaults" Content="Built-in defaults"/>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>
      </TabItem>
      <TabItem x:Name="TabProgress" Header="  Progress and results  ">
        <DockPanel>
          <GroupBox Header="Progress" DockPanel.Dock="Top">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="120"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
              </Grid.RowDefinitions>
              <TextBlock Grid.Row="0" Text="Operation" Margin="4"/><TextBlock Grid.Row="0" Grid.Column="1" x:Name="txtPrOperation" Margin="4" FontWeight="SemiBold"/>
              <TextBlock Grid.Row="1" Text="Profile" Margin="4"/><TextBlock Grid.Row="1" Grid.Column="1" x:Name="txtPrProfile" Margin="4"/>
              <TextBlock Grid.Row="2" Text="Current file" Margin="4"/><TextBlock Grid.Row="2" Grid.Column="1" x:Name="txtPrFile" Margin="4" TextTrimming="CharacterEllipsis"/>
              <TextBlock Grid.Row="3" Text="Files" Margin="4"/><TextBlock Grid.Row="3" Grid.Column="1" x:Name="txtPrCounts" Margin="4"/>
              <TextBlock Grid.Row="4" Text="Transferred" Margin="4"/><TextBlock Grid.Row="4" Grid.Column="1" x:Name="txtPrBytes" Margin="4"/>
              <TextBlock Grid.Row="5" Text="Elapsed" Margin="4"/><TextBlock Grid.Row="5" Grid.Column="1" x:Name="txtPrElapsed" Margin="4"/>
              <DockPanel Grid.Row="6" Grid.ColumnSpan="2">
                <Button x:Name="btnCancel" DockPanel.Dock="Right" Content="Cancel" IsEnabled="False"/>
                <ProgressBar x:Name="pbProgress" Height="20" Margin="4" Minimum="0" Maximum="100"/>
              </DockPanel>
            </Grid>
          </GroupBox>
          <GroupBox Header="Result" DockPanel.Dock="Top">
            <StackPanel>
              <TextBlock x:Name="txtPrResult" TextWrapping="Wrap" Margin="4" FontWeight="SemiBold"/>
              <WrapPanel>
                <Button x:Name="btnOpenSet" Content="Open backup set folder" IsEnabled="False"/>
                <Button x:Name="btnOpenLog" Content="Open log" IsEnabled="False"/>
              </WrapPanel>
            </StackPanel>
          </GroupBox>
          <GroupBox Header="Messages">
            <TextBox x:Name="txtPrLog" IsReadOnly="True" FontFamily="Consolas" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
          </GroupBox>
        </DockPanel>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

$script:UpbWpfAutoAnswer = $null
$script:UpbWpfDialogLog = New-Object System.Collections.ArrayList

$script:UpbWpfReviewXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="860" Height="600" WindowStartupLocation="CenterOwner" Background="#F4F6F9" FontFamily="Segoe UI" ShowInTaskbar="False">
  <DockPanel Margin="10">
    <TextBlock x:Name="txtIntro" DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <WrapPanel DockPanel.Dock="Bottom" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="btnCancelReview" Content="Cancel" Padding="14,4" Margin="4" IsCancel="True"/>
      <Button x:Name="btnOk" Padding="14,4" Margin="4" IsDefault="True" Background="#1F6FEB" Foreground="White" FontWeight="SemiBold"/>
    </WrapPanel>
    <TextBox x:Name="txtBody" IsReadOnly="True" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
  </DockPanel>
</Window>
'@

function Test-UpbWpfAvailable {
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { return 'The WPF interface needs Windows. Use -Interface Console.' }
    try { $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId } catch { $sessionId = 1 }
    if ($sessionId -eq 0 -or -not [Environment]::UserInteractive) { return 'The WPF interface needs an interactive desktop session (this session cannot show windows). Use -Interface Console or -NonInteractive.' }
    try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms -ErrorAction Stop }
    catch { return "WPF is not available in this PowerShell environment ($((Get-UpbInnerException $_).Message)). On Server Core or minimal installations use -Interface Console." }
    return $null
}

function New-UpbWpfCheckItem {
    param([string]$Text, $Tag, [bool]$Checked, [string]$ToolTip)
    $cb = New-Object System.Windows.Controls.CheckBox
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $cb.Content = $tb
    $cb.Tag = $Tag
    $cb.IsChecked = $Checked
    $cb.Margin = New-Object System.Windows.Thickness 2
    if ($ToolTip) { $cb.ToolTip = $ToolTip }
    return $cb
}

function Set-UpbWpfCheckText {
    param($CheckBox, [string]$Text)
    $CheckBox.Content.Text = $Text
}

function Select-UpbWpfFolder {
    param([string]$Description, [string]$Initial)
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = $Description
    $d.ShowNewFolderButton = $true
    if ($Initial) { $near = Get-UpbNearestExistingDirectory $Initial; if ($near) { $d.SelectedPath = $near } }
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    return $null
}

function Show-UpbWpfMessage {
    param([string]$Text, [string]$Caption = 'UserProfileBackup', [string]$Icon = 'Information', [string]$Buttons = 'OK')
    $owner = $script:W.Window
    if ($script:UpbWpfAutoAnswer) {
        [void]$script:UpbWpfDialogLog.Add("$Caption`: $Text")
        return [System.Windows.MessageBoxResult]$script:UpbWpfAutoAnswer
    }
    return [System.Windows.MessageBox]::Show($owner, $Text, $Caption, [System.Windows.MessageBoxButton]$Buttons, [System.Windows.MessageBoxImage]$Icon)
}

function Show-UpbWpfReview {
    param([string]$Title, [string]$Intro, [string[]]$Lines, [string]$OkLabel = 'Start')
    $win = [Windows.Markup.XamlReader]::Parse($script:UpbWpfReviewXaml)
    $win.Title = $Title
    $win.Owner = $script:W.Window
    $win.FindName('txtIntro').Text = $Intro
    $win.FindName('txtBody').Text = ($Lines -join [Environment]::NewLine)
    $ok = $win.FindName('btnOk')
    $ok.Content = $OkLabel
    $ok.Add_Click({ $win.DialogResult = $true })
    $result = $win.ShowDialog()
    return [bool]$result
}

function Set-UpbWpfStatus { param([string]$Text) $script:W.txtStatus.Text = $Text }

function Get-UpbWpfDateText {
    param($Picker, $TimeBox)
    if (-not $Picker.SelectedDate) { return $null }
    $d = ([datetime]$Picker.SelectedDate).ToString('yyyy-MM-dd')
    $t = $TimeBox.Text.Trim()
    if ($t) { return "$d $t" }
    return $d
}

function Set-UpbWpfDateControls {
    param($Picker, $TimeBox, $Text)
    $Picker.SelectedDate = $null; $TimeBox.Text = ''
    if (-not $Text) { return }
    try {
        $d = ConvertTo-UpbDateInput $Text
        $Picker.SelectedDate = $d.Value.Date
        if (-not $d.DateOnly) {
            if ($d.Value.Second -eq 0) { $TimeBox.Text = $d.Value.ToString('HH:mm') } else { $TimeBox.Text = $d.Value.ToString('HH:mm:ss') }
        }
    } catch { }
}

# ---- Back up tab -----------------------------------------------------------

function Update-UpbWpfProfileList {
    param([string[]]$Selected)
    $W = $script:W
    $W.lstBkProfiles.Items.Clear()
    $W.AllProfiles = @(Get-UpbUserProfiles -IncludeSystem:([bool]$W.chkBkSystem.IsChecked))
    $matched = @{}
    foreach ($p in $W.AllProfiles) {
        $isSel = $false
        foreach ($s in @($Selected)) { if ($s -and ($p.AccountName -ieq $s -or $p.UserName -ieq $s -or $p.Path -ieq $s.TrimEnd('\'))) { $isSel = $true; $matched[$s.ToLowerInvariant()] = $true } }
        $flag = ''; if ($p.IsSystem) { $flag = ' (system)' }
        $item = New-UpbWpfCheckItem -Text ('{0}{1}   -   {2}   -   {3}' -f $p.AccountName, $flag, $p.Path, $p.Availability) -Tag $p.AccountName -Checked $isSel -ToolTip $p.Sid
        if (-not $p.Available) { $item.Foreground = [System.Windows.Media.Brushes]::Firebrick }
        $item.Add_Click({ Update-UpbWpfFolderList })
        [void]$W.lstBkProfiles.Items.Add($item)
    }
    foreach ($s in @($Selected)) {
        if ($s -and -not $matched.ContainsKey($s.ToLowerInvariant())) {
            $item = New-UpbWpfCheckItem -Text ("$s   -   (added)") -Tag $s -Checked $true
            $item.Add_Click({ Update-UpbWpfFolderList })
            [void]$W.lstBkProfiles.Items.Add($item)
        }
    }
}

function Get-UpbWpfSelectedProfiles {
    return @($script:W.lstBkProfiles.Items | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
}

function Update-UpbWpfFolderList {
    param([string[]]$Selected)
    $W = $script:W
    if ($PSBoundParameters.ContainsKey('Selected')) { $sel = @($Selected) }
    else { $sel = @($W.lstBkFolders.Items | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag }) }
    $customs = @($W.lstBkFolders.Items | Where-Object { $script:UpbUserDataFolders -notcontains [string]$_.Tag } | ForEach-Object { [string]$_.Tag })
    foreach ($s in $sel) { if ($script:UpbUserDataFolders -notcontains $s -and $customs -notcontains $s) { $customs += $s } }
    $kf = $null
    $first = @(Get-UpbWpfSelectedProfiles) | Select-Object -First 1
    if ($first) {
        try { $p = @(Resolve-UpbProfileSelection -Names @($first) -AllProfiles $W.AllProfiles)[0]; $kf = Get-UpbKnownFolders -UserProfile $p } catch { $kf = $null }
    }
    $W.lstBkFolders.Items.Clear()
    foreach ($name in $script:UpbUserDataFolders) {
        $text = $name
        if ($name -eq 'Bookmarks') { $text = 'Bookmarks   -   Favorites + Edge, Chrome and Firefox bookmark files' }
        elseif ($kf) {
            $k = $kf[$name]; $text = '{0}   -   {1}' -f $name, $k.Path
            if ($k.Redirected -or $k.Source -eq 'OneDrive (detected)') { $text += "   ($($k.Source))" }
            if (-not $k.Exists) { $text += '   (not found)' }
        }
        [void]$W.lstBkFolders.Items.Add((New-UpbWpfCheckItem -Text $text -Tag $name -Checked ($sel -contains $name)))
    }
    foreach ($c in $customs) { [void]$W.lstBkFolders.Items.Add((New-UpbWpfCheckItem -Text "$c   -   (custom)" -Tag $c -Checked ($sel -contains $c))) }
    $W.lstBkFolders.IsEnabled = [bool]$W.rbScopeSelected.IsChecked
}

function Update-UpbWpfDateUi {
    $W = $script:W
    $filter = [string]$W.cmbDateFilter.SelectedItem
    $single = 'On', 'After', 'Before' -contains $filter
    if ($single) { $W.pnlDateSingle.Visibility = 'Visible' } else { $W.pnlDateSingle.Visibility = 'Collapsed' }
    if ($filter -eq 'Range') { $W.pnlDateRange.Visibility = 'Visible' } else { $W.pnlDateRange.Visibility = 'Collapsed' }
    $W.txtFilterHelp.Text = switch ($filter) {
        'All' { 'Every file is backed up.' }
        'On' { 'The whole local calendar day of the date.' }
        'After' { 'Date only: from the start of the next day (the day itself is excluded). With a time: strictly later.' }
        'Before' { 'Date only: before the start of that day (the day itself is excluded). With a time: strictly earlier.' }
        'CurrentWeek' { 'From Monday 00:00 of the current week; evaluated when the backup starts.' }
        'CurrentMonth' { 'From the 1st of the current month at 00:00; evaluated when the backup starts.' }
        'Range' { 'Date-only endpoints include both whole days. Date/time endpoints are inclusive.' }
    }
    try {
        $f = Resolve-UpbDateFilter -Filter $filter -Date (Get-UpbWpfDateText $W.dpDate $W.txtTime) -StartDate (Get-UpbWpfDateText $W.dpStart $W.txtStartTime) -EndDate (Get-UpbWpfDateText $W.dpEnd $W.txtEndTime) -DateField ([string]$W.cmbDateField.SelectedItem)
        $text = $f.Description
        if ($null -ne $f.Lower) { $text += "`nLower bound: $(Format-UpbLocalTime $f.Lower) $(if ($f.LowerInclusive) { '(included)' } else { '(excluded)' })" }
        if ($null -ne $f.Upper) { $text += "`nUpper bound: $(Format-UpbLocalTime $f.Upper) $(if ($f.UpperInclusive) { '(included)' } else { '(excluded)' })" }
        foreach ($n in $f.Notes) { $text += "`nNote: $n" }
        $W.txtBoundaries.Text = $text
        $W.txtBoundaries.Foreground = [System.Windows.Media.Brushes]::Black
        $W.DateValid = $true
    } catch {
        $W.txtBoundaries.Text = (Get-UpbInnerException $_).Message
        $W.txtBoundaries.Foreground = [System.Windows.Media.Brushes]::Firebrick
        $W.DateValid = $false
    }
}

function Update-UpbWpfFreeSpace {
    $W = $script:W
    $dest = $W.txtBkDest.Text.Trim()
    if (-not $dest) { $W.txtBkFree.Text = 'Choose a local folder, an external drive or a \\server\share\folder.'; return }
    try {
        $full = ConvertTo-UpbFullPath $dest
        $near = Get-UpbNearestExistingDirectory $full
        if (-not $near) { $W.txtBkFree.Text = 'This location is not reachable.'; return }
        $free = [UpbIo]::GetFreeBytes($near)
        $W.txtBkFree.Text = "Free space: $(Format-UpbBytes $free).  A new UPB_<computer>_<date> folder is created here for each backup."
    } catch { $W.txtBkFree.Text = 'Not a valid path.' }
}

function Get-UpbWpfBackupOptions {
    $W = $script:W
    $o = Copy-UpbOptions $W.Options
    $o.Operation = 'Backup'
    $o.Profiles = @(Get-UpbWpfSelectedProfiles)
    $o.IncludeSystemProfiles = [bool]$W.chkBkSystem.IsChecked
    if ($W.rbScopeComplete.IsChecked) { $o.BackupScope = 'Complete' } elseif ($W.rbScopeSelected.IsChecked) { $o.BackupScope = 'SelectedFolders' } else { $o.BackupScope = 'UserData' }
    $o.Folders = @()
    if ($o.BackupScope -eq 'SelectedFolders') { $o.Folders = @($W.lstBkFolders.Items | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag }) }
    $o.DateFilter = [string]$W.cmbDateFilter.SelectedItem
    $o.DateField = [string]$W.cmbDateField.SelectedItem
    $o.Date = $null; $o.StartDate = $null; $o.EndDate = $null
    if ('On', 'After', 'Before' -contains $o.DateFilter) { $o.Date = Get-UpbWpfDateText $W.dpDate $W.txtTime }
    if ($o.DateFilter -eq 'Range') { $o.StartDate = Get-UpbWpfDateText $W.dpStart $W.txtStartTime; $o.EndDate = Get-UpbWpfDateText $W.dpEnd $W.txtEndTime }
    $o.Destination = $W.txtBkDest.Text.Trim()
    $o.Verify = [bool]$W.chkBkVerify.IsChecked
    $o.LogPath = $W.txtBkLog.Text.Trim(); if (-not $o.LogPath) { $o.LogPath = $null }
    $o.WhatIf = $false
    $o.NonInteractive = $false
    return $o
}

function Set-UpbWpfBackupFromOptions {
    param([System.Collections.IDictionary]$O)
    $W = $script:W
    $W.chkBkSystem.IsChecked = [bool]$O.IncludeSystemProfiles
    Update-UpbWpfProfileList -Selected $O.Profiles
    switch ($O.BackupScope) { 'Complete' { $W.rbScopeComplete.IsChecked = $true } 'SelectedFolders' { $W.rbScopeSelected.IsChecked = $true } default { $W.rbScopeUserData.IsChecked = $true } }
    Update-UpbWpfFolderList -Selected $O.Folders
    $W.cmbDateFilter.SelectedItem = [string]$O.DateFilter
    $W.cmbDateField.SelectedItem = [string]$O.DateField
    Set-UpbWpfDateControls $W.dpDate $W.txtTime $O.Date
    Set-UpbWpfDateControls $W.dpStart $W.txtStartTime $O.StartDate
    Set-UpbWpfDateControls $W.dpEnd $W.txtEndTime $O.EndDate
    $W.txtBkDest.Text = [string]$O.Destination
    $W.chkBkVerify.IsChecked = [bool]$O.Verify
    $W.txtBkLog.Text = [string]$O.LogPath
    Update-UpbWpfDateUi
    Update-UpbWpfFreeSpace
}

# ---- Restore tab -----------------------------------------------------------

function Get-UpbWpfMappingText {
    param([string]$Name)
    $m = $script:W.RsMap[$Name]
    return ('{0}   ->   {1}' -f $Name, (Get-UpbMappingText $m))
}

function Update-UpbWpfBackupSets {
    $W = $script:W
    $W.cmbRsSets.Items.Clear()
    $roots = @()
    foreach ($c in @($W.Settings.Destination, $W.txtBkDest.Text.Trim())) { if ($c -and ($roots -notcontains $c)) { $roots += $c } }
    foreach ($root in $roots) {
        foreach ($s in (Find-UpbBackupSets -Root $root)) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = ('{0}   {1}   [{2}]   {3}' -f $s.Created.ToString('yyyy-MM-dd HH:mm'), $s.Name, $s.Status, $s.Profiles)
            $item.Tag = $s.Path
            [void]$W.cmbRsSets.Items.Add($item)
        }
    }
    if ($W.cmbRsSets.Items.Count -eq 0) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = '(none found - use Browse)'; $item.IsEnabled = $false
        [void]$W.cmbRsSets.Items.Add($item)
    }
}

function Import-UpbWpfManifest {
    param([string]$Path, [string[]]$Selected, $Mappings)
    $W = $script:W
    try {
        $info = Read-UpbBackupManifest -Path $Path
    } catch {
        $W.txtRsManifest.Text = 'ERROR: ' + (Get-UpbInnerException $_).Message
        $W.lstRsProfiles.Items.Clear()
        $W.ManifestInfo = $null
        return $false
    }
    $W.ManifestInfo = $info
    $W.txtRsPath.Text = $info.SetPath
    $W.txtRsManifest.Text = (Get-UpbManifestSummary $info) -join [Environment]::NewLine
    $W.RsMap = @{}
    $W.lstRsProfiles.Items.Clear()
    $profiles = @($info.Manifest.Profiles)
    foreach ($p in $profiles) {
        $m = $null
        foreach ($candidate in @($Mappings)) { if ($candidate -and (Find-UpbManifestProfile -Manifest $info.Manifest -Name $candidate.Profile) -eq $p) { $m = $candidate } }
        if ($m) { $W.RsMap[$p.AccountName] = @{ Profile = $p.AccountName; Target = $m.Target; Value = $m.Value } }
        else { $W.RsMap[$p.AccountName] = @{ Profile = $p.AccountName; Target = 'Original'; Value = $null } }
        $isSel = $profiles.Count -eq 1
        foreach ($s in @($Selected)) { if ($s -and (Find-UpbManifestProfile -Manifest $info.Manifest -Name $s) -eq $p) { $isSel = $true } }
        [void]$W.lstRsProfiles.Items.Add((New-UpbWpfCheckItem -Text (Get-UpbWpfMappingText $p.AccountName) -Tag $p.AccountName -Checked $isSel -ToolTip $p.ProfilePath))
    }
    if ($W.lstRsProfiles.Items.Count -gt 0) { $W.lstRsProfiles.SelectedIndex = 0 }
    return $true
}

function Update-UpbWpfMappingEditor {
    $W = $script:W
    $item = $W.lstRsProfiles.SelectedItem
    if (-not $item) { return }
    $m = $W.RsMap[[string]$item.Tag]
    switch ($m.Target) {
        'Profile' { $W.rbMapProfile.IsChecked = $true; $W.cmbMapProfile.Text = [string]$m.Value; $W.cmbMapProfile.SelectedItem = $null; foreach ($i in $W.cmbMapProfile.Items) { if ([string]$i -ieq [string]$m.Value) { $W.cmbMapProfile.SelectedItem = $i } } }
        'Folder' { $W.rbMapFolder.IsChecked = $true; $W.txtMapFolder.Text = [string]$m.Value }
        default { $W.rbMapOriginal.IsChecked = $true }
    }
}

function Get-UpbWpfRestoreOptions {
    $W = $script:W
    $o = Copy-UpbOptions $W.Options
    $o.Operation = 'Restore'
    $o.BackupPath = $W.txtRsPath.Text.Trim(); if (-not $o.BackupPath) { $o.BackupPath = $null }
    $selected = @($W.lstRsProfiles.Items | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    $o.RestoreProfiles = $selected
    $o.RestoreMappings = @(foreach ($n in $selected) { $m = $W.RsMap[$n]; $h = [ordered]@{ Profile = $n; Target = $m.Target }; if ($m.Target -ne 'Original') { $h.Value = $m.Value }; $h })
    $o.RestoreMapPath = $null
    $o.Sources['Destination'] = 'Default'
    $o.ConflictAction = [string]$W.cmbConflict.SelectedItem
    $o.Sources['ConflictAction'] = 'Interactive'
    $o.Verify = [bool]$W.chkRsVerify.IsChecked
    $o.LogPath = $W.txtRsLog.Text.Trim(); if (-not $o.LogPath) { $o.LogPath = $null }
    $o.WhatIf = $false
    $o.NonInteractive = $false
    $o.OverwriteConfirmed = $false
    return $o
}

function Set-UpbWpfRestoreFromOptions {
    param([System.Collections.IDictionary]$O)
    $W = $script:W
    $W.cmbConflict.SelectedItem = [string]$O.ConflictAction
    $W.chkRsVerify.IsChecked = [bool]$O.Verify
    $W.txtRsLog.Text = [string]$O.LogPath
    $mappings = @($O.RestoreMappings)
    if ($mappings.Count -eq 0 -and $O.RestoreMapPath) { try { $mappings = @(Import-UpbRestoreMap -Path $O.RestoreMapPath) } catch { Set-UpbWpfStatus ('Mapping file ignored: ' + (Get-UpbInnerException $_).Message) } }
    if ($mappings.Count -eq 0 -and $O.Destination -and ($O.Sources['Destination'] -eq 'Parameter' -or $O.Sources['Destination'] -eq 'Configuration') -and @($O.RestoreProfiles).Count -eq 1) {
        $mappings = @(@{ Profile = @($O.RestoreProfiles)[0]; Target = 'Folder'; Value = [string]$O.Destination })
    }
    if ($O.BackupPath) { [void](Import-UpbWpfManifest -Path $O.BackupPath -Selected $O.RestoreProfiles -Mappings $mappings) }
    else { $W.txtRsPath.Text = ''; $W.txtRsManifest.Text = 'Choose a backup set, then click Load manifest.'; $W.lstRsProfiles.Items.Clear(); $W.ManifestInfo = $null }
}

# ---- Configuration and settings tabs ---------------------------------------

function Get-UpbWpfConfigurationOptions {
    $W = $script:W
    $op = [string]$W.cmbCfgOperation.SelectedItem
    if ($op -eq 'Restore') { $o = Get-UpbWpfRestoreOptions } else { $o = Get-UpbWpfBackupOptions }
    $o.Operation = $op
    $o.Name = $W.txtCfgName.Text.Trim()
    $o.Description = $W.txtCfgDesc.Text.Trim()
    $o.Interface = [string]$W.cmbCfgInterface.SelectedItem
    return $o
}

function Update-UpbWpfConfigPreview {
    $W = $script:W
    try {
        $o = Get-UpbWpfConfigurationOptions
        $W.txtCfgJson.Text = (Get-UpbConfigurationPreviewLines $o) -join [Environment]::NewLine
        $errors = Test-UpbConfigurationData -Data (ConvertTo-UpbConfiguration -Options $o) -Kind Configuration
        if (-not $o.Name) { $errors = @($errors) + @('Give the configuration a name.') }
        if ($errors.Count -eq 0) { $W.txtCfgStatus.Text = 'Valid. Review the JSON on the right, then Save.'; $W.txtCfgStatus.Foreground = [System.Windows.Media.Brushes]::DarkGreen }
        else { $W.txtCfgStatus.Text = ($errors -join [Environment]::NewLine); $W.txtCfgStatus.Foreground = [System.Windows.Media.Brushes]::Firebrick }
        return ($errors.Count -eq 0)
    } catch {
        $W.txtCfgStatus.Text = (Get-UpbInnerException $_).Message
        $W.txtCfgStatus.Foreground = [System.Windows.Media.Brushes]::Firebrick
        return $false
    }
}

function Set-UpbWpfFromOptions {
    param([System.Collections.IDictionary]$O)
    $W = $script:W
    $W.Options = $O
    Set-UpbWpfBackupFromOptions $O
    Set-UpbWpfRestoreFromOptions $O
    $W.txtCfgName.Text = [string]$O.Name
    $W.txtCfgDesc.Text = [string]$O.Description
    if ($O.Operation) { $W.cmbCfgOperation.SelectedItem = [string]$O.Operation } else { $W.cmbCfgOperation.SelectedItem = 'Backup' }
    $W.cmbCfgInterface.SelectedItem = [string]$O.Interface
}

function Set-UpbWpfSettingsControls {
    param([System.Collections.IDictionary]$S)
    $W = $script:W
    $d = New-UpbDefaultOptions
    $get = { param($k) if ($S.Contains($k) -and $null -ne $S[$k] -and $S[$k] -ne '') { $S[$k] } else { $d[$k] } }
    $W.cmbSetInterface.SelectedItem = [string](& $get 'Interface')
    $W.txtSetDest.Text = [string](& $get 'Destination')
    $W.cmbSetScope.SelectedItem = [string](& $get 'BackupScope')
    $W.cmbSetDateField.SelectedItem = [string](& $get 'DateField')
    $W.cmbSetConflict.SelectedItem = [string](& $get 'ConflictAction')
    $W.chkSetVerify.IsChecked = [bool](& $get 'Verify')
    $W.txtSetLog.Text = [string](& $get 'LogPath')
    $W.chkSetSystem.IsChecked = [bool](& $get 'IncludeSystemProfiles')
    $folders = @(& $get 'Folders')
    $W.lstSetFolders.Items.Clear()
    foreach ($n in $script:UpbUserDataFolders) { [void]$W.lstSetFolders.Items.Add((New-UpbWpfCheckItem -Text $n -Tag $n -Checked ($folders -contains $n))) }
    $info = "Saved in $(Get-UpbSettingsPath). Precedence: built-in defaults < settings < configuration profile < command-line parameters. Default log folder: $(Get-UpbDefaultLogDirectory)."
    if ($script:UpbSettingsWarning) { $info += "`n$($script:UpbSettingsWarning)" }
    $W.txtSetInfo.Text = $info
}

function Get-UpbWpfSettingsFromControls {
    $W = $script:W
    $s = [ordered]@{ SchemaVersion = $script:UpbSettingsSchemaVersion }
    $s.Interface = [string]$W.cmbSetInterface.SelectedItem
    $dest = $W.txtSetDest.Text.Trim(); if ($dest) { $s.Destination = (ConvertTo-UpbFullPath $dest) }
    $s.BackupScope = [string]$W.cmbSetScope.SelectedItem
    $s.Folders = @($W.lstSetFolders.Items | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    $s.DateField = [string]$W.cmbSetDateField.SelectedItem
    $s.ConflictAction = [string]$W.cmbSetConflict.SelectedItem
    $s.Verify = [bool]$W.chkSetVerify.IsChecked
    $log = $W.txtSetLog.Text.Trim(); if ($log) { $s.LogPath = $log }
    $s.IncludeSystemProfiles = [bool]$W.chkSetSystem.IsChecked
    return $s
}

# ---- Running operations ----------------------------------------------------

function Set-UpbWpfRunning {
    param([bool]$Running)
    $W = $script:W
    $W.Running = $Running
    foreach ($n in 'btnBkStart', 'btnBkPreview', 'btnRsStart', 'btnRsPreview', 'btnCfgSave', 'btnSetSave') { $W[$n].IsEnabled = -not $Running }
    $W.btnCancel.IsEnabled = $Running
}

function Start-UpbWpfOperation {
    param([System.Collections.IDictionary]$Options)
    $W = $script:W
    if ($W.Running) { return }
    $state = New-UpbState
    $W.State = $state
    $W.MessageIndex = 0
    $W.LastResult = $null
    $W.txtPrLog.Clear()
    $W.txtPrResult.Text = ''
    $W.txtPrResult.Foreground = [System.Windows.Media.Brushes]::Black
    $W.btnOpenSet.IsEnabled = $false; $W.btnOpenLog.IsEnabled = $false
    $W.pbProgress.Value = 0
    $W.txtPrOperation.Text = '{0}{1}' -f $Options.Operation, $(if ($Options.WhatIf) { ' (preview - no changes)' } else { '' })
    $W.Tabs.SelectedItem = $W.TabProgress
    Set-UpbWpfRunning $true
    Set-UpbWpfStatus "$($Options.Operation) running..."

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            param($ScriptPath, $RunOptions, $RunState)
            . $ScriptPath
            if ($RunOptions.Operation -eq 'Backup') { Invoke-UpbBackup -Options $RunOptions -State $RunState }
            else { Invoke-UpbRestore -Options $RunOptions -State $RunState }
        }.ToString()).AddArgument($script:UpbScriptPath).AddArgument($Options).AddArgument($state)
    $W.Job = @{ PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke() }
    $W.Timer.Start()
}

function Update-UpbWpfProgress {
    $W = $script:W
    $s = $W.State
    if (-not $s) { return }
    $W.txtPrProfile.Text = [string]$s.Profile
    $W.txtPrFile.Text = [string]$s.CurrentFile
    $W.txtPrCounts.Text = ('{0:N0} of {1:N0} processed   (copied {2:N0}, skipped {3:N0}, failed {4:N0})   phase: {5}' -f $s.FilesDone, $s.FilesTotal, $s.FilesCopied, $s.FilesSkipped, $s.FilesFailed, $s.Phase)
    $W.txtPrBytes.Text = ('{0} of {1}' -f (Format-UpbBytes $s.BytesDone), (Format-UpbBytes $s.BytesTotal))
    $W.txtPrElapsed.Text = Format-UpbDuration ((Get-Date) - $s.Started)
    $W.pbProgress.Value = [double]$s.Percent
    $count = $s.Messages.Count
    if ($count -gt $W.MessageIndex) {
        $sb = New-Object Text.StringBuilder
        for ($i = $W.MessageIndex; $i -lt $count; $i++) { [void]$sb.AppendLine([string]$s.Messages[$i]) }
        $W.MessageIndex = $count
        $W.txtPrLog.AppendText($sb.ToString())
        $W.txtPrLog.ScrollToEnd()
    }
    if ($W.Job -and $W.Job.Handle.IsCompleted) {
        $W.Timer.Stop()
        $job = $W.Job; $W.Job = $null
        $errorText = $null
        try { [void]$job.PowerShell.EndInvoke($job.Handle) } catch { $errorText = (Get-UpbInnerException $_).Message }
        if ($job.PowerShell.Streams.Error.Count -gt 0 -and -not $s.Result) { $errorText = [string]$job.PowerShell.Streams.Error[0] }
        $job.PowerShell.Dispose(); $job.Runspace.Dispose()
        Set-UpbWpfRunning $false
        $result = $s.Result
        if (-not $result) {
            $W.txtPrResult.Text = "The operation failed to run: $errorText"
            $W.txtPrResult.Foreground = [System.Windows.Media.Brushes]::Firebrick
            $W.ExitCode = 2
            Set-UpbWpfStatus 'Failed.'
        } else {
            $W.LastResult = $result
            $W.ExitCode = $result.ExitCode
            $W.txtPrResult.Text = "$($result.Status) (exit code $($result.ExitCode)): $($result.Message)"
            $brush = switch ($result.ExitCode) { 0 { [System.Windows.Media.Brushes]::DarkGreen } 1 { [System.Windows.Media.Brushes]::DarkOrange } 3 { [System.Windows.Media.Brushes]::DarkOrange } default { [System.Windows.Media.Brushes]::Firebrick } }
            $W.txtPrResult.Foreground = $brush
            $W.btnOpenSet.IsEnabled = [bool]($result.BackupSetPath -and (Test-Path -LiteralPath $result.BackupSetPath))
            $W.btnOpenLog.IsEnabled = [bool]($result.LogPath -and (Test-Path -LiteralPath $result.LogPath))
            $W.pbProgress.Value = $(if ($result.ExitCode -eq 0) { 100 } else { $W.pbProgress.Value })
            Set-UpbWpfStatus "$($result.Operation): $($result.Status)."
            if ($W.CloseWhenDone) { $W.Window.Close(); return }
            $icon = 'Information'; if ($result.ExitCode -eq 1 -or $result.ExitCode -eq 3) { $icon = 'Warning' } elseif ($result.ExitCode -eq 2) { $icon = 'Error' }
            [void](Show-UpbWpfMessage -Text $result.Message -Caption "$($result.Operation): $($result.Status)" -Icon $icon)
        }
        if ($W.CloseWhenDone) { $W.Window.Close() }
    }
}

function Invoke-UpbWpfBackup {
    param([switch]$WhatIfMode, [switch]$SkipReview)
    $W = $script:W
    if (-not $W.DateValid) { [void](Show-UpbWpfMessage -Text $W.txtBoundaries.Text -Caption 'Date filter' -Icon 'Warning'); return }
    $o = Get-UpbWpfBackupOptions
    $W.Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $prep = Get-UpbBackupPreparation -Options $o -AllProfiles $W.AllProfiles
        $lines = Format-UpbBackupPreview -Preparation $prep -Options $o
    } catch {
        $W.Window.Cursor = $null
        [void](Show-UpbWpfMessage -Text (Get-UpbInnerException $_).Message -Caption 'Cannot start the backup' -Icon 'Warning')
        return
    } finally { $W.Window.Cursor = $null }
    $o.ResolvedDateFilter = $prep.Filter
    $o.WhatIf = [bool]$WhatIfMode
    if (-not $SkipReview) {
        $label = 'Start backup'; if ($WhatIfMode) { $label = 'Run preview' }
        if (-not (Show-UpbWpfReview -Title 'Review backup' -Intro 'The date boundaries below were evaluated now and will be used exactly as shown. Nothing is copied until you click the button.' -Lines $lines -OkLabel $label)) { return }
    }
    Start-UpbWpfOperation $o
}

function Invoke-UpbWpfRestore {
    param([switch]$WhatIfMode, [switch]$SkipReview, [switch]$Confirmed)
    $W = $script:W
    $o = Get-UpbWpfRestoreOptions
    if (-not $o.BackupPath) { [void](Show-UpbWpfMessage -Text 'Choose a backup set first.' -Caption 'Restore' -Icon 'Warning'); return }
    if (@($o.RestoreProfiles).Count -eq 0) { [void](Show-UpbWpfMessage -Text 'Tick at least one profile to restore.' -Caption 'Restore' -Icon 'Warning'); return }
    $o.OverwriteConfirmed = $true   # checked below before anything runs
    try {
        $info = $W.ManifestInfo
        if (-not $info -or $info.SetPath -ne (ConvertTo-UpbFullPath $o.BackupPath)) { $info = Read-UpbBackupManifest -Path $o.BackupPath }
        $plan = Get-UpbRestorePlan -Options $o -ManifestInfo $info -AllProfiles (Get-UpbUserProfiles -IncludeSystem)
        $lines = Format-UpbRestorePreview -Plan $plan -Options $o
    } catch {
        [void](Show-UpbWpfMessage -Text (Get-UpbInnerException $_).Message -Caption 'Cannot start the restore' -Icon 'Warning')
        return
    }
    $o.WhatIf = [bool]$WhatIfMode
    if (-not $SkipReview) {
        $label = 'Start restore'; if ($WhatIfMode) { $label = 'Run preview' }
        if (-not (Show-UpbWpfReview -Title 'Review restore' -Intro 'Check every source -> destination mapping. Files that exist only at the destination are never deleted.' -Lines $lines -OkLabel $label)) { return }
    }
    if ($o.ConflictAction -eq 'Overwrite' -and -not $WhatIfMode -and -not $Confirmed) {
        $answer = Show-UpbWpfMessage -Text "Existing files at the destinations will be REPLACED by the backed-up versions. This cannot be undone.`n`nOverwrite existing files?" -Caption 'Confirm overwrite' -Icon 'Warning' -Buttons 'YesNo'
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    Start-UpbWpfOperation $o
}

function Save-UpbWpfConfigurationFrom {
    param([string]$Operation)
    $W = $script:W
    $W.cmbCfgOperation.SelectedItem = $Operation
    if (-not $W.txtCfgName.Text.Trim()) { $W.txtCfgName.Text = "$Operation $(Get-Date -Format 'yyyy-MM-dd')" }
    $W.Tabs.SelectedItem = $W.TabConfig
    [void](Update-UpbWpfConfigPreview)
    Set-UpbWpfStatus 'Review the configuration, adjust the name, interface and file, then click Save.'
}

function Show-UpbWpfWindow {
    param([System.Collections.IDictionary]$Options, [switch]$AutoStart, [ValidateSet('Backup', 'Restore', 'Configuration', 'Settings')][string]$Page = 'Backup', [string]$ConfigurationOutputPath, [string]$ConfigurationPath)
    $problem = Test-UpbWpfAvailable
    if ($problem) { Write-Host "ERROR: $problem" -ForegroundColor Red; return 2 }
    $window = [Windows.Markup.XamlReader]::Parse($script:UpbWpfXaml)
    $W = @{ Window = $window; Options = $Options; Running = $false; ExitCode = 0; RsMap = @{}; ManifestInfo = $null; DateValid = $true; CloseWhenDone = $false; Settings = (Get-UpbSettings -Quiet); AllProfiles = @() }
    $script:W = $W
    foreach ($m in [regex]::Matches($script:UpbWpfXaml, 'x:Name="(\w+)"')) { $n = $m.Groups[1].Value; $W[$n] = $window.FindName($n) }

    $W.cmbDateFilter.ItemsSource = $script:UpbDateFilters
    $W.cmbDateField.ItemsSource = @('CreationTime', 'LastWriteTime')
    $W.cmbConflict.ItemsSource = @('Skip', 'Overwrite', 'KeepBoth')
    $W.cmbCfgOperation.ItemsSource = @('Backup', 'Restore')
    $W.cmbCfgInterface.ItemsSource = @('Console', 'WPF')
    $W.cmbSetInterface.ItemsSource = @('Console', 'WPF')
    $W.cmbSetScope.ItemsSource = @('Complete', 'UserData', 'SelectedFolders')
    $W.cmbSetDateField.ItemsSource = @('CreationTime', 'LastWriteTime')
    $W.cmbSetConflict.ItemsSource = @('Skip', 'Overwrite', 'KeepBoth')
    if (Test-UpbIsAdmin) { $W.txtBkElevation.Text = 'Running elevated: other users'' profiles can be read.' }
    else { $W.txtBkElevation.Text = 'Not elevated: backing up other users'' profiles usually needs "Run as administrator".'; $W.txtBkElevation.Foreground = [System.Windows.Media.Brushes]::DarkOrange }
    $W.Timer = New-Object System.Windows.Threading.DispatcherTimer
    $W.Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $W.Timer.Add_Tick({ Update-UpbWpfProgress })

    # Back up tab events.
    $W.btnBkRefresh.Add_Click({ Update-UpbWpfProfileList -Selected (Get-UpbWpfSelectedProfiles); Update-UpbWpfFolderList })
    $W.chkBkSystem.Add_Click({ Update-UpbWpfProfileList -Selected (Get-UpbWpfSelectedProfiles) })
    $W.btnBkAddProfile.Add_Click({
            $p = Select-UpbWpfFolder -Description 'Choose a profile folder (for example C:\Users\name)' -Initial 'C:\Users'
            if ($p) {
                $item = New-UpbWpfCheckItem -Text "$p   -   (added)" -Tag $p -Checked $true
                $item.Add_Click({ Update-UpbWpfFolderList })
                [void]$script:W.lstBkProfiles.Items.Add($item); Update-UpbWpfFolderList
            }
        })
    foreach ($rb in 'rbScopeComplete', 'rbScopeUserData', 'rbScopeSelected') { $W[$rb].Add_Checked({ $script:W.lstBkFolders.IsEnabled = [bool]$script:W.rbScopeSelected.IsChecked }) }
    $W.btnBkAddFolder.Add_Click({
            $p = Select-UpbWpfFolder -Description 'Choose a custom folder to back up' -Initial $env:USERPROFILE
            if ($p) { [void]$script:W.lstBkFolders.Items.Add((New-UpbWpfCheckItem -Text "$p   -   (custom)" -Tag $p -Checked $true)); $script:W.rbScopeSelected.IsChecked = $true }
        })
    $W.btnBkAddRelative.Add_Click({
            Add-Type -AssemblyName Microsoft.VisualBasic
            $rel = [Microsoft.VisualBasic.Interaction]::InputBox('Folder relative to each profile folder (for example Source\Repos). It is resolved separately inside every selected profile.', 'Add relative folder', '')
            if ($rel) { [void]$script:W.lstBkFolders.Items.Add((New-UpbWpfCheckItem -Text "$rel   -   (custom, relative to each profile)" -Tag $rel -Checked $true)); $script:W.rbScopeSelected.IsChecked = $true }
        })
    $W.btnBkRemoveFolder.Add_Click({
            $sel = $script:W.lstBkFolders.SelectedItem
            if ($sel -and $script:UpbUserDataFolders -notcontains [string]$sel.Tag) { $script:W.lstBkFolders.Items.Remove($sel) }
            else { Set-UpbWpfStatus 'Select a custom folder row to remove it. Standard folders can only be unticked.' }
        })
    $W.cmbDateFilter.Add_SelectionChanged({ Update-UpbWpfDateUi })
    $W.cmbDateField.Add_SelectionChanged({ Update-UpbWpfDateUi })
    foreach ($dp in 'dpDate', 'dpStart', 'dpEnd') { $W[$dp].Add_SelectedDateChanged({ Update-UpbWpfDateUi }) }
    foreach ($tb in 'txtTime', 'txtStartTime', 'txtEndTime') { $W[$tb].Add_TextChanged({ Update-UpbWpfDateUi }) }
    $W.txtBkDest.Add_LostFocus({ Update-UpbWpfFreeSpace })
    $W.btnBkBrowse.Add_Click({ $p = Select-UpbWpfFolder -Description 'Choose where to create the backup set (local folder, external drive or network share)' -Initial $script:W.txtBkDest.Text; if ($p) { $script:W.txtBkDest.Text = $p; Update-UpbWpfFreeSpace } })
    $W.btnBkLog.Add_Click({ $p = Select-UpbWpfFolder -Description 'Choose a folder for log files' -Initial $script:W.txtBkLog.Text; if ($p) { $script:W.txtBkLog.Text = $p } })
    $W.btnBkStart.Add_Click({ Invoke-UpbWpfBackup })
    $W.btnBkPreview.Add_Click({ Invoke-UpbWpfBackup -WhatIfMode })
    $W.btnBkSaveConfig.Add_Click({ Save-UpbWpfConfigurationFrom 'Backup' })

    # Restore tab events.
    $W.btnRsBrowse.Add_Click({
            $start = $script:W.txtRsPath.Text; if (-not $start) { $start = [string]$script:W.Settings.Destination }
            $p = Select-UpbWpfFolder -Description 'Choose a backup set folder (UPB_...)' -Initial $start
            if ($p) { $script:W.txtRsPath.Text = $p; [void](Import-UpbWpfManifest -Path $p) }
        })
    $W.btnRsLoad.Add_Click({ if ($script:W.txtRsPath.Text.Trim()) { [void](Import-UpbWpfManifest -Path $script:W.txtRsPath.Text.Trim()) } })
    $W.cmbRsSets.Add_SelectionChanged({ $i = $script:W.cmbRsSets.SelectedItem; if ($i -and $i.Tag) { $script:W.txtRsPath.Text = [string]$i.Tag; [void](Import-UpbWpfManifest -Path ([string]$i.Tag)) } })
    $W.lstRsProfiles.Add_SelectionChanged({ Update-UpbWpfMappingEditor })
    $W.btnMapBrowse.Add_Click({ $p = Select-UpbWpfFolder -Description 'Choose the folder to restore into' -Initial $script:W.txtMapFolder.Text; if ($p) { $script:W.txtMapFolder.Text = $p; $script:W.rbMapFolder.IsChecked = $true } })
    $W.btnMapApply.Add_Click({
            $item = $script:W.lstRsProfiles.SelectedItem
            if (-not $item) { Set-UpbWpfStatus 'Select a profile row first.'; return }
            $name = [string]$item.Tag
            if ($script:W.rbMapProfile.IsChecked) {
                $target = [string]$script:W.cmbMapProfile.Text
                if (-not $target) { [void](Show-UpbWpfMessage -Text 'Choose the target profile.' -Icon 'Warning'); return }
                $script:W.RsMap[$name] = @{ Profile = $name; Target = 'Profile'; Value = $target }
            } elseif ($script:W.rbMapFolder.IsChecked) {
                $folder = $script:W.txtMapFolder.Text.Trim()
                if (-not $folder -or -not [IO.Path]::IsPathRooted($folder)) { [void](Show-UpbWpfMessage -Text 'Enter an absolute folder path.' -Icon 'Warning'); return }
                $script:W.RsMap[$name] = @{ Profile = $name; Target = 'Folder'; Value = (ConvertTo-UpbFullPath $folder) }
            } else { $script:W.RsMap[$name] = @{ Profile = $name; Target = 'Original'; Value = $null } }
            Set-UpbWpfCheckText $item (Get-UpbWpfMappingText $name)
            $item.IsChecked = $true
            Set-UpbWpfStatus "Destination for $name updated."
        })
    $W.btnRsLoadMap.Add_Click({
            if (-not $script:W.ManifestInfo) { [void](Show-UpbWpfMessage -Text 'Load a backup set first.' -Icon 'Warning'); return }
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'Restore map (*.json)|*.json|All files (*.*)|*.*'
            if ($dlg.ShowDialog($script:W.Window)) {
                try {
                    $maps = Import-UpbRestoreMap -Path $dlg.FileName
                    $names = @($maps | ForEach-Object { $_.Profile })
                    [void](Import-UpbWpfManifest -Path $script:W.ManifestInfo.SetPath -Selected $names -Mappings $maps)
                    Set-UpbWpfStatus "Mappings loaded from $($dlg.FileName)."
                } catch { [void](Show-UpbWpfMessage -Text (Get-UpbInnerException $_).Message -Caption 'Restore map' -Icon 'Warning') }
            }
        })
    $W.cmbConflict.Add_SelectionChanged({
            $script:W.txtConflictHelp.Text = switch ([string]$script:W.cmbConflict.SelectedItem) {
                'Skip' { 'Existing files are left unchanged.' }
                'Overwrite' { 'Existing files are replaced (you will be asked to confirm).' }
                'KeepBoth' { 'Restored copies get a unique name, e.g. "report (2).docx".' }
            }
        })
    $W.btnRsStart.Add_Click({ Invoke-UpbWpfRestore })
    $W.btnRsPreview.Add_Click({ Invoke-UpbWpfRestore -WhatIfMode })
    $W.btnRsSaveConfig.Add_Click({ Save-UpbWpfConfigurationFrom 'Restore' })

    # Configuration tab events.
    $W.Tabs.Add_SelectionChanged({ param($sender, $e) if ($e.OriginalSource -eq $script:W.Tabs -and $script:W.Tabs.SelectedItem -eq $script:W.TabConfig) { [void](Update-UpbWpfConfigPreview) } })
    $W.cmbCfgOperation.Add_SelectionChanged({ [void](Update-UpbWpfConfigPreview) })
    $W.cmbCfgInterface.Add_SelectionChanged({ [void](Update-UpbWpfConfigPreview) })
    $W.txtCfgName.Add_LostFocus({ [void](Update-UpbWpfConfigPreview) })
    $W.btnCfgRefresh.Add_Click({ [void](Update-UpbWpfConfigPreview) })
    $W.btnCfgValidate.Add_Click({ if (Update-UpbWpfConfigPreview) { [void](Show-UpbWpfMessage -Text 'The configuration is valid.' -Caption 'Validate') } else { [void](Show-UpbWpfMessage -Text $script:W.txtCfgStatus.Text -Caption 'Validate' -Icon 'Warning') } })
    $W.btnCfgNew.Add_Click({
            $o = Get-UpbEffectiveOptions -Bound @{} -AppSettings (Get-UpbSettings -Quiet) -Configuration $null
            Set-UpbWpfFromOptions $o
            $script:W.txtCfgPath.Text = ''
            [void](Update-UpbWpfConfigPreview)
            Set-UpbWpfStatus 'New configuration: fill in the Back up or Restore tab, then name and save it here.'
        })
    $W.btnCfgBrowse.Add_Click({
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Filter = 'Configuration (*.json)|*.json'
            $dlg.InitialDirectory = Get-UpbConfigurationDirectory
            if (-not (Test-Path -LiteralPath $dlg.InitialDirectory)) { [void][IO.Directory]::CreateDirectory($dlg.InitialDirectory) }
            $dlg.FileName = (Get-UpbSafeName $(if ($script:W.txtCfgName.Text) { $script:W.txtCfgName.Text } else { 'Configuration' })) + '.json'
            if ($dlg.ShowDialog($script:W.Window)) { $script:W.txtCfgPath.Text = $dlg.FileName }
        })
    $W.btnCfgOpen.Add_Click({
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'Configuration (*.json)|*.json|All files (*.*)|*.*'
            $dir = Get-UpbConfigurationDirectory; if (Test-Path -LiteralPath $dir) { $dlg.InitialDirectory = $dir }
            if ($dlg.ShowDialog($script:W.Window)) {
                try {
                    $cfg = Import-UpbConfiguration -Path $dlg.FileName
                    $o = Get-UpbEffectiveOptions -Bound @{} -AppSettings (Get-UpbSettings -Quiet) -Configuration $cfg
                    Set-UpbWpfFromOptions $o
                    $script:W.txtCfgPath.Text = $cfg['__Path']
                    [void](Update-UpbWpfConfigPreview)
                    Set-UpbWpfStatus "Loaded $($cfg['__Path']). Its values are now in the Back up and Restore tabs."
                } catch { [void](Show-UpbWpfMessage -Text (Get-UpbInnerException $_).Message -Caption 'Open configuration' -Icon 'Warning') }
            }
        })
    $W.btnCfgSave.Add_Click({
            if (-not (Update-UpbWpfConfigPreview)) { [void](Show-UpbWpfMessage -Text $script:W.txtCfgStatus.Text -Caption 'The configuration is not valid' -Icon 'Warning'); return }
            $o = Get-UpbWpfConfigurationOptions
            $path = $script:W.txtCfgPath.Text.Trim()
            if (-not $path) { $path = Get-UpbDefaultConfigurationPath $o.Name; $script:W.txtCfgPath.Text = $path }
            if ((Test-Path -LiteralPath $path) -and $script:W.LastSavedConfig -ne $path) {
                if ((Show-UpbWpfMessage -Text "'$path' already exists. Replace it?" -Caption 'Save configuration' -Icon 'Question' -Buttons 'YesNo') -ne [System.Windows.MessageBoxResult]::Yes) { return }
            }
            try {
                $saved = Export-UpbConfiguration -Options $o -Path $path
                $script:W.LastSavedConfig = $saved
                $script:W.txtCfgStatus.Text = "Saved to $saved"
                Set-UpbWpfStatus "Configuration saved to $saved"
            } catch { [void](Show-UpbWpfMessage -Text (Get-UpbInnerException $_).Message -Caption 'Save configuration' -Icon 'Warning') }
        })

    # Settings tab events.
    $W.btnSetDest.Add_Click({ $p = Select-UpbWpfFolder -Description 'Default backup destination' -Initial $script:W.txtSetDest.Text; if ($p) { $script:W.txtSetDest.Text = $p } })
    $W.btnSetLog.Add_Click({ $p = Select-UpbWpfFolder -Description 'Folder for log files' -Initial $script:W.txtSetLog.Text; if ($p) { $script:W.txtSetLog.Text = $p } })
    $W.btnSetReload.Add_Click({ $script:W.Settings = Get-UpbSettings -Quiet; Set-UpbWpfSettingsControls $script:W.Settings; Set-UpbWpfStatus 'Settings reloaded.' })
    $W.btnSetDefaults.Add_Click({ Set-UpbWpfSettingsControls ([ordered]@{ SchemaVersion = 1 }); Set-UpbWpfStatus 'Built-in defaults shown. Click Save settings to keep them.' })
    $W.btnSetSave.Add_Click({
            try {
                $s = Get-UpbWpfSettingsFromControls
                $path = Save-UpbSettings $s
                $script:W.Settings = Get-UpbSettings -Quiet
                Set-UpbWpfStatus "Settings saved to $path. They apply to new operations and the next start."
                [void](Show-UpbWpfMessage -Text "Settings saved to:`n$path" -Caption 'Settings')
            } catch { [void](Show-UpbWpfMessage -Text (Get-UpbInnerException $_).Message -Caption 'Settings' -Icon 'Warning') }
        })

    # Progress tab events.
    $W.btnCancel.Add_Click({
            if ($script:W.State -and -not $script:W.State.CancelRequested) {
                $script:W.State.CancelRequested = $true
                $script:W.btnCancel.IsEnabled = $false
                Set-UpbWpfStatus 'Cancel requested; stopping after the current file...'
            }
        })
    $W.btnOpenSet.Add_Click({ if ($script:W.LastResult.BackupSetPath) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:W.LastResult.BackupSetPath) } })
    $W.btnOpenLog.Add_Click({ if ($script:W.LastResult.LogPath) { Start-Process notepad.exe -ArgumentList ('"{0}"' -f $script:W.LastResult.LogPath) } })

    $window.Add_Closing({
            param($sender, $e)
            if ($script:W.Running) {
                $answer = Show-UpbWpfMessage -Text 'An operation is running. Cancel it and close when it stops?' -Caption 'UserProfileBackup' -Icon 'Question' -Buttons 'YesNo'
                $e.Cancel = $true
                if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { $script:W.State.CancelRequested = $true; $script:W.CloseWhenDone = $true }
            }
        })

    # Initial values.
    $W.cmbProfileItems = $null
    Set-UpbWpfFromOptions $Options
    $W.cmbMapProfile.IsEditable = $true
    $W.cmbMapProfile.ItemsSource = @(Get-UpbUserProfiles | ForEach-Object { $_.AccountName })
    Set-UpbWpfSettingsControls $W.Settings
    Update-UpbWpfBackupSets
    if ($ConfigurationPath) { $W.txtCfgPath.Text = $ConfigurationPath }
    if ($ConfigurationOutputPath) { $W.txtCfgPath.Text = (ConvertTo-UpbFullPath $ConfigurationOutputPath) }
    switch ($Page) {
        'Restore' { $W.Tabs.SelectedItem = $W.TabRestore }
        'Configuration' { $W.Tabs.SelectedItem = $W.TabConfig }
        'Settings' { $W.Tabs.SelectedItem = $W.TabSettings }
        default { if ($Options.Operation -eq 'Restore') { $W.Tabs.SelectedItem = $W.TabRestore } else { $W.Tabs.SelectedItem = $W.TabBackup } }
    }
    if ($script:UpbSettingsWarning) { Set-UpbWpfStatus $script:UpbSettingsWarning }
    $W.AutoStart = [bool]$AutoStart
    $window.Add_ContentRendered({
            # Automated UI tests set $script:UpbWpfTestHook to drive the window.
            if ($script:UpbWpfTestHook) { & $script:UpbWpfTestHook $script:W }
            if ($env:UPB_WPF_SMOKE_CLOSE -eq '1') { $script:W.ExitCode = 0; $script:W.Window.Close(); return }
            if ($script:W.AutoStart) {
                $script:W.AutoStart = $false
                if ($script:W.Options.Operation -eq 'Restore') { Invoke-UpbWpfRestore -WhatIfMode:([bool]$script:W.Options.WhatIf) -SkipReview }
                else { Invoke-UpbWpfBackup -WhatIfMode:([bool]$script:W.Options.WhatIf) -SkipReview }
            }
        })
    [void]$window.ShowDialog()
    return [int]$W.ExitCode
}

# Starts the window on an STA thread when the current thread cannot host WPF.
function Start-UpbWpf {
    param([System.Collections.IDictionary]$Options, [switch]$AutoStart, [string]$Page = 'Backup', [string]$ConfigurationOutputPath, [string]$ConfigurationPath)
    $problem = Test-UpbWpfAvailable
    if ($problem) { Write-Host "ERROR: $problem" -ForegroundColor Red; return 2 }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA) {
        return (Show-UpbWpfWindow -Options $Options -AutoStart:$AutoStart -Page $Page -ConfigurationOutputPath $ConfigurationOutputPath -ConfigurationPath $ConfigurationPath)
    }
    if (-not $script:UpbScriptPath) { Write-Host 'ERROR: WPF needs an STA thread. Start PowerShell with -STA, or run the script from a file.' -ForegroundColor Red; return 2 }
    Write-Verbose 'The current thread is MTA; starting the window on a dedicated STA thread.'
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
    $rs = [runspacefactory]::CreateRunspace($Host, $iss)
    $rs.ApartmentState = [Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    try {
        [void]$ps.AddScript({
                param($ScriptPath, $WinOptions, $WinAutoStart, $WinPage, $WinOutput, $WinConfig)
                . $ScriptPath
                Show-UpbWpfWindow -Options $WinOptions -AutoStart:$WinAutoStart -Page $WinPage -ConfigurationOutputPath $WinOutput -ConfigurationPath $WinConfig
            }.ToString()).AddArgument($script:UpbScriptPath).AddArgument($Options).AddArgument([bool]$AutoStart).AddArgument($Page).AddArgument($ConfigurationOutputPath).AddArgument($ConfigurationPath)
        $out = $ps.Invoke()
        foreach ($e in $ps.Streams.Error) { Write-Host "ERROR: $e" -ForegroundColor Red }
        $code = $out | Where-Object { $_ -is [int] } | Select-Object -Last 1
        if ($null -eq $code) { return 2 }
        return [int]$code
    } finally { $ps.Dispose(); $rs.Dispose() }
}

#endregion

#region Entry point

function Test-UpbOperationReady {
    param([System.Collections.IDictionary]$Options)
    if ($Options.Operation -eq 'Backup') { return ((Test-UpbBackupOptions $Options).Count -eq 0) }
    if ($Options.Operation -eq 'Restore') {
        if (-not $Options.BackupPath) { return $false }
        if (@($Options.RestoreProfiles).Count -gt 0) { return $true }
        try { return (@((Read-UpbBackupManifest -Path $Options.BackupPath).Manifest.Profiles).Count -eq 1) } catch { return $false }
    }
    return $false
}

function Write-UpbErrorLines {
    param([string[]]$Lines)
    foreach ($l in $Lines) { Write-Host "ERROR: $l" -ForegroundColor Red }
}

function Invoke-UpbMain {
    param([System.Collections.IDictionary]$Bound, [string]$ParameterSetName, [bool]$WhatIfRequested)
    $ErrorActionPreference = 'Stop'
    try {
        $errors = Test-UpbParameterCombination $Bound
        if ($errors.Count -gt 0) { Write-UpbErrorLines $errors; return 2 }

        $appSettings = Get-UpbSettings
        $configuration = $null
        if ($Bound.ContainsKey('ConfigurationPath')) { $configuration = Import-UpbConfiguration -Path $Bound['ConfigurationPath'] }
        $options = Get-UpbEffectiveOptions -Bound $Bound -AppSettings $appSettings -Configuration $configuration
        $options.WhatIf = $WhatIfRequested
        $options.NonInteractive = [bool]$Bound['NonInteractive']

        # Re-check parameter combinations against the operation that came from the configuration.
        if ($options.Operation -and -not $Bound.ContainsKey('Operation') -and $ParameterSetName -eq 'Run') {
            $effective = @{} + $Bound
            $effective['Operation'] = $options.Operation
            $errors = Test-UpbParameterCombination $effective
            if ($errors.Count -gt 0) { Write-UpbErrorLines ($errors | ForEach-Object { "$_ (the configuration's operation is $($options.Operation))" }); return 2 }
        }

        $interface = $options.Interface
        if (-not $interface) { $interface = 'Console' }

        if ($ParameterSetName -eq 'Settings') {
            if ($interface -eq 'WPF') { return (Start-UpbWpf -Options $options -Page 'Settings') }
            return (Start-UpbConsole -Options $options -Bound $Bound -Configuration $configuration -Page Settings)
        }
        if ($ParameterSetName -eq 'NewConfiguration') {
            if ($interface -eq 'WPF') {
                $cfgPath = $null; if ($configuration) { $cfgPath = $configuration['__Path'] }
                return (Start-UpbWpf -Options $options -Page 'Configuration' -ConfigurationOutputPath $Bound['ConfigurationOutputPath'] -ConfigurationPath $cfgPath)
            }
            return (Start-UpbConsole -Options $options -Bound $Bound -Configuration $configuration -Page NewConfiguration -ConfigurationOutputPath $Bound['ConfigurationOutputPath'])
        }

        if ($options.NonInteractive) {
            if ($Bound['Interface'] -eq 'WPF') { Write-UpbErrorLines @('-NonInteractive cannot be combined with -Interface WPF.'); return 2 }
            if (-not $options.Operation) { Write-UpbErrorLines @('-NonInteractive needs an operation: use -Operation Backup|Restore or a configuration profile that sets Operation.'); return 2 }
            if ($options.Operation -eq 'Backup') { $missing = Test-UpbBackupOptions $options } else { $missing = Test-UpbRestoreOptions $options }
            if ($missing.Count -gt 0) { Write-UpbErrorLines $missing; return 2 }
            $result = Invoke-UpbConsoleRun -Options $options
            return [int]$result.ExitCode
        }

        $ready = $false
        if ($options.Operation) { $ready = Test-UpbOperationReady $options }
        $runNow = $ready -and $Bound.ContainsKey('Operation')
        if ($interface -eq 'WPF') {
            $page = 'Backup'; if ($options.Operation -eq 'Restore') { $page = 'Restore' }
            return (Start-UpbWpf -Options $options -AutoStart:$runNow -Page $page)
        }
        return (Start-UpbConsole -Options $options -Bound $Bound -Configuration $configuration -AutoRun:$runNow)
    } catch {
        $inner = Get-UpbInnerException $_
        if ($inner -is [UpbValidationException]) { Write-UpbErrorLines @($inner.Message -split "`r?`n") }
        else {
            Write-UpbErrorLines @("Unexpected error: $($inner.Message)")
            Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        }
        return 2
    } finally {
        Close-UpbLog
    }
}

#endregion

if ($MyInvocation.InvocationName -ne '.') {
    $upbWhatIf = [bool]$WhatIfPreference
    $WhatIfPreference = $false
    $upbExitCode = Invoke-UpbMain -Bound $PSBoundParameters -ParameterSetName $PSCmdlet.ParameterSetName -WhatIfRequested $upbWhatIf
    $upbExitCode = @($upbExitCode | Where-Object { $_ -is [int] }) | Select-Object -Last 1
    if ($null -eq $upbExitCode) { $upbExitCode = 2 }
    exit $upbExitCode
}
