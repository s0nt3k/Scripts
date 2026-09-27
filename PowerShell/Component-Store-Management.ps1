<#
.SYNOPSIS
    Component Store Management - an interactive console tool for servicing the
    Windows component store (WinSxS), online or offline.

.DESCRIPTION
    On start-up you choose the component store to work against:

        1. The active (running) Windows installation
        2. An offline Windows installation on another drive letter
        3. A Windows installation ISO (install.wim / install.esd is mounted)

    You then get menus for:

        * Managing component store HEALTH
            - CheckHealth is run automatically so you can see immediately
              whether the store is healthy
            - ScanHealth (deep corruption scan)
            - RestoreHealth (repair), after which the system files are
              scanned and you are asked whether to fix anything found
            - If a scan finds no corruption you are still offered a system
              file scan (SFC)

        * Managing component store DRIVERS
            - list / install / uninstall third-party drivers
            - push the active machine's driver store into the target store
            - driver report (HTML + CSV)

        * Managing component store UPDATES
            - list / add / remove update packages (.msu / .cab)
            - push updates from the active machine's Windows Update cache
            - update report (HTML + CSV)

        * ANALYZING the component store
            - AnalyzeComponentStore report, then cleanup (flagged when
              Windows recommends it) and /ResetBase

        * BACKING UP the component store
            - servicing metadata (inventory, hives, logs): fast, small, and
              explicitly not a restorable store
            - a serviceable .wim capture (VSS snapshot when the target is the
              running system) that can be re-mounted, updated, and used as a
              DISM /Source: for RestoreHealth
            - list, verify, and re-open a backup as the working target

        * SYNCHRONISING a store up to a reference build
            - compare any store against the running installation, another
              offline installation, or a backup, and list exactly which
              packages are missing or older
            - acquire those packages from local sources, from a written
              manifest of Microsoft Update Catalog links, or by downloading
              them from the catalog
            - apply them servicing-stack-first, then verify the result

        * A PRINTABLE SESSION REPORT
            - every action taken during the sitting, with outcomes, timings
              and a sign-off block, as HTML (print-styled), CSV and JSON

.NOTES
    Run from an ELEVATED Windows PowerShell 5.1 or PowerShell 7 console.
    Requires DISM (in-box) and, for ISO work, the Dism PowerShell module.

    Mounting an ISO's install.esd read/write is not possible; the script
    offers to export the selected index to a .wim first.

    There is no offline Windows Update client: Windows cannot be pointed at a
    mounted image and told to update it. Synchronising a store therefore means
    working out which packages are missing, obtaining the .msu/.cab files, and
    applying them with Add-WindowsPackage. The Microsoft Update Catalog has no
    supported API, so the download path drives its public web endpoints and may
    break without notice; the catalog-link manifest is always written first so
    the work can still be completed by hand.

    Logs, reports, backups and the update cache:
        %ProgramData%\ComponentStoreManagement
#>

[CmdletBinding()]
param(
    # Internal: set when the script relaunches itself elevated.
    [switch]$Relaunched
)

#region ------------------------------------------------------------- Globals

$Script:AppName    = 'Component Store Management'
$Script:AppVersion = '1.0'
$Script:ScriptPath = $MyInvocation.MyCommand.Path
$Script:WorkRoot   = Join-Path $env:ProgramData 'ComponentStoreManagement'
$Script:MountRoot  = Join-Path $Script:WorkRoot  'Mount'
$Script:ReportRoot = Join-Path $Script:WorkRoot  'Reports'
$Script:ExportRoot = Join-Path $Script:WorkRoot  'Exported'
$Script:LogFile    = Join-Path $Script:WorkRoot  ('CSM_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))

foreach ($dir in @($Script:WorkRoot, $Script:MountRoot, $Script:ReportRoot, $Script:ExportRoot)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$Script:BackupRoot = Join-Path $Script:WorkRoot 'Backups'
$Script:CacheRoot  = Join-Path $Script:WorkRoot 'UpdateCache'

foreach ($dir in @($Script:BackupRoot, $Script:CacheRoot)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# The component store currently being serviced.
$Script:Target = $null

# Last known health / analysis results, refreshed as operations run.
$Script:LastHealth   = $null
$Script:LastAnalysis = $null

# ---------------------------------------------------------------- Session state
#
# Everything the technician does is appended to $Script:SessionActions so the
# end-of-session report can describe the whole sitting rather than a single
# operation. The session id ties the report, the log and any backups together.

$Script:SessionId      = 'CSM-{0:yyyyMMdd-HHmmss}-{1}' -f (Get-Date),
                         ([guid]::NewGuid().ToString('N').Substring(0, 4).ToUpperInvariant())
$Script:SessionStart   = Get-Date
$Script:SessionActions = New-Object System.Collections.Generic.List[object]
$Script:SessionTargets = New-Object System.Collections.Generic.List[object]
$Script:SessionReportWritten = $false

#endregion

#region ------------------------------------------------------- UI / logging

function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP','RAW')][string]$Level = 'INFO'
    )
    $line = if ($Level -eq 'RAW') { $Message }
            else { '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}' -f (Get-Date), $Level, $Message }
    try { Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8 } catch { }
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host ">> $Message" -ForegroundColor Cyan
    Write-Log $Message 'STEP'
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "   $Message" -ForegroundColor Green
    Write-Log $Message 'OK'
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "   $Message" -ForegroundColor Yellow
    Write-Log $Message 'WARN'
}

function Write-Err {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "   $Message" -ForegroundColor Red
    Write-Log $Message 'ERROR'
}

function Write-Info {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    Write-Host "   $Message" -ForegroundColor Gray
    Write-Log $Message 'INFO'
}

function Write-Banner {
    param([Parameter(Mandatory)][string]$Title)
    $bar = '=' * 74
    Write-Host ''
    Write-Host $bar -ForegroundColor DarkCyan
    Write-Host ("  {0}" -f $Title) -ForegroundColor White
    Write-Host $bar -ForegroundColor DarkCyan
}

function Write-TargetLine {
    if ($Script:Target) {
        Write-Host ('  Target : {0}' -f $Script:Target.Label) -ForegroundColor DarkGray
    }
}

function Wait-Key {
    param([string]$Message = 'Press Enter to continue')
    Write-Host ''
    [void](Read-Host $Message)
}

function Confirm-YesNo {
    param(
        [Parameter(Mandatory)][string]$Question,
        [bool]$Default = $true
    )
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        Write-Host ''
        $answer = Read-Host ("{0} {1}" -f $Question, $hint)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Warn 'Please answer Y or N.' }
        }
    }
}

function Read-Choice {
    <#  Prints nothing; validates a menu answer against a set of allowed keys. #>
    param(
        [Parameter(Mandatory)][string[]]$Valid,
        [string]$Prompt = 'Select an option'
    )
    while ($true) {
        Write-Host ''
        $answer = (Read-Host $Prompt).Trim()
        if ($Valid -contains $answer) { return $answer }
        Write-Warn ('Invalid choice. Valid options: {0}' -f ($Valid -join ', '))
    }
}

function Expand-Selection {
    <#  Turns "1,3,5-7" or "all" into an array of 1-based indexes. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Spec,
        [Parameter(Mandatory)][int]$Max
    )
    $Spec = $Spec.Trim()
    if ([string]::IsNullOrWhiteSpace($Spec)) { return @() }
    if ($Spec -match '^(all|\*)$') { return 1..$Max }

    $result = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($Spec -split ',')) {
        $p = $part.Trim()
        if ($p -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            foreach ($n in $a..$b) { if ($n -ge 1 -and $n -le $Max) { $result.Add($n) } }
        }
        elseif ($p -match '^\d+$') {
            $n = [int]$p
            if ($n -ge 1 -and $n -le $Max) { $result.Add($n) }
        }
        elseif ($p) {
            Write-Warn ("Ignoring unrecognised selection '{0}'." -f $p)
        }
    }
    return ($result | Select-Object -Unique)
}

function Read-ExistingPath {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [ValidateSet('Any','Leaf','Container')][string]$Type = 'Any'
    )
    while ($true) {
        Write-Host ''
        $raw = (Read-Host ("{0} (blank to cancel)" -f $Prompt)).Trim().Trim('"')
        if (-not $raw) { return $null }
        if (Test-Path -LiteralPath $raw) {
            $item = Get-Item -LiteralPath $raw
            if ($Type -eq 'Leaf'      -and $item.PSIsContainer) { Write-Warn 'That is a folder, a file was expected.'; continue }
            if ($Type -eq 'Container' -and -not $item.PSIsContainer) { Write-Warn 'That is a file, a folder was expected.'; continue }
            return $item.FullName
        }
        Write-Warn 'Path not found.'
    }
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -le 0) { return '0 B' }
    $units = 'B','KB','MB','GB','TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt ($units.Count - 1)) { $Bytes /= 1024; $i++ }
    return ('{0:N2} {1}' -f $Bytes, $units[$i])
}

#endregion

#region ------------------------------------------------------- Session record

function Add-SessionAction {
    <#
        Records one technician action for the end-of-session report.

        Status is one of Ok / Warning / Failed / Info / Declined. It is kept
        distinct from the free-text Result so the report can colour and count
        outcomes without parsing prose.
    #>
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Action,
        [ValidateSet('Ok','Warning','Failed','Info','Declined')][string]$Status = 'Info',
        [string]$Result  = '',
        [string]$Detail  = '',
        [string]$Target  = $(if ($Script:Target) { $Script:Target.Label } else { '(none)' }),
        [Nullable[datetime]]$Started = $null,
        [Nullable[int]]$ExitCode = $null
    )

    $now = Get-Date
    $record = [pscustomobject]@{
        Seq       = $Script:SessionActions.Count + 1
        Time      = $now
        Started   = $(if ($Started) { $Started } else { $now })
        Duration  = $(if ($Started) { [math]::Round(($now - $Started).TotalSeconds, 1) } else { $null })
        Category  = $Category
        Action    = $Action
        Target    = $Target
        Status    = $Status
        Result    = $Result
        Detail    = $Detail
        ExitCode  = $ExitCode
    }

    $Script:SessionActions.Add($record)
    Write-Log ('SESSION [{0}] {1} / {2} -> {3} {4}' -f
        $Status, $Category, $Action, $Result, $Detail) 'INFO'
    return $record
}

function Register-SessionTarget {
    <#  Remembers each distinct component store touched during the session. #>
    param([Parameter(Mandatory)][object]$TargetObject)

    if (-not $TargetObject) { return }
    if ($Script:SessionTargets | Where-Object { $_.Label -eq $TargetObject.Label }) { return }

    $identity = Get-TargetIdentity -TargetObject $TargetObject
    $Script:SessionTargets.Add([pscustomobject]@{
        Label       = $TargetObject.Label
        Kind        = $TargetObject.Kind
        ImagePath   = $TargetObject.ImagePath
        WindowsDir  = $TargetObject.WindowsDir
        Product     = $identity.ProductName
        Build       = $identity.BuildString
        Edition     = $identity.Edition
        Arch        = $identity.Architecture
        FirstUsed   = Get-Date
    })
}

#endregion

#region ----------------------------------------------------- Target identity

function Get-OfflineRegistryValue {
    <#
        Reads values from an offline SOFTWARE hive by loading it under a
        temporary key. The hive is always unloaded again, including on failure,
        because a stranded hive keeps a file handle on the offline image and
        blocks a later unmount.
    #>
    param(
        [Parameter(Mandatory)][string]$HivePath,
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string[]]$Names
    )

    if (-not (Test-Path -LiteralPath $HivePath)) { return @{} }

    $mount  = 'CSM_OFFLINE_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $loaded = $false
    $values = @{}

    try {
        $out = & reg.exe load ("HKLM\$mount") $HivePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log ('reg load failed for {0}: {1}' -f $HivePath, ($out -join ' ')) 'WARN'
            return @{}
        }
        $loaded = $true

        $key = Get-Item -LiteralPath ("HKLM:\$mount\$SubKey") -ErrorAction Stop
        foreach ($name in $Names) {
            $values[$name] = $key.GetValue($name, $null)
        }
    }
    catch {
        Write-Log ('Offline registry read failed: {0}' -f $_.Exception.Message) 'WARN'
    }
    finally {
        if ($loaded) {
            # The .NET registry handle must be released before reg unload will
            # succeed, otherwise the hive stays loaded and the image stays locked.
            [gc]::Collect()
            [gc]::WaitForPendingFinalizers()
            & reg.exe unload ("HKLM\$mount") 2>&1 | Out-Null
        }
    }

    return $values
}

function Get-TargetIdentity {
    <#
        Returns the servicing identity of a component store: product, build,
        UBR, edition and architecture. This is what "the same version and
        build" is measured against when synchronising one store to another.
    #>
    param([object]$TargetObject = $Script:Target)

    $unknown = [pscustomobject]@{
        Kind         = $(if ($TargetObject) { $TargetObject.Kind } else { 'Unknown' })
        ProductName  = 'Unknown'
        CurrentBuild = 0
        UBR          = 0
        BuildString  = 'unknown'
        Edition      = 'Unknown'
        Architecture = 'Unknown'
        DisplayVersion = ''
        Resolved     = $false
    }

    if (-not $TargetObject) { return $unknown }

    try {
        if ($TargetObject.Kind -eq 'Online') {
            $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
                'AMD64' { 'x64' }
                'ARM64' { 'ARM64' }
                'x86'   { 'x86' }
                default { $env:PROCESSOR_ARCHITECTURE }
            }
            $build = [int]$cv.CurrentBuild
            $ubr   = [int]$(if ($null -ne $cv.UBR) { $cv.UBR } else { 0 })

            return [pscustomobject]@{
                Kind           = 'Online'
                ProductName    = [string]$cv.ProductName
                CurrentBuild   = $build
                UBR            = $ubr
                BuildString    = ('{0}.{1}' -f $build, $ubr)
                Edition        = [string]$cv.EditionID
                Architecture   = $arch
                DisplayVersion = [string]$cv.DisplayVersion
                Resolved       = $true
            }
        }

        # Offline and mounted images: read the image's own SOFTWARE hive. The
        # DISM image info does not carry the UBR, and the UBR is precisely what
        # distinguishes "patched to the same level" from "same base build".
        $winDir = $TargetObject.WindowsDir
        if (-not $winDir -and $TargetObject.ImagePath) {
            $winDir = Join-Path $TargetObject.ImagePath 'Windows'
        }
        if (-not $winDir -or -not (Test-Path -LiteralPath $winDir)) { return $unknown }

        $hive = Join-Path $winDir 'System32\config\SOFTWARE'
        $vals = Get-OfflineRegistryValue -HivePath $hive `
                    -SubKey 'Microsoft\Windows NT\CurrentVersion' `
                    -Names @('ProductName','CurrentBuild','UBR','EditionID','DisplayVersion')

        if ($vals.Count -eq 0 -or -not $vals['CurrentBuild']) { return $unknown }

        $build = [int]$vals['CurrentBuild']
        $ubr   = [int]$(if ($null -ne $vals['UBR']) { $vals['UBR'] } else { 0 })

        # Architecture comes from the image metadata where available, since the
        # offline hive does not record it in a single reliable place.
        $arch = 'Unknown'
        try {
            if ($TargetObject.WimPath) {
                $info = Get-WindowsImage -ImagePath $TargetObject.WimPath `
                                         -Index $TargetObject.Index -ErrorAction Stop
                $arch = switch ([int]$info.Architecture) {
                    0 { 'x86' } 5 { 'ARM' } 9 { 'x64' } 12 { 'ARM64' } default { 'Unknown' }
                }
            }
            elseif (Test-Path -LiteralPath (Join-Path $winDir 'SysWOW64')) { $arch = 'x64' }
            elseif (Test-Path -LiteralPath (Join-Path $winDir 'System32\ntoskrnl.exe')) { $arch = 'x86' }
        }
        catch { $arch = 'Unknown' }

        return [pscustomobject]@{
            Kind           = $TargetObject.Kind
            ProductName    = [string]$vals['ProductName']
            CurrentBuild   = $build
            UBR            = $ubr
            BuildString    = ('{0}.{1}' -f $build, $ubr)
            Edition        = [string]$vals['EditionID']
            Architecture   = $arch
            DisplayVersion = [string]$vals['DisplayVersion']
            Resolved       = $true
        }
    }
    catch {
        Write-Log ('Get-TargetIdentity failed: {0}' -f $_.Exception.Message) 'WARN'
        return $unknown
    }
}

function Show-TargetIdentity {
    param(
        [object]$TargetObject = $Script:Target,
        [string]$Caption = 'Component store identity'
    )
    $id = Get-TargetIdentity -TargetObject $TargetObject
    Write-Host ''
    Write-Host ('   {0}' -f $Caption) -ForegroundColor White
    Write-Host ('     Product : {0}' -f $id.ProductName)    -ForegroundColor Gray
    Write-Host ('     Build   : {0}{1}' -f $id.BuildString,
        $(if ($id.DisplayVersion) { "  ($($id.DisplayVersion))" } else { '' })) -ForegroundColor Gray
    Write-Host ('     Edition : {0}' -f $id.Edition)        -ForegroundColor Gray
    Write-Host ('     Arch    : {0}' -f $id.Architecture)   -ForegroundColor Gray
    if (-not $id.Resolved) {
        Write-Warn 'The build could not be read from this target; comparisons will be unreliable.'
    }
    return $id
}

function Get-PackageInventoryFor {
    <#
        Package inventory for an arbitrary target, without disturbing the
        currently selected one. Used to read a reference store during a delta.
    #>
    param(
        [Parameter(Mandatory)][object]$TargetObject,
        [switch]$All
    )
    try {
        $pkgs = if ($TargetObject.Kind -eq 'Online') {
                    Get-WindowsPackage -Online -ErrorAction Stop
                } else {
                    Get-WindowsPackage -Path $TargetObject.ImagePath -ErrorAction Stop
                }
        $pkgs = @($pkgs)
        if (-not $All) {
            $pkgs = @($pkgs | Where-Object {
                ($_.ReleaseType -match 'Update|Hotfix|Security') -or
                ($_.PackageName -match 'KB\d{6,}')
            })
        }
        return @($pkgs)
    }
    catch {
        Write-Err ("Could not enumerate packages for '{0}': {1}" -f $TargetObject.Label, $_.Exception.Message)
        return @()
    }
}

function Get-PackageIdentity {
    <#
        Splits a package name into the identity that survives versioning and the
        version itself, so two stores can be compared by "same component,
        different version" rather than by exact string.

        Package-For-KB5039302~31bf3856ad364e35~amd64~~10.0.1.7
        -> Identity  Package-For-KB5039302~31bf3856ad364e35~amd64~~
           Version   10.0.1.7
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PackageName)

    if ($PackageName -match '^(?<id>.+~)(?<ver>[\d\.]+)$') {
        return [pscustomobject]@{
            Identity = $Matches['id']
            Version  = $Matches['ver']
        }
    }
    return [pscustomobject]@{ Identity = $PackageName; Version = '' }
}

#endregion

#region ----------------------------------------------------------- Elevation

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Elevated {
    if (Test-Elevated) { return $true }

    Write-Banner 'Administrator rights required'
    Write-Warn 'Servicing the component store requires an elevated session.'

    if ($Relaunched -or -not $Script:ScriptPath) {
        Write-Err 'Please re-open PowerShell as Administrator and run this script again.'
        return $false
    }

    if (-not (Confirm-YesNo 'Relaunch this script as Administrator now?' $true)) {
        return $false
    }

    $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy','Bypass'
        '-NoExit'
        '-File', ('"{0}"' -f $Script:ScriptPath)
        '-Relaunched'
    )
    try {
        Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs | Out-Null
        Write-Ok 'Elevated session started. This window can be closed.'
    }
    catch {
        Write-Err ("Elevation was declined or failed: {0}" -f $_.Exception.Message)
    }
    return $false
}

#endregion

#region --------------------------------------------------- Native invocation

function Invoke-Dism {
    <#
        Runs dism.exe against the current target, streaming output to the
        console (progress bars collapsed) and to the log, and returns
        @{ ExitCode; Text; Lines }.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Quiet,
        [switch]$NoScope      # do not prepend /Online or /Image:
    )

    $scope = @()
    if (-not $NoScope) {
        if ($Script:Target.Kind -eq 'Online') { $scope = @('/Online') }
        else { $scope = @(('/Image:{0}' -f $Script:Target.ImagePath)) }
    }

    $full = @('/English') + $scope + $Arguments
    Write-Log ('dism.exe ' + ($full -join ' ')) 'INFO'
    if (-not $Quiet) {
        Write-Host ('   dism.exe {0}' -f ($full -join ' ')) -ForegroundColor DarkGray
    }

    $lines        = New-Object System.Collections.Generic.List[string]
    $progressSeen = $false

    & dism.exe @full 2>&1 | ForEach-Object {
        $line = ([string]$_) -replace "[`b`r]", ''
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        $lines.Add($line)
        Write-Log $line 'RAW'

        if ($line -match '^\s*\[[=\s\.]*[\d\.]*%?[=\s\.]*\]') {
            if (-not $Quiet -and -not $progressSeen) {
                Write-Host '   working, this can take several minutes...' -ForegroundColor DarkGray
                $progressSeen = $true
            }
            return
        }
        if (-not $Quiet) { Write-Host ('   {0}' -f $line) -ForegroundColor Gray }
    }

    $code = $LASTEXITCODE
    Write-Log ("dism exit code: {0}" -f $code) 'INFO'

    return [pscustomobject]@{
        ExitCode = $code
        Text     = ($lines -join [Environment]::NewLine)
        Lines    = $lines.ToArray()
    }
}

function Invoke-Sfc {
    <#
        Runs sfc.exe against the current target. sfc writes UTF-16 to the
        console, so the console encoding is switched for the duration.
    #>
    param([switch]$VerifyOnly)

    $sfcArgs = @()
    $sfcArgs += if ($VerifyOnly) { '/verifyonly' } else { '/scannow' }

    if ($Script:Target.Kind -ne 'Online') {
        $boot = $Script:Target.BootDir
        $win  = $Script:Target.WindowsDir
        $sfcArgs += ('/offbootdir={0}' -f $boot)
        $sfcArgs += ('/offwindir={0}'  -f $win)
    }

    Write-Host ('   sfc.exe {0}' -f ($sfcArgs -join ' ')) -ForegroundColor DarkGray
    Write-Host '   scanning protected system files, this can take a while...' -ForegroundColor DarkGray
    Write-Log ('sfc.exe ' + ($sfcArgs -join ' ')) 'INFO'

    $previous = [Console]::OutputEncoding
    $lines    = New-Object System.Collections.Generic.List[string]
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        & sfc.exe @sfcArgs 2>&1 | ForEach-Object {
            $line = (([string]$_) -replace "`0", '') -replace "[`b`r]", ''
            if ([string]::IsNullOrWhiteSpace($line)) { return }
            $lines.Add($line)
            Write-Log $line 'RAW'
            if ($line -notmatch '^\s*Verification\s+\d+%\s+complete') {
                Write-Host ('   {0}' -f $line) -ForegroundColor Gray
            }
        }
        $code = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previous
    }

    $text = $lines -join [Environment]::NewLine

    $state =
        if     ($text -match 'did not find any integrity violations')                  { 'Clean' }
        elseif ($text -match 'found corrupt files and successfully repaired them')     { 'Repaired' }
        elseif ($text -match 'found corrupt files but was unable to fix some')         { 'Unfixable' }
        elseif ($text -match 'found integrity violations')                             { 'Violations' }
        elseif ($text -match 'could not perform the requested operation')              { 'Failed' }
        elseif ($text -match 'could not start the repair service')                     { 'Failed' }
        else                                                                           { 'Unknown' }

    return [pscustomobject]@{
        ExitCode = $code
        State    = $state
        Text     = $text
        Lines    = $lines.ToArray()
    }
}

#endregion

#region ---------------------------------------------------- Target selection

function New-Target {
    param(
        [Parameter(Mandatory)][ValidateSet('Online','Offline','Image')][string]$Kind,
        [Parameter(Mandatory)][string]$Label,
        [string]$ImagePath,
        [string]$WindowsDir,
        [string]$BootDir,
        [string]$IsoPath,
        [string]$IsoDrive,
        [string]$WimPath,
        [int]$Index = 0,
        [bool]$Mounted = $false,
        [bool]$ReadOnly = $false
    )
    [pscustomobject]@{
        Kind       = $Kind
        Label      = $Label
        ImagePath  = $ImagePath
        WindowsDir = $WindowsDir
        BootDir    = $BootDir
        IsoPath    = $IsoPath
        IsoDrive   = $IsoDrive
        WimPath    = $WimPath
        Index      = $Index
        Mounted    = $Mounted
        ReadOnly   = $ReadOnly
        MountDir   = $(if ($Mounted) { $ImagePath } else { $null })
    }
}

function Get-OfflineWindowsVolumes {
    <#  Volumes other than the running system that contain a \Windows\WinSxS. #>
    $sysDrive = ($env:SystemDrive).TrimEnd('\')
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($vol in (Get-Volume -ErrorAction SilentlyContinue |
                      Where-Object { $_.DriveLetter } | Sort-Object DriveLetter)) {
        $root = ('{0}:\' -f $vol.DriveLetter)
        $win  = Join-Path $root 'Windows'
        if (-not (Test-Path -LiteralPath (Join-Path $win 'WinSxS'))) { continue }
        $isActive = (('{0}:' -f $vol.DriveLetter) -ieq $sysDrive)
        $result.Add([pscustomobject]@{
            Drive      = ('{0}:' -f $vol.DriveLetter)
            Root       = $root
            WindowsDir = $win
            Label      = $vol.FileSystemLabel
            SizeFree   = $vol.SizeRemaining
            Size       = $vol.Size
            IsActive   = $isActive
        })
    }
    return $result
}

function Select-OnlineTarget {
    Write-Step 'Selecting the active (running) component store'
    $target = New-Target -Kind 'Online' `
                         -Label ('Active installation - {0} ({1})' -f $env:SystemDrive, (Get-WindowsBuildString)) `
                         -ImagePath $null `
                         -WindowsDir $env:windir `
                         -BootDir ($env:SystemDrive + '\')
    Write-Ok ('Target set to the running Windows installation ({0}).' -f $env:windir)
    return $target
}

function Get-WindowsBuildString {
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $ubr = if ($cv.UBR) { $cv.UBR } else { 0 }
        return ('{0} {1}.{2}' -f $cv.ProductName, $cv.CurrentBuild, $ubr)
    }
    catch { return 'Windows' }
}

function Select-OfflineDriveTarget {
    Write-Step 'Selecting an offline component store by drive letter'

    $vols = Get-OfflineWindowsVolumes
    $candidates = @($vols | Where-Object { -not $_.IsActive })

    if ($candidates.Count -gt 0) {
        Write-Host ''
        Write-Host '   Detected offline Windows installations:' -ForegroundColor White
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $c = $candidates[$i]
            $volLabel = if ([string]::IsNullOrWhiteSpace($c.Label)) { '(no label)' } else { $c.Label }
            Write-Host ('   [{0}] {1}  {2}  free {3} of {4}' -f
                ($i + 1), $c.Drive, $volLabel,
                (Format-Bytes $c.SizeFree), (Format-Bytes $c.Size)) -ForegroundColor Gray
        }
        Write-Host '   [M] Type a drive letter manually' -ForegroundColor Gray
        Write-Host '   [0] Cancel' -ForegroundColor Gray

        $valid = @('0','M','m') + (1..$candidates.Count | ForEach-Object { "$_" })
        $pick  = Read-Choice -Valid $valid -Prompt 'Select an installation'
        if ($pick -eq '0') { return $null }
        if ($pick -notmatch '^[Mm]$') {
            $c = $candidates[[int]$pick - 1]
            return New-OfflineTargetFromRoot -Root $c.Root
        }
    }
    else {
        Write-Info 'No other Windows installations were detected automatically.'
    }

    while ($true) {
        Write-Host ''
        $letter = (Read-Host 'Drive letter of the offline Windows installation (e.g. D, blank to cancel)').Trim()
        if (-not $letter) { return $null }
        $letter = $letter.TrimEnd(':','\').ToUpper()
        if ($letter -notmatch '^[A-Z]$') { Write-Warn 'Enter a single drive letter.'; continue }
        $root = ('{0}:\' -f $letter)
        if (-not (Test-Path -LiteralPath (Join-Path $root 'Windows\WinSxS'))) {
            Write-Warn ('{0}Windows\WinSxS was not found on that drive.' -f $root)
            if (-not (Confirm-YesNo 'Use it anyway?' $false)) { continue }
        }
        return New-OfflineTargetFromRoot -Root $root
    }
}

function New-OfflineTargetFromRoot {
    param([Parameter(Mandatory)][string]$Root)
    $Root = $Root.TrimEnd('\') + '\'
    $win  = Join-Path $Root 'Windows'
    $t = New-Target -Kind 'Offline' `
                    -Label ('Offline installation - {0}' -f $Root) `
                    -ImagePath $Root `
                    -WindowsDir $win `
                    -BootDir $Root
    Write-Ok ('Target set to the offline installation at {0}.' -f $Root)
    return $t
}

function Select-IsoTarget {
    Write-Step 'Selecting a Windows installation ISO'

    $iso = Read-ExistingPath -Prompt 'Full path to the Windows installation ISO (.iso)' -Type 'Leaf'
    if (-not $iso) { return $null }
    if ([IO.Path]::GetExtension($iso) -notmatch '^\.(iso|img)$') {
        Write-Warn 'That file does not look like an ISO image.'
        if (-not (Confirm-YesNo 'Continue anyway?' $false)) { return $null }
    }

    Write-Info 'Mounting the ISO...'
    try {
        $existing = Get-DiskImage -ImagePath $iso -ErrorAction Stop
        if ($existing.Attached) {
            Write-Info 'ISO is already mounted; reusing the existing mount.'
            $di = $existing
        }
        else {
            $di = Mount-DiskImage -ImagePath $iso -PassThru -ErrorAction Stop
        }
        Start-Sleep -Milliseconds 700
        $isoDrive = ($di | Get-Volume | Where-Object DriveLetter).DriveLetter
    }
    catch {
        Write-Err ("Could not mount the ISO: {0}" -f $_.Exception.Message)
        return $null
    }

    if (-not $isoDrive) {
        Write-Err 'The ISO mounted but no drive letter was assigned.'
        Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
        return $null
    }

    $isoRoot = ('{0}:\' -f $isoDrive)
    Write-Ok ('ISO mounted at {0}' -f $isoRoot)

    $sources = Join-Path $isoRoot 'sources'
    $image =
        @('install.wim','install.esd') |
        ForEach-Object { Join-Path $sources $_ } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if (-not $image) {
        Write-Err 'No sources\install.wim or sources\install.esd was found on the ISO.'
        Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
        return $null
    }
    Write-Info ('Found {0}' -f $image)

    # --- pick an edition/index -------------------------------------------
    try {
        $images = @(Get-WindowsImage -ImagePath $image -ErrorAction Stop)
    }
    catch {
        Write-Err ("Could not read the image: {0}" -f $_.Exception.Message)
        Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
        return $null
    }

    Write-Host ''
    Write-Host '   Editions in the image:' -ForegroundColor White
    for ($i = 0; $i -lt $images.Count; $i++) {
        $im = $images[$i]
        Write-Host ('   [{0}] Index {1} - {2}' -f ($i + 1), $im.ImageIndex, $im.ImageName) -ForegroundColor Gray
        if ($im.ImageDescription -and $im.ImageDescription -ne $im.ImageName) {
            Write-Host ('       {0}' -f $im.ImageDescription) -ForegroundColor DarkGray
        }
    }
    Write-Host '   [0] Cancel' -ForegroundColor Gray

    $valid = @('0') + (1..$images.Count | ForEach-Object { "$_" })
    $pick  = Read-Choice -Valid $valid -Prompt 'Select the edition to service'
    if ($pick -eq '0') {
        Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
        return $null
    }
    $chosen = $images[[int]$pick - 1]
    $index  = [int]$chosen.ImageIndex

    # --- read/write needs a WIM; ESD must be exported first ---------------
    $readOnly = $false
    $workImage = $image

    if ([IO.Path]::GetExtension($image) -ieq '.esd') {
        Write-Host ''
        Write-Warn 'install.esd is compressed read-only and cannot be serviced directly.'
        Write-Host '   [1] Export this edition to a .wim first (needed to repair / add drivers or updates)' -ForegroundColor Gray
        Write-Host '   [2] Mount read-only (reports and analysis only)' -ForegroundColor Gray
        Write-Host '   [0] Cancel' -ForegroundColor Gray
        $esdPick = Read-Choice -Valid @('0','1','2') -Prompt 'Select an option'
        switch ($esdPick) {
            '0' { Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null; return $null }
            '2' { $readOnly = $true }
            '1' {
                $dest = Join-Path $Script:ExportRoot ('install_{0:yyyyMMdd_HHmmss}.wim' -f (Get-Date))
                Write-Info ('Exporting index {0} to {1}' -f $index, $dest)
                Write-Info 'This can take 10-30 minutes and needs several GB of free space.'
                try {
                    Export-WindowsImage -SourceImagePath $image -SourceIndex $index `
                                        -DestinationImagePath $dest -CompressionType Max `
                                        -ErrorAction Stop | Out-Null
                }
                catch {
                    Write-Err ("Export failed: {0}" -f $_.Exception.Message)
                    Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
                    return $null
                }
                Write-Ok 'Export complete.'
                $workImage = $dest
                $index     = 1
            }
        }
    }

    # --- mount the image --------------------------------------------------
    $mountDir = Join-Path $Script:MountRoot ('img_{0:yyyyMMdd_HHmmss}' -f (Get-Date))
    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

    Write-Info ('Mounting index {0} to {1}{2}' -f $index, $mountDir, $(if ($readOnly) { ' (read-only)' } else { '' }))
    try {
        if ($readOnly) {
            Mount-WindowsImage -ImagePath $workImage -Index $index -Path $mountDir -ReadOnly -ErrorAction Stop | Out-Null
        }
        else {
            Mount-WindowsImage -ImagePath $workImage -Index $index -Path $mountDir -ErrorAction Stop | Out-Null
        }
    }
    catch {
        Write-Err ("Mount failed: {0}" -f $_.Exception.Message)
        Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
        Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
        return $null
    }
    Write-Ok 'Image mounted.'

    $label = ('ISO - {0} [index {1}{2}]' -f (Split-Path $iso -Leaf), $index,
              $(if ($readOnly) { ', read-only' } else { '' }))

    return New-Target -Kind 'Image' -Label $label `
                      -ImagePath $mountDir `
                      -WindowsDir (Join-Path $mountDir 'Windows') `
                      -BootDir ($mountDir.TrimEnd('\') + '\') `
                      -IsoPath $iso -IsoDrive $isoDrive `
                      -WimPath $workImage -Index $index `
                      -Mounted $true -ReadOnly $readOnly
}

function Close-Target {
    <#  Unmounts anything the target opened. #>
    param([object]$TargetToClose = $Script:Target)

    if (-not $TargetToClose) { return }
    if ($TargetToClose.Kind -ne 'Image') { return }

    if ($TargetToClose.Mounted -and $TargetToClose.MountDir -and (Test-Path -LiteralPath $TargetToClose.MountDir)) {
        $save = $false
        if (-not $TargetToClose.ReadOnly) {
            $save = Confirm-YesNo 'Save (commit) the changes made to the mounted image?' $true
        }
        Write-Step ('Unmounting {0} ({1})' -f $TargetToClose.MountDir, $(if ($save) { 'commit' } else { 'discard' }))
        try {
            if ($save) { Dismount-WindowsImage -Path $TargetToClose.MountDir -Save -ErrorAction Stop | Out-Null }
            else       { Dismount-WindowsImage -Path $TargetToClose.MountDir -Discard -ErrorAction Stop | Out-Null }
            Write-Ok 'Image unmounted.'
        }
        catch {
            Write-Err ("Unmount failed: {0}" -f $_.Exception.Message)
            Write-Warn 'Run "dism /Cleanup-Mountpoints" once no process is using the mount folder.'
        }
        Remove-Item -LiteralPath $TargetToClose.MountDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($TargetToClose.IsoPath) {
        Write-Info ('Dismounting ISO {0}' -f $TargetToClose.IsoPath)
        Dismount-DiskImage -ImagePath $TargetToClose.IsoPath -ErrorAction SilentlyContinue | Out-Null
    }
}

function Select-Target {
    param([switch]$AllowCancel)

    while ($true) {
        Write-Banner "$Script:AppName - select the component store"
        Write-Host '   Which component store do you want to manage?' -ForegroundColor White
        Write-Host ''
        Write-Host '   [1] The active (running) Windows installation' -ForegroundColor Gray
        Write-Host '   [2] An offline Windows installation on another drive letter' -ForegroundColor Gray
        Write-Host '   [3] A Windows installation ISO (install.wim / install.esd)' -ForegroundColor Gray
        if ($AllowCancel) { Write-Host '   [0] Keep the current target' -ForegroundColor Gray }
        else              { Write-Host '   [0] Exit' -ForegroundColor Gray }

        $pick = Read-Choice -Valid @('0','1','2','3')
        switch ($pick) {
            '0' { return $null }
            '1' { $t = Select-OnlineTarget }
            '2' { $t = Select-OfflineDriveTarget }
            '3' { $t = Select-IsoTarget }
        }
        if ($t) { return $t }
        Write-Warn 'No target was selected.'
    }
}

function Test-TargetWritable {
    <#  Blocks servicing actions on a read-only mount. #>
    if ($Script:Target.Kind -eq 'Image' -and $Script:Target.ReadOnly) {
        Write-Err 'The image is mounted read-only; this operation would change it.'
        Write-Info 'Re-select the ISO and choose the export-to-WIM option to service it.'
        return $false
    }
    return $true
}

#endregion

#region -------------------------------------------------------------- Health

function Get-HealthState {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($Text -match 'No component store corruption detected')  { return 'Healthy' }
    if ($Text -match 'The component store corruption was repaired') { return 'Repaired' }
    if ($Text -match 'The component store is repairable')        { return 'Repairable' }
    if ($Text -match 'store corruption.*(cannot|could not) be repaired|is not repairable') { return 'Unrepairable' }
    if ($Text -match 'The restore operation completed successfully') { return 'Repaired' }
    return 'Unknown'
}

function Show-HealthStatus {
    param([Parameter(Mandatory)][string]$State, [string]$Source = 'CheckHealth')

    Write-Host ''
    switch ($State) {
        'Healthy' {
            Write-Host ('   COMPONENT STORE HEALTH : HEALTHY  ({0})' -f $Source) -ForegroundColor Green
            Write-Host '   No component store corruption is flagged.' -ForegroundColor Green
        }
        'Repaired' {
            Write-Host ('   COMPONENT STORE HEALTH : REPAIRED  ({0})' -f $Source) -ForegroundColor Green
            Write-Host '   Corruption was found and has been repaired.' -ForegroundColor Green
        }
        'Repairable' {
            Write-Host ('   COMPONENT STORE HEALTH : CORRUPT - REPAIRABLE  ({0})' -f $Source) -ForegroundColor Yellow
            Write-Host '   Corruption was detected and DISM reports it can be repaired.' -ForegroundColor Yellow
        }
        'Unrepairable' {
            Write-Host ('   COMPONENT STORE HEALTH : CORRUPT - NOT REPAIRABLE  ({0})' -f $Source) -ForegroundColor Red
            Write-Host '   DISM cannot repair this store from its current sources.' -ForegroundColor Red
            Write-Host '   A known-good source (install.wim / install.esd) is required.' -ForegroundColor Red
        }
        default {
            Write-Host ('   COMPONENT STORE HEALTH : UNKNOWN  ({0})' -f $Source) -ForegroundColor Yellow
            Write-Host '   The health state could not be determined from the DISM output.' -ForegroundColor Yellow
        }
    }
}

function Invoke-CheckHealth {
    param([switch]$Quiet)
    $started = Get-Date
    Write-Step 'Checking component store health (CheckHealth)'
    $r = Invoke-Dism -Arguments @('/Cleanup-Image','/CheckHealth') -Quiet:$Quiet
    $state = Get-HealthState -Text $r.Text
    $Script:LastHealth = [pscustomobject]@{
        State  = $state
        Source = 'CheckHealth'
        When   = Get-Date
        Text   = $r.Text
    }

    Add-SessionAction -Category 'Health' -Action 'CheckHealth' -Started $started -ExitCode $r.ExitCode `
        -Status (Get-HealthActionStatus -State $state) -Result $state | Out-Null
    return $Script:LastHealth
}

function Invoke-ScanHealth {
    $started = Get-Date
    Write-Step 'Scanning the component store for corruption (ScanHealth)'
    Write-Info 'This performs a full scan and normally takes 5-20 minutes.'
    $r = Invoke-Dism -Arguments @('/Cleanup-Image','/ScanHealth')
    $state = Get-HealthState -Text $r.Text
    $Script:LastHealth = [pscustomobject]@{
        State  = $state
        Source = 'ScanHealth'
        When   = Get-Date
        Text   = $r.Text
    }

    Add-SessionAction -Category 'Health' -Action 'ScanHealth' -Started $started -ExitCode $r.ExitCode `
        -Status (Get-HealthActionStatus -State $state) -Result $state | Out-Null
    return $Script:LastHealth
}

function Get-HealthActionStatus {
    <#  Maps a DISM health verdict onto a session-report status. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$State)
    switch ($State) {
        'Healthy'      { 'Ok' }
        'Repaired'     { 'Ok' }
        'Repairable'   { 'Warning' }
        'Unrepairable' { 'Failed' }
        default        { 'Warning' }
    }
}

function Select-RepairSource {
    <#
        Returns @{ SourceArgs = @(...); Description = '...' } or $null if the
        user cancels. An empty SourceArgs means "let DISM use Windows Update".
    #>
    Write-Host ''
    Write-Host '   Repair source:' -ForegroundColor White
    Write-Host '   [1] Let DISM choose (Windows Update / configured sources)' -ForegroundColor Gray
    Write-Host '   [2] A folder, e.g. an extracted \sources\sxs or a mounted image \Windows' -ForegroundColor Gray
    Write-Host '   [3] A Windows installation ISO (mounted for the repair)' -ForegroundColor Gray
    Write-Host '   [4] An install.wim / install.esd file already on disk' -ForegroundColor Gray
    Write-Host '   [0] Cancel' -ForegroundColor Gray

    $pick = Read-Choice -Valid @('0','1','2','3','4') -Prompt 'Select a repair source'

    switch ($pick) {
        '0' { return $null }

        '1' {
            if ($Script:Target.Kind -ne 'Online') {
                Write-Warn 'Offline images cannot reach Windows Update; a source is strongly recommended.'
            }
            return [pscustomobject]@{ SourceArgs = @(); Description = 'DISM default (Windows Update)'; Temp = $null }
        }

        '2' {
            $folder = Read-ExistingPath -Prompt 'Path to the source folder' -Type 'Container'
            if (-not $folder) { return $null }
            $limit = Confirm-YesNo 'Prevent DISM from contacting Windows Update (/LimitAccess)?' $true
            $a = @(('/Source:{0}' -f $folder))
            if ($limit) { $a += '/LimitAccess' }
            return [pscustomobject]@{ SourceArgs = $a; Description = $folder; Temp = $null }
        }

        '3' {
            $iso = Read-ExistingPath -Prompt 'Path to the Windows installation ISO' -Type 'Leaf'
            if (-not $iso) { return $null }
            try {
                $di = Mount-DiskImage -ImagePath $iso -PassThru -ErrorAction Stop
                Start-Sleep -Milliseconds 700
                $letter = ($di | Get-Volume | Where-Object DriveLetter).DriveLetter
            }
            catch {
                Write-Err ("Could not mount the ISO: {0}" -f $_.Exception.Message)
                return $null
            }
            $img = @('install.wim','install.esd') |
                   ForEach-Object { Join-Path ('{0}:\sources' -f $letter) $_ } |
                   Where-Object { Test-Path -LiteralPath $_ } |
                   Select-Object -First 1
            if (-not $img) {
                Write-Err 'No install.wim / install.esd on that ISO.'
                Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
                return $null
            }
            $src = New-SourceStringFromImage -ImagePath $img
            if (-not $src) {
                Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null
                return $null
            }
            return [pscustomobject]@{
                SourceArgs  = @(('/Source:{0}' -f $src), '/LimitAccess')
                Description = $src
                Temp        = $iso
            }
        }

        '4' {
            $img = Read-ExistingPath -Prompt 'Path to install.wim or install.esd' -Type 'Leaf'
            if (-not $img) { return $null }
            $src = New-SourceStringFromImage -ImagePath $img
            if (-not $src) { return $null }
            return [pscustomobject]@{
                SourceArgs  = @(('/Source:{0}' -f $src), '/LimitAccess')
                Description = $src
                Temp        = $null
            }
        }
    }
}

function New-SourceStringFromImage {
    <#  Builds wim:<path>:<index> / esd:<path>:<index> after asking for an index. #>
    param([Parameter(Mandatory)][string]$ImagePath)

    try { $images = @(Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop) }
    catch {
        Write-Err ("Could not read {0}: {1}" -f $ImagePath, $_.Exception.Message)
        return $null
    }
    if ($images.Count -eq 0) { Write-Err 'The image contains no indexes.'; return $null }

    Write-Host ''
    Write-Host '   Editions available as a repair source:' -ForegroundColor White
    for ($i = 0; $i -lt $images.Count; $i++) {
        Write-Host ('   [{0}] Index {1} - {2}' -f ($i + 1), $images[$i].ImageIndex, $images[$i].ImageName) -ForegroundColor Gray
    }
    Write-Host '   [0] Cancel' -ForegroundColor Gray

    $valid = @('0') + (1..$images.Count | ForEach-Object { "$_" })
    $pick  = Read-Choice -Valid $valid -Prompt 'Select the edition to repair from'
    if ($pick -eq '0') { return $null }

    $index  = $images[[int]$pick - 1].ImageIndex
    $prefix = if ([IO.Path]::GetExtension($ImagePath) -ieq '.esd') { 'esd' } else { 'wim' }
    return ('{0}:{1}:{2}' -f $prefix, $ImagePath, $index)
}

function Invoke-RestoreHealth {
    <#  Repairs the store, then verifies health and runs the system file scan. #>
    if (-not (Test-TargetWritable)) { return }

    $source = Select-RepairSource
    if ($null -eq $source) { Write-Info 'Repair cancelled.'; return }

    $stateBefore = if ($Script:LastHealth) { [string]$Script:LastHealth.State } else { 'not assessed' }
    $started     = Get-Date

    try {
        Write-Step 'Repairing the component store (RestoreHealth)'
        Write-Info ('Source: {0}' -f $source.Description)
        Write-Info 'This can take 10-40 minutes. Do not close this window.'

        $dismArgs = @('/Cleanup-Image','/RestoreHealth') + $source.SourceArgs
        $r = Invoke-Dism -Arguments $dismArgs

        $succeeded = ($r.ExitCode -eq 0) -or ($r.Text -match 'The restore operation completed successfully')

        if (-not $succeeded) {
            Write-Err ('RestoreHealth failed (exit code {0}).' -f $r.ExitCode)
            if ($r.Text -match '0x800f081f') {
                Write-Warn 'Error 0x800F081F: the source files could not be found.'
                Write-Info 'Retry with an install.wim / install.esd that matches this build exactly.'
            }
            Write-Info ('Details: {0}\Logs\DISM\dism.log' -f $Script:Target.WindowsDir)

            Add-SessionAction -Category 'Health' -Action 'RestoreHealth' -Status 'Failed' `
                -Result ('dism exit {0}' -f $r.ExitCode) -Started $started -ExitCode $r.ExitCode `
                -Detail ('before: {0}; source: {1}' -f $stateBefore, $source.Description) | Out-Null

            if (Confirm-YesNo 'Try again with a different repair source?' $false) {
                Invoke-RestoreHealth
            }
            return
        }

        Write-Ok 'The restore operation completed successfully.'
        Add-SessionAction -Category 'Health' -Action 'RestoreHealth' -Status 'Ok' `
            -Result ('repaired (was {0})' -f $stateBefore) -Started $started -ExitCode $r.ExitCode `
            -Detail ('source: {0}' -f $source.Description) | Out-Null
    }
    finally {
        if ($source -and $source.Temp) {
            Dismount-DiskImage -ImagePath $source.Temp -ErrorAction SilentlyContinue | Out-Null
        }
    }

    # --- confirm the store is healthy again -------------------------------
    $health = Invoke-CheckHealth
    Show-HealthStatus -State $health.State -Source 'CheckHealth (post-repair)'

    if ($health.State -in @('Repairable','Unrepairable')) {
        Write-Warn 'The store still reports corruption; system file repair would likely fail.'
        if (-not (Confirm-YesNo 'Scan for missing or corrupted system files anyway?' $false)) { return }
    }
    else {
        Write-Host ''
        Write-Info 'Component store health has been restored.'
        Write-Info 'Now scanning for missing or corrupted system files.'
    }

    Invoke-SystemFileScan
}

function Invoke-SystemFileScan {
    <#
        Verifies protected system files and, if violations are found, offers
        to repair them.
    #>
    Write-Step 'Scanning for missing or corrupted system files (SFC verify)'

    if ($Script:Target.Kind -eq 'Image' -and $Script:Target.ReadOnly) {
        Write-Warn 'The image is mounted read-only; SFC can verify but not repair.'
    }

    $verify = Invoke-Sfc -VerifyOnly

    switch ($verify.State) {
        'Clean' {
            Write-Host ''
            Write-Ok 'No missing or corrupted system files were found.'
            return
        }
        'Failed' {
            Write-Host ''
            Write-Err 'SFC could not complete the verification.'
            if ($Script:Target.Kind -ne 'Online') {
                Write-Info 'Offline scans require /offbootdir and /offwindir to point at a real installation.'
            }
            Write-Info ('Details: {0}\Logs\CBS\CBS.log' -f $Script:Target.WindowsDir)
            return
        }
        'Unknown' {
            Write-Host ''
            Write-Warn 'The SFC result could not be interpreted; review the output above.'
            if (-not (Confirm-YesNo 'Run a repairing scan (sfc /scannow) anyway?' $false)) { return }
        }
        default {
            Write-Host ''
            Write-Warn 'Missing or corrupted system files were found.'
        }
    }

    if ($Script:Target.Kind -eq 'Image' -and $Script:Target.ReadOnly) {
        Write-Err 'Cannot repair: the image is mounted read-only.'
        return
    }

    if (-not (Confirm-YesNo 'Would you like to fix the missing and/or corrupted system files now?' $true)) {
        Write-Info 'System files were left unchanged.'
        return
    }

    Write-Step 'Repairing system files (SFC scan and repair)'
    $fix = Invoke-Sfc

    Write-Host ''
    switch ($fix.State) {
        'Repaired'   { Write-Ok 'Corrupt files were found and successfully repaired.'
                       if ($Script:Target.Kind -eq 'Online') { Write-Info 'A restart is recommended.' } }
        'Clean'      { Write-Ok 'No integrity violations remained.' }
        'Unfixable'  { Write-Err 'Some corrupt files could not be repaired.'
                       Write-Info ('Review {0}\Logs\CBS\CBS.log, then repair the component store and retry.' -f $Script:Target.WindowsDir) }
        'Failed'     { Write-Err 'The repair scan could not be completed.' }
        default      { Write-Warn 'The repair result could not be interpreted; review the output above.' }
    }
}

function Show-HealthMenu {
    # The health state is shown as soon as the menu is opened.
    $health = Invoke-CheckHealth
    Show-HealthStatus -State $health.State -Source 'CheckHealth'

    while ($true) {
        Write-Banner 'Manage component store health'
        Write-TargetLine
        if ($Script:LastHealth) {
            Show-HealthStatus -State $Script:LastHealth.State -Source ('{0}, {1:HH:mm:ss}' -f $Script:LastHealth.Source, $Script:LastHealth.When)
        }

        Write-Host ''
        Write-Host '   [1] Scan the component store for corruption (ScanHealth)' -ForegroundColor Gray
        Write-Host '   [2] Repair a corrupted component store (RestoreHealth)' -ForegroundColor Gray
        Write-Host '   [3] Scan for missing or corrupted system files (SFC)' -ForegroundColor Gray
        Write-Host '   [4] Re-check health now (CheckHealth)' -ForegroundColor Gray
        Write-Host '   [0] Back to the main menu' -ForegroundColor Gray

        switch (Read-Choice -Valid @('0','1','2','3','4')) {

            '0' { return }

            '1' {
                $scan = Invoke-ScanHealth
                Show-HealthStatus -State $scan.State -Source 'ScanHealth'

                switch ($scan.State) {
                    'Healthy' {
                        # No corruption - still offer the system file scan.
                        if (Confirm-YesNo 'No corruption was found. Scan for missing or corrupted system files anyway?' $true) {
                            Invoke-SystemFileScan
                        }
                    }
                    'Repaired' {
                        if (Confirm-YesNo 'Scan for missing or corrupted system files as well?' $true) {
                            Invoke-SystemFileScan
                        }
                    }
                    'Repairable' {
                        if (Confirm-YesNo 'Corruption was detected and is repairable. Would you like to repair the component store now?' $true) {
                            Invoke-RestoreHealth
                        }
                    }
                    'Unrepairable' {
                        Write-Warn 'DISM reports the corruption is not repairable from its current sources.'
                        if (Confirm-YesNo 'Attempt a repair using a known-good source (install.wim / install.esd)?' $true) {
                            Invoke-RestoreHealth
                        }
                    }
                    default {
                        if (Confirm-YesNo 'The scan result was inconclusive. Attempt a repair?' $false) {
                            Invoke-RestoreHealth
                        }
                    }
                }
                Wait-Key
            }

            '2' { Invoke-RestoreHealth;   Wait-Key }
            '3' { Invoke-SystemFileScan;  Wait-Key }
            '4' {
                $h = Invoke-CheckHealth
                Show-HealthStatus -State $h.State -Source 'CheckHealth'
                Wait-Key
            }
        }
    }
}

#endregion

#region ------------------------------------------------------------- Drivers

function Get-TargetDrivers {
    <#  Third-party drivers staged in the target component/driver store. #>
    param([switch]$IncludeInbox)
    try {
        if ($Script:Target.Kind -eq 'Online') {
            $d = if ($IncludeInbox) { Get-WindowsDriver -Online -All -ErrorAction Stop }
                 else               { Get-WindowsDriver -Online -ErrorAction Stop }
        }
        else {
            $d = if ($IncludeInbox) { Get-WindowsDriver -Path $Script:Target.ImagePath -All -ErrorAction Stop }
                 else               { Get-WindowsDriver -Path $Script:Target.ImagePath -ErrorAction Stop }
        }
        return @($d | Sort-Object ClassName, ProviderName, Driver)
    }
    catch {
        Write-Err ("Could not enumerate drivers: {0}" -f $_.Exception.Message)
        return @()
    }
}

function Show-DriverTable {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Drivers,
        [switch]$Numbered
    )
    if ($Drivers.Count -eq 0) {
        Write-Info 'No third-party drivers are present in this component store.'
        return
    }

    Write-Host ''
    $header = if ($Numbered) { '{0,4}  {1,-12} {2,-16} {3,-26} {4,-13} {5}' -f '#','Published','Class','Provider','Version','Original name' }
              else           { '      {0,-12} {1,-16} {2,-26} {3,-13} {4}'  -f 'Published','Class','Provider','Version','Original name' }
    Write-Host ('   ' + $header) -ForegroundColor White
    Write-Host ('   ' + ('-' * 104)) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Drivers.Count; $i++) {
        $d    = $Drivers[$i]
        $date = if ($d.Date) { ([datetime]$d.Date).ToString('yyyy-MM-dd') } else { '' }
        $orig = if ($d.OriginalFileName) { Split-Path $d.OriginalFileName -Leaf } else { '' }
        $row  = '{0,-12} {1,-16} {2,-26} {3,-13} {4}' -f
                    $d.Driver,
                    (($d.ClassName    -as [string]) -replace '(.{0,15}).*','$1'),
                    (($d.ProviderName -as [string]) -replace '(.{0,25}).*','$1'),
                    (($d.Version      -as [string]) -replace '(.{0,12}).*','$1'),
                    "$orig  ($date)"
        if ($Numbered) { Write-Host ('   {0,4}  {1}' -f ($i + 1), $row) -ForegroundColor Gray }
        else           { Write-Host ('         {0}' -f $row) -ForegroundColor Gray }
    }
    Write-Host ''
    Write-Info ('{0} third-party driver package(s).' -f $Drivers.Count)
}

function Invoke-ListDrivers {
    Write-Step 'Third-party drivers in the component store'
    $drivers = Get-TargetDrivers
    Show-DriverTable -Drivers $drivers
}

function Invoke-AddDriver {
    if (-not (Test-TargetWritable)) { return }

    Write-Step 'Install a third-party driver into the component store'
    Write-Host ''
    Write-Host '   [1] A single .inf file' -ForegroundColor Gray
    Write-Host '   [2] A folder of drivers' -ForegroundColor Gray
    Write-Host '   [0] Cancel' -ForegroundColor Gray

    $pick = Read-Choice -Valid @('0','1','2')
    if ($pick -eq '0') { return }

    $recurse = $false
    if ($pick -eq '1') {
        $path = Read-ExistingPath -Prompt 'Path to the .inf file' -Type 'Leaf'
        if ($path -and ([IO.Path]::GetExtension($path) -ne '.inf')) {
            Write-Warn 'That file is not an .inf.'
            if (-not (Confirm-YesNo 'Continue anyway?' $false)) { return }
        }
    }
    else {
        $path = Read-ExistingPath -Prompt 'Path to the driver folder' -Type 'Container'
        if ($path) {
            $recurse = Confirm-YesNo 'Include sub-folders?' $true
            $count = @(Get-ChildItem -LiteralPath $path -Filter '*.inf' -File -Recurse:$recurse -ErrorAction SilentlyContinue).Count
            Write-Info ('{0} .inf file(s) found.' -f $count)
            if ($count -eq 0) { return }
        }
    }
    if (-not $path) { return }

    $unsigned = Confirm-YesNo 'Allow unsigned drivers (ForceUnsigned)?' $false

    if ($Script:Target.Kind -eq 'Online') {
        $installNow = Confirm-YesNo 'Also install the driver on matching devices now (not just stage it)?' $true
        $pnpArgs = @('/add-driver', $path)
        if ($recurse)    { $pnpArgs += '/subdirs' }
        if ($installNow) { $pnpArgs += '/install' }

        Write-Info ('pnputil.exe {0}' -f ($pnpArgs -join ' '))
        & pnputil.exe @pnpArgs 2>&1 | ForEach-Object {
            Write-Host ('   {0}' -f $_) -ForegroundColor Gray; Write-Log ([string]$_) 'RAW'
        }
        if ($LASTEXITCODE -in @(0, 3010)) {
            Write-Ok 'Driver added to the driver store.'
            if ($LASTEXITCODE -eq 3010) { Write-Info 'A restart is required to complete the installation.' }
        }
        else { Write-Err ('pnputil returned exit code {0}.' -f $LASTEXITCODE) }
    }
    else {
        try {
            Add-WindowsDriver -Path $Script:Target.ImagePath -Driver $path `
                              -Recurse:$recurse -ForceUnsigned:$unsigned -ErrorAction Stop | Out-Null
            Write-Ok 'Driver(s) added to the offline component store.'
        }
        catch { Write-Err ("Add-WindowsDriver failed: {0}" -f $_.Exception.Message) }
    }
}

function Invoke-RemoveDriver {
    if (-not (Test-TargetWritable)) { return }

    Write-Step 'Uninstall third-party drivers from the component store'
    $drivers = Get-TargetDrivers
    if ($drivers.Count -eq 0) { Show-DriverTable -Drivers $drivers; return }

    Show-DriverTable -Drivers $drivers -Numbered
    Write-Host ''
    $spec = Read-Host 'Numbers to remove (e.g. 1,3,5-7 or "all", blank to cancel)'
    $picks = Expand-Selection -Spec $spec -Max $drivers.Count
    if ($picks.Count -eq 0) { Write-Info 'Nothing selected.'; return }

    Write-Host ''
    Write-Warn ('{0} driver package(s) will be removed:' -f $picks.Count)
    foreach ($n in $picks) {
        $d = $drivers[$n - 1]
        Write-Host ('     {0}  {1}  {2}' -f $d.Driver, $d.ClassName, $d.ProviderName) -ForegroundColor Yellow
    }
    if (-not (Confirm-YesNo 'Remove these driver packages?' $false)) { Write-Info 'Cancelled.'; return }

    $forceOnline = $false
    if ($Script:Target.Kind -eq 'Online') {
        $forceOnline = Confirm-YesNo 'Force removal even if a device is currently using the driver?' $false
    }

    $ok = 0; $bad = 0
    foreach ($n in $picks) {
        $d = $drivers[$n - 1]
        Write-Info ('Removing {0} ...' -f $d.Driver)
        if ($Script:Target.Kind -eq 'Online') {
            $pnpArgs = @('/delete-driver', $d.Driver, '/uninstall')
            if ($forceOnline) { $pnpArgs += '/force' }
            & pnputil.exe @pnpArgs 2>&1 | ForEach-Object { Write-Log ([string]$_) 'RAW' }
            if ($LASTEXITCODE -in @(0, 3010)) { $ok++; Write-Ok ('{0} removed.' -f $d.Driver) }
            else { $bad++; Write-Err ('{0} could not be removed (exit {1}).' -f $d.Driver, $LASTEXITCODE) }
        }
        else {
            try {
                Remove-WindowsDriver -Path $Script:Target.ImagePath -Driver $d.Driver -ErrorAction Stop | Out-Null
                $ok++; Write-Ok ('{0} removed.' -f $d.Driver)
            }
            catch { $bad++; Write-Err ("{0}: {1}" -f $d.Driver, $_.Exception.Message) }
        }
    }
    Write-Host ''
    Write-Info ('Removed {0}, failed {1}.' -f $ok, $bad)
}

function Invoke-AddActiveDriverStore {
    <#
        Exports the running machine's third-party driver store and injects it
        into the selected component store.
    #>
    Write-Step "Add the active system's driver store to the component store"

    $dest = Join-Path $Script:ExportRoot ('DriverStore_{0:yyyyMMdd_HHmmss}' -f (Get-Date))
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    Write-Info ('Exporting the active driver store to {0}' -f $dest)
    Write-Info 'This copies every third-party driver package and can take a few minutes.'

    $exported = $false
    & pnputil.exe /export-driver '*' $dest 2>&1 | ForEach-Object {
        Write-Log ([string]$_) 'RAW'
    }
    if ($LASTEXITCODE -eq 0) { $exported = $true }
    else {
        Write-Warn 'pnputil export failed; falling back to DISM /Export-Driver.'
        & dism.exe /English /Online /Export-Driver ('/Destination:{0}' -f $dest) 2>&1 | ForEach-Object {
            Write-Log ([string]$_) 'RAW'
        }
        if ($LASTEXITCODE -eq 0) { $exported = $true }
    }

    $infs = @(Get-ChildItem -LiteralPath $dest -Filter '*.inf' -File -Recurse -ErrorAction SilentlyContinue)
    if (-not $exported -or $infs.Count -eq 0) {
        Write-Err 'No drivers were exported from the active system.'
        return
    }
    Write-Ok ('{0} driver package(s) exported.' -f $infs.Count)

    if ($Script:Target.Kind -eq 'Online') {
        Write-Info 'The target IS the active system, so these drivers are already in its store.'
        Write-Info ('The export has been kept as a backup at {0}' -f $dest)
        return
    }

    if (-not (Test-TargetWritable)) {
        Write-Info ('The export has been kept at {0}' -f $dest)
        return
    }

    if (-not (Confirm-YesNo ('Inject all {0} exported driver package(s) into {1}?' -f $infs.Count, $Script:Target.Label) $true)) {
        Write-Info ('The export has been kept at {0}' -f $dest)
        return
    }

    $unsigned = Confirm-YesNo 'Allow unsigned drivers (ForceUnsigned)?' $true
    Write-Info 'Injecting drivers, this can take several minutes...'
    try {
        Add-WindowsDriver -Path $Script:Target.ImagePath -Driver $dest -Recurse `
                          -ForceUnsigned:$unsigned -ErrorAction Stop | Out-Null
        Write-Ok 'The active driver store was added to the target component store.'
    }
    catch {
        Write-Err ("Injection failed: {0}" -f $_.Exception.Message)
        Write-Info ('The exported drivers remain at {0}' -f $dest)
    }
}

function Invoke-DriverReport {
    Write-Step 'Create a component store driver report'

    $includeInbox = Confirm-YesNo 'Include in-box (Microsoft) drivers as well as third-party ones?' $false
    Write-Info 'Collecting drivers...'
    $drivers = Get-TargetDrivers -IncludeInbox:$includeInbox
    if ($drivers.Count -eq 0) { Write-Warn 'No drivers were returned; nothing to report.'; return }

    $rows = $drivers | Select-Object `
        @{n='Driver';        e={$_.Driver}},
        @{n='OriginalName';  e={ if ($_.OriginalFileName) { Split-Path $_.OriginalFileName -Leaf } else { '' } }},
        @{n='Provider';      e={$_.ProviderName}},
        @{n='Class';         e={$_.ClassName}},
        @{n='Version';       e={$_.Version}},
        @{n='Date';          e={ if ($_.Date) { ([datetime]$_.Date).ToString('yyyy-MM-dd') } else { '' } }},
        @{n='BootCritical';  e={$_.BootCritical}},
        @{n='Inbox';         e={$_.Inbox}},
        @{n='Signer';        e={$_.DriverSignature}}

    $summary = [ordered]@{
        'Target'              = $Script:Target.Label
        'Windows directory'   = $Script:Target.WindowsDir
        'Driver packages'     = $drivers.Count
        'Boot critical'       = @($drivers | Where-Object BootCritical).Count
        'Distinct classes'    = @($drivers | Select-Object -ExpandProperty ClassName -Unique).Count
        'Distinct providers'  = @($drivers | Select-Object -ExpandProperty ProviderName -Unique).Count
        'Generated'           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    Export-Report -Name 'Drivers' -Title 'Component Store - Driver Report' -Summary $summary -Rows $rows
}

function Show-DriversMenu {
    while ($true) {
        Write-Banner 'Manage component store drivers'
        Write-TargetLine
        Write-Host ''
        Write-Host '   [1] List third-party drivers in the component store' -ForegroundColor Gray
        Write-Host '   [2] Install a third-party driver into the component store' -ForegroundColor Gray
        Write-Host '   [3] Uninstall third-party drivers from the component store' -ForegroundColor Gray
        Write-Host "   [4] Add the active system's driver store to the component store" -ForegroundColor Gray
        Write-Host '   [5] Create a report of the component store drivers' -ForegroundColor Gray
        Write-Host '   [0] Back to the main menu' -ForegroundColor Gray

        switch (Read-Choice -Valid @('0','1','2','3','4','5')) {
            '0' { return }
            '1' { Invoke-ListDrivers;           Wait-Key }
            '2' { Invoke-AddDriver;             Wait-Key }
            '3' { Invoke-RemoveDriver;          Wait-Key }
            '4' { Invoke-AddActiveDriverStore;  Wait-Key }
            '5' { Invoke-DriverReport;          Wait-Key }
        }
    }
}

#endregion

#region ------------------------------------------------------------- Updates

function Get-TargetPackages {
    <#  Packages in the target store; update-type packages unless -All. #>
    param([switch]$All)
    try {
        $pkgs = if ($Script:Target.Kind -eq 'Online') {
                    Get-WindowsPackage -Online -ErrorAction Stop
                } else {
                    Get-WindowsPackage -Path $Script:Target.ImagePath -ErrorAction Stop
                }
        $pkgs = @($pkgs)
        if (-not $All) {
            $pkgs = @($pkgs | Where-Object {
                ($_.ReleaseType -match 'Update|Hotfix|Security') -or
                ($_.PackageName -match 'KB\d{6,}')
            })
        }
        return @($pkgs | Sort-Object InstallTime -Descending)
    }
    catch {
        Write-Err ("Could not enumerate packages: {0}" -f $_.Exception.Message)
        return @()
    }
}

function Get-PackageKb {
    <#
        Returns the KB number when the package name carries one. Cumulative,
        servicing-stack and .NET rollup packages do not, so the trailing
        component version is returned instead.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PackageName)
    if ($PackageName -match '(KB\d{6,})') { return $Matches[1] }
    if ($PackageName -match '~~([\d\.]+)\s*$') { return $Matches[1] }
    return ''
}

function Show-PackageTable {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packages,
        [switch]$Numbered
    )
    if ($Packages.Count -eq 0) {
        Write-Info 'No matching packages were found in this component store.'
        return
    }

    Write-Host ''
    Write-Host ('   {0}{1,-15} {2,-11} {3,-18} {4}' -f
        $(if ($Numbered) { '   # ' } else { '' }), 'KB / version', 'State', 'Installed', 'Package name') -ForegroundColor White
    Write-Host ('   ' + ('-' * 118)) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $p    = $Packages[$i]
        $kb   = Get-PackageKb -PackageName ([string]$p.PackageName)
        $when = if ($p.InstallTime) { ([datetime]$p.InstallTime).ToString('yyyy-MM-dd HH:mm') } else { '' }
        $row  = '{0,-15} {1,-11} {2,-18} {3}' -f $kb, $p.PackageState, $when, $p.PackageName
        if ($Numbered) { Write-Host ('   {0,4} {1}' -f ($i + 1), $row) -ForegroundColor Gray }
        else           { Write-Host ('   {0}' -f $row) -ForegroundColor Gray }
    }
    Write-Host ''
    Write-Info ('{0} package(s).' -f $Packages.Count)
}

function Invoke-ListUpdates {
    Write-Step 'Updates installed in the component store'
    $all = Confirm-YesNo 'Show every package (not just updates)?' $false
    $pkgs = Get-TargetPackages -All:$all
    Show-PackageTable -Packages $pkgs

    if ($Script:Target.Kind -eq 'Online') {
        try {
            $hf = @(Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 15)
            if ($hf.Count -gt 0) {
                Write-Host ''
                Write-Host '   Most recent hotfixes reported by Windows:' -ForegroundColor White
                foreach ($h in $hf) {
                    $when = if ($h.InstalledOn) { ([datetime]$h.InstalledOn).ToString('yyyy-MM-dd') } else { '' }
                    Write-Host ('     {0,-10} {1,-18} {2}' -f $h.HotFixID, $h.Description, $when) -ForegroundColor Gray
                }
            }
        }
        catch { }
    }
}

function Add-UpdateFiles {
    <#  Adds a list of .msu / .cab files to the target store. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [bool]$IgnoreCheck = $false,
        [bool]$PreventPending = $false
    )
    $started = Get-Date
    $ok = 0; $bad = 0
    $failedNames = New-Object System.Collections.Generic.List[string]

    foreach ($f in $Files) {
        Write-Info ('Adding {0} ...' -f $f.Name)
        try {
            if ($Script:Target.Kind -eq 'Online') {
                Add-WindowsPackage -Online -PackagePath $f.FullName -NoRestart `
                                   -IgnoreCheck:$IgnoreCheck -PreventPending:$PreventPending -ErrorAction Stop | Out-Null
            }
            else {
                Add-WindowsPackage -Path $Script:Target.ImagePath -PackagePath $f.FullName `
                                   -IgnoreCheck:$IgnoreCheck -PreventPending:$PreventPending -ErrorAction Stop | Out-Null
            }
            $ok++; Write-Ok ('{0} added.' -f $f.Name)
        }
        catch {
            $bad++
            $failedNames.Add($f.Name)
            $msg = $_.Exception.Message
            Write-Err ("{0}: {1}" -f $f.Name, $msg)
            if ($msg -match '0x800f081e') { Write-Info '  0x800F081E: the update does not apply to this image.' }
            if ($msg -match '0x80240017') { Write-Info '  0x80240017: the update is not applicable (wrong build or edition).' }
        }
    }
    Write-Host ''
    Write-Info ('Added {0}, failed {1}.' -f $ok, $bad)

    $status = if ($bad -eq 0 -and $ok -gt 0) { 'Ok' }
              elseif ($ok -gt 0)             { 'Warning' }
              else                           { 'Failed' }

    Add-SessionAction -Category 'Updates' -Action 'Applied update package(s)' -Status $status `
        -Result ('{0} added, {1} failed' -f $ok, $bad) -Started $started `
        -Detail $(if ($failedNames.Count -gt 0) { 'failed: ' + ($failedNames -join ', ') }
                  else { ($Files | ForEach-Object { $_.Name }) -join ', ' }) | Out-Null
}

function Invoke-AddUpdate {
    if (-not (Test-TargetWritable)) { return }

    Write-Step 'Add update packages to the component store'
    Write-Host ''
    Write-Host '   [1] A single .msu or .cab file' -ForegroundColor Gray
    Write-Host '   [2] Every .msu / .cab in a folder' -ForegroundColor Gray
    Write-Host '   [0] Cancel' -ForegroundColor Gray

    $pick = Read-Choice -Valid @('0','1','2')
    if ($pick -eq '0') { return }

    $files = @()
    if ($pick -eq '1') {
        $path = Read-ExistingPath -Prompt 'Path to the .msu or .cab file' -Type 'Leaf'
        if (-not $path) { return }
        if ([IO.Path]::GetExtension($path) -notmatch '^\.(msu|cab)$') {
            Write-Warn 'That file is not an .msu or .cab.'
            if (-not (Confirm-YesNo 'Continue anyway?' $false)) { return }
        }
        $files = @(Get-Item -LiteralPath $path)
    }
    else {
        $folder = Read-ExistingPath -Prompt 'Path to the folder of updates' -Type 'Container'
        if (-not $folder) { return }
        $recurse = Confirm-YesNo 'Include sub-folders?' $true
        $files = @(Get-ChildItem -LiteralPath $folder -File -Recurse:$recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -match '^\.(msu|cab)$' } |
                   Sort-Object Name)
        if ($files.Count -eq 0) { Write-Warn 'No .msu or .cab files were found.'; return }
        Write-Host ''
        foreach ($f in $files) { Write-Host ('     {0}  ({1})' -f $f.Name, (Format-Bytes $f.Length)) -ForegroundColor Gray }
        Write-Host ''
        if (-not (Confirm-YesNo ('Add these {0} package(s)?' -f $files.Count) $true)) { return }
    }

    $ignore  = Confirm-YesNo 'Skip the applicability check (IgnoreCheck)?' $false
    $prevent = $false
    if ($Script:Target.Kind -ne 'Online') {
        $prevent = Confirm-YesNo 'Refuse packages that would leave the image in a pending state (PreventPending)?' $true
    }

    Add-UpdateFiles -Files $files -IgnoreCheck $ignore -PreventPending $prevent

    if ($Script:Target.Kind -eq 'Online') {
        Write-Info 'A restart may be required to finish installing these updates.'
    }
}

function Invoke-RemoveUpdate {
    if (-not (Test-TargetWritable)) { return }

    Write-Step 'Remove update packages from the component store'
    $pkgs = Get-TargetPackages
    if ($pkgs.Count -eq 0) { Show-PackageTable -Packages $pkgs; return }

    Show-PackageTable -Packages $pkgs -Numbered
    Write-Host ''
    $spec = Read-Host 'Numbers to remove (e.g. 1,3,5-7, blank to cancel)'
    $picks = Expand-Selection -Spec $spec -Max $pkgs.Count
    if ($picks.Count -eq 0) { Write-Info 'Nothing selected.'; return }

    Write-Host ''
    Write-Warn ('{0} package(s) will be removed:' -f $picks.Count)
    foreach ($n in $picks) { Write-Host ('     {0}' -f $pkgs[$n - 1].PackageName) -ForegroundColor Yellow }
    Write-Host ''
    Write-Warn 'Packages superseded by a /ResetBase cleanup can no longer be removed.'
    if (-not (Confirm-YesNo 'Remove these packages?' $false)) { Write-Info 'Cancelled.'; return }

    $ok = 0; $bad = 0
    foreach ($n in $picks) {
        $p = $pkgs[$n - 1]
        Write-Info ('Removing {0} ...' -f $p.PackageName)
        try {
            if ($Script:Target.Kind -eq 'Online') {
                Remove-WindowsPackage -Online -PackageName $p.PackageName -NoRestart -ErrorAction Stop | Out-Null
            }
            else {
                Remove-WindowsPackage -Path $Script:Target.ImagePath -PackageName $p.PackageName -ErrorAction Stop | Out-Null
            }
            $ok++; Write-Ok ('{0} removed.' -f (Get-PackageKb -PackageName $p.PackageName))
        }
        catch {
            $bad++
            Write-Err ("{0}: {1}" -f $p.PackageName, $_.Exception.Message)
            Write-Info '  Permanent packages and superseded components cannot be removed.'
        }
    }
    Write-Host ''
    Write-Info ('Removed {0}, failed {1}.' -f $ok, $bad)
    if ($Script:Target.Kind -eq 'Online' -and $ok -gt 0) { Write-Info 'A restart may be required.' }
}

function Invoke-AddActiveUpdates {
    <#
        Mirror of "add the active driver store": takes the update packages
        cached on the running machine and offers to add them to the target.
    #>
    Write-Step "Add updates from the active system to the component store"

    $searchRoots = @(
        (Join-Path $env:windir 'SoftwareDistribution\Download')
    )
    Write-Info ('Searching {0} for cached update packages...' -f $searchRoots[0])

    $files = @()
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $files += @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -match '^\.(msu|cab)$' -and $_.Length -gt 1MB })
    }
    $files = @($files | Sort-Object Length -Descending)

    if ($files.Count -eq 0) {
        Write-Warn 'No cached update packages were found on the active system.'
        Write-Info 'Windows removes them after installation; download the .msu files you need instead.'
        if (-not (Confirm-YesNo 'Pick a different folder of update packages?' $true)) { return }
        $folder = Read-ExistingPath -Prompt 'Path to the folder of updates' -Type 'Container'
        if (-not $folder) { return }
        $files = @(Get-ChildItem -LiteralPath $folder -File -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.Extension -match '^\.(msu|cab)$' } | Sort-Object Name)
        if ($files.Count -eq 0) { Write-Warn 'No .msu or .cab files were found.'; return }
    }

    if ($Script:Target.Kind -eq 'Online') {
        Write-Info 'The target IS the active system; these packages are already installed or pending.'
        Write-Host ''
        foreach ($f in ($files | Select-Object -First 25)) {
            Write-Host ('     {0}  ({1})' -f $f.Name, (Format-Bytes $f.Length)) -ForegroundColor Gray
        }
        return
    }

    if (-not (Test-TargetWritable)) { return }

    Show-PackageFileList -Files $files
    Write-Host ''
    $spec = Read-Host 'Numbers to add (e.g. 1,3,5-7 or "all", blank to cancel)'
    $picks = Expand-Selection -Spec $spec -Max $files.Count
    if ($picks.Count -eq 0) { Write-Info 'Nothing selected.'; return }

    $chosen = @($picks | ForEach-Object { $files[$_ - 1] })
    $ignore = Confirm-YesNo 'Skip the applicability check (IgnoreCheck)?' $false
    Add-UpdateFiles -Files $chosen -IgnoreCheck $ignore -PreventPending $true
}

function Show-PackageFileList {
    param([Parameter(Mandatory)][object[]]$Files)
    Write-Host ''
    Write-Host ('   {0,4}  {1,-12} {2}' -f '#','Size','File') -ForegroundColor White
    Write-Host ('   ' + ('-' * 90)) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Files.Count; $i++) {
        Write-Host ('   {0,4}  {1,-12} {2}' -f ($i + 1), (Format-Bytes $Files[$i].Length), $Files[$i].Name) -ForegroundColor Gray
    }
}

function Invoke-UpdateReport {
    Write-Step 'Create a component store updates report'

    $all = Confirm-YesNo 'Include every package, not just updates?' $false
    Write-Info 'Collecting packages...'
    $pkgs = Get-TargetPackages -All:$all
    if ($pkgs.Count -eq 0) { Write-Warn 'No packages were returned; nothing to report.'; return }

    $rows = $pkgs | Select-Object `
        @{n='KbOrVersion'; e={ Get-PackageKb -PackageName ([string]$_.PackageName) }},
        @{n='ReleaseType'; e={$_.ReleaseType}},
        @{n='State';       e={$_.PackageState}},
        @{n='Installed';   e={ if ($_.InstallTime) { ([datetime]$_.InstallTime).ToString('yyyy-MM-dd HH:mm') } else { '' } }},
        @{n='PackageName'; e={$_.PackageName}}

    $summary = [ordered]@{
        'Target'            = $Script:Target.Label
        'Windows directory' = $Script:Target.WindowsDir
        'Packages listed'   = $pkgs.Count
        'Named KB updates'  = @($pkgs | Where-Object { $_.PackageName -match 'KB\d{6,}' } |
                                Select-Object -ExpandProperty PackageName -Unique).Count
        'Installed'         = @($pkgs | Where-Object { $_.PackageState -eq 'Installed' }).Count
        'Superseded'        = @($pkgs | Where-Object { $_.PackageState -eq 'Superseded' }).Count
        'Newest install'    = ($pkgs | Where-Object InstallTime |
                                Sort-Object InstallTime -Descending |
                                Select-Object -First 1 -ExpandProperty InstallTime) -as [string]
        'Generated'         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }

    Export-Report -Name 'Updates' -Title 'Component Store - Update Report' -Summary $summary -Rows $rows
}

function Show-UpdatesMenu {
    while ($true) {
        Write-Banner 'Manage component store updates'
        Write-TargetLine
        Write-Host ''
        Write-Host '   [1] List the updates installed in the component store' -ForegroundColor Gray
        Write-Host '   [2] Add update package(s) (.msu / .cab) to the component store' -ForegroundColor Gray
        Write-Host '   [3] Remove update package(s) from the component store' -ForegroundColor Gray
        Write-Host "   [4] Add updates from the active system to the component store" -ForegroundColor Gray
        Write-Host '   [5] Create a report of the component store updates' -ForegroundColor Gray
        Write-Host '   [6] Compare this store against a reference (what is missing?)' -ForegroundColor Gray
        Write-Host '   [7] Synchronise this store up to a reference build' -ForegroundColor Gray
        Write-Host ('   [8] Open the update cache ({0})' -f $Script:CacheRoot) -ForegroundColor Gray
        Write-Host '   [0] Back to the main menu' -ForegroundColor Gray

        switch (Read-Choice -Valid @('0','1','2','3','4','5','6','7','8')) {
            '0' { return }
            '1' { Invoke-ListUpdates;        Wait-Key }
            '2' { Invoke-AddUpdate;          Wait-Key }
            '3' { Invoke-RemoveUpdate;       Wait-Key }
            '4' { Invoke-AddActiveUpdates;   Wait-Key }
            '5' { Invoke-UpdateReport;       Wait-Key }
            '6' { Invoke-UpdateDeltaReport;  Wait-Key }
            '7' { Invoke-SyncToReference;    Wait-Key }
            '8' { Start-Process explorer.exe $Script:CacheRoot | Out-Null }
        }
    }
}

#endregion

#region -------------------------------------------- Analyze / cleanup / base

function Invoke-AnalyzeComponentStore {
    Write-Step 'Analyzing the component store (AnalyzeComponentStore)'
    Write-Info 'This can take a few minutes.'

    $r = Invoke-Dism -Arguments @('/Cleanup-Image','/AnalyzeComponentStore') -Quiet

    if ($r.ExitCode -ne 0) {
        Write-Err ('DISM returned exit code {0}.' -f $r.ExitCode)
        foreach ($l in ($r.Lines | Select-Object -Last 8)) { Write-Host ('   {0}' -f $l) -ForegroundColor DarkGray }
        return $null
    }

    $info = [ordered]@{}
    $inReport = $false
    foreach ($line in $r.Lines) {
        if ($line -match 'Component Store \(WinSxS\) information') { $inReport = $true; continue }
        if (-not $inReport) { continue }
        if ($line -match 'The operation completed successfully') { break }
        if ($line -match '^\s*([A-Za-z][^:]*?)\s*:\s*(.+?)\s*$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()
            if ($key -match '^(Version|Image Version)$') { continue }
            $info[$key] = $val
        }
    }

    if ($info.Count -eq 0) {
        Write-Warn 'The analysis output could not be parsed; raw output follows.'
        foreach ($l in $r.Lines) { Write-Host ('   {0}' -f $l) -ForegroundColor Gray }
        return $null
    }

    $recommendedRaw = $info['Component Store Cleanup Recommended']
    $Script:LastAnalysis = [pscustomobject]@{
        When        = Get-Date
        Info        = $info
        Recommended = ($recommendedRaw -match '^(Yes|True)$')
        Reclaimable = [int]($info['Number of Reclaimable Packages'] -as [int])
        Text        = $r.Text
    }
    return $Script:LastAnalysis
}

function Show-AnalysisResult {
    param([object]$Analysis = $Script:LastAnalysis)

    if (-not $Analysis) { Write-Warn 'No analysis data is available.'; return }

    Write-Host ''
    Write-Host '   Component store (WinSxS) information' -ForegroundColor White
    Write-Host ('   ' + ('-' * 72)) -ForegroundColor DarkGray
    foreach ($k in $Analysis.Info.Keys) {
        $color = if ($k -eq 'Component Store Cleanup Recommended') {
                     if ($Analysis.Recommended) { 'Yellow' } else { 'Green' }
                 } else { 'Gray' }
        Write-Host ('   {0,-50} {1}' -f $k, $Analysis.Info[$k]) -ForegroundColor $color
    }
    Write-Host ('   ' + ('-' * 72)) -ForegroundColor DarkGray
    Write-Host ('   Analyzed {0:yyyy-MM-dd HH:mm:ss}' -f $Analysis.When) -ForegroundColor DarkGray

    Write-Host ''
    if ($Analysis.Recommended) {
        Write-Host '   >> Windows RECOMMENDS a component store cleanup.' -ForegroundColor Yellow
        if ($Analysis.Reclaimable -gt 0) {
            Write-Host ('   >> {0} reclaimable package(s) can be removed.' -f $Analysis.Reclaimable) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '   >> No component store cleanup is recommended at this time.' -ForegroundColor Green
    }
}

function Invoke-ComponentCleanup {
    param([switch]$ResetBase, [switch]$Defer)

    if (-not (Test-TargetWritable)) { return }

    if ($ResetBase) {
        Write-Host ''
        Write-Warn 'ResetBase removes every superseded component permanently.'
        Write-Warn 'After it completes, already-installed Windows updates CANNOT be uninstalled.'
        if (-not (Confirm-YesNo 'Continue with /ResetBase?' $false)) { Write-Info 'Cancelled.'; return }
    }

    $label = if ($ResetBase) { 'Cleaning up the component store and resetting the base' }
             else            { 'Cleaning up the component store' }
    Write-Step $label
    Write-Info 'This can take 10-60 minutes and cannot be interrupted safely.'

    $dismArgs = @('/Cleanup-Image','/StartComponentCleanup')
    if ($ResetBase) { $dismArgs += '/ResetBase' }
    if ($Defer)     { $dismArgs += '/Defer' }

    $started = Get-Date
    $r = Invoke-Dism -Arguments $dismArgs
    $actionName = if ($ResetBase) { 'StartComponentCleanup /ResetBase' } else { 'StartComponentCleanup' }

    if ($r.ExitCode -eq 0 -or $r.Text -match 'The operation completed successfully') {
        Write-Ok 'Cleanup completed successfully.'
        Add-SessionAction -Category 'Cleanup' -Action $actionName -Status 'Ok' `
            -Result 'Completed' -Started $started -ExitCode $r.ExitCode `
            -Detail $(if ($ResetBase) { 'Superseded components removed permanently; updates can no longer be uninstalled.' }
                      else { '' }) | Out-Null

        if (Confirm-YesNo 'Re-analyze the component store to see the new size?' $true) {
            $a = Invoke-AnalyzeComponentStore
            if ($a) { Show-AnalysisResult -Analysis $a }
        }
    }
    else {
        Write-Err ('Cleanup failed (exit code {0}).' -f $r.ExitCode)
        if ($r.Text -match '0x800f0806') {
            Write-Warn '0x800F0806: a servicing operation is already pending. Restart and try again.'
        }
        Write-Info ('Details: {0}\Logs\DISM\dism.log' -f $Script:Target.WindowsDir)

        Add-SessionAction -Category 'Cleanup' -Action $actionName -Status 'Failed' `
            -Result ('dism exit {0}' -f $r.ExitCode) -Started $started -ExitCode $r.ExitCode | Out-Null
    }
}

function Invoke-SpSuperseded {
    if (-not (Test-TargetWritable)) { return }

    Write-Host ''
    Write-Warn 'SPSuperseded deletes service-pack backup files permanently.'
    if (-not (Confirm-YesNo 'Continue?' $false)) { Write-Info 'Cancelled.'; return }

    $hide = Confirm-YesNo 'Also hide the service pack in Installed Updates (/HideSP)?' $false

    Write-Step 'Removing service pack backup files (SPSuperseded)'
    $dismArgs = @('/Cleanup-Image','/SPSuperseded')
    if ($hide) { $dismArgs += '/HideSP' }

    $started = Get-Date
    $r = Invoke-Dism -Arguments $dismArgs
    if ($r.ExitCode -eq 0) {
        Write-Ok 'Operation completed.'
        Add-SessionAction -Category 'Cleanup' -Action 'SPSuperseded' -Status 'Ok' `
            -Result 'Service pack backup files removed' -Started $started -ExitCode $r.ExitCode | Out-Null
    }
    else {
        Write-Err ('DISM returned exit code {0}.' -f $r.ExitCode)
        Add-SessionAction -Category 'Cleanup' -Action 'SPSuperseded' -Status 'Failed' `
            -Result ('dism exit {0}' -f $r.ExitCode) -Started $started -ExitCode $r.ExitCode | Out-Null
    }
}

function Invoke-AnalysisReport {
    if (-not $Script:LastAnalysis) { Write-Warn 'Run the analysis first.'; return }

    $rows = foreach ($k in $Script:LastAnalysis.Info.Keys) {
        [pscustomobject]@{ Property = $k; Value = $Script:LastAnalysis.Info[$k] }
    }

    $summary = [ordered]@{
        'Target'             = $Script:Target.Label
        'Windows directory'  = $Script:Target.WindowsDir
        'Cleanup recommended'= $(if ($Script:LastAnalysis.Recommended) { 'Yes' } else { 'No' })
        'Reclaimable packages' = $Script:LastAnalysis.Reclaimable
        'Health (last known)'  = $(if ($Script:LastHealth) { $Script:LastHealth.State } else { 'not checked' })
        'Analyzed'           = $Script:LastAnalysis.When.ToString('yyyy-MM-dd HH:mm:ss')
    }

    Export-Report -Name 'Analysis' -Title 'Component Store - Analysis Report' -Summary $summary -Rows $rows
}

function Show-AnalyzeMenu {
    $analysis = Invoke-AnalyzeComponentStore
    if ($analysis) { Show-AnalysisResult -Analysis $analysis }

    while ($true) {
        Write-Banner 'Component store information'
        Write-TargetLine
        if ($Script:LastAnalysis) { Show-AnalysisResult -Analysis $Script:LastAnalysis }

        $recTag = if ($Script:LastAnalysis -and $Script:LastAnalysis.Recommended) { '   <-- RECOMMENDED' } else { '' }

        Write-Host ''
        Write-Host ('   [1] Clean up the component store (StartComponentCleanup){0}' -f $recTag) -ForegroundColor $(if ($recTag) { 'Yellow' } else { 'Gray' })
        Write-Host '   [2] Clean up and reset the component store base (/ResetBase)' -ForegroundColor Gray
        Write-Host '   [3] Clean up and reset the base, deferring long operations (/ResetBase /Defer)' -ForegroundColor Gray
        Write-Host '   [4] Remove service pack backup files (/SPSuperseded)' -ForegroundColor Gray
        Write-Host '   [5] Re-run the analysis' -ForegroundColor Gray
        Write-Host '   [6] Save this analysis as a report' -ForegroundColor Gray
        Write-Host '   [0] Back to the main menu' -ForegroundColor Gray

        switch (Read-Choice -Valid @('0','1','2','3','4','5','6')) {
            '0' { return }
            '1' {
                if ($Script:LastAnalysis -and -not $Script:LastAnalysis.Recommended) {
                    Write-Warn 'Windows does not currently recommend a cleanup.'
                    if (-not (Confirm-YesNo 'Run the cleanup anyway?' $false)) { Wait-Key; break }
                }
                Invoke-ComponentCleanup
                Wait-Key
            }
            '2' { Invoke-ComponentCleanup -ResetBase;        Wait-Key }
            '3' { Invoke-ComponentCleanup -ResetBase -Defer; Wait-Key }
            '4' { Invoke-SpSuperseded;                       Wait-Key }
            '5' {
                $a = Invoke-AnalyzeComponentStore
                if ($a) { Show-AnalysisResult -Analysis $a }
                Wait-Key
            }
            '6' { Invoke-AnalysisReport; Wait-Key }
        }
    }
}

#endregion

#region ------------------------------------------------- Update delta / sync

function Select-ReferenceTarget {
    <#
        Chooses the component store whose patch level is the goal. Returns
        @{ Target; Mounted } so the caller can unmount anything opened here.

        The reference is read-only by intent: nothing in the sync workflow
        writes to it.
    #>
    Write-Step 'Select the reference component store (the level to match)'
    Write-Host ''
    Write-Host '   [1] The active (running) Windows installation' -ForegroundColor Gray
    Write-Host '   [2] An offline Windows installation on another drive letter' -ForegroundColor Gray
    Write-Host '   [3] A backup image created by this tool' -ForegroundColor Gray
    Write-Host '   [0] Cancel' -ForegroundColor Gray

    switch (Read-Choice -Valid @('0','1','2','3')) {
        '0' { return $null }

        '1' {
            $t = New-Target -Kind 'Online' `
                    -Label ('Active installation - {0}' -f (Get-WindowsBuildString)) `
                    -WindowsDir $env:windir -BootDir ($env:SystemDrive + '\')
            return [pscustomobject]@{ Target = $t; Mounted = $false }
        }

        '2' {
            $vols = @(Get-OfflineWindowsVolumes | Where-Object { -not $_.IsActive })
            if ($vols.Count -eq 0) { Write-Warn 'No offline Windows installations were found.'; return $null }

            Write-Host ''
            for ($i = 0; $i -lt $vols.Count; $i++) {
                Write-Host ('   [{0}] {1}  {2}' -f ($i + 1), $vols[$i].Drive, $vols[$i].Label) -ForegroundColor Gray
            }
            $pick = Read-Host 'Which installation (blank to cancel)'
            $idx  = Expand-Selection -Spec $pick -Max $vols.Count
            if ($idx.Count -eq 0) { return $null }

            $v = $vols[$idx[0] - 1]
            $t = New-Target -Kind 'Offline' -Label ('Offline installation - {0}' -f $v.Drive) `
                    -ImagePath $v.Root.TrimEnd('\') -WindowsDir $v.WindowsDir -BootDir $v.Root
            return [pscustomobject]@{ Target = $t; Mounted = $false }
        }

        '3' {
            $sets = @(Get-BackupSets | Where-Object { $_.HasImage })
            if ($sets.Count -eq 0) { Write-Warn 'There are no image backups to use as a reference.'; return $null }

            Show-BackupTable -Sets $sets -Numbered
            $pick = Read-Host 'Which backup (blank to cancel)'
            $idx  = Expand-Selection -Spec $pick -Max $sets.Count
            if ($idx.Count -eq 0) { return $null }

            $set = $sets[$idx[0] - 1]
            $dir = Join-Path $Script:MountRoot ('ref_{0}' -f (Get-Date -Format 'HHmmss'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            Write-Info 'Mounting the backup read-only as the reference...'
            try {
                Mount-WindowsImage -ImagePath $set.WimPath -Index 1 -Path $dir -ReadOnly -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Err ("Could not mount the backup: {0}" -f $_.Exception.Message)
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                return $null
            }

            $t = New-Target -Kind 'Image' -Label ('Backup {0} {1}' -f $set.Product, $set.Build) `
                    -ImagePath $dir -WindowsDir (Join-Path $dir 'Windows') `
                    -WimPath $set.WimPath -Index 1 -Mounted $true -ReadOnly $true
            return [pscustomobject]@{ Target = $t; Mounted = $true }
        }
    }
}

function Close-ReferenceTarget {
    param([object]$Reference)
    if (-not $Reference -or -not $Reference.Mounted) { return }

    Write-Info 'Releasing the reference image...'
    try {
        Dismount-WindowsImage -Path $Reference.Target.ImagePath -Discard -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $Reference.Target.ImagePath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok 'Reference released.'
    }
    catch { Write-Warn ("Could not release the reference image: {0}" -f $_.Exception.Message) }
}

function Get-UpdateDelta {
    <#
        Compares the packages in a reference store against a target store and
        classifies each one.

        Comparison is by package IDENTITY (the name with its trailing version
        removed) rather than by full package name, because the same component
        at a different patch level has a different full name. Comparing full
        names would report every updated component as both missing and extra.
    #>
    param(
        [Parameter(Mandatory)][object]$ReferenceTarget,
        [Parameter(Mandatory)][object]$CompareTarget
    )

    Write-Info 'Reading the reference package inventory...'
    $refPkgs = Get-PackageInventoryFor -TargetObject $ReferenceTarget
    Write-Info ('  {0} update package(s) in the reference.' -f $refPkgs.Count)

    Write-Info 'Reading the target package inventory...'
    $tgtPkgs = Get-PackageInventoryFor -TargetObject $CompareTarget
    Write-Info ('  {0} update package(s) in the target.' -f $tgtPkgs.Count)

    if ($refPkgs.Count -eq 0) {
        Write-Warn 'The reference returned no packages; a delta cannot be computed.'
        return @()
    }

    # Index the target by identity for lookup.
    $tgtIndex = @{}
    foreach ($p in $tgtPkgs) {
        $id = Get-PackageIdentity -PackageName ([string]$p.PackageName)
        if (-not $tgtIndex.ContainsKey($id.Identity)) { $tgtIndex[$id.Identity] = $id.Version }
    }

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($p in $refPkgs) {
        $name = [string]$p.PackageName
        $id   = Get-PackageIdentity -PackageName $name
        $kb   = Get-PackageKb -PackageName $name

        $verdict = 'Present'
        $tgtVer  = ''

        if (-not $tgtIndex.ContainsKey($id.Identity)) {
            $verdict = 'Missing'
        }
        else {
            $tgtVer = $tgtIndex[$id.Identity]
            if ($tgtVer -ne $id.Version) {
                $cmp = 0
                try { $cmp = ([version]$id.Version).CompareTo([version]$tgtVer) } catch { $cmp = 0 }
                $verdict = if ($cmp -gt 0) { 'Older in target' }
                           elseif ($cmp -lt 0) { 'Newer in target' }
                           else { 'Present' }
            }
        }

        $rows.Add([pscustomobject]@{
            KB               = $kb
            Verdict          = $verdict
            ReferenceVersion = $id.Version
            TargetVersion    = $tgtVer
            ReleaseType      = [string]$p.ReleaseType
            State            = [string]$p.PackageState
            PackageName      = $name
            Identity         = $id.Identity
        })
    }

    # Anything in the target the reference does not have is worth surfacing: it
    # usually means the target is on a different branch, not merely behind.
    $refIndex = @{}
    foreach ($p in $refPkgs) {
        $id = Get-PackageIdentity -PackageName ([string]$p.PackageName)
        $refIndex[$id.Identity] = $true
    }
    foreach ($p in $tgtPkgs) {
        $name = [string]$p.PackageName
        $id   = Get-PackageIdentity -PackageName $name
        if ($refIndex.ContainsKey($id.Identity)) { continue }
        $rows.Add([pscustomobject]@{
            KB               = (Get-PackageKb -PackageName $name)
            Verdict          = 'Only in target'
            ReferenceVersion = ''
            TargetVersion    = $id.Version
            ReleaseType      = [string]$p.ReleaseType
            State            = [string]$p.PackageState
            PackageName      = $name
            Identity         = $id.Identity
        })
    }

    return @($rows | Sort-Object @{ Expression = {
        switch ($_.Verdict) {
            'Missing'         { 0 }
            'Older in target' { 1 }
            'Only in target'  { 2 }
            'Newer in target' { 3 }
            default           { 4 }
        } } }, KB)
}

function Show-DeltaSummary {
    <#  Prints the delta and returns the set of rows that represent work to do. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Delta,
        [Parameter(Mandatory)][object]$ReferenceIdentity,
        [Parameter(Mandatory)][object]$TargetIdentity
    )

    Write-Host ''
    Write-Host '   Build comparison' -ForegroundColor White
    Write-Host ('     Reference : {0,-12} {1} {2}' -f
        $ReferenceIdentity.BuildString, $ReferenceIdentity.ProductName, $ReferenceIdentity.Architecture) -ForegroundColor Gray
    Write-Host ('     Target    : {0,-12} {1} {2}' -f
        $TargetIdentity.BuildString, $TargetIdentity.ProductName, $TargetIdentity.Architecture) -ForegroundColor Gray

    if ($ReferenceIdentity.Architecture -ne $TargetIdentity.Architecture -and
        $ReferenceIdentity.Architecture -ne 'Unknown' -and $TargetIdentity.Architecture -ne 'Unknown') {
        Write-Err 'The reference and target architectures differ. Updates will not apply across architectures.'
    }
    if ($ReferenceIdentity.CurrentBuild -ne $TargetIdentity.CurrentBuild -and
        $ReferenceIdentity.CurrentBuild -gt 0 -and $TargetIdentity.CurrentBuild -gt 0) {
        Write-Warn ('The base builds differ ({0} vs {1}). Cumulative updates do not move a store between' -f
            $ReferenceIdentity.CurrentBuild, $TargetIdentity.CurrentBuild)
        Write-Warn 'base builds; that requires a feature update or a newer image.'
    }

    $missing = @($Delta | Where-Object { $_.Verdict -eq 'Missing' })
    $older   = @($Delta | Where-Object { $_.Verdict -eq 'Older in target' })
    $newer   = @($Delta | Where-Object { $_.Verdict -eq 'Newer in target' })
    $only    = @($Delta | Where-Object { $_.Verdict -eq 'Only in target' })
    $present = @($Delta | Where-Object { $_.Verdict -eq 'Present' })

    Write-Host ''
    Write-Host '   Package delta' -ForegroundColor White
    Write-Host ('     Missing from target : {0}' -f $missing.Count) -ForegroundColor $(if ($missing.Count) { 'Yellow' } else { 'Green' })
    Write-Host ('     Older in target     : {0}' -f $older.Count)   -ForegroundColor $(if ($older.Count)   { 'Yellow' } else { 'Green' })
    Write-Host ('     Newer in target     : {0}' -f $newer.Count)   -ForegroundColor Gray
    Write-Host ('     Only in target      : {0}' -f $only.Count)    -ForegroundColor Gray
    Write-Host ('     Already matching    : {0}' -f $present.Count) -ForegroundColor Gray

    $work = @($missing + $older)
    if ($work.Count -gt 0) {
        Write-Host ''
        Write-Host '   Updates required to bring the target to the reference level' -ForegroundColor White
        Write-Host ('   {0,-14} {1,-17} {2,-12} {3}' -f 'KB','Verdict','Reference','Package') -ForegroundColor White
        Write-Host ('   ' + ('-' * 112)) -ForegroundColor DarkGray
        foreach ($r in $work) {
            Write-Host ('   {0,-14} {1,-17} {2,-12} {3}' -f
                $r.KB, $r.Verdict, $r.ReferenceVersion, $r.PackageName) -ForegroundColor Gray
        }
    }
    else {
        Write-Host ''
        Write-Ok 'The target already carries every package the reference has.'
    }

    return $work
}

# ---------------------------------------------------------- Update acquisition

function Get-LocalUpdateFiles {
    <#
        Searches the local sources for .msu / .cab packages: this tool's own
        cache, the running machine's Windows Update download folder, and any
        folder the technician nominates.
    #>
    param([string[]]$ExtraFolders = @())

    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add($Script:CacheRoot)
    $roots.Add((Join-Path $env:windir 'SoftwareDistribution\Download'))
    foreach ($f in $ExtraFolders) { if ($f) { $roots.Add($f) } }

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(msu|cab)$' -and $_.Length -gt 100KB } |
            ForEach-Object { $files.Add($_) }
    }
    return @($files | Sort-Object FullName -Unique)
}

function Find-UpdateFileForKb {
    <#  Picks the local file whose name carries the wanted KB. #>
    param(
        # Packages whose name carries no KB reach this with an empty string,
        # so the binder must allow it for the guard below to do its job.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Kb,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Files,
        [string]$Architecture = ''
    )
    if (-not $Kb) { return $null }

    $candidates = @($Files | Where-Object { $_.Name -match [regex]::Escape($Kb) })
    if ($candidates.Count -eq 0) { return $null }

    if ($Architecture) {
        $archToken = switch ($Architecture) {
            'x64'   { 'x64|amd64' }
            'x86'   { 'x86' }
            'ARM64' { 'arm64' }
            default { '' }
        }
        if ($archToken) {
            $archMatch = @($candidates | Where-Object { $_.Name -match $archToken })
            if ($archMatch.Count -gt 0) { $candidates = $archMatch }
        }
    }

    # Prefer the largest: the cumulative package rather than a stub or a
    # language pack that happens to carry the same KB in its name.
    return ($candidates | Sort-Object Length -Descending | Select-Object -First 1)
}

function Get-CatalogSearchUrl {
    param([Parameter(Mandatory)][string]$Query)
    return ('https://www.catalog.update.microsoft.com/Search.aspx?q={0}' -f
        [uri]::EscapeDataString($Query))
}

function Find-CatalogUpdate {
    <#
        Queries the Microsoft Update Catalog for a KB.

        The catalog publishes no supported API, so this drives its public web
        endpoints and parses the returned markup. That is unsupported by
        Microsoft and can break without notice, so every failure here is
        non-fatal: the caller falls back to the manifest of catalog links.
    #>
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$TimeoutSec = 45
    )

    $url = Get-CatalogSearchUrl -Query $Query
    Write-Log ('Catalog search: {0}' -f $url) 'INFO'

    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec `
                    -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -ErrorAction Stop
    }
    catch {
        Write-Warn ("Catalog search failed: {0}" -f $_.Exception.Message)
        return @()
    }

    $html = $resp.Content
    if ($html -match 'We did not find any results') { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    $seen    = New-Object System.Collections.Generic.HashSet[string]

    # Each result row carries its update id in the title anchor's onclick
    # handler. The anchor's id attribute holds the same guid but is written with
    # single quotes, so the onclick is the more dependable anchor to match on.
    $pattern = '(?s)goToDetails\("(?<id>[0-9a-fA-F\-]{36})"\)[^>]*>(?<title>.*?)</a>'

    foreach ($m in [regex]::Matches($html, $pattern)) {
        $id = $m.Groups['id'].Value
        if (-not $seen.Add($id)) { continue }

        $title = ($m.Groups['title'].Value -replace '<[^>]+>', '').Trim()
        $title = ([System.Net.WebUtility]::HtmlDecode($title) -replace '\s+', ' ').Trim()
        if (-not $title) { continue }

        $results.Add([pscustomobject]@{
            UpdateId = $id
            Title    = $title
        })
    }

    return $results.ToArray()
}

function Get-CatalogDownloadUrl {
    <#
        Resolves an update id to its direct download URLs through the catalog's
        download dialog. Returns the .msu / .cab URLs it finds.
    #>
    param(
        [Parameter(Mandatory)][string]$UpdateId,
        [int]$TimeoutSec = 45
    )

    $body = 'updateIDs=' + [uri]::EscapeDataString(
        ('[{{"size":0,"languages":"","uidInfo":"{0}","updateID":"{0}"}}]' -f $UpdateId))

    try {
        $resp = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' `
                    -Method Post -Body $body -UseBasicParsing -TimeoutSec $TimeoutSec `
                    -ContentType 'application/x-www-form-urlencoded' `
                    -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -ErrorAction Stop
    }
    catch {
        Write-Warn ("Catalog download lookup failed: {0}" -f $_.Exception.Message)
        return @()
    }

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($resp.Content, "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'")) {
        $u = $m.Groups[1].Value
        if ($u -match '\.(msu|cab)$') { $urls.Add($u) }
    }
    return @($urls | Select-Object -Unique)
}

function Save-CatalogFile {
    <#
        Downloads a package and verifies it before it is considered usable.

        Verification records the SHA256 and checks the Authenticode signature.
        An unsigned or untrusted package is reported and NOT silently accepted,
        because an update package is applied with full servicing privilege.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    $name = Split-Path ([uri]$Url).AbsolutePath -Leaf
    $path = Join-Path $Destination $name

    if (Test-Path -LiteralPath $path) {
        Write-Info ('Already cached: {0}' -f $name)
    }
    else {
        Write-Info ('Downloading {0} ...' -f $name)
        $progress = $ProgressPreference
        try {
            # The progress bar makes Invoke-WebRequest dramatically slower on 5.1.
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing -TimeoutSec 1800 -ErrorAction Stop
        }
        catch {
            Write-Err ("Download failed: {0}" -f $_.Exception.Message)
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            return $null
        }
        finally { $ProgressPreference = $progress }
    }

    $file = Get-Item -LiteralPath $path
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash

    $sigStatus = 'Unknown'
    $sigSubject = ''
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        $sigStatus = [string]$sig.Status
        if ($sig.SignerCertificate) { $sigSubject = $sig.SignerCertificate.Subject }
    }
    catch { $sigStatus = 'Unreadable' }

    Write-Info ('  Size      : {0}' -f (Format-Bytes $file.Length))
    Write-Info ('  SHA256    : {0}' -f $hash)
    Write-Info ('  Signature : {0}' -f $sigStatus)

    if ($sigStatus -ne 'Valid') {
        Write-Warn ('{0} does not carry a valid Authenticode signature.' -f $name)
        if (-not (Confirm-YesNo 'Keep this package anyway?' $false)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            return $null
        }
    }
    else { Write-Ok ('{0} verified.' -f $name) }

    return [pscustomobject]@{
        Path      = $path
        Name      = $name
        Size      = $file.Length
        Sha256    = $hash
        Signature = $sigStatus
        Signer    = $sigSubject
        Url       = $Url
    }
}

function Export-RequiredUpdatesManifest {
    <#
        Writes the required-update list with a catalog search link per KB.

        This is always produced, even when the automated download succeeds,
        because it is the artifact that lets the work be reproduced or audited
        on a machine with no network access.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Required,
        [Parameter(Mandatory)][object]$ReferenceIdentity,
        [Parameter(Mandatory)][object]$TargetIdentity
    )

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($kb in (@($Required | Where-Object { $_.KB -match '^KB\d+' } |
                       Select-Object -ExpandProperty KB -Unique))) {
        $query = '{0} {1}' -f $kb, $TargetIdentity.Architecture
        $rows.Add([pscustomobject]@{
            KB         = $kb
            Architecture = $TargetIdentity.Architecture
            TargetBuild  = $TargetIdentity.BuildString
            GoalBuild    = $ReferenceIdentity.BuildString
            CatalogSearch = (Get-CatalogSearchUrl -Query $query)
        })
    }

    # Packages with no KB in the name still matter; list them so the manifest
    # is a complete statement of the gap rather than only its convenient part.
    foreach ($r in @($Required | Where-Object { $_.KB -notmatch '^KB\d+' })) {
        $rows.Add([pscustomobject]@{
            KB            = '(no KB in package name)'
            Architecture  = $TargetIdentity.Architecture
            TargetBuild   = $TargetIdentity.BuildString
            GoalBuild     = $ReferenceIdentity.BuildString
            CatalogSearch = $r.PackageName
        })
    }

    $summary = [ordered]@{
        'Session'            = $Script:SessionId
        'Target store'       = $Script:Target.Label
        'Target build'       = $TargetIdentity.BuildString
        'Reference build'    = $ReferenceIdentity.BuildString
        'Architecture'       = $TargetIdentity.Architecture
        'Packages required'  = $Required.Count
        'Distinct KBs'       = @($rows | Where-Object { $_.KB -match '^KB' }).Count
        'Note'               = 'Download each KB for the listed architecture, place the .msu/.cab files in ' +
                               $Script:CacheRoot + ', then re-run the synchronise action.'
    }

    Export-Report -Name 'RequiredUpdates' -Title 'Updates required to reach the reference build' `
        -Summary $summary -Rows $rows.ToArray()

    return $rows.ToArray()
}

function Get-UpdateApplyOrder {
    <#
        Orders packages for application.

        Servicing stack updates must go first: the SSU upgrades the very engine
        that installs the cumulative update, and applying an LCU against an old
        servicing stack is a documented cause of failed and unrecoverable
        offline servicing. Cumulative updates follow, then everything else.

        A package is treated as a servicing stack update when the caller has
        marked it (an SsuHint note property set during acquisition) or when its
        file name carries an SSU token. The hint matters because a modern SSU
        delivered as a cumulative update's prerequisite is named like any other
        package - windows11.0-kb5043080-x64_<hash>.msu - with nothing in the
        name to identify it.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packages)

    return @($Packages | Sort-Object @{ Expression = {
        $n = [string]$_.Name
        if ($_.PSObject.Properties.Name -contains 'SsuHint' -and $_.SsuHint) { 0 }
        elseif ($n -match 'ssu|servicingstack|servicing-stack') { 0 }
        elseif ($n -match 'lcu|cumulative') { 1 }
        else { 2 }
    }}, Name)
}

function Invoke-SyncToReference {
    <#
        Brings the current target up to the patch level of a reference store.

        There is no offline Windows Update client: Windows cannot be pointed at
        a mounted image and told to update it. The supported route, and the one
        used here, is to determine the missing packages, obtain the .msu/.cab
        files, and apply them with Add-WindowsPackage.
    #>
    Write-Step 'Synchronise this component store to a reference build'

    if ($Script:Target.Kind -eq 'Online') {
        Write-Err 'The target is the running installation.'
        Write-Info 'Use Windows Update to service the running system; this action updates an offline'
        Write-Info 'store, a mounted image or a backup to match a reference.'
        return
    }
    if (-not (Test-TargetWritable)) { return }

    $started = Get-Date
    $reference = Select-ReferenceTarget
    if (-not $reference) { Write-Info 'Cancelled.'; return }

    try {
        $refId = Get-TargetIdentity -TargetObject $reference.Target
        $tgtId = Get-TargetIdentity -TargetObject $Script:Target

        Write-Host ''
        Write-Info 'Computing the package delta...'
        $delta = Get-UpdateDelta -ReferenceTarget $reference.Target -CompareTarget $Script:Target
        if ($delta.Count -eq 0) {
            Write-Warn 'No comparison could be made.'
            Add-SessionAction -Category 'Updates' -Action 'Synchronise to reference' -Status 'Failed' `
                -Result 'Delta could not be computed' -Started $started
            return
        }

        $required = Show-DeltaSummary -Delta $delta -ReferenceIdentity $refId -TargetIdentity $tgtId

        Add-SessionAction -Category 'Updates' -Action 'Computed update delta' -Status 'Ok' `
            -Result ('{0} package(s) required' -f $required.Count) `
            -Detail ('reference {0} -> target {1}' -f $refId.BuildString, $tgtId.BuildString) -Started $started

        if ($required.Count -eq 0) {
            Write-Ok 'Nothing to synchronise.'
            if (Confirm-YesNo 'Write the comparison to a report anyway?' $false) {
                Export-Report -Name 'UpdateDelta' -Title 'Component store update comparison' `
                    -Summary ([ordered]@{
                        'Reference build' = $refId.BuildString
                        'Target build'    = $tgtId.BuildString
                        'Result'          = 'Target already matches the reference'
                    }) -Rows $delta
            }
            return
        }

        # The manifest is written before any download so the required list
        # survives even if acquisition or application fails.
        Write-Host ''
        if (Confirm-YesNo 'Write the required-update list and catalog links to a report now?' $true) {
            Export-RequiredUpdatesManifest -Required $required `
                -ReferenceIdentity $refId -TargetIdentity $tgtId | Out-Null
        }

        Write-Host ''
        if (-not (Confirm-YesNo 'Attempt to acquire and apply these updates?' $false)) {
            Write-Info 'Stopping after the comparison. Nothing has been changed.'
            Add-SessionAction -Category 'Updates' -Action 'Synchronise to reference' -Status 'Declined' `
                -Result 'Technician stopped after the comparison' -Started $started
            return
        }

        # --- Acquire -------------------------------------------------------
        $wantedKbs = @($required | Where-Object { $_.KB -match '^KB\d+' } |
                       Select-Object -ExpandProperty KB -Unique)

        if ($wantedKbs.Count -eq 0) {
            Write-Warn 'None of the required packages carry a KB number, so they cannot be located by KB.'
            Write-Info 'Supply the packages manually and use "Add an update package" instead.'
            return
        }

        Write-Host ''
        Write-Info ('{0} distinct KB(s) required: {1}' -f $wantedKbs.Count, ($wantedKbs -join ', '))

        $extra = @()
        if (Confirm-YesNo 'Search an additional folder of update packages?' $false) {
            $folder = Read-ExistingPath -Prompt 'Folder containing .msu / .cab files' -Type 'Container'
            if ($folder) { $extra = @($folder) }
        }

        Write-Info 'Searching local sources...'
        $localFiles = Get-LocalUpdateFiles -ExtraFolders $extra
        Write-Info ('  {0} candidate package file(s) found locally.' -f $localFiles.Count)

        $resolved = New-Object System.Collections.Generic.List[object]
        $unresolved = New-Object System.Collections.Generic.List[string]

        foreach ($kb in $wantedKbs) {
            $hit = Find-UpdateFileForKb -Kb $kb -Files $localFiles -Architecture $tgtId.Architecture
            if ($hit) {
                Write-Ok ('{0}: found locally ({1})' -f $kb, $hit.Name)
                $resolved.Add($hit)
            }
            else { $unresolved.Add($kb) }
        }

        if ($unresolved.Count -gt 0) {
            Write-Host ''
            Write-Warn ('{0} KB(s) were not found locally: {1}' -f $unresolved.Count, ($unresolved -join ', '))
            Write-Info 'The Microsoft Update Catalog has no supported API. Downloading from it drives its'
            Write-Info 'public web endpoints, which Microsoft may change at any time.'

            if (Confirm-YesNo 'Try to download the missing packages from the Microsoft Update Catalog?' $false) {
                foreach ($kb in $unresolved.ToArray()) {
                    Write-Host ''
                    Write-Info ('Searching the catalog for {0} ({1})...' -f $kb, $tgtId.Architecture)

                    $query = '{0} {1}' -f $kb, $tgtId.Architecture
                    $hits  = Find-CatalogUpdate -Query $query
                    if ($hits.Count -eq 0) {
                        Write-Warn ('No catalog results for {0}.' -f $kb)
                        Write-Info ('  Search manually: {0}' -f (Get-CatalogSearchUrl -Query $query))
                        continue
                    }

                    Write-Host ''
                    for ($i = 0; $i -lt [math]::Min($hits.Count, 15); $i++) {
                        Write-Host ('   [{0,2}] {1}' -f ($i + 1), $hits[$i].Title) -ForegroundColor Gray
                    }
                    $pick = Read-Host 'Which result to download (blank to skip this KB)'
                    $idx  = Expand-Selection -Spec $pick -Max ([math]::Min($hits.Count, 15))
                    if ($idx.Count -eq 0) { Write-Info 'Skipped.'; continue }

                    $chosen = $hits[$idx[0] - 1]
                    $urls   = Get-CatalogDownloadUrl -UpdateId $chosen.UpdateId
                    if ($urls.Count -eq 0) { Write-Warn 'No download URL was returned for that result.'; continue }

                    if ($urls.Count -gt 1) {
                        Write-Info ('{0} files are attached to this update; the extra one is normally the ' -f $urls.Count)
                        Write-Info 'prerequisite servicing stack update and will be applied first.'
                    }

                    foreach ($u in $urls) {
                        $saved = Save-CatalogFile -Url $u -Destination $Script:CacheRoot
                        if (-not $saved) { continue }

                        $item = Get-Item -LiteralPath $saved.Path

                        # A cumulative update's download often includes its
                        # prerequisite SSU as a second file, named for a
                        # different KB. Nothing in that file name identifies it
                        # as a servicing stack update, so flag it here where the
                        # relationship is still visible.
                        $isPrerequisite = ($urls.Count -gt 1) -and ($item.Name -notmatch [regex]::Escape($kb))
                        $isSsuByTitle   = $chosen.Title -match 'Servicing Stack'

                        Add-Member -InputObject $item -NotePropertyName 'SsuHint' `
                            -NotePropertyValue ($isPrerequisite -or $isSsuByTitle) -Force

                        if ($isPrerequisite -or $isSsuByTitle) {
                            Write-Info ('  {0} will be applied as a servicing stack update.' -f $item.Name)
                        }

                        $resolved.Add($item)
                        Add-SessionAction -Category 'Updates' -Action ('Downloaded {0}' -f $kb) -Status 'Ok' `
                            -Result $saved.Name -Detail ('SHA256 {0}; signature {1}' -f $saved.Sha256, $saved.Signature) | Out-Null
                        $unresolved.Remove($kb) | Out-Null
                    }
                }
            }
        }

        if ($resolved.Count -eq 0) {
            Write-Host ''
            Write-Err 'No update packages could be obtained. Nothing has been applied.'
            Write-Info ('Place the required .msu files in {0} and run this action again.' -f $Script:CacheRoot)
            Add-SessionAction -Category 'Updates' -Action 'Synchronise to reference' -Status 'Failed' `
                -Result 'No packages could be obtained' -Detail ($wantedKbs -join ', ') -Started $started
            return
        }

        # --- Apply ---------------------------------------------------------
        $ordered = Get-UpdateApplyOrder -Packages @($resolved | Sort-Object FullName -Unique)

        Write-Host ''
        Write-Host '   Packages will be applied in this order:' -ForegroundColor White
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            Write-Host ('     {0,2}. {1}  ({2})' -f ($i + 1), $ordered[$i].Name, (Format-Bytes $ordered[$i].Length)) -ForegroundColor Gray
        }
        Write-Host ''
        Write-Info 'Servicing stack updates are applied before cumulative updates because the stack'
        Write-Info 'installs the cumulative package.'

        if ($unresolved.Count -gt 0) {
            Write-Warn ('{0} required KB(s) are still missing: {1}' -f $unresolved.Count, ($unresolved -join ', '))
            Write-Warn 'The target will not fully reach the reference build in this pass.'
        }

        if (-not (Confirm-YesNo 'Apply these packages to the target now?' $false)) {
            Write-Info 'Nothing was applied.'
            Add-SessionAction -Category 'Updates' -Action 'Synchronise to reference' -Status 'Declined' `
                -Result 'Declined at the apply confirmation' -Started $started
            return
        }

        $applyStart = Get-Date
        Add-UpdateFiles -Files $ordered -IgnoreCheck $false -PreventPending $true

        # --- Verify --------------------------------------------------------
        Write-Step 'Verifying the result'
        $afterId = Get-TargetIdentity -TargetObject $Script:Target
        Write-Info ('Target build before : {0}' -f $tgtId.BuildString)
        Write-Info ('Target build after  : {0}' -f $afterId.BuildString)
        Write-Info ('Reference build     : {0}' -f $refId.BuildString)

        $afterDelta = Get-UpdateDelta -ReferenceTarget $reference.Target -CompareTarget $Script:Target
        $stillNeeded = @($afterDelta | Where-Object { $_.Verdict -in @('Missing','Older in target') })

        Write-Host ''
        if ($stillNeeded.Count -eq 0) {
            Write-Ok 'The target now matches the reference package set.'
            $status = 'Ok'
        }
        else {
            Write-Warn ('{0} package(s) still differ from the reference.' -f $stillNeeded.Count)
            $status = 'Warning'
        }

        Add-SessionAction -Category 'Updates' -Action 'Synchronise to reference' -Status $status `
            -Result ('{0} -> {1} (goal {2})' -f $tgtId.BuildString, $afterId.BuildString, $refId.BuildString) `
            -Detail ('{0} package(s) applied; {1} still outstanding' -f $ordered.Count, $stillNeeded.Count) `
            -Started $applyStart

        if (Confirm-YesNo 'Write a before-and-after synchronisation report?' $true) {
            Export-Report -Name 'UpdateSync' -Title 'Component store synchronisation' `
                -Summary ([ordered]@{
                    'Session'             = $Script:SessionId
                    'Target'              = $Script:Target.Label
                    'Reference'           = $reference.Target.Label
                    'Build before'        = $tgtId.BuildString
                    'Build after'         = $afterId.BuildString
                    'Reference build'     = $refId.BuildString
                    'Packages applied'    = $ordered.Count
                    'Still outstanding'   = $stillNeeded.Count
                }) -Rows $afterDelta
        }
    }
    finally {
        Close-ReferenceTarget -Reference $reference
    }
}

function Invoke-UpdateDeltaReport {
    <#  Comparison only: computes and reports the delta, changing nothing. #>
    Write-Step 'Compare this component store against a reference'

    $started   = Get-Date
    $reference = Select-ReferenceTarget
    if (-not $reference) { Write-Info 'Cancelled.'; return }

    try {
        $refId = Get-TargetIdentity -TargetObject $reference.Target
        $tgtId = Get-TargetIdentity -TargetObject $Script:Target

        $delta = Get-UpdateDelta -ReferenceTarget $reference.Target -CompareTarget $Script:Target
        if ($delta.Count -eq 0) { Write-Warn 'No comparison could be made.'; return }

        $required = Show-DeltaSummary -Delta $delta -ReferenceIdentity $refId -TargetIdentity $tgtId

        Add-SessionAction -Category 'Updates' -Action 'Compared against reference' -Status 'Ok' `
            -Result ('{0} package(s) required' -f $required.Count) `
            -Detail ('reference {0} vs target {1}' -f $refId.BuildString, $tgtId.BuildString) -Started $started

        Write-Host ''
        if ($required.Count -gt 0 -and (Confirm-YesNo 'Write the required-update list with catalog links?' $true)) {
            Export-RequiredUpdatesManifest -Required $required `
                -ReferenceIdentity $refId -TargetIdentity $tgtId | Out-Null
        }
        elseif (Confirm-YesNo 'Write the full comparison to a report?' $true) {
            Export-Report -Name 'UpdateDelta' -Title 'Component store update comparison' `
                -Summary ([ordered]@{
                    'Reference'       = $reference.Target.Label
                    'Reference build' = $refId.BuildString
                    'Target'          = $Script:Target.Label
                    'Target build'    = $tgtId.BuildString
                    'Required'        = $required.Count
                }) -Rows $delta
        }
    }
    finally { Close-ReferenceTarget -Reference $reference }
}

#endregion

#region -------------------------------------------------------------- Backup

function New-BackupSetFolder {
    <#  Creates a timestamped backup set folder and returns its path. #>
    param([Parameter(Mandatory)][string]$Kind)

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $name  = '{0}_{1}' -f $Kind, $stamp
    $path  = Join-Path $Script:BackupRoot $name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Write-BackupManifest {
    <#
        Every backup set carries a manifest describing what it is, what it came
        from and what it can be used for. Without this a folder of WIMs is
        indistinguishable rubble six months later.
    #>
    param(
        [Parameter(Mandatory)][string]$SetPath,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][object]$Identity,
        [Parameter(Mandatory)][string]$SourceLabel,
        [object[]]$Files = @(),
        [string]$Notes = ''
    )

    $manifest = [pscustomobject]@{
        SchemaVersion  = 1
        Kind           = $Kind
        SessionId      = $Script:SessionId
        CreatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        CreatedBy      = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        CreatedOn      = $env:COMPUTERNAME
        AppVersion     = $Script:AppVersion
        SourceLabel    = $SourceLabel
        ProductName    = $Identity.ProductName
        CurrentBuild   = $Identity.CurrentBuild
        UBR            = $Identity.UBR
        BuildString    = $Identity.BuildString
        Edition        = $Identity.Edition
        Architecture   = $Identity.Architecture
        DisplayVersion = $Identity.DisplayVersion
        Notes          = $Notes
        Files          = @($Files)
    }

    $path = Join-Path $SetPath 'backup-manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $manifest
}

function Invoke-MetadataBackup {
    <#
        Fast, small backup of the servicing STATE: package and feature
        inventory, servicing registry hives and the servicing logs.

        This is a reference and forensic artifact. It is deliberately NOT a
        restorable component store, and the manifest says so, because restoring
        COMPONENTS over a live store is not a supported repair.
    #>
    param([string]$SetPath)

    $started = Get-Date
    Write-Step 'Backing up component store servicing metadata'

    if (-not $SetPath) { $SetPath = New-BackupSetFolder -Kind 'Metadata' }
    $identity = Get-TargetIdentity
    $files    = New-Object System.Collections.Generic.List[object]

    # --- Package inventory -------------------------------------------------
    Write-Info 'Collecting package inventory...'
    $pkgs = Get-TargetPackages -All
    if ($pkgs.Count -gt 0) {
        $rows = $pkgs | Select-Object PackageName, PackageState, ReleaseType, InstallTime
        $csv  = Join-Path $SetPath 'packages.csv'
        $json = Join-Path $SetPath 'packages.json'
        $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
        $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $json -Encoding UTF8
        $files.Add([pscustomobject]@{ Name = 'packages.csv';  Purpose = 'Package inventory' })
        $files.Add([pscustomobject]@{ Name = 'packages.json'; Purpose = 'Package inventory (structured)' })
        Write-Ok ('{0} package(s) recorded.' -f $pkgs.Count)
    }
    else { Write-Warn 'No packages were enumerated.' }

    # --- Feature inventory -------------------------------------------------
    try {
        Write-Info 'Collecting optional feature inventory...'
        $feat = if ($Script:Target.Kind -eq 'Online') {
                    Get-WindowsOptionalFeature -Online -ErrorAction Stop
                } else {
                    Get-WindowsOptionalFeature -Path $Script:Target.ImagePath -ErrorAction Stop
                }
        $featRows = @($feat | Select-Object FeatureName, State)
        if ($featRows.Count -gt 0) {
            $featRows | Export-Csv -LiteralPath (Join-Path $SetPath 'features.csv') -NoTypeInformation -Encoding UTF8
            $files.Add([pscustomobject]@{ Name = 'features.csv'; Purpose = 'Optional feature states' })
            Write-Ok ('{0} feature(s) recorded.' -f $featRows.Count)
        }
    }
    catch { Write-Warn ("Feature inventory unavailable: {0}" -f $_.Exception.Message) }

    # --- Servicing registry hives -----------------------------------------
    # COMPONENTS is the component store's own database; SOFTWARE carries the
    # build identity. Both are copied as files for an offline target and
    # exported via reg for the online one.
    $hiveDir = Join-Path $SetPath 'Hives'
    New-Item -ItemType Directory -Path $hiveDir -Force | Out-Null
    try {
        if ($Script:Target.Kind -eq 'Online') {
            Write-Info 'Exporting servicing registry hives...'
            foreach ($h in @(
                @{ Key = 'HKLM\COMPONENTS'; File = 'COMPONENTS.reg' },
                @{ Key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
                   File = 'CBS.reg' })) {
                $out = Join-Path $hiveDir $h.File
                & reg.exe export $h.Key $out /y 2>&1 | Out-Null
                if (Test-Path -LiteralPath $out) {
                    $files.Add([pscustomobject]@{ Name = "Hives\$($h.File)"; Purpose = 'Servicing registry export' })
                }
            }
        }
        else {
            $cfg = Join-Path $Script:Target.WindowsDir 'System32\config'
            foreach ($h in @('COMPONENTS','SOFTWARE','SYSTEM')) {
                $src = Join-Path $cfg $h
                if (Test-Path -LiteralPath $src) {
                    Copy-Item -LiteralPath $src -Destination (Join-Path $hiveDir $h) -Force -ErrorAction Stop
                    $files.Add([pscustomobject]@{ Name = "Hives\$h"; Purpose = 'Offline servicing hive' })
                }
            }
        }
        Write-Ok 'Servicing hives captured.'
    }
    catch { Write-Warn ("Hive capture incomplete: {0}" -f $_.Exception.Message) }

    # --- Servicing logs ----------------------------------------------------
    $logDir = Join-Path $SetPath 'Logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logSources = @(
        (Join-Path $Script:Target.WindowsDir 'Logs\CBS'),
        (Join-Path $Script:Target.WindowsDir 'Logs\DISM')
    )
    foreach ($src in $logSources) {
        if (-not (Test-Path -LiteralPath $src)) { continue }
        try {
            $dest = Join-Path $logDir (Split-Path $src -Leaf)
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -lt 200MB } |
                Copy-Item -Destination $dest -Force -ErrorAction SilentlyContinue
            $files.Add([pscustomobject]@{ Name = "Logs\$(Split-Path $src -Leaf)"; Purpose = 'Servicing log' })
        }
        catch { Write-Warn ("Could not copy {0}: {1}" -f $src, $_.Exception.Message) }
    }
    Write-Ok 'Servicing logs captured.'

    Write-BackupManifest -SetPath $SetPath -Kind 'Metadata' -Identity $identity `
        -SourceLabel $Script:Target.Label -Files $files.ToArray() `
        -Notes ('Servicing metadata only. This set records the state of the component store; ' +
                'it is NOT a restorable component store and cannot be used as a DISM repair source.') | Out-Null

    $size = (Get-ChildItem -LiteralPath $SetPath -Recurse -File -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum
    Write-Ok ('Metadata backup written to {0} ({1}).' -f $SetPath, (Format-Bytes $size))

    Add-SessionAction -Category 'Backup' -Action 'Servicing metadata backup' -Status 'Ok' `
        -Result ('{0} package(s), {1}' -f $pkgs.Count, (Format-Bytes $size)) `
        -Detail $SetPath -Started $started
    return $SetPath
}

function New-VssShadowLink {
    <#
        Creates a VSS shadow copy of a volume and exposes it through a
        directory symlink, because DISM cannot capture directly from a
        \\?\GLOBALROOT device path but follows a link to one.

        Returns @{ ShadowId; Link } or $null.
    #>
    param([Parameter(Mandatory)][string]$Volume)   # e.g. 'C:\'

    try {
        Write-Info ('Creating a VSS shadow copy of {0}...' -f $Volume)
        $class  = [wmiclass]'root\cimv2:Win32_ShadowCopy'
        $result = $class.Create($Volume, 'ClientAccessible')

        if ($result.ReturnValue -ne 0) {
            Write-Warn ('VSS shadow creation failed with code {0}.' -f $result.ReturnValue)
            return $null
        }

        $shadow = Get-CimInstance Win32_ShadowCopy -Filter ("ID='{0}'" -f $result.ShadowID) -ErrorAction Stop
        $device = $shadow.DeviceObject

        $link = Join-Path $Script:MountRoot ('shadow_{0}' -f (Get-Date -Format 'HHmmss'))
        if (Test-Path -LiteralPath $link) { & cmd.exe /c rmdir "$link" 2>&1 | Out-Null }

        # The trailing backslash is required: without it the link resolves to the
        # device rather than its root directory and DISM reports an empty source.
        & cmd.exe /c mklink /d "$link" "$device\" 2>&1 | Out-Null
        if (-not (Test-Path -LiteralPath $link)) {
            Write-Warn 'Could not create the shadow copy link.'
            $shadow | Remove-CimInstance -ErrorAction SilentlyContinue
            return $null
        }

        Write-Ok ('Shadow copy ready ({0}).' -f $result.ShadowID)
        return [pscustomobject]@{ ShadowId = $result.ShadowID; Link = $link }
    }
    catch {
        Write-Warn ("VSS shadow copy unavailable: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Remove-VssShadowLink {
    param([object]$Shadow)
    if (-not $Shadow) { return }

    if ($Shadow.Link -and (Test-Path -LiteralPath $Shadow.Link)) {
        & cmd.exe /c rmdir "$($Shadow.Link)" 2>&1 | Out-Null
    }
    try {
        Get-CimInstance Win32_ShadowCopy -Filter ("ID='{0}'" -f $Shadow.ShadowId) -ErrorAction Stop |
            Remove-CimInstance -ErrorAction Stop
        Write-Info 'Shadow copy released.'
    }
    catch { Write-Warn ("Could not release the shadow copy: {0}" -f $_.Exception.Message) }
}

function Invoke-ImageBackup {
    <#
        Captures the target Windows installation to a .wim.

        A WIM is used rather than a file copy because WIM preserves the hard
        links, ACLs and short names that WinSxS depends on, and because the
        resulting file can be re-mounted, serviced with Add-WindowsPackage and
        used directly as a DISM /Source: for RestoreHealth. A plain copy of
        WinSxS satisfies none of those.
    #>
    param([string]$SetPath)

    $started = Get-Date
    Write-Step 'Backing up the component store as a serviceable image'

    $identity = Get-TargetIdentity
    Show-TargetIdentity -Caption 'Store to be captured' | Out-Null

    # --- Determine the capture source -------------------------------------
    $shadow      = $null
    $captureDir  = $null
    $sourceLabel = $Script:Target.Label

    try {
        if ($Script:Target.Kind -eq 'Online') {
            Write-Host ''
            Write-Info 'The running installation must be captured from a snapshot so that files'
            Write-Info 'in use are captured consistently.'

            $shadow = New-VssShadowLink -Volume ($env:SystemDrive + '\')
            if ($shadow) {
                $captureDir = $shadow.Link
            }
            else {
                Write-Warn 'A shadow copy could not be created.'
                Write-Warn 'Capturing a running volume without one will skip locked files, producing'
                Write-Warn 'an image that is NOT reliable as a repair source.'
                if (-not (Confirm-YesNo 'Capture the live volume anyway?' $false)) {
                    Add-SessionAction -Category 'Backup' -Action 'Image backup' -Status 'Declined' `
                        -Result 'Declined after VSS was unavailable' -Started $started
                    return $null
                }
                $captureDir = $env:SystemDrive + '\'
            }
        }
        else {
            $captureDir = $Script:Target.ImagePath
            if (-not (Test-Path -LiteralPath $captureDir)) {
                Write-Err 'The offline image path is not available.'
                return $null
            }
        }

        # --- Destination and space check ----------------------------------
        if (-not $SetPath) { $SetPath = New-BackupSetFolder -Kind 'Image' }
        $wimPath = Join-Path $SetPath 'ComponentStore.wim'

        $sourceSize = $null
        try {
            $winDir = if ($Script:Target.Kind -eq 'Online') { $env:windir } else { $Script:Target.WindowsDir }
            $sourceSize = (Get-ChildItem -LiteralPath (Join-Path $winDir 'WinSxS') -Recurse -File `
                            -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        }
        catch { }

        $free = (Get-Item -LiteralPath $SetPath).PSDrive.Free
        Write-Host ''
        Write-Info ('Destination     : {0}' -f $SetPath)
        Write-Info ('Free space      : {0}' -f (Format-Bytes $free))
        if ($sourceSize) {
            # WinSxS apparent size overstates the real cost because of hard links,
            # and maximum compression typically lands well under it.
            Write-Info ('WinSxS apparent : {0} (hard links make the real figure smaller)' -f (Format-Bytes $sourceSize))
        }
        Write-Info 'A full capture of a Windows installation is commonly 4-9 GB compressed.'

        if ($free -lt 10GB) {
            Write-Warn 'Less than 10 GB is free on the destination. The capture may fail part-way.'
            if (-not (Confirm-YesNo 'Continue anyway?' $false)) {
                Add-SessionAction -Category 'Backup' -Action 'Image backup' -Status 'Declined' `
                    -Result 'Declined at the free-space warning' -Started $started
                return $null
            }
        }

        if (-not (Confirm-YesNo 'Start the capture now? This can take 15-45 minutes.' $true)) {
            Add-SessionAction -Category 'Backup' -Action 'Image backup' -Status 'Declined' `
                -Result 'Declined before capture' -Started $started
            return $null
        }

        # --- Capture -------------------------------------------------------
        $name = '{0} {1} {2}' -f $identity.ProductName, $identity.BuildString, $identity.Architecture
        $desc = 'System OpMan component store backup of {0}, captured {1} (session {2})' -f
                $sourceLabel, (Get-Date).ToString('yyyy-MM-dd HH:mm'), $Script:SessionId

        Write-Info 'Capturing. DISM reports progress slowly; this is normal.'
        $res = Invoke-Dism -NoScope -Arguments @(
            '/Capture-Image',
            ('/ImageFile:{0}' -f $wimPath),
            ('/CaptureDir:{0}' -f $captureDir),
            ('/Name:{0}'  -f $name),
            ('/Description:{0}' -f $desc),
            '/Compress:max',
            '/CheckIntegrity'
        )

        if ($res.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $wimPath)) {
            Write-Err ('Capture failed (dism exit code {0}).' -f $res.ExitCode)
            Add-SessionAction -Category 'Backup' -Action 'Image backup' -Status 'Failed' `
                -Result ('dism exit {0}' -f $res.ExitCode) -Detail $wimPath `
                -Started $started -ExitCode $res.ExitCode
            return $null
        }

        $wimSize = (Get-Item -LiteralPath $wimPath).Length
        Write-Ok ('Image captured: {0} ({1})' -f $wimPath, (Format-Bytes $wimSize))

        Write-BackupManifest -SetPath $SetPath -Kind 'Image' -Identity $identity `
            -SourceLabel $sourceLabel `
            -Files @([pscustomobject]@{ Name = 'ComponentStore.wim'; Purpose = 'Captured Windows installation' }) `
            -Notes ('Serviceable image backup. It can be mounted and updated, and can be used as a ' +
                    'DISM /Source: for RestoreHealth against a matching build, edition and architecture.') | Out-Null

        # A metadata set alongside the image costs little and makes the backup
        # self-describing without having to mount the WIM.
        Invoke-MetadataBackup -SetPath $SetPath | Out-Null

        Add-SessionAction -Category 'Backup' -Action 'Image backup' -Status 'Ok' `
            -Result ('{0} captured' -f (Format-Bytes $wimSize)) -Detail $wimPath `
            -Started $started -ExitCode $res.ExitCode
        return $SetPath
    }
    finally {
        if ($shadow) { Remove-VssShadowLink -Shadow $shadow }
    }
}

function Get-BackupSets {
    <#  Every backup set under the backup root, newest first. #>
    $sets = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Script:BackupRoot)) { return $sets.ToArray() }

    foreach ($dir in (Get-ChildItem -LiteralPath $Script:BackupRoot -Directory -ErrorAction SilentlyContinue)) {
        $mf = Join-Path $dir.FullName 'backup-manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try {
            $m = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
            $wim = Join-Path $dir.FullName 'ComponentStore.wim'
            $size = (Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
            $sets.Add([pscustomobject]@{
                Path        = $dir.FullName
                Name        = $dir.Name
                Kind        = $m.Kind
                Created     = [datetime]$m.CreatedUtc
                Product     = $m.ProductName
                Build       = $m.BuildString
                Edition     = $m.Edition
                Arch        = $m.Architecture
                Source      = $m.SourceLabel
                HasImage    = (Test-Path -LiteralPath $wim)
                WimPath     = $(if (Test-Path -LiteralPath $wim) { $wim } else { $null })
                Size        = $size
                SessionId   = $m.SessionId
            })
        }
        catch { Write-Log ('Unreadable backup manifest in {0}' -f $dir.FullName) 'WARN' }
    }
    return @($sets | Sort-Object Created -Descending)
}

function Show-BackupTable {
    param([AllowEmptyCollection()][object[]]$Sets, [switch]$Numbered)

    if ($Sets.Count -eq 0) { Write-Info 'No backup sets have been created yet.'; return }

    Write-Host ''
    Write-Host ('   {0}{1,-10} {2,-17} {3,-14} {4,-9} {5,-7} {6}' -f
        $(if ($Numbered) { '   # ' } else { '' }),
        'Kind','Created','Build','Arch','Size','Source') -ForegroundColor White
    Write-Host ('   ' + ('-' * 110)) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Sets.Count; $i++) {
        $s = $Sets[$i]
        $row = '{0,-10} {1,-17} {2,-14} {3,-9} {4,-7} {5}' -f
               $(if ($s.HasImage) { 'Image' } else { 'Metadata' }),
               $s.Created.ToLocalTime().ToString('yyyy-MM-dd HH:mm'),
               $s.Build, $s.Arch, (Format-Bytes $s.Size), $s.Source
        if ($Numbered) { Write-Host ('   {0,4} {1}' -f ($i + 1), $row) -ForegroundColor Gray }
        else           { Write-Host ('   {0}' -f $row) -ForegroundColor Gray }
    }
    Write-Host ''
    Write-Info ('{0} backup set(s) in {1}' -f $Sets.Count, $Script:BackupRoot)
}

function Invoke-ListBackups {
    Write-Step 'Backup sets'
    Show-BackupTable -Sets (Get-BackupSets)
}

function Invoke-VerifyBackup {
    <#
        Confirms a backup set is intact: the manifest parses, the declared files
        exist, and any WIM passes a DISM integrity check.
    #>
    Write-Step 'Verify a backup set'
    $sets = Get-BackupSets
    if ($sets.Count -eq 0) { Write-Info 'There are no backup sets to verify.'; return }

    Show-BackupTable -Sets $sets -Numbered
    $pick = Read-Host 'Which backup set (blank to cancel)'
    $idx  = Expand-Selection -Spec $pick -Max $sets.Count
    if ($idx.Count -eq 0) { Write-Info 'Cancelled.'; return }

    $set     = $sets[$idx[0] - 1]
    $started = Get-Date
    $issues  = New-Object System.Collections.Generic.List[string]

    Write-Info ('Verifying {0}' -f $set.Path)

    $mf = Join-Path $set.Path 'backup-manifest.json'
    try {
        $m = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
        foreach ($f in @($m.Files)) {
            $p = Join-Path $set.Path $f.Name
            if (-not (Test-Path -LiteralPath $p)) { $issues.Add("Missing: $($f.Name)") }
        }
        Write-Ok 'Manifest parsed and file list checked.'
    }
    catch { $issues.Add("Manifest unreadable: $($_.Exception.Message)") }

    if ($set.HasImage) {
        Write-Info 'Checking image integrity (this reads the whole WIM)...'
        $res = Invoke-Dism -NoScope -Arguments @(
            '/Get-ImageInfo', ('/ImageFile:{0}' -f $set.WimPath), '/Index:1', '/CheckIntegrity')
        if ($res.ExitCode -ne 0) { $issues.Add("Image integrity check failed (dism exit $($res.ExitCode))") }
        else { Write-Ok 'Image integrity check passed.' }
    }

    Write-Host ''
    if ($issues.Count -eq 0) {
        Write-Ok 'Backup set verified with no issues.'
        Add-SessionAction -Category 'Backup' -Action 'Verify backup' -Status 'Ok' `
            -Result 'No issues' -Detail $set.Path -Started $started
    }
    else {
        foreach ($i in $issues) { Write-Err $i }
        Add-SessionAction -Category 'Backup' -Action 'Verify backup' -Status 'Failed' `
            -Result ('{0} issue(s)' -f $issues.Count) -Detail ($issues -join '; ') -Started $started
    }
}

function Select-BackupAsTarget {
    <#
        Mounts a backup image and makes it the current target, which is what
        allows a backup copy to be brought up to the same build as the online
        store using the normal update workflow.
    #>
    Write-Step 'Open a backup image as the current component store'

    $sets = @(Get-BackupSets | Where-Object { $_.HasImage })
    if ($sets.Count -eq 0) {
        Write-Info 'There are no image backups. Metadata-only sets cannot be mounted.'
        return $null
    }

    Show-BackupTable -Sets $sets -Numbered
    $pick = Read-Host 'Which backup to open (blank to cancel)'
    $idx  = Expand-Selection -Spec $pick -Max $sets.Count
    if ($idx.Count -eq 0) { Write-Info 'Cancelled.'; return $null }

    $set      = $sets[$idx[0] - 1]
    $readOnly = -not (Confirm-YesNo 'Mount read/write so the backup can be updated?' $true)
    $mountDir = Join-Path $Script:MountRoot ('backup_{0}' -f (Get-Date -Format 'HHmmss'))
    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

    Write-Info ('Mounting {0} ...' -f $set.WimPath)
    try {
        if ($readOnly) {
            Mount-WindowsImage -ImagePath $set.WimPath -Index 1 -Path $mountDir -ReadOnly -ErrorAction Stop | Out-Null
        }
        else {
            Mount-WindowsImage -ImagePath $set.WimPath -Index 1 -Path $mountDir -ErrorAction Stop | Out-Null
        }
    }
    catch {
        Write-Err ("Mount failed: {0}" -f $_.Exception.Message)
        Remove-Item -LiteralPath $mountDir -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    Write-Ok 'Backup image mounted.'
    $target = New-Target -Kind 'Image' `
                -Label ('Backup {0} - {1} {2}' -f $set.Created.ToLocalTime().ToString('yyyy-MM-dd HH:mm'),
                                                  $set.Product, $set.Build) `
                -ImagePath $mountDir `
                -WindowsDir (Join-Path $mountDir 'Windows') `
                -WimPath $set.WimPath `
                -Index 1 -Mounted $true -ReadOnly $readOnly

    Add-SessionAction -Category 'Target' -Action 'Opened backup as target' -Status 'Ok' `
        -Result $(if ($readOnly) { 'read-only' } else { 'read/write' }) -Detail $set.Path -Target $target.Label
    return $target
}

function Show-BackupMenu {
    while ($true) {
        Write-Banner 'Component store - backup'
        Write-TargetLine
        Write-Host ''
        Write-Host '   [1] Back up servicing metadata (fast, small, reference only)' -ForegroundColor Gray
        Write-Host '   [2] Back up the component store as a serviceable image (.wim)' -ForegroundColor Gray
        Write-Host '   [3] List backup sets' -ForegroundColor Gray
        Write-Host '   [4] Verify a backup set' -ForegroundColor Gray
        Write-Host '   [5] Open a backup image as the current component store' -ForegroundColor Gray
        Write-Host '   [6] Open the backup folder' -ForegroundColor Gray
        Write-Host '   [0] Back' -ForegroundColor Gray

        switch (Read-Choice -Valid @('0','1','2','3','4','5','6')) {
            '0' { return }
            '1' { Invoke-MetadataBackup | Out-Null; Wait-Key }
            '2' { Invoke-ImageBackup    | Out-Null; Wait-Key }
            '3' { Invoke-ListBackups;   Wait-Key }
            '4' { Invoke-VerifyBackup;  Wait-Key }
            '5' {
                $t = Select-BackupAsTarget
                if ($t) {
                    Close-Target
                    $Script:Target       = $t
                    $Script:LastHealth   = $null
                    $Script:LastAnalysis = $null
                    Register-SessionTarget -TargetObject $t
                    return
                }
                Wait-Key
            }
            '6' { Start-Process explorer.exe $Script:BackupRoot | Out-Null }
        }
    }
}

#endregion

#region ------------------------------------------------------------- Reports

function ConvertTo-HtmlText {
    <#  Minimal HTML escaping; avoids depending on System.Web across editions. #>
    param([Parameter(Position = 0)][AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
}

function Export-Report {
    <#  Writes a CSV and a self-contained HTML report, then offers to open it. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Summary,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows
    )

    $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $csvPath = Join-Path $Script:ReportRoot ('ComponentStore_{0}_{1}.csv'  -f $Name, $stamp)
    $htmPath = Join-Path $Script:ReportRoot ('ComponentStore_{0}_{1}.html' -f $Name, $stamp)

    try { $Rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 }
    catch { Write-Err ("Could not write the CSV: {0}" -f $_.Exception.Message) }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine(('<title>{0}</title>' -f (ConvertTo-HtmlText $Title)))
    [void]$sb.AppendLine(@'
<style>
 :root{color-scheme:light dark}
 body{font:14px/1.5 "Segoe UI",system-ui,sans-serif;margin:0;padding:32px;background:#f6f7f9;color:#14181f}
 h1{font-size:22px;margin:0 0 4px}
 .sub{color:#5b6472;margin-bottom:24px}
 .card{background:#fff;border:1px solid #e3e6ea;border-radius:10px;padding:18px 20px;margin-bottom:22px;
       box-shadow:0 1px 2px rgba(16,24,40,.04)}
 .card h2{font-size:15px;margin:0 0 12px;text-transform:uppercase;letter-spacing:.05em;color:#5b6472}
 dl{display:grid;grid-template-columns:minmax(180px,auto) 1fr;gap:6px 24px;margin:0}
 dt{color:#5b6472}
 dd{margin:0;font-variant-numeric:tabular-nums}
 table{border-collapse:collapse;width:100%;font-size:13px}
 th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #eceef1;vertical-align:top}
 th{background:#f2f4f7;font-weight:600;position:sticky;top:0}
 tbody tr:nth-child(even){background:#fafbfc}
 td{word-break:break-word}
 footer{color:#8a93a0;font-size:12px}
 @media (prefers-color-scheme:dark){
  body{background:#12151a;color:#e6e9ee}
  .card{background:#1a1f27;border-color:#2a313c;box-shadow:none}
  th{background:#222833}
  th,td{border-bottom-color:#2a313c}
  tbody tr:nth-child(even){background:#1d232b}
  .sub,dt,.card h2,footer{color:#9aa4b2}
 }
</style></head><body>
'@)

    [void]$sb.AppendLine(('<h1>{0}</h1>' -f (ConvertTo-HtmlText $Title)))
    [void]$sb.AppendLine(('<div class="sub">Generated {0} by {1} {2}</div>' -f
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'),
        (ConvertTo-HtmlText $Script:AppName), $Script:AppVersion))

    [void]$sb.AppendLine('<div class="card"><h2>Summary</h2><dl>')
    foreach ($k in $Summary.Keys) {
        [void]$sb.AppendLine(('<dt>{0}</dt><dd>{1}</dd>' -f
            (ConvertTo-HtmlText ([string]$k)),
            (ConvertTo-HtmlText ([string]$Summary[$k]))))
    }
    [void]$sb.AppendLine('</dl></div>')

    [void]$sb.AppendLine(('<div class="card"><h2>Detail ({0} rows)</h2>' -f $Rows.Count))
    if ($Rows.Count -gt 0) {
        $cols = $Rows[0].PSObject.Properties.Name
        [void]$sb.Append('<table><thead><tr>')
        foreach ($c in $cols) { [void]$sb.Append(('<th>{0}</th>' -f (ConvertTo-HtmlText $c))) }
        [void]$sb.AppendLine('</tr></thead><tbody>')
        foreach ($row in $Rows) {
            [void]$sb.Append('<tr>')
            foreach ($c in $cols) {
                [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlText ([string]$row.$c))))
            }
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    else { [void]$sb.AppendLine('<p>No rows.</p>') }
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine(('<footer>Log: {0}</footer></body></html>' -f
        (ConvertTo-HtmlText $Script:LogFile)))

    try {
        Set-Content -LiteralPath $htmPath -Value $sb.ToString() -Encoding UTF8
        Write-Ok ('HTML report : {0}' -f $htmPath)
        Write-Ok ('CSV report  : {0}' -f $csvPath)
        if (Confirm-YesNo 'Open the HTML report now?' $true) {
            Start-Process -FilePath $htmPath | Out-Null
        }
    }
    catch { Write-Err ("Could not write the HTML report: {0}" -f $_.Exception.Message) }
}

function Export-SessionReport {
    <#
        Writes a print-oriented summary of the whole sitting: what was worked
        on, every action taken, and how each one turned out.

        The stylesheet carries a print block because this report is meant to be
        handed over or filed: backgrounds are dropped, the palette is forced
        light regardless of the viewer's theme, and rows are kept off page
        breaks.
    #>
    param([switch]$Quiet)

    $ended = Get-Date

    # ToArray() rather than @(...): on PowerShell 7.6 / .NET 10 the array
    # subexpression throws "Argument types do not match" for List[object].
    $actions  = $Script:SessionActions.ToArray()
    $stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $htmPath  = Join-Path $Script:ReportRoot ('Session_{0}_{1}.html' -f $Script:SessionId, $stamp)
    $csvPath  = Join-Path $Script:ReportRoot ('Session_{0}_{1}.csv'  -f $Script:SessionId, $stamp)
    $jsonPath = Join-Path $Script:ReportRoot ('Session_{0}_{1}.json' -f $Script:SessionId, $stamp)

    $counts = [ordered]@{
        Ok       = @($actions | Where-Object { $_.Status -eq 'Ok' }).Count
        Warning  = @($actions | Where-Object { $_.Status -eq 'Warning' }).Count
        Failed   = @($actions | Where-Object { $_.Status -eq 'Failed' }).Count
        Declined = @($actions | Where-Object { $_.Status -eq 'Declined' }).Count
        Info     = @($actions | Where-Object { $_.Status -eq 'Info' }).Count
    }

    try {
        $actions | Select-Object Seq, Time, Category, Action, Target, Status, Result, Detail, Duration, ExitCode |
            Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    }
    catch { Write-Err ("Could not write the session CSV: {0}" -f $_.Exception.Message) }

    try {
        [pscustomobject]@{
            SessionId  = $Script:SessionId
            Computer   = $env:COMPUTERNAME
            User       = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
            Elevated   = (Test-Elevated)
            App        = $Script:AppName
            Version    = $Script:AppVersion
            Started    = $Script:SessionStart.ToString('o')
            Ended      = $ended.ToString('o')
            Stores     = $Script:SessionTargets.ToArray()
            Counts     = $counts
            Actions    = $actions
            LogFile    = $Script:LogFile
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    }
    catch { Write-Err ("Could not write the session JSON: {0}" -f $_.Exception.Message) }

    $duration = $ended - $Script:SessionStart
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine(('<title>Session report {0}</title>' -f (ConvertTo-HtmlText $Script:SessionId)))
    [void]$sb.AppendLine(@'
<style>
 body{font:13px/1.55 "Segoe UI",system-ui,sans-serif;margin:0;padding:28px;background:#f6f7f9;color:#14181f}
 h1{font-size:21px;margin:0 0 2px}
 h2{font-size:14px;margin:0 0 12px;text-transform:uppercase;letter-spacing:.05em;color:#5b6472}
 .sub{color:#5b6472;margin-bottom:22px}
 .card{background:#fff;border:1px solid #e3e6ea;border-radius:10px;padding:16px 20px;margin-bottom:18px}
 dl{display:grid;grid-template-columns:minmax(150px,auto) 1fr;gap:5px 20px;margin:0}
 dt{color:#5b6472}
 dd{margin:0;font-variant-numeric:tabular-nums}
 table{border-collapse:collapse;width:100%;font-size:12px}
 th,td{text-align:left;padding:6px 9px;border-bottom:1px solid #eceef1;vertical-align:top}
 th{background:#f2f4f7;font-weight:600}
 td.num{font-variant-numeric:tabular-nums;white-space:nowrap}
 .tally{display:flex;gap:10px;flex-wrap:wrap;margin:0}
 .pill{border-radius:20px;padding:5px 14px;font-weight:600;font-size:12px;border:1px solid}
 .ok{background:#e8f6ed;color:#1b6b3a;border-color:#b7e0c5}
 .warn{background:#fdf4e3;color:#8a5a00;border-color:#f0dcae}
 .fail{background:#fdecec;color:#a11c1c;border-color:#f3c3c3}
 .decl{background:#eef1f5;color:#4a5361;border-color:#d7dce3}
 .info{background:#eaf1fb;color:#1e4e8c;border-color:#c5d8f2}
 .s-Ok{color:#1b6b3a;font-weight:600}
 .s-Warning{color:#8a5a00;font-weight:600}
 .s-Failed{color:#a11c1c;font-weight:600}
 .s-Declined{color:#4a5361}
 .s-Info{color:#1e4e8c}
 .sign{margin-top:26px;display:grid;grid-template-columns:1fr 1fr;gap:34px}
 .sign div{border-top:1px solid #9aa4b2;padding-top:6px;color:#5b6472;font-size:12px}
 footer{color:#8a93a0;font-size:11px;margin-top:20px}

 @media print{
  /* Force the light palette: a dark background wastes toner and the status
     colours stop being legible once the browser drops backgrounds. */
  body{background:#fff;padding:0;font-size:11.5px}
  .card{border:1px solid #ccc;border-radius:0;box-shadow:none;page-break-inside:avoid;margin-bottom:12px}
  h1{font-size:18px}
  table{font-size:10.5px}
  thead{display:table-header-group}
  tr{page-break-inside:avoid}
  .pill{border:1px solid #999;background:#fff !important;color:#000 !important}
  .no-print{display:none}
  @page{margin:14mm}
 }
</style></head><body>
'@)

    [void]$sb.AppendLine(('<h1>Component store session report</h1>'))
    [void]$sb.AppendLine(('<div class="sub">Session {0} &middot; generated {1} by {2} {3}</div>' -f
        (ConvertTo-HtmlText $Script:SessionId), $ended.ToString('yyyy-MM-dd HH:mm:ss'),
        (ConvertTo-HtmlText $Script:AppName), $Script:AppVersion))

    # --- Session identity --------------------------------------------------
    [void]$sb.AppendLine('<div class="card"><h2>Session</h2><dl>')
    $identityRows = [ordered]@{
        'Computer'    = $env:COMPUTERNAME
        'Technician'  = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        'Elevated'    = $(if (Test-Elevated) { 'Yes' } else { 'No' })
        'Started'     = $Script:SessionStart.ToString('yyyy-MM-dd HH:mm:ss')
        'Ended'       = $ended.ToString('yyyy-MM-dd HH:mm:ss')
        'Duration'    = ('{0:hh\:mm\:ss}' -f $duration)
        'Actions'     = $actions.Count
        'Log file'    = $Script:LogFile
    }
    foreach ($k in $identityRows.Keys) {
        [void]$sb.AppendLine(('<dt>{0}</dt><dd>{1}</dd>' -f
            (ConvertTo-HtmlText $k), (ConvertTo-HtmlText ([string]$identityRows[$k]))))
    }
    [void]$sb.AppendLine('</dl></div>')

    # --- Outcome tally -----------------------------------------------------
    [void]$sb.AppendLine('<div class="card"><h2>Outcomes</h2><div class="tally">')
    $pillClass = @{ Ok='ok'; Warning='warn'; Failed='fail'; Declined='decl'; Info='info' }
    foreach ($k in $counts.Keys) {
        [void]$sb.AppendLine(('<span class="pill {0}">{1}: {2}</span>' -f
            $pillClass[$k], $k, $counts[$k]))
    }
    [void]$sb.AppendLine('</div></div>')

    # --- Stores worked on --------------------------------------------------
    [void]$sb.AppendLine('<div class="card"><h2>Component stores in this session</h2>')
    if ($Script:SessionTargets.Count -gt 0) {
        [void]$sb.AppendLine('<table><thead><tr><th>Store</th><th>Kind</th><th>Product</th>' +
                             '<th>Build</th><th>Edition</th><th>Arch</th><th>Path</th></tr></thead><tbody>')
        foreach ($t in $Script:SessionTargets) {
            # The whole -f expression must sit inside one set of parentheses:
            # within a method call's argument list PowerShell treats commas as
            # argument separators, not as the -f operator's argument array.
            $row = ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td class="num">{3}</td>' +
                    '<td>{4}</td><td>{5}</td><td>{6}</td></tr>') -f
                    (ConvertTo-HtmlText $t.Label), (ConvertTo-HtmlText $t.Kind),
                    (ConvertTo-HtmlText $t.Product), (ConvertTo-HtmlText $t.Build),
                    (ConvertTo-HtmlText $t.Edition), (ConvertTo-HtmlText $t.Arch),
                    (ConvertTo-HtmlText ([string]$t.ImagePath))
            [void]$sb.AppendLine($row)
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    else { [void]$sb.AppendLine('<p>No component store was selected.</p>') }
    [void]$sb.AppendLine('</div>')

    # --- Health ------------------------------------------------------------
    if ($Script:LastHealth) {
        [void]$sb.AppendLine('<div class="card"><h2>Last recorded health</h2><dl>')
        [void]$sb.AppendLine(('<dt>State</dt><dd>{0}</dd>' -f (ConvertTo-HtmlText ([string]$Script:LastHealth.State))))
        if ($Script:LastHealth.PSObject.Properties.Name -contains 'Detail') {
            [void]$sb.AppendLine(('<dt>Detail</dt><dd>{0}</dd>' -f
                (ConvertTo-HtmlText ([string]$Script:LastHealth.Detail))))
        }
        [void]$sb.AppendLine('</dl></div>')
    }

    # --- Timeline ----------------------------------------------------------
    [void]$sb.AppendLine(('<div class="card"><h2>Activity ({0} actions)</h2>' -f $actions.Count))
    if ($actions.Count -gt 0) {
        [void]$sb.AppendLine('<table><thead><tr><th>#</th><th>Time</th><th>Area</th><th>Action</th>' +
                             '<th>Store</th><th>Status</th><th>Result</th><th>Detail</th><th>Sec</th>' +
                             '</tr></thead><tbody>')
        foreach ($a in $actions) {
            $row = ('<tr><td class="num">{0}</td><td class="num">{1}</td><td>{2}</td><td>{3}</td>' +
                    '<td>{4}</td><td class="s-{5}">{5}</td><td>{6}</td><td>{7}</td>' +
                    '<td class="num">{8}</td></tr>') -f
                    $a.Seq,
                    $a.Time.ToString('HH:mm:ss'),
                    (ConvertTo-HtmlText $a.Category),
                    (ConvertTo-HtmlText $a.Action),
                    (ConvertTo-HtmlText $a.Target),
                    (ConvertTo-HtmlText $a.Status),
                    (ConvertTo-HtmlText $a.Result),
                    (ConvertTo-HtmlText $a.Detail),
                    (ConvertTo-HtmlText ([string]$a.Duration))
            [void]$sb.AppendLine($row)
        }
        [void]$sb.AppendLine('</tbody></table>')
    }
    else { [void]$sb.AppendLine('<p>No actions were recorded during this session.</p>') }
    [void]$sb.AppendLine('</div>')

    # --- Problems ----------------------------------------------------------
    $problems = @($actions | Where-Object { $_.Status -in @('Failed','Warning') })
    if ($problems.Count -gt 0) {
        [void]$sb.AppendLine(('<div class="card"><h2>Failures and warnings ({0})</h2>' -f $problems.Count))
        [void]$sb.AppendLine('<table><thead><tr><th>#</th><th>Action</th><th>Status</th>' +
                             '<th>Result</th><th>Detail</th></tr></thead><tbody>')
        foreach ($p in $problems) {
            $row = ('<tr><td class="num">{0}</td><td>{1}</td><td class="s-{2}">{2}</td>' +
                    '<td>{3}</td><td>{4}</td></tr>') -f
                    $p.Seq, (ConvertTo-HtmlText $p.Action), (ConvertTo-HtmlText $p.Status),
                    (ConvertTo-HtmlText $p.Result), (ConvertTo-HtmlText $p.Detail)
            [void]$sb.AppendLine($row)
        }
        [void]$sb.AppendLine('</tbody></table></div>')
    }

    # --- Sign-off ----------------------------------------------------------
    [void]$sb.AppendLine('<div class="card"><h2>Sign-off</h2><div class="sign">')
    [void]$sb.AppendLine('<div>Technician &mdash; name, signature, date</div>')
    [void]$sb.AppendLine('<div>Reviewed by &mdash; name, signature, date</div>')
    [void]$sb.AppendLine('</div></div>')

    [void]$sb.AppendLine(('<footer>Session {0} &middot; log {1}</footer></body></html>' -f
        (ConvertTo-HtmlText $Script:SessionId), (ConvertTo-HtmlText $Script:LogFile)))

    try {
        Set-Content -LiteralPath $htmPath -Value $sb.ToString() -Encoding UTF8
        Write-Ok ('Session report : {0}' -f $htmPath)
        Write-Ok ('Session CSV    : {0}' -f $csvPath)
        Write-Ok ('Session JSON   : {0}' -f $jsonPath)
        $Script:SessionReportWritten = $true

        if (-not $Quiet -and (Confirm-YesNo 'Open the session report now?' $true)) {
            Start-Process -FilePath $htmPath | Out-Null
        }
    }
    catch { Write-Err ("Could not write the session report: {0}" -f $_.Exception.Message) }

    return $htmPath
}

#endregion

#region ----------------------------------------------------------- Main menu

function Show-MainMenu {
    while ($true) {
        Write-Banner "$Script:AppName $Script:AppVersion"
        Write-TargetLine
        if ($Script:LastHealth) {
            $c = switch ($Script:LastHealth.State) {
                'Healthy'      { 'Green' }
                'Repaired'     { 'Green' }
                'Repairable'   { 'Yellow' }
                'Unrepairable' { 'Red' }
                default        { 'DarkGray' }
            }
            Write-Host ('  Health : {0}' -f $Script:LastHealth.State) -ForegroundColor $c
        }

        if ($Script:SessionActions.Count -gt 0) {
            Write-Host ('  Session: {0}   {1} action(s)' -f
                $Script:SessionId, $Script:SessionActions.Count) -ForegroundColor DarkGray
        }

        Write-Host ''
        Write-Host '   [1] Manage component store health' -ForegroundColor Gray
        Write-Host '   [2] Manage component store drivers' -ForegroundColor Gray
        Write-Host '   [3] Manage component store updates' -ForegroundColor Gray
        Write-Host '   [4] Analyze component store information' -ForegroundColor Gray
        Write-Host '   [5] Back up / restore the component store' -ForegroundColor Gray
        Write-Host '   [6] Change the selected component store' -ForegroundColor Gray
        Write-Host '   [7] Create the session report' -ForegroundColor Gray
        Write-Host ('   [8] Open the working folder ({0})' -f $Script:WorkRoot) -ForegroundColor Gray
        Write-Host '   [0] Exit' -ForegroundColor Gray

        switch (Read-Choice -Valid @('0','1','2','3','4','5','6','7','8')) {
            '0' { return }
            '1' { Show-HealthMenu }
            '2' { Show-DriversMenu }
            '3' { Show-UpdatesMenu }
            '4' { Show-AnalyzeMenu }
            '5' { Show-BackupMenu }
            '6' {
                $new = Select-Target -AllowCancel
                if ($new) {
                    Close-Target
                    $Script:Target      = $new
                    $Script:LastHealth  = $null
                    $Script:LastAnalysis = $null
                    Register-SessionTarget -TargetObject $new
                    Add-SessionAction -Category 'Target' -Action 'Changed component store' `
                        -Status 'Info' -Result $new.Label -Target $new.Label | Out-Null
                }
            }
            '7' { Export-SessionReport | Out-Null; Wait-Key }
            '8' { Start-Process explorer.exe $Script:WorkRoot | Out-Null }
        }
    }
}

function Test-StaleMounts {
    try { $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop) } catch { return }
    $stale = @($mounted | Where-Object { $_.MountStatus -ne 'Ok' })
    if ($stale.Count -eq 0) { return }

    Write-Warn ('{0} stale image mount point(s) were found.' -f $stale.Count)
    foreach ($m in $stale) { Write-Info ('  {0}  ({1})' -f $m.Path, $m.MountStatus) }
    if (Confirm-YesNo 'Clean them up now (dism /Cleanup-Mountpoints)?' $true) {
        & dism.exe /English /Cleanup-Mountpoints 2>&1 | ForEach-Object { Write-Log ([string]$_) 'RAW' }
        Write-Ok 'Mount points cleaned up.'
    }
}

function Start-App {
    $host.UI.RawUI.WindowTitle = "$Script:AppName $Script:AppVersion"
    Write-Banner "$Script:AppName $Script:AppVersion"
    Write-Info ('Log file: {0}' -f $Script:LogFile)

    if (-not (Assert-Elevated)) { Wait-Key 'Press Enter to close'; return }

    if (-not (Get-Command dism.exe -ErrorAction SilentlyContinue)) {
        Write-Err 'dism.exe was not found on this system.'
        Wait-Key 'Press Enter to close'; return
    }
    if (-not (Get-Module -ListAvailable -Name Dism)) {
        Write-Warn 'The Dism PowerShell module is unavailable; ISO servicing and reports will be limited.'
    }

    Test-StaleMounts

    Write-Info ('Session : {0}' -f $Script:SessionId)

    try {
        $Script:Target = Select-Target
        if (-not $Script:Target) { Write-Info 'No component store selected. Exiting.'; return }

        Register-SessionTarget -TargetObject $Script:Target
        Add-SessionAction -Category 'Session' -Action 'Session started' -Status 'Info' `
            -Result ('{0} {1}' -f $Script:AppName, $Script:AppVersion) `
            -Detail ('{0}\{1} on {2}' -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME) | Out-Null

        Show-MainMenu
    }
    finally {
        Close-Target

        # The report is offered rather than forced: a technician who opened the
        # tool to look at one value does not need a filed document for it.
        if ($Script:SessionActions.Count -gt 1 -and -not $Script:SessionReportWritten) {
            Write-Host ''
            Add-SessionAction -Category 'Session' -Action 'Session ended' -Status 'Info' `
                -Result ('{0} action(s)' -f $Script:SessionActions.Count) | Out-Null

            if (Confirm-YesNo 'Create a printable report of everything done in this session?' $true) {
                Export-SessionReport | Out-Null
            }
        }

        Write-Host ''
        Write-Info ('Session log saved to {0}' -f $Script:LogFile)
        Write-Host ''
    }
}

Start-App

#endregion
