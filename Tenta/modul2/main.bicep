@description('Azure-region för resurserna')
param location string = resourceGroup().location

@description('Projektnamn som används för att bygga resursnamn')
param projectName string = 'nordvik'

@description('Globalt unikt namn för Azure Container Registry')
param acrName string = 'acrnordvikponpih01'

@description('Globalt unikt namn för storage account')
param storageAccountName string = 'stnordvikponpih01'

@description('Image-tag för portalen')
param imageName string = 'nordvik-portal:latest'

@description('Sätts till true i steg 2 av deploy.sh efter att imagen byggts och pushats.')
param deployApp bool = false

@description('Taggar som appliceras på alla resurser')
param tags object = {
  Company: 'Nordvik'
  Environment: 'Production'
  CostCenter: 'Forvaltning'
  Fastighet: 'Alla'
  ManagedBy: 'IaC'
}

// Resursnamn som byggs från projectName
var containerAppName = 'ca-${projectName}-portal'
var containerEnvName = 'cae-${projectName}'
var logAnalyticsWorkspaceName = 'log-${projectName}'
var identityName = 'id-${projectName}-web'
var vnetName = 'vnet-${projectName}'
var subnetAcaName = 'snet-aca'
var subnetPeName = 'snet-pe'
var nsgAcaName = 'nsg-aca'

// Fast GUID:n för inbyggda Azure-roller
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

// NSG för Container Apps-subnätet
// Tillåter endast port 80 och 443 in från internet. Allt annat nekas.
resource nsgAca 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgAcaName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-HTTPS-Inbound'
        properties: {
          description: 'HTTPS från internet till portalen'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'Allow-HTTP-Inbound'
        properties: {
          description: 'HTTP från internet (vidarebefordras till HTTPS)'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer'
        properties: {
          description: 'Krävs av Container Apps för health checks'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 120
          direction: 'Inbound'
        }
      }
    ]
  }
}

// VNet med snet-aca (Container Apps) och snet-pe (förberett för Private Endpoint)
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: subnetAcaName
        properties: {
          addressPrefix: '10.0.0.0/23'
          delegations: [
            {
              name: 'aca-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
          ]
          networkSecurityGroup: {
            id: nsgAca.id
          }
        }
      }
      {
        name: subnetPeName
        properties: {
          addressPrefix: '10.0.4.0/24'
        }
      }
    ]
  }
}

resource subnetAca 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: subnetAcaName
}

// Storage Account
// Service Endpoint på subnätet ger åtkomst via Azure-backbone.
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: subnetAca.id
          action: 'Allow'
        }
      ]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource felanmalningarContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'felanmalningar'
}

resource kontraktContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'kontrakt'
}

// Flyttar kontrakt till Cool-lagringsnivå efter 90 dagar
resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'kontrakt-till-cool'
          enabled: true
          type: 'Lifecycle'
          definition: {
            actions: {
              baseBlob: {
                tierToCool: { daysAfterModificationGreaterThan: 90 }
              }
            }
            filters: {
              blobTypes: [ 'blockBlob' ]
              prefixMatch: [ 'kontrakt/' ]
            }
          }
        }
      ]
    }
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource managedEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: containerEnvName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: subnetAca.id
      internal: false
    }
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource blobDataContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(felanmalningarContainer.id, identity.id, blobDataContributorRoleId)
  scope: felanmalningarContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = if (deployApp) {
  name: containerAppName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
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
          name: 'portal'
          image: '${acr.properties.loginServer}/${imageName}'
          resources: { cpu: json('0.5'), memory: '1.0Gi' }
          env: [
            { name: 'AZURE_STORAGE_BLOB_URL', value: storageAccount.properties.primaryEndpoints.blob }
            { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
          ]
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/health', port: 80 }
              initialDelaySeconds: 10
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: { path: '/health', port: 80 }
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 10
        rules: [
          {
            name: 'daytime'
            custom: {
              type: 'cron'
              metadata: {
                timezone: 'Europe/Stockholm'
                start: '0 6 * * *'
                end: '0 22 * * *'
                desiredReplicas: '2'
              }
            }
          }
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [ acrPullRole, blobDataContributorRole ]
}

output acrLoginServer string = acr.properties.loginServer
output storageAccountName string = storageAccount.name
output containerAppName string = deployApp ? containerApp!.name : ''
output containerAppFQDN string = deployApp ? containerApp!.properties.configuration.ingress.fqdn : ''
output logAnalyticsWorkspaceId string = logAnalytics.id
output identityClientId string = identity.properties.clientId
output nsgName string = nsgAca.name
