<#
.SYNOPSIS
    Interactive directory browser using arrow keys.

.DESCRIPTION
    Navigate the filesystem in the Windows console using arrow keys.
    Up/Down to select, Enter/Right to open a folder, Left/Backspace to go up.

.PARAMETER StartPath
    The directory to start browsing from. Defaults to the current directory.

.EXAMPLE
    .\Browse-Directory.ps1
    .\Browse-Directory.ps1 -StartPath "C:\"
#>

param(
    [string]$StartPath = (Get-Location).Path
)

function Get-DirectoryListing {
    param([string]$Path)

    $items = @()

    try {
        # Directories first, then files, both sorted alphabetically
        $dirs = Get-ChildItem -Path $Path -Directory -Force -ErrorAction Stop |
            Sort-Object Name
        $files = Get-ChildItem -Path $Path -File -Force -ErrorAction Stop |
            Sort-Object Name

        foreach ($d in $dirs) {
            $items += [PSCustomObject]@{
                Name      = $d.Name
                IsDir     = $true
                Size      = $null
                LastWrite = $d.LastWriteTime
                FullPath  = $d.FullName
            }
        }
        foreach ($f in $files) {
            $items += [PSCustomObject]@{
                Name      = $f.Name
                IsDir     = $false
                Size      = $f.Length
                LastWrite = $f.LastWriteTime
                FullPath  = $f.FullName
            }
        }
    }
    catch {
        # Access denied or other error — return empty
    }

    return $items
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes  B"
}

function Draw-Screen {
    param(
        [string]$CurrentPath,
        [array]$Items,
        [int]$SelectedIndex,
        [int]$ScrollOffset,
        [string]$Message
    )

    $bufferHeight = $Host.UI.RawUI.WindowSize.Height
    $bufferWidth  = $Host.UI.RawUI.WindowSize.Width

    # Reserve lines: header(3) + footer(3) = 6
    $listHeight = $bufferHeight - 6
    if ($listHeight -lt 1) { $listHeight = 1 }

    # Move cursor to top-left and clear
    [Console]::SetCursorPosition(0, 0)

    # ── Header ──
    $headerLine = " Directory: $CurrentPath"
    if ($headerLine.Length -gt $bufferWidth) {
        $headerLine = $headerLine.Substring(0, $bufferWidth)
    }
    Write-Host ($headerLine.PadRight($bufferWidth)) -ForegroundColor Cyan -NoNewline
    Write-Host ""

    $separator = [string]::new([char]0x2500, [Math]::Min($bufferWidth, 120))
    Write-Host $separator -ForegroundColor DarkGray

    # ── Item list ──
    $countInfo = "  $($Items.Count) items"
    if ($Items.Count -eq 0) {
        $emptyMsg = "  (empty or access denied)"
        Write-Host ($emptyMsg.PadRight($bufferWidth)) -ForegroundColor DarkYellow -NoNewline
        Write-Host ""
        # Fill remaining lines
        for ($i = 1; $i -lt $listHeight; $i++) {
            Write-Host (" ".PadRight($bufferWidth)) -NoNewline
            Write-Host ""
        }
    }
    else {
        for ($row = 0; $row -lt $listHeight; $row++) {
            $idx = $ScrollOffset + $row
            if ($idx -lt $Items.Count) {
                $item = $Items[$idx]

                # Build columns
                if ($item.IsDir) {
                    $icon = "  > "
                    $sizeStr = "     <DIR>"
                }
                else {
                    $icon = "    "
                    $sizeStr = (Format-FileSize $item.Size).PadLeft(10)
                }

                $dateStr = $item.LastWrite.ToString("yyyy-MM-dd HH:mm")
                $nameMaxLen = $bufferWidth - 34
                if ($nameMaxLen -lt 10) { $nameMaxLen = 10 }

                $displayName = $item.Name
                if ($displayName.Length -gt $nameMaxLen) {
                    $displayName = $displayName.Substring(0, $nameMaxLen - 3) + "..."
                }

                $line = "$icon$($displayName.PadRight($nameMaxLen)) $sizeStr  $dateStr"
                if ($line.Length -gt $bufferWidth) {
                    $line = $line.Substring(0, $bufferWidth)
                }

                if ($idx -eq $SelectedIndex) {
                    Write-Host ($line.PadRight($bufferWidth)) -BackgroundColor DarkCyan -ForegroundColor White -NoNewline
                }
                elseif ($item.IsDir) {
                    Write-Host ($line.PadRight($bufferWidth)) -ForegroundColor Yellow -NoNewline
                }
                else {
                    Write-Host ($line.PadRight($bufferWidth)) -NoNewline
                }
                Write-Host ""
            }
            else {
                Write-Host (" ".PadRight($bufferWidth)) -NoNewline
                Write-Host ""
            }
        }
    }

    # ── Footer ──
    Write-Host $separator -ForegroundColor DarkGray
    $footerLeft = " [Up/Down] Navigate  [Enter/Right] Open  [Left/Backspace] Up  [Q] Quit"
    if ($Message) {
        $footerLeft = " $Message"
    }
    if ($footerLeft.Length -gt $bufferWidth) {
        $footerLeft = $footerLeft.Substring(0, $bufferWidth)
    }
    $posInfo = ""
    if ($Items.Count -gt 0) {
        $posInfo = " $($SelectedIndex + 1)/$($Items.Count) "
    }
    $pad = $bufferWidth - $footerLeft.Length - $posInfo.Length
    if ($pad -lt 0) { $pad = 0 }
    Write-Host ($footerLeft + (" " * $pad) + $posInfo) -ForegroundColor DarkGray -NoNewline
    Write-Host ""
}

# ── Main Loop ──

$currentPath = (Resolve-Path $StartPath).Path
$selectedIndex = 0
$message = ""

# Hide cursor for cleaner UI
[Console]::CursorVisible = $false

try {
    Clear-Host

    while ($true) {
        $items = Get-DirectoryListing -Path $currentPath

        # Clamp selection
        if ($items.Count -eq 0) {
            $selectedIndex = 0
        }
        elseif ($selectedIndex -ge $items.Count) {
            $selectedIndex = $items.Count - 1
        }

        # Calculate scroll offset
        $bufferHeight = $Host.UI.RawUI.WindowSize.Height
        $listHeight = $bufferHeight - 6
        if ($listHeight -lt 1) { $listHeight = 1 }

        # Keep selected item visible
        $scrollOffset = 0
        if ($items.Count -gt $listHeight) {
            if ($selectedIndex -ge $listHeight) {
                $scrollOffset = $selectedIndex - $listHeight + 1
            }
            # Centre the selection when possible
            $half = [Math]::Floor($listHeight / 2)
            $scrollOffset = $selectedIndex - $half
            if ($scrollOffset -lt 0) { $scrollOffset = 0 }
            $maxOffset = $items.Count - $listHeight
            if ($scrollOffset -gt $maxOffset) { $scrollOffset = $maxOffset }
        }

        Draw-Screen -CurrentPath $currentPath `
                     -Items $items `
                     -SelectedIndex $selectedIndex `
                     -ScrollOffset $scrollOffset `
                     -Message $message

        $message = ""

        # Read key
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

        switch ($key.VirtualKeyCode) {
            # Up arrow
            38 {
                if ($selectedIndex -gt 0) { $selectedIndex-- }
            }
            # Down arrow
            40 {
                if ($items.Count -gt 0 -and $selectedIndex -lt $items.Count - 1) {
                    $selectedIndex++
                }
            }
            # Right arrow / Enter
            { $_ -eq 39 -or $_ -eq 13 } {
                if ($items.Count -gt 0 -and $items[$selectedIndex].IsDir) {
                    $newPath = $items[$selectedIndex].FullPath
                    $testItems = Get-DirectoryListing -Path $newPath
                    if ($null -eq $testItems) { $testItems = @() }
                    $currentPath = $newPath
                    $selectedIndex = 0
                }
                elseif ($items.Count -gt 0) {
                    $message = "Not a directory: $($items[$selectedIndex].Name)"
                }
            }
            # Left arrow / Backspace
            { $_ -eq 37 -or $_ -eq 8 } {
                $parent = Split-Path $currentPath -Parent
                if ($parent) {
                    $oldName = Split-Path $currentPath -Leaf
                    $currentPath = $parent
                    # Try to re-select the directory we came from
                    $newItems = Get-DirectoryListing -Path $currentPath
                    $selectedIndex = 0
                    for ($i = 0; $i -lt $newItems.Count; $i++) {
                        if ($newItems[$i].Name -eq $oldName) {
                            $selectedIndex = $i
                            break
                        }
                    }
                }
                else {
                    $message = "Already at root"
                }
            }
            # Home
            36 { $selectedIndex = 0 }
            # End
            35 {
                if ($items.Count -gt 0) { $selectedIndex = $items.Count - 1 }
            }
            # Page Up
            33 {
                $selectedIndex -= $listHeight
                if ($selectedIndex -lt 0) { $selectedIndex = 0 }
            }
            # Page Down
            34 {
                $selectedIndex += $listHeight
                if ($items.Count -gt 0 -and $selectedIndex -ge $items.Count) {
                    $selectedIndex = $items.Count - 1
                }
            }
            # Q or Escape
            { $_ -eq 81 -or $_ -eq 27 } {
                Clear-Host
                Write-Host "Final directory: $currentPath" -ForegroundColor Green
                return
            }
        }
    }
}
finally {
    [Console]::CursorVisible = $true
}
