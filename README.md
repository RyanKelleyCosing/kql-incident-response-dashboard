# KQL-Powered Incident Response Dashboard

[![Azure Monitor](https://img.shields.io/badge/Azure%20Monitor-Workbook-blue?logo=microsoft-azure)](.)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![KQL](https://img.shields.io/badge/KQL-Incident%20Response-green)](.)

An incident-response focused Azure Monitor workbook that surfaces operational failures, authentication anomalies, and health regressions from Log Analytics with reusable KQL queries and repo-friendly deployment automation.

## What This Project Demonstrates

- KQL for operational triage instead of static screenshots
- Azure Monitor Workbook authoring as code
- Reusable query packs for incident response playbooks
- Lightweight repo validation for dashboard artifacts

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│               KQL-Powered Incident Response Dashboard                  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                     Log Analytics Workspace                            │
│      App Events      Sign-in Logs      Heartbeats      Diagnostics     │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    Azure Monitor Workbook                              │
│    High Severity Events   Auth Anomalies   Service Regressions         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                  Optional Incident Action Group                        │
└─────────────────────────────────────────────────────────────────────────┘
```

## Dashboard Views

| View | Signal | Triage Goal |
|------|--------|-------------|
| High Severity Events | Exceptions, traces, diagnostics | Identify emerging failures fast |
| Authentication Anomalies | Sign-in failures and IP spread | Spot brute force or credential abuse |
| Service Health Regressions | Heartbeat gaps and missing telemetry | Catch degraded services before tickets pile up |

## Quick Start

### Prerequisites

- Azure subscription
- Azure CLI with Bicep support
- A resource group for Azure Monitor assets

### Deploy Infrastructure

```bash
az login

az group create -n rg-ir-dashboard -l eastus

az deployment group create \
  -g rg-ir-dashboard \
  -f infra/main.bicep \
  -p environment=dev notificationEmail='oncall@example.com'
```

### Validate Locally

```powershell
pwsh ./tests/validate-dashboard.ps1
```

## Project Structure

```
├── .github/
│   └── workflows/
│       └── validate.yml                   # CI validation for workbook + Bicep
├── infra/
│   └── main.bicep                         # Workbook, workspace, action group
├── queries/
│   ├── authentication-anomalies.kql       # Sign-in investigation query
│   ├── high-severity-errors.kql           # Failure trend query
│   └── service-health-regressions.kql     # Heartbeat and availability query
├── tests/
│   └── validate-dashboard.ps1             # Offline validation script
├── workbooks/
│   └── incident-response-dashboard.workbook.json
├── .gitignore
├── LICENSE
└── README.md
```

## Query Pack

- `queries/high-severity-errors.kql` highlights noisy or critical failures in the last 24 hours.
- `queries/authentication-anomalies.kql` identifies repeated sign-in failures and unusual IP spread.
- `queries/service-health-regressions.kql` flags resources with stale or sparse heartbeat data.

## Publishing

```bash
git clone https://github.com/RyanKelleyCosing/kql-incident-response-dashboard.git
```

## License

MIT License - see [LICENSE](LICENSE) for details.