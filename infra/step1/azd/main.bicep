targetScope = 'subscription'

@description('azd environment name.')
param environmentName string

@description('Primary Azure region for this demo.')
param location string

@description('Optional existing resource group name override.')
param existingResourceGroupName string = ''

var defaultResourceGroupName = environmentName == 'demo'
  ? 'rg-securetalk-poc-swc-mx01'
  : 'rg-securetalk-poc-swc-mx01-${environmentName}'
var resourceGroupName = empty(existingResourceGroupName) ? defaultResourceGroupName : existingResourceGroupName

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: {
    'azd-env-name': environmentName
    'demo-stage': 'step1'
    'SecurityControl': 'Ignore'
  }
}

output AZURE_RESOURCE_GROUP string = resourceGroupName
output AZURE_LOCATION string = location
