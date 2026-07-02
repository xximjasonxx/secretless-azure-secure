targetScope = 'resourceGroup'

@description('Location for the manual-approval private endpoint.')
param location string = resourceGroup().location

@description('Name of the private endpoint to create for the pending approval demo.')
param privateEndpointName string = 'pe-manual-pending-demo'

@description('Subnet resource ID where the private endpoint NIC is created (typically snet-pe).')
param peSubnetResourceId string

@description('Target PaaS resource ID to request connection to (for example a storage account or key vault).')
param targetResourceId string

@description('Group ID on the target resource. Use "blob" for Storage Blob or "vault" for Key Vault.')
param groupId string = 'blob'

@description('Message shown to the resource owner during manual approval.')
param requestMessage string = 'Manual approval requested for conference demo (simulate cross-team consumer).'

@description('Optional resource tags.')
param tags object = {}

var normalizedTags = union(tags, {
  'SecurityControl': 'Ignore'
})

resource manualApprovalPe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: privateEndpointName
  location: location
  tags: normalizedTags
  properties: {
    subnet: {
      id: peSubnetResourceId
    }
    // Manual flow:
    // The deciding factor is RBAC permission
    // Microsoft.<provider>/.../privateEndpointConnectionsApproval/action on the target resource.
    // If caller lacks that action, the connection lands in Pending until owner approval.
    manualPrivateLinkServiceConnections: [
      {
        name: 'manual-${groupId}-connection'
        properties: {
          privateLinkServiceId: targetResourceId
          groupIds: [
            groupId
          ]
          requestMessage: requestMessage
        }
      }
    ]
  }
}

output manualPrivateEndpointId string = manualApprovalPe.id
