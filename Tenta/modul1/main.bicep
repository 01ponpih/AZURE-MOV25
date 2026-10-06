@description('Azure-region för resurserna')
param location string = resourceGroup().location

@description('Projektnamn som används för att bygga resursnamn')
param projectName string = 'nordvik'

@description('Globalt unikt namn för Function App (Container App)')
param functionAppName string = 'func-nordvik-ponpih'

@description('Globalt unikt namn för Azure Container Registry (från modul2)')
param acrName string = 'acrnordvikponpih01'

@description('Globalt unikt namn för storage account (från modul2)')
param storageAccountName string = 'stnordvikponpih01'

@description('Namn på Container Apps Environment (från modul2)')
param containerEnvName string = 'cae-nordvik'

@description('Image-tag för Function-containern')
param imageName string = 'nordvik-function:latest'

@description('Sätts till true i steg 2 av deploy.sh efter att imagen byggts och pushats.')
param deployFunction bool = false

@description('URL till Power Automate-flödet')
param powerAutomateWebhookUrl string = ''

@description('Taggar som appliceras på alla resurser')
param tags object = {
  Company: 'Nordvik'
  Environment: 'Production'
  CostCenter: 'Forvaltning'
  Fastighet: 'Alla'
  ManagedBy: 'IaC'
}

var identityName = 'id-${projectName}-func'

// Fast GUID:n för inbyggda Azure-roller
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var blobOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var tableContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var storageAccountContributorRoleId = '17d1049b-9a84-46fb-8f53-869881c3d3ab'

// Referenser till modul2-resurser
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource containerEnv 'Microsoft.App/managedEnvironments@2023-05-01' existing = {
  name: containerEnvName
}

// User-Assigned Managed Identity för Function Appen
// Används både för att hämta imagen från ACR och för att läsa/skriva till storage.
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

// Rolltilldelningar. Container Apps-hosting av Functions kräver:
// Blob Data Owner + Queue Data Contributor + Storage Account Contributor
// för att Function Hostens interna mekanismer ska fungera.
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource blobOwnerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, identity.id, blobOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobOwnerRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource queueContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, identity.id, queueContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', queueContributorRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource tableContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, identity.id, tableContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', tableContributorRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Account Contributor för att läsa tjänstens egenskaper
resource storageAccountContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, identity.id, storageAccountContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountContributorRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Function App som Container App i samma VNet som webbappen.
// KEDA Cron-scaler håller en replik igång 06-22 och skalar till noll
// övriga tider för att minimera kostnaden.
resource functionApp 'Microsoft.App/containerApps@2023-05-01' = if (deployFunction) {
  name: functionAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 80
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: identity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'function'
          image: '${acr.properties.loginServer}/${imageName}'
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: [
            // AZURE_CLIENT_ID används av DefaultAzureCredential för att veta vilken
            // managed identity som ska användas vid autentisering mot Azure.
            { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
            // Intern storage för Function Hostens mekanismer (receipts, checkpointing)
            { name: 'AzureWebJobsStorage__blobServiceUri', value: storageAccount.properties.primaryEndpoints.blob }
            { name: 'AzureWebJobsStorage__queueServiceUri', value: storageAccount.properties.primaryEndpoints.queue }
            { name: 'AzureWebJobsStorage__tableServiceUri', value: storageAccount.properties.primaryEndpoints.table }
            { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
            { name: 'AzureWebJobsStorage__clientId', value: identity.properties.clientId }
            // Storage som blob-triggern lyssnar på
            { name: 'ARENDE_STORAGE__blobServiceUri', value: storageAccount.properties.primaryEndpoints.blob }
            { name: 'ARENDE_STORAGE__queueServiceUri', value: storageAccount.properties.primaryEndpoints.queue }
            { name: 'ARENDE_STORAGE__credential', value: 'managedidentity' }
            { name: 'ARENDE_STORAGE__clientId', value: identity.properties.clientId }
            // Övriga inställningar
            { name: 'POWER_AUTOMATE_WEBHOOK_URL', value: powerAutomateWebhookUrl }
            { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
            { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 5
        rules: [
          {
            name: 'daytime'
            custom: {
              type: 'cron'
              metadata: {
                timezone: 'Europe/Stockholm'
                start: '0 6 * * *'
                end: '0 22 * * *'
                desiredReplicas: '1'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ acrPullRole, blobOwnerRole, queueContributorRole, tableContributorRole, storageAccountContributorRole ]
}

output functionAppName string = deployFunction ? functionApp!.name : ''
output functionAppFQDN string = deployFunction ? functionApp!.properties.configuration.ingress.fqdn : ''
