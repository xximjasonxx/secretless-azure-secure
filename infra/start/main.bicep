targetScope = 'subscription'

@description('azd environment name. Used for deterministic naming and tagging.')
param environmentName string

@description('Primary Azure region for this environment.')
param location string

@description('Optional existing resource group name to deploy into. Leave empty to create a deterministic RG name.')
param existingResourceGroupName string = ''

@description('External asset service URL. 404 responses are tolerated by the app for demo mode.')
param assetServiceApiUrl string = 'https://assets.contoso.invalid/api/assets'

@description('Insecure initial-stage API key stored directly in app settings.')
@secure()
param assetServiceApiKey string = ''

@description('Table name for asset comments.')
param commentsTableName string = 'assetcomments'

@description('Table name for asset tickets.')
param ticketsTableName string = 'assettickets'

// Deterministic short token keeps names stable and repeatable.
var token = toLower(take(uniqueString(subscription().id, environmentName, location), 6))
var resourceGroupName = empty(existingResourceGroupName) ? 'rg-${environmentName}-${token}' : existingResourceGroupName
var resolvedAssetServiceApiKey = empty(assetServiceApiKey) ? 'demo-insecure-api-key' : assetServiceApiKey
var tags = {
  'azd-env-name': environmentName
  'demo-scenario': 'app-security-journey'
  'demo-stage': 'start'
  'SecurityControl': 'Ignore'
}

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = if (empty(existingResourceGroupName)) {
  name: resourceGroupName
  location: location
  tags: tags
}

var appServicePlanName = 'asp-${environmentName}-${token}'
var webAppName = 'app-${environmentName}-${token}-${take(uniqueString(subscription().id, resourceGroupName, 'web'), 5)}'
var storageAccountName = toLower('st${token}${take(uniqueString(subscription().id, resourceGroupName, 'st'), 11)}')

module storage './modules/storage-start.bicep' = {
  name: 'storage-start-${token}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: storageAccountName
    location: location
    tags: tags
    commentsTableName: commentsTableName
    ticketsTableName: ticketsTableName
  }
  dependsOn: [
    rg
  ]
}

module app './modules/app-start.bicep' = {
  name: 'app-start-${token}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: webAppName
    location: location
    tags: tags
    serviceName: 'api'
    appServicePlanName: appServicePlanName
    storageConnectionString: storage.outputs.storageConnectionString
    commentsTableName: commentsTableName
    ticketsTableName: ticketsTableName
    assetServiceApiUrl: assetServiceApiUrl
    assetServiceApiKey: resolvedAssetServiceApiKey
  }
  dependsOn: [
    rg
  ]
}

// UPPERCASE outputs become azd environment variables.
output AZURE_RESOURCE_GROUP string = resourceGroupName
output AZURE_LOCATION string = location
output AZURE_WEBAPP_NAME string = app.outputs.webAppName
output API_URL string = app.outputs.appUrl
output AZURE_STORAGE_ACCOUNT_NAME string = storage.outputs.storageAccountName
output STORAGE_TABLES_URI string = storage.outputs.storageTablesUri
output ASSET_COMMENTS_TABLE string = commentsTableName
output ASSET_TICKETS_TABLE string = ticketsTableName
