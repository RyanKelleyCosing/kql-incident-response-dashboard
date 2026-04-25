$ErrorActionPreference = 'Stop'

function Invoke-BicepBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $bicepCommand = Get-Command bicep -ErrorAction SilentlyContinue
    if ($bicepCommand) {
        & $bicepCommand.Source build --file $FilePath | Out-Null
        return
    }

    $azCommand = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCommand) {
        throw 'Install either the Bicep CLI or Azure CLI before running validation.'
    }

    az bicep install | Out-Null
    az bicep build --file $FilePath | Out-Null
}

$repoRoot = Split-Path -Parent $PSScriptRoot

Push-Location $repoRoot
try {
    Invoke-BicepBuild -FilePath 'infra/main.bicep'
    $template = Get-Content 'infra/main.json' -Raw | ConvertFrom-Json
    Get-Content 'workbooks/incident-response-dashboard.workbook.json' -Raw | ConvertFrom-Json | Out-Null

    if ($template.resources.type -notcontains 'Microsoft.Insights/workbooks') {
        throw 'Compiled template is missing the workbook resource.'
    }

    $bicepSource = Get-Content 'infra/main.bicep' -Raw
    foreach ($requiredToken in @(
        'Microsoft.Insights/scheduledQueryRules'
        'high-severity-errors'
        'authentication-anomalies'
        'service-health-regressions'
    )) {
        if ($bicepSource -notmatch [regex]::Escape($requiredToken)) {
            throw "Bicep template is missing expected alert token '$requiredToken'."
        }
    }

    foreach ($queryFile in Get-ChildItem 'queries/*.kql') {
        if ([string]::IsNullOrWhiteSpace((Get-Content $queryFile.FullName -Raw))) {
            throw "Query file '$($queryFile.Name)' is empty."
        }
        Write-Host "Validated $($queryFile.Name)"
    }

    foreach ($queryFile in Get-ChildItem 'queries/daily-summaries/*.kql') {
        if ([string]::IsNullOrWhiteSpace((Get-Content $queryFile.FullName -Raw))) {
            throw "Daily summary query file '$($queryFile.Name)' is empty."
        }
        Write-Host "Validated $($queryFile.Name)"
    }

    $summaryOutputPath = Join-Path ([System.IO.Path]::GetTempPath()) "daily-soc-summary-$([guid]::NewGuid()).html"
    & (Join-Path $repoRoot 'scripts/Invoke-DailySocSummary.ps1') `
        -HighSeverityInputPath (Join-Path $repoRoot 'tests/sample-data/high-severity-summary.json') `
        -AuthenticationInputPath (Join-Path $repoRoot 'tests/sample-data/authentication-summary.json') `
        -ServiceHealthInputPath (Join-Path $repoRoot 'tests/sample-data/service-health-summary.json') `
        -OutputFormat Html `
        -OutputPath $summaryOutputPath | Out-Null

    if (-not (Test-Path $summaryOutputPath)) {
        throw 'Daily SOC summary renderer did not create the expected output file.'
    }

    $summaryContent = Get-Content $summaryOutputPath -Raw
    foreach ($requiredToken in @(
        'Daily SOC Summary'
        'High Severity Events'
        'Authentication Anomalies'
        'Service Health Regressions'
        'Unusual IP Spread'
    )) {
        if ($summaryContent -notmatch [regex]::Escape($requiredToken)) {
            throw "Daily SOC summary output is missing expected token '$requiredToken'."
        }
    }

    $emailPreview = & (Join-Path $repoRoot 'scripts/Send-DailySocSummaryEmail.ps1') `
        -HighSeverityInputPath (Join-Path $repoRoot 'tests/sample-data/high-severity-summary.json') `
        -AuthenticationInputPath (Join-Path $repoRoot 'tests/sample-data/authentication-summary.json') `
        -ServiceHealthInputPath (Join-Path $repoRoot 'tests/sample-data/service-health-summary.json') `
        -To 'soc@example.com' `
        -From 'digest@example.com' `
        -PreviewOnly

    foreach ($requiredToken in @(
        'Daily SOC Summary'
        'soc@example.com'
        'High Severity Events'
    )) {
        if ($emailPreview -notmatch [regex]::Escape($requiredToken)) {
            throw "Daily SOC email preview is missing expected token '$requiredToken'."
        }
    }

    Remove-Item $summaryOutputPath -Force

    Write-Host 'Validated workbook, query pack, scheduled alert infrastructure, daily SOC summary mode, and digest email preview.'
    Write-Host 'Dashboard validation completed successfully.'
}
finally {
    Pop-Location
}