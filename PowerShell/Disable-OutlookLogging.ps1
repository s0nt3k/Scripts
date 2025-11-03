function Disable-OutlookTroubleshootingLogging {
<#
.SYNOPSIS
2025-11-03 | Project: ToolBox | Func#: TBD
Category: Outlook | Sub: Logging | Version: 0.2
Purpose: Disable Outlook “troubleshooting logging” for the current user and show a confirmation popup.
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
        $outlookProc = Get-Process -Name OUTLOOK -ErrorAction SilentlyContinue
        $outlookRunning = [bool]$outlookProc
        $notes = @()
        if ($outlookRunning) { $notes += 'Outlook is running; changes take effect after Outlook restarts.' }

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

        # Show confirmation popup ONLY if we actually executed changes (not -WhatIf)
        if (-not $WhatIfPreference) {
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
                # If the popup fails (e.g., non-interactive host), fall back to a console note
                Write-Host "Outlook Troubleshooting Logging disabled. (Popup unavailable: $($_.Exception.Message))" -ForegroundColor Green
            }
        }

        $obj
    }
}

Disable-OutlookTroubleshootingLogging 
