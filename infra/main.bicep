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

var suffix = uniqueString(resourceGroup().id)
var actionGroupName = 'ag-ir-${environment}-${suffix}'
var logAnalyticsName = 'log-ir-${environment}-${suffix}'
var workbookName = guid(resourceGroup().id, 'incident-response-dashboard', environment)
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

output workspaceId string = logAnalytics.id
output workbookId string = workbook.id
output actionGroupId string = !empty(notificationEmail) ? incidentActionGroup.id : ''
