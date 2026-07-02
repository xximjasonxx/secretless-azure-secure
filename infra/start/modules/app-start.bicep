targetScope = 'resourceGroup'

@description('Web app name.')
param name string

@description('Resource location.')
param location string = resourceGroup().location

@description('Common tags.')
param tags object = {}
var normalizedTags = union(tags, {
  'SecurityControl': 'Ignore'
})

@description('azd service name for deployment wiring.')
param serviceName string = 'api'

@description('App Service plan name.')
param appServicePlanName string

@description('Storage connection string used in start stage.')
param storageConnectionString string

@description('Comments table name.')
param commentsTableName string

@description('Tickets table name.')
param ticketsTableName string

@description('Asset service URL.')
param assetServiceApiUrl string

@description('Asset service API key stored directly in app settings for start stage.')
param assetServiceApiKey string

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: normalizedTags
  sku: {
    // Premium v3 avoids subscriptions that have zero Basic/Standard quota.
    name: 'P0v3'
    tier: 'PremiumV3'
    size: 'P0v3'
    capacity: 1
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: name
  location: location
  kind: 'app,linux'
  tags: union(normalizedTags, {
    'azd-service-name': serviceName
  })
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/health'
      appSettings: [
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'APP_SECURITY_STAGE'
          value: 'start'
        }
        {
          name: 'ASSET_SERVICE_API_URL'
          value: assetServiceApiUrl
        }
        {
          name: 'ASSET_SERVICE_API_KEY'
          value: assetServiceApiKey
        }
        {
          name: 'STORAGE_CONNECTION_STRING'
          value: storageConnectionString
        }
        {
          name: 'STORAGE_TABLES_URI'
          value: ''
        }
        {
          name: 'ASSET_COMMENTS_TABLE'
          value: commentsTableName
        }
        {
          name: 'ASSET_TICKETS_TABLE'
          value: ticketsTableName
        }
      ]
    }
  }
}

output webAppName string = webApp.name
output appUrl string = 'https://${webApp.properties.defaultHostName}'
