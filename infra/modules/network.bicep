targetScope = 'resourceGroup'

@description('Virtual network name.')
param name string

@description('Resource location.')
param location string = resourceGroup().location

@description('Common tags.')
param tags object = {}
var normalizedTags = union(tags, {
  'SecurityControl': 'Ignore'
})

@description('Subnet used by App Service regional VNet integration (outbound path).')
param appSubnetName string = 'snet-app'

@description('Subnet that holds private endpoints.')
param peSubnetName string = 'snet-pe'

@description('Address space for the demo VNet.')
param addressPrefix string = '10.42.0.0/16'

@description('Address prefix for App Service integration subnet.')
param appSubnetPrefix string = '10.42.1.0/24'

@description('Address prefix for private endpoint subnet.')
param peSubnetPrefix string = '10.42.2.0/24'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: name
  location: location
  tags: normalizedTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: [
      {
        name: appSubnetName
        properties: {
          addressPrefix: appSubnetPrefix
          delegations: [
            {
              name: 'delegate-to-appservice'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          // Required so private endpoints can be placed in this subnet.
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output appSubnetId string = '${vnet.id}/subnets/${appSubnetName}'
output peSubnetId string = '${vnet.id}/subnets/${peSubnetName}'
