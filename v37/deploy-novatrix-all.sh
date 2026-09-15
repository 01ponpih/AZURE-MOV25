#!/usr/bin/env bash
#
# deploy-novatrix-all.sh
#
# Kombinerat provisioneringsskript for Novatrix v34 (Compute), v35 (IAM) och v36 (Natverk).
#
# Kor i Azure Cloud Shell (bash) eller pa en Linux-/WSL-maskin med Azure CLI.
# Kraver inloggning: az login
#
# Kor hela filen: bash deploy-novatrix-all.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Gemensamma variabler
# ---------------------------------------------------------------------------
RG="rg-novatrix-v35"
LOCATION="swedencentral"
VNET_NAME="vnet-novatrix"
WEB_SUBNET="snet-web"
DATA_SUBNET="snet-db"
NSG_WEB="nsg-web"
VM_NAME="vm-novatrix-web"
VM_SIZE="Standard_B2ats_v2"
ADMIN_USER="azureuser"

IDENTITY_APP="id-novatrix-app"
GROUP_DRIFT="Azure-Drift"
GROUP_DEV="Azure-Utveckling"

# --- Vem far SSH:a in? (v36 natverk) ---
# ADMIN_IPS ar din lista av tillatna admin-adresser (t.ex. "203.0.113.10" "198.51.100.0/24")
ADMIN_IPS=()

# SSH_SOURCE_MODE: "All" eller "Listed"
SSH_SOURCE_MODE="All"

# Saker IP-detektering med timeout och felhantering
DETECTED_IP=$(curl -s --max-time 5 https://api.ipify.org || true)

if [ -n "$DETECTED_IP" ]; then
    DETECTED_IP="$DETECTED_IP/32"
    echo "Upptackte publik IP: $DETECTED_IP"
else
    echo "Varning: Kunde inte upptacka publik IP automatiskt."
fi

if [ "$SSH_SOURCE_MODE" == "All" ] && [ -n "$DETECTED_IP" ]; then
    SSH_SOURCES=("${ADMIN_IPS[@]}" "$DETECTED_IP")
else
    SSH_SOURCES=("${ADMIN_IPS[@]}")
fi

# Rensa dubbletter om listan innehaller element
if [ ${#SSH_SOURCES[@]} -gt 0 ]; then
    SSH_SOURCE_LIST=$(printf "%s\n" "${SSH_SOURCES[@]}" | sort -u)
    mapfile -t SSH_SOURCES <<< "$SSH_SOURCE_LIST"
    echo "SSH tillats fran: ${SSH_SOURCES[*]}"
else
    echo "Varning: Inga SSH-kallor angivna. Ingen SSH-regel skapas."
fi

# ---------------------------------------------------------------------------
# Cloud-init (v34) skrivs till en tillfallig fil
# ---------------------------------------------------------------------------
CLOUD_INIT=$(mktemp /tmp/novatrix-cloud-init-XXXX.yaml)

cat > "$CLOUD_INIT" << 'EOF'
#cloud-config
package_update: true
packages:
  - nginx
write_files:
  - path: /var/www/html/index.html
    content: |
      <!DOCTYPE html>
      <html lang="sv">
      <head>
        <meta charset="UTF-8">
        <title>Novatrix AB - Kundtj&auml;nst</title>
        <style>
          body { font-family: sans-serif; max-width: 500px; margin: 60px auto; }
          label { display: block; margin-top: 12px; }
          input, textarea { width: 100%; padding: 8px; box-sizing: border-box; }
          button { margin-top: 16px; padding: 10px 20px; }
        </style>
      </head>
      <body>
        <h1>Novatrix AB</h1>
        <p>V&auml;lkommen till v&aring;r kundtj&auml;nst. Fyll i formul&auml;ret nedan s&aring; &aring;terkommer vi s&aring; fort vi kan.</p>
        <form>
          <label for="namn">Namn</label>
          <input type="text" id="namn" name="namn">
          <label for="epost">E-post</label>
          <input type="email" id="epost" name="epost">
          <label for="meddelande">Meddelande</label>
          <textarea id="meddelande" name="meddelande" rows="5"></textarea>
          <button type="submit">Skicka</button>
        </form>
      </body>
      </html>
runcmd:
  - systemctl enable nginx
  - systemctl restart nginx
EOF

echo "Cloud-init skriven till tillfallig fil: $CLOUD_INIT"

# ===========================================================================
# STEG 1 (v36) - Resursgrupp och natverk
# ===========================================================================
echo ""
echo "== STEG 1: Resursgrupp och natverk =="

az group create --name "$RG" --location "$LOCATION"

az network vnet create \
  --resource-group "$RG" --name "$VNET_NAME" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$WEB_SUBNET" --subnet-prefix 10.0.1.0/24

az network vnet subnet create \
  --resource-group "$RG" --vnet-name "$VNET_NAME" \
  --name "$DATA_SUBNET" --address-prefix 10.0.2.0/24

# NSG for webbsubnat
az network nsg create --resource-group "$RG" --name "$NSG_WEB"

az network nsg rule create \
  --resource-group "$RG" --nsg-name "$NSG_WEB" \
  --name allow-web --priority 100 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 80

if [ ${#SSH_SOURCES[@]} -gt 0 ]; then
  az network nsg rule create \
    --resource-group "$RG" --nsg-name "$NSG_WEB" \
    --name allow-ssh-admin --priority 120 --direction Inbound --access Allow \
    --protocol Tcp --destination-port-ranges 22 \
    --source-address-prefixes "${SSH_SOURCES[@]}"
fi

az network vnet subnet update \
  --resource-group "$RG" --vnet-name "$VNET_NAME" --name "$WEB_SUBNET" \
  --network-security-group "$NSG_WEB"

# ===========================================================================
# STEG 2 (v34) - Virtuell maskin
# ===========================================================================
echo ""
echo "== STEG 2: Virtuell server =="

az vm create \
  --resource-group "$RG" --name "$VM_NAME" \
  --image Ubuntu2404 --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" --generate-ssh-keys \
  --vnet-name "$VNET_NAME" --subnet "$WEB_SUBNET" \
  --nsg "" \
  --custom-data "$CLOUD_INIT"

PUBLIC_IP=$(az vm list-ip-addresses --resource-group "$RG" --name "$VM_NAME" \
  --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)

echo "VM klar. Publik IP: $PUBLIC_IP"

# ===========================================================================
# STEG 3 (v35) - Identiteter, RBAC och Managed Identity
# ===========================================================================
echo ""
echo "== STEG 3: IAM och identitet =="

RG_ID=$(az group show --name "$RG" --query id -o tsv)

# --- Idempotent hantering av Entra ID-grupper ---
DRIFT_GROUP_ID=$(az ad group show --group "$GROUP_DRIFT" --query id -o tsv 2>/dev/null || true)
if [ -z "$DRIFT_GROUP_ID" ]; then
    echo "Skapar Entra ID-grupp: $GROUP_DRIFT"
    DRIFT_GROUP_ID=$(az ad group create --display-name "$GROUP_DRIFT" --mail-nickname "$GROUP_DRIFT" --query id -o tsv)
else
    echo "Entra ID-grupp $GROUP_DRIFT existerar redan."
fi

DEV_GROUP_ID=$(az ad group show --group "$GROUP_DEV" --query id -o tsv 2>/dev/null || true)
if [ -z "$DEV_GROUP_ID" ]; then
    echo "Skapar Entra ID-grupp: $GROUP_DEV"
    DEV_GROUP_ID=$(az ad group create --display-name "$GROUP_DEV" --mail-nickname "$GROUP_DEV" --query id -o tsv)
else
    echo "Entra ID-grupp $GROUP_DEV existerar redan."
fi

# Vanta pa att grupperna replikeras i Entra ID innan RBAC tilldelas,
# men bara om grupperna faktiskt just skapades.
echo "Vantar 10 sekunder pa Entra ID-replikering..."
sleep 10

# --- RBAC, idempotent: skapa bara tilldelningen om den inte redan finns ---
assign_role_if_missing() {
    local assignee="$1"
    local role="$2"
    local scope="$3"
    local existing
    existing=$(az role assignment list \
        --assignee "$assignee" --role "$role" --scope "$scope" \
        --query "[0].id" -o tsv 2>/dev/null || true)

    if [ -z "$existing" ]; then
        echo "Tilldelar roll '$role' till $assignee"
        az role assignment create --assignee "$assignee" --role "$role" --scope "$scope"
    else
        echo "Rolltilldelning '$role' for $assignee finns redan, hoppar over."
    fi
}

assign_role_if_missing "$DRIFT_GROUP_ID" "Contributor" "$RG_ID"
assign_role_if_missing "$DEV_GROUP_ID" "Reader" "$RG_ID"

# --- Managed Identity ---
az identity create --resource-group "$RG" --name "$IDENTITY_APP"

# Hamta identitetens fullstandiga resurs-ID. Kravs av --identities nedan,
# det racker inte att bara ange namnet.
IDENTITY_ID=$(az identity show \
  --resource-group "$RG" --name "$IDENTITY_APP" \
  --query id -o tsv)

# Koppla den hanterade identiteten till servern (idempotent i sig sjalvt,
# att kora om det ar redan tilldelat orsakar inget fel)
az vm identity assign \
  --resource-group "$RG" \
  --name "$VM_NAME" \
  --identities "$IDENTITY_ID"

# Stada bort den tillfalliga cloud-init-filen
rm -f "$CLOUD_INIT"

echo ""
echo "======================================================================="
echo "Klart! Hela miljon ar aterskapad."
echo "Observera: Nginx installeras via cloud-init i bakgrunden vid forsta start."
echo "Det kan ta 1-2 minuter innan http://$PUBLIC_IP svarar i webblasaren."
echo ""
echo "For att riva miljon nar du ar klar:"
echo "  az group delete --name $RG --yes --no-wait"
echo "======================================================================="
