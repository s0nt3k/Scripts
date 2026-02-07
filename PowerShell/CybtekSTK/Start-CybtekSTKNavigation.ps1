# --- Settings File Path (resolved at script scope for $PSScriptRoot access) -
$script:SettingsFilePath = if ($PSScriptRoot) {
    Join-Path $PSScriptRoot "CybtekSTK.settings.json"
} else {
    Join-Path $PWD "CybtekSTK.settings.json"
}

function Start-CybtekSTKNavigation {

    # --- Enable Virtual Terminal Processing for ANSI Escape Sequences -------
    Add-Type -MemberDefinition @"
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@ -Namespace "Win32" -Name "NativeMethods" -ErrorAction SilentlyContinue

    $stdOut = [Win32.NativeMethods]::GetStdHandle(-11)
    $mode   = 0
    [void][Win32.NativeMethods]::GetConsoleMode($stdOut, [ref]$mode)
    [void][Win32.NativeMethods]::SetConsoleMode($stdOut, $mode -bor 0x0004)

    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

    # --- Console Font API ---------------------------------------------------
    Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;

        namespace Win32 {
            [StructLayout(LayoutKind.Sequential)]
            public struct FontCoord {
                public short X;
                public short Y;
            }

            [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
            public struct CONSOLE_FONT_INFOEX {
                public uint cbSize;
                public uint nFont;
                public FontCoord dwFontSize;
                public uint FontFamily;
                public uint FontWeight;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
                public string FaceName;
            }

            public class ConsoleFont {
                [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
                public static extern bool SetCurrentConsoleFontEx(
                    IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);

                [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
                public static extern bool GetCurrentConsoleFontEx(
                    IntPtr hConsoleOutput, bool bMaximumWindow, ref CONSOLE_FONT_INFOEX lpConsoleCurrentFontEx);
            }
        }
"@ -ErrorAction SilentlyContinue

    # --- ANSI Base ----------------------------------------------------------
    $ESC   = [char]0x1B
    $Reset = "$ESC[0m"

    # --- Color Map (name -> ANSI foreground code) ---------------------------
    $script:ColorMap = [ordered]@{
        "Black"          = 30
        "Red"            = 31
        "Green"          = 32
        "Yellow"         = 33
        "Blue"           = 34
        "Magenta"        = 35
        "Cyan"           = 36
        "White"          = 37
        "Bright Black"   = 90
        "Bright Red"     = 91
        "Bright Green"   = 92
        "Bright Yellow"  = 93
        "Bright Blue"    = 94
        "Bright Magenta" = 95
        "Bright Cyan"    = 96
        "Bright White"   = 97
    }

    # Dark foreground codes that need light text when used as a background
    $script:DarkCodes = @(30, 31, 34, 35, 90)

    # Dark console colors that need light contrasting text
    $script:DarkConsoleColors = @(
        [ConsoleColor]::Black, [ConsoleColor]::DarkBlue, [ConsoleColor]::DarkGreen,
        [ConsoleColor]::DarkCyan, [ConsoleColor]::DarkRed, [ConsoleColor]::DarkMagenta,
        [ConsoleColor]::DarkGray, [ConsoleColor]::Blue, [ConsoleColor]::Red
    )

    # Common console-compatible fonts
    $script:ConsoleFonts = @(
        "Consolas"
        "Cascadia Mono"
        "Cascadia Code"
        "Lucida Console"
        "Courier New"
        "Terminal"
    )

    # --- Configurable Color Settings (stored as foreground ANSI codes) ------
    $script:BorderFg    = 33    # Yellow
    $script:TitleFg     = 33    # Yellow
    $script:MenuFg      = 33    # Yellow
    $script:HighlightFg = 30    # Black
    $script:HighlightBg = 33    # Yellow (stored as fg code; +10 for background)
    $script:DateTimeFg  = 33    # Yellow

    # --- Technical Service Mode State ----------------------------------------
    $script:TechServiceModeActive = $false
    $script:TSModeSettings = [ordered]@{
        ShowRecentFiles          = $true
        ShowFrequentFolders      = $true
        ShowRecommended          = $true
        IncludeAccountInsights   = $true
        ShowIconsNeverThumbnails = $true
        ShowHiddenFiles          = $true
        HideEmptyDrives          = $true
        HideFolderMergeConflicts = $true
        HideProtectedOSFiles     = $true
        ShowPreviewHandlers      = $true
        HideUnhideXTekFolder    = $true
        HideUnhideAppData       = $true
        RustDeskService          = $true
        UserAccessControl        = $true
        PowerShellExecutionPolicy = $true
        WindowsScreenSaver       = $true
    }
    $script:ScreenSaverBackup = @{}

    # --- Storage Sense Settings -------------------------------------------------
    $script:StorageSenseSettings = [ordered]@{
        Downloads            = $true
        DeliveryOptimization = $true
        WindowsUpdate        = $true
        Thumbnails           = $true
        Defender             = $true
        INetCache            = $true
        RecycleBin           = $true
        WER                  = $true
        TempFiles            = $true
        DirectX              = $true
    }

    # --- Build Style Strings from Current Settings --------------------------
    function Update-Styles {
        $script:BorderStyle    = "$ESC[$($script:BorderFg)m"
        $script:TitleStyle     = "$ESC[1;3;$($script:TitleFg)m"
        $script:MenuStyle      = "$ESC[3;$($script:MenuFg)m"
        $bgCode = $script:HighlightBg + 10
        $script:HighlightStyle = "$ESC[3;$($script:HighlightFg);${bgCode}m"
        $script:DateTimeStyle  = "$ESC[3;$($script:DateTimeFg)m"
        $script:ErrorStyle     = "$ESC[1;31m"
        $script:SuccessStyle   = "$ESC[1;3;32m"
    }

    Update-Styles

    # --- Helper Functions ---------------------------------------------------

    function Get-CenterPadding {
        param([int]$TextLength)
        $width = [Console]::WindowWidth
        $pad   = [Math]::Max(0, [Math]::Floor(($width - $TextLength) / 2))
        return (' ' * $pad)
    }

    function Get-ColorName {
        param([int]$Code)
        foreach ($entry in $script:ColorMap.GetEnumerator()) {
            if ($entry.Value -eq $Code) { return $entry.Key }
        }
        return "Custom"
    }

    function Test-AdminGroupMember {
        try {
            $members     = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop
            $currentUser = "$env:COMPUTERNAME\$env:USERNAME"
            return ($members.Name -contains $currentUser)
        }
        catch {
            return $false
        }
    }

    function Test-IconsOnlyEnabled {
        try {
            $val = Get-ItemPropertyValue `
                -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" `
                -Name "IconsOnly" -ErrorAction Stop
            return ($val -eq 1)
        }
        catch {
            return $false
        }
    }

    function Get-CurrentFont {
        try {
            $handle   = [Win32.NativeMethods]::GetStdHandle(-11)
            $fontInfo = New-Object Win32.CONSOLE_FONT_INFOEX
            $fontInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][Win32.CONSOLE_FONT_INFOEX])
            [void][Win32.ConsoleFont]::GetCurrentConsoleFontEx($handle, $false, [ref]$fontInfo)
            return @{ Name = $fontInfo.FaceName; Size = [int]$fontInfo.dwFontSize.Y }
        }
        catch {
            return @{ Name = "Unknown"; Size = 0 }
        }
    }

    function Set-ConsoleFont {
        param([string]$FontName, [int]$FontSize)
        $handle   = [Win32.NativeMethods]::GetStdHandle(-11)
        $fontInfo = New-Object Win32.CONSOLE_FONT_INFOEX
        $fontInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][Win32.CONSOLE_FONT_INFOEX])
        [void][Win32.ConsoleFont]::GetCurrentConsoleFontEx($handle, $false, [ref]$fontInfo)

        $fontInfo.FaceName   = $FontName
        $fontSize            = New-Object Win32.FontCoord
        $fontSize.X          = 0
        $fontSize.Y          = [short]$FontSize
        $fontInfo.dwFontSize = $fontSize
        $fontInfo.FontFamily = 54
        $fontInfo.FontWeight = 400

        $result = [Win32.ConsoleFont]::SetCurrentConsoleFontEx($handle, $false, [ref]$fontInfo)
        if (-not $result) { throw "Failed to set console font." }
    }

    function Set-ConsoleSize {
        param([int]$Width, [int]$Height)
        $bufHeight = [Math]::Min($Height * 2000, 32766)

        # Buffer must be >= window; grow buffer first, then set window, then trim buffer
        $curBuf    = $host.UI.RawUI.BufferSize
        $tempBufW  = [Math]::Max($Width, $curBuf.Width)
        $tempBufH  = [Math]::Max($bufHeight, $curBuf.Height)
        $host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($tempBufW, $tempBufH)
        $host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($Width, $Height)
        $host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($Width, $bufHeight)
    }

    # --- Settings Persistence -----------------------------------------------

    function Save-Settings {
        $fontInfo = Get-CurrentFont
        $settings = [ordered]@{
            BorderFg          = $script:BorderFg
            TitleFg           = $script:TitleFg
            MenuFg            = $script:MenuFg
            HighlightFg       = $script:HighlightFg
            HighlightBg       = $script:HighlightBg
            DateTimeFg        = $script:DateTimeFg
            TechServiceModeActive = $script:TechServiceModeActive
            TSModeSettings    = $script:TSModeSettings
            ScreenSaverBackup = $script:ScreenSaverBackup
            StorageSenseSettings = $script:StorageSenseSettings
            ConsoleWidth      = [int][Console]::WindowWidth
            ConsoleHeight     = [int][Console]::WindowHeight
            ConsoleForeground = "$($host.UI.RawUI.ForegroundColor)"
            ConsoleBackground = "$($host.UI.RawUI.BackgroundColor)"
            FontName          = $fontInfo.Name
            FontSize          = $fontInfo.Size
        }
        $settings | ConvertTo-Json | Set-Content $script:SettingsFilePath -Force
    }

    function Load-Settings {
        if (-not (Test-Path $script:SettingsFilePath)) {
            Save-Settings
            return
        }
        try {
            $s = Get-Content $script:SettingsFilePath -Raw | ConvertFrom-Json

            # Navigation colors
            if ($null -ne $s.BorderFg)    { $script:BorderFg    = [int]$s.BorderFg }
            if ($null -ne $s.TitleFg)     { $script:TitleFg     = [int]$s.TitleFg }
            if ($null -ne $s.MenuFg)      { $script:MenuFg      = [int]$s.MenuFg }
            if ($null -ne $s.HighlightFg) { $script:HighlightFg = [int]$s.HighlightFg }
            if ($null -ne $s.HighlightBg) { $script:HighlightBg = [int]$s.HighlightBg }
            if ($null -ne $s.DateTimeFg)  { $script:DateTimeFg  = [int]$s.DateTimeFg }
            if ($null -ne $s.TechServiceModeActive) { $script:TechServiceModeActive = [bool]$s.TechServiceModeActive }
            if ($s.TSModeSettings) {
                $tsObj = $s.TSModeSettings
                foreach ($key in @($script:TSModeSettings.Keys)) {
                    $val = $tsObj.$key
                    if ($null -ne $val) { $script:TSModeSettings[$key] = [bool]$val }
                }
            }
            if ($s.ScreenSaverBackup) {
                $sbObj = $s.ScreenSaverBackup
                $script:ScreenSaverBackup = @{}
                if ($null -ne $sbObj.Active)     { $script:ScreenSaverBackup.Active     = "$($sbObj.Active)" }
                if ($null -ne $sbObj.IsSecure)   { $script:ScreenSaverBackup.IsSecure   = "$($sbObj.IsSecure)" }
                if ($null -ne $sbObj.TimeOut)    { $script:ScreenSaverBackup.TimeOut    = "$($sbObj.TimeOut)" }
                if ($null -ne $sbObj.Executable) { $script:ScreenSaverBackup.Executable = "$($sbObj.Executable)" }
            }
            if ($s.StorageSenseSettings) {
                $ssObj = $s.StorageSenseSettings
                foreach ($key in @($script:StorageSenseSettings.Keys)) {
                    $val = $ssObj.$key
                    if ($null -ne $val) { $script:StorageSenseSettings[$key] = [bool]$val }
                }
            }
            Update-Styles

            # Console font (apply before size since font affects max window dimensions)
            if ($s.FontName -and $s.FontSize) {
                try { Set-ConsoleFont -FontName $s.FontName -FontSize ([int]$s.FontSize) } catch {}
            }

            # Console window size
            if ($s.ConsoleWidth -and $s.ConsoleHeight) {
                try { Set-ConsoleSize -Width ([int]$s.ConsoleWidth) -Height ([int]$s.ConsoleHeight) } catch {}
            }

            # Console colors
            if ($s.ConsoleForeground) {
                try { $host.UI.RawUI.ForegroundColor = [ConsoleColor]$s.ConsoleForeground } catch {}
            }
            if ($s.ConsoleBackground) {
                try { $host.UI.RawUI.BackgroundColor = [ConsoleColor]$s.ConsoleBackground } catch {}
            }
        }
        catch {
            # File corrupt; recreate with defaults
            Save-Settings
        }
    }

    # --- Display Functions --------------------------------------------------

    function Show-TitleBanner {
        param([string]$Title = "CybtekSTK Navigation System")

        $margin   = 2
        $boxWidth = [Console]::WindowWidth - ($margin * 2)

        # Fixed border elements = 10 chars: ╔/║/╚(1) + ═══/♠ (3) + ╦/│/╩(1) + ╦/│/╩(1) + ═══/♠ (3) + ╗/║/╝(1)
        $titleArea = $boxWidth - 10

        # Center title text within the title area
        $titleText     = $Title
        $titlePadTotal = $titleArea - $titleText.Length
        $titlePadLeft  = [Math]::Floor($titlePadTotal / 2)
        $titlePadRight = $titlePadTotal - $titlePadLeft
        $title         = (' ' * $titlePadLeft) + $titleText + (' ' * $titlePadRight)

        $lineTop = [char]0x2554 + ([string][char]0x2550 * 3) + [char]0x2566 +
                   ([string][char]0x2550 * $titleArea) + [char]0x2566 +
                   ([string][char]0x2550 * 3) + [char]0x2557

        $borderL = [string][char]0x2551 + " $([char]0x2660) " + [char]0x2502
        $borderR = [string][char]0x2502 + " $([char]0x2660) " + [char]0x2551

        $lineBot = [char]0x255A + ([string][char]0x2550 * 3) + [char]0x2569 +
                   ([string][char]0x2550 * $titleArea) + [char]0x2569 +
                   ([string][char]0x2550 * 3) + [char]0x255D

        $pad = ' ' * $margin

        $bg = "$ESC[40m"

        Write-Host ""
        Write-Host "$pad$bg$($script:BorderStyle)$lineTop$Reset"
        Write-Host "$pad$bg$($script:BorderStyle)$borderL$Reset$bg$($script:TitleStyle)$title$Reset$bg$($script:BorderStyle)$borderR$Reset"
        Write-Host "$pad$bg$($script:BorderStyle)$lineBot$Reset"
        Write-Host ""
    }

    function Show-StatusMessage {
        param(
            [string]$Message,
            [string]$Type = "Success"
        )
        $msgStyle = if ($Type -eq "Error") { $script:ErrorStyle } else { $script:SuccessStyle }
        $pad = Get-CenterPadding -TextLength ($Message.Length + 4)
        Write-Host ""
        Write-Host "$pad$msgStyle  $Message  $Reset"
        Start-Sleep -Seconds 2
    }

    function Show-FooterBanner {
        $margin   = 2
        $boxWidth = [Console]::WindowWidth - ($margin * 2)
        $inner    = $boxWidth - 2   # inside the ╔/╗ and ╚/╝ columns

        $now     = Get-Date
        $timeStr = $now.ToString("dddd MMMM d yyyy h:mm:ss tt")
        $content = ("  " + $timeStr).PadRight($inner)

        $lineTop = [char]0x2554 + ([string][char]0x2500 * $inner) + [char]0x2557
        $lineBot = [char]0x255A + ([string][char]0x2550 * $inner) + [char]0x255D

        $pad = ' ' * $margin
        $bl  = [char]0x2551

        $bg = "$ESC[40m"

        Write-Host "$pad$bg$($script:BorderStyle)$lineTop$Reset"
        Write-Host "$pad$bg$($script:BorderStyle)$bl$Reset$bg$($script:DateTimeStyle)$content$Reset$bg$($script:BorderStyle)$bl$Reset"
        $script:FooterTimeRow = [Console]::CursorTop - 1
        Write-Host "$pad$bg$($script:BorderStyle)$lineBot$Reset"
    }

    function Update-FooterClock {
        $margin   = 2
        $boxWidth = [Console]::WindowWidth - ($margin * 2)
        $inner    = $boxWidth - 2

        $now     = Get-Date
        $timeStr = $now.ToString("dddd MMMM d yyyy h:mm:ss tt")
        $content = ("  " + $timeStr).PadRight($inner)

        $bl  = [char]0x2551
        $pad = ' ' * $margin

        $bg = "$ESC[40m"

        $savedLeft = [Console]::CursorLeft
        $savedTop  = [Console]::CursorTop
        [Console]::SetCursorPosition(0, $script:FooterTimeRow)
        Write-Host "$pad$bg$($script:BorderStyle)$bl$Reset$bg$($script:DateTimeStyle)$content$Reset$bg$($script:BorderStyle)$bl$Reset" -NoNewline
        [Console]::SetCursorPosition($savedLeft, $savedTop)
    }

    function Wait-KeyWithClock {
        while ($true) {
            if ([Console]::KeyAvailable) {
                return [Console]::ReadKey($true)
            }
            Update-FooterClock
            Start-Sleep -Milliseconds 200
        }
    }

    function Show-SplashImage {
        $imagePath = Join-Path (Split-Path $script:SettingsFilePath) "applogo.png"
        if (-not (Test-Path $imagePath)) { return }

        Add-Type -AssemblyName System.Drawing

        try {
            $img = [System.Drawing.Image]::FromFile((Resolve-Path $imagePath).Path)
        } catch { return }

        $consoleWidth = [Console]::WindowWidth
        $consoleHeight = [Console]::WindowHeight

        # Scale image to fit console (each char row = 2 pixel rows via half-block characters)
        $maxW = $consoleWidth - 4
        $maxH = ($consoleHeight - 2) * 2
        $scale = [Math]::Min($maxW / $img.Width, $maxH / $img.Height)
        $newW = [Math]::Max(1, [int]($img.Width * $scale))
        $newH = [Math]::Max(2, [int]($img.Height * $scale))
        if ($newH % 2 -ne 0) { $newH++ }

        $bmp = New-Object System.Drawing.Bitmap($img, $newW, $newH)
        $img.Dispose()

        # Lock bits for fast pixel access (Format32bppArgb = BGRA byte order)
        $rect = New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)
        $bmpData = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $stride = $bmpData.Stride
        $pixels = [byte[]]::new([Math]::Abs($stride) * $bmp.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($bmpData.Scan0, $pixels, 0, $pixels.Length)
        $bmp.UnlockBits($bmpData)
        $bmp.Dispose()

        [Console]::Clear()
        [Console]::CursorVisible = $false

        $charRows = $newH / 2
        $padTop = [Math]::Max(0, [Math]::Floor(($consoleHeight - $charRows) / 2))
        $padLeft = [Math]::Max(0, [Math]::Floor(($consoleWidth - $newW) / 2))
        $leftPad = ' ' * $padLeft
        $halfBlock = [char]0x2580

        $sb = [System.Text.StringBuilder]::new()
        for ($p = 0; $p -lt $padTop; $p++) { [void]$sb.AppendLine() }

        for ($y = 0; $y -lt $newH; $y += 2) {
            [void]$sb.Append($leftPad)
            for ($x = 0; $x -lt $newW; $x++) {
                # Top pixel (BGRA)
                $tOff = $y * $stride + $x * 4
                if ($pixels[$tOff + 3] -lt 128) { $tR = 0; $tG = 0; $tB = 0 }
                else { $tR = $pixels[$tOff + 2]; $tG = $pixels[$tOff + 1]; $tB = $pixels[$tOff] }

                # Bottom pixel (BGRA)
                $bOff = ($y + 1) * $stride + $x * 4
                if (($y + 1) -ge $newH -or $pixels[$bOff + 3] -lt 128) { $bR = 0; $bG = 0; $bB = 0 }
                else { $bR = $pixels[$bOff + 2]; $bG = $pixels[$bOff + 1]; $bB = $pixels[$bOff] }

                [void]$sb.Append("$ESC[38;2;${tR};${tG};${tB};48;2;${bR};${bG};${bB}m$halfBlock")
            }
            [void]$sb.Append($Reset)
            if (($y + 2) -lt $newH) { [void]$sb.AppendLine() }
        }

        Write-Host $sb.ToString()
        Start-Sleep -Seconds 3
        [Console]::Clear()
    }

    function Format-FileSize {
        param([long]$Bytes)
        if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
        if ($Bytes -ge 100MB) { return "{0:N0} MB" -f ($Bytes / 1MB) }
        if ($Bytes -ge 10MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
        if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
        if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
        if ($Bytes -gt 0) { return "$Bytes B" }
        return "0 B"
    }

    function Get-FolderSize {
        param([string[]]$Paths)
        $total = [long]0
        foreach ($p in $Paths) {
            if (Test-Path $p) {
                $sum = (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
                if ($sum) { $total += $sum }
            }
        }
        return $total
    }

    function Get-WrappedLines {
        param([string]$Text, [int]$Width)
        if (-not $Text) { return @("") }
        $words = $Text -split '\s+'
        $lines = @()
        $currentLine = ""
        foreach ($word in $words) {
            if ($currentLine.Length -eq 0) {
                $currentLine = $word
            }
            elseif (($currentLine.Length + 1 + $word.Length) -le $Width) {
                $currentLine += " $word"
            }
            else {
                $lines += $currentLine
                $currentLine = $word
            }
        }
        if ($currentLine.Length -gt 0) { $lines += $currentLine }
        return $lines
    }

    # --- System Admin Helper Functions ----------------------------------------

    function Write-Step {
        param(
            [int]$StepNumber,
            [string]$Message,
            [string]$Status = "Running"
        )
        $statusColor = switch ($Status) {
            "Running" { "$ESC[33m" }
            "Pass"    { "$ESC[32m" }
            "Fail"    { "$ESC[31m" }
            "Skip"    { "$ESC[90m" }
            "Info"    { "$ESC[36m" }
            default   { "$ESC[37m" }
        }
        $tag = "[$Status]"
        $gap = [Math]::Max(1, 55 - $Message.Length)
        Write-Host "  $statusColor[Step $StepNumber]$Reset $Message$(' ' * $gap)$statusColor$tag$Reset"
    }

    function Read-YesNo {
        param([string]$Prompt)
        Write-Host ""
        Write-Host "  $Prompt (Y/N): " -NoNewline
        [Console]::CursorVisible = $true
        $answer = $null
        while ($answer -notin @('Y','N','y','n')) {
            $k = [Console]::ReadKey($true)
            $answer = $k.KeyChar
        }
        Write-Host $answer
        [Console]::CursorVisible = $false
        return ($answer -eq 'Y' -or $answer -eq 'y')
    }

    function Show-OperationScreen {
        param(
            [string]$Title,
            [string]$Subtitle
        )
        [Console]::Clear()
        [Console]::CursorVisible = $false
        Show-TitleBanner -Title $Title
        Write-Host ""
        if ($Subtitle) {
            $pad = Get-CenterPadding -TextLength $Subtitle.Length
            Write-Host "$pad$($script:TitleStyle)$Subtitle$Reset"
            Write-Host ""
        }
    }

    function Show-Menu {
        param(
            [string[]]$Items,
            [int]$Selected,
            [string]$Title = "CybtekSTK Navigation System"
        )

        [Console]::Clear()
        [Console]::CursorVisible = $false

        Show-TitleBanner -Title $Title
        Write-Host ""

        # --- Menu Items -----------------------------------------------------
        $maxLen = ($Items | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $label   = "   $($Items[$i].PadRight($maxLen))   "
            $menuPad = Get-CenterPadding -TextLength $label.Length

            if ($i -eq $Selected) {
                Write-Host "$menuPad$($script:HighlightStyle)$label$Reset"
            }
            else {
                Write-Host "$menuPad$($script:MenuStyle)$label$Reset"
            }
            Write-Host ""
        }

        Show-FooterBanner
    }

    # --- Pickers ------------------------------------------------------------

    function Show-ColorPicker {
        param(
            [int]$CurrentCode,
            [string]$SettingName
        )

        $colorNames = @($script:ColorMap.Keys)
        $colorCodes = @($script:ColorMap.Values)

        # Find index of the current color
        $pickerIndex = 0
        for ($i = 0; $i -lt $colorCodes.Count; $i++) {
            if ($colorCodes[$i] -eq $CurrentCode) { $pickerIndex = $i; break }
        }

        while ($true) {
            [Console]::Clear()
            [Console]::CursorVisible = $false

            Show-TitleBanner

            $subtitle = "Select $SettingName"
            $subPad   = Get-CenterPadding -TextLength ($subtitle.Length + 4)
            Write-Host "$subPad$($script:TitleStyle)  $subtitle  $Reset"
            Write-Host ""

            for ($i = 0; $i -lt $colorNames.Count; $i++) {
                $code  = $colorCodes[$i]
                $name  = $colorNames[$i]
                $label = "   $([char]0x25A0)  $($name.PadRight(18))   "
                $pad   = Get-CenterPadding -TextLength $label.Length

                if ($i -eq $pickerIndex) {
                    $bgCode = $code + 10
                    $fgText = if ($script:DarkCodes -contains $code) { 97 } else { 30 }
                    Write-Host "$pad$ESC[3;${fgText};${bgCode}m$label$Reset"
                }
                else {
                    Write-Host "$pad$ESC[3;${code}m$label$Reset"
                }
            }

            Write-Host ""
            $hintText = "Enter = Select   Escape = Cancel"
            $hintPad  = Get-CenterPadding -TextLength ($hintText.Length + 4)
            Write-Host "$hintPad$($script:MenuStyle)  $hintText  $Reset"

            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                'UpArrow' {
                    if ($pickerIndex -le 0) { $pickerIndex = $colorNames.Count - 1 }
                    else { $pickerIndex-- }
                }
                'DownArrow' {
                    if ($pickerIndex -ge ($colorNames.Count - 1)) { $pickerIndex = 0 }
                    else { $pickerIndex++ }
                }
                'Enter'  { return $colorCodes[$pickerIndex] }
                'Escape' { return $CurrentCode }
            }
        }
    }

    function Show-ConsoleColorPicker {
        param(
            [ConsoleColor]$CurrentColor,
            [string]$SettingName
        )

        $colors      = [Enum]::GetValues([ConsoleColor])
        $pickerIndex = [Array]::IndexOf($colors, $CurrentColor)
        if ($pickerIndex -lt 0) { $pickerIndex = 0 }

        while ($true) {
            [Console]::Clear()
            [Console]::CursorVisible = $false

            Show-TitleBanner

            $subtitle = "Select $SettingName"
            $subPad   = Get-CenterPadding -TextLength ($subtitle.Length + 4)
            Write-Host "$subPad$($script:TitleStyle)  $subtitle  $Reset"
            Write-Host ""

            for ($i = 0; $i -lt $colors.Count; $i++) {
                $color = $colors[$i]
                $name  = "$color".PadRight(14)
                $label = "   $([char]0x25A0)  $name   "
                $pad   = Get-CenterPadding -TextLength $label.Length

                if ($i -eq $pickerIndex) {
                    $contrast = if ($script:DarkConsoleColors -contains $color) { 'White' } else { 'Black' }
                    Write-Host $pad -NoNewline
                    Write-Host $label -ForegroundColor $contrast -BackgroundColor $color
                }
                else {
                    Write-Host $pad -NoNewline
                    Write-Host $label -ForegroundColor $color
                }
            }

            Write-Host ""
            $hintText = "Enter = Select   Escape = Cancel"
            $hintPad  = Get-CenterPadding -TextLength ($hintText.Length + 4)
            Write-Host "$hintPad$($script:MenuStyle)  $hintText  $Reset"

            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                'UpArrow' {
                    if ($pickerIndex -le 0) { $pickerIndex = $colors.Count - 1 }
                    else { $pickerIndex-- }
                }
                'DownArrow' {
                    if ($pickerIndex -ge ($colors.Count - 1)) { $pickerIndex = 0 }
                    else { $pickerIndex++ }
                }
                'Enter'  { return $colors[$pickerIndex] }
                'Escape' { return $CurrentColor }
            }
        }
    }

    function Show-NumberPicker {
        param(
            [int]$CurrentValue,
            [string]$SettingName,
            [int]$Min = 1,
            [int]$Max = 9999
        )

        $value = $CurrentValue

        while ($true) {
            [Console]::Clear()
            [Console]::CursorVisible = $false

            Show-TitleBanner

            $subtitle = $SettingName
            $subPad   = Get-CenterPadding -TextLength ($subtitle.Length + 4)
            Write-Host "$subPad$($script:TitleStyle)  $subtitle  $Reset"
            Write-Host ""
            Write-Host ""

            $valueStr = "$value"
            $valPad   = Get-CenterPadding -TextLength $valueStr.Length
            Write-Host "$valPad$($script:HighlightStyle) $valueStr $Reset"

            Write-Host ""
            Write-Host ""
            $hint    = "Up/Down = +/- 1   PageUp/PageDn = +/- 10   Enter = Confirm   Escape = Cancel"
            $hintPad = Get-CenterPadding -TextLength ($hint.Length + 4)
            Write-Host "$hintPad$($script:MenuStyle)  $hint  $Reset"

            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                'UpArrow'   { if ($value -lt $Max) { $value++ } }
                'DownArrow' { if ($value -gt $Min) { $value-- } }
                'PageUp'    { $value = [Math]::Min($Max, $value + 10) }
                'PageDown'  { $value = [Math]::Max($Min, $value - 10) }
                'Enter'     { return $value }
                'Escape'    { return $CurrentValue }
            }
        }
    }

    function Show-FontPicker {
        param([string]$CurrentFont)

        $fonts = [System.Collections.ArrayList]::new($script:ConsoleFonts)
        if ($CurrentFont -and $fonts -notcontains $CurrentFont) {
            [void]$fonts.Insert(0, $CurrentFont)
        }

        $pickerIndex = 0
        for ($i = 0; $i -lt $fonts.Count; $i++) {
            if ($fonts[$i] -eq $CurrentFont) { $pickerIndex = $i; break }
        }

        while ($true) {
            [Console]::Clear()
            [Console]::CursorVisible = $false

            Show-TitleBanner

            $subtitle = "Select Font Name"
            $subPad   = Get-CenterPadding -TextLength ($subtitle.Length + 4)
            Write-Host "$subPad$($script:TitleStyle)  $subtitle  $Reset"
            Write-Host ""

            $maxLen = ($fonts | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum

            for ($i = 0; $i -lt $fonts.Count; $i++) {
                $label = "   $($fonts[$i].PadRight($maxLen))   "
                $pad   = Get-CenterPadding -TextLength $label.Length

                if ($i -eq $pickerIndex) {
                    Write-Host "$pad$($script:HighlightStyle)$label$Reset"
                }
                else {
                    Write-Host "$pad$($script:MenuStyle)$label$Reset"
                }
                Write-Host ""
            }

            Write-Host ""
            $hintText = "Enter = Select   Escape = Cancel"
            $hintPad  = Get-CenterPadding -TextLength ($hintText.Length + 4)
            Write-Host "$hintPad$($script:MenuStyle)  $hintText  $Reset"

            $key = [Console]::ReadKey($true)

            switch ($key.Key) {
                'UpArrow' {
                    if ($pickerIndex -le 0) { $pickerIndex = $fonts.Count - 1 }
                    else { $pickerIndex-- }
                }
                'DownArrow' {
                    if ($pickerIndex -ge ($fonts.Count - 1)) { $pickerIndex = 0 }
                    else { $pickerIndex++ }
                }
                'Enter'  { return $fonts[$pickerIndex] }
                'Escape' { return $CurrentFont }
            }
        }
    }

    # --- Settings Menus -----------------------------------------------------

    function Show-TechServiceModeSettings {
        $leftLayout = @(
            @{ Type = "header"; Text = "FILE EXPLORER PRIVACY" }
            @{ Type = "item"; Key = "ShowRecentFiles"; Text = "Show recently used files" }
            @{ Type = "item"; Key = "ShowFrequentFolders"; Text = "Show frequently used folders" }
            @{ Type = "item"; Key = "ShowRecommended"; Text = "Show recommended selection" }
            @{ Type = "item"; Key = "IncludeAccountInsights"; Text = "Include account based insights" }
            @{ Type = "spacer" }
            @{ Type = "header"; Text = "FILE EXPLORER FILES AND FOLDERS" }
            @{ Type = "item"; Key = "ShowIconsNeverThumbnails"; Text = "Show icons, never thumbnails" }
            @{ Type = "item"; Key = "ShowHiddenFiles"; Text = "Show hidden files, folders and drives" }
            @{ Type = "item"; Key = "HideEmptyDrives"; Text = "Hide empty drives" }
            @{ Type = "item"; Key = "HideFolderMergeConflicts"; Text = "Hide folder merge conflicts" }
            @{ Type = "item"; Key = "HideProtectedOSFiles"; Text = "Hide protective operating system files" }
            @{ Type = "item"; Key = "ShowPreviewHandlers"; Text = "Show preview handlers in preview panel" }
            @{ Type = "spacer" }
            @{ Type = "header"; Text = "FILE EXPLORER DIRECTORY" }
            @{ Type = "item"; Key = "HideUnhideXTekFolder"; Text = "Hide/Unhide Path C:\xTekFolder\" }
            @{ Type = "item"; Key = "HideUnhideAppData"; Text = "Hide/Unhide Path %AppData%" }
        )

        $rightLayout = @(
            @{ Type = "header"; Text = "OTHER TS-MODE SETTINGS" }
            @{ Type = "item"; Key = "RustDeskService"; Text = "RustDesk Service (Remote Desktop)" }
            @{ Type = "item"; Key = "UserAccessControl"; Text = "User Access Control Permissions" }
            @{ Type = "item"; Key = "PowerShellExecutionPolicy"; Text = "Set PowerShell Execution Policy" }
            @{ Type = "item"; Key = "WindowsScreenSaver"; Text = "Windows Screen Saver Setting" }
        )

        # Build selectable item indices for each column
        $leftSelectable = @()
        for ($i = 0; $i -lt $leftLayout.Count; $i++) {
            if ($leftLayout[$i].Type -eq "item") { $leftSelectable += $i }
        }
        $rightSelectable = @()
        for ($i = 0; $i -lt $rightLayout.Count; $i++) {
            if ($rightLayout[$i].Type -eq "item") { $rightSelectable += $i }
        }

        $curCol   = 0   # 0 = left, 1 = right
        $curLeft  = 0   # index into $leftSelectable
        $curRight = 0   # index into $rightSelectable

        while ($true) {
            [Console]::Clear()
            [Console]::CursorVisible = $false

            Show-TitleBanner -Title "CybtekSTK Navigation Settings Menu"
            Write-Host ""

            # Calculate dimensions
            $margin        = 2
            $boxWidth      = [Console]::WindowWidth - ($margin * 2)
            $innerWidth    = $boxWidth - 2
            $colWidth      = [Math]::Floor(($innerWidth - 1) / 2)
            $rightColWidth = $innerWidth - $colWidth - 1

            $pad  = ' ' * $margin
            $hBar = [char]0x2500
            $vBar = [char]0x2502

            # Top border
            $topLine = [char]0x250C + ([string]$hBar * $colWidth) + [char]0x252C + ([string]$hBar * $rightColWidth) + [char]0x2510
            Write-Host "$pad$($script:BorderStyle)$topLine$Reset"

            # Content rows
            $maxRows = [Math]::Max($leftLayout.Count, $rightLayout.Count)

            for ($row = 0; $row -lt $maxRows; $row++) {
                # --- Left cell ---
                $leftText       = ""
                $leftIsHeader   = $false
                $leftIsSelected = $false

                if ($row -lt $leftLayout.Count) {
                    $entry = $leftLayout[$row]
                    switch ($entry.Type) {
                        "header" { $leftText = " $($entry.Text)"; $leftIsHeader = $true }
                        "item"   {
                            $chk = if ($script:TSModeSettings[$entry.Key]) { "X" } else { "_" }
                            $leftText = " [$chk] $($entry.Text)"
                            if ($curCol -eq 0 -and $leftSelectable[$curLeft] -eq $row) { $leftIsSelected = $true }
                        }
                    }
                }
                if ($leftText.Length -gt $colWidth) { $leftText = $leftText.Substring(0, $colWidth) }
                $leftText = $leftText.PadRight($colWidth)

                # --- Right cell ---
                $rightText       = ""
                $rightIsHeader   = $false
                $rightIsSelected = $false

                if ($row -lt $rightLayout.Count) {
                    $entry = $rightLayout[$row]
                    switch ($entry.Type) {
                        "header" { $rightText = " $($entry.Text)"; $rightIsHeader = $true }
                        "item"   {
                            $chk = if ($script:TSModeSettings[$entry.Key]) { "X" } else { "_" }
                            $rightText = " [$chk] $($entry.Text)"
                            if ($curCol -eq 1 -and $rightSelectable[$curRight] -eq $row) { $rightIsSelected = $true }
                        }
                    }
                }
                if ($rightText.Length -gt $rightColWidth) { $rightText = $rightText.Substring(0, $rightColWidth) }
                $rightText = $rightText.PadRight($rightColWidth)

                # --- Render row ---
                Write-Host "$pad$($script:BorderStyle)$vBar$Reset" -NoNewline

                if ($leftIsSelected)       { Write-Host "$($script:HighlightStyle)$leftText$Reset" -NoNewline }
                elseif ($leftIsHeader)      { Write-Host "$($script:TitleStyle)$leftText$Reset" -NoNewline }
                else                        { Write-Host "$($script:MenuStyle)$leftText$Reset" -NoNewline }

                Write-Host "$($script:BorderStyle)$vBar$Reset" -NoNewline

                if ($rightIsSelected)       { Write-Host "$($script:HighlightStyle)$rightText$Reset" -NoNewline }
                elseif ($rightIsHeader)      { Write-Host "$($script:TitleStyle)$rightText$Reset" -NoNewline }
                else                        { Write-Host "$($script:MenuStyle)$rightText$Reset" -NoNewline }

                Write-Host "$($script:BorderStyle)$vBar$Reset"
            }

            # Bottom border
            $botLine = [char]0x2514 + ([string]$hBar * $colWidth) + [char]0x2534 + ([string]$hBar * $rightColWidth) + [char]0x2518
            Write-Host "$pad$($script:BorderStyle)$botLine$Reset"

            Write-Host ""
            $hintText = "Arrow Keys = Navigate   Space = Toggle   Escape = Back"
            $hintPad  = Get-CenterPadding -TextLength ($hintText.Length + 4)
            Write-Host "$hintPad$($script:MenuStyle)  $hintText  $Reset"

            Show-FooterBanner

            $key = Wait-KeyWithClock

            switch ($key.Key) {
                'UpArrow' {
                    if ($curCol -eq 0) {
                        if ($curLeft -gt 0) { $curLeft-- } else { $curLeft = $leftSelectable.Count - 1 }
                    } else {
                        if ($curRight -gt 0) { $curRight-- } else { $curRight = $rightSelectable.Count - 1 }
                    }
                }
                'DownArrow' {
                    if ($curCol -eq 0) {
                        if ($curLeft -lt ($leftSelectable.Count - 1)) { $curLeft++ } else { $curLeft = 0 }
                    } else {
                        if ($curRight -lt ($rightSelectable.Count - 1)) { $curRight++ } else { $curRight = 0 }
                    }
                }
                'LeftArrow'  { $curCol = 0 }
                'RightArrow' { $curCol = 1 }
                'Spacebar' {
                    $itemKey = if ($curCol -eq 0) { $leftLayout[$leftSelectable[$curLeft]].Key }
                               else               { $rightLayout[$rightSelectable[$curRight]].Key }
                    $script:TSModeSettings[$itemKey] = -not $script:TSModeSettings[$itemKey]
                    Save-Settings
                }
                'Enter' {
                    $itemKey = if ($curCol -eq 0) { $leftLayout[$leftSelectable[$curLeft]].Key }
                               else               { $rightLayout[$rightSelectable[$curRight]].Key }
                    $script:TSModeSettings[$itemKey] = -not $script:TSModeSettings[$itemKey]
                    Save-Settings
                }
                'Escape' { return }
            }
        }
    }

    function Show-SettingsMenu {
        $settingsIndex = 0

        while ($true) {
            $items = @(
                "CybtekSTK Navigation System Colors"
                "Windows Terminal Console Settings"
                "Technical Service Mode Settings"
                "Back to Main Menu"
            )

            Show-Menu -Items $items -Selected $settingsIndex -Title "CybtekSTK Navigation Settings Menu"

            $key = Wait-KeyWithClock

            switch ($key.Key) {
                'UpArrow' {
                    if ($settingsIndex -le 0) { $settingsIndex = $items.Count - 1 }
                    else { $settingsIndex-- }
                }
                'DownArrow' {
                    if ($settingsIndex -ge ($items.Count - 1)) { $settingsIndex = 0 }
                    else { $settingsIndex++ }
                }
                'Escape' { return }
                'Enter' {
                    switch ($settingsIndex) {
                        0 { Show-ColorSettingsMenu }
                        1 { Show-ConsoleSettingsMenu }
                        2 { Show-TechServiceModeSettings }
                        3 { return }
                    }
                }
            }
        }
    }

    function Show-ColorSettingsMenu {
        $settingsIndex = 0
        $labelWidth    = 28

        while ($true) {
            $borderName = Get-ColorName $script:BorderFg
            $titleName  = Get-ColorName $script:TitleFg
            $menuName   = Get-ColorName $script:MenuFg
            $hlFgName   = Get-ColorName $script:HighlightFg
            $hlBgName   = Get-ColorName $script:HighlightBg
            $dtName     = Get-ColorName $script:DateTimeFg

            $items = @(
                "Border Color:".PadRight($labelWidth) + $borderName
                "Title Color:".PadRight($labelWidth) + $titleName
                "Menu Option Color:".PadRight($labelWidth) + $menuName
                "Highlight Foreground:".PadRight($labelWidth) + $hlFgName
                "Highlight Background:".PadRight($labelWidth) + $hlBgName
                "Date/Time Color:".PadRight($labelWidth) + $dtName
                "Back to Settings"
            )

            Show-Menu -Items $items -Selected $settingsIndex -Title "CybtekSTK Navigation Settings Menu"

            $key = Wait-KeyWithClock

            switch ($key.Key) {
                'UpArrow' {
                    if ($settingsIndex -le 0) { $settingsIndex = $items.Count - 1 }
                    else { $settingsIndex-- }
                }
                'DownArrow' {
                    if ($settingsIndex -ge ($items.Count - 1)) { $settingsIndex = 0 }
                    else { $settingsIndex++ }
                }
                'Escape' { return }
                'Enter' {
                    switch ($settingsIndex) {
                        0 { $script:BorderFg    = Show-ColorPicker -CurrentCode $script:BorderFg    -SettingName "Border Color";         Update-Styles; Save-Settings }
                        1 { $script:TitleFg     = Show-ColorPicker -CurrentCode $script:TitleFg     -SettingName "Title Color";          Update-Styles; Save-Settings }
                        2 { $script:MenuFg      = Show-ColorPicker -CurrentCode $script:MenuFg      -SettingName "Menu Option Color";    Update-Styles; Save-Settings }
                        3 { $script:HighlightFg = Show-ColorPicker -CurrentCode $script:HighlightFg -SettingName "Highlight Foreground"; Update-Styles; Save-Settings }
                        4 { $script:HighlightBg = Show-ColorPicker -CurrentCode $script:HighlightBg -SettingName "Highlight Background"; Update-Styles; Save-Settings }
                        5 { $script:DateTimeFg  = Show-ColorPicker -CurrentCode $script:DateTimeFg  -SettingName "Date/Time Color";          Update-Styles; Save-Settings }
                        6 { return }
                    }
                }
            }
        }
    }

    function Show-ConsoleSettingsMenu {
        $settingsIndex = 0
        $labelWidth    = 28

        while ($true) {
            $curWidth  = [Console]::WindowWidth
            $curHeight = [Console]::WindowHeight
            $curFg     = $host.UI.RawUI.ForegroundColor
            $curBg     = $host.UI.RawUI.BackgroundColor
            $fontInfo  = Get-CurrentFont

            $items = @(
                "Window Width:".PadRight($labelWidth) + $curWidth
                "Window Height:".PadRight($labelWidth) + $curHeight
                "Console Foreground:".PadRight($labelWidth) + $curFg
                "Console Background:".PadRight($labelWidth) + $curBg
                "Font Name:".PadRight($labelWidth) + $fontInfo.Name
                "Font Size:".PadRight($labelWidth) + $fontInfo.Size
                "Back to Settings"
            )

            Show-Menu -Items $items -Selected $settingsIndex -Title "CybtekSTK Navigation Settings Menu"

            $key = Wait-KeyWithClock

            switch ($key.Key) {
                'UpArrow' {
                    if ($settingsIndex -le 0) { $settingsIndex = $items.Count - 1 }
                    else { $settingsIndex-- }
                }
                'DownArrow' {
                    if ($settingsIndex -ge ($items.Count - 1)) { $settingsIndex = 0 }
                    else { $settingsIndex++ }
                }
                'Escape' { return }
                'Enter' {
                    switch ($settingsIndex) {
                        0 {
                            $newWidth = Show-NumberPicker -CurrentValue $curWidth -SettingName "Window Width" -Min 30 -Max 500
                            if ($newWidth -ne $curWidth) {
                                try   { Set-ConsoleSize -Width $newWidth -Height $curHeight }
                                catch { Show-StatusMessage -Message "Error: $($_.Exception.Message)" -Type "Error" }
                            }
                            Save-Settings
                        }
                        1 {
                            $newHeight = Show-NumberPicker -CurrentValue $curHeight -SettingName "Window Height" -Min 10 -Max 100
                            if ($newHeight -ne $curHeight) {
                                try   { Set-ConsoleSize -Width $curWidth -Height $newHeight }
                                catch { Show-StatusMessage -Message "Error: $($_.Exception.Message)" -Type "Error" }
                            }
                            Save-Settings
                        }
                        2 {
                            $newFg = Show-ConsoleColorPicker -CurrentColor $curFg -SettingName "Console Foreground"
                            if ($newFg -ne $curFg) {
                                $host.UI.RawUI.ForegroundColor = $newFg
                            }
                            Save-Settings
                        }
                        3 {
                            $newBg = Show-ConsoleColorPicker -CurrentColor $curBg -SettingName "Console Background"
                            if ($newBg -ne $curBg) {
                                $host.UI.RawUI.BackgroundColor = $newBg
                                [Console]::Clear()
                            }
                            Save-Settings
                        }
                        4 {
                            $newFont = Show-FontPicker -CurrentFont $fontInfo.Name
                            if ($newFont -ne $fontInfo.Name) {
                                try   { Set-ConsoleFont -FontName $newFont -FontSize $fontInfo.Size }
                                catch { Show-StatusMessage -Message "Error: $($_.Exception.Message)" -Type "Error" }
                            }
                            Save-Settings
                        }
                        5 {
                            $newSize = Show-NumberPicker -CurrentValue $fontInfo.Size -SettingName "Font Size" -Min 6 -Max 72
                            if ($newSize -ne $fontInfo.Size) {
                                try   { Set-ConsoleFont -FontName $fontInfo.Name -FontSize $newSize }
                                catch { Show-StatusMessage -Message "Error: $($_.Exception.Message)" -Type "Error" }
                            }
                            Save-Settings
                        }
                        6 { return }
                    }
                }
            }
        }
    }

    # --- Action Handlers ----------------------------------------------------

    function Invoke-TogglePrivilegedAccess {
        param([bool]$IsAdmin)

        if ($IsAdmin) {
            try {
                Remove-LocalGroupMember -Group "Administrators" -Member $env:USERNAME -ErrorAction Stop
                Show-StatusMessage -Message "Privileged User Access has been disabled."
            }
            catch {
                Show-StatusMessage -Message "Error: $($_.Exception.Message)" -Type "Error"
            }
        }
        else {
            try {
                Add-LocalGroupMember -Group "Administrators" -Member $env:USERNAME -ErrorAction Stop
                Show-StatusMessage -Message "Privileged User Access has been enabled."
            }
            catch {
                Show-StatusMessage -Message "Error: $($_.Exception.Message)" -Type "Error"
            }
        }
    }

    function Invoke-ToggleServiceMode {
        $regAdvanced = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        $regExplorer = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
        $regDesktop  = "HKCU:\Control Panel\Desktop"
        $ts = $script:TSModeSettings

        if (-not $script:TechServiceModeActive) {
            # --- ENABLE Technical Service Mode ---
            try {
                $restartExplorer = $false

                # File Explorer Privacy
                if ($ts.ShowRecentFiles) {
                    Set-ItemProperty -Path $regExplorer -Name "ShowRecent" -Value 0
                    $restartExplorer = $true
                }
                if ($ts.ShowFrequentFolders) {
                    Set-ItemProperty -Path $regExplorer -Name "ShowFrequent" -Value 0
                    $restartExplorer = $true
                }
                if ($ts.ShowRecommended) {
                    Set-ItemProperty -Path $regAdvanced -Name "Start_IrisRecommendations" -Value 0
                }
                if ($ts.IncludeAccountInsights) {
                    Set-ItemProperty -Path $regAdvanced -Name "Start_AccountNotifications" -Value 0
                }

                # File Explorer Files and Folders
                if ($ts.ShowIconsNeverThumbnails) {
                    Set-ItemProperty -Path $regAdvanced -Name "IconsOnly" -Value 1
                    $restartExplorer = $true
                }
                if ($ts.ShowHiddenFiles) {
                    Set-ItemProperty -Path $regAdvanced -Name "Hidden" -Value 1
                    $restartExplorer = $true
                }
                if ($ts.HideEmptyDrives) {
                    Set-ItemProperty -Path $regAdvanced -Name "HideDrivesWithNoMedia" -Value 0
                    $restartExplorer = $true
                }
                if ($ts.HideFolderMergeConflicts) {
                    Set-ItemProperty -Path $regAdvanced -Name "HideMergeConflicts" -Value 0
                    $restartExplorer = $true
                }
                if ($ts.HideProtectedOSFiles) {
                    Set-ItemProperty -Path $regAdvanced -Name "ShowSuperHidden" -Value 1
                    $restartExplorer = $true
                }
                if ($ts.ShowPreviewHandlers) {
                    Set-ItemProperty -Path $regAdvanced -Name "ShowPreviewHandlers" -Value 0
                    $restartExplorer = $true
                }

                # File Explorer Directory
                if ($ts.HideUnhideXTekFolder) {
                    if (Test-Path "C:\xTekFolder") { attrib -h "C:\xTekFolder" }
                }
                if ($ts.HideUnhideAppData) {
                    $appData = Join-Path $env:USERPROFILE "AppData"
                    if (Test-Path $appData) { attrib -h $appData }
                }

                # RustDesk Service
                if ($ts.RustDeskService) {
                    try {
                        Start-Service -Name "RustDesk" -ErrorAction Stop
                        $rdPath = "C:\Program Files\RustDesk\rustdesk.exe"
                        if (Test-Path $rdPath) {
                            Start-Process -FilePath $rdPath -Verb RunAs -ErrorAction SilentlyContinue
                        }
                    } catch {}
                }

                # User Access Control
                if ($ts.UserAccessControl) {
                    try { Add-LocalGroupMember -Group "Administrators" -Member $env:USERNAME -ErrorAction Stop } catch {}
                }

                # PowerShell Execution Policy
                if ($ts.PowerShellExecutionPolicy) {
                    try { Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser -Force } catch {}
                }

                # Screen Saver — save current settings then disable
                if ($ts.WindowsScreenSaver) {
                    try {
                        $script:ScreenSaverBackup = @{
                            Active     = (Get-ItemPropertyValue -Path $regDesktop -Name "ScreenSaveActive"    -ErrorAction SilentlyContinue)
                            IsSecure   = (Get-ItemPropertyValue -Path $regDesktop -Name "ScreenSaverIsSecure" -ErrorAction SilentlyContinue)
                            TimeOut    = (Get-ItemPropertyValue -Path $regDesktop -Name "ScreenSaveTimeOut"   -ErrorAction SilentlyContinue)
                            Executable = (Get-ItemPropertyValue -Path $regDesktop -Name "SCRNSAVE.EXE"        -ErrorAction SilentlyContinue)
                        }
                        Set-ItemProperty -Path $regDesktop -Name "ScreenSaveActive" -Value "0"
                    } catch {}
                }

                if ($restartExplorer) {
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                }

                $script:TechServiceModeActive = $true
                Save-Settings
                Show-StatusMessage -Message "Technical Service Mode has been enabled."
            }
            catch {
                Show-StatusMessage -Message "Error: $($_.Exception.Message)" -Type "Error"
            }
        }
        else {
            # --- DISABLE Technical Service Mode ---
            try {
                $restartExplorer = $false

                # File Explorer Privacy
                if ($ts.ShowRecentFiles) {
                    Set-ItemProperty -Path $regExplorer -Name "ShowRecent" -Value 1
                    $restartExplorer = $true
                }
                if ($ts.ShowFrequentFolders) {
                    Set-ItemProperty -Path $regExplorer -Name "ShowFrequent" -Value 1
                    $restartExplorer = $true
                }
                if ($ts.ShowRecommended) {
                    Set-ItemProperty -Path $regAdvanced -Name "Start_IrisRecommendations" -Value 1
                }
                if ($ts.IncludeAccountInsights) {
                    Set-ItemProperty -Path $regAdvanced -Name "Start_AccountNotifications" -Value 1
                }

                # File Explorer Files and Folders
                if ($ts.ShowIconsNeverThumbnails) {
                    Set-ItemProperty -Path $regAdvanced -Name "IconsOnly" -Value 0
                    $restartExplorer = $true
                }
                if ($ts.ShowHiddenFiles) {
                    Set-ItemProperty -Path $regAdvanced -Name "Hidden" -Value 2
                    $restartExplorer = $true
                }
                if ($ts.HideEmptyDrives) {
                    Set-ItemProperty -Path $regAdvanced -Name "HideDrivesWithNoMedia" -Value 1
                    $restartExplorer = $true
                }
                if ($ts.HideFolderMergeConflicts) {
                    Set-ItemProperty -Path $regAdvanced -Name "HideMergeConflicts" -Value 1
                    $restartExplorer = $true
                }
                if ($ts.HideProtectedOSFiles) {
                    Set-ItemProperty -Path $regAdvanced -Name "ShowSuperHidden" -Value 0
                    $restartExplorer = $true
                }
                if ($ts.ShowPreviewHandlers) {
                    Set-ItemProperty -Path $regAdvanced -Name "ShowPreviewHandlers" -Value 1
                    $restartExplorer = $true
                }

                # File Explorer Directory
                if ($ts.HideUnhideXTekFolder) {
                    if (Test-Path "C:\xTekFolder") { attrib +h "C:\xTekFolder" }
                }
                if ($ts.HideUnhideAppData) {
                    $appData = Join-Path $env:USERPROFILE "AppData"
                    if (Test-Path $appData) { attrib +h $appData }
                }

                # RustDesk Service
                if ($ts.RustDeskService) {
                    try {
                        Stop-Service -Name "RustDesk" -Force -ErrorAction Stop
                        Stop-Process -Name "rustdesk" -Force -ErrorAction SilentlyContinue
                    } catch {}
                }

                # User Access Control
                if ($ts.UserAccessControl) {
                    try { Remove-LocalGroupMember -Group "Administrators" -Member $env:USERNAME -ErrorAction Stop } catch {}
                }

                # PowerShell Execution Policy
                if ($ts.PowerShellExecutionPolicy) {
                    try { Set-ExecutionPolicy -ExecutionPolicy AllSigned -Scope CurrentUser -Force } catch {}
                }

                # Screen Saver — restore saved settings
                if ($ts.WindowsScreenSaver) {
                    try {
                        $backup = $script:ScreenSaverBackup
                        if ($backup.Active)     { Set-ItemProperty -Path $regDesktop -Name "ScreenSaveActive"    -Value $backup.Active }
                        else                    { Set-ItemProperty -Path $regDesktop -Name "ScreenSaveActive"    -Value "1" }
                        if ($backup.IsSecure)   { Set-ItemProperty -Path $regDesktop -Name "ScreenSaverIsSecure" -Value $backup.IsSecure }
                        if ($backup.TimeOut)    { Set-ItemProperty -Path $regDesktop -Name "ScreenSaveTimeOut"   -Value $backup.TimeOut }
                        if ($backup.Executable) { Set-ItemProperty -Path $regDesktop -Name "SCRNSAVE.EXE"        -Value $backup.Executable }
                    } catch {}
                }

                if ($restartExplorer) {
                    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                }

                $script:TechServiceModeActive = $false
                Save-Settings
                Show-StatusMessage -Message "Technical Service Mode has been disabled."
            }
            catch {
                Show-StatusMessage -Message "Error: $($_.Exception.Message)" -Type "Error"
            }
        }
    }

    # --- System Administration Functions -------------------------------------

    function Invoke-VerifyComponentStore {
        Show-OperationScreen -Title "System Administration & Maintenance" -Subtitle "Verify Windows Component Store (WinSxS) Health"

        $stepNum = 0

        # ── Step 1: Verify DISM API DLL prerequisites ──
        $stepNum++
        Write-Step -StepNumber $stepNum -Message "Verifying DISM API prerequisites" -Status "Running"

        $requiredDlls = @(
            @{ Name = "dismapi.dll";     Path = "$env:SystemRoot\System32\dismapi.dll" }
            @{ Name = "Dism.exe";        Path = "$env:SystemRoot\System32\Dism.exe" }
            @{ Name = "DismHost.exe";    Path = "$env:SystemRoot\System32\Dism\DismHost.exe" }
            @{ Name = "DismCorePS.dll";  Path = "$env:SystemRoot\System32\Dism\DismCorePS.dll" }
            @{ Name = "DismProv.dll";    Path = "$env:SystemRoot\System32\Dism\DismProv.dll" }
        )

        $missingDlls = @()
        foreach ($dll in $requiredDlls) {
            if (-not (Test-Path $dll.Path)) { $missingDlls += $dll.Name }
        }

        if ($missingDlls.Count -gt 0) {
            Write-Step -StepNumber $stepNum -Message "Missing DISM API components detected" -Status "Fail"
            Write-Host ""
            foreach ($m in $missingDlls) { Write-Host "    Missing: $m" }

            $install = Read-YesNo -Prompt "Would you like the system to install the required DLLs to interact with the DISM API?"
            if ($install) {
                Write-Host ""
                Write-Host "  Restoring DISM API components via System File Checker..."
                Write-Host ""
                & sfc /scannow
                Write-Host ""

                # Re-check
                $stillMissing = @()
                foreach ($dll in $requiredDlls) {
                    if (-not (Test-Path $dll.Path)) { $stillMissing += $dll.Name }
                }

                if ($stillMissing.Count -eq 0) {
                    Write-Step -StepNumber $stepNum -Message "DISM API components installed successfully" -Status "Pass"
                } else {
                    Write-Step -StepNumber $stepNum -Message "Could not restore all DISM API components" -Status "Fail"
                    Write-Host ""
                    foreach ($m in $stillMissing) { Write-Host "    Still missing: $m" }
                    Write-Host ""
                    Write-Host "  Unable to proceed without DISM API components."
                    Write-Host "  Press any key to return..."
                    [Console]::ReadKey($true) | Out-Null
                    return
                }
            } else {
                Write-Host ""
                Write-Host "  The DISM API components are required to proceed."
                Write-Host "  Press any key to return..."
                [Console]::ReadKey($true) | Out-Null
                return
            }
        } else {
            Write-Step -StepNumber $stepNum -Message "All DISM API components verified" -Status "Pass"
        }

        # ── Step 2: Verify DISM API is accessible ──
        $stepNum++
        Write-Step -StepNumber $stepNum -Message "Verifying DISM API accessibility" -Status "Running"
        try {
            Import-Module Dism -ErrorAction Stop
            Write-Step -StepNumber $stepNum -Message "DISM API is accessible" -Status "Pass"
        } catch {
            Write-Step -StepNumber $stepNum -Message "DISM API is not accessible: $($_.Exception.Message)" -Status "Fail"
            Write-Host ""
            Write-Host "  Unable to access the DISM API. Press any key to return..."
            [Console]::ReadKey($true) | Out-Null
            return
        }

        # ── Step 3: Analyze component store health and cleanup status ──
        $stepNum++
        Write-Host ""
        Write-Step -StepNumber $stepNum -Message "Analyzing Windows component store" -Status "Running"

        $isCorrupted = $false
        try {
            $scanResult = Repair-WindowsImage -Online -ScanHealth -ErrorAction Stop
            if ($scanResult.ImageHealthState -eq 'Healthy') {
                Write-Step -StepNumber $stepNum -Message "Windows system image is healthy" -Status "Pass"
            } else {
                Write-Step -StepNumber $stepNum -Message "Windows system image corruption detected" -Status "Fail"
                $isCorrupted = $true
            }
        } catch {
            Write-Step -StepNumber $stepNum -Message "Analysis error: $($_.Exception.Message)" -Status "Fail"
            $isCorrupted = $true
        }

        $stepNum++
        Write-Step -StepNumber $stepNum -Message "Checking component store cleanup status" -Status "Running"
        $needsCleanup = $false
        try {
            $analyzeOutput = & dism /online /cleanup-image /analyzecomponentstore 2>&1
            $analyzeText = $analyzeOutput | Out-String
            $needsCleanup = $analyzeText -match "Component Store Cleanup Recommended\s*:\s*Yes"
            if ($needsCleanup) {
                Write-Step -StepNumber $stepNum -Message "Component store cleanup is recommended" -Status "Info"
            } else {
                Write-Step -StepNumber $stepNum -Message "No component store cleanup needed" -Status "Pass"
            }
        } catch {
            Write-Step -StepNumber $stepNum -Message "Cleanup analysis failed: $($_.Exception.Message)" -Status "Fail"
        }

        # ── Step 4: Handle cleanup recommendation ──
        if ($needsCleanup) {
            $stepNum++
            Write-Host ""
            Write-Host "  Component store cleanup is recommended to free disk space and improve servicing."
            $doCleanup = Read-YesNo -Prompt "Would you like to run the cleanup process now?"
            if ($doCleanup) {
                Write-Step -StepNumber $stepNum -Message "Running component store cleanup" -Status "Running"
                try {
                    Repair-WindowsImage -Online -StartComponentCleanup -ErrorAction Stop | Out-Null
                    Write-Step -StepNumber $stepNum -Message "Component store cleanup completed" -Status "Pass"
                } catch {
                    Write-Step -StepNumber $stepNum -Message "Cleanup failed: $($_.Exception.Message)" -Status "Fail"
                }
            } else {
                Write-Step -StepNumber $stepNum -Message "Cleanup skipped by user" -Status "Skip"
            }
        }

        # ── Step 5: Handle corruption or healthy image ──
        $repairRan = $false
        $stepNum++
        Write-Host ""

        if ($isCorrupted) {
            Write-Host "  $($script:ErrorStyle)The Windows system image component store is corrupted.$Reset"
            Write-Host "  $($script:ErrorStyle)The component store repair process needs to be run to repair the corruption.$Reset"

            $doRepair = Read-YesNo -Prompt "Would you like to run the repair process now?"
            if ($doRepair) {
                Write-Step -StepNumber $stepNum -Message "Repairing Windows system image" -Status "Running"
                try {
                    $repairResult = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop
                    if ($repairResult.ImageHealthState -eq 'Healthy') {
                        Write-Step -StepNumber $stepNum -Message "Windows system image repaired successfully" -Status "Pass"
                    } else {
                        Write-Step -StepNumber $stepNum -Message "Repair completed: $($repairResult.ImageHealthState)" -Status "Info"
                    }
                    $repairRan = $true
                } catch {
                    Write-Step -StepNumber $stepNum -Message "Repair failed: $($_.Exception.Message)" -Status "Fail"
                }
            } else {
                Write-Host ""
                Write-Host "  $($script:ErrorStyle)WARNING: A corrupted Windows system image can:$Reset"
                Write-Host "    - Create system instability"
                Write-Host "    - Cause application failures"
                Write-Host "    - Degrade system performance"
                Write-Host "    - Prevent updates from installing, creating catastrophic security risk"

                $skipConfirm = Read-YesNo -Prompt "Are you sure you do not want to run the repair process right now?"
                if (-not $skipConfirm) {
                    Write-Step -StepNumber $stepNum -Message "Repairing Windows system image" -Status "Running"
                    try {
                        $repairResult = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop
                        if ($repairResult.ImageHealthState -eq 'Healthy') {
                            Write-Step -StepNumber $stepNum -Message "Windows system image repaired successfully" -Status "Pass"
                        } else {
                            Write-Step -StepNumber $stepNum -Message "Repair completed: $($repairResult.ImageHealthState)" -Status "Info"
                        }
                        $repairRan = $true
                    } catch {
                        Write-Step -StepNumber $stepNum -Message "Repair failed: $($_.Exception.Message)" -Status "Fail"
                    }
                } else {
                    Write-Step -StepNumber $stepNum -Message "Repair declined by user" -Status "Skip"
                }
            }
        } else {
            Write-Host "  The Windows system image is healthy. No repairs are needed."
            $doRepairAnyway = Read-YesNo -Prompt "Would you like to run the repair process anyway?"
            if ($doRepairAnyway) {
                Write-Step -StepNumber $stepNum -Message "Repairing Windows system image" -Status "Running"
                try {
                    $repairResult = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop
                    if ($repairResult.ImageHealthState -eq 'Healthy') {
                        Write-Step -StepNumber $stepNum -Message "Windows system image repair completed" -Status "Pass"
                    } else {
                        Write-Step -StepNumber $stepNum -Message "Repair completed: $($repairResult.ImageHealthState)" -Status "Info"
                    }
                    $repairRan = $true
                } catch {
                    Write-Step -StepNumber $stepNum -Message "Repair failed: $($_.Exception.Message)" -Status "Fail"
                }
            } else {
                Write-Step -StepNumber $stepNum -Message "Repair skipped by user" -Status "Skip"
            }
        }

        # ── Step 6: System file scan ──
        $stepNum++
        Write-Host ""

        if ($repairRan) {
            Write-Host "  The Windows system image has been repaired."
            Write-Host "  You now need to scan for any missing or corrupted system files."
            Write-Host ""
            Write-Host "  Press any key to continue..."
            [Console]::ReadKey($true) | Out-Null
            Write-Host ""
        } else {
            $doScan = Read-YesNo -Prompt "Would you like to scan for any missing or corrupted system files anyway?"
            if (-not $doScan) {
                return
            }
            Write-Host ""
        }

        Write-Host "  Select scan mode:"
        Write-Host "    $($script:MenuStyle)[1]$Reset Scan only (identify missing or corrupted files)"
        Write-Host "    $($script:MenuStyle)[2]$Reset Scan and repair missing or corrupted files"
        Write-Host ""
        Write-Host "  Press 1 or 2: " -NoNewline
        [Console]::CursorVisible = $true
        $sfcChoice = $null
        while ($sfcChoice -notin @('1','2')) {
            $k = [Console]::ReadKey($true)
            $sfcChoice = $k.KeyChar
        }
        Write-Host $sfcChoice
        [Console]::CursorVisible = $false

        if ($sfcChoice -eq '1') {
            Write-Step -StepNumber $stepNum -Message "Scanning for missing or corrupted system files" -Status "Running"
            Write-Host ""
            $sfcOutput = & sfc /verifyonly 2>&1
            $sfcText = $sfcOutput | Out-String
            Write-Host ""

            if ($sfcText -match "did not find any integrity violations") {
                Write-Step -StepNumber $stepNum -Message "Scan complete: No missing or corrupted system files detected" -Status "Pass"
            } else {
                Write-Step -StepNumber $stepNum -Message "Missing and/or corrupted system files were detected" -Status "Fail"
                Write-Host ""
                Write-Host "  Missing and/or corrupted system files were detected and need to be repaired."
                Write-Host "  Press any key to begin repairing system files..."
                [Console]::ReadKey($true) | Out-Null

                $stepNum++
                Write-Step -StepNumber $stepNum -Message "Repairing system files" -Status "Running"
                Write-Host ""
                & sfc /scannow
                Write-Host ""
                Write-Step -StepNumber $stepNum -Message "System file repair completed" -Status "Pass"
            }
        } else {
            Write-Step -StepNumber $stepNum -Message "Scanning and repairing system files" -Status "Running"
            Write-Host ""
            & sfc /scannow
            Write-Host ""
            Write-Step -StepNumber $stepNum -Message "System file scan and repair completed" -Status "Pass"
        }

        Write-Host ""
        Write-Host "  $($script:SuccessStyle)Component store verification complete.$Reset"
        Write-Host ""
        Write-Host "  Press any key to return..."
        [Console]::ReadKey($true) | Out-Null
    }

    function Invoke-VerifyWMIHealth {
        Show-OperationScreen -Title "System Administration & Maintenance" -Subtitle "Check WMI Repository Health"

        $stepNum = 0

        # Step 1: Check WMI service status
        $stepNum++
        Write-Step -StepNumber $stepNum -Message "Checking WMI service status" -Status "Running"
        $svc = Get-Service -Name Winmgmt -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Step -StepNumber $stepNum -Message "WMI service is running" -Status "Pass"
        } elseif ($svc) {
            Write-Step -StepNumber $stepNum -Message "WMI service is $($svc.Status)" -Status "Fail"
            $startSvc = Read-YesNo -Prompt "WMI service is not running. Attempt to start?"
            if ($startSvc) {
                try {
                    Start-Service -Name Winmgmt -ErrorAction Stop
                    Write-Step -StepNumber $stepNum -Message "WMI service started" -Status "Pass"
                } catch {
                    Write-Step -StepNumber $stepNum -Message "Failed to start: $($_.Exception.Message)" -Status "Fail"
                }
            }
        } else {
            Write-Step -StepNumber $stepNum -Message "WMI service not found" -Status "Fail"
        }

        # Step 2: Check WMI prerequisites
        $stepNum++
        Write-Host ""
        Write-Step -StepNumber $stepNum -Message "Checking WMI prerequisites" -Status "Running"
        $wbemPath = "$env:SystemRoot\System32\wbem"
        $requiredFiles = @("wbemcore.dll", "wbemprox.dll", "wmiutils.dll", "mofcomp.exe", "winmgmt.exe")
        $missingFiles = @()
        foreach ($file in $requiredFiles) {
            if (-not (Test-Path (Join-Path $wbemPath $file))) {
                $missingFiles += $file
            }
        }
        if ($missingFiles.Count -eq 0) {
            Write-Step -StepNumber $stepNum -Message "All WMI components present" -Status "Pass"
        } else {
            Write-Step -StepNumber $stepNum -Message "Missing: $($missingFiles -join ', ')" -Status "Fail"
        }

        # Step 3: Verify WMI repository
        $stepNum++
        Write-Host ""
        Write-Step -StepNumber $stepNum -Message "Verifying WMI repository consistency" -Status "Running"
        $verifyOutput = & winmgmt /verifyrepository 2>&1
        $verifyText = ($verifyOutput | Out-String).Trim()

        if ($verifyText -match "consistent") {
            Write-Step -StepNumber $stepNum -Message "WMI repository is consistent" -Status "Pass"
        } else {
            Write-Step -StepNumber $stepNum -Message "WMI repository is inconsistent" -Status "Fail"

            # Step 4: Salvage repository
            $stepNum++
            $doSalvage = Read-YesNo -Prompt "WMI repository is inconsistent. Attempt salvage?"
            if ($doSalvage) {
                Write-Step -StepNumber $stepNum -Message "Salvaging WMI repository" -Status "Running"
                & winmgmt /salvagerepository 2>&1 | Out-Null

                $verifyAgain = & winmgmt /verifyrepository 2>&1
                $verifyAgainText = ($verifyAgain | Out-String).Trim()

                if ($verifyAgainText -match "consistent") {
                    Write-Step -StepNumber $stepNum -Message "WMI repository salvaged successfully" -Status "Pass"
                } else {
                    Write-Step -StepNumber $stepNum -Message "Salvage did not resolve inconsistency" -Status "Fail"

                    # Step 5: Reset repository
                    $stepNum++
                    $doReset = Read-YesNo -Prompt "Salvage failed. Reset WMI repository? (Rebuilds from scratch)"
                    if ($doReset) {
                        Write-Step -StepNumber $stepNum -Message "Resetting WMI repository" -Status "Running"
                        & winmgmt /resetrepository 2>&1 | Out-Null

                        $verifyFinal = & winmgmt /verifyrepository 2>&1
                        $verifyFinalText = ($verifyFinal | Out-String).Trim()
                        if ($verifyFinalText -match "consistent") {
                            Write-Step -StepNumber $stepNum -Message "WMI repository reset successfully" -Status "Pass"
                        } else {
                            Write-Step -StepNumber $stepNum -Message "Repository reset completed with warnings" -Status "Info"
                        }
                    } else {
                        Write-Step -StepNumber $stepNum -Message "Repository reset skipped" -Status "Skip"
                    }
                }
            } else {
                Write-Step -StepNumber $stepNum -Message "Salvage skipped by user" -Status "Skip"
            }
        }

        # Step N: Test WMI functionality
        $stepNum++
        Write-Host ""
        Write-Step -StepNumber $stepNum -Message "Testing WMI functionality" -Status "Running"
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            if ($os) {
                Write-Step -StepNumber $stepNum -Message "WMI queries operating normally" -Status "Pass"
            } else {
                Write-Step -StepNumber $stepNum -Message "WMI query returned no data" -Status "Fail"
            }
        } catch {
            Write-Step -StepNumber $stepNum -Message "WMI query failed: $($_.Exception.Message)" -Status "Fail"

            $stepNum++
            $doReregister = Read-YesNo -Prompt "WMI queries failing. Re-register WMI providers?"
            if ($doReregister) {
                Write-Step -StepNumber $stepNum -Message "Re-registering WMI providers" -Status "Running"
                $mofFiles = Get-ChildItem -Path $wbemPath -Filter "*.mof" -ErrorAction SilentlyContinue
                $registered = 0
                foreach ($mof in $mofFiles) {
                    try {
                        & mofcomp $mof.FullName 2>&1 | Out-Null
                        $registered++
                    } catch {}
                }
                Write-Step -StepNumber $stepNum -Message "Re-registered $registered MOF files" -Status "Pass"
            } else {
                Write-Step -StepNumber $stepNum -Message "Provider re-registration skipped" -Status "Skip"
            }
        }

        Write-Host ""
        Write-Host "  $($script:SuccessStyle)WMI health verification complete.$Reset"
        Write-Host ""
        Write-Host "  Press any key to return..."
        [Console]::ReadKey($true) | Out-Null
    }

    # --- System Settings Functions ------------------------------------------------

    function Get-StorageSenseEnabled {
        try {
            $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
            if (Test-Path $regPath) {
                $val = Get-ItemPropertyValue -Path $regPath -Name "01" -ErrorAction SilentlyContinue
                return ($val -eq 1)
            }
            return $false
        } catch {
            return $false
        }
    }

    function Show-StorageCleanupUI {
        # Non-italic styles for this screen
        $bgCode = $script:HighlightBg + 10
        $localMenuStyle      = "$ESC[$($script:MenuFg)m"
        $localHighlightStyle = "$ESC[$($script:HighlightFg);${bgCode}m"

        [Console]::Clear()
        [Console]::CursorVisible = $false
        Show-TitleBanner -Title "Enable System Storage Sense"
        Write-Host ""
        Write-Host "  ${localMenuStyle}Calculating cleanup category sizes...$Reset"

        # Calculate sizes
        $sid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        $recycleBinPath = "$env:SystemDrive\`$Recycle.Bin\$sid"

        $thumbSize = [long]0
        $thumbPath = "$env:LocalAppData\Microsoft\Windows\Explorer"
        if (Test-Path $thumbPath) {
            $sum = (Get-ChildItem $thumbPath -Filter "thumbcache_*.db" -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($sum) { $thumbSize = $sum }
        }

        $items = @(
            @{
                Name = "Downloads"
                Key = "Downloads"
                Size = (Get-FolderSize -Paths @("$env:USERPROFILE\Downloads"))
                Selected = [bool]$script:StorageSenseSettings["Downloads"]
                Desc = "Warning: These are files in your personal downloads folder. Select this if you'd like to delete everything. This does not respect Storage Sense configuration."
                DescExtra = "The Technical Solutions Provider (TSP) will be creating a custom cleanup option for the download folder in a later version release of the CybtekSTK Navigation Menu script."
                DescSignature = "- Sonny M. Gibson, TSP (2/6/26)"
            }
            @{
                Name = "Delivery Optimization Files"
                Key = "DeliveryOptimization"
                Size = (Get-FolderSize -Paths @("$env:SystemRoot\SoftwareDistribution\DeliveryOptimization"))
                Selected = [bool]$script:StorageSenseSettings["DeliveryOptimization"]
                Desc = "Delivery Optimization is used to download updates from Microsoft. These files are stored in a dedicated cache to be uploaded to other devices on your local network (if your settings allow such use). You may safely delete these files if you need the space."
            }
            @{
                Name = "Windows Update Clean-up"
                Key = "WindowsUpdate"
                Size = (Get-FolderSize -Paths @("$env:SystemRoot\SoftwareDistribution\Download"))
                Selected = [bool]$script:StorageSenseSettings["WindowsUpdate"]
                Desc = "Windows keeps copies of all installed updates from Windows Updates, even after installing newer versions of updates. Windows Update clean-up deletes or compresses older versions of updates that are no longer needed and take up space. You might need to restart your computer."
            }
            @{
                Name = "Thumbnails"
                Key = "Thumbnails"
                Size = $thumbSize
                Selected = [bool]$script:StorageSenseSettings["Thumbnails"]
                Desc = "Windows keeps a copy of all your pictures, videos and documents thumbnails so they can be displayed quickly when you open a folder. If you delete these thumbnails, they will be automatically recreated as needed."
            }
            @{
                Name = "Microsoft Defender Antivirus"
                Key = "Defender"
                Size = (Get-FolderSize -Paths @("$env:ProgramData\Microsoft\Windows Defender\Scans\History"))
                Selected = [bool]$script:StorageSenseSettings["Defender"]
                Desc = "Non-critical files used by Microsoft Defender antivirus."
            }
            @{
                Name = "Temporary Internet Files"
                Key = "INetCache"
                Size = (Get-FolderSize -Paths @("$env:LocalAppData\Microsoft\Windows\INetCache"))
                Selected = [bool]$script:StorageSenseSettings["INetCache"]
                Desc = "The Temporary Internet Files folder contains web pages stored on your hard disk for quick viewing. Your personalized settings for web pages will be left intact."
            }
            @{
                Name = "Recycle Bin"
                Key = "RecycleBin"
                Size = (Get-FolderSize -Paths @($recycleBinPath))
                Selected = [bool]$script:StorageSenseSettings["RecycleBin"]
                Desc = "The Recycle Bin contains files that you have deleted from your computer. These files are not permanently removed until you empty the Recycle Bin."
            }
            @{
                Name = "Windows error reports and feedback"
                Key = "WER"
                Size = (Get-FolderSize -Paths @("$env:LocalAppData\Microsoft\Windows\WER", "$env:ProgramData\Microsoft\Windows\WER"))
                Selected = [bool]$script:StorageSenseSettings["WER"]
                Desc = "Diagnostic files generated from Windows errors and user feedback."
            }
            @{
                Name = "Temporary files"
                Key = "TempFiles"
                Size = (Get-FolderSize -Paths @("$env:TEMP", "$env:SystemRoot\Temp"))
                Selected = [bool]$script:StorageSenseSettings["TempFiles"]
                Desc = "Apps can store temporary information in specific folders. These can be cleaned up manually if the app does not do it automatically."
            }
            @{
                Name = "DirectX Shared Cache"
                Key = "DirectX"
                Size = (Get-FolderSize -Paths @("$env:LocalAppData\D3DSCache"))
                Selected = [bool]$script:StorageSenseSettings["DirectX"]
                Desc = "Clean up files created by the graphics system which can speed up application load time and improve responsiveness. They will be re-generated as needed."
            }
        )

        # Pre-calculate max size string width for alignment
        $maxSizeWidth = 0
        foreach ($itm in $items) {
            $len = (Format-FileSize $itm.Size).Length
            if ($len -gt $maxSizeWidth) { $maxSizeWidth = $len }
        }

        $curIndex = 0

        while ($true) {
            [Console]::Clear()
            [Console]::CursorVisible = $false
            Show-TitleBanner -Title "Enable System Storage Sense"

            # Layout dimensions
            $margin = 2
            $boxWidth = [Console]::WindowWidth - ($margin * 2)
            $innerWidth = $boxWidth - 2
            $leftColWidth = [Math]::Floor(($innerWidth - 1) / 2)
            $rightColWidth = $innerWidth - $leftColWidth - 1

            $pad = ' ' * $margin
            $hBar = [char]0x2500
            $vBar = [char]0x2502

            # Wrap description for current item
            $descLines = Get-WrappedLines -Text $items[$curIndex].Desc -Width ($rightColWidth - 2)
            $orangeStartLine = -1
            $signatureLine = -1

            if ($items[$curIndex].DescExtra) {
                $orangeStartLine = $descLines.Count + 1
                $descLines += ""
                $extraLines = Get-WrappedLines -Text $items[$curIndex].DescExtra -Width ($rightColWidth - 2)
                $descLines += $extraLines
                if ($items[$curIndex].DescSignature) {
                    $descLines += ""
                    $sigText = $items[$curIndex].DescSignature
                    $sigPadded = $sigText.PadLeft($rightColWidth - 2) + " "
                    $signatureLine = $descLines.Count
                    $descLines += $sigPadded
                }
            }

            # Rows: items + separator + total
            $contentRows = $items.Count + 2
            $maxRows = [Math]::Max($contentRows, $descLines.Count)

            # Top border
            $topLine = [char]0x250C + ([string]$hBar * $leftColWidth) + [char]0x252C + ([string]$hBar * $rightColWidth) + [char]0x2510
            Write-Host "$pad$($script:BorderStyle)$topLine$Reset"

            for ($row = 0; $row -lt $maxRows; $row++) {
                # --- Left cell ---
                $leftText = ""
                $leftIsHighlight = $false
                $leftIsSeparator = $false

                if ($row -lt $items.Count) {
                    $item = $items[$row]
                    $chk = if ($item.Selected) { "X" } else { "_" }
                    $sizeStr = (Format-FileSize $item.Size).PadLeft($maxSizeWidth)
                    $nameMaxLen = $leftColWidth - 6 - $maxSizeWidth - 1
                    if ($nameMaxLen -lt 10) { $nameMaxLen = 10 }
                    $name = $item.Name
                    if ($name.Length -gt $nameMaxLen) { $name = $name.Substring(0, $nameMaxLen) }
                    $leftText = " [$chk] $($name.PadRight($nameMaxLen))$sizeStr "
                    if ($row -eq $curIndex) { $leftIsHighlight = $true }
                }
                elseif ($row -eq $items.Count) {
                    $leftText = [string]$hBar * $leftColWidth
                    $leftIsSeparator = $true
                }
                elseif ($row -eq $items.Count + 1) {
                    $selectedSize = [long]0
                    foreach ($itm in $items) { if ($itm.Selected) { $selectedSize += $itm.Size } }
                    $totalSize = [long]0
                    foreach ($itm in $items) { $totalSize += $itm.Size }
                    $selStr = Format-FileSize $selectedSize
                    $totStr = Format-FileSize $totalSize
                    $totalLabel = " Total selected"
                    $totalSizes = "$selStr of $totStr "
                    $totalGap = $leftColWidth - $totalLabel.Length - $totalSizes.Length
                    if ($totalGap -lt 1) { $totalGap = 1 }
                    $leftText = $totalLabel + (' ' * $totalGap) + $totalSizes
                }

                if ($leftText.Length -lt $leftColWidth) { $leftText = $leftText.PadRight($leftColWidth) }
                if ($leftText.Length -gt $leftColWidth) { $leftText = $leftText.Substring(0, $leftColWidth) }

                # --- Right cell ---
                $rightText = ""
                if ($row -lt $descLines.Count) {
                    $rightText = " " + $descLines[$row]
                }
                if ($rightText.Length -lt $rightColWidth) { $rightText = $rightText.PadRight($rightColWidth) }
                if ($rightText.Length -gt $rightColWidth) { $rightText = $rightText.Substring(0, $rightColWidth) }

                # --- Render ---
                Write-Host "$pad$($script:BorderStyle)$vBar$Reset" -NoNewline

                if ($leftIsHighlight) {
                    Write-Host "${localHighlightStyle}$leftText$Reset" -NoNewline
                }
                elseif ($leftIsSeparator) {
                    Write-Host "$($script:BorderStyle)$leftText$Reset" -NoNewline
                }
                else {
                    Write-Host "${localMenuStyle}$leftText$Reset" -NoNewline
                }

                Write-Host "$($script:BorderStyle)$vBar$Reset" -NoNewline
                if ($signatureLine -ge 0 -and $row -eq $signatureLine) {
                    Write-Host "$ESC[36m$rightText$Reset" -NoNewline
                }
                elseif ($orangeStartLine -ge 0 -and $row -ge $orangeStartLine) {
                    Write-Host "$ESC[38;5;208m$rightText$Reset" -NoNewline
                }
                else {
                    Write-Host "${localMenuStyle}$rightText$Reset" -NoNewline
                }
                Write-Host "$($script:BorderStyle)$vBar$Reset"
            }

            # Bottom border
            $botLine = [char]0x2514 + ([string]$hBar * $leftColWidth) + [char]0x2534 + ([string]$hBar * $rightColWidth) + [char]0x2518
            Write-Host "$pad$($script:BorderStyle)$botLine$Reset"

            Write-Host ""
            $altWText = "When finished use shortcut keys [Alt] + [W] to save and enable Storage Sense."
            $altWPad = Get-CenterPadding -TextLength $altWText.Length
            Write-Host "$altWPad$ESC[38;5;208m$altWText$Reset"
            Write-Host ""
            $hintText = "Arrow Keys = Navigate   Space = Toggle   Escape = Back"
            $hintPad = Get-CenterPadding -TextLength ($hintText.Length + 4)
            Write-Host "$hintPad${localMenuStyle}  $hintText  $Reset"

            Show-FooterBanner

            $key = Wait-KeyWithClock

            switch ($key.Key) {
                'UpArrow' {
                    if ($curIndex -gt 0) { $curIndex-- } else { $curIndex = $items.Count - 1 }
                }
                'DownArrow' {
                    if ($curIndex -lt ($items.Count - 1)) { $curIndex++ } else { $curIndex = 0 }
                }
                'Spacebar' {
                    $items[$curIndex].Selected = -not $items[$curIndex].Selected
                    $script:StorageSenseSettings[$items[$curIndex].Key] = $items[$curIndex].Selected
                    Save-Settings
                }
                'Enter' {
                    $hasSelected = $false
                    foreach ($itm in $items) { if ($itm.Selected) { $hasSelected = $true; break } }

                    if ($hasSelected) {
                        $confirm = Read-YesNo -Prompt "Clean selected items and enable Storage Sense?"
                        if ($confirm) {
                            Invoke-StorageCleanup -Items $items
                            try {
                                $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
                                if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                                Set-ItemProperty -Path $regPath -Name "01" -Value 1 -Type DWord
                            } catch {}
                            Show-StatusMessage -Message "Selected items cleaned. Storage Sense enabled."
                            return
                        }
                    } else {
                        $confirm = Read-YesNo -Prompt "Enable System Storage Sense without cleaning?"
                        if ($confirm) {
                            try {
                                $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
                                if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                                Set-ItemProperty -Path $regPath -Name "01" -Value 1 -Type DWord
                            } catch {}
                            Show-StatusMessage -Message "System Storage Sense has been enabled."
                            return
                        }
                    }
                }
                'W' {
                    if ($key.Modifiers -band [ConsoleModifiers]::Alt) {
                        # Save user settings to JSON
                        Save-Settings

                        # Enable Storage Sense in Windows registry
                        try {
                            $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
                            if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                            Set-ItemProperty -Path $regPath -Name "01" -Value 1 -Type DWord
                        } catch {}

                        # Clear screen and show confirmation between header and footer
                        [Console]::Clear()
                        Show-TitleBanner -Title "System Settings & Configurations"

                        Write-Host ""
                        $msg1 = "System Storage Sense is now enabled and configured to your custom settings."
                        $msg1Pad = Get-CenterPadding -TextLength $msg1.Length
                        Write-Host "$msg1Pad${localMenuStyle}$msg1$Reset"
                        Write-Host ""
                        $msg2 = "Would you like to run the Storage Sense Cleanup Service now? Y/N"
                        $msg2Pad = Get-CenterPadding -TextLength $msg2.Length
                        Write-Host "$msg2Pad${localMenuStyle}$msg2$Reset"

                        Show-FooterBanner

                        # Wait for Y/N with live clock
                        $answer = $null
                        while ($null -eq $answer) {
                            if ([Console]::KeyAvailable) {
                                $k = [Console]::ReadKey($true)
                                if ($k.KeyChar -eq 'Y' -or $k.KeyChar -eq 'y') { $answer = 'Y' }
                                elseif ($k.KeyChar -eq 'N' -or $k.KeyChar -eq 'n') { $answer = 'N' }
                            }
                            Update-FooterClock
                            Start-Sleep -Milliseconds 200
                        }

                        if ($answer -eq 'Y') {
                            Invoke-StorageCleanup -Items $items
                        }
                        # Return $true to signal parent menu to go back to main menu
                        return $true
                    }
                }
                'Escape' { return }
            }
        }
    }

    function Invoke-StorageCleanup {
        param([array]$Items)
        Show-OperationScreen -Title "System Settings & Configurations" -Subtitle "Cleaning Selected Items"

        $stepNum = 0
        foreach ($item in $Items) {
            if (-not $item.Selected) { continue }
            $stepNum++
            Write-Step -StepNumber $stepNum -Message "Cleaning $($item.Name)" -Status "Running"
            try {
                switch ($item.Key) {
                    "Downloads" {
                        Get-ChildItem "$env:USERPROFILE\Downloads" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "DeliveryOptimization" {
                        Get-ChildItem "$env:SystemRoot\SoftwareDistribution\DeliveryOptimization" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "WindowsUpdate" {
                        Get-ChildItem "$env:SystemRoot\SoftwareDistribution\Download" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "Thumbnails" {
                        Get-ChildItem "$env:LocalAppData\Microsoft\Windows\Explorer" -Filter "thumbcache_*.db" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Force -ErrorAction SilentlyContinue
                    }
                    "Defender" {
                        Get-ChildItem "$env:ProgramData\Microsoft\Windows Defender\Scans\History" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "INetCache" {
                        Get-ChildItem "$env:LocalAppData\Microsoft\Windows\INetCache" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "RecycleBin" {
                        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                    }
                    "WER" {
                        Get-ChildItem "$env:LocalAppData\Microsoft\Windows\WER" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                        Get-ChildItem "$env:ProgramData\Microsoft\Windows\WER" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "TempFiles" {
                        Get-ChildItem "$env:TEMP" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                        Get-ChildItem "$env:SystemRoot\Temp" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "DirectX" {
                        Get-ChildItem "$env:LocalAppData\D3DSCache" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-Step -StepNumber $stepNum -Message "Cleaned $($item.Name)" -Status "Pass"
            }
            catch {
                Write-Step -StepNumber $stepNum -Message "Failed: $($_.Exception.Message)" -Status "Fail"
            }
        }

        Write-Host ""
        Write-Host "  $($script:SuccessStyle)Cleanup complete.$Reset"
        Write-Host ""
        Write-Host "  Press any key to continue..."
        [Console]::ReadKey($true) | Out-Null
    }

    function Invoke-SystemFactoryReset {
        [Console]::Clear()
        [Console]::CursorVisible = $false

        Show-TitleBanner -Title "System Settings & Configurations"

        $headerEndRow = [Console]::CursorTop
        $footerStartRow = [Console]::WindowHeight - 5

        # Vertically center content (msg1 + blank + msg2 + blank + options = 5 lines)
        $verticalPad = [Math]::Max(0, [Math]::Floor(($footerStartRow - $headerEndRow - 5) / 2))
        for ($p = 0; $p -lt $verticalPad; $p++) { Write-Host "" }

        $msg1 = "Preparing to Reset Windows 11 Operating System"
        $msg1Pad = Get-CenterPadding -TextLength $msg1.Length
        Write-Host "$msg1Pad$($script:TitleStyle)$msg1$Reset"

        Write-Host ""
        $msg2 = "Do you want to keep your programs and files or perform a full factory reset"
        $msg2Pad = Get-CenterPadding -TextLength $msg2.Length
        Write-Host "$msg2Pad$($script:MenuStyle)$msg2$Reset"

        Write-Host ""
        $optionRow = [Console]::CursorTop
        $selectedOption = 0

        # Write placeholder for option line then position footer at bottom
        Write-Host ""
        if (([Console]::CursorTop) -lt $footerStartRow) {
            [Console]::SetCursorPosition(0, $footerStartRow)
        } else { Write-Host ""; Write-Host "" }
        Show-FooterBanner

        # Option selection loop
        while ($true) {
            [Console]::SetCursorPosition(0, $optionRow)

            $opt1 = "[PARTIAL FACTORY RESET]"
            $opt2 = "[FULL FACTORY RESET]"
            $gap = 5
            $totalWidth = $opt1.Length + $gap + $opt2.Length
            $optPad = Get-CenterPadding -TextLength $totalWidth

            Write-Host -NoNewline $optPad
            if ($selectedOption -eq 0) {
                Write-Host -NoNewline "$($script:HighlightStyle)$opt1$Reset"
            } else {
                Write-Host -NoNewline "$($script:MenuStyle)$opt1$Reset"
            }
            Write-Host -NoNewline (" " * $gap)
            if ($selectedOption -eq 1) {
                Write-Host -NoNewline "$($script:HighlightStyle)$opt2$Reset"
            } else {
                Write-Host -NoNewline "$($script:MenuStyle)$opt2$Reset"
            }
            Write-Host ""

            $key = Wait-KeyWithClock

            switch ($key.Key) {
                'LeftArrow'  { $selectedOption = 0 }
                'RightArrow' { $selectedOption = 1 }
                'Escape' { return }
                'Enter' { break }
            }
        }

        $isFullReset = ($selectedOption -eq 1)
        $resetType = if ($isFullReset) { "FULL FACTORY RESET" } else { "PARTIAL FACTORY RESET" }

        # Countdown screen
        [Console]::Clear()
        Show-TitleBanner -Title "System Settings & Configurations"

        $headerEndRow = [Console]::CursorTop
        $footerStartRow = [Console]::WindowHeight - 5

        # Vertically center the countdown message (1 line)
        $verticalPad = [Math]::Max(0, [Math]::Floor(($footerStartRow - $headerEndRow - 1) / 2))
        for ($p = 0; $p -lt $verticalPad; $p++) { Write-Host "" }

        $countdownRow = [Console]::CursorTop

        # Write initial message
        $initMsg = "Windows will begin perform a $resetType in 10 seconds. Press any key to cancel."
        $initPad = Get-CenterPadding -TextLength $initMsg.Length
        Write-Host "$initPad$($script:MenuStyle)$initMsg$Reset"

        # Position footer at bottom
        if (([Console]::CursorTop) -lt $footerStartRow) {
            [Console]::SetCursorPosition(0, $footerStartRow)
        } else { Write-Host ""; Write-Host "" }
        Show-FooterBanner

        # Countdown loop
        for ($countdown = 10; $countdown -ge 0; $countdown--) {
            $savedLeft = [Console]::CursorLeft
            $savedTop = [Console]::CursorTop
            [Console]::SetCursorPosition(0, $countdownRow)

            $countdownMsg = "Windows will begin perform a $resetType in $countdown seconds. Press any key to cancel."
            $countdownPad = Get-CenterPadding -TextLength $countdownMsg.Length

            Write-Host (" " * [Console]::WindowWidth) -NoNewline
            [Console]::SetCursorPosition(0, $countdownRow)
            Write-Host "$countdownPad$($script:MenuStyle)$countdownMsg$Reset" -NoNewline

            [Console]::SetCursorPosition($savedLeft, $savedTop)

            if ($countdown -eq 0) { break }

            # Wait 1 second, checking for cancellation
            $deadline = [DateTime]::Now.AddSeconds(1)
            $cancelled = $false
            while ([DateTime]::Now -lt $deadline) {
                if ([Console]::KeyAvailable) {
                    [Console]::ReadKey($true) | Out-Null
                    $cancelled = $true
                    break
                }
                Update-FooterClock
                Start-Sleep -Milliseconds 200
            }

            if ($cancelled) {
                Show-StatusMessage -Message "Factory reset has been cancelled."
                return
            }
        }

        # Execute factory reset
        try {
            if ($isFullReset) {
                Invoke-CimMethod -Namespace "root/cimv2/mdm/dmmap" -ClassName "MDM_RemoteWipe" -MethodName "doWipeMethod" -ErrorAction Stop
            } else {
                Invoke-CimMethod -Namespace "root/cimv2/mdm/dmmap" -ClassName "MDM_RemoteWipe" -MethodName "doWipeProtectedMethod" -ErrorAction Stop
            }
        } catch {
            Start-Process "systemreset.exe" -ArgumentList "--factoryreset"
        }
    }

    function Show-SystemSettingsMenu {
        $menuIndex = 0
        while ($true) {
            $storageSenseEnabled = Get-StorageSenseEnabled
            $storageText = if ($storageSenseEnabled) { "Disable System Storage Sense" } else { "Enable System Storage Sense" }

            $isAdmin = Test-AdminGroupMember
            $privText = if ($isAdmin) { "Disable Privileged User Access" } else { "Enable Privileged User Access" }

            $menuItems = @(
                $storageText,
                $privText,
                "System Factory Reset Windows OS",
                "Back to Main Menu"
            )

            Show-Menu -Items $menuItems -Selected $menuIndex -Title "System Settings & Configurations"

            $key = Wait-KeyWithClock

            switch ($key.Key) {
                'UpArrow' {
                    if ($menuIndex -le 0) { $menuIndex = $menuItems.Count - 1 }
                    else { $menuIndex-- }
                }
                'DownArrow' {
                    if ($menuIndex -ge ($menuItems.Count - 1)) { $menuIndex = 0 }
                    else { $menuIndex++ }
                }
                'Escape' { return }
                'Enter' {
                    switch ($menuIndex) {
                        0 {
                            if ($storageSenseEnabled) {
                                try {
                                    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
                                    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
                                    Set-ItemProperty -Path $regPath -Name "01" -Value 0 -Type DWord
                                    Show-StatusMessage -Message "System Storage Sense has been disabled."
                                } catch {
                                    Show-StatusMessage -Message "Error: $($_.Exception.Message)" -Type "Error"
                                }
                            } else {
                                $result = Show-StorageCleanupUI
                                if ($result -eq $true) { return }
                            }
                        }
                        1 { Invoke-TogglePrivilegedAccess -IsAdmin $isAdmin }
                        2 { Invoke-SystemFactoryReset }
                        3 { return }
                    }
                }
            }
        }
    }

    function Invoke-StorageSenseCleanup {
        Show-OperationScreen -Title "System Administration & Maintenance" -Subtitle "Cleanup Storage Sense Files"

        # Check if Storage Sense is enabled
        if (-not (Get-StorageSenseEnabled)) {
            Write-Host ""
            Write-Host "  Storage Sense needs to be enabled in order to utilize the Storage"
            Write-Host "  Sense Cleanup Recommendations. Go to the System Settings &"
            Write-Host "  Configurations menu and select Enable System Storage Sense."
            Write-Host ""
            Write-Host "  Go to System Settings & Configurations Menu now? [Y]es/[N]o: " -NoNewline
            [Console]::CursorVisible = $true
            $answer = $null
            while ($null -eq $answer) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq 'Enter') { $answer = 'N' }
                elseif ($k.KeyChar -eq 'Y' -or $k.KeyChar -eq 'y') { $answer = 'Y' }
                elseif ($k.KeyChar -eq 'N' -or $k.KeyChar -eq 'n') { $answer = 'N' }
            }
            Write-Host $answer
            [Console]::CursorVisible = $false
            if ($answer -eq 'Y') {
                Show-SystemSettingsMenu
            }
            return
        }

        Write-Host "  Scanning storage categories..."
        Write-Host ""

        # Calculate sizes for all categories
        $sid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
        $recycleBinPath = "$env:SystemDrive\`$Recycle.Bin\$sid"

        $thumbSize = [long]0
        $thumbPath = "$env:LocalAppData\Microsoft\Windows\Explorer"
        if (Test-Path $thumbPath) {
            $sum = (Get-ChildItem $thumbPath -Filter "thumbcache_*.db" -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($sum) { $thumbSize = $sum }
        }

        $categories = @(
            @{ Name = "Downloads";                          Key = "Downloads";           Size = (Get-FolderSize -Paths @("$env:USERPROFILE\Downloads")) }
            @{ Name = "Delivery Optimization Files";        Key = "DeliveryOptimization"; Size = (Get-FolderSize -Paths @("$env:SystemRoot\SoftwareDistribution\DeliveryOptimization")) }
            @{ Name = "Windows Update Clean-up";            Key = "WindowsUpdate";       Size = (Get-FolderSize -Paths @("$env:SystemRoot\SoftwareDistribution\Download")) }
            @{ Name = "Thumbnails";                         Key = "Thumbnails";          Size = $thumbSize }
            @{ Name = "Microsoft Defender Antivirus";       Key = "Defender";            Size = (Get-FolderSize -Paths @("$env:ProgramData\Microsoft\Windows Defender\Scans\History")) }
            @{ Name = "Temporary Internet Files";           Key = "INetCache";           Size = (Get-FolderSize -Paths @("$env:LocalAppData\Microsoft\Windows\INetCache")) }
            @{ Name = "Recycle Bin";                        Key = "RecycleBin";          Size = (Get-FolderSize -Paths @($recycleBinPath)) }
            @{ Name = "Windows error reports and feedback"; Key = "WER";                 Size = (Get-FolderSize -Paths @("$env:LocalAppData\Microsoft\Windows\WER", "$env:ProgramData\Microsoft\Windows\WER")) }
            @{ Name = "Temporary files";                    Key = "TempFiles";           Size = (Get-FolderSize -Paths @("$env:TEMP", "$env:SystemRoot\Temp")) }
            @{ Name = "DirectX Shared Cache";               Key = "DirectX";             Size = (Get-FolderSize -Paths @("$env:LocalAppData\D3DSCache")) }
        )

        # Calculate alignment widths
        $maxNameLen = 0
        $maxSizeWidth = 0
        foreach ($cat in $categories) {
            if ($cat.Name.Length -gt $maxNameLen) { $maxNameLen = $cat.Name.Length }
            $len = (Format-FileSize $cat.Size).Length
            if ($len -gt $maxSizeWidth) { $maxSizeWidth = $len }
        }

        $totalSize = [long]0
        foreach ($cat in $categories) { $totalSize += $cat.Size }

        # Display current sizes
        foreach ($cat in $categories) {
            $sizeStr = (Format-FileSize $cat.Size).PadLeft($maxSizeWidth)
            Write-Host "    $($cat.Name.PadRight($maxNameLen))  $sizeStr"
        }

        Write-Host ""
        Write-Host "    $("Total".PadRight($maxNameLen))  $(Format-FileSize $totalSize)"
        Write-Host ""
        Write-Host "  Running cleanup..."
        Write-Host ""

        # Clean all categories
        $stepNum = 0
        foreach ($cat in $categories) {
            $stepNum++
            Write-Step -StepNumber $stepNum -Message "Cleaning $($cat.Name)" -Status "Running"
            try {
                switch ($cat.Key) {
                    "Downloads" {
                        Get-ChildItem "$env:USERPROFILE\Downloads" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "DeliveryOptimization" {
                        Get-ChildItem "$env:SystemRoot\SoftwareDistribution\DeliveryOptimization" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "WindowsUpdate" {
                        Get-ChildItem "$env:SystemRoot\SoftwareDistribution\Download" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "Thumbnails" {
                        Get-ChildItem "$env:LocalAppData\Microsoft\Windows\Explorer" -Filter "thumbcache_*.db" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Force -ErrorAction SilentlyContinue
                    }
                    "Defender" {
                        Get-ChildItem "$env:ProgramData\Microsoft\Windows Defender\Scans\History" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "INetCache" {
                        Get-ChildItem "$env:LocalAppData\Microsoft\Windows\INetCache" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "RecycleBin" {
                        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                    }
                    "WER" {
                        Get-ChildItem "$env:LocalAppData\Microsoft\Windows\WER" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                        Get-ChildItem "$env:ProgramData\Microsoft\Windows\WER" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "TempFiles" {
                        Get-ChildItem "$env:TEMP" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                        Get-ChildItem "$env:SystemRoot\Temp" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    "DirectX" {
                        Get-ChildItem "$env:LocalAppData\D3DSCache" -Force -ErrorAction SilentlyContinue |
                            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-Step -StepNumber $stepNum -Message "Cleaned $($cat.Name)" -Status "Pass"
            }
            catch {
                Write-Step -StepNumber $stepNum -Message "Failed: $($_.Exception.Message)" -Status "Fail"
            }
        }

        # Display updated sizes (all zeroed out)
        Write-Host ""
        Write-Host "  $($script:SuccessStyle)Cleanup complete. Updated storage summary:$Reset"
        Write-Host ""

        foreach ($cat in $categories) {
            $sizeStr = "0.00 GB".PadLeft($maxSizeWidth)
            Write-Host "    $($cat.Name.PadRight($maxNameLen))  $sizeStr"
        }

        $freedStr = Format-FileSize $totalSize
        Write-Host ""
        Write-Host "    $($script:SuccessStyle)Total space freed: $freedStr$Reset"
        Write-Host ""
        Write-Host "  Press any key to continue..."
        [Console]::ReadKey($true) | Out-Null
    }

    function Invoke-WindowsUpdateService {
        [Console]::Clear()
        [Console]::CursorVisible = $false

        # 2 row margin above header
        Write-Host ""
        Write-Host ""
        Show-TitleBanner -Title "Windows Update API COM"

        $isMonthly = (Get-Date).Day -eq 1
        $consoleWidth = [Console]::WindowWidth

        # Display check type
        if ($isMonthly) {
            Write-Host "  Checking Windows Update Catalog for Monthly Update:"
        } else {
            Write-Host "  Checking Windows Update Catalog for Daily Update:"
        }
        Write-Host ""

        # Search for updates using Windows Update COM API
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $searchResult = $searcher.Search("IsInstalled=0 AND Type='Software'")
        } catch {
            Write-Host "   Error accessing Windows Update API: $($_.Exception.Message)"
            Write-Host ""
            Write-Host "  Press any key to return..."
            [Console]::ReadKey($true) | Out-Null
            return
        }

        # Build update list
        $updates = @()
        foreach ($update in $searchResult.Updates) {
            $isSecurity = $false
            $isCritical = $false
            $catDisplay = "Update"

            foreach ($cat in $update.Categories) {
                if ($cat.Name -match "Security") { $isSecurity = $true }
                if ($cat.Name -match "Critical") { $isCritical = $true }
                if ($catDisplay -eq "Update" -and $cat.Name) {
                    $catDisplay = $cat.Name -replace " Updates?$", ""
                }
            }

            if ($isSecurity -and $isCritical) { $typeStr = "Security/Critical" }
            elseif ($isSecurity) { $typeStr = "Security" }
            elseif ($isCritical) { $typeStr = "Critical" }
            else { $typeStr = $catDisplay }

            # Get KB number
            $kb = ""
            if ($update.KBArticleIDs.Count -gt 0) {
                $kb = "KB$($update.KBArticleIDs.Item(0))"
            }

            if ($isMonthly) {
                # Monthly (1st of month) - include all updates
                $updates += @{ Type = $typeStr; KB = $kb; Name = $update.Title; Update = $update }
            } else {
                # Daily - only security/critical
                if ($isSecurity -or $isCritical) {
                    $updates += @{ Type = $typeStr; KB = $kb; Name = $update.Title; Update = $update }
                }
            }
        }

        # No updates available
        if ($updates.Count -eq 0) {
            if ($isMonthly) {
                Write-Host "   No updates available at this time."
            } else {
                Write-Host "   No Security or Critical updates available at this time."
            }

            # Position footer at bottom with 2 row margin
            $footerStart = [Console]::WindowHeight - 3
            $targetRow = $footerStart - 2
            $currentRow = [Console]::CursorTop
            if ($currentRow -lt $targetRow) {
                for ($p = 0; $p -lt ($targetRow - $currentRow); $p++) { Write-Host "" }
            } else { Write-Host ""; Write-Host "" }
            Show-FooterBanner

            while (-not [Console]::KeyAvailable) {
                Update-FooterClock
                Start-Sleep -Milliseconds 200
            }
            [Console]::ReadKey($true) | Out-Null
            return
        }

        # Display numbered updates
        for ($i = 0; $i -lt $updates.Count; $i++) {
            $num = $i + 1
            $upd = $updates[$i]
            $line = "   $num. [$($upd.Type)] $($upd.KB) $($upd.Name)"
            if ($line.Length -gt ($consoleWidth - 3)) {
                $line = $line.Substring(0, $consoleWidth - 7) + ".."
            }
            Write-Host $line
        }

        # Separator line with 3-space padding on both sides
        $sepLen = [Math]::Max(1, $consoleWidth - 6)
        Write-Host "   $('-' * $sepLen)   "

        # Summary message
        Write-Host ""
        Write-Host "   $($updates.Count) Security and/or Critical updates are available for your system and must be"
        Write-Host "   installed immediately to protect the system from vulnerabilities and"
        Write-Host "   instabilities. Press any key to continue, if no key is pressed within 7"
        Write-Host "   seconds updates will be downloaded and installed automatically."

        # Position footer at bottom with 2 row margin
        $footerStart = [Console]::WindowHeight - 3
        $targetRow = $footerStart - 2
        $currentRow = [Console]::CursorTop
        if ($currentRow -lt $targetRow) {
            for ($p = 0; $p -lt ($targetRow - $currentRow); $p++) { Write-Host "" }
        } else { Write-Host ""; Write-Host "" }
        Show-FooterBanner

        # Wait 7 seconds or keypress
        $deadline = [DateTime]::Now.AddSeconds(7)
        while ([DateTime]::Now -lt $deadline) {
            if ([Console]::KeyAvailable) {
                [Console]::ReadKey($true) | Out-Null
                break
            }
            Update-FooterClock
            Start-Sleep -Milliseconds 200
        }

        # Download and install screen
        [Console]::Clear()
        Write-Host ""
        Write-Host ""
        Show-TitleBanner -Title "Windows Update API COM"
        Write-Host ""
        Write-Host "  Downloading and installing updates..."
        Write-Host ""

        try {
            $updateColl = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($upd in $updates) {
                $updateColl.Add($upd.Update) | Out-Null
            }

            # Download
            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $updateColl

            for ($i = 0; $i -lt $updates.Count; $i++) {
                Write-Step -StepNumber ($i + 1) -Message "Downloading $($updates[$i].KB)" -Status "Running"
            }

            $null = $downloader.Download()

            Write-Host ""
            Write-Host "  Installing updates..."
            Write-Host ""

            # Install
            $installer = New-Object -ComObject Microsoft.Update.Installer
            $installer.Updates = $updateColl
            $installResult = $installer.Install()

            for ($i = 0; $i -lt $updates.Count; $i++) {
                $result = $installResult.GetUpdateResult($i)
                $status = if ($result.ResultCode -eq 2) { "Pass" } else { "Fail" }
                Write-Step -StepNumber ($i + 1) -Message "Installed $($updates[$i].KB)" -Status $status
            }

            Write-Host ""
            Write-Host "  $($script:SuccessStyle)All updates have been downloaded and installed.$Reset"
        } catch {
            Write-Host ""
            Write-Host "  $($script:ErrorStyle)Error: $($_.Exception.Message)$Reset"
        }

        # Reboot message
        Write-Host ""
        Write-Host "  The system needs to be rebooted in order for the updates to take effect."
        Write-Host "  The system is going to reboot in 7 seconds or press any key to reboot now."

        # Position footer at bottom with 2 row margin
        $footerStart = [Console]::WindowHeight - 3
        $targetRow = $footerStart - 2
        $currentRow = [Console]::CursorTop
        if ($currentRow -lt $targetRow) {
            for ($p = 0; $p -lt ($targetRow - $currentRow); $p++) { Write-Host "" }
        } else { Write-Host ""; Write-Host "" }
        Show-FooterBanner

        # Wait 7 seconds or keypress then reboot
        $deadline = [DateTime]::Now.AddSeconds(7)
        while ([DateTime]::Now -lt $deadline) {
            if ([Console]::KeyAvailable) {
                [Console]::ReadKey($true) | Out-Null
                break
            }
            Update-FooterClock
            Start-Sleep -Milliseconds 200
        }

        Restart-Computer -Force
    }

    function Show-SystemAdminMenu {
        $adminIndex = 0
        while ($true) {
            $menuItems = @(
                "Check Component Store Health",
                "Check WMI Repository Health",
                "Cleanup Storage Sense Files",
                "Windows Update Service",
                "Back to Main Menu"
            )
            Show-Menu -Items $menuItems -Selected $adminIndex -Title "System Administration & Maintenance"
            $key = Wait-KeyWithClock
            switch ($key.Key) {
                'UpArrow' {
                    if ($adminIndex -le 0) { $adminIndex = $menuItems.Count - 1 }
                    else { $adminIndex-- }
                }
                'DownArrow' {
                    if ($adminIndex -ge ($menuItems.Count - 1)) { $adminIndex = 0 }
                    else { $adminIndex++ }
                }
                'Enter' {
                    switch ($adminIndex) {
                        0 { Invoke-VerifyComponentStore }
                        1 { Invoke-VerifyWMIHealth }
                        2 { Invoke-StorageSenseCleanup }
                        3 { Invoke-WindowsUpdateService }
                        4 { return }
                    }
                }
            }
        }
    }

    function Show-ServiceAccountMenu {
        $menuIndex = 0
        while ($true) {
            $serviceModeText = if ($script:TechServiceModeActive) { "Disable Technical Service Mode" } else { "Enable Technical Service Mode" }

            $menuItems = @(
                $serviceModeText,
                "Back to Main Menu"
            )
            Show-Menu -Items $menuItems -Selected $menuIndex -Title "Service & Customer Account Management"
            $key = Wait-KeyWithClock
            switch ($key.Key) {
                'UpArrow' {
                    if ($menuIndex -le 0) { $menuIndex = $menuItems.Count - 1 }
                    else { $menuIndex-- }
                }
                'DownArrow' {
                    if ($menuIndex -ge ($menuItems.Count - 1)) { $menuIndex = 0 }
                    else { $menuIndex++ }
                }
                'Escape' { return }
                'Enter' {
                    switch ($menuIndex) {
                        0 { Invoke-ToggleServiceMode }
                        1 { return }
                    }
                }
            }
        }
    }

    # --- Main Menu Loop -----------------------------------------------------

    Load-Settings

    $script:ScriptStartTime = Get-Date
    $selectedIndex = 0

    try {
        while ($true) {
            # Build menu items based on current state
            $item1 = "Service & Customer Account Management"
            $item2 = "System Settings & Configurations"
            $item3 = "System Administration & Maintenance"
            $item4 = "CybtekSTK Navigation Settings"
            $item5 = "Terminate Administration Script"

            $menuItems = @($item1, $item2, $item3, $item4, $item5)

            # Clamp selected index
            if ($selectedIndex -ge $menuItems.Count) { $selectedIndex = 0 }

            # Draw menu
            Show-Menu -Items $menuItems -Selected $selectedIndex

            # Wait for key input (live clock updates in footer)
            $key = Wait-KeyWithClock

            switch ($key.Key) {
                'UpArrow' {
                    if ($selectedIndex -le 0) { $selectedIndex = $menuItems.Count - 1 }
                    else { $selectedIndex-- }
                }
                'DownArrow' {
                    if ($selectedIndex -ge ($menuItems.Count - 1)) { $selectedIndex = 0 }
                    else { $selectedIndex++ }
                }
                'Enter' {
                    switch ($selectedIndex) {
                        0 { Show-ServiceAccountMenu }
                        1 { Show-SystemSettingsMenu }
                        2 { Show-SystemAdminMenu }
                        3 { Show-SettingsMenu }
                        4 {
                            [Console]::Clear()
                            [Console]::CursorVisible = $true
                            return
                        }
                    }
                }
            }
        }
    }
    finally {
        # Restore cursor visibility on any exit path
        [Console]::CursorVisible = $true

        # Show thank-you GUI window
        $elapsed = (Get-Date) - $script:ScriptStartTime
        $minutes = [Math]::Round($elapsed.TotalMinutes, 1)

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $form = New-Object System.Windows.Forms.Form
        $form.Text            = "CybtekSTK Navigation"
        $form.StartPosition   = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox     = $false
        $form.MinimizeBox     = $false
        $form.ClientSize      = New-Object System.Drawing.Size(360, 160)
        $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)

        $lblThank = New-Object System.Windows.Forms.Label
        $lblThank.Text      = "Thank you for using"
        $lblThank.ForeColor = [System.Drawing.Color]::White
        $lblThank.Font      = New-Object System.Drawing.Font("Segoe UI", 13)
        $lblThank.AutoSize  = $true
        $lblThank.Location  = New-Object System.Drawing.Point(0, 25)
        $lblThank.Width     = 360
        $lblThank.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $lblThank.Anchor    = 'Top,Left,Right'
        $lblThank.AutoSize  = $false
        $lblThank.Size      = New-Object System.Drawing.Size(360, 30)

        $lblName = New-Object System.Windows.Forms.Label
        $lblName.Text      = "CybtekSTK Navigation System"
        $lblName.ForeColor = [System.Drawing.Color]::Gold
        $lblName.Font      = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Bold)
        $lblName.AutoSize  = $false
        $lblName.Size      = New-Object System.Drawing.Size(360, 35)
        $lblName.Location  = New-Object System.Drawing.Point(0, 58)
        $lblName.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

        $lblTime = New-Object System.Windows.Forms.Label
        $lblTime.Text      = "Session duration: $minutes minute$(if ($minutes -ne 1) { 's' })"
        $lblTime.ForeColor = [System.Drawing.Color]::LightGray
        $lblTime.Font      = New-Object System.Drawing.Font("Segoe UI", 10)
        $lblTime.AutoSize  = $false
        $lblTime.Size      = New-Object System.Drawing.Size(360, 25)
        $lblTime.Location  = New-Object System.Drawing.Point(0, 98)
        $lblTime.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 5000
        $timer.Add_Tick({ $form.Close() })

        $form.Controls.AddRange(@($lblThank, $lblName, $lblTime))
        $form.Add_Shown({ $timer.Start() })
        $form.ShowDialog() | Out-Null
        $timer.Dispose()
        $form.Dispose()
    }
}

# --- Entry Point ------------------------------------------------------------
# Runs the menu when called directly (.\functions.ps1 or & .\functions.ps1).
# Dot-sourcing (. .\functions.ps1) imports Start-CybtekSTKNavigation without launching.

if ($MyInvocation.InvocationName -ne '.') {
    Start-CybtekSTKNavigation
}