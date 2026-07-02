targetScope = 'resourceGroup'

@description('System-assigned managed identity principalId of the web app.')
param principalId string

@description('Name of the target Key Vault.')
param keyVaultName string

@description('Name of the target Storage account.')
param storageAccountName string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource keyVaultSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, principalId, 'kv-secrets-user')
  scope: keyVault
  properties: {
    // Key Vault Secrets User (4633458b-17de-408a-b874-0445c86b69e6):
    // minimum data-plane read for secrets. This is enough for GET secret, nothing more.
    // Important: control-plane Contributor DOES NOT grant data-plane secret read here.
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource storageBlobDataReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, principalId, 'storage-blob-data-reader')
  scope: storageAccount
  properties: {
    // Storage Blob Data Reader (2a2b9908-6ea1-4ae2-8e65-a410df84e7d1):
    // minimum data-plane role to read hello.txt from democontainer.
    // Important: control-plane Contributor DOES NOT grant blob data read permissions.
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
