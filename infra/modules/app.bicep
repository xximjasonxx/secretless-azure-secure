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

@description('Subnet resource ID for regional VNet integration.')
param appSubnetId string

@description('Key Vault URI passed to app as non-secret config.')
param keyVaultUri string

@description('Storage blob endpoint URI passed to app as non-secret config.')
param storageBlobUri string

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: normalizedTags
  sku: {
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
    // azd deploy uses this tag to find the host resource for service "api".
    'azd-service-name': serviceName
  })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    virtualNetworkSubnetId: appSubnetId
    siteConfig: {
      // App Service deploy path used by azd host:appservice for .NET code apps.
      linuxFxVersion: 'DOTNETCORE|8.0'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      healthCheckPath: '/health'
      vnetRouteAllEnabled: true
      appSettings: [
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          // Non-secret identifier only; app uses this with DefaultAzureCredential.
          name: 'KEYVAULT_URI'
          value: keyVaultUri
        }
        {
          // Non-secret identifier only; no keys/SAS/connection strings are used.
          name: 'STORAGE_BLOB_URI'
          value: storageBlobUri
        }
      ]
    }
  }
}

output webAppName string = webApp.name
output appPrincipalId string = webApp.identity.principalId
output appUrl string = 'https://${webApp.properties.defaultHostName}'
