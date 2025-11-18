<# 
    Backup-Drivers.ps1
    Creates a backup of the current system's drivers and stores
    them in a single compressed file in C:\xTekFolder\Backups\
    Requires: PowerShell 5.1, Administrator privileges
#>

# --- Verify script is running as Administrator ---
$windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$windowsPrincipal = New-Object Security.Principal.WindowsPrincipal($windowsIdentity)
$adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator

if (-not $windowsPrincipal.IsInRole($adminRole)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell and choose 'Run as administrator', then run this script again."
    exit 1
}

# --- Define paths ---
$backupRoot = 'C:\xTekFolder\Backups'
$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$tempExportFolder = Join-Path $backupRoot "DriverExport_$timestamp"
$zipPath    = Join-Path $backupRoot "DriverBackup_$timestamp.zip"

try {
    # Ensure root backup folder exists
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        Write-Host "Creating backup folder at $backupRoot ..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    }

    # Create temporary export folder
    if (-not (Test-Path -LiteralPath $tempExportFolder)) {
        New-Item -ItemType Directory -Path $tempExportFolder -Force | Out-Null
    }

    Write-Host "Exporting installed drivers to: $tempExportFolder" -ForegroundColor Cyan

    # Export drivers from the current (online) Windows installation
    # Uses the DISM / Export-WindowsDriver cmdlet (available on Windows 8/10/11)
    Export-WindowsDriver -Online -Destination $tempExportFolder -ErrorAction Stop

    Write-Host "Driver export completed. Compressing to archive..." -ForegroundColor Cyan

    # Compress all exported drivers into a single ZIP
    if (Test-Path -LiteralPath $zipPath) {
        # Overwrite existing file with same name, if any
        Remove-Item -LiteralPath $zipPath -Force
    }

    Compress-Archive -Path (Join-Path $tempExportFolder '*') -DestinationPath $zipPath -Force

    Write-Host "Driver backup created successfully:" -ForegroundColor Green
    Write-Host "  $zipPath"

}
catch {
    Write-Host "ERROR during driver backup: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    # Optional: clean up temporary folder after compression
    if (Test-Path -LiteralPath $tempExportFolder) {
        try {
            Remove-Item -LiteralPath $tempExportFolder -Recurse -Force
            Write-Host "Cleaned up temporary folder: $tempExportFolder" -ForegroundColor DarkGray
        }
        catch {
            Write-Host "Could not remove temporary folder: $tempExportFolder" -ForegroundColor Yellow
        }
    }
}
