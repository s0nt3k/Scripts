function Get-BootTime {
    [CmdletBinding()]
    param ()

    try {
        $os = Get-CimInstance Win32_OperatingSystem

        $bootTime = $os.LastBootUpTime

        $uptime = (Get-Date) - $bootTime

        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            LastBootTime = $bootTime
            UptimeDays   = [Math]::Round($uptime.TotalDays, 2)
            UptimeHours  = [Math]::Round($uptime.TotalHours, 2)
        }
    }
    catch {
        Write-Error "Unable to retrieve boot time: $_"
    }
}
function Get-BootDuration {

    try {
        # Try to get boot performance event
        $event = Get-WinEvent -FilterHashtable @{
            LogName = "Microsoft-Windows-Diagnostics-Performance/Operational"
            Id      = 100
        } -MaxEvents 1 -ErrorAction Stop
    }
    catch {
        $event = $null
    }

    if ($event) {

        # Parse XML
        $xml = [xml]$event.ToXml()

        $bootTimeMs = ($xml.Event.EventData.Data |
            Where-Object { $_.Name -eq "BootTime" }).'#text'

        $bootTimeSec = [math]::Round($bootTimeMs / 1000, 2)

        return [PSCustomObject]@{
            Source          = "Event Log"
            LastBoot        = $event.TimeCreated
            BootTimeSeconds = $bootTimeSec
        }
    }

    # Fallback: Use WMI (no boot duration, only uptime)
    $os = Get-CimInstance Win32_OperatingSystem

    $lastBoot = $os.LastBootUpTime
    $uptime   = (Get-Date) - $lastBoot

    [PSCustomObject]@{
        Source          = "System Uptime (Fallback)"
        LastBoot        = $lastBoot
        Uptime          = $uptime.ToString()
        Note            = "Boot duration not recorded on this system"
    }
}
function Get-ActivePowerSchemeName {

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class PowerApi
{
    [DllImport("powrprof.dll")]
    public static extern uint PowerGetActiveScheme(
        IntPtr UserRootPowerKey,
        out IntPtr ActivePolicyGuid
    );

    [DllImport("powrprof.dll")]
    public static extern uint PowerReadFriendlyName(
        IntPtr RootPowerKey,
        ref Guid SchemeGuid,
        IntPtr SubGroupOfPowerSettingsGuid,
        IntPtr PowerSettingGuid,
        byte[] Buffer,
        ref uint BufferSize
    );

    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr hMem);
}
"@

    # Get active power scheme GUID
    $ptr = [IntPtr]::Zero

    $result = [PowerApi]::PowerGetActiveScheme(
        [IntPtr]::Zero,
        [ref]$ptr
    )

    if ($result -ne 0 -or $ptr -eq [IntPtr]::Zero) {
        throw "Failed to retrieve active power scheme. Error code: $result"
    }

    try {
        # Convert pointer to GUID
        $guid = [Runtime.InteropServices.Marshal]::PtrToStructure(
            $ptr,
            [Type][Guid]
        )

        # Prepare buffer
        $size = 1024
        $buffer = New-Object byte[] $size

        $result = [PowerApi]::PowerReadFriendlyName(
            [IntPtr]::Zero,
            [ref]$guid,
            [IntPtr]::Zero,
            [IntPtr]::Zero,
            $buffer,
            [ref]$size
        )

        if ($result -ne 0) {
            throw "Failed to read power scheme name. Error code: $result"
        }

        # Convert Unicode bytes to string
        $name = [System.Text.Encoding]::Unicode.GetString(
            $buffer,
            0,
            $size
        ).TrimEnd([char]0)

        return [PSCustomObject]@{
            Name = $name
            Guid = $guid
        }
    }
    finally {
        # Free memory allocated by Windows
        if ($ptr -ne [IntPtr]::Zero) {
            [PowerApi]::LocalFree($ptr) | Out-Null
        }
    }
}
function Get-FastBootStatus {

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
    $valueName = "HiberbootEnabled"

    try {
        $value = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop

        if ($value.$valueName -eq 1) {
            Write-Output "ENABLED"
        }
        else {
            Write-Output "DISABLED"
        }
    }
    catch {
        Write-Output "DISABLED"
    }
}
function Get-WindowsUpdateDriverStatus {

    $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $valueName = "ExcludeWUDriversInQualityUpdate"

    try {
        $value = Get-ItemProperty -Path $regPath -Name $valueName -ErrorAction Stop

        if ($value.$valueName -eq 0) {
            Write-Output "ENABLED"
        }
        elseif ($value.$valueName -eq 1) {
            Write-Output "DISABLED"
        }
        else {
            Write-Output "ENABLED"
        }
    }
    catch {
        Write-Output "ENABLED"
    }
}
function Test-SystemProtection {
    <#
    .SYNOPSIS
        Checks if System Protection is enabled on the C: drive.
    #>
    [CmdletBinding()]
    param()

    process {
        Write-Host "Drive C: System Protection......:" -NoNewline
        
        # Query the SystemRestoreConfig class in the root\default namespace
        $srConfig = Get-CimInstance -Namespace root\default -ClassName SystemRestoreConfig -ErrorAction SilentlyContinue

        if ($null -ne $srConfig) {
            Write-Host " ENABLED" -ForegroundColor Green
            return $true
        }
        else {
            Write-Host " DISABLED" -ForegroundColor Red
            return $false
        }
    }
}
function Get-LocalMachineID {
    <#
    .SYNOPSIS
        Returns the unique Machine GUID of the local Windows system.

    .DESCRIPTION
        Retrieves the MachineGuid from the Windows registry. This GUID is
        created during Windows installation and is commonly used as a unique
        identifier for the system.

    .OUTPUTS
        System.String

    .EXAMPLE
        Get-LocalMachineID
    #>

    try {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\Cryptography'
        $machineGuid = (Get-ItemProperty -Path $regPath -Name MachineGuid -ErrorAction Stop).MachineGuid

        return $machineGuid
    }
    catch {
        Write-Error "Unable to retrieve Machine ID. $_"
    }
}
function Show-BIOSUUIDColored {

    try {
        $uuid = (Get-WmiObject -Class Win32_ComputerSystemProduct -ErrorAction Stop).UUID

        if ([string]::IsNullOrWhiteSpace($uuid) -or $uuid -eq "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF") {
            Write-Host "Invalid or unavailable BIOS UUID." -ForegroundColor Red
            return
        }

        $hyphenCount = 0

        foreach ($char in $uuid.ToCharArray()) {

            if ($char -eq '-') {
                Write-Host $char -ForegroundColor Gray -NoNewline
                $hyphenCount++
            }
            elseif ($hyphenCount -eq 0) {
                Write-Host $char -ForegroundColor Cyan -NoNewline
            }
            else {
                Write-Host $char -ForegroundColor Yellow -NoNewline
            }
        }

        Write-Host ""
    }
    catch {
        Write-Host "Failed to retrieve BIOS UUID: $_" -ForegroundColor Red
    }
}
function Show-MachineIDColored {

    try {
        $machineGuid = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid

        if ([string]::IsNullOrWhiteSpace($machineGuid)) {
            Write-Host "Machine ID not found." -ForegroundColor Red
            return
        }

        $hyphenCount = 0

        foreach ($char in $machineGuid.ToCharArray()) {

            if ($char -eq '-') {
                Write-Host $char -ForegroundColor Gray -NoNewline
                $hyphenCount++
            }
            elseif ($hyphenCount -eq 0) {
                Write-Host $char -ForegroundColor Cyan -NoNewline
            }
            else {
                Write-Host $char -ForegroundColor Yellow -NoNewline
            }
        }

        Write-Host ""
    }
    catch {
        Write-Host "Failed to retrieve Machine ID: $_" -ForegroundColor Red
    }
}
function Get-LocalMachineUniqueID {
    [PSCustomObject]@{
        MachineGuid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
        BIOS_UUID   = (Get-WmiObject Win32_ComputerSystemProduct).UUID
        TPM_ID      = (Get-WmiObject -Namespace root\cimv2\security\microsofttpm -Class Win32_Tpm -ErrorAction SilentlyContinue).ManufacturerIdTxt
    }
}

Clear-Host

$MachineInfo = Get-ComputerInfo
$FastBoot = Get-FastBootStatus
$WinUpdate = Get-WindowsUpdateDriverStatus
$PowerProfile = Get-ActivePowerSchemeName

Write-Host 
Write-Host -NoNewline "Machine BIOS UUID...............: "; Show-BIOSUUIDColored
Write-host -NoNewline "Windows HOST GUID...............: "; Show-MachineIDColored
Write-Host "Machine Hostname................:" $MachineInfo.CsDNSHostName
Write-Host "Operating System................:" $MachineInfo.OsName
Write-Host "OS Installation Date............:" $MachineInfo.OsInstallDate
Write-Host "OS Last Boot Time...............:" $MachineInfo.OsLastBootUpTime
Write-Host "Physical Memory.................:" $MachineInfo.OsTotalVisibleMemorySize
Write-Host "Active Power Schene.............:" $PowerProfile.Name
Write-Host "Windows FastBoot................:" $FastBoot
Write-Host "Windows Driver Updates..........:" $WinUpdate
Write-Host "MS Software Update..............:" 
$value = Test-SystemProtection
Write-Host
Write-Warning "This application is still under development!"
Write-Host -NoNewline "DEVELOPER: " -ForegroundColor Gray
Write-Host -NoNewline "s0nt3k s01uti0ns" -ForegroundColor DarkYellow
Write-Host " - Last update (2/22/26)" -ForegroundColor Darkcyan
