<#
.SYNOPSIS
Creates a Word document that lists every available font, rendering each name in its own font.

.DESCRIPTION
- Starts Microsoft Word via COM automation.
- Adds a new blank document.
- Iterates the Word font collection and writes the font name using that font.
- Optionally saves the document to a path you provide and/or closes Word when finished.

.PARAMETER SavePath
Optional file path to save the generated document (e.g. C:\Temp\FontSampler.docx).

.PARAMETER CloseAfter
If set, saves (when -SavePath is provided) and closes Word after populating the document.
#>
[CmdletBinding()]
param(
    [string]$SavePath,
    [switch]$CloseAfter
)

$word = $null
$doc  = $null
try {
    $word = New-Object -ComObject Word.Application
    $word.Visible = $true

    $doc = $word.Documents.Add()

    $selection = $word.Selection
    $selection.ClearFormatting()

    $fonts = $word.Fonts
    foreach ($font in $fonts) {
        $fontName = $font.Name
        if ([string]::IsNullOrWhiteSpace($fontName)) {
            continue
        }

        $selection.Font.Name = $fontName
        $selection.TypeText($fontName)
        $selection.TypeParagraph()
    }

    if ($SavePath) {
        $doc.SaveAs([ref]$SavePath)
    }
}
finally {
    if ($CloseAfter -and $word) {
        $word.Quit()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($word) | Out-Null
    }
}
