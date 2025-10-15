function Set-RustDeskServerConfig {
<#
.SYNOPSIS
2025-10-14 | Project: Cybtek STK Utilities | Func#: 001 | Category: RemoteSupport | Sub: RustDesk
Version: 0.1
Purpose: Update RustDesk client config with the ID server FQDN and public Key (and optional Relay/API) on Windows.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Required: your RustDesk ID (rendezvous) server FQDN, e.g. rustdesk.example.com
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IdServerFqdn,

        # Required: the RustDesk server public key string (the long base64-like value ending with '=')
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        # Optional: relay server FQDN. If omitted, we default it to the ID server.
        [string]$RelayFqdn,

        # Optional: API URL (Pro servers). If omitted, we default to https://<IdServerFqdn>
        [string]$ApiUrl,

        # Also update the LocalService profile used by the Windows service
        [switch]$AllProfiles,

        # Don’t stop/start “RustDesk Service”
        [switch]$NoServiceRestart
    )

    begin {
        # Resolve defaults
        if ([string]::IsNullOrWhiteSpace($RelayFqdn)) { $RelayFqdn = $IdServerFqdn }
        if ([string]::IsNullOrWhiteSpace($ApiUrl))    { $ApiUrl    = "https://$IdServerFqdn" }

        # Paths
        $userToml = Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml'
        $svcToml  = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config\RustDesk2.toml'

        $targets = @($userToml)
        if ($AllProfiles) { $targets += $svcToml }

        # Minimal, known-good TOML that sets ID server + key (+ relay/api)
        $toml = @"
rendezvous_server = '$IdServerFqdn'
nat_type = 1
serial = 0

[options]
custom-rendezvous-server = '$IdServerFqdn'
key = '$Key'
relay-server = '$RelayFqdn'
api-server = '$ApiUrl'
"@
    }

    process {
        foreach ($path in $targets) {
            $dir = Split-Path -Path $path -Parent
            if (-not (Test-Path -LiteralPath $dir)) {
                if ($PSCmdlet.ShouldProcess($dir, "Create directory")) {
                    New-Item -ItemType Directory -Force -Path $dir | Out-Null
                }
            }

            # Backup existing
            if (Test-Path -LiteralPath $path) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $bak = "$path.bak.$stamp"
                if ($PSCmdlet.ShouldProcess($path, "Backup to $bak")) {
                    Copy-Item -LiteralPath $path -Destination $bak -Force
                }
            }

            # Write TOML
            if ($PSCmdlet.ShouldProcess($path, "Write RustDesk2.toml")) {
                $toml | Set-Content -LiteralPath $path -Encoding UTF8
            }
        }

        if (-not $NoServiceRestart) {
            $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'RustDesk Service' -or $_.DisplayName -eq 'RustDesk Service' }
            if ($null -ne $svc) {
                if ($svc.Status -ne 'Stopped') {
                    if ($PSCmdlet.ShouldProcess('RustDesk Service', 'Stop')) { Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue }
                }
                if ($PSCmdlet.ShouldProcess('RustDesk Service', 'Start')) { Start-Service -Name $svc.Name -ErrorAction SilentlyContinue }
            }
        }
    }
}
<#
# Basic: set ID server and key for current user profile
Set-RustDeskServerConfig -IdServerFqdn 'rustdesk.yourdomain.com' -Key 'AAAAB3NzaC1yc2EAAAADAQABAAABAQC...='

# Also set for the LocalService profile used by the RustDesk Windows service
Set-RustDeskServerConfig -IdServerFqdn 'rustdesk.yourdomain.com' -Key 'AAAAB3NzaC1yc2EAAAADAQABAAABAQC...=' -AllProfiles

# Provide explicit Relay and API values if you use different endpoints
Set-RustDeskServerConfig -IdServerFqdn 'id.yourdomain.com' -RelayFqdn 'relay.yourdomain.com' -ApiUrl 'https://id.yourdomain.com' -Key 'AAAAB3Nza...=' -AllProfiles
#>

Set-RustDeskServerConfig -IdServerFqdn 'remote.mynetworkroute.com' -Key 'qi1fihIs5XM83ekptuva2gx61TmJzZ+gv2fneqA9I5M=' -AllProfiles
