@description('Environment name used in naming and tagging.')
@allowed([
  'dev'
  'prod'
])
param environment string = 'dev'

@description('Azure region for the Log Analytics workspace and workbook.')
param location string = resourceGroup().location

@description('Optional email address for the incident response action group. Leave blank to skip action group deployment.')
param notificationEmail string = ''

@description('Deploy scheduled query alert rules for the three incident-response signal families. Disabled by default for a dashboard-first, low-noise setup.')
param deployScheduledAlerts bool = false

@description('Create the high-severity errors alert when scheduled alerts are enabled. Disabled by default because it is the noisiest signal family.')
param enableHighSeverityAlert bool = false

@description('Create the authentication anomalies alert when scheduled alerts are enabled. Enabled by default because sign-in abuse is worth monitoring proactively.')
param enableAuthenticationAlert bool = true

@description('Create the service health regressions alert when scheduled alerts are enabled. Enabled by default because heartbeat gaps are a reasonable low-noise operational signal.')
param enableServiceRegressionAlert bool = true

@description('How often the scheduled query alerts evaluate their queries. The default favors lower noise over fast paging.')
param alertEvaluationFrequency string = 'PT30M'

@description('The query window used by the scheduled query alerts. The default favors lower noise over fast paging.')
param alertWindowSize string = 'PT30M'

@description('Minimum aggregated high-severity events required before the failure alert fires. The default is intentionally conservative for dashboard-first deployments.')
@minValue(0)
param highSeverityAlertThreshold int = 15

@description('Minimum aggregated failed sign-in attempts required before the authentication alert fires. The default is intentionally conservative for dashboard-first deployments.')
@minValue(0)
param authenticationAlertThreshold int = 20

@description('Minimum affected resources required before the service regression alert fires. The default is intentionally conservative for dashboard-first deployments.')
@minValue(0)
param serviceRegressionAlertThreshold int = 1

var suffix = uniqueString(resourceGroup().id)
var actionGroupName = 'ag-ir-${environment}-${suffix}'
var logAnalyticsName = 'log-ir-${environment}-${suffix}'
var workbookName = guid(resourceGroup().id, 'incident-response-dashboard', environment)
var highSeverityAlertQuery = '${replace(loadTextContent('../queries/high-severity-errors.kql'), 'let lookback = 24h;', 'let lookback = 30m;')}\n| summarize AggregatedValue = sum(EventCount)'
var authenticationAlertQuery = '${replace(loadTextContent('../queries/authentication-anomalies.kql'), 'let lookback = 24h;', 'let lookback = 60m;')}\n| summarize AggregatedValue = sum(FailedAttempts)'
var serviceRegressionAlertQuery = '${replace(loadTextContent('../queries/service-health-regressions.kql'), 'let lookback = 6h;', 'let lookback = 60m;')}\n| summarize AggregatedValue = count()'
var alertActionGroupIds = !empty(notificationEmail) ? [incidentActionGroup.id] : []
var scheduledAlerts = [
  {
    name: 'sqr-ir-high-errors-${environment}-${suffix}'
    displayName: 'IR High Severity Errors'
    description: 'Raises an alert when high-severity exceptions or diagnostics spike inside the alert window.'
    isEnabled: enableHighSeverityAlert
    severity: 2
    threshold: highSeverityAlertThreshold
    query: highSeverityAlertQuery
    signal: 'high-severity-errors'
  }
  {
    name: 'sqr-ir-auth-anomalies-${environment}-${suffix}'
    displayName: 'IR Authentication Anomalies'
    description: 'Raises an alert when repeated failed sign-in activity breaches the configured threshold.'
    isEnabled: enableAuthenticationAlert
    severity: 2
    threshold: authenticationAlertThreshold
    query: authenticationAlertQuery
    signal: 'authentication-anomalies'
  }
  {
    name: 'sqr-ir-service-regressions-${environment}-${suffix}'
    displayName: 'IR Service Health Regressions'
    description: 'Raises an alert when heartbeat gaps indicate degraded or missing service telemetry.'
    isEnabled: enableServiceRegressionAlert
    severity: 3
    threshold: serviceRegressionAlertThreshold
    query: serviceRegressionAlertQuery
    signal: 'service-health-regressions'
  }
]
var scheduledQueryRuleIds = concat(
  enableHighSeverityAlert ? [resourceId('Microsoft.Insights/scheduledQueryRules', scheduledAlerts[0].name)] : [],
  enableAuthenticationAlert ? [resourceId('Microsoft.Insights/scheduledQueryRules', scheduledAlerts[1].name)] : [],
  enableServiceRegressionAlert ? [resourceId('Microsoft.Insights/scheduledQueryRules', scheduledAlerts[2].name)] : []
)
var tags = {
  Environment: environment
  ManagedBy: 'Bicep'
  Project: 'KQL-Incident-Response-Dashboard'
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource incidentActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(notificationEmail)) {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    emailReceivers: [
      {
        emailAddress: notificationEmail
        name: 'primaryOnCall'
        useCommonAlertSchema: true
      }
    ]
    enabled: true
    groupShortName: 'IR${toUpper(environment)}'
  }
}

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookName
  kind: 'shared'
  location: location
  tags: tags
  properties: {
    category: 'workbook'
    description: 'Operational workbook for KQL-driven incident response.'
    displayName: 'KQL Incident Response Dashboard'
    serializedData: loadTextContent('../workbooks/incident-response-dashboard.workbook.json')
    sourceId: logAnalytics.id
    version: 'Notebook/1.0'
  }
}

resource scheduledQueryRules 'Microsoft.Insights/scheduledQueryRules@2025-01-01-preview' = [for alert in scheduledAlerts: if (deployScheduledAlerts && alert.isEnabled) {
  name: alert.name
  kind: 'LogAlert'
  location: location
  tags: union(tags, {
    Signal: alert.signal
  })
  properties: {
    autoMitigate: false
    checkWorkspaceAlertsStorageConfigured: false
    criteria: {
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          failingPeriods: {
            minFailingPeriodsToAlert: 1
            numberOfEvaluationPeriods: 1
          }
          metricMeasureColumn: 'AggregatedValue'
          operator: 'GreaterThan'
          query: alert.query
          threshold: alert.threshold
          timeAggregation: 'Average'
        }
      ]
    }
    description: alert.description
    displayName: alert.displayName
    enabled: true
    evaluationFrequency: alertEvaluationFrequency
    muteActionsDuration: 'PT30M'
    overrideQueryTimeRange: alertWindowSize
    scopes: [
      logAnalytics.id
    ]
    severity: alert.severity
    skipQueryValidation: false
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    windowSize: alertWindowSize
    ...(empty(alertActionGroupIds)
      ? {}
      : {
          actions: {
            actionGroups: alertActionGroupIds
            customProperties: {
              Project: 'KQL-Incident-Response-Dashboard'
              Signal: alert.signal
            }
          }
        })
  }
}]

output workspaceId string = logAnalytics.id
output workbookId string = workbook.id
output actionGroupId string = !empty(notificationEmail) ? incidentActionGroup.id : ''
output scheduledQueryRuleIds array = deployScheduledAlerts ? scheduledQueryRuleIds : []
