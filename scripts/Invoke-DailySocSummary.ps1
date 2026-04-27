<#
.SYNOPSIS
Generates a daily SOC-style summary from the KQL incident-response signal families.

.DESCRIPTION
Runs the repo-managed daily summary KQL queries against a Log Analytics workspace,
or consumes pre-exported JSON payloads for offline validation. The script renders
HTML, Markdown, or JSON so the summary can be viewed as a dashboard artifact or
used as a digest body for email or Teams automation.
#>

param(
    [string]$WorkspaceId,
    [string]$HighSeverityInputPath,
    [string]$AuthenticationInputPath,
    [string]$ServiceHealthInputPath,
    [ValidateSet('Html', 'Markdown', 'Json')]
    [string]$OutputFormat = 'Html',
    [string]$OutputPath,
    [string]$ReportTitle = 'Daily SOC Summary'
)

$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    return Split-Path -Parent $PSScriptRoot
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = ''
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

function Get-NumericPropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    $value = Get-PropertyValue -Object $Object -Name $Name -DefaultValue 0
    try {
        return [double]$value
    }
    catch {
        return 0
    }
}

function Format-DeltaText {
    param(
        [double]$Delta,
        [double]$DeltaPercent
    )

    $deltaLabel = if ($Delta -gt 0) {
        "+$([int]$Delta)"
    }
    elseif ($Delta -lt 0) {
        [string]([int]$Delta)
    }
    else {
        '0'
    }

    if ([double]::IsNaN($DeltaPercent)) {
        return "$deltaLabel (n/a versus previous period)"
    }

    return "$deltaLabel ($([math]::Round($DeltaPercent, 2))%)"
}

function Format-Timestamp {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 'n/a'
    }

    try {
        return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + ' UTC'
    }
    catch {
        return [string]$Value
    }
}

function Escape-Html {
    param([string]$Value)

    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Resolve-WorkspaceCustomerId {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'WorkspaceId is required when input JSON paths are not supplied.'
    }

    if ($Value -notlike '/subscriptions/*') {
        return $Value
    }

    $resolvedCustomerId = az monitor log-analytics workspace show --ids $Value --query customerId --output tsv --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not resolve the Log Analytics customer ID from workspace resource ID '$Value': $resolvedCustomerId"
    }

    return ([string]$resolvedCustomerId).Trim()
}

function Convert-QueryPayloadToRows {
    param([object]$Payload)

    if ($null -eq $Payload) {
        return @()
    }

    if ($Payload -is [System.Array]) {
        return @($Payload)
    }

    if ($Payload.PSObject.Properties['tables']) {
        $table = $Payload.tables[0]
        if ($null -eq $table) {
            return @()
        }

        $columns = @($table.columns)
        $rows = @()
        foreach ($row in @($table.rows)) {
            $item = [ordered]@{}
            for ($index = 0; $index -lt $columns.Count; $index++) {
                $item[$columns[$index].name] = $row[$index]
            }
            $rows += [pscustomobject]$item
        }

        return $rows
    }

    if ($Payload.PSObject.Properties['columns'] -and $Payload.PSObject.Properties['rows']) {
        return Convert-QueryPayloadToRows -Payload ([pscustomobject]@{ tables = @($Payload) })
    }

    return @($Payload)
}

function Get-QueryRows {
    param(
        [string]$WorkspaceId,
        [string]$InputPath,
        [string]$QueryPath
    )

    if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        $payload = Get-Content $InputPath -Raw | ConvertFrom-Json -Depth 20
        return Convert-QueryPayloadToRows -Payload $payload
    }

    $resolvedWorkspaceId = Resolve-WorkspaceCustomerId -Value $WorkspaceId
    # Pass the query via az CLI's @<file> argument syntax so multi-line KQL
    # text is read directly from disk. This avoids PowerShell's legacy
    # native-argument escaping on Windows, which can mangle embedded
    # newlines and cause the service to reject the query with
    # "No tabular expression statement found".
    $queryResult = az monitor log-analytics query --workspace $resolvedWorkspaceId --analytics-query "@$QueryPath" --output json --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Log Analytics query failed for '$QueryPath': $queryResult"
    }

    $payload = $queryResult | ConvertFrom-Json -Depth 20
    return Convert-QueryPayloadToRows -Payload $payload
}

function Get-DeltaDirection {
    param([double]$Delta)

    if ($Delta -gt 0) {
        return 'up'
    }

    if ($Delta -lt 0) {
        return 'down'
    }

    return 'flat'
}

function New-SignalSection {
    param(
        [string]$Title,
        [string]$Signal,
        [object]$Row,
        [string]$PrimaryMetricLabel,
        [string]$PrimaryMetricCurrentKey,
        [string]$PrimaryMetricPreviousKey,
        [string]$SecondaryMetricLabel,
        [string]$SecondaryMetricKey,
        [string]$TopEntityLabel,
        [string]$Recommendation
    )

    $currentValue = Get-NumericPropertyValue -Object $Row -Name $PrimaryMetricCurrentKey
    $previousValue = Get-NumericPropertyValue -Object $Row -Name $PrimaryMetricPreviousKey
    $deltaValue = Get-NumericPropertyValue -Object $Row -Name 'DeltaCount'
    $deltaPercentValue = Get-NumericPropertyValue -Object $Row -Name 'DeltaPercent'
    $secondaryMetricValue = Get-PropertyValue -Object $Row -Name $SecondaryMetricKey -DefaultValue '0'
    $topEntityValue = Get-PropertyValue -Object $Row -Name 'TopEntity' -DefaultValue 'None'
    $latestEventValue = Format-Timestamp -Value (Get-PropertyValue -Object $Row -Name 'LatestEvent' -DefaultValue '')

    return [pscustomobject]@{
        title = $Title
        signal = $Signal
        primaryMetricLabel = $PrimaryMetricLabel
        currentValue = [int]$currentValue
        previousValue = [int]$previousValue
        deltaValue = [int]$deltaValue
        deltaPercentValue = if ($previousValue -eq 0 -and $deltaValue -ne 0) { [double]::NaN } else { $deltaPercentValue }
        deltaDirection = Get-DeltaDirection -Delta $deltaValue
        secondaryMetricLabel = $SecondaryMetricLabel
        secondaryMetricValue = $secondaryMetricValue
        topEntityLabel = $TopEntityLabel
        topEntityValue = [string]$topEntityValue
        latestEventValue = $latestEventValue
        recommendation = $Recommendation
    }
}

function ConvertTo-HtmlReport {
    param(
        [string]$Title,
        [string]$GeneratedAt,
        [object[]]$Sections
    )

    $sectionMarkup = foreach ($section in $Sections) {
        $deltaClass = switch ($section.deltaDirection) {
            'up' { 'delta-up' }
            'down' { 'delta-down' }
            default { 'delta-flat' }
        }

        @"
<article class="panel">
    <div class="signal-meta">$(Escape-Html $section.signal)</div>
    <h2>$(Escape-Html $section.title)</h2>
  <div class="metric-grid">
    <div class="metric-card">
            <div class="metric-label">$(Escape-Html $section.primaryMetricLabel)</div>
            <div class="metric-value">$(Escape-Html ([string]$section.currentValue))</div>
            <div class="metric-subtitle">Previous 24h: $(Escape-Html ([string]$section.previousValue))</div>
    </div>
    <div class="metric-card $deltaClass">
      <div class="metric-label">Drift</div>
            <div class="metric-value">$(Escape-Html (Format-DeltaText -Delta $section.deltaValue -DeltaPercent $section.deltaPercentValue))</div>
            <div class="metric-subtitle">Signal is $(Escape-Html $section.deltaDirection) versus yesterday</div>
    </div>
    <div class="metric-card">
            <div class="metric-label">$(Escape-Html $section.secondaryMetricLabel)</div>
            <div class="metric-value">$(Escape-Html ([string]$section.secondaryMetricValue))</div>
            <div class="metric-subtitle">$(Escape-Html $section.topEntityLabel): $(Escape-Html $section.topEntityValue)</div>
    </div>
  </div>
  <div class="detail-row">
        <div><strong>Latest event:</strong> $(Escape-Html $section.latestEventValue)</div>
        <div><strong>Recommendation:</strong> $(Escape-Html $section.recommendation)</div>
  </div>
</article>
"@
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>$(Escape-Html $Title)</title>
  <style>
    :root {
      --bg: #f6f1e8;
      --panel: rgba(255, 252, 247, 0.94);
      --ink: #18212f;
      --muted: #5b6676;
      --line: rgba(24, 33, 47, 0.12);
      --accent: #9a3412;
      --good: #0f766e;
      --bad: #b91c1c;
      --flat: #475569;
      --shadow: 0 18px 40px rgba(24, 33, 47, 0.10);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: "Segoe UI Variable Text", "Trebuchet MS", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, rgba(154, 52, 18, 0.16), transparent 28%),
        radial-gradient(circle at top right, rgba(15, 118, 110, 0.14), transparent 30%),
        linear-gradient(180deg, #fff9f1 0%, var(--bg) 100%);
    }
    main {
      max-width: 1140px;
      margin: 0 auto;
      padding: 40px 20px 52px;
    }
    .hero {
      margin-bottom: 22px;
    }
    .eyebrow {
      text-transform: uppercase;
      letter-spacing: 0.12em;
      color: var(--muted);
      font-size: 0.82rem;
      margin-bottom: 8px;
    }
    h1 {
      margin: 0 0 10px;
      font-size: clamp(2rem, 4vw, 3.25rem);
      line-height: 1.02;
    }
    .lede {
      margin: 0;
      max-width: 70ch;
      color: var(--muted);
      line-height: 1.6;
    }
    .signal-grid {
      display: grid;
      gap: 16px;
    }
    .panel {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 22px;
      box-shadow: var(--shadow);
      padding: 20px;
    }
    .signal-meta {
      text-transform: uppercase;
      letter-spacing: 0.1em;
      color: var(--muted);
      font-size: 0.8rem;
      margin-bottom: 6px;
    }
    h2 {
      margin: 0 0 16px;
      font-size: 1.3rem;
    }
    .metric-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 12px;
    }
    .metric-card {
      border: 1px solid var(--line);
      border-radius: 16px;
      background: rgba(255, 255, 255, 0.76);
      padding: 14px;
    }
    .metric-label {
      color: var(--muted);
      font-size: 0.82rem;
      text-transform: uppercase;
      letter-spacing: 0.08em;
      margin-bottom: 6px;
    }
    .metric-value {
      font-size: 1.45rem;
      font-weight: 700;
      margin-bottom: 4px;
    }
    .metric-subtitle {
      color: var(--muted);
      font-size: 0.9rem;
      line-height: 1.45;
    }
    .delta-up .metric-value { color: var(--bad); }
    .delta-down .metric-value { color: var(--good); }
    .delta-flat .metric-value { color: var(--flat); }
    .detail-row {
      display: grid;
      gap: 10px;
      margin-top: 14px;
      color: var(--muted);
      line-height: 1.55;
    }
  </style>
</head>
<body>
  <main>
    <section class="hero">
      <div class="eyebrow">Digest-ready summary mode</div>
            <h1>$(Escape-Html $Title)</h1>
      <p class="lede">Generated from the repo-managed summary queries over the same three incident-response signal families used by the workbook and scheduled alerts. This output is suitable for a lightweight dashboard artifact or as a Markdown or HTML body for email or Teams automation.</p>
            <p class="lede">Generated at: $(Escape-Html $GeneratedAt)</p>
    </section>
    <section class="signal-grid">
$($sectionMarkup -join "`n")
    </section>
  </main>
</body>
</html>
"@
}

function ConvertTo-MarkdownReport {
    param(
        [string]$Title,
        [string]$GeneratedAt,
        [object[]]$Sections
    )

    $lines = @(
        "# $Title",
        '',
        "Generated at: $GeneratedAt",
        '',
        'Covers the last 24 hours versus the previous 24 hours.',
        ''
    )

    foreach ($section in $Sections) {
        $lines += "## $($section.title)"
        $lines += ''
        $lines += "- $($section.primaryMetricLabel): $($section.currentValue)"
        $lines += "- Previous 24h: $($section.previousValue)"
        $lines += "- Drift: $(Format-DeltaText -Delta $section.deltaValue -DeltaPercent $section.deltaPercentValue)"
        $lines += "- $($section.secondaryMetricLabel): $($section.secondaryMetricValue)"
        $lines += "- $($section.topEntityLabel): $($section.topEntityValue)"
        $lines += "- Latest event: $($section.latestEventValue)"
        $lines += "- Recommendation: $($section.recommendation)"
        $lines += ''
    }

    return ($lines -join "`n")
}

$repoRoot = Get-RepoRoot
$summaryQueryRoot = Join-Path $repoRoot 'queries/daily-summaries'

$highSeverityRows = Get-QueryRows -WorkspaceId $WorkspaceId -InputPath $HighSeverityInputPath -QueryPath (Join-Path $summaryQueryRoot 'high-severity-summary.kql')
$authenticationRows = Get-QueryRows -WorkspaceId $WorkspaceId -InputPath $AuthenticationInputPath -QueryPath (Join-Path $summaryQueryRoot 'authentication-summary.kql')
$serviceHealthRows = Get-QueryRows -WorkspaceId $WorkspaceId -InputPath $ServiceHealthInputPath -QueryPath (Join-Path $summaryQueryRoot 'service-health-summary.kql')

$sections = @(
    New-SignalSection `
        -Title 'High Severity Events' `
        -Signal 'high-severity-errors' `
        -Row ($highSeverityRows | Select-Object -First 1) `
        -PrimaryMetricLabel 'Failure Count Drift' `
        -PrimaryMetricCurrentKey 'CurrentCount' `
        -PrimaryMetricPreviousKey 'PreviousCount' `
        -SecondaryMetricLabel 'Top Source Table' `
        -SecondaryMetricKey 'TopEntity' `
        -TopEntityLabel 'Primary contributor' `
        -Recommendation 'If failure drift is up, pivot into the workbook and review the top source table before enabling paging.'
    New-SignalSection `
        -Title 'Authentication Anomalies' `
        -Signal 'authentication-anomalies' `
        -Row ($authenticationRows | Select-Object -First 1) `
        -PrimaryMetricLabel 'Failed Attempts Drift' `
        -PrimaryMetricCurrentKey 'CurrentFailedAttempts' `
        -PrimaryMetricPreviousKey 'PreviousFailedAttempts' `
        -SecondaryMetricLabel 'Unusual IP Spread' `
        -SecondaryMetricKey 'MaxDistinctIPsCurrent' `
        -TopEntityLabel 'Most affected identity' `
        -Recommendation 'If unusual IP spread is elevated, investigate the top identity and tighten sign-in controls before enabling broader alert fan-out.'
    New-SignalSection `
        -Title 'Service Health Regressions' `
        -Signal 'service-health-regressions' `
        -Row ($serviceHealthRows | Select-Object -First 1) `
        -PrimaryMetricLabel 'Affected Resources Drift' `
        -PrimaryMetricCurrentKey 'CurrentAffectedResources' `
        -PrimaryMetricPreviousKey 'PreviousAffectedResources' `
        -SecondaryMetricLabel 'Worst Gap Minutes' `
        -SecondaryMetricKey 'WorstGapMinutesCurrent' `
        -TopEntityLabel 'Most stale resource' `
        -Recommendation 'If heartbeat regressions remain active, inspect the most stale resource and only promote to paging if the service impact is real.'
)

$generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')
$reportModel = [pscustomobject]@{
    title = $ReportTitle
    generatedAt = $generatedAt
    mode = 'DailySocSummary'
    sections = $sections
}

$reportContent = switch ($OutputFormat) {
    'Html' { ConvertTo-HtmlReport -Title $ReportTitle -GeneratedAt $generatedAt -Sections $sections }
    'Markdown' { ConvertTo-MarkdownReport -Title $ReportTitle -GeneratedAt $generatedAt -Sections $sections }
    'Json' { $reportModel | ConvertTo-Json -Depth 6 }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    Set-Content -Path $OutputPath -Value $reportContent -Encoding UTF8
    Write-Host "Wrote daily SOC summary to $OutputPath"
}

$reportContent