function Start-LatestScriptAsAdmin {
    <#
    .SYNOPSIS
        Finds and runs the most recently modified .ps1 script in the current directory as Admin.
    #>
    
    # 1. Locate the latest script in the script's root directory
    $latestScript = Get-ChildItem -Path $PSScriptRoot -Filter "*.ps1" | 
                    Sort-Object LastWriteTime -Descending | 
                    Select-Object -First 1

    if ($null -eq $latestScript) {
        Write-Warning "No PowerShell scripts found in $PSScriptRoot"
        return
    }

    Write-Host "Launching: $($latestScript.Name) with elevated privileges..." -ForegroundColor Cyan

    # 2. Build the arguments for a new PowerShell process
    # -File specifies the path, -ExecutionPolicy Bypass ensures it runs
    $processArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$($latestScript.FullName)`""

    # 3. Start the process with the 'runas' verb for Admin elevation
    try {
        Start-Process "pwsh.exe" -ArgumentList $processArgs -Verb RunAs -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to start process. This usually happens if the UAC prompt was declined."
    }
}

Start-LatestScriptAsAdmin