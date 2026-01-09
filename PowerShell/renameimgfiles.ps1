# Requires: Windows PowerShell 5+ (or PowerShell 7 on Windows with WinForms available)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ----------------------------
# Helper: Rename JPEGs
# ----------------------------
function Rename-JpegFiles {
    param(
        [Parameter(Mandatory)]
        [string]$FolderPath,

        [Parameter(Mandatory)]
        [string]$PreText
    )

    if (-not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        throw "Folder path is invalid or does not exist."
    }

    $clean = $PreText.Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) {
        throw "PreText cannot be blank."
    }

    # Remove characters that are invalid in Windows filenames
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    foreach ($ch in $invalid) {
        $clean = $clean.Replace($ch, '')
    }
    $clean = $clean.Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) {
        throw "PreText becomes empty after removing invalid filename characters."
    }

    # Get JPEG files (non-recursive). Sort for predictable numbering.
    $files = Get-ChildItem -LiteralPath $FolderPath -File |
        Where-Object { $_.Extension -match '^\.(jpe?g)$' } |
        Sort-Object Name

    if (-not $files -or $files.Count -eq 0) {
        return [pscustomobject]@{
            Renamed = 0
            Folder  = $FolderPath
            Note    = "No .jpg/.jpeg files found."
        }
    }

    # Two-pass rename to avoid collisions:
    # Pass 1: rename originals to unique temp names
    $tempTag = [Guid]::NewGuid().ToString("N")
    $tempMap = @()

    foreach ($f in $files) {
        $tempName = "__TMP_$tempTag" + $f.Extension.ToLowerInvariant()
        $tempPath = Join-Path -Path $FolderPath -ChildPath $tempName

        # Ensure uniqueness even in weird edge cases
        $i = 0
        while (Test-Path -LiteralPath $tempPath) {
            $i++
            $tempName = "__TMP_$tempTag" + "_$i" + $f.Extension.ToLowerInvariant()
            $tempPath = Join-Path -Path $FolderPath -ChildPath $tempName
        }

        Rename-Item -LiteralPath $f.FullName -NewName $tempName -ErrorAction Stop
        $tempMap += [pscustomobject]@{
            TempFullName = $tempPath
            Extension    = $f.Extension.ToLowerInvariant()  # keep original extension (.jpg or .jpeg)
        }
    }

    # Pass 2: rename temps to final names
    $count = 0
    foreach ($item in $tempMap) {
        $count++
        $num = "{0:D5}" -f $count
        $finalName = "{0}_{1}{2}" -f $clean, $num, $item.Extension
        $finalPath = Join-Path -Path $FolderPath -ChildPath $finalName

        if (Test-Path -LiteralPath $finalPath) {
            throw "Collision detected: '$finalName' already exists. Aborting."
        }

        Rename-Item -LiteralPath $item.TempFullName -NewName $finalName -ErrorAction Stop
    }

    return [pscustomobject]@{
        Renamed = $count
        Folder  = $FolderPath
        Prefix  = $clean
    }
}

# ----------------------------
# Build GUI
# ----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "JPEG Renamer"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(640, 210)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $true

# Folder Label
$lblFolder = New-Object System.Windows.Forms.Label
$lblFolder.Text = "Folder"
$lblFolder.AutoSize = $true
$lblFolder.Location = New-Object System.Drawing.Point(12, 18)
$form.Controls.Add($lblFolder)

# Folder TextBox
$txtFolder = New-Object System.Windows.Forms.TextBox
$txtFolder.Location = New-Object System.Drawing.Point(70, 14)
$txtFolder.Size = New-Object System.Drawing.Size(450, 24)
$txtFolder.Anchor = "Top,Left,Right"
$form.Controls.Add($txtFolder)

# Browse Button
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Browse..."
$btnBrowse.Location = New-Object System.Drawing.Point(530, 12)
$btnBrowse.Size = New-Object System.Drawing.Size(90, 28)
$btnBrowse.Anchor = "Top,Right"
$form.Controls.Add($btnBrowse)

# PreText Label
$lblPre = New-Object System.Windows.Forms.Label
$lblPre.Text = "PreText"
$lblPre.AutoSize = $true
$lblPre.Location = New-Object System.Drawing.Point(12, 62)
$form.Controls.Add($lblPre)

# PreText TextBox
$txtPre = New-Object System.Windows.Forms.TextBox
$txtPre.Location = New-Object System.Drawing.Point(70, 58)
$txtPre.Size = New-Object System.Drawing.Size(450, 24)
$txtPre.Anchor = "Top,Left,Right"
$form.Controls.Add($txtPre)

# Rename Button
$btnRename = New-Object System.Windows.Forms.Button
$btnRename.Text = "Rename"
$btnRename.Location = New-Object System.Drawing.Point(530, 56)
$btnRename.Size = New-Object System.Drawing.Size(90, 28)
$btnRename.Anchor = "Top,Right"
$form.Controls.Add($btnRename)

# Status label
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $false
$lblStatus.Text = "Select a folder, enter PreText, then click Rename."
$lblStatus.Location = New-Object System.Drawing.Point(12, 105)
$lblStatus.Size = New-Object System.Drawing.Size(608, 50)
$lblStatus.BorderStyle = "FixedSingle"
$lblStatus.Padding = New-Object System.Windows.Forms.Padding(6)
$form.Controls.Add($lblStatus)

# Folder Browser Dialog
$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$folderDialog.Description = "Select a folder containing JPEG files"
$folderDialog.ShowNewFolderButton = $false

# ----------------------------
# Events
# ----------------------------
$btnBrowse.Add_Click({
    if (Test-Path -LiteralPath $txtFolder.Text -PathType Container) {
        $folderDialog.SelectedPath = $txtFolder.Text
    } else {
        $folderDialog.SelectedPath = [Environment]::GetFolderPath("MyPictures")
    }

    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFolder.Text = $folderDialog.SelectedPath
        $lblStatus.Text = "Folder selected: $($folderDialog.SelectedPath)"
    }
})

$btnRename.Add_Click({
    try {
        $btnRename.Enabled = $false
        $btnBrowse.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        $folder = $txtFolder.Text.Trim()
        $pre    = $txtPre.Text.Trim()

        $result = Rename-JpegFiles -FolderPath $folder -PreText $pre

        if ($result.Renamed -gt 0) {
            $lblStatus.Text = "Done. Renamed $($result.Renamed) file(s) in:`r`n$($result.Folder)`r`nPrefix: $($result.Prefix)"
            [System.Windows.Forms.MessageBox]::Show(
                "Renamed $($result.Renamed) JPEG file(s).",
                "Success",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } else {
            $lblStatus.Text = "No JPEG files found in:`r`n$folder"
            [System.Windows.Forms.MessageBox]::Show(
                "No .jpg/.jpeg files found in the selected folder.",
                "Nothing to rename",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        $lblStatus.Text = "Error:`r`n$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Rename failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnRename.Enabled = $true
        $btnBrowse.Enabled = $true
    }
})

# Enter key triggers rename when PreText box is focused
$txtPre.Add_KeyDown({
    if ($_.KeyCode -eq "Enter") { $btnRename.PerformClick() }
})

# Show the form
[void]$form.ShowDialog()
