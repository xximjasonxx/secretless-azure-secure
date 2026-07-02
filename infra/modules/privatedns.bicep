targetScope = 'resourceGroup'

@description('Resource location.')
param location string = resourceGroup().location

@description('Common tags.')
param tags object = {}
var normalizedTags = union(tags, {
  'SecurityControl': 'Ignore'
})

@description('Resource ID of the VNet to link to private DNS zones.')
param vnetResourceId string

@description('Resource ID of the subnet that hosts private endpoints.')
param peSubnetResourceId string

@description('Resource ID of Key Vault.')
param keyVaultResourceId string

@description('Resource ID of Storage account.')
param storageAccountResourceId string

@description('Name of the Key Vault private endpoint.')
param keyVaultPrivateEndpointName string

@description('Name of the Storage blob private endpoint.')
param storagePrivateEndpointName string

var keyVaultPrivateDnsZoneName = 'privatelink.vaultcore.azure.net'
var blobPrivateDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'

resource keyVaultZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: keyVaultPrivateDnsZoneName
  location: 'global'
  tags: normalizedTags
}

resource blobZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: blobPrivateDnsZoneName
  location: 'global'
  tags: normalizedTags
}

resource keyVaultZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: keyVaultZone
  name: 'link-${last(split(vnetResourceId, '/'))}'
  location: 'global'
  tags: normalizedTags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetResourceId
    }
  }
}

resource blobZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: blobZone
  name: 'link-${last(split(vnetResourceId, '/'))}'
  location: 'global'
  tags: normalizedTags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetResourceId
    }
  }
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: keyVaultPrivateEndpointName
  location: location
  tags: normalizedTags
  properties: {
    subnet: {
      id: peSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: 'kv-auto-approved'
        properties: {
          privateLinkServiceId: keyVaultResourceId
          groupIds: [
            'vault'
          ]
          // Auto flow: caller has approval rights on target resource, so this is approved during create.
          requestMessage: 'Automatic approval path for conference demo.'
        }
      }
    ]
  }
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: storagePrivateEndpointName
  location: location
  tags: normalizedTags
  properties: {
    subnet: {
      id: peSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: 'storage-auto-approved'
        properties: {
          privateLinkServiceId: storageAccountResourceId
          groupIds: [
            'blob'
          ]
          // Auto flow: caller has approval rights on target resource, so this is approved during create.
          requestMessage: 'Automatic approval path for conference demo.'
        }
      }
    ]
  }
}

resource keyVaultZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'kv-zone'
        properties: {
          privateDnsZoneId: keyVaultZone.id
        }
      }
    ]
  }
  dependsOn: [
    keyVaultZoneLink
  ]
}

resource blobZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-zone'
        properties: {
          privateDnsZoneId: blobZone.id
        }
      }
    ]
  }
  dependsOn: [
    blobZoneLink
  ]
}

output keyVaultPrivateEndpointId string = keyVaultPrivateEndpoint.id
output storagePrivateEndpointId string = storagePrivateEndpoint.id
