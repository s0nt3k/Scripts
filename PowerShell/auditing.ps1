<#
.SYNOPSIS
Interactive console menu to enable/disable Windows auditing via registry and security policy, with per-computer logging.

.DESCRIPTION
Provides an arrow-key navigable menu (highlighting the current selection) to:
- Enable/Disable an auditing-related registry setting (LSA AuditBaseObjects)
- Enable/Disable auditing security policy via auditpol (all categories)
- Show current status
- View logs

Logs are written to: $PSScriptRoot\Logs\%COMPUTERNAME%\
Each log line records: timestamp, hostname, windows user, technician name, and auditing status.

.NOTES
- Requires Administrator for changing settings.
- PowerShell 5.1 compatible.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsUser {
    if ($env:USERDOMAIN) { return "$($env:USERDOMAIN)\\$($env:USERNAME)" }
    return $env:USERNAME
}

function Get-LogFolder {
    $folder = Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path 'Logs' -ChildPath $env:COMPUTERNAME)
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
    return $folder
}

function Get-LogFilePath {
    $logFolder = Get-LogFolder
    $dateStamp = Get-Date -Format 'yyyyMMdd'
    return Join-Path -Path $logFolder -ChildPath "Enable-DisableAuditing_$dateStamp.log"
}

function Write-ActivityLog {
    param(
        [Parameter(Mandatory)]
        [string]$TechnicianName,

        [Parameter(Mandatory)]
        [string]$Action,

        [string]$Details
    )

    $timestamp = (Get-Date).ToString('o')
    $hostname = $env:COMPUTERNAME
    $windowsUser = Get-WindowsUser

    $registryStatus = (Get-RegistryAuditingStatus).Status
    $securityPolicyStatus = (Get-SecurityPolicyAuditingStatus).Status

    $line = [string]::Join("\t", @(
        "ts=$timestamp",
        "host=$hostname",
        "user=$windowsUser",
        "tech=$TechnicianName",
        "registryAudit=$registryStatus",
        "securityPolicyAudit=$securityPolicyStatus",
        "action=$Action",
        "details=$Details"
    ))

    $path = Get-LogFilePath
    Add-Content -Path $path -Value $line -Encoding UTF8
}

function Get-RegistryAuditingStatus {
    # Uses the LSA policy value backing the security option:
    # "Audit: Audit the access of global system objects" (AuditBaseObjects)
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $name = 'AuditBaseObjects'

    $value = $null
    try {
        $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Stop
        $value = [int]$item.$name
    } catch {
        $value = 0
    }

    if ($value -eq 1) {
        return [pscustomobject]@{ Status = 'Enabled'; Value = 1; Path = $path; Name = $name }
    }

    return [pscustomobject]@{ Status = 'Disabled'; Value = 0; Path = $path; Name = $name }
}

function Set-RegistryAuditingStatus {
    param(
        [Parameter(Mandatory)]
        [bool]$Enable
    )

    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $name = 'AuditBaseObjects'
    $desired = if ($Enable) { 1 } else { 0 }

    if (-not (Test-IsAdministrator)) {
        throw 'Administrator privileges are required to change the registry auditing setting.'
    }

    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -Path $path -Name $name -PropertyType DWord -Value $desired -Force | Out-Null

    return Get-RegistryAuditingStatus
}

function Get-SecurityPolicyAuditingStatus {
    $auditpol = Get-Command -Name 'auditpol.exe' -ErrorAction SilentlyContinue
    if (-not $auditpol) {
        return [pscustomobject]@{ Status = 'Unknown'; Reason = 'auditpol.exe not found' }
    }

    $output = & $auditpol.Source /get /category:* 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        return [pscustomobject]@{ Status = 'Unknown'; Reason = 'auditpol.exe returned a non-zero exit code' }
    }

    # Heuristic: if any subcategory is auditing Success/Failure, treat as Enabled.
    # If all subcategories are "No Auditing" (or Not Supported), treat as Disabled.
    $lines = @($output | Where-Object { $_ -and $_.Trim().Length -gt 0 })

    $hasEnabled = $false
    $hasAnyAuditable = $false

    foreach ($line in $lines) {
        # Skip headers
        if ($line -match '^\s*System audit policy' -or $line -match '^\s*Category/Subcategory' -or $line -match '^\s*-{3,}\s*$') { continue }

        if ($line -match 'No Auditing') {
            $hasAnyAuditable = $true
            continue
        }
        if ($line -match 'Not Supported') { continue }
        if ($line -match 'Success' -or $line -match 'Failure') {
            $hasEnabled = $true
            $hasAnyAuditable = $true
        }
    }

    if (-not $hasAnyAuditable) {
        return [pscustomobject]@{ Status = 'Unknown'; Reason = 'Unable to parse auditpol output' }
    }

    if ($hasEnabled) {
        return [pscustomobject]@{ Status = 'Enabled' }
    }

    return [pscustomobject]@{ Status = 'Disabled' }
}

function Set-SecurityPolicyAuditingStatus {
    param(
        [Parameter(Mandatory)]
        [bool]$Enable
    )

    $auditpol = Get-Command -Name 'auditpol.exe' -ErrorAction Stop

    if (-not (Test-IsAdministrator)) {
        throw 'Administrator privileges are required to change auditing security policy (auditpol).' 
    }

    if ($Enable) {
        & $auditpol.Source /set /category:* /success:enable /failure:enable | Out-Null
    } else {
        & $auditpol.Source /set /category:* /success:disable /failure:disable | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        throw "auditpol.exe failed with exit code $LASTEXITCODE" 
    }

    return Get-SecurityPolicyAuditingStatus
}

function Pause-ForKey {
    param([string]$Message = 'Press any key to continue...')
    Write-Host ''
    Write-Host $Message -ForegroundColor DarkGray
    [void][Console]::ReadKey($true)
}

function Read-MenuSelection {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string[]]$Options
    )

    $selectedIndex = 0

    while ($true) {
        Clear-Host
        Write-Host $Title
        Write-Host ('=' * $Title.Length)
        Write-Host ''

        for ($i = 0; $i -lt $Options.Count; $i++) {
            $prefix = if ($i -eq $selectedIndex) { '>' } else { ' ' }
            $line = "$prefix $($Options[$i])"

            if ($i -eq $selectedIndex) {
                Write-Host $line -BackgroundColor DarkCyan -ForegroundColor Black
            } else {
                Write-Host $line
            }
        }

        Write-Host ''
        Write-Host 'Use Up/Down arrows, Enter to select.' -ForegroundColor DarkGray

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $selectedIndex = ($selectedIndex - 1 + $Options.Count) % $Options.Count }
            'DownArrow' { $selectedIndex = ($selectedIndex + 1) % $Options.Count }
            'Enter'     { return $selectedIndex }
        }
    }
}

function Show-CurrentStatus {
    $reg = Get-RegistryAuditingStatus
    $sec = Get-SecurityPolicyAuditingStatus

    Clear-Host
    Write-Host 'Current Auditing Status'
    Write-Host '======================='
    Write-Host ''
    Write-Host ("Registry (AuditBaseObjects): {0}" -f $reg.Status)
    Write-Host ("Security Policy (auditpol):   {0}" -f $sec.Status)
    if ($sec.PSObject.Properties.Name -contains 'Reason' -and $sec.Reason) {
        Write-Host ("  Reason: {0}" -f $sec.Reason) -ForegroundColor DarkGray
    }
}

function View-Logs {
    $logFolder = Get-LogFolder
    $files = Get-ChildItem -Path $logFolder -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime -Descending

    Clear-Host
    Write-Host 'Enable/Disable Auditing Logs'
    Write-Host '============================'
    Write-Host ("Folder: {0}" -f $logFolder)
    Write-Host ''

    if (-not $files) {
        Write-Host 'No log files found yet.' -ForegroundColor Yellow
        Pause-ForKey
        return
    }

    $latest = $files | Select-Object -First 1
    Write-Host ("Showing latest log file: {0}" -f $latest.Name)
    Write-Host ''

    try {
        Get-Content -Path $latest.FullName -Tail 200 -ErrorAction Stop | ForEach-Object { Write-Host $_ }
    } catch {
        Write-Host ("Failed to read log file: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    Pause-ForKey
}

# --- Main ---

$technicianName = Read-Host 'Technician name'
if (-not $technicianName -or $technicianName.Trim().Length -eq 0) {
    $technicianName = 'Unknown'
}

Write-ActivityLog -TechnicianName $technicianName -Action 'start' -Details 'Script started'

$menuTitle = 'Enable/Disable Auditing'
$menuOptions = @(
    'Enable/Disable Auditing Registry Setting',
    'Enable/Disable Auditing Security Policy',
    'Get Current Status of Auditing Settings',
    'View Enable/Disable Auditing Settings Logs',
    'Terminate Enable/Disable Auditing Script'
)

while ($true) {
    $choice = Read-MenuSelection -Title $menuTitle -Options $menuOptions

    switch ($choice) {
        0 {
            try {
                $current = Get-RegistryAuditingStatus
                $newEnabled = ($current.Status -ne 'Enabled')
                $result = Set-RegistryAuditingStatus -Enable:$newEnabled

                $msg = "Registry auditing setting is now: $($result.Status)" 
                Write-ActivityLog -TechnicianName $technicianName -Action 'toggle-registry' -Details $msg

                Clear-Host
                Write-Host $msg -ForegroundColor Green
                Write-Host ("Path: {0}  Name: {1}  Value: {2}" -f $result.Path, $result.Name, $result.Value) -ForegroundColor DarkGray
            } catch {
                $err = $_.Exception.Message
                Write-ActivityLog -TechnicianName $technicianName -Action 'toggle-registry-failed' -Details $err
                Clear-Host
                Write-Host "Failed: $err" -ForegroundColor Red
                if (-not (Test-IsAdministrator)) {
                    Write-Host 'Tip: Re-run this script as Administrator.' -ForegroundColor Yellow
                }
            }
            Pause-ForKey
        }
        1 {
            try {
                $current = Get-SecurityPolicyAuditingStatus
                $newEnabled = ($current.Status -ne 'Enabled')
                $result = Set-SecurityPolicyAuditingStatus -Enable:$newEnabled

                $msg = "Security policy auditing is now: $($result.Status)" 
                Write-ActivityLog -TechnicianName $technicianName -Action 'toggle-security-policy' -Details $msg

                Clear-Host
                Write-Host $msg -ForegroundColor Green
                Write-Host 'Note: This uses auditpol to set ALL categories success/failure.' -ForegroundColor DarkGray
            } catch {
                $err = $_.Exception.Message
                Write-ActivityLog -TechnicianName $technicianName -Action 'toggle-security-policy-failed' -Details $err
                Clear-Host
                Write-Host "Failed: $err" -ForegroundColor Red
                if (-not (Test-IsAdministrator)) {
                    Write-Host 'Tip: Re-run this script as Administrator.' -ForegroundColor Yellow
                }
            }
            Pause-ForKey
        }
        2 {
            Show-CurrentStatus
            Write-ActivityLog -TechnicianName $technicianName -Action 'status' -Details 'Displayed current status'
            Pause-ForKey
        }
        3 {
            Write-ActivityLog -TechnicianName $technicianName -Action 'view-logs' -Details 'Viewed logs'
            View-Logs
        }
        4 {
            Write-ActivityLog -TechnicianName $technicianName -Action 'terminate' -Details 'Script terminated by user'
            Clear-Host
            return
        }
    }
}
