#requires -RunAsAdministrator
[CmdletBinding()]
Param(
    [switch] $SetDefaultShellToPwsh = $false,
    [switch] $DisableWSManRemoting = $false,
    [int]    $RequiredPwshMajor = 7
)

$ErrorActionPreference = 'Stop'

# -----------------------------
# Metadata (Hashtable, full)
# -----------------------------
$Metadata = @{
    Timestamp    = (Get-Date -Format o)
    Project      = 'System Manager'
    Name         = 'Initialize-OpenSSHRemoting'
    Version      = '0.1'
    Category     = 'Remoting'
    CategoryCode = '620'           # Provisional; ensure uniqueness in your master JSON
    Subcategory  = 'OpenSSH'
    SubcatCode   = '022'           # Provisional; ensure uniqueness in your master JSON
    FIDN         = '62002200000'   # 11 digits provisional: 620 022 + sequence
    PIDN         = '50277491362'   # Project ID Number (provisional)
    Author       = 'Sonny M. Gibson (s0nt3k)'
    Description  = 'Installs and configures OpenSSH Server; enables firewall; sets PowerShell SSH remoting; optional WSMan; validates setup.'
    Compliance   = 'Use on trusted hosts with approved access controls; protect credentials and keys per policy.'
}

# Emit a brief verbose banner so $Metadata is read (PSScriptAnalyzer)
Write-Verbose ("Script {0} v{1}" -f $Metadata.Name, $Metadata.Version)

function Start-ActivityLogging {
    [CmdletBinding()]
    param()
    try {
        $root = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent -Path $PSCommandPath } else { (Get-Location).Path }
        $logDir = Join-Path $root (Join-Path 'Logs' $env:COMPUTERNAME)
        $repDir = Join-Path $root (Join-Path 'Reports' $env:COMPUTERNAME)
        $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Path $repDir -Force -ErrorAction SilentlyContinue
        $unix = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        $ts   = Get-Date -Format 'yyyyMMddTHHmmss'
        $script:LogFilePath    = Join-Path $logDir   ("{0}_sshpsremoting.log" -f $unix)
        $script:ReportFilePath = Join-Path $repDir   ("{0}_sshpsremoting.html" -f $ts)
        Write-Verbose ("Logging to {0}" -f $script:LogFilePath)
        try { Start-Transcript -Path $script:LogFilePath -Force -ErrorAction Stop } catch { Write-Verbose "Transcript could not be started: $($_.Exception.Message)" }
    } catch {
        Write-Verbose "Failed to initialize logging: $($_.Exception.Message)"
    }
}

function Stop-ActivityLogging {
    [CmdletBinding()] param()
    try { Stop-Transcript | Out-Null } catch { }
}

function Get-SSHDConfigEntries {
    [CmdletBinding()] param([string]$Path = 'C:\\ProgramData\\ssh\\sshd_config')
    $entries = @()
    if (Test-Path $Path) {
        $raw = Get-Content -Path $Path -ErrorAction SilentlyContinue
        foreach ($ln in $raw) {
            $t = $ln.Trim()
            if (-not $t) { continue }
            if ($t.StartsWith('#')) { continue }
            $parts = ($t -split '\s+', 2)
            if ($parts.Length -ge 1) {
                $dir = $parts[0]
                $val = if ($parts.Length -eq 2) { $parts[1] } else { '' }
                $entries += [pscustomobject]@{ Directive = $dir; Value = $val }
            }
        }
    }
    return ,$entries
}

function Test-SSHPSRemotingConfigured {
    [CmdletBinding()] param()
    $sshdConfig = 'C:\ProgramData\ssh\sshd_config'
    $hasSubsystem = $false
    if (Test-Path $sshdConfig) {
        try {
            $raw = Get-Content -Path $sshdConfig -ErrorAction Stop
            foreach ($ln in $raw) {
                $t = $ln.Trim()
                if ($t -match '^(#\s*)?Subsystem\s+powershell\b' -and $t -notmatch '^#') { $hasSubsystem = $true; break }
            }
        } catch { $hasSubsystem = $false }
    }
    $svc = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
    $running = ($svc -and $svc.Status -eq 'Running')
    $rule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    $fwEnabled = ($rule -and $rule.Enabled)
    $portOk = $false; try { $portOk = (Test-NetConnection -ComputerName 'localhost' -Port 22 -WarningAction SilentlyContinue).TcpTestSucceeded } catch {}
    [pscustomobject]@{
        HasSubsystem        = $hasSubsystem
        SshdRunning         = $running
        FirewallRuleEnabled = $fwEnabled
        Port22Reachable     = $portOk
        Configured          = ($hasSubsystem -and $running -and $fwEnabled)
    }
}

function Disable-SSHPSRemoting {
    [CmdletBinding()] param()
    Write-Info 'Disabling SSH PowerShell remoting and related services/rules...'
    $sshdConfig = 'C:\ProgramData\ssh\sshd_config'
    if (Test-Path $sshdConfig) {
        try {
            $lines = Get-Content -Path $sshdConfig -ErrorAction Stop
            for ($i=0; $i -lt $lines.Count; $i++) {
                $t = $lines[$i].Trim()
                if ($t -match '^(#\s*)?Subsystem\s+powershell\b' -and $t -notmatch '^#') {
                    $lines[$i] = '# ' + $lines[$i]
                }
            }
            $lines | Out-File -FilePath $sshdConfig -Encoding ascii -Force
            Write-Verbose 'Commented Subsystem powershell line in sshd_config.'
            try { (Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe') -ArgumentList '-t' -NoNewWindow -PassThru -Wait).ExitCode | Out-Null } catch {}
        } catch {
            Write-ErrorDetail -ErrorRecord $_ -Context 'Disable-SSHPSRemoting(Edit sshd_config)'
        }
    }
    try {
        $ruleName = 'OpenSSH-Server-In-TCP'
        if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Out-Null
            Write-Verbose 'Removed firewall rule OpenSSH-Server-In-TCP.'
        }
    } catch {
        Write-ErrorDetail -ErrorRecord $_ -Context 'Disable-SSHPSRemoting(Remove Firewall)'
    }
    foreach ($svcName in 'sshd','ssh-agent') {
        try {
            if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                Set-Service  -Name $svcName -StartupType Disabled -ErrorAction SilentlyContinue
                Write-Verbose ("Disabled service {0}" -f $svcName)
            }
        } catch {
            Write-ErrorDetail -ErrorRecord $_ -Context ("Disable-SSHPSRemoting(Service {0})" -f $svcName)
        }
    }
    try {
        Disable-PSRemoting -Force -ErrorAction SilentlyContinue
        Write-Verbose 'Disabled WSMan-based PowerShell remoting.'
    } catch {
        Write-ErrorDetail -ErrorRecord $_ -Context 'Disable-SSHPSRemoting(WSMan)'
    }
}

function Get-FirewallRuleDetails {
    [CmdletBinding()] param([string]$Name = 'OpenSSH-Server-In-TCP')
    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if (-not $rule) { return $null }
    $port = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Name        = $rule.Name
        DisplayName = $rule.DisplayName
        Enabled     = $rule.Enabled
        Profile     = $rule.Profile
        Direction   = $rule.Direction
        Action      = $rule.Action
        LocalPort   = $port.LocalPort
        Protocol    = $port.Protocol
    }
}

function Get-SSHAuthPreferences {
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$ResolvedPwsh
    )
    $directives = @{}

    # Defaults
    $directives['PubkeyAuthentication']    = 'yes'
    $directives['PasswordAuthentication']  = 'yes'

    Write-Host "Authentication setup" -ForegroundColor Cyan
    $useRsa = Read-Host 'Use RSA public key authentication? [Y]es/[N]o (default: Y)'
    $useRsa = if ([string]::IsNullOrWhiteSpace($useRsa)) { 'Y' } else { $useRsa }

    $keyInfo = $null
    if ($useRsa -match '^(Y|y)') {
        $keyInfo = New-SSHKeyPairIfRequested
        $directives['PubkeyAuthentication'] = 'yes'
        # Optionally offer to disable password auth if keys present
        if ($keyInfo -and $keyInfo.PublicKeyPath) {
            $disablePwd = Read-Host 'Disable PasswordAuthentication (recommended with working keys)? [Y]es/[N]o (default: N)'
            if ($disablePwd -match '^(Y|y)') { $directives['PasswordAuthentication'] = 'no' }
        }
    } else {
        # Guidance on passwords usage patterns
        Write-Host 'No key auth selected.' -ForegroundColor Yellow
        Write-Host 'Manual console auth uses plain text password prompts.' -ForegroundColor Yellow
        Write-Host 'For automation, prefer key-based auth. SSH does not accept a password argument non-interactively.' -ForegroundColor Yellow
        $pwdPref = Read-Host 'Allow plain password prompts? [Y]es (default) / [N]o'
        if ($pwdPref -match '^(N|n)') { $directives['PasswordAuthentication'] = 'no' }
    }

    # Common settings prompts
    $chgPort = Read-Host 'Change default SSH port from 22? Enter port or press Enter to skip'
    if ($chgPort -and ($chgPort -as [int])) { $directives['Port'] = [int]$chgPort }

    $allowUsers = Read-Host 'Restrict to specific users? Enter comma-separated users or press Enter to skip'
    if ($allowUsers) { $directives['AllowUsers'] = ($allowUsers -replace ',\s+', ' ') }

    $allowGroups = Read-Host 'Restrict to specific local groups? Enter comma-separated groups or press Enter to skip'
    if ($allowGroups) { $directives['AllowGroups'] = ($allowGroups -replace ',\s+', ' ') }

    [pscustomobject]@{
        SshdDirectives   = $directives
        KeyInfo          = $keyInfo
        Choices          = [pscustomobject]@{
            UseRSAKeys              = ($useRsa -match '^(Y|y)')
            DisablePasswordAuth     = ($directives['PasswordAuthentication'] -eq 'no')
            CustomPort              = $directives['Port']
            AllowedUsers            = $directives['AllowUsers']
            AllowedGroups           = $directives['AllowGroups']
        }
        Guidance        = 'For scripts, prefer key-based authentication or SSH agent. PowerShell SSH transport does not accept plaintext passwords. For WSMan remoting, you can pass PSCredential.'
    }
}

function New-SSHKeyPairIfRequested {
    [CmdletBinding()] param()
    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if (-not $sshKeygen) { Write-Warning 'ssh-keygen.exe not found in PATH. Skipping key generation.'; return $null }

    $userHome = [Environment]::GetFolderPath('UserProfile')
    $sshDir = Join-Path $userHome '.ssh'
    $null = New-Item -ItemType Directory -Path $sshDir -Force -ErrorAction SilentlyContinue
    $keyPath = Join-Path $sshDir 'id_rsa'
    if (Test-Path $keyPath) {
        $overwrite = Read-Host "Key $keyPath exists. Overwrite? [N]o/[Y]es (default: N)"
        if ($overwrite -notmatch '^(Y|y)') { return [pscustomobject]@{ PrivateKeyPath=$keyPath; PublicKeyPath=("${keyPath}.pub") } }
    }
    $ppAsk = Read-Host 'Protect private key with a passphrase? [Y]es/[N]o (default: Y)'
    $ppAsk = if ([string]::IsNullOrWhiteSpace($ppAsk)) { 'Y' } else { $ppAsk }
    $passArg = if ($ppAsk -match '^(N|n)') { '-N ""' } else { '' }
    $keygenArgs = "-t rsa -b 4096 -f `"$keyPath`" $passArg"
    Write-Host 'Generating RSA 4096 key pair...' -ForegroundColor Cyan
    $p = Start-Process -FilePath $sshKeygen.Source -ArgumentList $keygenArgs -PassThru -Wait -NoNewWindow
    if ($p.ExitCode -ne 0) { Write-Warning 'Key generation failed.'; return $null }

    # Ensure authorized_keys
    $authz = Join-Path $sshDir 'authorized_keys'
    try {
        Get-Content -LiteralPath ("${keyPath}.pub") -ErrorAction Stop | Add-Content -LiteralPath $authz -Encoding ascii
    } catch {
        Write-Warning "Could not append public key to ${authz}: $($_.Exception.Message)"
    }

    # Try to add to ssh-agent
    try {
        $sshAdd = Get-Command ssh-add.exe -ErrorAction SilentlyContinue
        if ($sshAdd) { Start-Process -FilePath $sshAdd.Source -ArgumentList "`"$keyPath`"" -NoNewWindow -Wait | Out-Null }
    } catch { }

    Write-Host "Key pair created: $keyPath (+ .pub). Public key appended to authorized_keys." -ForegroundColor Green
    Write-Host 'Usage:' -ForegroundColor Cyan
    Write-Host ' - Interactive: ssh user@host' -ForegroundColor Gray
    Write-Host ' - PowerShell remoting over SSH: Enter-PSSession -HostName host -UserName user [-KeyFilePath ~/.ssh/id_rsa]' -ForegroundColor Gray
    [pscustomobject]@{ PrivateKeyPath=$keyPath; PublicKeyPath=("$keyPath.pub"); AuthorizedKeys=$authz }
}

function New-SSHRemotingReportHtml {
    [CmdletBinding()] param(
        [Parameter(Mandatory)] [pscustomobject]$Data,
        [Parameter(Mandatory)] [string]$OutputPath
    )
    $bootstrapCss = 'https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css'
    $bootstrapJs  = 'https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js'
    $fontAwesome  = 'https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css'

    $htmlHeader = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>OpenSSH + PowerShell Remoting Report</title>
  <link href="$bootstrapCss" rel="stylesheet" />
  <link href="$fontAwesome" rel="stylesheet" />
  <style>
    body { padding: 1.2rem; }
    .kv { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace; }
    .codebox { background:#0f172a0d; border:1px solid #e2e8f0; border-radius:.5rem; padding:.75rem; }
  </style>
</head>
<body>
<div class="container">
  <div class="d-flex align-items-center mb-3">
    <i class="fa-solid fa-terminal fa-2x text-primary me-2"></i>
    <h2 class="m-0">OpenSSH + PowerShell Remoting Report</h2>
  </div>
  <p class="text-muted">Generated: $([DateTime]::Now.ToString('u')) • Host: $($Data.ComputerName)</p>
"@

    $overview = @"
  <div class="card mb-3">
    <div class="card-header"><i class="fa-solid fa-gauge-high me-1"></i>Overview</div>
    <div class="card-body">
      <div class="row">
        <div class="col-md-6">
          <ul class="list-group">
            <li class="list-group-item d-flex justify-content-between align-items-center">
              Script Version <span class="badge bg-secondary kv">$($Data.ScriptVersion)</span>
            </li>
            <li class="list-group-item d-flex justify-content-between align-items-center">
              PowerShell Required <span class="badge bg-secondary kv">$($Data.RequiredPwshMajor)+</span>
            </li>
            <li class="list-group-item d-flex justify-content-between align-items-center">
              PowerShell Path <span class="badge bg-primary kv">$($Data.PowerShellExePath)</span>
            </li>
            <li class="list-group-item d-flex justify-content-between align-items-center">
              PowerShell Major <span class="badge bg-primary kv">$($Data.PowerShellMajor)</span>
            </li>
          </ul>
        </div>
        <div class="col-md-6">
          <ul class="list-group">
            <li class="list-group-item d-flex justify-content-between align-items-center">
              sshd Status <span class="badge bg-$(if($Data.SSHD.Status -eq 'Running'){'success'}else{'danger'}) kv">$($Data.SSHD.Status)</span>
            </li>
            <li class="list-group-item d-flex justify-content-between align-items-center">
              ssh-agent Status <span class="badge bg-$(if($Data.SSHAgent.Status -eq 'Running'){'success'}else{'danger'}) kv">$($Data.SSHAgent.Status)</span>
            </li>
            <li class="list-group-item d-flex justify-content-between align-items-center">
              Port 22 Reachable <span class="badge bg-$(if($Data.Port22Reachable){'success'}else{'danger'}) kv">$($Data.Port22Reachable)</span>
            </li>
            <li class="list-group-item d-flex justify-content-between align-items-center">
              WSMan Enabled <span class="badge bg-$(if($Data.WSManEnabled){'success'}else{'secondary'}) kv">$($Data.WSManEnabled)</span>
            </li>
          </ul>
        </div>
      </div>
    </div>
  </div>
"@

    $fw = $Data.Firewall
    $firewall = @"
  <div class="card mb-3">
    <div class="card-header"><i class="fa-solid fa-shield-halved me-1"></i>Firewall (OpenSSH-Server-In-TCP)</div>
    <div class="card-body">
      <div class="row">
        <div class="col-md-6">
          <ul class="list-group">
            <li class="list-group-item">Enabled: <span class="kv">$($fw.Enabled)</span></li>
            <li class="list-group-item">Profile: <span class="kv">$($fw.Profile)</span></li>
            <li class="list-group-item">Direction: <span class="kv">$($fw.Direction)</span></li>
          </ul>
        </div>
        <div class="col-md-6">
          <ul class="list-group">
            <li class="list-group-item">Action: <span class="kv">$($fw.Action)</span></li>
            <li class="list-group-item">Protocol: <span class="kv">$($fw.Protocol)</span></li>
            <li class="list-group-item">LocalPort: <span class="kv">$($fw.LocalPort)</span></li>
          </ul>
        </div>
      </div>
      <details class="mt-3">
        <summary><i class="fa-regular fa-circle-question me-1"></i>Explanation</summary>
        <p class="mt-2">Inbound rule allowing TCP/22 to reach the OpenSSH server (sshd). Profiles determine which network types this applies to (Domain, Private, Public). Action must be Allow for connectivity.</p>
      </details>
    </div>
  </div>
"@

    $entries = $Data.SSHDConfig
    $sshdExplain = @{ 
        'Subsystem' = 'Defines a logical service. For PowerShell remoting, this points to pwsh.exe with -sshs.'
        'Port' = 'Specifies the port sshd listens on (default 22).'
        'AddressFamily' = 'Specifies whether sshd uses IPv4, IPv6, or any.'
        'ListenAddress' = 'Binds sshd to specific local addresses.'
        'PasswordAuthentication' = 'Enables password authentication when set to yes.'
        'PubkeyAuthentication' = 'Enables public key authentication when set to yes.'
        'AllowGroups' = 'Restricts login to members of specified groups.'
        'AllowUsers' = 'Restricts login to specified users.'
        'DenyGroups' = 'Denies login to members of specified groups.'
        'DenyUsers' = 'Denies login to specified users.'
        'HostKey' = 'Specifies the private host key files used by sshd.'
        'Ciphers' = 'Lists allowed symmetric ciphers.'
        'MACs' = 'Lists allowed message authentication codes.'
        'KexAlgorithms' = 'Lists allowed key exchange algorithms.'
    }
    $rows = foreach ($e in $entries) {
        $desc = if ($sshdExplain.ContainsKey($e.Directive)) { $sshdExplain[$e.Directive] } else { 'Unknown/other directive. Refer to sshd_config documentation.' }
        "<tr><td class='kv'>$($e.Directive)</td><td class='kv'>$([System.Web.HttpUtility]::HtmlEncode($e.Value))</td><td>$desc</td></tr>"
    }
    $sshdSection = @"
  <div class="card mb-3">
    <div class="card-header"><i class="fa-solid fa-gear me-1"></i>sshd_config</div>
    <div class="card-body">
      <div class="table-responsive">
        <table class="table table-sm table-striped">
          <thead><tr><th>Directive</th><th>Value</th><th>Explanation</th></tr></thead>
          <tbody>
            $([string]::Join([Environment]::NewLine, $rows))
          </tbody>
        </table>
      </div>
      <details class="mt-2"><summary><i class="fa-regular fa-circle-question me-1"></i>Subsystem powershell</summary>
        <div class="mt-2">This line enables PowerShell remoting over SSH transport. The <code>-sshs</code> switch tells PowerShell to run as an SSH subsystem without an interactive prompt, enabling remoting sessions using <code>Enter-PSSession -HostName ...</code>.</div>
      </details>
    </div>
  </div>
"@

    $ps = $Data.PowerShell
    $psSection = @"
  <div class="card mb-4">
    <div class="card-header"><i class="fa-brands fa-windows me-1"></i>PowerShell</div>
    <div class="card-body">
      <ul class="list-group">
        <li class="list-group-item">Path: <span class="kv">$($ps.Path)</span></li>
        <li class="list-group-item">Version Major: <span class="kv">$($ps.Major)</span></li>
        <li class="list-group-item">OpenSSH DefaultShell (HKLM): <span class="kv">$($ps.DefaultShell)</span></li>
      </ul>
      <details class="mt-3"><summary><i class="fa-regular fa-circle-question me-1"></i>DefaultShell</summary>
        <p class="mt-2">When set, interactive <code>ssh</code> logons start this shell by default. This does not affect remoting via the PowerShell SSH subsystem.</p>
      </details>
    </div>
  </div>
"@

    $prefs = $Data.Preferences
    $prefsSection = @()
    if ($prefs) {
        $pRows = @()
        $pRows += "<tr><td>Use RSA Keys</td><td class='kv'>$($prefs.Choices.UseRSAKeys)</td></tr>"
        $pRows += "<tr><td>PasswordAuthentication Disabled</td><td class='kv'>$($prefs.Choices.DisablePasswordAuth)</td></tr>"
        if ($prefs.Choices.CustomPort) { $pRows += "<tr><td>Custom Port</td><td class='kv'>$($prefs.Choices.CustomPort)</td></tr>" }
        if ($prefs.Choices.AllowedUsers) { $pRows += "<tr><td>AllowUsers</td><td class='kv'>$($prefs.Choices.AllowedUsers)</td></tr>" }
        if ($prefs.Choices.AllowedGroups) { $pRows += "<tr><td>AllowGroups</td><td class='kv'>$($prefs.Choices.AllowedGroups)</td></tr>" }
        if ($prefs.KeyInfo) {
            $pRows += "<tr><td>Private Key</td><td class='kv'>$([System.Web.HttpUtility]::HtmlEncode($prefs.KeyInfo.PrivateKeyPath))</td></tr>"
            $pRows += "<tr><td>Public Key</td><td class='kv'>$([System.Web.HttpUtility]::HtmlEncode($prefs.KeyInfo.PublicKeyPath))</td></tr>"
            $pRows += "<tr><td>authorized_keys</td><td class='kv'>$([System.Web.HttpUtility]::HtmlEncode($prefs.KeyInfo.AuthorizedKeys))</td></tr>"
        }
        $prefsSection = @"
  <div class="card mb-4">
    <div class="card-header"><i class="fa-solid fa-user-shield me-1"></i>Authentication Preferences</div>
    <div class="card-body">
      <div class="table-responsive"><table class="table table-sm">
        <tbody>
          $([string]::Join([Environment]::NewLine, $pRows))
        </tbody>
      </table></div>
      <details class="mt-2"><summary><i class="fa-regular fa-circle-question me-1"></i>Guidance</summary>
        <p class="mt-2">$([System.Web.HttpUtility]::HtmlEncode($prefs.Guidance))</p>
      </details>
    </div>
  </div>
"@
    }

    $htmlFooter = @"
</div>
<script src="$bootstrapJs"></script>
</body>
</html>
"@

    $doc = @(
        $htmlHeader,
        $overview,
        $firewall,
        $sshdSection,
        $psSection,
        $prefsSection,
        $htmlFooter
    ) -join [Environment]::NewLine

    $parent = Split-Path -Parent -Path $OutputPath
    $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction SilentlyContinue
    $doc | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
}

function Write-Info {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-ErrorDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context
    )
    $ex = $ErrorRecord.Exception
    $inner = if ($ex.InnerException) { $ex.InnerException.Message } else { $null }
    $msg = @(
        if ($Context) { "Context     : $Context" }
        "Message     : $($ex.Message)"
        if ($inner) { "Inner       : $inner" }
        "Category    : $($ErrorRecord.CategoryInfo.Category)"
        "TargetName  : $($ErrorRecord.CategoryInfo.TargetName)"
        "TargetType  : $($ErrorRecord.CategoryInfo.TargetType)"
        "FullyQualId : $($ErrorRecord.FullyQualifiedErrorId)"
        "ScriptStack : $($ErrorRecord.ScriptStackTrace)"
    ) -join [Environment]::NewLine
    Write-Error $msg
}

function Test-IsAdmin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$current
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-OpenSSHServerIfNeeded {
    [CmdletBinding()]
    param()
    Write-Info 'Checking OpenSSH Server capability...'
    try {
        Write-Verbose 'Querying Windows capabilities for OpenSSH.Server*'
        $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' }
        if (-not $cap) {
            throw 'Unable to query Windows capabilities for OpenSSH.Server.'
        }
        if ($cap.State -ne 'Installed') {
            Write-Info 'Installing OpenSSH Server capability...'
            Write-Verbose ("Add-WindowsCapability -Online -Name {0}" -f $cap.Name)
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
            Write-Info 'OpenSSH Server installed.'
        } else {
            Write-Info 'OpenSSH Server already installed.'
        }
    } catch {
        Write-ErrorDetail -ErrorRecord $_ -Context 'Install-OpenSSHServerIfNeeded'
        throw
    }
}

function Set-OpenSSHServices {
    [CmdletBinding()]
    param()
    Write-Info 'Ensuring OpenSSH services are set to Automatic and running...'
    try {
        foreach ($svc in 'sshd','ssh-agent') {
            Write-Verbose "Checking service: $svc"
            if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
                throw "Service '$svc' not found after installation."
            }
            Write-Verbose "Setting startup type to Automatic for $svc"
            Set-Service -Name $svc -StartupType Automatic
            $state = (Get-Service -Name $svc).Status
            if ($state -ne 'Running') {
                Write-Verbose "Starting service $svc (current: $state)"
                Start-Service -Name $svc
            }
        }
    } catch {
        Write-ErrorDetail -ErrorRecord $_ -Context 'Set-OpenSSHServices'
        throw
    }
}

function Set-OpenSSHFirewallRule {
    [CmdletBinding()]
    param()
    Write-Info 'Validating firewall rule for OpenSSH (TCP/22)...'
    $ruleName = 'OpenSSH-Server-In-TCP'
    try {
        $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
        if ($rule) {
            Write-Verbose "Enabling existing firewall rule $ruleName"
            Enable-NetFirewallRule -Name $ruleName | Out-Null
            Write-Info "Firewall rule '$ruleName' is enabled."
        } else {
            Write-Info "Creating firewall rule '$ruleName'..."
            Write-Verbose 'New-NetFirewallRule -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22'
            New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        }
    } catch {
        Write-ErrorDetail -ErrorRecord $_ -Context 'Set-OpenSSHFirewallRule'
        throw
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

function Get-PwshVersionMajor {
    param([Parameter(Mandatory)][string]$ExePath)
    try {
        $out = & $ExePath -NoLogo -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2>$null
        [int]::Parse(($out | Select-Object -First 1).ToString().Trim())
    } catch { return -1 }
}

function Find-PwshOnDrives {
    [CmdletBinding()] param(
        [string[]]$Drives = $null
    )
    if (-not $Drives) {
        $Drives = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ge 0 } | Select-Object -ExpandProperty Root)
    }
    Write-Info "Searching for pwsh.exe on: $($Drives -join ', ')"
    $found = @()
    foreach ($d in $Drives) {
        try {
            $found += Get-ChildItem -LiteralPath $d -Recurse -Filter 'pwsh.exe' -File -ErrorAction SilentlyContinue
        } catch { }
    }
    return $found | Select-Object -ExpandProperty FullName -Unique
}

function Install-PowerShell7ViaWinget {
    [CmdletBinding()] param()
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wg) { return $false }
    Write-Info 'Installing PowerShell 7 via winget...'
    $wingetArgs = @('install','--id','Microsoft.PowerShell','--source','winget','--silent','--accept-package-agreements','--accept-source-agreements')
    try {
        $p = Start-Process -FilePath $wg.Source -ArgumentList $wingetArgs -PassThru -Wait -NoNewWindow
        return ($p.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function Assert-RequiredPwsh {
    [CmdletBinding()] param(
        [int]$RequiredMajor = 7
    )
    Write-Verbose ("Ensuring required PowerShell major version: {0}" -f $RequiredMajor)
    # Try common locations first
    $path = Get-PowerShellExecutablePath -ErrorAction SilentlyContinue
    if ($path) {
        $maj = Get-PwshVersionMajor -ExePath $path
        if ($maj -ge $RequiredMajor) { return $path }
    }

    Write-Warning ("Required PowerShell {0}+ not found. Current: {1}" -f $RequiredMajor, ($maj | ForEach-Object { $_ }))
    Write-Host 'This script requires PowerShell Core (pwsh) for SSH remoting host.' -ForegroundColor Yellow
    $choice = Read-Host 'Choose: [S]earch disk for pwsh.exe, [D]ownload and install now, [C]ancel'
    switch -Regex ($choice) {
        '^(S|s)' {
            $dr = Read-Host 'Enter drive letters or paths to search (comma-separated) or press Enter for all drives'
            $drives = if ([string]::IsNullOrWhiteSpace($dr)) { $null } else { $dr -split ',\s*' }
            $cands = @(Find-PwshOnDrives -Drives $drives)
            if (-not $cands) { throw 'Search finished: pwsh.exe not found.' }
            Write-Host 'Found candidate pwsh.exe locations:' -ForegroundColor Cyan
            for ($i=0; $i -lt $cands.Count; $i++) { Write-Host ("  [{0}] {1}" -f $i, $cands[$i]) }
            $pick = Read-Host 'Enter index to use'
            if (-not ($pick -as [int])) { throw 'Invalid selection.' }
            $sel = $cands[[int]$pick]
            $vm = Get-PwshVersionMajor -ExePath $sel
            if ($vm -lt $RequiredMajor) { throw "Selected pwsh.exe is version $vm; required $RequiredMajor+." }
            return $sel
        }
        '^(D|d)' {
            if (Install-PowerShell7ViaWinget) {
                # After install, re-detect
                $post = Get-Command pwsh -ErrorAction SilentlyContinue
                if ($post) {
                    $maj2 = Get-PwshVersionMajor -ExePath $post.Source
                    if ($maj2 -ge $RequiredMajor) { return $post.Source }
                }
            }
            Write-Warning 'Automatic install failed or winget not available. Opening download page...'
            Start-Process 'https://github.com/PowerShell/PowerShell/releases/latest' | Out-Null
            throw 'Please install PowerShell 7+ and re-run the script.'
        }
        default { throw 'Required PowerShell not installed. Aborting by user choice.' }
    }
}

function Set-SSHDConfigForPowerShellRemoting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PowerShellExePath,
        [Hashtable]$AdditionalDirectives
    )
    Write-Info 'Configuring sshd_config for PowerShell remoting over SSH...'
    try {
        $sshdConfig = 'C:\ProgramData\ssh\sshd_config'
        if (-not (Test-Path $sshdConfig)) {
            throw "sshd_config not found at '$sshdConfig'."
        }
        $psExeForConfig = ($PowerShellExePath -replace '\\','/')
        $desiredLine = "Subsystem powershell $psExeForConfig -sshs -NoLogo -NoProfile"

        # Backup existing config (ASCII to avoid BOM issues)
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "${sshdConfig}.bak-$timestamp"
        Write-Verbose "Backing up sshd_config to: $backup"
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
        # Apply additional directives if provided
        if ($AdditionalDirectives) {
            foreach ($key in $AdditionalDirectives.Keys) {
                $val = [string]$AdditionalDirectives[$key]
                $applied = $false
                for ($j=0; $j -lt $lines.Count; $j++) {
                    $t = $lines[$j].Trim()
                    if ($t -match ("^(#\\s*)?{0}\\b" -f [Regex]::Escape($key))) {
                        $lines[$j] = ("{0} {1}" -f $key, $val)
                        $applied = $true
                    }
                }
                if (-not $applied) { $lines += ("{0} {1}" -f $key, $val) }
            }
        }
        # Write without BOM; ASCII is accepted by OpenSSH
        Write-Verbose 'Writing updated sshd_config (ASCII encoding)'
        $lines | Out-File -FilePath $sshdConfig -Encoding ascii -Force

        # Validate sshd config syntax
        $sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
        if (-not (Test-Path $sshdExe)) { $sshdExe = 'sshd.exe' }
        Write-Info 'Validating sshd configuration (sshd -t)...'
        $proc = Start-Process -FilePath $sshdExe -ArgumentList '-t' -NoNewWindow -PassThru -Wait
        if ($proc.ExitCode -ne 0) {
            Write-Verbose 'Validation failed; restoring backup and restarting sshd'
            Copy-Item -Path $backup -Destination $sshdConfig -Force
            try { Restart-Service sshd -Force } catch { }
            throw "sshd configuration validation failed with exit code $($proc.ExitCode). Restored from backup: $backup"
        }

        # Restart service to apply changes
        Restart-Service sshd -Force
        Write-Info 'sshd service restarted.'
    } catch {
        Write-ErrorDetail -ErrorRecord $_ -Context 'Set-SSHDConfigForPowerShellRemoting'
        throw
    }
}

function Set-OpenSSHDefaultShell {
    [CmdletBinding()]
    param([string]$PwshPath)
    try {
        Write-Info 'Setting default OpenSSH shell to PowerShell (pwsh/powershell.exe)...'
        Write-Verbose ("Registry HKLM:SOFTWARE\\OpenSSH DefaultShell = {0}" -f $PwshPath)
        New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -Value $PwshPath -PropertyType String -Force | Out-Null
        Write-Info 'Default shell set. (Affects interactive ssh.exe sessions)'
    } catch {
        Write-ErrorDetail -ErrorRecord $_ -Context 'Set-OpenSSHDefaultShell'
        throw
    }
}

function Enable-WSManRemoting {
    [CmdletBinding()]
    param()
    try {
        Write-Info 'Enabling Windows PowerShell remoting over WSMan (Enable-PSRemoting)...'
        Enable-PSRemoting -Force -SkipNetworkProfileCheck
    } catch {
        Write-ErrorDetail -ErrorRecord $_ -Context 'Enable-WSManRemoting'
        throw
    }
}

function Test-SSHServer {
    [CmdletBinding()]
    param()
    Write-Info 'Running validation checks...'
    $result = [ordered]@{}
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    $result['sshd Service Exists'] = [bool]$svc
    $result['sshd Service Status'] = if ($svc) { $svc.Status } else { 'NotFound' }
    $fw = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    $result['Firewall Rule Present'] = [bool]$fw
    $result['Firewall Rule Enabled'] = if ($fw) { $fw.Enabled } else { $false }
    try {
        $tnc = Test-NetConnection -ComputerName 'localhost' -Port 22 -WarningAction SilentlyContinue
        Write-Verbose ("Test-NetConnection localhost:22 → {0}" -f ($tnc.TcpTestSucceeded))
    } catch {
        $tnc = $null
    }
    $result['Port 22 Reachable (localhost)'] = $tnc.TcpTestSucceeded
    $sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    if (-not (Test-Path $sshdExe)) { $sshdExe = 'sshd.exe' }
    try {
        $proc = Start-Process -FilePath $sshdExe -ArgumentList '-t' -NoNewWindow -PassThru -Wait
        $result['sshd -t (Config Valid)'] = ($proc.ExitCode -eq 0)
    } catch {
        $result['sshd -t (Config Valid)'] = $false
    }

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

function Initialize-OpenSSHRemoting {
    [CmdletBinding()] param(
        [switch] $SetDefaultShellToPwsh,
        [switch] $DisableWSManRemoting,
        [int] $RequiredPwshMajor = 7
    )

    try {
        Start-ActivityLogging
        if (-not (Test-IsAdmin)) {
            throw 'This script must be run as Administrator.'
        }

        Write-Info 'Starting OpenSSH Server + PowerShell remoting setup...'
        Write-Verbose 'Begin: Install and configure OpenSSH + remoting'

        # If already configured, ask user for desired action
        $state = Test-SSHPSRemotingConfigured
        if ($state.Configured) {
            Write-Host 'This host appears already configured for PowerShell remoting over SSH.' -ForegroundColor Yellow
            Write-Host (" - Subsystem present: {0}" -f $state.HasSubsystem)
            Write-Host (" - sshd running:   {0}" -f $state.SshdRunning)
            Write-Host (" - Firewall open:  {0}" -f $state.FirewallRuleEnabled)
            $opt = Read-Host 'Choose: [D]isable SSH+remoting, [R]econfigure, [P]roduce report only, [S]kip (default: R)'
            if ([string]::IsNullOrWhiteSpace($opt)) { $opt = 'R' }
            switch -Regex ($opt) {
                '^(D|d)' {
                    Disable-SSHPSRemoting
                    # Create report after disable and exit
                    $psGuess = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
                    if (-not $psGuess) { $psGuess = Get-PowerShellExecutablePath -ErrorAction SilentlyContinue }
                    $psMaj = if ($psGuess) { Get-PwshVersionMajor -ExePath $psGuess } else { -1 }
                    $svcSshd  = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
                    $svcAgent = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
                    $fw       = Get-FirewallRuleDetails -Name 'OpenSSH-Server-In-TCP'
                    $tnc      = $null; try { $tnc = Test-NetConnection -ComputerName 'localhost' -Port 22 -WarningAction SilentlyContinue } catch {}
                    $defShell = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction SilentlyContinue).DefaultShell
                    $wsOk     = $false; try { $wsOk = [bool](Test-WSMan -ComputerName 'localhost' -ErrorAction SilentlyContinue) } catch { $wsOk = $false }
                    $data = [pscustomobject]@{
                        ComputerName      = $env:COMPUTERNAME
                        ScriptVersion     = $Metadata.Version
                        RequiredPwshMajor = $RequiredPwshMajor
                        PowerShellExePath = $psGuess
                        PowerShellMajor   = $psMaj
                        SSHD              = [pscustomobject]@{ Status = if ($svcSshd) { $svcSshd.Status } else { 'NotFound' } }
                        SSHAgent          = [pscustomobject]@{ Status = if ($svcAgent) { $svcAgent.Status } else { 'NotFound' } }
                        Firewall          = $fw
                        Port22Reachable   = if ($tnc) { $tnc.TcpTestSucceeded } else { $false }
                        WSManEnabled      = $wsOk
                        SSHDConfig        = @(Get-SSHDConfigEntries)
                        PowerShell        = [pscustomobject]@{ Path = $psGuess; Major = $psMaj; DefaultShell = $defShell }
                        Preferences       = $null
                    }
                    New-SSHRemotingReportHtml -Data $data -OutputPath $script:ReportFilePath
                    Write-Info ("Report written to: {0}" -f $script:ReportFilePath)
                    return
                }
                '^(P|p)' {
                    # Report only
                    $psGuess = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
                    if (-not $psGuess) { $psGuess = Get-PowerShellExecutablePath -ErrorAction SilentlyContinue }
                    $psMaj = if ($psGuess) { Get-PwshVersionMajor -ExePath $psGuess } else { -1 }
                    $svcSshd  = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
                    $svcAgent = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
                    $fw       = Get-FirewallRuleDetails -Name 'OpenSSH-Server-In-TCP'
                    $tnc      = $null; try { $tnc = Test-NetConnection -ComputerName 'localhost' -Port 22 -WarningAction SilentlyContinue } catch {}
                    $defShell = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction SilentlyContinue).DefaultShell
                    $wsOk     = $false; try { $wsOk = [bool](Test-WSMan -ComputerName 'localhost' -ErrorAction SilentlyContinue) } catch { $wsOk = $false }
                    $data = [pscustomobject]@{
                        ComputerName      = $env:COMPUTERNAME
                        ScriptVersion     = $Metadata.Version
                        RequiredPwshMajor = $RequiredPwshMajor
                        PowerShellExePath = $psGuess
                        PowerShellMajor   = $psMaj
                        SSHD              = [pscustomobject]@{ Status = if ($svcSshd) { $svcSshd.Status } else { 'NotFound' } }
                        SSHAgent          = [pscustomobject]@{ Status = if ($svcAgent) { $svcAgent.Status } else { 'NotFound' } }
                        Firewall          = $fw
                        Port22Reachable   = if ($tnc) { $tnc.TcpTestSucceeded } else { $false }
                        WSManEnabled      = $wsOk
                        SSHDConfig        = @(Get-SSHDConfigEntries)
                        PowerShell        = [pscustomobject]@{ Path = $psGuess; Major = $psMaj; DefaultShell = $defShell }
                        Preferences       = $null
                    }
                    New-SSHRemotingReportHtml -Data $data -OutputPath $script:ReportFilePath
                    Write-Info ("Report written to: {0}" -f $script:ReportFilePath)
                    return
                }
                '^(S|s)' {
                    Write-Host 'Skipping configuration by user request.' -ForegroundColor Yellow
                    return
                }
                default { }
            }
        }

        Install-OpenSSHServerIfNeeded
        Set-OpenSSHServices
        Set-OpenSSHFirewallRule
        $psPath = Assert-RequiredPwsh -RequiredMajor $RequiredPwshMajor

        # Gather authentication and common hardening preferences
        $prefs = Get-SSHAuthPreferences -ResolvedPwsh $psPath

        # Apply sshd_config with additional directives according to preferences
        Set-SSHDConfigForPowerShellRemoting -PowerShellExePath $psPath -AdditionalDirectives $prefs.SshdDirectives
        if ($SetDefaultShellToPwsh) {
            Set-OpenSSHDefaultShell -PwshPath $psPath
        }
        if (-not $DisableWSManRemoting) { Enable-WSManRemoting }

        if (Test-SSHServer) {
            Write-Info 'Setup and validation completed successfully.'
            Write-Host 'You can test PowerShell remoting over SSH with:'
            Write-Host "  Enter-PSSession -HostName localhost -UserName $env:USERNAME" -ForegroundColor Yellow
            Write-Host 'You will be prompted for your password or use keys if configured.'
        } else {
            throw 'One or more validation checks failed. Review the summary above for details.'
        }

        # Collect and write report
        $svcSshd   = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
        $svcAgent  = Get-Service -Name 'ssh-agent' -ErrorAction SilentlyContinue
        $fw        = Get-FirewallRuleDetails -Name 'OpenSSH-Server-In-TCP'
        $tnc       = $null; try { $tnc = Test-NetConnection -ComputerName 'localhost' -Port 22 -WarningAction SilentlyContinue } catch {}
        $defShell  = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction SilentlyContinue).DefaultShell
        $wsOk      = $false; try { $wsOk = [bool](Test-WSMan -ComputerName 'localhost' -ErrorAction SilentlyContinue) } catch { $wsOk = $false }
        $psMaj     = Get-PwshVersionMajor -ExePath $psPath
        $data = [pscustomobject]@{
            ComputerName      = $env:COMPUTERNAME
            ScriptVersion     = $Metadata.Version
            RequiredPwshMajor = $RequiredPwshMajor
            PowerShellExePath = $psPath
            PowerShellMajor   = $psMaj
            SSHD              = [pscustomobject]@{ Status = if ($svcSshd) { $svcSshd.Status } else { 'NotFound' } }
            SSHAgent          = [pscustomobject]@{ Status = if ($svcAgent) { $svcAgent.Status } else { 'NotFound' } }
            Firewall          = $fw
            Port22Reachable   = if ($tnc) { $tnc.TcpTestSucceeded } else { $false }
            WSManEnabled      = $wsOk
            SSHDConfig        = @(Get-SSHDConfigEntries)
            PowerShell        = [pscustomobject]@{ Path = $psPath; Major = $psMaj; DefaultShell = $defShell }
            Preferences       = $prefs
        }
        New-SSHRemotingReportHtml -Data $data -OutputPath $script:ReportFilePath
        Write-Info ("Report written to: {0}" -f $script:ReportFilePath)
    } catch {
        Write-ErrorDetail -ErrorRecord $_ -Context 'Initialize-OpenSSHRemoting'
        throw
    } finally { Stop-ActivityLogging }
}

# Auto-run when executed directly (not dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {
    Initialize-OpenSSHRemoting @PSBoundParameters
}
