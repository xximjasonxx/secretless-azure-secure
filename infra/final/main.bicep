targetScope = 'resourceGroup'

@description('Location for new network resources.')
param location string = resourceGroup().location

@description('Existing App Service name.')
param appName string

@description('Key Vault name created during final stage.')
param keyVaultName string = toLower('kv${take(uniqueString(resourceGroup().id, appName, 'finalkv'), 22)}')

@description('Existing Storage account name.')
param storageAccountName string

@description('Asset service API key value copied into Key Vault during final stage. Leave empty to keep the existing secret value.')
@secure()
param assetServiceApiKeySecretValue string = ''

@description('Object ID granted Key Vault Administrator on the final Key Vault.')
param keyVaultAdminObjectId string

@description('Principal type for the Key Vault Administrator assignment.')
param keyVaultAdminPrincipalType string = 'User'

@description('App Service managed identity object ID granted Key Vault secret read access.')
param appPrincipalObjectId string

@description('Key Vault secret name used by the app.')
param assetServiceApiKeySecretName string = 'AssetServiceApiKey'

@description('Optional tags for final-stage resources.')
param tags object = {}
var normalizedTags = union(tags, {
  'SecurityControl': 'Ignore'
})

var vnetName = 'vnet-final-${take(uniqueString(resourceGroup().id, appName), 6)}'
var appGatewaySubnetName = 'snet-appgw'
var privateEndpointSubnetName = 'snet-pe'
var appIntegrationSubnetName = 'snet-app'
var appGatewayPublicIpDnsLabel = toLower('agw-${take(uniqueString(subscription().id, resourceGroup().id, appName), 26)}')

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: normalizedTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.80.0.0/16'
      ]
    }
    subnets: [
      {
        name: appGatewaySubnetName
        properties: {
          addressPrefix: '10.80.1.0/24'
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: '10.80.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: appIntegrationSubnetName
        properties: {
          addressPrefix: '10.80.4.0/24'
          delegations: [
            {
              name: 'appservice-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}

resource appGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-appgw-${take(uniqueString(resourceGroup().id, appName), 6)}'
  location: location
  tags: normalizedTags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: appGatewayPublicIpDnsLabel
    }
  }
}

resource appPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
  tags: normalizedTags
}

resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: normalizedTags
}

resource tablePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.table.${environment().suffixes.storage}'
  location: 'global'
  tags: normalizedTags
}

resource appZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: appPrivateDnsZone
  name: 'link-${vnet.name}'
  location: 'global'
  tags: normalizedTags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource keyVaultZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: keyVaultPrivateDnsZone
  name: 'link-${vnet.name}'
  location: 'global'
  tags: normalizedTags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource tableZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: tablePrivateDnsZone
  name: 'link-${vnet.name}'
  location: 'global'
  tags: normalizedTags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource app 'Microsoft.Web/sites@2023-12-01' existing = {
  name: appName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: normalizedTags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource assetServiceApiKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (!empty(assetServiceApiKeySecretValue)) {
  parent: keyVault
  name: assetServiceApiKeySecretName
  properties: {
    value: assetServiceApiKeySecretValue
  }
}

var keyVaultAdministratorRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483')
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource keyVaultAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, keyVaultAdminObjectId, keyVaultAdministratorRoleDefinitionId)
  properties: {
    roleDefinitionId: keyVaultAdministratorRoleDefinitionId
    principalId: keyVaultAdminObjectId
    principalType: keyVaultAdminPrincipalType
  }
}

resource appSecretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, appPrincipalObjectId, keyVaultSecretsUserRoleDefinitionId)
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: appPrincipalObjectId
    principalType: 'ServicePrincipal'
  }
}

resource appVnetIntegration 'Microsoft.Web/sites/networkConfig@2023-12-01' = {
  name: '${appName}/virtualNetwork'
  properties: {
    subnetResourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, appIntegrationSubnetName)
    swiftSupported: true
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource appPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-app-${take(uniqueString(resourceGroup().id, appName), 6)}'
  location: location
  tags: normalizedTags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, privateEndpointSubnetName)
    }
    privateLinkServiceConnections: [
      {
        name: 'app-connection'
        properties: {
          privateLinkServiceId: app.id
          groupIds: [
            'sites'
          ]
          requestMessage: 'Step2 private endpoint for App Service.'
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-kv-${take(uniqueString(resourceGroup().id, keyVaultName), 6)}'
  location: location
  tags: normalizedTags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, privateEndpointSubnetName)
    }
    privateLinkServiceConnections: [
      {
        name: 'kv-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
          requestMessage: 'Step2 private endpoint for Key Vault.'
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

resource tablePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-table-${take(uniqueString(resourceGroup().id, storageAccountName), 6)}'
  location: location
  tags: normalizedTags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, privateEndpointSubnetName)
    }
    privateLinkServiceConnections: [
      {
        name: 'table-connection'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'table'
          ]
          requestMessage: 'Step2 private endpoint for Storage Table.'
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

resource appZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: appPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'app-zone'
        properties: {
          privateDnsZoneId: appPrivateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    appZoneLink
  ]
}

resource keyVaultZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'kv-zone'
        properties: {
          privateDnsZoneId: keyVaultPrivateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    keyVaultZoneLink
  ]
}

resource tableZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: tablePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'table-zone'
        properties: {
          privateDnsZoneId: tablePrivateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    tableZoneLink
  ]
}

output applicationGatewayPublicIp string = appGatewayPublicIp.properties.ipAddress
output applicationGatewayPublicFqdn string = appGatewayPublicIp.properties.dnsSettings.fqdn
output applicationGatewayPublicIpName string = appGatewayPublicIp.name
output finalVnetName string = vnet.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
