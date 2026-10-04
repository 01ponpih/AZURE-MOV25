# Azure Uppgift 7

## Repo

Länk till GitHub-repo: https://github.com/01ponpih/AZURE-MOV25

Följande filer finns i `v40/`:

### modul1 – Azure Function

| Fil | Beskrivning |
| :--- | :--- |
| `function_app.py` | Blob-trigger som skickar ärenden till Power Automate |
| `main.bicep` | Skapar Function App och kopplar den till lagringskontot |
| `host.json` | Konfiguration för Function App |
| `requirements.txt` | Python-beroenden |
| `deploy.sh` | Publicerar koden till Azure |

### modul2 – Webbapp i container

| Fil | Beskrivning |
| :--- | :--- |
| `app.py` | Flask-app som tar emot formuläret |
| `Dockerfile` | Bygger containern |
| `main.bicep` | Skapar storage, ACR, Container App och Log Analytics |
| `requirements.txt` | Python-beroenden |
| `deploy.sh` | Bygger, pushar och deployar containern |

## Delmoment 2 – Alternativ nivå

Kundtjänstens två delar körs nu på två olika virtualiseringsnivåer:

- Webbformuläret körs som en container på Azure Container Apps
- Ärendemottagningen körs som en serverless-funktion i Azure Functions

Webbappen tar emot formuläret och sparar ärendet som en JSON-fil i Blob Storage.
Den svarar användaren direkt utan att vänta på vidare bearbetning. Function Appen
triggas av den nya filen och skickar ärendet vidare till Power Automate.

### Deployment

Modulerna körs i följande ordning eftersom modul1 är beroende av modul2:

**Modul 2** – skapar infrastruktur och webbapp
   ```bash
   cd ../modul2
   bash deploy.sh
   ```
**Modul 1** – skapar Function App och kopplar den till lagringskontot
```bash
cd ../modul1
export POWER_AUTOMATE_WEBHOOK_URL="https://..."
bash deploy.sh
```

## Delmoment 3 – Jämförelse av nivåerna

| Nivå | Vad man hanterar | Kostnad | Skalbarhet |
| :--- | :--- | :--- | :--- |
| VM | Operativsystem, patchar, nätverk, app | Fast timkostnad dygnet runt | Manuell |
| Container | App och beroenden | Per instans, kan skalas till noll | Automatisk |
| Serverless | Endast koden | Per körning | Automatisk |

**VM** kör en hel dator i molnet. Man ansvarar för operativsystemet och betalar
för maskinen även när ingen använder den. Det passar inte för en enkel
ärendemottagning.

**Container** paketerar appen med allt den behöver. Den startar snabbare än en VM
och kan skalas automatiskt. Container Apps kan gå ner till noll instanser när
ingen trafik finns.

**Serverless** innebär att man bara laddar upp koden och molnet sköter resten.
Man betalar endast för den tid koden körs. Det passar bra för korta,
händelsestyrda uppgifter som att ta emot en fil och skicka vidare den.

För ärendemottagningen passar serverless bäst. Uppgiften är händelsestyrd och
exekveras sporadiskt. En VM hade medfört onödig drift och dygnet-runt-kostnader,
medan en dedikerad container som ständigt lyssnar efter filer hade varit
överdimensionerad. Med serverless existerar mottagningen bara exakt den sekund
ett ärende behöver hanteras.

## Delmoment 4 – Verifiering

Flödet verifieras genom att skicka ett ärende via webbformuläret.

1. Öppna appens URL och fyll i formuläret
2. Ärendet sparas som en JSON-fil i containern arenden
3. Function Appen triggas av filen
4. Ärendet skickas vidare till Power Automate

Kontroll av blobbar:

```bash
az storage blob list \
  --account-name <storage-namn> \
  --container-name arenden \
  --auth-mode login \
  --query "[].name" -o tsv
  ```

Kontroll av felmeddelanden i Log Analytics:
```text
ContainerAppConsoleLogs_CL
| where Log_s contains "ERROR" or Log_s contains "Exception"
| project TimeGenerated, ContainerAppName_s, Log_s
| sort by TimeGenerated desc
```
Skärmdumpar med bekträftelse av funktionalitet finns i repot för v40.

## VG – Motivering
### Kostnad.
 Webbappen körs med minReplicas: 0 och stängs ner helt när ingen
trafik finns. Function Appen körs på Consumption-plan och kostar bara under de
sekunder ett ärende behandlas. En VM hade kostat dygnet runt oavsett belastning.

### Skalbarhet. 
Container Apps skalar automatiskt mellan noll och tre instanser
beroende på trafik. Function Appen skalar automatiskt vid varje ny händelse. En
VM hade behövt dimensioneras för högsta förväntade belastning.

### Drift. 
Inga operativsystem att patcha. Inga nycklar eller connection strings
i koden. Webbappen och Function Appen använder managed identity för att komma åt
Blob Storage. Webbappen har rollen Storage Blob Data Contributor begränsat till
containern arenden, och Function Appen har samma roll på lagringskontot. Det
följer principen om minsta behörighet.

### Provisionering som kod. 
All infrastruktur skapas med Bicep. modul2/main.bicep
skapar storage account, container registry, Log Analytics, Container Apps-miljö
och webbappen. modul1/main.bicep skapar Function App och kopplar den till
lagringskontot. Inga manuella steg i portalen behövs.

### Optimering. 
Nästa steg i en produktionsmiljö vore att låsa storage-kontot
bakom en private endpoint i ett virtuellt nätverk, så att trafiken aldrig
lämnar Azures interna nätverk. Det hade gett ytterligare säkerhet men krävt mer
konfiguration och högre kostnad. För kursens omfattning har jag valt att hålla
lösningen enkel och reproducerbar.


## Kod

### modul2/main.bicep

```bicep
param location string = resourceGroup().location
param projectName string = 'novatrix'
param acrName string = 'acrnovatrix${uniqueString(resourceGroup().id)}'
param storageAccountName string = 'stnovatrix${uniqueString(resourceGroup().id)}'
param imageName string = 'novatrix-processor:latest'

@description('Sätts till true i steg 2 av deploy.sh efter att imagen byggts och pushats. Första deploymenten ska köra med false.')
param deployApp bool = false

var containerAppName = 'app-${projectName}'
var containerEnvName = 'env-${projectName}'
var logAnalyticsWorkspaceName = 'log-${projectName}'
var identityName = 'id-${projectName}-web'

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource arendenContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'arenden'
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// Container Apps Environment med Log Analytics-koppling
resource managedEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: containerEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// User-Assigned Managed Identity – existerar innan appen skapas.
// Detta löser ACR-race-conditionen strukturellt: rollen är på plats
// innan containern försöker hämta sin image.
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
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
  name: guid(arendenContainer.id, identity.id, blobDataContributorRoleId)
  scope: arendenContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Skapas endast vid steg 2 (deployApp=true), efter att imagen pushas.
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = if (deployApp) {
  name: containerAppName
  location: location
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
          name: 'web'
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
      scale: { minReplicas: 0, maxReplicas: 3 }
    }
  }
  dependsOn: [acrPullRole, blobDataContributorRole]
}

output acrLoginServer string = acr.properties.loginServer
output storageAccountName string = storageAccount.name
output containerAppName string = deployApp ? containerApp!.name : ''
output containerAppFQDN string = deployApp ? containerApp!.properties.configuration.ingress.fqdn : ''
output logAnalyticsWorkspaceId string = logAnalytics.id
output identityClientId string = identity.properties.clientId

```

### modul2/app.py

```python
import os
import json
import uuid
import datetime
import logging
import base64
from flask import Flask, request, render_template_string
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="sv">
<head>
    <meta charset="UTF-8">
    <title>Novatrix AB - Support</title>
    <style>
        body { font-family: sans-serif; background-color: #f0f2f5; margin: 0; padding: 20px; display: flex; justify-content: center; align-items: center; min-height: 100vh; }
        .container { background: #ffffff; padding: 40px; border-radius: 10px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); width: 100%; max-width: 500px; box-sizing: border-box; }
        h1 { text-align: center; color: #333; margin-top: 0; }
        p { text-align: center; color: #555; margin-bottom: 25px; }
        label { display: block; margin-top: 15px; font-weight: bold; color: #333; }
        input, textarea { width: 100%; padding: 10px; margin-top: 5px; box-sizing: border-box; border: 1px solid #ccc; border-radius: 5px; font-size: 1rem; }
        button { margin-top: 25px; width: 100%; padding: 12px 20px; background-color: #0078d4; color: white; border: none; border-radius: 5px; font-size: 1.1rem; cursor: pointer; transition: 0.2s; }
        button:hover { background-color: #005a9e; }
        .error { color: #d13438; margin-top: 15px; font-weight: bold; text-align: center; }
        .success-box { background: #ffffff; padding: 40px; border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.1); text-align: center; max-width: 500px; width: 100%; box-sizing: border-box; }
        .success-box h1 { color: #107c10; font-size: 2.5rem; margin-top: 0; margin-bottom: 10px; }
        .ref-box { background: #f3f2f1; padding: 15px; border-radius: 6px; font-family: monospace; font-size: 1.1rem; color: #000; word-break: break-all; margin-top: 15px; }
    </style>
</head>
<body>
    {% if success_id %}
    <div class="success-box">
        <h1>Tack!</h1>
        <p>Ditt ärende har sparats och behandlas nu.</p>
        <div class="ref-box">
            <strong>Referensnummer:</strong><br>{{ success_id }}
        </div>
    </div>
    {% else %}
    <div class="container">
        <h1>Novatrix AB</h1>
        <p>Hej! Fyll i uppgifterna nedan, vi svarar inom 24h.</p>
        {% if error_msg %}<p class="error">{{ error_msg }}</p>{% endif %}
        <form method="POST" enctype="multipart/form-data">
            <label for="namn">Namn</label>
            <input type="text" id="namn" name="namn" required>
            
            <label for="epost">E-post</label>
            <input type="email" id="epost" name="epost" required>
            
            <label for="meddelande">Meddelande</label>
            <textarea id="meddelande" name="meddelande" rows="5" required></textarea>
            
            <label for="bilaga">Bifoga fil (om du vill)</label>
            <input type="file" id="bilaga" name="bilaga">
            
            <button type="submit">Skicka</button>
        </form>
    </div>
    {% endif %}
</body>
</html>
"""

@app.route("/health", methods=["GET"])
def health():
    return "OK", 200

@app.route("/", methods=["GET", "POST"])
def index():
    if request.method == "POST":
        arende_id = str(uuid.uuid4())
        namn = request.form.get("namn")
        epost = request.form.get("epost")
        meddelande = request.form.get("meddelande")

        has_attachment = False
        attachment_name = ""
        attachment_base64 = ""

        fil = request.files.get("bilaga")
        if fil and fil.filename != "":
            has_attachment = True
            attachment_name = fil.filename
            file_bytes = fil.read()
            attachment_base64 = base64.b64encode(file_bytes).decode('utf-8')

        payload = {
            "id": arende_id,
            "name": namn,
            "mail": epost,
            "message": meddelande,
            "created": datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
            "has_attachment": has_attachment,
            "attachment_name": attachment_name,
            "attachment_content_base64": attachment_base64
        }

        blob_url = os.getenv("AZURE_STORAGE_BLOB_URL")

        try:
            if blob_url:
                credential = DefaultAzureCredential()
                blob_service_client = BlobServiceClient(account_url=blob_url, credential=credential)
                
                blob_client = blob_service_client.get_blob_client(container="arenden", blob=f"arende-{arende_id}.json")
                blob_client.upload_blob(json.dumps(payload, ensure_ascii=False), overwrite=True)
                
                return render_template_string(HTML_TEMPLATE, success_id=arende_id)
            else:
                return render_template_string(HTML_TEMPLATE, error_msg="Systemfel: Lagrings-URL saknas.")
        except Exception as e:
            app.logger.error(f"Kunde inte spara ärende: {e}")
            return render_template_string(HTML_TEMPLATE, error_msg="Ett fel uppstod när ärendet skulle sparas. Försök igen.")

    return render_template_string(HTML_TEMPLATE)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
```

### modul2/Dockerfile

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 80
CMD ["gunicorn", "-b", "0.0.0.0:80", "app:app"]
```

### modul2/requirements.txt

```text
flask
azure-storage-blob
azure-identity
gunicorn
```

### modul2/deploy.sh

```bash
#!/bin/bash
set -e
# Krävs i Git Bash på Windows för att undvika path-konvertering
export MSYS_NO_PATHCONV=1

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-novatrix}"
LOCATION="swedencentral"
GROUP_NAME="novatrix-drift"
IMAGE_TAG="novatrix-processor:latest"

echo "0. Verifierar Azure-kontext..."
CURRENT_SUB=$(az account show --query name -o tsv 2>/dev/null || echo "")
if [ -z "$CURRENT_SUB" ]; then
  echo "Fel: Ingen aktiv Azure-prenumeration. Kör 'az login' först."
  exit 1
fi
echo "   Prenumeration: $CURRENT_SUB"

echo "0b. Säkerställer att resursgruppen finns..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" -o none

echo "1. Steg 1: Infrastruktur, UAI och roller (utan app)..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file main.bicep \
  --parameters deployApp=false -o none

ACR_SERVER=$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name main \
  --query properties.outputs.acrLoginServer.value -o tsv)

STORAGE_NAME=$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name main \
  --query properties.outputs.storageAccountName.value -o tsv)

ACR_NAME="${ACR_SERVER%%.*}"

echo "Infrastruktur klar! ACR: $ACR_SERVER | Storage: $STORAGE_NAME"

echo "2. Tilldelar behörigheter till Entra ID-gruppen '$GROUP_NAME' (VG)..."
RG_ID=$(az group show --name "$RESOURCE_GROUP" --query id -o tsv)

GROUP_ID=$(az ad group show --group "$GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")

if [ -z "$GROUP_ID" ]; then
  echo "   Fel: Gruppen '$GROUP_NAME' finns inte i Entra ID."
  echo "   Skapa den manuellt en gång:"
  echo "     az ad group create --display-name '$GROUP_NAME' --mail-nickname '$GROUP_NAME'"
  echo "   Avbryter."
  exit 1
fi

echo "   Gruppen hittad: $GROUP_ID"

echo "   Tilldelar 'Reader' på resursgruppen..."
ROLE_OUTPUT=$(az role assignment create \
  --assignee-object-id "$GROUP_ID" \
  --assignee-principal-type Group \
  --role "Reader" \
  --scope "$RG_ID" 2>&1) || true

if echo "$ROLE_OUTPUT" | grep -qi "RoleAssignmentExists\|already exists"; then
  echo "   (Reader var redan tilldelad)"
elif echo "$ROLE_OUTPUT" | grep -qi "MissingSubscription\|AuthorizationFailed\|Forbidden"; then
  echo "   Fel vid Reader-tilldelning:"
  echo "   $ROLE_OUTPUT"
else
  echo "   Reader tilldelad."
fi

echo "   Tilldelar 'Storage Blob Data Contributor' på storage-kontot..."
STORAGE_ID=$(az storage account show \
  --name "$STORAGE_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

ROLE_OUTPUT=$(az role assignment create \
  --assignee-object-id "$GROUP_ID" \
  --assignee-principal-type Group \
  --role "Storage Blob Data Contributor" \
  --scope "$STORAGE_ID" 2>&1) || true

if echo "$ROLE_OUTPUT" | grep -qi "RoleAssignmentExists\|already exists"; then
  echo "   (Storage Blob Data Contributor var redan tilldelad)"
elif echo "$ROLE_OUTPUT" | grep -qi "MissingSubscription\|AuthorizationFailed\|Forbidden"; then
  echo "   Fel vid Storage-tilldelning:"
  echo "   $ROLE_OUTPUT"
  echo "   Fortsätter ändå (appen påverkas inte)."
else
  echo "   Storage Blob Data Contributor tilldelad."
fi

echo "3. Bygger och pushar Docker-image..."
az acr login --name "$ACR_NAME"
docker build -t "$ACR_SERVER/$IMAGE_TAG" .
docker push "$ACR_SERVER/$IMAGE_TAG"

echo "4. Skapar Container App med retry-loop (väntar på AcrPull-propagering)..."
APP_DEPLOYED=false
LAST_ERROR=""
for i in {1..10}; do
  echo "   Försök $i/10..."

  if LAST_ERROR=$(az deployment group create \
      --resource-group "$RESOURCE_GROUP" \
      --template-file main.bicep \
      --parameters deployApp=true imageName="$IMAGE_TAG" -o none 2>&1); then
    echo "   Appen utrullad och rättigheterna har slagit igenom!"
    APP_DEPLOYED=true
    break
  fi

  if ! echo "$LAST_ERROR" | grep -qi "unauthorized\|forbidden\|permission\|acrpull\|401\|403\|operation expired\|failed to provision"; then
    echo "   Felet verkar inte bero på rättighetspropagering. Avbryter."
    echo "$LAST_ERROR"
    exit 1
  fi

  echo "   Väntar 30 sekunder innan nästa försök..."
  sleep 30
done

if [ "$APP_DEPLOYED" = false ]; then
  echo "Fel: Kunde inte rulla ut Container Appen efter 10 försök."
  echo "Sista felmeddelande:"
  echo "$LAST_ERROR"
  exit 1
fi

APP_NAME=$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name main \
  --query properties.outputs.containerAppName.value -o tsv)

echo "5. Verifierar hälsostatus..."
APP_FQDN=$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv)

echo "Appens URL: https://$APP_FQDN"

for i in {1..10}; do
  if curl -sf "https://$APP_FQDN/health" > /dev/null; then
    echo "   Health Check: OK (200 OK)"
    break
  fi
  echo "   Väntar på att appen svarar ($i/10)..."
  sleep 10
done

echo "Modul 2 är klar!"
```

### modul1/main.bicep

```bicep
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

```

### modul1/function_app.py

```python
import azure.functions as func
import logging
import requests
import json
import os

app = func.FunctionApp()

@app.blob_trigger(arg_name="myblob", path="arenden/{name}", connection="ARENDE_STORAGE")
def process_arende(myblob: func.InputStream):
    logging.info(f"Händelse fångad för blob: {myblob.name}")
    try:
        content = json.loads(myblob.read().decode('utf-8'))
        webhook_url = os.getenv("POWER_AUTOMATE_WEBHOOK_URL")
        
        if webhook_url:
            r = requests.post(webhook_url, json=content, timeout=10)
            r.raise_for_status()
            logging.info(f"Power Automate-notis skickades framgångsrikt! Statuskod: {r.status_code}")
        else:
            logging.warning("POWER_AUTOMATE_WEBHOOK_URL saknas i appsettings.")
    except Exception as e:
        logging.error(f"Ett fel uppstod vid behandling eller webhook-anrop: {e}")
        raise
```

### modul1/host.json

```json
{
  "version": "2.0",
  "logging": {
    "applicationInsights": {
      "samplingSettings": {
        "isEnabled": true,
        "excludedTypes": "Request"
      }
    }
  },
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.*, 5.0.0)"
  }
}
```

### modul1/requirements.txt

```text
azure-functions
requests
```

### modul1/deploy.sh

```bash
#!/bin/bash
set -e
# Krävs i Git Bash på Windows för att undvika path-konvertering
export MSYS_NO_PATHCONV=1

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-novatrix}"
WEBHOOK_URL="${POWER_AUTOMATE_WEBHOOK_URL:?Sätt miljövariabeln först: export POWER_AUTOMATE_WEBHOOK_URL='https://...'}"

echo "1. Hämtar lagringskontot från Modul 2..."
STORAGE_NAME=$(az storage account list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?starts_with(name, 'stnovatrix')].name | [0]" -o tsv)

if [ -z "$STORAGE_NAME" ]; then
  echo "Fel: Hittade inget lagringskonto med prefix 'stnovatrix' i '$RESOURCE_GROUP'."
  exit 1
fi

echo "2. Förbereder virtuell Python-miljö..."
if [ ! -d ".venv" ]; then
  python -m venv .venv
fi
source .venv/Scripts/activate || source .venv/bin/activate
pip install -r requirements.txt --quiet

echo "3. Rullar ut Bicep för Modul 1..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file main.bicep \
  --parameters modul2StorageAccountName="$STORAGE_NAME" \
               powerAutomateWebhookUrl="$WEBHOOK_URL" -o none

echo "4. Hämtar Function App-namn..."
FUNC_NAME=$(az functionapp list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?starts_with(name, 'func-novatrix')].name | [0]" -o tsv)

echo "5. Publicerar Python-kod till $FUNC_NAME..."
func azure functionapp publish "$FUNC_NAME" --python --build remote

echo "6. Verifierar registrerade triggers med retry-loop..."
TRIGGERS=""
for i in {1..6}; do
  TRIGGERS=$(az functionapp function list --name "$FUNC_NAME" --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || echo "")
  if [ -n "$TRIGGERS" ]; then
    break
  fi
  echo "   Väntar på att triggern registreras i Azure ($i/6)..."
  sleep 10
done

if [ -n "$TRIGGERS" ]; then
  for FUNC in $TRIGGERS; do
    BINDING=$(az functionapp function show \
      --name "$FUNC_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --function-name "$FUNC" \
      --query "config.bindings[?type=='blobTrigger'].type" -o tsv 2>/dev/null || echo "")
    if [ -n "$BINDING" ]; then
      echo "   Bekräftat: Funktionen '$FUNC' är aktiv med '$BINDING'!"
    fi
  done
else
  echo "Varning: Inga funktioner registrerades inom tidsramen."
fi

echo "7. Skickar testfil för verifiering av blob-trigger..."
TEST_FILE=$(mktemp)
echo '{"id":"test-auto","name":"Auto Test","mail":"test@novatrix.local","message":"Automatiskt funktionstest"}' > "$TEST_FILE"

if az storage blob upload \
  --account-name "$STORAGE_NAME" \
  --container-name arenden \
  --name "test-arende-$(date +%s).json" \
  --file "$TEST_FILE" \
  --auth-mode login -o none 2>/dev/null; then
  echo "   Testfil uppladdad till containern 'arenden'! Function App triggas i bakgrunden."
else
  echo "   Kunde inte ladda upp testfil automatiskt (kontrollera dina egna Storage Blob-rättigheter)."
fi
rm -f "$TEST_FILE"

echo "Modul 1 är redo!"
```