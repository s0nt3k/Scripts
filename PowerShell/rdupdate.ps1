function Set-RustDeskClientConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # FQDN (optionally :port) of your RustDesk ID (signal) server.
        [ValidateNotNullOrEmpty()]
        [string]$IdServerFqdn='remote.mynetworkroute.com',

        # Public Key from your RustDesk server (not a license key).
        [ValidateNotNullOrEmpty()]
        [string]$Key='qi1fihIs5XM83ekptuva2gx61TmJzZ+gv2fneqA9I5M=',

        # Permanent unattended password (SecureString only to satisfy PSScriptAnalyzer).
        [Parameter(Mandatory)]
        [System.Security.SecureString]$PermanentPassword='vYFL@#\03Dz@WLK1i9Hxg6mi1mZb',

        # Optional: override the default per-user RustDesk2.toml path.
        [string]$ConfigPath,

        # Also try to configure the LocalService (Windows Service) profile copies.
        [switch]$IncludeServiceContext,

        # Optional: explicit path to rustdesk.exe
        [string]$RustDeskExePath
    )

    begin {
        # --- Minimal metadata hashtable (inside function; no code before begin) ---
        $Meta = @{
            Timestamp   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Project     = 'ToolkIT'
            FuncNum     = '001'
            Category    = 'RemoteAccess'
            Subcategory = 'RustDesk'
            Version     = '0.3'
            Synopsis    = 'Configure RustDesk client (ID server, Key) and set a permanent password.'
        }

        # Regex options constant
        $rxIgnoreMulti = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor `
                         [System.Text.RegularExpressions.RegexOptions]::Multiline

        function Get-RustDeskExePath {
            param([string]$Hint)
            if ($Hint -and (Test-Path -LiteralPath $Hint)) { return (Resolve-Path -LiteralPath $Hint).Path }

            $candidates = @(
                "$Env:ProgramFiles\RustDesk\rustdesk.exe",
                "$Env:ProgramFiles(x86)\RustDesk\rustdesk.exe",
                "$Env:LOCALAPPDATA\Programs\rustdesk\rustdesk.exe"
            )
            $fromPath = (Get-Command rustdesk.exe -ErrorAction SilentlyContinue)?.Source
            if ($fromPath) { $candidates = ,$fromPath + $candidates }

            foreach ($p in $candidates) {
                if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
            }
            return $null
        }

        function Get-RustDeskUserConfigPath {
            if ($PSBoundParameters.ContainsKey('ConfigPath') -and $ConfigPath) { return $ConfigPath }
            Join-Path $Env:APPDATA 'RustDesk\config\RustDesk2.toml'
        }

        function Get-RustDeskServiceConfigPath {
            $base = 'C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk\config'
            @(
                Join-Path $base 'RustDesk2.toml',
                Join-Path $base 'RustDesk.toml'
            ) | Where-Object { $_ }
        }

        function Set-RustDeskClientOptions {
            param(
                [Parameter(Mandatory)][string]$TomlPath,
                [Parameter(Mandatory)][string]$IdServer,
                [Parameter(Mandatory)][string]$PubKey
            )

            $dir = Split-Path -LiteralPath $TomlPath -Parent
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }

            $content = ''
            if (Test-Path -LiteralPath $TomlPath) {
                $backup = "$TomlPath.bak.{0:yyyyMMdd_HHmmss}" -f (Get-Date)
                Copy-Item -LiteralPath $TomlPath -Destination $backup -Force
                $content = Get-Content -LiteralPath $TomlPath -Raw
            }
            if ([string]::IsNullOrWhiteSpace($content)) { $content = "[options]`n" }

            # Ensure [options] section exists
            if (-not [regex]::IsMatch($content, '^\s*\[options\]\s*$', $rxIgnoreMulti)) {
                $content = ($content.TrimEnd() + "`r`n`r`n[options]`r`n")
            }

            # Normalize server (append default 21116 if no port)
            $normalizedIdServer = if ($IdServer -match ':\d+$') { $IdServer } else { "$IdServer:21116" }

            # Locate [options] block
            $lines  = $content -split "`r?`n"
            $start  = ($lines | Select-String -Pattern '^\s*\[options\]\s*$' -CaseSensitive:$false).LineNumber
            if (-not $start) { throw "Failed to locate [options] section after insertion." }
            $start-- # zero-based

            $nextHdr = ($lines[($start+1)..($lines.Length-1)] |
                        Select-String -Pattern '^\s*\[.*?\]\s*$' -CaseSensitive:$false |
                        Select-Object -First 1).LineNumber
            $end = if ($nextHdr) { $start + $nextHdr } else { $lines.Length }

            $optionsBlock = $lines[($start+1)..($end-1)] -join "`r`n"

            # Upsert id-server
            if ([regex]::IsMatch($optionsBlock, '^\s*id-server\s*=\s*".*"\s*$', $rxIgnoreMulti)) {
                $optionsBlock = [regex]::Replace(
                    $optionsBlock, '^\s*id-server\s*=\s*".*"\s*$',
                    ('id-server = "' + $normalizedIdServer + '"'), $rxIgnoreMulti
                )
            } else {
                $optionsBlock = 'id-server = "' + $normalizedIdServer + '"' + "`r`n" + $optionsBlock
            }

            # Upsert key
            if ([regex]::IsMatch($optionsBlock, '^\s*key\s*=\s*".*"\s*$', $rxIgnoreMulti)) {
                $optionsBlock = [regex]::Replace(
                    $optionsBlock, '^\s*key\s*=\s*".*"\s*$',
                    ('key = "' + $PubKey + '"'), $rxIgnoreMulti
                )
            } else {
                $optionsBlock = 'key = "' + $PubKey + '"' + "`r`n" + $optionsBlock
            }

            # Rebuild file
            $newLines = @()
            if ($start -gt 0) { $newLines += $lines[0..$start] } else { $newLines += $lines[0] }
            $newLines += ($optionsBlock -split "`r?`n")
            if ($end -lt $lines.Length) { $newLines += $lines[$end..($lines.Length-1)] }

            $newContent = ($newLines -join "`r`n")
            Set-Content -LiteralPath $TomlPath -Value $newContent -Encoding UTF8 -Force
            return $TomlPath
        }

        # Resolve rustdesk.exe once
        $ExePath = Get-RustDeskExePath -Hint $RustDeskExePath
        if (-not $ExePath) {
            Write-Warning "Could not locate rustdesk.exe automatically. You can pass -RustDeskExePath."
        }
    }

    process {
        # 1) Update per-user TOML
        $userToml = Get-RustDeskUserConfigPath
        if ($PSCmdlet.ShouldProcess($userToml, "Set [options] id-server/key")) {
            Set-RustDeskClientOptions -TomlPath $userToml -IdServer $IdServerFqdn -PubKey $Key | Out-Null
            Write-Verbose "Updated user config: $userToml"
        }

        # 2) Optionally update service context TOMLs (best-effort)
        $svcPaths = @()
        if ($IncludeServiceContext) {
            foreach ($svcToml in Get-RustDeskServiceConfigPath) {
                if ($PSCmdlet.ShouldProcess($svcToml, "Set [options] id-server/key (service context)")) {
                    try {
                        Set-RustDeskClientOptions -TomlPath $svcToml -IdServer $IdServerFqdn -PubKey $Key | Out-Null
                        $svcPaths += $svcToml
                        Write-Verbose "Updated service config: $svcToml"
                    } catch {
                        Write-Warning "Failed to update service config at $svcToml : $($_.Exception.Message)"
                    }
                }
            }
        }

        # 3) Set permanent password via rustdesk.exe --password (convert SecureString just-in-time)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PermanentPassword)
        )
        try {
            if ($ExePath) {
                if ($PSCmdlet.ShouldProcess($ExePath, "Set permanent password")) {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName  = $ExePath
                    $psi.Arguments = "--password `"$plain`""
                    $psi.UseShellExecute = $false
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError  = $true

                    $p = [System.Diagnostics.Process]::Start($psi)
                    $out = $p.StandardOutput.ReadToEnd()
                    $err = $p.StandardError.ReadToEnd()
                    $p.WaitForExit()

                    if ($p.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($err)) {
                        Write-Warning "rustdesk.exe exit code $($p.ExitCode): $err"
                    } else {
                        Write-Verbose "rustdesk.exe output: $out"
                    }
                }
            } else {
                Write-Warning "Permanent password not set because rustdesk.exe was not found."
            }
        }
        finally {
            if ($plain) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR([System.Runtime.InteropServices.Marshal]::StringToBSTR($plain)) | Out-Null }
        }

        # 4) Summary object
        [pscustomobject]@{
            Meta                  = $Meta
            RustDeskExe           = $ExePath
            UserConfigPath        = $userToml
            ServiceConfigPaths    = ($svcPaths -join '; ')
            IdServerConfigured    = $IdServerFqdn
            KeyConfiguredPreview  = ('*' * [Math]::Min($Key.Length, 8)) + '…'
            PermanentPasswordSet  = [bool]$ExePath
            Timestamp             = (Get-Date)
        }
    }

    end { }
}
