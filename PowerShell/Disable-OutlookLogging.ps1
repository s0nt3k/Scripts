function Disable-OutlookTroubleshootingLogging {
<#
.SYNOPSIS
Disable Outlook “troubleshooting logging” for the current user with pre/post popups.
.VERSION
0.3 (PowerShell 5.1-compatible)
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        # Common Office/Outlook registry versions (adjust if needed)
        [string[]]$OfficeVersions = @('16.0','15.0','14.0','12.0'),

        # Also write the user policy key so the checkbox is disabled in the UI
        [switch]$AlsoDisablePolicy,

        # Also stop default ETL logging via policy
        [switch]$AlsoDisableEtlDefault,

        # Remove the current user’s temp “Outlook Logging” folder (if present)
        [switch]$RemoveExistingLogs
    )

    begin {
        $results = @()
        $notes = @()
        $userApproved = $false

        # Detect if Outlook is running (helpful for the message)
        $outlookProc = Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue
        $outlookRunning = [bool]$outlookProc
        if ($outlookRunning) { $notes += 'Outlook is running; restart after changes.' }

        # ---- Pre-execution confirmation (GUI with Yes/No; console fallback) ----
        if (-not $WhatIfPreference) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                $msg = "This will turn OFF Outlook's 'Troubleshooting Logging' for your account." +
                       "`r`n`r`nIt will:" +
                       "`r`n • Stop extra diagnostic logs from being created." +
                       (if ($AlsoDisablePolicy)   { "`r`n • Disable the logging option via policy." } else { "" }) +
                       (if ($AlsoDisableEtlDefault) { "`r`n • Stop default ETL logging via policy." } else { "" }) +
                       (if ($RemoveExistingLogs)  { "`r`n • Remove existing 'Outlook Logging' temp files." } else { "" }) +
                       (if ($outlookRunning)      { "`r`n`r`nOutlook is currently open—please restart it after this change." } else { "" }) +
                       "`r`n`r`nDo you want to continue?"
                $result = [System.Windows.Forms.MessageBox]::Show(
                    $msg,
                    'Confirm: Disable Outlook Troubleshooting Logging',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { $userApproved = $true }
            } catch {
                # Non-interactive/Server Core fallback
                $answer = Read-Host "Disable Outlook Troubleshooting Logging now? (Y/N)"
                if ($answer -match '^(y|yes)$') { $userApproved = $true }
            }
        } else {
            $notes += 'WhatIf mode: simulation only; no popups, no changes.'
        }

        if (-not $userApproved -and -not $WhatIfPreference) {
            [pscustomobject]@{
                CancelledByUser    = $true
                OutlookRunning     = $outlookRunning
                VersionsProcessed  = $null
                Details            = @()
                Notes              = 'Operation cancelled before making changes.'
                NextSteps          = 'No action taken.'
            }
            return
        }

        # --- Helpers (5.1-safe) ---
        function Set-Dword {
            param(
                [Parameter(Mandatory)] [string]$Path,
                [Parameter(Mandatory)] [string]$Name,
                [Parameter(Mandatory)] [int]$Value
            )
            if (-not (Test-Path -LiteralPath $Path)) {
                if ($PSCmdlet.ShouldProcess($Path, "Create registry key")) {
                    New-Item -Path $Path -Force | Out-Null
                }
            }
            if ($PSCmdlet.ShouldProcess("$Path\\$Name", "Set DWORD=$Value")) {
                New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
            }
        }

        function Get-CurrentValue {
            param([string]$Path, [string]$Name)
            try {
                if (Test-Path -LiteralPath $Path) {
                    $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
                    if ($null -ne $prop) { return [int]$prop.$Name }
                }
            } catch { }
            return $null
        }
    }

    process {
        foreach ($ver in $OfficeVersions) {
            $changed = $false
            $prefPath   = "HKCU:\Software\Microsoft\Office\$ver\Outlook\Options\Mail"
            $policyPath = "HKCU:\Software\Policies\Microsoft\Office\$ver\Outlook\Options\Mail"
            $etlPath    = "HKCU:\Software\Policies\Microsoft\Office\$ver\Outlook\Logging"

            $beforePref   = Get-CurrentValue -Path $prefPath   -Name 'EnableLogging'
            $beforePolicy = Get-CurrentValue -Path $policyPath -Name 'EnableLogging'
            $beforeEtl    = Get-CurrentValue -Path $etlPath    -Name 'DisableDefaultLogging'

            # Disable the user preference toggle
            Set-Dword -Path $prefPath -Name 'EnableLogging' -Value 0
            $afterPref = 0
            $changed = $changed -or ($beforePref -ne $afterPref)

            if ($AlsoDisablePolicy) {
                Set-Dword -Path $policyPath -Name 'EnableLogging' -Value 0
                $afterPolicy = 0
                $changed = $changed -or ($beforePolicy -ne $afterPolicy)
            }

            if ($AlsoDisableEtlDefault) {
                Set-Dword -Path $etlPath -Name 'DisableDefaultLogging' -Value 1
                $afterEtl = 1
                $changed = $changed -or ($beforeEtl -ne $afterEtl)
            }

            $results += [pscustomobject]@{
                OfficeVersion                       = $ver
                Preference_EnableLogging_Before     = $beforePref
                Preference_EnableLogging_After      = 0
                Policy_EnableLogging_Before         = $beforePolicy
                Policy_EnableLogging_After          = $(if ($AlsoDisablePolicy) { 0 } else { $beforePolicy })
                Policy_DisableDefaultLogging_Before = $beforeEtl
                Policy_DisableDefaultLogging_After  = $(if ($AlsoDisableEtlDefault) { 1 } else { $beforeEtl })
                Changed                             = $changed
            }
        }

        if ($RemoveExistingLogs) {
            $logDir = Join-Path -Path $env:TEMP -ChildPath 'Outlook Logging'
            if (Test-Path -LiteralPath $logDir) {
                if ($PSCmdlet.ShouldProcess($logDir, "Remove log folder")) {
                    try {
                        Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction Stop
                        $notes += "Deleted: $logDir"
                    } catch {
                        $notes += "Could not delete: $logDir ($($_.Exception.Message))"
                    }
                }
            }
        }
    }

    end {
        $obj = [pscustomobject]@{
            OutlookRunning     = $outlookRunning
            VersionsProcessed  = ($results.OfficeVersion -join ', ')
            Details            = $results
            Notes              = ($notes -join '; ')
            NextSteps          = 'Restart Outlook to apply changes.'
        }

        # Post-success popup (skip in -WhatIf)
        if (-not $WhatIfPreference -and $results.Count -gt 0) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                $msg = "Outlook Troubleshooting Logging has been disabled for this user."
                if ($outlookRunning) { $msg += "`r`n`r`nPlease restart Outlook to apply the change." }
                [void][System.Windows.Forms.MessageBox]::Show(
                    $msg,
                    'Outlook Logging Disabled',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                )
            } catch {
                Write-Host "Outlook Troubleshooting Logging disabled. (Popup unavailable: $($_.Exception.Message))" -ForegroundColor Green
            }
        }

        $obj
    }
}

Disable-OutlookTroubleshootingLogging
