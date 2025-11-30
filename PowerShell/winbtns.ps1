# Requires: PowerShell 5.1, run as Administrator

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#--- Basic admin check ---------------------------------------------------------
$windowsIdentity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$windowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($windowsIdentity)

if (-not $windowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show(
        "This tool must be run as Administrator in order to change system settings, group membership, and reboot options.",
        "Administrator Rights Required",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
}

#--- Helper: get current user info --------------------------------------------
$currentUserName      = $windowsIdentity.Name  # e.g. COMPUTER\User or DOMAIN\User
$currentUserParts     = $currentUserName.Split('\')
if ($currentUserParts.Count -eq 2) {
    $currentUserDomainOrComputer = $currentUserParts[0]
    $currentUserSam              = $currentUserParts[1]
} else {
    $currentUserDomainOrComputer = $env:COMPUTERNAME
    $currentUserSam              = $currentUserName
}

#--- Helper: Driver update policy toggles -------------------------------------
function Disable-DriverUpdates {
    try {
        # Policy: "Do not include drivers with Windows Updates"
        $wuKeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        if (-not (Test-Path -LiteralPath $wuKeyPath)) {
            New-Item -Path $wuKeyPath -Force | Out-Null
        }
        New-ItemProperty -Path $wuKeyPath -Name 'ExcludeWUDriversInQualityUpdate' -Value 1 -PropertyType DWord -Force | Out-Null

        # Policy: Turn off searching Windows Update for drivers
        $driverSearchKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
        if (-not (Test-Path -LiteralPath $driverSearchKey)) {
            New-Item -Path $driverSearchKey -Force | Out-Null
        }
        New-ItemProperty -Path $driverSearchKey -Name 'DontSearchWindowsUpdate' -Value 1 -PropertyType DWord -Force | Out-Null

        [System.Windows.Forms.MessageBox]::Show(
            "Windows driver updates have been disabled via policy and registry." + [Environment]::NewLine +
            "These changes generally apply after the next policy refresh or restart.",
            "Driver Updates Disabled",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while disabling driver updates:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Enable-DriverUpdates {
    try {
        $wuKeyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
        if (Test-Path -LiteralPath $wuKeyPath) {
            Remove-ItemProperty -Path $wuKeyPath -Name 'ExcludeWUDriversInQualityUpdate' -ErrorAction SilentlyContinue
        }

        $driverSearchKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching'
        if (Test-Path -LiteralPath $driverSearchKey) {
            Remove-ItemProperty -Path $driverSearchKey -Name 'DontSearchWindowsUpdate' -ErrorAction SilentlyContinue
        }

        [System.Windows.Forms.MessageBox]::Show(
            "Windows driver updates have been re-enabled (policy values removed)." + [Environment]::NewLine +
            "Windows may again download drivers from Windows Update.",
            "Driver Updates Enabled",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while enabling driver updates:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

#--- Helper: Local Administrators membership ----------------------------------
function Add-CurrentUserToLocalAdmins {
    try {
        $localAdminsGroup = [ADSI]"WinNT://./Administrators,group"
        $memberPath       = "WinNT://$currentUserDomainOrComputer/$currentUserSam,user"

        # Check if already a member
        $alreadyMember = $false
        foreach ($member in $localAdminsGroup.psbase.Invoke('Members')) {
            $name = $member.GetType().InvokeMember('Name','GetProperty',$null,$member,$null)
            if ($name -ieq $currentUserSam) {
                $alreadyMember = $true
                break
            }
        }

        if ($alreadyMember) {
            [System.Windows.Forms.MessageBox]::Show(
                "The current user '$currentUserSam' is already in the local Administrators group.",
                "Already Administrator",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        $localAdminsGroup.Add($memberPath)

        [System.Windows.Forms.MessageBox]::Show(
            "The current user '$currentUserSam' has been added to the local Administrators group." + [Environment]::NewLine +
            "You may need to sign out and back in for this to fully take effect.",
            "Privileges Enabled",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while adding the user to Administrators:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Remove-CurrentUserFromLocalAdmins {
    try {
        $localAdminsGroup = [ADSI]"WinNT://./Administrators,group"
        $memberPath       = "WinNT://$currentUserDomainOrComputer/$currentUserSam,user"

        $localAdminsGroup.Remove($memberPath)

        [System.Windows.Forms.MessageBox]::Show(
            "The current user '$currentUserSam' has been removed from the local Administrators group." + [Environment]::NewLine +
            "You may need to sign out and back in for this to fully take effect.",
            "Privileges Disabled",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while removing the user from Administrators:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

#--- Helper: Power actions -----------------------------------------------------
function Invoke-ColdReboot {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will perform a full restart of the computer (bypassing fast startup)." + [Environment]::NewLine +
        "All open applications will be closed.",
        "Confirm Cold Reboot",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        Start-Process -FilePath "shutdown.exe" -ArgumentList "/r","/f","/t","0","/full"
    }
}

function Invoke-HybridShutdown {
    # Note: Windows supports 'hybrid' for shutdown, not restart. This does a fast-startup style shutdown.
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will perform a hybrid shutdown (fast startup)." + [Environment]::NewLine +
        "The PC will power off; when turned back on, it should start faster.",
        "Confirm Hybrid Shutdown",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        Start-Process -FilePath "shutdown.exe" -ArgumentList "/s","/f","/t","0","/hybrid"
    }
}

function Invoke-RebootToFirmware {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will reboot the computer directly into the BIOS/UEFI firmware setup (if supported by the hardware)." + [Environment]::NewLine +
        "All open applications will be closed.",
        "Confirm Reboot to BIOS/UEFI",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        Start-Process -FilePath "shutdown.exe" -ArgumentList "/r","/fw","/f","/t","0"
    }
}

function Invoke-PowerOff {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "This will power off the computer completely." + [Environment]::NewLine +
        "Make sure all work is saved.",
        "Confirm Power Off",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        Start-Process -FilePath "shutdown.exe" -ArgumentList "/s","/f","/t","0"
    }
}

#--- Build GUI -----------------------------------------------------------------
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = "Driver Updates & Privilege Control"
$form.Size             = New-Object System.Drawing.Size(600, 320)
$form.StartPosition    = "CenterScreen"
$form.MaximizeBox      = $false
$form.FormBorderStyle  = [System.Windows.Forms.FormBorderStyle]::FixedDialog

# Layout panel
$table                 = New-Object System.Windows.Forms.TableLayoutPanel
$table.RowCount        = 4
$table.ColumnCount     = 2
$table.Dock            = [System.Windows.Forms.DockStyle]::Fill
$table.Padding         = New-Object System.Windows.Forms.Padding(10)
$table.AutoSize        = $true

# Set equal row/column styles
for ($i = 0; $i -lt $table.ColumnCount; $i++) {
    $colStyle = New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)
    $table.ColumnStyles.Add($colStyle)
}
for ($i = 0; $i -lt $table.RowCount; $i++) {
    $rowStyle = New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 25)
    $table.RowStyles.Add($rowStyle)
}

function New-Button([string]$text) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Dock = [System.Windows.Forms.DockStyle]::Fill
    $btn.Margin = New-Object System.Windows.Forms.Padding(5)
    return $btn
}

$btnDisableDrivers   = New-Button "Disable Driver Updates (WU & Policy)"
$btnEnableDrivers    = New-Button "Enable Driver Updates (WU & Policy)"
$btnGrantAdmin       = New-Button "Turn ON User Privileges (Admin level)"
$btnRevokeAdmin      = New-Button "Turn OFF User Privileges (User level)"
$btnColdReboot       = New-Button "Cold Reboot (Full Restart)"
$btnHybridShutdown   = New-Button "Hybrid Shutdown (Fast Startup)"
$btnRebootFirmware   = New-Button "Reboot to BIOS/UEFI Firmware"
$btnPowerOff         = New-Button "Power Off Computer"

# Wire up events
$btnDisableDrivers.Add_Click({ Disable-DriverUpdates })
$btnEnableDrivers.Add_Click({ Enable-DriverUpdates })
$btnGrantAdmin.Add_Click({ Add-CurrentUserToLocalAdmins })
$btnRevokeAdmin.Add_Click({ Remove-CurrentUserFromLocalAdmins })
$btnColdReboot.Add_Click({ Invoke-ColdReboot })
$btnHybridShutdown.Add_Click({ Invoke-HybridShutdown })
$btnRebootFirmware.Add_Click({ Invoke-RebootToFirmware })
$btnPowerOff.Add_Click({ Invoke-PowerOff })

# Add buttons to table (row, column)
$table.Controls.Add($btnDisableDrivers,  0, 0)
$table.Controls.Add($btnEnableDrivers,   1, 0)
$table.Controls.Add($btnGrantAdmin,      0, 1)
$table.Controls.Add($btnRevokeAdmin,     1, 1)
$table.Controls.Add($btnColdReboot,      0, 2)
$table.Controls.Add($btnHybridShutdown,  1, 2)
$table.Controls.Add($btnRebootFirmware,  0, 3)
$table.Controls.Add($btnPowerOff,        1, 3)

$form.Controls.Add($table)

# Show the form
[void]$form.ShowDialog()
