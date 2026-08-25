targetScope = 'resourceGroup'

@description('System-assigned managed identity principalId of the web app.')
param principalId string

@description('Name of the target Key Vault.')
param keyVaultName string

@description('Name of the target Storage account.')
param storageAccountName string

@description('Name of the comments table.')
param commentsTableName string = 'assetcomments'

@description('Name of the tickets table.')
param ticketsTableName string = 'assettickets'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource commentsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' existing = {
  parent: tableService
  name: commentsTableName
}

resource ticketsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' existing = {
  parent: tableService
  name: ticketsTableName
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

resource commentsTableDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(commentsTable.id, principalId, 'storage-comments-table-data-contributor')
  scope: commentsTable
  properties: {
    // Storage Table Data Contributor (0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3):
    // table data access is limited to the comments table resource.
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource ticketsTableDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ticketsTable.id, principalId, 'storage-tickets-table-data-contributor')
  scope: ticketsTable
  properties: {
    // Storage Table Data Contributor (0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3):
    // table data access is limited to the tickets table resource.
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
