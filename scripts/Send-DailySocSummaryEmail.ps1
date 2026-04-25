<#
.SYNOPSIS
Generates and optionally sends the daily SOC summary email.

.DESCRIPTION
Builds the summary body by invoking Invoke-DailySocSummary.ps1 in Markdown or
HTML mode, then either previews the result or sends it through an SMTP relay.
This keeps automated digest delivery optional and avoids adding another always-on
Azure service to the repo.
#>

[CmdletBinding()]
param(
    [string]$WorkspaceId,
    [string]$HighSeverityInputPath,
    [string]$AuthenticationInputPath,
    [string]$ServiceHealthInputPath,
    [ValidateSet('Markdown', 'Html')]
    [string]$BodyFormat = 'Markdown',
    [string]$ReportTitle = 'Daily SOC Summary',
    [string]$Subject,
    [string[]]$To,
    [string]$From,
    [string]$SmtpServer,
    [int]$SmtpPort = 587,
    [bool]$UseSsl = $true,
    [pscredential]$SmtpCredential,
    [switch]$PreviewOnly
)

$ErrorActionPreference = 'Stop'

if (
    $null -eq $SmtpCredential -and
    -not [string]::IsNullOrWhiteSpace($env:KQL_DIGEST_SMTP_USERNAME) -and
    -not [string]::IsNullOrWhiteSpace($env:KQL_DIGEST_SMTP_PASSWORD)
) {
    $SmtpCredential = [pscredential]::new(
        $env:KQL_DIGEST_SMTP_USERNAME,
        (ConvertTo-SecureString $env:KQL_DIGEST_SMTP_PASSWORD -AsPlainText -Force)
    )
}

function Get-RequiredValue {
    param(
        [string]$Value,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Parameter '$Name' is required unless -PreviewOnly is used."
    }

    return $Value
}

function New-MessageBody {
    param(
        [string]$DigestScriptPath,
        [string]$WorkspaceId,
        [string]$HighSeverityInputPath,
        [string]$AuthenticationInputPath,
        [string]$ServiceHealthInputPath,
        [string]$BodyFormat,
        [string]$ReportTitle
    )

    $outputFormat = if ($BodyFormat -eq 'Html') { 'Html' } else { 'Markdown' }
    $scriptParameters = @{
        OutputFormat = $outputFormat
        ReportTitle = $ReportTitle
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
        $scriptParameters.WorkspaceId = $WorkspaceId
    }
    if (-not [string]::IsNullOrWhiteSpace($HighSeverityInputPath)) {
        $scriptParameters.HighSeverityInputPath = $HighSeverityInputPath
    }
    if (-not [string]::IsNullOrWhiteSpace($AuthenticationInputPath)) {
        $scriptParameters.AuthenticationInputPath = $AuthenticationInputPath
    }
    if (-not [string]::IsNullOrWhiteSpace($ServiceHealthInputPath)) {
        $scriptParameters.ServiceHealthInputPath = $ServiceHealthInputPath
    }

    return (& $DigestScriptPath @scriptParameters | Out-String).Trim()
}

function Send-SmtpDigest {
    param(
        [string]$Subject,
        [string[]]$To,
        [string]$From,
        [string]$Body,
        [bool]$IsBodyHtml,
        [string]$SmtpServer,
        [int]$SmtpPort,
        [bool]$UseSsl,
        [pscredential]$SmtpCredential
    )

    $mailMessage = [System.Net.Mail.MailMessage]::new()
    try {
        $mailMessage.From = [System.Net.Mail.MailAddress]::new($From)
        foreach ($recipient in $To) {
            if (-not [string]::IsNullOrWhiteSpace($recipient)) {
                $mailMessage.To.Add($recipient)
            }
        }

        $mailMessage.Subject = $Subject
        $mailMessage.Body = $Body
        $mailMessage.IsBodyHtml = $IsBodyHtml
        $mailMessage.BodyEncoding = [System.Text.Encoding]::UTF8
        $mailMessage.SubjectEncoding = [System.Text.Encoding]::UTF8

        $smtpClient = [System.Net.Mail.SmtpClient]::new($SmtpServer, $SmtpPort)
        try {
            $smtpClient.EnableSsl = $UseSsl
            $smtpClient.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network

            if ($null -ne $SmtpCredential) {
                $smtpClient.Credentials = $SmtpCredential
            }

            $smtpClient.Send($mailMessage)
        }
        finally {
            $smtpClient.Dispose()
        }
    }
    finally {
        $mailMessage.Dispose()
    }
}

$digestScriptPath = Join-Path $PSScriptRoot 'Invoke-DailySocSummary.ps1'
$subjectLine = if ([string]::IsNullOrWhiteSpace($Subject)) {
    "$ReportTitle - $(Get-Date -Format 'yyyy-MM-dd')"
}
else {
    $Subject
}

$messageBody = New-MessageBody `
    -DigestScriptPath $digestScriptPath `
    -WorkspaceId $WorkspaceId `
    -HighSeverityInputPath $HighSeverityInputPath `
    -AuthenticationInputPath $AuthenticationInputPath `
    -ServiceHealthInputPath $ServiceHealthInputPath `
    -BodyFormat $BodyFormat `
    -ReportTitle $ReportTitle

if ($PreviewOnly) {
    [pscustomobject]@{
        Subject = $subjectLine
        BodyFormat = $BodyFormat
        Recipients = @($To)
        Body = $messageBody
    } | ConvertTo-Json -Depth 4
    return
}

$resolvedFrom = if ([string]::IsNullOrWhiteSpace($From)) {
    if (-not [string]::IsNullOrWhiteSpace($env:KQL_DIGEST_EMAIL_FROM)) {
        $env:KQL_DIGEST_EMAIL_FROM
    }
    elseif ($null -ne $SmtpCredential) {
        $SmtpCredential.UserName
    }
    else {
        ''
    }
}

$resolvedRecipients = if ($null -ne $To -and $To.Count -gt 0) {
    $To
}
elseif (-not [string]::IsNullOrWhiteSpace($env:KQL_DIGEST_EMAIL_TO)) {
    @($env:KQL_DIGEST_EMAIL_TO -split ';|,')
}
else {
    @()
}

$resolvedServer = if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
    $env:KQL_DIGEST_SMTP_SERVER
}
else {
    $SmtpServer
}

$resolvedFrom = Get-RequiredValue -Value $resolvedFrom -Name 'From'
$resolvedServer = Get-RequiredValue -Value $resolvedServer -Name 'SmtpServer'
if ($resolvedRecipients.Count -eq 0) {
    throw "Parameter 'To' is required unless KQL_DIGEST_EMAIL_TO is configured."
}

Send-SmtpDigest `
    -Subject $subjectLine `
    -To $resolvedRecipients `
    -From $resolvedFrom `
    -Body $messageBody `
    -IsBodyHtml ($BodyFormat -eq 'Html') `
    -SmtpServer $resolvedServer `
    -SmtpPort $SmtpPort `
    -UseSsl $UseSsl `
    -SmtpCredential $SmtpCredential

Write-Information "Sent daily SOC summary to $($resolvedRecipients -join ', ')" -InformationAction Continue