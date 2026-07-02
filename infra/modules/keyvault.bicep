targetScope = 'resourceGroup'

@description('Key Vault name.')
param name string

@description('Resource location.')
param location string = resourceGroup().location

@description('Common tags.')
param tags object = {}
var normalizedTags = union(tags, {
  'SecurityControl': 'Ignore'
})

@secure()
@description('Value for DemoSecret. This remains in Key Vault and is masked by the app.')
param demoSecretValue string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: normalizedTags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // Secretless baseline: use Azure RBAC for data-plane auth, not access policies.
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    // Keep template deployment disabled so Key Vault can remain bypass:none.
    enabledForTemplateDeployment: false
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

resource demoSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'DemoSecret'
  properties: {
    value: demoSecretValue
  }
}

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
