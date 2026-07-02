targetScope = 'subscription'

@description('azd environment name. Used for deterministic naming and tagging.')
param environmentName string

@description('Primary Azure region for this single-resource-group demo.')
param location string

@description('Optional existing resource group name to deploy into. Leave empty to create a deterministic RG name.')
param existingResourceGroupName string = ''

@secure()
@description('Demo secret value to seed in Key Vault. This stays in Key Vault only and is never passed to the app.')
param demoSecretValue string = newGuid()

// Deterministic short token keeps names stable and re-runnable for conference demos.
var token = toLower(take(uniqueString(subscription().id, environmentName, location), 6))
var resourceGroupName = empty(existingResourceGroupName) ? 'rg-${environmentName}-${token}' : existingResourceGroupName
var tags = {
  'azd-env-name': environmentName
  'demo-scenario': 'secretless-private-link'
  'SecurityControl': 'Ignore'
}

// Single resource group for a self-contained, easy-to-teardown talk demo.
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = if (empty(existingResourceGroupName)) {
  name: resourceGroupName
  location: location
  tags: tags
}

// Names are deterministic from token; no random runtime-generated names.
var vnetName = 'vnet-${environmentName}-${token}'
var appServicePlanName = 'asp-${environmentName}-${token}'
var webAppName = 'app-${environmentName}-${token}-${take(uniqueString(subscription().id, resourceGroupName, 'web'), 5)}'
var keyVaultName = toLower('kv${token}${take(uniqueString(subscription().id, resourceGroupName, 'kv'), 10)}')
var storageAccountName = toLower('st${token}${take(uniqueString(subscription().id, resourceGroupName, 'st'), 11)}')

// -------- Main resource graph --------
// network -> (app, privatedns)
// keyvault -> (rbac, privatedns)
// storage -> (rbac, privatedns)
// app -> rbac
// privatedns wires private endpoints + DNS to make public FQDNs resolve to private IPs.

module network './modules/network.bicep' = {
  name: 'network-${token}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: vnetName
    location: location
    tags: tags
    appSubnetName: 'snet-app'
    peSubnetName: 'snet-pe'
  }
  dependsOn: [
    rg
  ]
}

module keyVault './modules/keyvault.bicep' = {
  name: 'keyvault-${token}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: keyVaultName
    location: location
    tags: tags
    demoSecretValue: demoSecretValue
  }
  dependsOn: [
    rg
  ]
}

module storage './modules/storage.bicep' = {
  name: 'storage-${token}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: storageAccountName
    location: location
    tags: tags
    containerName: 'democontainer'
  }
  dependsOn: [
    rg
  ]
}

module app './modules/app.bicep' = {
  name: 'app-${token}'
  scope: resourceGroup(resourceGroupName)
  params: {
    name: webAppName
    location: location
    tags: tags
    serviceName: 'api'
    appServicePlanName: appServicePlanName
    appSubnetId: network.outputs.appSubnetId
    keyVaultUri: keyVault.outputs.keyVaultUri
    storageBlobUri: storage.outputs.storageBlobUri
  }
  dependsOn: [
    rg
  ]
}

module rbac './modules/rbac.bicep' = {
  name: 'rbac-${token}'
  scope: resourceGroup(resourceGroupName)
  params: {
    principalId: app.outputs.appPrincipalId
    keyVaultName: keyVault.outputs.keyVaultName
    storageAccountName: storage.outputs.storageAccountName
  }
  dependsOn: [
    rg
  ]
}

module privateDns './modules/privatedns.bicep' = {
  name: 'privatedns-${token}'
  scope: resourceGroup(resourceGroupName)
  params: {
    location: location
    tags: tags
    vnetResourceId: network.outputs.vnetId
    peSubnetResourceId: network.outputs.peSubnetId
    keyVaultResourceId: keyVault.outputs.keyVaultId
    storageAccountResourceId: storage.outputs.storageAccountId
    keyVaultPrivateEndpointName: 'pe-kv-${token}'
    storagePrivateEndpointName: 'pe-st-${token}'
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
output AZURE_KEY_VAULT_NAME string = keyVault.outputs.keyVaultName
output AZURE_STORAGE_ACCOUNT_NAME string = storage.outputs.storageAccountName
output KEYVAULT_URI string = keyVault.outputs.keyVaultUri
output STORAGE_BLOB_URI string = storage.outputs.storageBlobUri
