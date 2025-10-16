#requires -Version 7.0
function Fix-SystemError6118 {
    <#
    .SYNOPSIS
    Minimal in-function metadata (until finalization).
    #>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        # Set active network profiles to Private (recommended on trusted LANs)
        [switch]$MakePrivate,

        # Apply changes without confirmation prompts
        [switch]$SkipConfirm,

        # Report-only dry run (collect and write what *would* change)
        [switch]$WhatIfOnly
    )

    # ---- Minimal Metadata Hashtable (per user preference) ----
    $Metadata = @{
        Timestamp   = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff zzz")
        Project     = 's0nt3k Knowledgebase'
        Function    = 'Fix-SystemError6118'
        FuncNum     = '002'
        Category    = 'Virtualization'
        Subcategory = 'ProxmoxWindowsNetworking'
        Version     = '0.1'
        Synopsis    = 'Safely remediate common local causes of System error 6118 in a Windows 11 VM (services, firewall, network profile) with logs and a before/after snapshot.'
    }

    # ---- Environment & Paths ----
    $Computer   = $env:COMPUTERNAME
    $base       = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($base)) { $base = (Get-Location).Path }
    $tsUnix     = [int][math]::Round(((Get-Date).ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds)

    $logDir     = Join-Path $base ("Logs\{0}" -f $Computer)
    $repDir     = Join-Path $base ("Reports\{0}" -f $Computer)
    $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue
    $null = New-Item -Path $repDir -ItemType Directory -Force -ErrorAction SilentlyContinue
    $logPath    = Join-Path $logDir ("{0}_6118fix.log" -f $tsUnix)
    $jsonPath   = Join-Path $repDir ("{0}_6118fix.json" -f $tsUnix)

    # ---- Logging ----
    $LogLock = New-Object object
    function Write-Log {
        param(
            [ValidateSet('INFO','WARN','ERROR','ACTION')][string]$Level = 'INFO',
            [Parameter(Mandatory)][string]$Message
        )
        $line = "{0} [{1}] {2}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $Level.ToUpper(), $Message
        Write-Host $line
        [System.Threading.Monitor]::Enter($LogLock)
        try { Add-Content -LiteralPath $logPath -Value $line }
        finally { [System.Threading.Monitor]::Exit($LogLock) }
    }

    if ($SkipConfirm) { $script:ConfirmPreference = 'None' }
    if ($WhatIfOnly)  { $PSBoundParameters['WhatIf'] = $true }

    Write-Log -Level INFO -Message "Starting Fix-SystemError6118..."
    Write-Log -Level INFO -Message ("Metadata: {0}" -f ($Metadata | ConvertTo-Json -Compress))

    # ---- Snapshot (Before) ----
    $before = [ordered]@{
        NetworkProfiles = @()
        Services        = @()
        FirewallRules   = @()
    }
    try {
        $before.NetworkProfiles = (Get-NetConnectionProfile | Select-Object Name, InterfaceAlias, NetworkCategory)
    } catch { Write-Log -Level WARN -Message ("Get-NetConnectionProfile failed: {0}" -f $_.Exception.Message) }

    $svcNames = 'FDResPub','fdPHost','SSDPSRV','upnphost','LanmanServer'
    try {
        $before.Services = Get-Service -Name $svcNames -ErrorAction SilentlyContinue |
            Select-Object Name, Status, StartType
    } catch { }
    try {
        $before.FirewallRules = Get-NetFirewallRule -DisplayGroup 'Network Discovery','File and Printer Sharing' -ErrorAction SilentlyContinue |
            Select-Object DisplayName, Enabled, Profile, Direction, Action
    } catch { }

    # ---- Planned Actions ----
    $planned = New-Object System.Collections.Generic.List[hashtable]

    # A) Set network profile(s) to Private
    if ($MakePrivate) {
        try {
            $profiles = Get-NetConnectionProfile -ErrorAction Stop
            foreach ($p in $profiles) {
                if ($p.NetworkCategory -ne 'Private') {
                    $planned.Add(@{ Type='Profile'; Interface=$p.InterfaceAlias; From=$p.NetworkCategory; To='Private' })
                    if ($PSCmdlet.ShouldProcess("Profile:$($p.InterfaceAlias)", "Set-NetConnectionProfile -NetworkCategory Private")) {
                        Set-NetConnectionProfile -InterfaceAlias $p.InterfaceAlias -NetworkCategory Private @PSBoundParameters
                        Write-Log -Level ACTION -Message ("Set-NetConnectionProfile {0} -> Private" -f $p.InterfaceAlias)
                    }
                }
            }
        } catch {
            Write-Log -Level ERROR -Message ("Failed to adjust network profiles: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Log -Level INFO -Message "Skipping profile change (use -MakePrivate to set profiles to Private)."
    }

    # B) Ensure discovery services are Automatic and running
    $coreSvcs = 'FDResPub','fdPHost','SSDPSRV','upnphost'
    foreach ($svc in $coreSvcs) {
        try {
            $s = Get-Service -Name $svc -ErrorAction Stop
            if ($s.StartType -ne 'Automatic') {
                $planned.Add(@{ Type='ServiceStartType'; Name=$svc; From=$s.StartType; To='Automatic' })
                if ($PSCmdlet.ShouldProcess("Service:$svc", "Set-Service -StartupType Automatic")) {
                    Set-Service -Name $svc -StartupType Automatic @PSBoundParameters
                    Write-Log -Level ACTION -Message ("Set-Service {0} -StartupType Automatic" -f $svc)
                }
            }
            if ($s.Status -ne 'Running') {
                $planned.Add(@{ Type='ServiceStart'; Name=$svc; From=$s.Status; To='Running' })
                if ($PSCmdlet.ShouldProcess("Service:$svc", "Start-Service")) {
                    Start-Service -Name $svc -ErrorAction SilentlyContinue
                    Write-Log -Level ACTION -Message ("Start-Service {0}" -f $svc)
                }
            }
        } catch {
            Write-Log -Level ERROR -Message ("Service {0} error: {1}" -f $svc, $_.Exception.Message)
        }
    }

    # C) Enable firewall groups on Private profile
    foreach ($grp in @('Network Discovery','File and Printer Sharing')) {
        try {
            $rules = Get-NetFirewallRule -DisplayGroup $grp -ErrorAction SilentlyContinue
            if ($rules) {
                # We won't forcibly change profile scopes here; we enable any disabled rules.
                $disabled = $rules | Where-Object Enabled -ne 'True'
                if ($disabled) {
                    $planned.Add(@{ Type='FirewallEnableGroup'; Group=$grp; Count=$disabled.Count })
                    if ($PSCmdlet.ShouldProcess("Firewall Group:$grp", "Enable-NetFirewallRule -DisplayGroup '$grp'")) {
                        Enable-NetFirewallRule -DisplayGroup $grp @PSBoundParameters
                        Write-Log -Level ACTION -Message ("Enable-NetFirewallRule -DisplayGroup '{0}'" -f $grp)
                    }
                } else {
                    Write-Log -Level INFO -Message ("Firewall group already enabled: {0}" -f $grp)
                }
            } else {
                Write-Log -Level WARN -Message ("No firewall rules found for group: {0}" -f $grp)
            }
        } catch {
            Write-Log -Level ERROR -Message ("Firewall group {0} error: {1}" -f $grp, $_.Exception.Message)
        }
    }

    # D) Explicitly *not* enabling SMB1
    Write-Log -Level INFO -Message "Security: SMB1 will NOT be enabled by this script."

    # ---- Snapshot (After) ----
    $after = [ordered]@{
        NetworkProfiles = @()
        Services        = @()
        FirewallRules   = @()
    }
    try {
        $after.NetworkProfiles = (Get-NetConnectionProfile | Select-Object Name, InterfaceAlias, NetworkCategory)
    } catch { }
    try {
        $after.Services = Get-Service -Name $svcNames -ErrorAction SilentlyContinue |
            Select-Object Name, Status, StartType
    } catch { }
    try {
        $after.FirewallRules = Get-NetFirewallRule -DisplayGroup 'Network Discovery','File and Printer Sharing' -ErrorAction SilentlyContinue |
            Select-Object DisplayName, Enabled, Profile, Direction, Action
    } catch { }

    # ---- Compose report ----
    $report = [ordered]@{
        Metadata  = $Metadata
        Computer  = $Computer
        When      = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff zzz")
        Paths     = @{ Log=$logPath; Json=$jsonPath }
        Planned   = $planned
        Before    = $before
        After     = $after
        Notes     = @(
            'This script avoids enabling SMB1.',
            'Profile changes are applied only with -MakePrivate.',
            'All actions honor -WhatIf and -Confirm unless -SkipConfirm is used.'
        )
    }

    try {
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
        Write-Log -Level INFO -Message ("Saved report: {0}" -f $jsonPath)
    } catch {
        Write-Log -Level ERROR -Message ("Failed to save JSON report: {0}" -f $_.Exception.Message)
    }

    # ---- Output ----
    $report
}

# Auto-run if executed directly
if ($MyInvocation.PSScriptRoot) {
    Write-Host "Running Fix-SystemError6118..."
    try {
        $out = Fix-SystemError6118 -WhatIfOnly:$false
        $out | ConvertTo-Json -Depth 6 | Out-Host
        Write-Host "Report:"
        Write-Host "  $($out.Paths.Json)"
        Write-Host "Log:"
        Write-Host "  $($out.Paths.Log)"
        Write-Host "`nTip: Re-run with -MakePrivate and/or -SkipConfirm if appropriate."
    } catch {
        Write-Error $_
    }
}
