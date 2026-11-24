
<#
.SYNOPSIS
    Downloads and plays zehner.mp4 from GitHub.

.DESCRIPTION
    Downloads the MP4 file from the s0nt3k/Scripts
    GitHub repository and opens it using the
    default Windows video player.

.NOTES
    File Name : Play-ZehnerVideo.ps1
    Version   : 1.0.0
    Platform  : Windows 10 / Windows 11
    Requires  : PowerShell 5.1 or later
    Author    : Sontek Solutions
#>

$ErrorActionPreference = 'Stop'

# GitHub raw video URL
$VideoURL = 'https://raw.githubusercontent.com/s0nt3k/Scripts/main/Assets/Images/zehner.mp4'

# Temporary download location
$VideoPath = Join-Path $env:TEMP 'zehner.mp4'

try {
    Write-Host "Downloading video from GitHub..." -ForegroundColor Cyan

    # Enable TLS 1.2 for Windows PowerShell
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Download video
    Invoke-WebRequest `
        -Uri $VideoURL `
        -OutFile $VideoPath `
        -UseBasicParsing

    # Verify download
    if (-not (Test-Path -LiteralPath $VideoPath)) {
        throw "Video download failed."
    }

    if ((Get-Item -LiteralPath $VideoPath).Length -eq 0) {
        throw "Downloaded video is empty."
    }

    Write-Host "Download completed successfully." -ForegroundColor Green
    Write-Host "Launching video player..." -ForegroundColor Cyan

    # Play video using default Windows application
    Start-Process -FilePath $VideoPath
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
