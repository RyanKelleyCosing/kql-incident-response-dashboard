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
    Get-Content 'workbooks/incident-response-dashboard.workbook.json' -Raw | ConvertFrom-Json | Out-Null

    foreach ($queryFile in Get-ChildItem 'queries/*.kql') {
        if ([string]::IsNullOrWhiteSpace((Get-Content $queryFile.FullName -Raw))) {
            throw "Query file '$($queryFile.Name)' is empty."
        }
        Write-Host "Validated $($queryFile.Name)"
    }

    Write-Host 'Dashboard validation completed successfully.'
}
finally {
    Pop-Location
}