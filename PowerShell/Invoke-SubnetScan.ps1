function Invoke-SubnetScan {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "This function automatically detects the subnet of the localhost primary network adapter" -ForegroundColor Cyan
    Write-Host "and scans all IP addresses in that subnet for live hosts." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "If you want to FORCE a specific subnet, press ANY key within the next 5 seconds." -ForegroundColor Yellow
    Write-Host "If no key is pressed, the function will use the automatically detected subnet." -ForegroundColor Yellow
    Write-Host ""

    $overrideSubnet = $false

    # --- 5 second keypress window ---
    try {
        for ($i = 5; $i -gt 0; $i--) {
            Write-Host -NoNewline "`rPress any key to enter a custom base address... ($i seconds) "
            if ([Console]::KeyAvailable) {
                [void][Console]::ReadKey($true)  # consume key
                $overrideSubnet = $true
                break
            }
            Start-Sleep -Seconds 1
        }
    }
    catch {
        # If we’re in a host without a console (ISE/VSCode/etc.), just skip the override option.
        Write-Host ""
        Write-Host "Console key detection is not available in this host. Proceeding with auto-detected subnet." -ForegroundColor DarkYellow
    }
    Write-Host ""

    # --- Determine base address ---
    $baseAddress = $null

    if ($overrideSubnet) {
        # Example: 192.168.1 (scan 192.168.1.1–192.168.1.254)
        $baseAddress = Read-Host "Enter the base address (for example: 192.168.1, 10.0.0, or 172.16.200)"
    }
    else {
        # Auto-detect primary IPv4 address and subnet
        try {
            $ipConfig = Get-NetIPConfiguration |
                        Where-Object {
                            $_.IPv4DefaultGateway -ne $null -and
                            $_.NetAdapter.Status -eq 'Up' -and
                            $_.IPv4Address -ne $null
                        } |
                        Select-Object -First 1

            if (-not $ipConfig) {
                Write-Warning "Unable to detect a primary network adapter with an IPv4 address and default gateway."
                return
            }

            $ipv4         = $ipConfig.IPv4Address[0]
            $ipAddress    = $ipv4.IPAddress
            $prefixLength = $ipv4.PrefixLength

            # Use the first 3 octets as the base (e.g. 192.168.1.x)
            $octets = $ipAddress.Split('.')
            if ($octets.Count -ne 4) {
                Write-Warning "Detected IPv4 address is not in the expected format: $ipAddress"
                return
            }

            $baseAddress = "{0}.{1}.{2}" -f $octets[0], $octets[1], $octets[2]
            Write-Host "Auto-detected IPv4 address: $ipAddress/$prefixLength" -ForegroundColor Green
            Write-Host "Using subnet base address:   $baseAddress.0/24" -ForegroundColor Green
            Write-Host ""
        }
        catch {
            Write-Warning "Failed to auto-detect the local subnet: $($_.Exception.Message)"
            return
        }
    }

    if ([string]::IsNullOrWhiteSpace($baseAddress)) {
        Write-Warning "No base address was determined. Exiting."
        return
    }

    # --- Clean up and validate base address ---
    $baseAddress = $baseAddress.Trim()

    # Expect something like X.Y.Z where each part is 0–255
    $baseParts = $baseAddress -split '\.'

    if ($baseParts.Count -ne 3) {
        Write-Warning "The base address '$baseAddress' is not in the expected format (three numbers like 192.168.1 or 10.0.0)."
        return
    }

    foreach ($part in $baseParts) {
        $partTrimmed = $part.Trim()
        [byte]$octet = 0
        if (-not [byte]::TryParse($partTrimmed, [ref]$octet)) {
            Write-Warning "The base address '$baseAddress' is not valid. Each part must be a number between 0 and 255 (e.g. 192.168.1, 10.0.0, 172.16.200)."
            return
        }
    }

    Write-Host "Scanning subnet: $baseAddress.1 through $baseAddress.254" -ForegroundColor Cyan
    Write-Host "Only hosts with a detected hostname will be listed." -ForegroundColor Cyan
    Write-Host ""

    $liveIPs = New-Object System.Collections.Generic.List[string]

    # --- First pass: ping each IP to populate ARP cache ---
    for ($lastOctet = 1; $lastOctet -le 254; $lastOctet++) {
        $ip = "$baseAddress.$lastOctet"

        $isUp = $false
        try {
            $isUp = Test-Connection -ComputerName $ip -Count 1 -Quiet -TimeoutSeconds 0.5
        }
        catch {
            $isUp = $false
        }

        if ($isUp) {
            [void]$liveIPs.Add($ip)
        }
    }

    if ($liveIPs.Count -eq 0) {
        Write-Host "No live hosts were detected in the scanned subnet." -ForegroundColor DarkYellow
        return
    }

    # --- Build ARP table map after pinging (IP -> MAC) ---
    $arpMap = @{}

    try {
        $arpOutput = arp -a
        foreach ($line in $arpOutput) {
            # Typical line:  192.168.1.1           00-11-22-33-44-55     dynamic
            if ($line -match '^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F-]{17})') {
                $ip  = $matches[1]
                $mac = $matches[2]
                $arpMap[$ip] = $mac
            }
        }
    }
    catch {
        Write-Warning "Failed to read ARP table: $($_.Exception.Message)"
    }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($ip in $liveIPs) {
        try {
            $hostEntry = [System.Net.Dns]::GetHostEntry($ip)
            $hostname  = $hostEntry.HostName
        }
        catch {
            # No hostname could be resolved; skip this IP
            continue
        }

        if ([string]::IsNullOrWhiteSpace($hostname)) {
            continue
        }

        $macAddress = $null
        if ($arpMap.ContainsKey($ip)) {
            $macAddress = $arpMap[$ip]
        }

        [void]$results.Add(
            [pscustomobject]@{
                IPAddress  = $ip
                HostName   = $hostname
                MacAddress = $macAddress
            }
        )
    }

    if ($results.Count -eq 0) {
        Write-Host "No hosts with a detectable hostname were found in the scanned subnet." -ForegroundColor DarkYellow
    }
    else {
        Write-Host ""
        Write-Host "Devices with detected hostnames:" -ForegroundColor Green
        $results | Sort-Object IPAddress | Format-Table -AutoSize
    }
}

# -------------------------------------------------------------
# Auto-run logic:
# - If this file is dot-sourced, $MyInvocation.InvocationName will be '.'
#   and the function will NOT run automatically.
# - If this file is executed directly (.\script.ps1), the function WILL run.
# -------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SubnetScan
}
