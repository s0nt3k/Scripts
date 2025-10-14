<#
.SYNOPSIS
  SaRA Enterprise helper with boxed console menu (single-key), freshness indicator, and Outlook diagnostics.

.DESCRIPTION
  - ZIP → $PSScriptRoot\xTemp, Extract → $PSScriptRoot\Assets\SaRA (uses DONE file to skip re-download).
  - On start: shows SaRA freshness tag (> or < 168 hours) and appends same tag to the R) line in the menu.
  - Reports saved to: $PSScriptRoot\Reports\$Env:ComputerName\Office\
    * Artifact filenames prefixed with UNIXtimestamp_ (e.g., 1726530000_report.html)
    * Summary: UNIXtimestamp_SaRA_Summary.txt
  - Menu (single key): Office activation/scrub/repair + Outlook Scan + Outlook Calendar Scan + Teams Add-in fix + Open Reports Folder.
  - Menu styles loaded from .\Data\menusettings.psd1 (deep-merged with defaults; supports Margin.Left/Top).

.NOTES
  Run elevated for activation/scrub/repair; run non-elevated for Outlook/Calendar/Teams scenarios for best results.
  Author: ChatGPT (for Sonny Gibson)
  Version: 1.7
#>

###### CONSOLE WINDOW CONFIGURATION SETTINGS ######

    # Set custom title for PowerShell window
    $host.ui.RawUI.WindowTitle = "🧰 Cybtek STK v3.0.0 (Delta)"

    # Set width to 120 characters and height to 40 lines
    $host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(76, 20)

    # Optionally, also set the buffer size if needed
    $host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(120, 200)

    # Set background to dark blue and foreground (text) to white
    $Host.UI.RawUI.BackgroundColor = 'Black'
    $Host.UI.RawUI.ForegroundColor = 'White'

    Add-Type -AssemblyName System.Windows.Forms
    Clear-Host

Function StartRepair {
[CmdletBinding()]
param()

#region --- Utility: Admin check, paths, IO helpers ---

function Test-IsAdmin {
    [CmdletBinding()]
    param()
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        Write-Warning ("Failed to check elevation: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Get-ToolPaths {
    [CmdletBinding()]
    param()

    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Path $MyInvocation.MyCommand.Path -Parent }

    $tempRoot   = Join-Path -Path $root -ChildPath "xTemp"
    $assets     = Join-Path -Path $root -ChildPath "Assets"
    $saraRoot   = Join-Path -Path $assets -ChildPath "SaRA"
    $zipPath    = Join-Path -Path $tempRoot -ChildPath "SaRA_Enterprise.zip"
    $reportsTop = Join-Path -Path $root -ChildPath "Reports"
    $reportsDir = Join-Path -Path $reportsTop -ChildPath (Join-Path $env:ComputerName "Office")
    $donePath   = Join-Path -Path $saraRoot -ChildPath "DONE"

    return [PSCustomObject]@{
        Root       = $root
        TempRoot   = $tempRoot
        Assets     = $assets
        SaraRoot   = $saraRoot
        Zip        = $zipPath
        ReportsTop = $reportsTop
        ReportsDir = $reportsDir
        Done       = $donePath
    }
}

function Ensure-Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-UnixTimestamp {
    [CmdletBinding()]
    param()
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

#endregion

#region --- SaRA install / status / freshness ---

function Get-SaRAStatus {
    [CmdletBinding()]
    param()

    $paths = Get-ToolPaths
    $saraCmd = $null
    if (Test-Path -Path $paths.SaraRoot) {
        $saraCmd = Get-ChildItem -Path $paths.SaraRoot -Recurse -Filter "SaRAcmd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    $installed = [bool]$saraCmd
    $lastDownload = $null
    if (Test-Path -Path $paths.Done) {
        try {
            $content = Get-Content -Path $paths.Done -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($content)) {
                $lastDownload = [datetime]::Parse($content)
            }
        } catch { }
        if (-not $lastDownload) {
            try { $lastDownload = (Get-Item -Path $paths.Done).LastWriteTime } catch { }
        }
    }

    [PSCustomObject]@{
        Installed     = $installed
        SaraCmdPath   = if ($saraCmd) { $saraCmd.FullName } else { $null }
        LastDownload  = $lastDownload
        Paths         = $paths
    }
}

function Install-SaRAEnterprise {
    [CmdletBinding()]
    param(
        [string]$DownloadUrl = "https://aka.ms/SaRA_EnterpriseVersionFiles"
    )
    $paths = Get-ToolPaths
    Ensure-Directory -Path $paths.TempRoot
    Ensure-Directory -Path $paths.Assets

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    } catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    Write-Host "Downloading SaRA Enterprise package..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $paths.Zip -UseBasicParsing
    } catch {
        throw ("Download failed from {0}: {1}" -f $DownloadUrl, $_.Exception.Message)
    }

    Write-Host ("Extracting to: {0}" -f $paths.SaraRoot) -ForegroundColor Cyan
    try {
        if (Test-Path -Path $paths.SaraRoot) {
            Remove-Item -Path $paths.SaraRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        Ensure-Directory -Path $paths.SaraRoot
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($paths.Zip, $paths.SaraRoot)
    } catch {
        throw ("Extraction failed: {0}" -f $_.Exception.Message)
    }

    # Stamp DONE file
    try {
        [System.IO.File]::WriteAllText($paths.Done, (Get-Date).ToString("o"))
    } catch {
        Write-Warning ("Failed to write DONE file at {0}" -f $paths.Done)
    }

    $saraCmd = Get-ChildItem -Path $paths.SaraRoot -Recurse -Filter "SaRAcmd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $saraCmd) {
        throw "SaRAcmd.exe not found after extraction."
    }

    return [PSCustomObject]@{
        SaraCmdPath = $saraCmd.FullName
        Paths       = $paths
    }
}

function Ensure-SaRAEnterprise {
    [CmdletBinding()]
    param([switch]$Force)

    $status = Get-SaRAStatus
    if (-not $Force.IsPresent -and $status.Installed) {
        return [PSCustomObject]@{
            SaraCmdPath = $status.SaraCmdPath
            Paths       = $status.Paths
        }
    }
    return (Install-SaRAEnterprise)
}

function Get-SaRAFreshnessTag {
    [CmdletBinding()]
    param()

    $status = Get-SaRAStatus
    if (-not $status.Installed -or -not $status.LastDownload) {
        return [PSCustomObject]@{
            TagText  = " (Not downloaded yet.)"
            Color    = "DarkYellow"
            Installed = $false
        }
    }

    $age = (Get-Date) - $status.LastDownload
    if ($age.TotalHours -gt 168) {
        return [PSCustomObject]@{
            TagText  = " (Updated > 168 Hours)"
            Color    = "Red"
            Installed = $true
        }
    } else {
        return [PSCustomObject]@{
            TagText  = " (Updated < 168 Hours)"
            Color    = "DarkGreen"
            Installed = $true
        }
    }
}

#endregion

#region --- Office repair actions (SaRA + Click-to-Run) ---

function Invoke-SaRAResetOfficeActivation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SaraCmdPath)
    $args = @("-S","ResetOfficeActivation","-AcceptEula","-CloseOffice")
    Write-Host "Running SaRA: Reset Office Activation..." -ForegroundColor Yellow
    Start-Process -FilePath $SaraCmdPath -ArgumentList $args -Wait -WindowStyle Normal
}

function Invoke-SaRAOfficeScrub {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SaraCmdPath,
        [ValidateSet("All","M365","2019","2016","2013","2010")]
        [string]$OfficeVersion = "All"
    )
    Write-Warning "This will uninstall/clean Office ($OfficeVersion). Save work and close apps."
    $confirm = Read-Host "Type YES to proceed"
    if ($confirm -ne "YES") { Write-Host "Cancelled." -ForegroundColor DarkGray; return }

    $args = @("-S","OfficeScrubScenario","-AcceptEula","-OfficeVersion",$OfficeVersion)
    Start-Process -FilePath $SaraCmdPath -ArgumentList $args -Wait -WindowStyle Normal
}

function Get-OfficeClickToRunPath {
    [CmdletBinding()]
    param()
    $candidates = @(
        "C:\Program Files\Microsoft Office\root\Client\OfficeClickToRun.exe",
        "C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe",
        "C:\Program Files (x86)\Microsoft Office\root\Client\OfficeClickToRun.exe",
        "C:\Program Files\Microsoft Office 15\ClientX64\OfficeClickToRun.exe",
        "C:\Program Files\Microsoft Office 15\ClientX86\OfficeClickToRun.exe"
    )
    foreach ($p in $candidates) { if (Test-Path -Path $p) { return $p } }
    return $null
}

function Invoke-OfficeRepair {
    [CmdletBinding()]
    param(
        [ValidateSet("QuickRepair","FullRepair")][string]$RepairType = "QuickRepair",
        [ValidateSet("x64","x86")][string]$Platform = $(if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }),
        [string]$Culture = "en-us",
        [switch]$Silent
    )

    $c2r = Get-OfficeClickToRunPath
    if (-not $c2r) { Write-Error "OfficeClickToRun.exe not found. Office Click-to-Run may not be installed."; return }

    $display = if ($Silent.IsPresent) { "false" } else { "true" }
    $args = @(
        "scenario=Repair",
        ("platform={0}" -f $Platform),
        ("culture={0}" -f $Culture),
        "forceappshutdown=true",
        ("RepairType={0}" -f $RepairType),
        ("DisplayLevel={0}" -f $display)
    ) -join " "

    Write-Host ("Starting Office {0}..." -f $RepairType) -ForegroundColor Yellow
    Start-Process -FilePath $c2r -ArgumentList $args -Wait -WindowStyle Normal
}

#endregion

#region --- Reports: target folder and artifact handling ---

function Get-ReportsFolder {
    [CmdletBinding()]
    param()
    $paths = Get-ToolPaths
    Ensure-Directory -Path $paths.ReportsDir
    return $paths.ReportsDir
}

function Copy-SaRAArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][long]$UnixTimestamp
    )
    $src = Join-Path -Path $env:LOCALAPPDATA -ChildPath "saralogs\UploadLogs"
    if (-not (Test-Path -Path $src)) { return @() }
    $prefix = "{0}_" -f $UnixTimestamp
    $copied = @()
    Get-ChildItem -Path $src -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $targetName = $prefix + $_.Name
            $destFile   = Join-Path -Path $Destination -ChildPath $targetName
            Copy-Item -Path $_.FullName -Destination $destFile -Force
            $copied += $destFile
        } catch { }
    }
    return $copied
}

function Convert-HtmlToText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$HtmlPath)
    try {
        $raw = Get-Content -Path $HtmlPath -Raw -ErrorAction Stop
        $text = $raw -replace '<script[^>]*>.*?</script>','' -replace '<style[^>]*>.*?</style>',''
        $text = $text -replace '<[^>]+>',''
        $text = $text -replace '&nbsp;',' ' -replace '&amp;','&' -replace '&gt;','>' -replace '&lt;','<'
        $lines = ($text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
        return ($lines -join [Environment]::NewLine)
    } catch { return "" }
}

function Write-TextSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$HtmlFiles,
        [Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)][long]$UnixTimestamp
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("SaRA Report Summary")
    [void]$sb.AppendLine(("Generated (local): {0}" -f (Get-Date)))
    [void]$sb.AppendLine(("Host: {0}" -f $env:COMPUTERNAME))
    [void]$sb.AppendLine("")

    foreach ($f in $HtmlFiles) {
        $txt = Convert-HtmlToText -HtmlPath $f
        if (-not [string]::IsNullOrWhiteSpace($txt)) {
            [void]$sb.AppendLine(("===== {0} =====" -f (Split-Path -Path $f -Leaf)))
            $lines = $txt -split "`r?`n"
            $max = [Math]::Min($lines.Count, 2000)
            for ($i=0; $i -lt $max; $i++) { [void]$sb.AppendLine($lines[$i]) }
            [void]$sb.AppendLine("")
        }
    }

    $outFile = Join-Path -Path $OutDir -ChildPath ("{0}_SaRA_Summary.txt" -f $UnixTimestamp)
    [System.IO.File]::WriteAllText($outFile, $sb.ToString(), [System.Text.Encoding]::UTF8)
    return $outFile
}

#endregion

#region --- Outlook/Calendar/Teams SaRA scenarios (use report folder & UNIX prefix) ---

function Invoke-SaRAOutlookScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SaraCmdPath)

    $dest = Get-ReportsFolder
    $unix = Get-UnixTimestamp
    Write-Host ("Running SaRA: Outlook Scan (comprehensive). Reports → {0}" -f $dest) -ForegroundColor Yellow

    if (Test-IsAdmin) {
        Write-Warning "This scan works best from a NON-admin PowerShell. Re-run non-elevated if results are incomplete."
    }

    $args = @("-S","ExpertExperienceAdminTask","-AcceptEula")
    Start-Process -FilePath $SaraCmdPath -ArgumentList $args -Wait -WindowStyle Normal

    $files = Copy-SaRAArtifacts -Destination $dest -UnixTimestamp $unix
    $htmls = $files | Where-Object { $_ -match '\.html?$' }
    if ($htmls.Count -gt 0) {
        $txt = Write-TextSummary -HtmlFiles $htmls -OutDir $dest -UnixTimestamp $unix
        Write-Host ("Saved: {0}" -f $txt) -ForegroundColor Green
    } else {
        Write-Warning "No HTML artifacts were found in UploadLogs; check SaRA output."
    }
}

function Invoke-SaRAOutlookCalendarScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SaraCmdPath)

    $dest = Get-ReportsFolder
    $unix = Get-UnixTimestamp
    Write-Host ("Running SaRA: Outlook Calendar Scan. Reports → {0}" -f $dest) -ForegroundColor Yellow

    if (Test-IsAdmin) {
        Write-Warning "This scan works best from a NON-admin PowerShell. Re-run non-elevated if results are incomplete."
    }

    $args = @("-S","OutlookCalendarCheckTask","-AcceptEula")
    Start-Process -FilePath $SaraCmdPath -ArgumentList $args -Wait -WindowStyle Normal

    $files = Copy-SaRAArtifacts -Destination $dest -UnixTimestamp $unix
    $htmls = $files | Where-Object { $_ -match '\.html?$' }
    if ($htmls.Count -gt 0) {
        $txt = Write-TextSummary -HtmlFiles $htmls -OutDir $dest -UnixTimestamp $unix
        Write-Host ("Saved: {0}" -f $txt) -ForegroundColor Green
    } else {
        Write-Warning "No HTML artifacts were found in UploadLogs; check SaRA output."
    }
}

function Invoke-SaRATeamsAddInFix {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SaraCmdPath)

    if (Test-IsAdmin) { Write-Warning "Run NON-admin for Teams Add-in scenario; re-run from a normal PowerShell if needed." }

    $dest = Get-ReportsFolder
    $unix = Get-UnixTimestamp
    Write-Host ("Running SaRA: Teams Meeting Add-in for Outlook. Reports → {0}" -f $dest) -ForegroundColor Yellow

    $args = @("-S","TeamsAddinScenario","-AcceptEula","-CloseOutlook")
    Start-Process -FilePath $SaraCmdPath -ArgumentList $args -Wait -WindowStyle Normal

    $files = Copy-SaRAArtifacts -Destination $dest -UnixTimestamp $unix
    $htmls = $files | Where-Object { $_ -match '\.html?$' }
    if ($htmls.Count -gt 0) {
        $txt = Write-TextSummary -HtmlFiles $htmls -OutDir $dest -UnixTimestamp $unix
        Write-Host ("Saved: {0}" -f $txt) -ForegroundColor Green
    } else {
        Write-Host "No HTML artifacts found; scenario may output mainly console results." -ForegroundColor DarkYellow
    }
}

#endregion

#region --- Settings merge + color helpers + drawing (title line fix included) ---

function Merge-HashtableDeep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Base, [Parameter(Mandatory)][hashtable]$Overlay)
    $result = @{}; foreach ($k in $Base.Keys) { $result[$k] = $Base[$k] }
    foreach ($k in $Overlay.Keys) {
        $overlayVal = $Overlay[$k]
        if ($result.ContainsKey($k)) {
            $baseVal = $result[$k]
            if ($baseVal -is [hashtable] -and $overlayVal -is [hashtable]) {
                $result[$k] = Merge-HashtableDeep -Base $baseVal -Overlay $overlayVal
            } else { $result[$k] = $overlayVal }
        } else { $result[$k] = $overlayVal }
    }
    return $result
}

function ConvertTo-ConsoleColor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [ConsoleColor]$Fallback = [ConsoleColor]::Gray)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Fallback }
    try { return [System.Enum]::Parse([ConsoleColor], $Name, $true) }
    catch { Write-Warning ("Invalid console color '{0}', using fallback {1}" -f $Name, $Fallback); return $Fallback }
}

function Get-MenuColor {
    [CmdletBinding()]
    param([hashtable]$Settings, [Parameter(Mandatory)][string]$Key, [ConsoleColor]$Fallback = [ConsoleColor]::Gray)
    $name = $null; try { $name = $Settings.Menu.Colors.$Key } catch {}
    return (ConvertTo-ConsoleColor -Name ([string]$name) -Fallback $Fallback)
}

function Get-DefaultMenuSettings {
    [CmdletBinding()]
    param()
    @{
        Menu = @{
            Title   = "Microsoft Office Repair Assistant (SMB Edition)"
            Width   = 74
            Padding = @{ Left = 2; Right = 2 }
            Margin  = @{ Left = 0; Top = 0 }
            Border  = @{
                TopLeft='╔'; Top='═'; TopRight='╗'
                Left='║'; Right='║'
                BottomLeft='╚'; Bottom='═'; BottomRight='╝'
                DividerLeft='╟'; Divider='─'; DividerRight='╢'
            }
            Colors  = @{
                Title='Cyan'; Border='DarkCyan'; Text='Gray'; Prompt='Yellow'; Accent='Green'
            }
        }
    }
}

function Get-MenuSettings {
    [CmdletBinding()]
    param([string]$SettingsPath = $(Join-Path -Path $PSScriptRoot -ChildPath "Data\menusettings.psd1"))
    $defaults = Get-DefaultMenuSettings
    if (Test-Path -Path $SettingsPath) {
        try {
            $loaded = Import-PowerShellDataFile -Path $SettingsPath
            if ($loaded -isnot [hashtable]) { Write-Warning "menusettings.psd1 is not a hashtable. Using defaults."; return $defaults }
            return (Merge-HashtableDeep -Base $defaults -Overlay $loaded)
        } catch {
            Write-Warning ("Failed to read {0}: {1}. Using defaults." -f $SettingsPath, $_.Exception.Message)
            return $defaults
        }
    } else { return $defaults }
}

function Get-VisibleText {
    param($Line)
    if ($Line -is [string]) { return $Line }
    if ($Line -is [hashtable] -and $Line.ContainsKey('Parts')) {
        $buf = New-Object System.Text.StringBuilder
        foreach ($p in $Line.Parts) { [void]$buf.Append([string]$p.Text) }
        return $buf.ToString()
    }
    return [string]$Line
}

function Write-BoxedMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][object[]]$Lines
    )

    $menu    = $Settings.Menu
    $border  = $menu.Border
    $padL    = [int]$menu.Padding.Left
    $padR    = [int]$menu.Padding.Right
    $marginL = if ($menu.Margin.Left) { [int]$menu.Margin.Left } else { 0 }
    $marginT = if ($menu.Margin.Top)  { [int]$menu.Margin.Top }  else { 0 }
    $title   = [string]$menu.Title

    $borderColor = Get-MenuColor -Settings $Settings -Key 'Border' -Fallback ([ConsoleColor]::DarkCyan)
    $titleColor  = Get-MenuColor -Settings $Settings -Key 'Title'  -Fallback ([ConsoleColor]::Cyan)
    $textColor   = Get-MenuColor -Settings $Settings -Key 'Text'   -Fallback ([ConsoleColor]::Gray)

    # Compute width from visible text
    $maxLineLen = 0
    foreach ($ln in $Lines) {
        $t = Get-VisibleText -Line $ln
        if ($t.Length -gt $maxLineLen) { $maxLineLen = $t.Length }
    }
    $contentWidth = [Math]::Max($maxLineLen, $title.Length)
    $width = if ($menu.Width -is [int] -and $menu.Width -ge ($contentWidth + $padL + $padR)) { [int]$menu.Width } else { $contentWidth + $padL + $padR }
    $innerWidth = $width

    $prefix = " " * $marginL
    for ($i = 0; $i -lt $marginT; $i++) { Write-Host "" }

    $topLine = $border.TopLeft + ($border.Top * $innerWidth) + $border.TopRight
    Write-Host ($prefix + $topLine) -ForegroundColor ([ConsoleColor]$borderColor)

    # Title row (pad left + title + fill + right pad) -- FIXED RIGHT BORDER ALIGNMENT
    $rightPad = [Math]::Max(0, ($innerWidth - $padL - $padR - $title.Length))
    $titlePadded = (" " * $padL) + $title + (" " * $rightPad) + (" " * $padR)
    Write-Host ($prefix + $border.Left) -ForegroundColor ([ConsoleColor]$borderColor) -NoNewline
    Write-Host $titlePadded -ForegroundColor ([ConsoleColor]$titleColor) -NoNewline
    Write-Host $border.Right -ForegroundColor ([ConsoleColor]$borderColor)

    $divLine = $border.DividerLeft + ($border.Divider * $innerWidth) + $border.DividerRight
    Write-Host ($prefix + $divLine) -ForegroundColor ([ConsoleColor]$borderColor)

    foreach ($ln in $Lines) {
        $visible = Get-VisibleText -Line $ln
        $rightPadCount = [Math]::Max(0, ($innerWidth - $padL - $padR - $visible.Length))
        Write-Host ($prefix + $border.Left) -ForegroundColor ([ConsoleColor]$borderColor) -NoNewline
        Write-Host ((" " * $padL)) -ForegroundColor ([ConsoleColor]$textColor) -NoNewline

        if ($ln -is [string]) {
            Write-Host $ln -ForegroundColor ([ConsoleColor]$textColor) -NoNewline
        } elseif ($ln -is [hashtable] -and $ln.ContainsKey('Parts')) {
            foreach ($p in $ln.Parts) {
                $c = if ($p.Color) { (ConvertTo-ConsoleColor -Name ([string]$p.Color) -Fallback $textColor) } else { $textColor }
                Write-Host ([string]$p.Text) -ForegroundColor ([ConsoleColor]$c) -NoNewline
            }
        } else {
            Write-Host $visible -ForegroundColor ([ConsoleColor]$textColor) -NoNewline
        }

        Write-Host ((" " * $rightPadCount) + (" " * $padR)) -ForegroundColor ([ConsoleColor]$textColor) -NoNewline
        Write-Host $border.Right -ForegroundColor ([ConsoleColor]$borderColor)
    }

    $botLine = $border.BottomLeft + ($border.Bottom * $innerWidth) + $border.BottomRight
    Write-Host ($prefix + $botLine) -ForegroundColor ([ConsoleColor]$borderColor)
}

#endregion

#region --- Single-Key input helper ---

function Read-SingleKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ValidKeys,
        [int]$TimeoutSeconds = 0
    )
    $end = if ($TimeoutSeconds -gt 0) { (Get-Date).AddSeconds($TimeoutSeconds) } else { [DateTime]::MaxValue }
    while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } # clear buffer
    while ([DateTime]::UtcNow -lt $end.ToUniversalTime()) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $ch  = $key.KeyChar.ToString()
            $upper = $ch.ToUpperInvariant()
            if ($ValidKeys -contains $ch -or $ValidKeys -contains $upper) { return $upper }
        } else {
            Start-Sleep -Milliseconds 50
        }
    }
    return $null
}

#endregion

#region --- Main Menu (adds R freshness badge + O: Open Reports Folder) ---

function Show-MainMenu {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SaraCmdPath)

    $settings = Get-MenuSettings
    $promptColor = Get-MenuColor -Settings $settings -Key 'Prompt' -Fallback ([ConsoleColor]::Yellow)
    $accentColor = Get-MenuColor -Settings $settings -Key 'Accent' -Fallback ([ConsoleColor]::Green)

    do {
        Clear-Host

        # Freshness suffix for the R) line
        $tag = Get-SaRAFreshnessTag
        $rLine = @{
            Parts = @(
                @{ Text = "R) Re-download/refresh SaRA package" },
                @{ Text = $tag.TagText; Color = $tag.Color }
            )
        }

        $lines = @(
            "1) Reset Office activation (SaRA)"
            "2) Scrub/Uninstall Office (SaRA)"
            "3) Repair Office (Click-to-Run) -> Quick Repair"
            "4) Repair Office (Click-to-Run) -> Online Repair (Full)"
            "5) Outlook Scan (Known Issues + Config Report)  [HTML + TXT]"
            "6) Outlook Calendar Scan (Dozens of checks)     [HTML + TXT]"
            "7) Fix Teams Meeting Add-in for Outlook (non-admin recommended)"
            "O) Open Reports Folder"
            $rLine
            "E) End/Terminate Office Repair Assistant"
        )

        Write-BoxedMenu -Settings $settings -Lines $lines
        Write-Host "    Tip: " -ForegroundColor ([ConsoleColor]$accentColor) -NoNewline
        Write-Host "Outlook/Calendar/Teams work best from a NON-admin PowerShell.`n"
        Write-Host "        Press a key: " -ForegroundColor ([ConsoleColor]$promptColor) -NoNewline
        Write-Host "[1..7/O/R/E]: " -ForegroundColor DarkGray -NoNewline 


        $choice = Read-SingleKey -ValidKeys @('1','2','3','4','5','6','7','O','R','E')

        switch ($choice) {
            "1" { Invoke-SaRAResetOfficeActivation -SaraCmdPath $SaraCmdPath }
            "2" {
                Write-Host "Choose Office version to remove: All, M365, 2019, 2016, 2013, 2010"
                $ver = Read-Host "Enter version (default All)"; if ([string]::IsNullOrWhiteSpace($ver)) { $ver = "All" }
                Invoke-SaRAOfficeScrub -SaraCmdPath $SaraCmdPath -OfficeVersion $ver
            }
            "3" { Invoke-OfficeRepair -RepairType QuickRepair }
            "4" { Write-Host "Online Repair is thorough and may take longer. Internet required."; Invoke-OfficeRepair -RepairType FullRepair }
            "5" { Invoke-SaRAOutlookScan -SaraCmdPath $SaraCmdPath }
            "6" { Invoke-SaRAOutlookCalendarScan -SaraCmdPath $SaraCmdPath }
            "7" { Invoke-SaRATeamsAddInFix -SaraCmdPath $SaraCmdPath }
            "O" {
                $dir = Get-ReportsFolder
                Write-Host ("Opening: {0}" -f $dir) -ForegroundColor Green
                Start-Process -FilePath "explorer.exe" -ArgumentList @("`"$dir`"")
            }
            "R" { 
                $pkg = Ensure-SaRAEnterprise -Force
                $SaraCmdPath = $pkg.SaraCmdPath
                Write-Host ("SaRA refreshed. Cmd path: {0}" -f $SaraCmdPath) -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            "E" { return }
            default { }
        }
    } while ($true)
}

#endregion

#region --- Entry Point ---

try {
    # Freshness note on startup
    $fresh = Get-SaRAFreshnessTag
    if ($fresh.TagText) {
        Write-Host $fresh.TagText -ForegroundColor (ConvertTo-ConsoleColor -Name $fresh.Color -Fallback ([ConsoleColor]::Gray))
    }

    # Only download if not installed
    $status = Get-SaRAStatus
    $pkg = if ($status.Installed) {
        [PSCustomObject]@{ SaraCmdPath = $status.SaraCmdPath; Paths = $status.Paths }
    } else {
        Ensure-SaRAEnterprise
    }

    $sara = $pkg.SaraCmdPath
    Write-Host ("SaRA Enterprise ready at: {0}" -f $sara) -ForegroundColor Green

    Show-MainMenu -SaraCmdPath $sara
} catch {
    Write-Error ("Setup failed: {0}" -f $_.Exception.Message)
}

#endregion
}
StartRepair