function Ensure-DirectoryExists {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Directory
    )

    if (-Not (Test-Path -Path $Directory -PathType Container)) {
        try {
            New-Item -Path $Directory -ItemType Directory -Force | Out-Null
            Write-Host "Directory created: $Directory"
        }
        catch {
            Write-Error "Failed to create directory: $_"
        }
    }
    else {
        Write-Host "Directory already exists: $Directory"
    }
}

function Download-File {
    param (
        [Parameter(Mandatory = $true)]
        [string]$URL,

        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )

    try {
        Invoke-WebRequest -Uri $URL -OutFile $OutFile -ErrorAction Stop
        Write-Host "File downloaded successfully to: $OutFile"
    }
    catch {
        Write-Error "Failed to download file: $_"
    }
}


Ensure-DirectoryExists -Directory "C:\MyFolder\"

Set-Location -Path "C:\MyFolder\"

Download-File -URL "https://github.com/rustdesk/rustdesk/releases/download/1.4.0/rustdesk-1.4.0-x86_64.exe" -OutFile "C:\MyFolder\rustdesk-host=remote.mynetworkroute.com,key=nWuGGYW2L7HYEkosrJy9MqdooAtBCw6KSxHLmq7GhLU=.exe"

Start-Process "C:\MyFolder\rustdesk-host=remote.mynetworkroute.co
