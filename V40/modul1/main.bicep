param location string = resourceGroup().location
param functionAppName string = 'func-novatrix-${uniqueString(resourceGroup().id)}'
param modul2StorageAccountName string
param powerAutomateWebhookUrl string = ''

// Hämtar befintligt lagringskonto från Modul 2
resource arendeStorage 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: modul2StorageAccountName
}

// Dedikerat lagringskonto för Function Appens interna WebJobs
resource funcStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'stfunc${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

resource appServicePlan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: 'plan-novatrix-func'
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2022-09-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'python|3.11'  
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${funcStorage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${funcStorage.listKeys().keys[0].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'POWER_AUTOMATE_WEBHOOK_URL'
          value: powerAutomateWebhookUrl
        }
        {
          name: 'ARENDE_STORAGE__blobServiceUri'
          value: arendeStorage.properties.primaryEndpoints.blob
        }
        {
          name: 'ARENDE_STORAGE__queueServiceUri'
          value: arendeStorage.properties.primaryEndpoints.queue
        }
        {
          name: 'ARENDE_STORAGE__credential'
          value: 'managedidentity'
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource funcBlobStoragePermission 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(arendeStorage.id, functionApp.name, blobDataContributorRoleId)
  scope: arendeStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppName string = functionApp.name
