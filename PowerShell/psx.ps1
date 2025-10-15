<#
.SYNOPSIS
Download PsExec and open an interactive PowerShell window as SYSTEM that displays a yellow warning message.

.DESCRIPTION
- Elevates if needed.
- Downloads PsExec from https://live.sysinternals.com/psexec.exe to $env:TEMP.
- Writes a small PowerShell script to C:\ProgramData\psexec_system_init.ps1 which prints a yellow warning and identity info.
- Launches PsExec to start powershell.exe as NT AUTHORITY\SYSTEM which runs that file and stays open (-NoExit).

.NOTES
Use only on machines you own or are authorized to manage.
#>

function Test-IsElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

if (-not (Test-IsElevated)) {
    Write-Host "Not running elevated. Relaunching elevated..."
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    # Use PowerShell executable to relaunch
    $pwsh = (Get-Process -Id $PID).Path
    $psi.FileName = $pwsh
    # Preserve script path for relaunch
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = "runas"
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        Write-Error "Elevation canceled or failed. Script needs administrator rights to continue."
    }
    exit
}

# Download PsExec
$psexecUrl  = 'https://live.sysinternals.com/psexec.exe'
$psexecPath = Join-Path -Path $env:TEMP -ChildPath 'psexec.exe'

Write-Host "Downloading PsExec..."
try {
    if (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue) {
        # -UseBasicParsing keeps compatibility with older PS versions
        Invoke-WebRequest -Uri $psexecUrl -OutFile $psexecPath -UseBasicParsing -ErrorAction Stop
    } else {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($psexecUrl, $psexecPath)
    }
    Write-Host "PsExec saved to: $psexecPath"
} catch {
    Write-Error "Failed to download PsExec: $($_.Exception.Message)"
    exit 1
}

# Unblock if needed
try { Unblock-File -Path $psexecPath -ErrorAction SilentlyContinue } catch { }

# Create the script that the SYSTEM PowerShell will run (placed in ProgramData so SYSTEM can access it)

$sysScriptPath = Join-Path -Path $env:ProgramData -ChildPath 'psexec_system_init.ps1'
$warningText = @"
# Small init script executed by the SYSTEM PowerShell session launched via PsExec.
# It displays a clear yellow warning and identity info, then stays interactive.

# Display a yellow warning
Write-Host "         **************************************************************" -ForegroundColor Yellow
Write-Host "        *         WARNING: THIS POWER SHELL SESSION RUNS AS SYSTEM     *" -ForegroundColor Yellow
Write-Host "        *  Only perform actions you are authorized to execute.         *" -ForegroundColor Yellow
Write-Host "        *  Unauthorized use may result in criminal or civil penalties. *" -ForegroundColor Yellow
Write-Host "         **************************************************************" -ForegroundColor Yellow
Write-Host ""

# Show who you are running as (double-check)
Write-Host "Session identity:... $(whoami)"
Write-Host "Process user:....... $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host ""

# Keep the console interactive; the -NoExit used when launching ensures the window stays open.
# Optionally, show quick tips for small-business admins:
Write-Host "Tip: Be cautious. Log actions and get written permission from owners before making changes." -ForegroundColor Yellow
"@

try {
    $warningText | Out-File -FilePath $sysScriptPath -Encoding UTF8 -Force
    Write-Host "Created SYSTEM init script at: $sysScriptPath"
} catch {
    Write-Error "Failed to write SYSTEM init script: $($_.Exception.Message)"
    exit 2
}

# Build PsExec args to run PowerShell as SYSTEM and execute our file, keeping the window open (-NoExit)
# Using '-accepteula' to accept Sysinternals EULA silently for first run.
$psexecArgs = @(
    '-accepteula',
    '-s',         # run as SYSTEM
    '-i',         # interactive (attach to console session)
    'powershell.exe',
    '-NoExit',
    '-File',
    $sysScriptPath
)

Write-Host "Launching interactive PowerShell as SYSTEM (you should see the yellow warning)..." -ForegroundColor Cyan
try {
    Start-Process -FilePath $psexecPath -ArgumentList $psexecArgs -WindowStyle Normal
    Write-Host "If PsExec launched successfully, a new window will appear running as SYSTEM."
} catch {
    Write-Error "Failed to start PsExec: $($_.Exception.Message)"
    exit 3
}
