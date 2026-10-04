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