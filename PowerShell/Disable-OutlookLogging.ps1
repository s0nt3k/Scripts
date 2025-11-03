function Disable-OutlookTroubleshootingLogging {
<#
.SYNOPSIS
2025-11-03 | Project: ToolBox | Func#: TBD
Category: Outlook | Sub: Logging | Version: 0.3
Purpose: Disable Outlook “troubleshooting logging” for the current user with pre/post confirmation popups.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [string[]]$OfficeVersions = @('16.0','15.0','14.0','12.0'),
        [switch]$AlsoDisablePolicy,
        [switch]$AlsoDisableEtlDefault,
        [switch]$RemoveExistingLogs
    )

    begin {
        $results = @()
        $notes = @()
        $userApproved = $false
        $outlookProc = Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue
        $outlookRunning = [bool]$outlookProc
        if ($outlookRunning) { $notes += 'Outlook is running; changes take effect after Outlook restarts.' }

        # --- Pre-execution confirmation popup ---
        if (-not $WhatIfPreference) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                $msg = "This will turn OFF Outlook's 'Troubleshooting Logging' for your account." +
                       "`r`n`r`nWhat this does:" +
                       "`r`n • Stops extra diagnostic logs from being created." +
                       "`r`n • (Optional) Disables policy-based logging and default ETL logging." +
                       (if ($outlookRunning) { "`r`n`r`nOutlook is currently open—please restart it after this change." } else { "" }) +
                       "`r`n`r`nDo you want to continue?"
                $result = [System.Windows.Forms.MessageBox]::Show(
                    $msg,
                    'Confirm: Disable Outlook Troubleshooting Logging',
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { $userApproved = $true }
            } catch {
                # Fallback to console prompt if GUI not available
                $answer = Read-Host "Disable Outlook Troubleshooting Logging now? (Y/N)"
                if ($answer -match '^(y|yes)$') { $userApproved = $true }
            }
        } else {
            # -WhatIf: skip popup; simulate only
            $notes += 'WhatIf mode: no popup shown; no changes will be written.'
            $userApproved = $false
        }

        if (-not $userApproved -and -not $WhatIfPreference) {
            # User cancelled
            $obj = [pscustomobject]@{
                CancelledByUser    = $true
                OutlookRunning     = $outlookRunning
                VersionsProcessed  = $null
                Details            = @()
                Notes              = 'Operation cancelled by user before making changes.'
                NextSteps          = 'No action taken.'
            }
            # Emit object and stop the function
            $obj
            return
        }

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

            # Turn OFF the user preference: EnableLogging = 0
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
                OfficeVersion                         = $ver
                Preference_EnableLogging_Before       = $beforePref
                Preference_EnableLogging_After        = 0
                Policy_EnableLogging_Before           = $beforePolicy
                Policy_EnableLogging_After            = $(if ($AlsoDisablePolicy) { 0 } else { $beforePolicy })
                Policy_DisableDefaultLogging_Before   = $beforeEtl
                Policy_DisableDefaultLogging_After    = $(if ($AlsoDisableEtlDefault) { 1 } else { $beforeEtl })
                Changed                               = $changed
            }
        }

        if ($RemoveExistingLogs) {
            $logDirs = @( Join-Path -Path $env:TEMP -ChildPath 'Outlook Logging' )
            foreach ($d in $logDirs) {
                if (Test-Path -LiteralPath $d) {
                    if ($PSCmdlet.ShouldProcess($d, "Remove log folder")) {
                        try {
                            Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                            $notes += "Deleted: $d"
                        } catch { $notes += "Could not delete: $d ($($_.Exception.Message))" }
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

        # Show post-success confirmation only when not -WhatIf and not cancelled
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
