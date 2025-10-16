#requires -RunAsAdministrator
Param(
    [switch] $SetDefaultShellToPwsh = $false,
    [switch] $DisableWSManRemoting = $false
)

$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$current
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-OpenSSHServerIfNeeded {
    Write-Info 'Checking OpenSSH Server capability...'
    $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' }
    if (-not $cap) {
        throw 'Unable to query Windows capabilities for OpenSSH.Server.'
    }
    if ($cap.State -ne 'Installed') {
        Write-Info 'Installing OpenSSH Server capability...'
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        Write-Info 'OpenSSH Server installed.'
    } else {
        Write-Info 'OpenSSH Server already installed.'
    }
}

function Set-OpenSSHServices {
    Write-Info 'Ensuring OpenSSH services are set to Automatic and running...'
    foreach ($svc in 'sshd','ssh-agent') {
        if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
            throw "Service '$svc' not found after installation."
        }
        Set-Service -Name $svc -StartupType Automatic
        if ((Get-Service -Name $svc).Status -ne 'Running') {
            Start-Service -Name $svc
        }
    }
}

function Set-OpenSSHFirewallRule {
    Write-Info 'Validating firewall rule for OpenSSH (TCP/22)...'
    $ruleName = 'OpenSSH-Server-In-TCP'
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($rule) {
        Enable-NetFirewallRule -Name $ruleName | Out-Null
        Write-Info "Firewall rule '$ruleName' is enabled."
    } else {
        Write-Info "Creating firewall rule '$ruleName'..."
        New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
}

function Get-PowerShellExecutablePath {
    # Prefer PowerShell 7+, fall back to Windows PowerShell 5.1
    $candidates = @()
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwshCmd) { $candidates += $pwshCmd.Source }
    $candidates += 'C:\Program Files\PowerShell\7\pwsh.exe'
    $candidates += 'C:\Program Files\PowerShell\7-preview\pwsh.exe'
    $candidates += 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($p in $candidates | Select-Object -Unique) {
        if (Test-Path $p) { return $p }
    }
    throw 'No PowerShell executable found (pwsh or Windows PowerShell).'
}

function Set-SSHDConfigForPowerShellRemoting {
    Write-Info 'Configuring sshd_config for PowerShell remoting over SSH...'
    $sshdConfig = 'C:\ProgramData\ssh\sshd_config'
    if (-not (Test-Path $sshdConfig)) {
        throw "sshd_config not found at '$sshdConfig'."
    }
    $psExe = Get-PowerShellExecutablePath
    $psExeForConfig = ($psExe -replace '\\','/')
    $desiredLine = "Subsystem powershell $psExeForConfig -sshs -NoLogo -NoProfile"

    # Backup existing config (ASCII to avoid BOM issues)
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "${sshdConfig}.bak-$timestamp"
    Copy-Item -Path $sshdConfig -Destination $backup -Force
    Write-Info "Backed up sshd_config to '$backup'"

    $lines = Get-Content -Path $sshdConfig -ErrorAction Stop
    $found = $false
    for ($i=0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -match '^(#\s*)?Subsystem\s+powershell\b') {
            $lines[$i] = $desiredLine
            $found = $true
        }
    }
    if (-not $found) {
        $lines += $desiredLine
    }
    # Write without BOM; ASCII is accepted by OpenSSH
    $lines | Out-File -FilePath $sshdConfig -Encoding ascii -Force

    # Validate sshd config syntax
    $sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    if (-not (Test-Path $sshdExe)) { $sshdExe = 'sshd.exe' }
    Write-Info 'Validating sshd configuration (sshd -t)...'
    $proc = Start-Process -FilePath $sshdExe -ArgumentList '-t' -NoNewWindow -PassThru -Wait
    if ($proc.ExitCode -ne 0) {
        throw "sshd configuration validation failed with exit code $($proc.ExitCode). Backup at: $backup"
    }

    # Restart service to apply changes
    Restart-Service sshd -Force
    Write-Info 'sshd service restarted.'
}

function Set-OpenSSHDefaultShell {
    param([string]$PwshPath)
    if ($SetDefaultShellToPwsh) {
        Write-Info 'Setting default OpenSSH shell to PowerShell 7 (pwsh)...'
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -Value $PwshPath -PropertyType String -Force | Out-Null
        Write-Info 'Default shell set. (Affects interactive ssh.exe sessions)'
    }
}

function Enable-WSManRemoting {
    Write-Info 'Enabling Windows PowerShell remoting over WSMan (Enable-PSRemoting)...'
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
}

function Test-SSHServer {
    Write-Info 'Running validation checks...'
    $result = [ordered]@{}
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    $result['sshd Service Exists'] = [bool]$svc
    $result['sshd Service Status'] = if ($svc) { $svc.Status } else { 'NotFound' }
    $fw = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    $result['Firewall Rule Present'] = [bool]$fw
    $result['Firewall Rule Enabled'] = if ($fw) { $fw.Enabled } else { $false }
    $tnc = Test-NetConnection -ComputerName 'localhost' -Port 22 -WarningAction SilentlyContinue
    $result['Port 22 Reachable (localhost)'] = $tnc.TcpTestSucceeded
    $sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    if (-not (Test-Path $sshdExe)) { $sshdExe = 'sshd.exe' }
    $proc = Start-Process -FilePath $sshdExe -ArgumentList '-t' -NoNewWindow -PassThru -Wait
    $result['sshd -t (Config Valid)'] = ($proc.ExitCode -eq 0)

    # Output summary
    Write-Host ''
    Write-Host 'Validation Summary:' -ForegroundColor Green
    foreach ($k in $result.Keys) {
        $v = $result[$k]
        Write-Host (" - {0}: {1}" -f $k, $v)
    }
    Write-Host ''

    # Return $true if all checks passed
    return ($result.Values | ForEach-Object { $_ -is [bool] ? $_ : $true } | Where-Object { $_ -eq $false } | Measure-Object).Count -eq 0
}

if (-not (Test-IsAdmin)) {
    throw 'This script must be run as Administrator.'
}

Write-Info 'Starting OpenSSH Server + PowerShell remoting setup...'

Install-OpenSSHServerIfNeeded
Set-OpenSSHServices
Set-OpenSSHFirewallRule
Set-SSHDConfigForPowerShellRemoting
$psPath = Get-PowerShellExecutablePath
Set-OpenSSHDefaultShell -PwshPath $psPath
if (-not $DisableWSManRemoting) { Enable-WSManRemoting }

if (Test-SSHServer) {
    Write-Info 'Setup and validation completed successfully.'
    Write-Host 'You can test PowerShell remoting over SSH with:'
    Write-Host "  Enter-PSSession -HostName localhost -UserName $env:USERNAME" -ForegroundColor Yellow
    Write-Host 'You will be prompted for your password or use keys if configured.'
} else {
    throw 'One or more validation checks failed. Review the summary above for details.'
}
