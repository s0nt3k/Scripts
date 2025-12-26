# Requires: PowerShell 5.1, run as Administrator

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#--- Basic admin check ---------------------------------------------------------
$windowsIdentity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$windowsPrincipal = New-Object System.Security.Principal.WindowsPrincipal($windowsIdentity)

if (-not $windowsPrincipal.IsInRole([System.Security.Principal.WindowsBuiltinRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show(
        "This tool must be run as Administrator to perform system management tasks.",
        "Administrator Rights Required",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    return
}

#--- Helper Functions ----------------------------------------------------------

function Get-SystemInformation {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
        
        $info = @"
Computer Name: $($cs.Name)
OS: $($os.Caption) $($os.Version)
Architecture: $($os.OSArchitecture)
CPU: $($cpu.Name)
Total RAM: $([math]::Round($cs.TotalPhysicalMemory / 1GB, 2)) GB
C: Drive Free: $([math]::Round($disk.FreeSpace / 1GB, 2)) GB / $([math]::Round($disk.Size / 1GB, 2)) GB
Last Boot: $($os.LastBootUpTime)
"@
        
        [System.Windows.Forms.MessageBox]::Show(
            $info,
            "System Information",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while gathering system information:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Invoke-WindowsUpdateCheck {
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "This will check for Windows Updates using the built-in Windows Update service." + [Environment]::NewLine +
            "This may take a few minutes." + [Environment]::NewLine + [Environment]::NewLine +
            "Continue?",
            "Check for Updates",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            $updateSession = $null
            $updateSearcher = $null
            try {
                $updateSession = New-Object -ComObject Microsoft.Update.Session
                $updateSearcher = $updateSession.CreateUpdateSearcher()
                
                $searchResult = $updateSearcher.Search("IsInstalled=0")
                
                if ($searchResult.Updates.Count -eq 0) {
                    [System.Windows.Forms.MessageBox]::Show(
                        "No updates are available.",
                        "Windows Update",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    ) | Out-Null
                }
                else {
                    [System.Windows.Forms.MessageBox]::Show(
                        "$($searchResult.Updates.Count) update(s) available." + [Environment]::NewLine +
                        "Please use Windows Update in Settings to install them.",
                        "Windows Update",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    ) | Out-Null
                }
            }
            finally {
                # Release COM objects
                if ($null -ne $updateSearcher) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null }
                if ($null -ne $updateSession) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($updateSession) | Out-Null }
            }
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while checking for updates:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Invoke-DiskCleanup {
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "This will run the Windows Disk Cleanup utility." + [Environment]::NewLine +
            "You will be prompted to select cleanup options." + [Environment]::NewLine + [Environment]::NewLine +
            "Continue?",
            "Disk Cleanup",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/d C:" -Wait
            
            [System.Windows.Forms.MessageBox]::Show(
                "Disk cleanup completed.",
                "Disk Cleanup",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred during disk cleanup:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Clear-TempFiles {
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "This will delete temporary files from:" + [Environment]::NewLine +
            "- Windows Temp folder" + [Environment]::NewLine +
            "- User Temp folder" + [Environment]::NewLine +
            "- Windows Prefetch folder" + [Environment]::NewLine + [Environment]::NewLine +
            "Some files may be in use and cannot be deleted." + [Environment]::NewLine + [Environment]::NewLine +
            "Continue?",
            "Clear Temporary Files",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            $deletedCount = 0
            $errorCount = 0
            
            $tempPaths = @(
                $env:TEMP,
                "C:\Windows\Temp",
                "C:\Windows\Prefetch"
            )
            
            foreach ($path in $tempPaths) {
                if (Test-Path -Path $path) {
                    Get-ChildItem -Path $path -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                        try {
                            Remove-Item -Path $_.FullName -Force -ErrorAction Stop
                            $deletedCount++
                        }
                        catch {
                            $errorCount++
                        }
                    }
                }
            }
            
            [System.Windows.Forms.MessageBox]::Show(
                "Temporary files cleanup completed." + [Environment]::NewLine +
                "Files deleted: $deletedCount" + [Environment]::NewLine +
                "Files skipped (in use): $errorCount",
                "Clear Temporary Files",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while clearing temp files:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Invoke-NetworkDiagnostics {
    try {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        $ipConfig = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null }
        
        $info = "Active Network Adapters:`r`n`r`n"
        
        foreach ($adapter in $adapters) {
            $info += "Name: $($adapter.Name)`r`n"
            $info += "Status: $($adapter.Status)`r`n"
            $info += "Speed: $($adapter.LinkSpeed)`r`n"
            
            $config = $ipConfig | Where-Object { $_.InterfaceAlias -eq $adapter.Name }
            if ($config) {
                if ($config.IPv4Address -and $config.IPv4Address.Count -gt 0) {
                    $info += "IPv4: $($config.IPv4Address[0].IPAddress)`r`n"
                }
                if ($config.IPv4DefaultGateway -and $config.IPv4DefaultGateway.Count -gt 0) {
                    $info += "Gateway: $($config.IPv4DefaultGateway[0].NextHop)`r`n"
                }
            }
            $info += "`r`n"
        }
        
        [System.Windows.Forms.MessageBox]::Show(
            $info,
            "Network Diagnostics",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred during network diagnostics:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Reset-NetworkStack {
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "This will reset the network stack by:" + [Environment]::NewLine +
            "- Flushing DNS cache" + [Environment]::NewLine +
            "- Resetting Winsock catalog" + [Environment]::NewLine +
            "- Resetting TCP/IP stack" + [Environment]::NewLine + [Environment]::NewLine +
            "A restart may be required after this operation." + [Environment]::NewLine + [Environment]::NewLine +
            "Continue?",
            "Reset Network Stack",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            # Flush DNS
            Clear-DnsClientCache
            
            # Reset Winsock
            Start-Process -FilePath "netsh.exe" -ArgumentList "winsock reset" -Wait -NoNewWindow
            
            # Reset TCP/IP
            Start-Process -FilePath "netsh.exe" -ArgumentList "int ip reset" -Wait -NoNewWindow
            
            [System.Windows.Forms.MessageBox]::Show(
                "Network stack has been reset." + [Environment]::NewLine +
                "Please restart your computer for changes to take full effect.",
                "Network Reset Complete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while resetting network stack:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Invoke-SystemFileCheck {
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "This will run System File Checker (SFC) to scan for and repair corrupted system files." + [Environment]::NewLine +
            "This process may take 10-15 minutes." + [Environment]::NewLine + [Environment]::NewLine +
            "Continue?",
            "System File Checker",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            [System.Windows.Forms.MessageBox]::Show(
                "System File Checker is running..." + [Environment]::NewLine +
                "A command window will open. Please wait for it to complete.",
                "SFC Running",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c sfc /scannow & pause" -Wait
            
            [System.Windows.Forms.MessageBox]::Show(
                "System File Checker has completed." + [Environment]::NewLine +
                "Check the command window for results.",
                "SFC Complete",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while running SFC:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Get-EventLogErrors {
    try {
        $events = Get-EventLog -LogName System -EntryType Error -Newest 10 -ErrorAction Stop
        
        $info = "Last 10 System Event Log Errors:`r`n`r`n"
        
        foreach ($event in $events) {
            $info += "Time: $($event.TimeGenerated)`r`n"
            $info += "Source: $($event.Source)`r`n"
            if ($event.Message) {
                $messagePreview = $event.Message.Substring(0, [Math]::Min(100, $event.Message.Length))
                $info += "Message: $messagePreview...`r`n`r`n"
            }
            else {
                $info += "Message: (No message available)`r`n`r`n"
            }
        }
        
        [System.Windows.Forms.MessageBox]::Show(
            $info,
            "Recent System Errors",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while retrieving event logs:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Invoke-ServiceManager {
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "This will open the Windows Services management console." + [Environment]::NewLine +
            "You can start, stop, and configure services from there." + [Environment]::NewLine + [Environment]::NewLine +
            "Continue?",
            "Service Manager",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath "services.msc"
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while opening Service Manager:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Get-PerformanceInfo {
    try {
        $cpu = Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop
        $mem = Get-CimInstance -ClassName Win32_OperatingSystem
        $disk = Get-Counter '\PhysicalDisk(_Total)\% Disk Time' -ErrorAction Stop
        
        $memUsedPercent = [math]::Round((($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize) * 100, 2)
        
        $info = @"
Current Performance Metrics:

CPU Usage: $([math]::Round($cpu.CounterSamples[0].CookedValue, 2))%
Memory Usage: $memUsedPercent%
Memory Available: $([math]::Round($mem.FreePhysicalMemory / 1MB, 2)) GB
Disk Usage: $([math]::Round($disk.CounterSamples[0].CookedValue, 2))%
"@
        
        [System.Windows.Forms.MessageBox]::Show(
            $info,
            "Performance Information",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred while gathering performance info:" + [Environment]::NewLine + $_.Exception.Message,
            "Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

#--- Build GUI -----------------------------------------------------------------
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = "Windows System Management Tool"
$form.Size             = New-Object System.Drawing.Size(700, 420)
$form.StartPosition    = "CenterScreen"
$form.MaximizeBox      = $false
$form.FormBorderStyle  = [System.Windows.Forms.FormBorderStyle]::FixedDialog

# Layout panel
$table                 = New-Object System.Windows.Forms.TableLayoutPanel
$table.RowCount        = 5
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
    $rowStyle = New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20)
    $table.RowStyles.Add($rowStyle)
}

function New-Button([string]$text) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $text
    $btn.Dock = [System.Windows.Forms.DockStyle]::Fill
    $btn.Margin = New-Object System.Windows.Forms.Padding(5)
    return $btn
}

$btnSystemInfo       = New-Button "System Information"
$btnWindowsUpdate    = New-Button "Check Windows Updates"
$btnDiskCleanup      = New-Button "Disk Cleanup Utility"
$btnClearTemp        = New-Button "Clear Temporary Files"
$btnNetworkDiag      = New-Button "Network Diagnostics"
$btnResetNetwork     = New-Button "Reset Network Stack"
$btnSFC              = New-Button "System File Checker (SFC)"
$btnEventLog         = New-Button "View Recent System Errors"
$btnServices         = New-Button "Open Service Manager"
$btnPerformance      = New-Button "Performance Information"

# Wire up events
$btnSystemInfo.Add_Click({ Get-SystemInformation })
$btnWindowsUpdate.Add_Click({ Invoke-WindowsUpdateCheck })
$btnDiskCleanup.Add_Click({ Invoke-DiskCleanup })
$btnClearTemp.Add_Click({ Clear-TempFiles })
$btnNetworkDiag.Add_Click({ Invoke-NetworkDiagnostics })
$btnResetNetwork.Add_Click({ Reset-NetworkStack })
$btnSFC.Add_Click({ Invoke-SystemFileCheck })
$btnEventLog.Add_Click({ Get-EventLogErrors })
$btnServices.Add_Click({ Invoke-ServiceManager })
$btnPerformance.Add_Click({ Get-PerformanceInfo })

# Add buttons to table (column, row)
$table.Controls.Add($btnSystemInfo,      0, 0)
$table.Controls.Add($btnWindowsUpdate,   1, 0)
$table.Controls.Add($btnDiskCleanup,     0, 1)
$table.Controls.Add($btnClearTemp,       1, 1)
$table.Controls.Add($btnNetworkDiag,     0, 2)
$table.Controls.Add($btnResetNetwork,    1, 2)
$table.Controls.Add($btnSFC,             0, 3)
$table.Controls.Add($btnEventLog,        1, 3)
$table.Controls.Add($btnServices,        0, 4)
$table.Controls.Add($btnPerformance,     1, 4)

$form.Controls.Add($table)

# Show the form
[void]$form.ShowDialog()
