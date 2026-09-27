# Run from an elevated Windows PowerShell session.
# Permanently deletes ONLY C:\Windows.old. This also removes the ability to
# roll back using that installation and any personal files left in that folder.
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'
$target = 'C:\Windows.old'

if ([System.IO.Path]::GetPathRoot($env:SystemRoot) -ne 'C:\') {
    throw 'The active Windows installation is not on C:. Review the target before deleting anything.'
}
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator, then run this script again.'
}

$folder = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
if ($null -eq $folder) { Write-Host "$target does not exist. Nothing to delete."; return }
if (-not $folder.PSIsContainer -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'The target is not an ordinary directory. Refusing to follow a link or mount point.'
}

if (-not $PSCmdlet.ShouldProcess($target, 'Permanently delete previous Windows installation and all contents')) { return }

Write-Host 'Taking ownership and granting the local Administrators group full control...'
& takeown.exe /F $target /A /R /D Y | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "takeown reported exit code $LASTEXITCODE; attempting the next step." }
& icacls.exe $target /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "icacls reported exit code $LASTEXITCODE; attempting deletion." }

Write-Host 'Clearing read-only, hidden, and system attributes...'
& attrib.exe -R -H -S $target /S /D 2>$null | Out-Null

Write-Host 'Deleting Windows.old (this can take several minutes)...'
# cmd's rd handles legacy Windows.old junctions better than Windows PowerShell 5.1.
& cmd.exe /d /c 'rd /s /q "C:\Windows.old"'
$deleteExitCode = $LASTEXITCODE

if (Test-Path -LiteralPath $target) {
    throw "Deletion incomplete (exit code $deleteExitCode). A file may be open or protected. Restart Windows and run the script again; if it remains locked, delete it from Windows Recovery Environment."
}
Write-Host 'C:\Windows.old was permanently deleted.' -ForegroundColor Green
