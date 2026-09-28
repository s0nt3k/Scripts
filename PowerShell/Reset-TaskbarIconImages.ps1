# Rebuild the icon cache for the signed-in user without changing taskbar pins.
# Run from an ordinary PowerShell window in the affected user's desktop session.

$ErrorActionPreference = 'Stop'

if (-not [Environment]::UserInteractive -or [Environment]::GetEnvironmentVariable('USERNAME') -eq 'SYSTEM') {
    throw 'Sign in as the affected user and run this script in that desktop session, not as SYSTEM.'
}

$cacheDirectory = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
$legacyCache = Join-Path $env:LOCALAPPDATA 'IconCache.db'
$sessionId = (Get-Process -Id $PID).SessionId
$explorerPath = Join-Path $env:WINDIR 'explorer.exe'

Write-Host 'This will briefly close File Explorer windows and hide the taskbar.'
Write-Host 'Save work in open File Explorer windows before continuing.'
$answer = Read-Host 'Rebuild icon images now? (Y/N)'
if ($answer -notmatch '^(?i:y|yes)$') {
    Write-Host 'Canceled.'
    return
}

$removed = 0
$failed = @()

try {
    # Only stop Explorer instances in the current desktop session.
    Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Where-Object SessionId -EQ $sessionId |
        Stop-Process -Force -ErrorAction Stop

    Start-Sleep -Milliseconds 800

    $cacheFiles = @()
    if (Test-Path -LiteralPath $cacheDirectory) {
        $cacheFiles += @(Get-ChildItem -LiteralPath $cacheDirectory -Filter 'iconcache*' -File -Force)
    }
    if (Test-Path -LiteralPath $legacyCache) {
        $cacheFiles += @(Get-Item -LiteralPath $legacyCache -Force)
    }

    foreach ($file in $cacheFiles) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $removed++
        }
        catch {
            $failed += "${file}: $($_.Exception.Message)"
        }
    }
}
finally {
    # Restore the desktop and taskbar even if clearing a cache file fails.
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Where-Object SessionId -EQ $sessionId)) {
        Start-Process -FilePath $explorerPath
    }
}

Write-Host "Removed $removed icon cache file(s). Windows will recreate them."
if ($failed.Count) {
    Write-Warning "Could not remove $($failed.Count) file(s):"
    $failed | ForEach-Object { Write-Warning $_ }
    Write-Host 'Restart Windows and run the script again if icons are still incorrect.'
}
else {
    Write-Host 'Done. If an icon is still blank, restart Windows once.'
}
