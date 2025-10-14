# Requires: Windows + Outlook desktop client
# PowerShell 7.5+ compatible (also works in Windows PowerShell 5.1)
function Invoke-OutlookSendHealth {
<#
.SYNOPSIS
2025-10-14 | Project: ToolkIT | Func#: 002 | Category: Outlook (Code: 412) | Subcategory: SendHealth (Code: 137)
Version: 0.1
Purpose: Analyze messages queued in Outlook (Drafts/Outbox) and flag common issues that can prevent sending (e.g., unresolved recipients, scheduled send "Do Not Deliver Before", oversized/blocked attachments, offline mode).
#>
    [CmdletBinding()]
    param(
        # Max total message size before flagging (MB). Many small-business mail systems use 20–25 MB limits.
        [int]$MaxSizeMB = 25,

        # Attachment extensions likely to be blocked by servers/security policies
        [string[]]$BlockedAttachmentExtensions = @('.exe','.js','.vbs','.jar','.bat','.cmd','.msi','.ps1','.vbe','.scr','.com','.cpl','.reg','.wsf','.wsh'),

        # If true, try to resolve recipients automatically to see if Outlook can match directories/contacts
        [switch]$ResolveRecipients,

        # Folders to scan (default scans Outbox and Drafts)
        [string[]]$Folders = @('Outbox','Drafts')
    )

    begin {
        # Helper: Safely get SMTP address from a Recipient/AddressEntry
        function Get-SmtpAddress {
            param([object]$Recipient)
            try {
                if ($null -eq $Recipient) { return $null }
                $ae = $Recipient.AddressEntry
                if ($null -eq $ae) { return $Recipient.Address }

                # For Exchange users
                $xuser = $ae.GetExchangeUser()
                if ($xuser) { return $xuser.PrimarySmtpAddress }

                # For Exchange distribution list
                $xdl = $ae.GetExchangeDistributionList()
                if ($xdl) { return $xdl.PrimarySmtpAddress }

                # Fallback to MAPI PR_SMTP_ADDRESS (0x39FE001E)
                $pa = $ae.PropertyAccessor
                $smtpProp = "http://schemas.microsoft.com/mapi/proptag/0x39FE001E"
                $smtp = $pa.GetProperty($smtpProp)
                if ($smtp) { return [string]$smtp }

                # Last resort
                return [string]$Recipient.Address
            } catch { return $Recipient.Address }
        }

        function Test-EmailFormat {
            param([string]$Address)
            if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
            # Basic RFC5322-ish pattern (good enough for validation here, not perfect)
            $pattern = '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
            return [bool]([System.Text.RegularExpressions.Regex]::IsMatch($Address, $pattern, 'IgnoreCase'))
        }

        function Get-AttachmentSizeBytes {
            param([object]$Attachment)
            try {
                # PR_ATTACH_SIZE (0x0E200003) in bytes via PropertyAccessor
                $pa = $Attachment.PropertyAccessor
                $sizeProp = "http://schemas.microsoft.com/mapi/proptag/0x0E200003"
                $sz = $pa.GetProperty($sizeProp)
                if ($sz -is [int]) { return [int64]$sz }
            } catch {}
            return $null # if not available
        }

        function New-Issue {
            param(
                [string]$Type,      # e.g., Recipients, Size, Attachments, Schedule, ClientState
                [string]$Severity,  # Info, Warning, Error
                [string]$Message
            )
            [pscustomobject]@{ Type=$Type; Severity=$Severity; Message=$Message }
        }
    }

    process {
        # Spin up Outlook interop
        try {
            $outlook = [Runtime.InteropServices.Marshal]::GetActiveObject('Outlook.Application')
        } catch {
            try { $outlook = New-Object -ComObject Outlook.Application }
            catch {
                Write-Warning "Outlook is not installed or cannot be automated on this system."
                return
            }
        }

        $session = $outlook.Session
        if ($null -eq $session) {
            Write-Warning "Unable to access Outlook MAPI session."
            return
        }

        # High-level client state checks
        $issues = @()
        try {
            if ($session.Offline -eq $true) {
                $issues += (New-Issue -Type 'ClientState' -Severity 'Error' -Message 'Outlook is in Work Offline mode. Messages will not send until you go online.')
            }
        } catch {}

        # Collect per-item checks
        $report = @()
        $now = Get-Date
        $maxBytes = [int64]$MaxSizeMB * 1MB

        foreach ($folderName in $Folders) {
            try {
                $folder = $session.GetDefaultFolder([Microsoft.Office.Interop.Outlook.OlDefaultFolders]::$folderName)
            } catch {
                # Fallback by numeric constants (in case the enum is not available)
                switch -Regex ($folderName) {
                    '^Outbox$'  { $folder = $session.GetDefaultFolder(4) }   # olFolderOutbox = 4
                    '^Drafts$'  { $folder = $session.GetDefaultFolder(16) }  # olFolderDrafts = 16
                    default     { $folder = $null }
                }
            }

            if ($null -eq $folder) { continue }

            foreach ($item in @($folder.Items)) {
                # Only care about actual MailItem (Class 43). Others like Reports/Meetings are ignored.
                $class = $null
                try { $class = $item.Class } catch {}
                if ($class -ne 43) { continue }

                $mail = $item
                $itemIssues = @()

                # --- Recipients ---
                $recipCount = 0
                $recipResolved = $true
                $recipEmails = @()

                try {
                    $recipCount = $mail.Recipients.Count
                    if ($ResolveRecipients) { $null = $mail.Recipients.ResolveAll() }
                    for ($i=1; $i -le $mail.Recipients.Count; $i++) {
                        $r = $mail.Recipients.Item($i)
                        $addr = Get-SmtpAddress -Recipient $r
                        $recipEmails += $addr
                        if (-not $r.Resolved) { $recipResolved = $false }
                        elseif (-not (Test-EmailFormat $addr)) { $recipResolved = $false }
                    }
                } catch {}

                if ($recipCount -eq 0) {
                    $itemIssues += (New-Issue -Type 'Recipients' -Severity 'Error' -Message 'No recipients in To/CC/BCC.')
                } elseif (-not $recipResolved) {
                    $itemIssues += (New-Issue -Type 'Recipients' -Severity 'Error' -Message "One or more recipients are unresolved or invalid: $([string]::Join(', ', $recipEmails))")
                }

                # --- Subject ---
                try {
                    if ([string]::IsNullOrWhiteSpace($mail.Subject)) {
                        $itemIssues += (New-Issue -Type 'Content' -Severity 'Warning' -Message 'Subject is empty. Some org policies may block or flag blank-subject messages.')
                    }
                } catch {}

                # --- Scheduled Send (Do Not Deliver Before) ---
                try {
                    if ($mail.DeferredDeliveryTime -and $mail.DeferredDeliveryTime -gt $now) {
                        $when = $mail.DeferredDeliveryTime.ToString('yyyy-MM-dd HH:mm')
                        $itemIssues += (New-Issue -Type 'Schedule' -Severity 'Info' -Message "Scheduled to send later (Do Not Deliver Before): $when")
                    }
                } catch {}

                # --- Size / Attachments ---
                $totalSize = $null
                try { $totalSize = [int64]$mail.Size } catch {}

                if ($totalSize -and $totalSize -gt $maxBytes) {
                    $itemIssues += (New-Issue -Type 'Size' -Severity 'Error' -Message ("Message size {0:N1} MB exceeds limit of {1} MB." -f ($totalSize/1MB), $MaxSizeMB))
                }

                # Attachment checks
                try {
                    if ($mail.Attachments.Count -gt 0) {
                        $blocked = @()
                        $largeAtt = $false
                        for ($a=1; $a -le $mail.Attachments.Count; $a++) {
                            $att = $mail.Attachments.Item($a)
                            $name = [string]$att.FileName
                            $ext = [System.IO.Path]::GetExtension($name)
                            if ($BlockedAttachmentExtensions -contains ($ext.ToLowerInvariant())) {
                                $blocked += $name
                            }
                            $asz = Get-AttachmentSizeBytes -Attachment $att
                            if ($asz -and $asz -gt $maxBytes) { $largeAtt = $true }
                        }
                        if ($blocked.Count -gt 0) {
                            $itemIssues += (New-Issue -Type 'Attachments' -Severity 'Warning' -Message ("Likely blocked attachment types: {0}" -f ($blocked -join ', ')))
                        }
                        if ($largeAtt) {
                            $itemIssues += (New-Issue -Type 'Attachments' -Severity 'Error' -Message ("At least one attachment exceeds the {0} MB limit." -f $MaxSizeMB))
                        }
                    }
                } catch {}

                # --- Importance: Not blocking, but flag if Low importance with blank subject
                try {
                    if (([string]::IsNullOrWhiteSpace($mail.Subject)) -and $mail.Importance -eq 0) { # olImportanceLow
                        $itemIssues += (New-Issue -Type 'Content' -Severity 'Info' -Message 'Low importance + blank subject — consider adding a subject to avoid filters.')
                    }
                } catch {}

                # Summarize
                $report += [pscustomobject]@{
                    Folder            = $folder.Name
                    Subject           = try { $mail.Subject } catch { '' }
                    To                = ($recipEmails -join '; ')
                    TotalSizeMB       = if ($totalSize) { [math]::Round($totalSize/1MB,1) } else { $null }
                    HasAttachments    = try { [bool]($mail.Attachments.Count -gt 0) } catch { $false }
                    ScheduledSendTime = try { if ($mail.DeferredDeliveryTime -and $mail.DeferredDeliveryTime -gt [datetime]::MinValue) { $mail.DeferredDeliveryTime } else { $null } } catch { $null }
                    Issues            = $itemIssues
                }
            }
        }

        # Output
        $summary = [pscustomobject]@{
            Timestamp    = (Get-Date)
            ClientOffline = try { [bool]$session.Offline } catch { $null }
            HighLevelIssues = $issues
            ItemsAnalyzed  = $report.Count
            ItemsWithIssues = ($report | Where-Object { $_.Issues.Count -gt 0 }).Count
        }

        # Write a human-friendly view first
        Write-Host "=== Outlook Send Health ===" -ForegroundColor Cyan
        if ($summary.ClientOffline -eq $true) {
            Write-Host "Client: OFFLINE (Work Offline is enabled)" -ForegroundColor Red
        } else {
            Write-Host "Client: ONLINE" -ForegroundColor Green
        }
        Write-Host ("Items analyzed: {0} | Items with issues: {1}" -f $summary.ItemsAnalyzed, $summary.ItemsWithIssues)

        foreach ($r in $report) {
            Write-Host ("`n[{0}] Subject: {1}" -f $r.Folder, ($r.Subject ?? '(no subject)')) -ForegroundColor Yellow
            if ($r.ScheduledSendTime) {
                Write-Host ("  Scheduled: {0}" -f $r.ScheduledSendTime)
            }
            if ($r.TotalSizeMB) {
                Write-Host ("  Size: {0} MB" -f $r.TotalSizeMB)
            }
            if ($r.To) {
                Write-Host ("  To: {0}" -f $r.To)
            }
            if ($r.Issues.Count -gt 0) {
                foreach ($i in $r.Issues) {
                    $color = switch ($i.Severity) { 'Error' {'Red'} 'Warning' {'DarkYellow'} default {'Gray'} }
                    Write-Host ("  - [{0}] {1}: {2}" -f $i.Severity, $i.Type, $i.Message) -ForegroundColor $color
                }
            } else {
                Write-Host "  - No obvious blocking issues detected." -ForegroundColor Green
            }
        }

        # Emit structured objects last for scripting/CI use
        $summary
        $report
    }
}

<# HOW TO USE
1) Close and re-open Outlook to ensure it is running under your profile, or make sure it is already open.
2) Open PowerShell (7.5+ recommended) as your Windows user.
3) Import the function into your session:
   . .\Invoke-OutlookSendHealth.ps1
4) Run:
   Invoke-OutlookSendHealth
   # Optional parameters:
   Invoke-OutlookSendHealth -MaxSizeMB 20 -ResolveRecipients
   Invoke-OutlookSendHealth -Folders @('Outbox','Drafts','Inbox')  # if you want to scan Inbox drafts too
#>
