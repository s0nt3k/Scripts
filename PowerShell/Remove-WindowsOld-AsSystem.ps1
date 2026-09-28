#Requires -Version 5.1
# Permanently removes C:\Windows.old after an explicit confirmation.
$ErrorActionPreference = 'Stop'
$target = 'C:\Windows.old'

function Invoke-Native {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -ne 'S-1-5-18') {
    Write-Warning 'This script must run as NT AUTHORITY\SYSTEM. Relaunch it from a trusted SYSTEM PowerShell session.'
    exit 1
}

if (-not [System.IO.Directory]::Exists($target)) {
    Write-Host "$target was not found. Nothing to remove."
    exit 0
}

# Refuse to operate on a substituted top-level directory.
$rootItem = Get-Item -LiteralPath $target -Force
if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "$target is a reparse point; refusing to follow it."
}

Write-Host "Located $target. Measuring its contents; this can take a while..."
$bytes = [long]0
$count = [long]0
$pending = New-Object 'System.Collections.Generic.Stack[string]'
$pending.Push($target)
while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($directory)) {
        $attributes = [System.IO.File]::GetAttributes($entry)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            $pending.Push($entry)
        } else {
            $bytes += (New-Object System.IO.FileInfo($entry)).Length
            $count++
        }
    }
}
$size = '{0:N2} GiB ({1:N0} bytes across {2:N0} files)' -f ($bytes / 1GB), $bytes, $count
Write-Host "$target uses approximately $size. Directory entries and links are excluded."
$answer = Read-Host 'Permanently delete C:\Windows.old and everything inside it? Type DELETE to confirm'
if ($answer -cne 'DELETE') {
    Write-Host 'Cancelled. No files were deleted.'
    exit 0
}

# Windows.old often contains files owned by TrustedInstaller and read-only files.
# /XJ keeps robocopy from following junctions outside the target tree.
$empty = Join-Path $env:TEMP ('WindowsOld-Empty-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $empty | Out-Null
try {
    Invoke-Native 'takeown.exe' @('/F', $target, '/A', '/R', '/D', 'Y')
    Invoke-Native 'icacls.exe' @($target, '/grant', '*S-1-5-18:(OI)(CI)F', '/T', '/C', '/L')
    & attrib.exe -R -S -H "$target\*" /S /D | Out-Host
    $mirrorArgs = @($empty, $target, '/MIR', '/XJ', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS')
    & robocopy.exe @mirrorArgs | Out-Host
    if ($LASTEXITCODE -ge 8) { throw "Robocopy failed with exit code $LASTEXITCODE." }
    & cmd.exe /d /c 'rmdir /s /q "C:\Windows.old"'
    if ($LASTEXITCODE -ne 0 -or [IO.Directory]::Exists($target)) {
        throw "Removal is incomplete. Check remaining files in $target for open handles or access errors."
    }
    Write-Host "$target was permanently removed."
} finally {
    Remove-Item -LiteralPath $empty -Force -Recurse -ErrorAction SilentlyContinue
}
