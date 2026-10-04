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