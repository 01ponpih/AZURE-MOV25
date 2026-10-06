#!/bin/bash
set -e
export MSYS_NO_PATHCONV=1

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-nordvik}"
WEBHOOK_URL="${POWER_AUTOMATE_WEBHOOK_URL:?Sätt miljövariabeln först: export POWER_AUTOMATE_WEBHOOK_URL='https://...'}"
IMAGE_TAG="nordvik-function:latest"

echo "0. Verifierar Azure-kontext..."
CURRENT_SUB=$(az account show --query name -o tsv 2>/dev/null || echo "")
if [ -z "$CURRENT_SUB" ]; then
  echo "Fel: Ingen aktiv Azure-prenumeration. Kör 'az login' först."
  exit 1
fi
echo "   Prenumeration: $CURRENT_SUB"

echo "1. Hämtar resurser från Modul 2..."
ACR_SERVER=$(az acr list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?starts_with(name, 'acrnordvik')].loginServer | [0]" -o tsv)

STORAGE_NAME=$(az storage account list \
  --resource-group "$RESOURCE_GROUP" \
  --query "[?starts_with(name, 'stnordvikponpih01')].name | [0]" -o tsv)

if [ -z "$ACR_SERVER" ] || [ -z "$STORAGE_NAME" ]; then
  echo "Fel: Kunde inte hitta ACR eller Storage från Modul 2."
  exit 1
fi

ACR_NAME="${ACR_SERVER%%.*}"

echo "   ACR: $ACR_SERVER"
echo "   Storage: $STORAGE_NAME"

echo "2. Bygger och pushar Function-imagen..."
az acr login --name "$ACR_NAME"
docker build -t "$ACR_SERVER/$IMAGE_TAG" .
docker push "$ACR_SERVER/$IMAGE_TAG"

echo "3. Steg 1: Skapar UAI och roller..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file main.bicep \
  --parameters deployFunction=false \
               powerAutomateWebhookUrl="$WEBHOOK_URL" -o none

echo "4. Väntar 60 sekunder på att rollerna propagerar..."
sleep 60

echo "5. Steg 2: Skapar Function Container App med KEDA Cron-scaler..."
FUNC_DEPLOYED=false
LAST_ERROR=""
for i in {1..10}; do
  echo "   Försök $i/10..."

  if LAST_ERROR=$(az deployment group create \
      --resource-group "$RESOURCE_GROUP" \
      --template-file main.bicep \
      --parameters deployFunction=true imageName="$IMAGE_TAG" \
                   powerAutomateWebhookUrl="$WEBHOOK_URL" -o none 2>&1); then
    echo "   Funktionen utrullad!"
    FUNC_DEPLOYED=true
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

if [ "$FUNC_DEPLOYED" = false ]; then
  echo "Fel: Kunde inte rulla ut Function Appen efter 10 försök."
  echo "Sista felmeddelande:"
  echo "$LAST_ERROR"
  exit 1
fi

echo "6. Väntar 30 sekunder på att funktionen startar..."
sleep 30

REPLICAS=$(az containerapp replica list \
  --name "func-nordvik-ponpih" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[].name" -o tsv 2>/dev/null || echo "")

if [ -n "$REPLICAS" ]; then
  echo "   Funktionen kör."
else
  echo "   Information: Inga replikaler aktiva just nu."
  echo "   Funktionen startar automatiskt kl. 06."
fi

echo "Modul 1 är klar!"