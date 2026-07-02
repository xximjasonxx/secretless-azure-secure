targetScope = 'resourceGroup'

@description('Storage account name (globally unique, lowercase, 3-24 chars).')
param name string

@description('Resource location.')
param location string = resourceGroup().location

@description('Common tags.')
param tags object = {}
var normalizedTags = union(tags, {
  'SecurityControl': 'Ignore'
})

@description('Table name for asset comments.')
param commentsTableName string

@description('Table name for asset tickets.')
param ticketsTableName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: normalizedTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Start stage intentionally uses connection string auth.
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource commentsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: commentsTableName
}

resource ticketsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: ticketsTableName
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${listKeys(storageAccount.id, storageAccount.apiVersion).keys[0].value}'

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output storageTablesUri string = 'https://${storageAccount.name}.table.${environment().suffixes.storage}/'
output storageConnectionString string = storageConnectionString
