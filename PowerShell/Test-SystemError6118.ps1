requires -Version 7.0
function Test-SystemError6118 {
    <#
    .SYNOPSIS
    Minimal in-function metadata (until finalization).
    #>
    [CmdletBinding()]
    param(
        # Optional: a LAN host to test direct SMB connectivity against (e.g., a NAS or another PC)
        [string]$TargetHost,

        # If set, only collect diagnostics without attempting any remediation hints
        [switch]$ReportOnly
    )

    # ---- Minimal Metadata Hashtable (per user preference) ----
    $Metadata = @{
        Timestamp   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff zzz")
        Project     = 's0nt3k Knowledgebase'
        Function    = 'Test-SystemError6118'
        FuncNum     = '001'
        Category    = 'Virtualization'
        Subcategory = 'ProxmoxWindowsNetworking'
        Version     = '0.1'
        Synopsis    = 'Diagnose causes of System error 6118 in a Windows 11 VM running on Proxmox and produce JSON/TXT reports.'
    }

    # ---- Paths ----
    $Computer   = $env:COMPUTERNAME
    $base       = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($base)) { $base = (Get-Location).Path }
    $tsUnix     = [int][math]::Round(((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)
    $logDir     = Join-Path $base ("Logs\{0}" -f $Computer)
    $repDir     = Join-Path $base ("Reports\{0}" -f $Computer)
    $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue
    $null = New-Item -Path $repDir -ItemType Directory -Force -ErrorAction SilentlyContinue
    $logPath    = Join-Path $logDir ("{0}_6118diag.log" -f $tsUnix)
    $jsonPath   = Join-Path $repDir ("{0}_6118diag.json" -f $tsUnix)
    $txtPath    = Join-Path $repDir ("{0}_6118diag.txt" -f $tsUnix)

    # ---- Logger ----
    $LogLock = New-Object object
    function Write-Log {
        param(
            [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO',
            [Parameter(Mandatory)][string]$Message
        )
        $line = "{0} [{1}] {2}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $Level.ToUpper(), $Message
        Write-Verbose $line
        [System.Threading.Monitor]::Enter($LogLock)
        try { Add-Content -LiteralPath $logPath -Value $line }
        finally { [System.Threading.Monitor]::Exit($LogLock) }
    }

    Write-Log -Level INFO -Message "Starting Test-SystemError6118 diagnostics..."
    Write-Log -Level INFO -Message ("Metadata: {0}" -f ($Metadata | ConvertTo-Json -Compress))

    # ---- Collectors ----
    $result = [ordered]@{
        Metadata     = $Metadata
        ComputerName = $Computer
        TimeLocal    = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff zzz")
        ProxmoxHints = @{
            VirtIONetDetected = $false
            NetKVMDriver      = $null
        }
        NetworkProfile = $null
        Adapters       = @()
        Services       = @()
        Firewall       = @()
        SMB            = @{
            ServerServiceRunning = $null
            Port445Listening     = $null
            TargetHost445Reach   = $null
            DirectUNCToTarget    = $null
        }
        Discovery      = @{
            WSDiscoveryUDP3702Allowed = $null
            NetBIOS137138Allowed      = $null
        }
        Tests          = @()
        Summary        = @{
            LikelyCauses = @()
            SuggestedActions = @()
            OverallStatus = 'Unknown'
        }
        Paths          = @{
            Log   = $logPath
            Json  = $jsonPath
            Text  = $txtPath
        }
    }

    # --- Network Profile ---
    try {
        $prof = Get-NetConnectionProfile -ErrorAction Stop
        $result.NetworkProfile = $prof | Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity
        Write-Log -Level INFO -Message ("Network profiles: {0}" -f (($result.NetworkProfile | ConvertTo-Json -Compress)))
    } catch {
        Write-Log -Level ERROR -Message ("Get-NetConnectionProfile failed: {0}" -f $_.Exception.Message)
    }

    # --- Adapters & VirtIO hints ---
    try {
        $adapters = Get-NetAdapter -Physical | Sort-Object ifIndex
        foreach ($a in $adapters) {
            $drv = try { (Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue) } catch { $null }
            $pnp = try { (Get-PnpDevice -FriendlyName $a.InterfaceDescription -ErrorAction SilentlyContinue) } catch { $null }
            $ver = try { (Get-NetAdapter | Where-Object Name -EQ $a.Name | Select-Object -ExpandProperty DriverVersion) } catch { $null }

            $isVirtIO = ($a.InterfaceDescription -match 'VirtIO' -or $a.DriverDescription -match 'Red Hat VirtIO' -or $a.DriverDescription -match 'NetKVM')
            if ($isVirtIO) {
                $result.ProxmoxHints.VirtIONetDetected = $true
                $result.ProxmoxHints.NetKVMDriver      = $ver
            }

            $result.Adapters += [pscustomobject]@{
                Name               = $a.Name
                Status             = $a.Status
                MacAddress         = $a.MacAddress
                LinkSpeed          = $a.LinkSpeed
                InterfaceDesc      = $a.InterfaceDescription
                DriverDescription  = $a.DriverDescription
                DriverVersion      = $ver
                VlanID             = (Get-NetAdapter -Name $a.Name).VlanID
            }
        }
        Write-Log -Level INFO -Message ("Adapters: {0}" -f (($result.Adapters | ConvertTo-Json -Compress)))
    } catch {
        Write-Log -Level ERROR -Message ("Adapter enumeration failed: {0}" -f $_.Exception.Message)
    }

    # --- Services ---
    $svcNames = 'FDResPub','fdPHost','SSDPSRV','upnphost','LanmanServer'
    try {
        $svcs = Get-Service -Name $svcNames -ErrorAction SilentlyContinue |
            Select-Object Name, Status, StartType
        $result.Services = $svcs
        Write-Log -Level INFO -Message ("Services: {0}" -f (($svcs | ConvertTo-Json -Compress)))
    } catch {
        Write-Log -Level ERROR -Message ("Service check failed: {0}" -f $_.Exception.Message)
    }

    # --- Firewall groups ---
    $fwGroups = 'Network Discovery','File and Printer Sharing'
    try {
        $rules = Get-NetFirewallRule -DisplayGroup $fwGroups -ErrorAction SilentlyContinue |
            Select-Object DisplayName, Enabled, Profile, Direction, Action
        $result.Firewall = $rules
        Write-Log -Level INFO -Message ("Firewall rules: {0}" -f (($rules | ConvertTo-Json -Compress)))
    } catch {
        Write-Log -Level ERROR -Message ("Firewall check failed: {0}" -f $_.Exception.Message)
    }

    # --- SMB (server) state ---
    try {
        $lanman = Get-Service -Name 'LanmanServer' -ErrorAction SilentlyContinue
        $result.SMB.ServerServiceRunning = ($lanman.Status -eq 'Running')
    } catch { }
    try {
        # Check if local TCP 445 is listening
        $netTCP = Get-NetTCPConnection -LocalPort 445 -State Listen -ErrorAction SilentlyContinue
        $result.SMB.Port445Listening = [bool]$netTCP
    } catch { }

    # --- Target tests (optional) ---
    if ($TargetHost) {
        try {
            $tnc = Test-NetConnection -ComputerName $TargetHost -Port 445 -WarningAction SilentlyContinue -InformationLevel Quiet
            $result.SMB.TargetHost445Reach = [bool]$tnc
            Write-Log -Level INFO -Message ("445 reachability to {0}: {1}" -f $TargetHost, $tnc)
        } catch {
            Write-Log -Level WARN -Message ("Test-NetConnection failed for {0}: {1}" -f $TargetHost, $_.Exception.Message)
        }
        try {
            $unc = Test-Path ("\\{0}\C$" -f $TargetHost)
            $result.SMB.DirectUNCToTarget = [bool]$unc
            Write-Log -Level INFO -Message ("Direct UNC to \\{0}\C$ : {1}" -f $TargetHost, $unc)
        } catch {
            Write-Log -Level WARN -Message ("UNC test failed for {0}: {1}" -f $TargetHost, $_.Exception.Message)
        }
    }

    # --- Discovery allowances (best-effort) ---
    try {
        $wsd = Get-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction SilentlyContinue |
               Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
               Where-Object { $_.Protocol -eq 'UDP' -and $_.LocalPort -eq 3702 }
        $result.Discovery.WSDiscoveryUDP3702Allowed = [bool]$wsd
    } catch { }
    try {
        $nb = Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue |
              Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
              Where-Object { $_.Protocol -eq 'UDP' -and ($_.LocalPort -eq 137 -or $_.LocalPort -eq 138) }
        $result.Discovery.NetBIOS137138Allowed = [bool]$nb
    } catch { }

    # --- Derive Likely Causes & Suggested Actions ---
    $causes = New-Object System.Collections.Generic.List[string]
    $actions = New-Object System.Collections.Generic.List[string]

    # Network profile
    if ($result.NetworkProfile) {
        $anyPublic = $result.NetworkProfile | Where-Object { $_.NetworkCategory -eq 'Public' }
        if ($anyPublic) {
            $causes.Add('Network profile is Public; discovery blocked by default.')
            $actions.Add('Set active network to Private: Set-NetConnectionProfile -InterfaceAlias "<name>" -NetworkCategory Private')
        }
    }

    # Services
    $svcMap = @{}
    foreach ($s in $result.Services) { $svcMap[$s.Name] = $s }
    foreach ($needed in 'FDResPub','fdPHost','SSDPSRV','upnphost') {
        if ($null -eq $svcMap[$needed] -or $svcMap[$needed].Status -ne 'Running') {
            $causes.Add("Service $needed not running.")
            $actions.Add("Set-Service $needed -StartupType Automatic; Start-Service $needed")
        }
    }

    # Firewall groups
    if ($result.Firewall) {
        $nd = $result.Firewall | Where-Object { $_.DisplayName -like '*Network Discovery*' -and $_.Enabled -ne 'True' }
        $fps = $result.Firewall | Where-Object { $_.DisplayName -like '*File and Printer Sharing*' -and $_.Enabled -ne 'True' }
        if ($nd) { $causes.Add('Network Discovery firewall group disabled or limited by profile.') ; $actions.Add("Enable-NetFirewallRule -DisplayGroup 'Network Discovery'") }
        if ($fps){ $causes.Add('File and Printer Sharing firewall group disabled or limited by profile.') ; $actions.Add("Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing'") }
    }

    # SMB server state
    if ($result.SMB.Port445Listening -ne $true -or $result.SMB.ServerServiceRunning -ne $true) {
        $causes.Add('SMB server (LanmanServer) not running or port 445 not listening.')
        $actions.Add('Ensure "Server" service is running and no security suite blocks TCP 445.')
    }

    # VirtIO hints
    if ($result.ProxmoxHints.VirtIONetDetected -and [string]::IsNullOrWhiteSpace($result.ProxmoxHints.NetKVMDriver)) {
        $causes.Add('VirtIO NetKVM driver version unknown; potential driver issue.')
        $actions.Add('Update VirtIO NetKVM driver from latest virtio-win ISO.')
    }

    # Target host tests
    if ($TargetHost) {
        if ($result.SMB.TargetHost445Reach -ne $true) {
            $causes.Add("Cannot reach TCP 445 on $TargetHost.")
            $actions.Add("Check $TargetHost firewall and LAN routing/VLANs for TCP 445.")
        } elseif ($result.SMB.DirectUNCToTarget -ne $true) {
            $causes.Add("SMB reachable but ADMIN$ (C$) denied or blocked; credentials/ACL issue.")
            $actions.Add("Use a share you have rights to, e.g., \\$TargetHost\Public, and verify credentials.")
        }
    }

    # WS-Discovery / NetBIOS allowance
    if ($result.Discovery.WSDiscoveryUDP3702Allowed -ne $true) {
        $causes.Add('WS-Discovery UDP 3702 may be blocked by firewall.')
        $actions.Add("Ensure UDP 3702 allowed on Private profile or enable 'Network Discovery' group.")
    }
    if ($result.Discovery.NetBIOS137138Allowed -ne $true) {
        $actions.Add("If you rely on NetBIOS discovery for legacy devices, allow UDP 137/138 (Private LAN only).")
    }

    # Finalize summary
    if ($causes.Count -eq 0) {
        $result.Summary.OverallStatus = 'No obvious local blockers detected. Likely L2 broadcast isolation on Proxmox bridge/VLAN.'
        $actions.Add('Verify Proxmox vmbr bridge is attached to a physical NIC (bridge-ports) and not set to none.')
        $actions.Add('Check VLAN tagging on the VM NIC and switch/access port; broadcasts must reach LAN.')
    } else {
        $result.Summary.OverallStatus = 'One or more likely blockers detected.'
    }
    $result.Summary.LikelyCauses = $causes
    $result.Summary.SuggestedActions = $actions

    # ---- Persist reports ----
    try {
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
        Write-Log -Level INFO -Message ("Saved JSON report: {0}" -f $jsonPath)
    } catch {
        Write-Log -Level ERROR -Message ("Failed to save JSON: {0}" -f $_.Exception.Message)
    }

    try {
        $lines = @()
        $lines += "=== Test-SystemError6118 Report ==="
        $lines += "Computer: $Computer"
        $lines += "When: $($result.TimeLocal)"
        $lines += ""
        $lines += "Overall: $($result.Summary.OverallStatus)"
        $lines += ""
        if ($causes.Count) {
            $lines += "[Likely Causes]"
            $causes | ForEach-Object { $lines += " - $_" }
            $lines += ""
        }
        if ($actions.Count) {
            $lines += "[Suggested Actions]"
            $actions | ForEach-Object { $lines += " - $_" }
            $lines += ""
        }
        $lines += "[Key Points]"
        $lines += " - Network Profile(s):"
        foreach ($p in ($result.NetworkProfile ?? @())) {
            $lines += ("    {0} / {1} / {2}" -f $p.Name, $p.InterfaceAlias, $p.NetworkCategory)
        }
        $lines += (" - Discovery Services: {0}" -f (($result.Services | Where-Object Name -in 'FDResPub','fdPHost','SSDPSRV','upnphost' | ForEach-Object { "{0}:{1}" -f $_.Name,$_.Status }) -join ', '))
        $lines += (" - Firewall Rules (Network Discovery, File and Printer Sharing): captured")
        $lines += (" - SMB: ServerRunning={0} Port445={1}" -f $result.SMB.ServerServiceRunning, $result.SMB.Port445Listening)
        if ($TargetHost) {
            $lines += (" - TargetHost {0}: 445Reach={1} UNC={2}" -f $TargetHost, $result.SMB.TargetHost445Reach, $result.SMB.DirectUNCToTarget)
        }
        Set-Content -LiteralPath $txtPath -Value $lines -Encoding UTF8
        Write-Log -Level INFO -Message ("Saved TXT report: {0}" -f $txtPath)
    } catch {
        Write-Log -Level ERROR -Message ("Failed to save TXT: {0}" -f $_.Exception.Message)
    }

    # ---- Output object ----
    $result
}

# Auto-run if script is executed directly, not dot-sourced
if ($MyInvocation.PSScriptRoot) {
    Write-Host "Running Test-SystemError6118... (use -Verbose for details)"
    try {
        $out = Test-SystemError6118
        $out | ConvertTo-Json -Depth 6 | Out-Host
        Write-Host "Reports saved to:"
        Write-Host "  $($out.Paths.Json)"
        Write-Host "  $($out.Paths.Text)"
        Write-Host "Log:"
        Write-Host "  $($out.Paths.Log)"
    } catch {
        Write-Error $_
    }
}
