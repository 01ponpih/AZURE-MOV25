#!/usr/bin/env bash
# deploy-novatrix-v36-final.sh
# Fullständig provisionering för Novatrix (v34-v36)

set -euo pipefail

# Azure CLI-konfiguration (tyst)
az config set extension.use_dynamic_install=yes_without_prompt > /dev/null 2>&1 || true
az config set extension.dynamic_install_allow_preview=true > /dev/null 2>&1 || true
az extension add --name bastion --upgrade > /dev/null 2>&1 || true

# --- Variabler ---
RG="rg-novatrix-v36"
LOCATION="swedencentral"
VNET_NAME="vnet-novatrix"
WEB_SUBNET="snet-web"
DATA_SUBNET="snet-db"
ADMIN_SUBNET="AzureBastionSubnet"
NSG_WEB="nsg-web"
NSG_DB="nsg-db"
VM_NAME="vm-novatrix-web"
VM_SIZE="Standard_B2ats_v2"
ADMIN_USER="azureuser"

IDENTITY_APP="id-novatrix-app"
GROUP_DRIFT="Azure-Drift"
GROUP_DEV="Azure-Utveckling"

BASTION_NAME="bastion-novatrix"
BASTION_PIP_NAME="pip-bastion-novatrix"
BASTION_SUBNET_PREFIX="10.0.3.0/26"

# --- Cloud-init (Nginx) ---
CLOUD_INIT=$(mktemp /tmp/novatrix-cloud-init-XXXX.yaml)

cat > "$CLOUD_INIT" << 'CLOUD_EOF'
#cloud-config
bootcmd:
  - apt-get update
package_update: false
packages:
  - nginx
write_files:
  - path: /var/www/html/index.html
    content: |
      <!DOCTYPE html>
      <html lang="sv">
      <head>
        <meta charset="UTF-8">
        <title>Novatrix AB - Kundtjänst</title>
        <style>
          body { font-family: sans-serif; max-width: 500px; margin: 60px auto; }
          label { display: block; margin-top: 12px; }
          input, textarea { width: 100%; padding: 8px; box-sizing: border-box; }
          button { margin-top: 16px; padding: 10px 20px; }
        </style>
      </head>
      <body>
        <h1>Novatrix AB</h1>
        <p>Välkommen till vår kundtjänst. Fyll i formuläret nedan så återkommer vi så fort vi kan.</p>
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
  - systemctl start nginx
  - systemctl restart nginx
CLOUD_EOF

echo "== STEG 1: Nätverk och säkerhet =="

# Resursgrupp
if ! az group show --name "$RG" &>/dev/null; then
    az group create --name "$RG" --location "$LOCATION" --output none
else
    echo "Resursgrupp $RG finns redan."
fi

# VNet (med webb-subnet initialt)
if ! az network vnet show --resource-group "$RG" --name "$VNET_NAME" &>/dev/null; then
    az network vnet create \
      --resource-group "$RG" --name "$VNET_NAME" \
      --address-prefix 10.0.0.0/16 \
      --subnet-name "$WEB_SUBNET" --subnet-prefix 10.0.1.0/24 \
      --output none
else
    echo "VNet $VNET_NAME finns redan."
fi

# Webb-subnät (om det saknas)
if ! az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET_NAME" --name "$WEB_SUBNET" &>/dev/null; then
    az network vnet subnet create \
      --resource-group "$RG" --vnet-name "$VNET_NAME" \
      --name "$WEB_SUBNET" --address-prefix 10.0.1.0/24 \
      --output none
    echo "Subnät $WEB_SUBNET skapades."
else
    echo "Subnät $WEB_SUBNET finns redan."
fi

# Data-subnät
if ! az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET_NAME" --name "$DATA_SUBNET" &>/dev/null; then
    az network vnet subnet create \
      --resource-group "$RG" --vnet-name "$VNET_NAME" \
      --name "$DATA_SUBNET" --address-prefix 10.0.2.0/24 \
      --output none
else
    echo "Subnät $DATA_SUBNET finns redan."
fi

# Bastion-subnät
if ! az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET_NAME" --name "$ADMIN_SUBNET" &>/dev/null; then
    az network vnet subnet create \
      --resource-group "$RG" --vnet-name "$VNET_NAME" \
      --name "$ADMIN_SUBNET" --address-prefix "$BASTION_SUBNET_PREFIX" \
      --output none
else
    echo "Subnät $ADMIN_SUBNET finns redan."
fi

# NSG för webb
if ! az network nsg show --resource-group "$RG" --name "$NSG_WEB" &>/dev/null; then
    az network nsg create --resource-group "$RG" --name "$NSG_WEB" --output none
else
    echo "NSG $NSG_WEB finns redan."
fi

# NSG för data (default deny)
if ! az network nsg show --resource-group "$RG" --name "$NSG_DB" &>/dev/null; then
    az network nsg create --resource-group "$RG" --name "$NSG_DB" --output none
else
    echo "NSG $NSG_DB finns redan."
fi

# Funktion för att lägga till NSG-regel om den saknas
add_nsg_rule_if_missing() {
    local nsg="$1"
    local rule_name="$2"
    local priority="$3"
    local direction="$4"
    local access="$5"
    local protocol="$6"
    local dest_port="$7"
    local source_prefix="${8:-*}"
    local dest_prefix="${9:-*}"

    if ! az network nsg rule show --resource-group "$RG" --nsg-name "$nsg" --name "$rule_name" &>/dev/null; then
        az network nsg rule create \
          --resource-group "$RG" --nsg-name "$nsg" \
          --name "$rule_name" --priority "$priority" --direction "$direction" --access "$access" \
          --protocol "$protocol" --destination-port-ranges "$dest_port" \
          --source-address-prefixes "$source_prefix" --destination-address-prefixes "$dest_prefix" \
          --output none
    else
        echo "Regel $rule_name i $nsg finns redan."
    fi
}

# Webbregler (HTTP/HTTPS från internet, SSH enbart från Bastion)
add_nsg_rule_if_missing "$NSG_WEB" "allow-web" 100 "Inbound" "Allow" "Tcp" "80" "Internet"
add_nsg_rule_if_missing "$NSG_WEB" "allow-https" 110 "Inbound" "Allow" "Tcp" "443" "Internet"
add_nsg_rule_if_missing "$NSG_WEB" "allow-ssh-from-bastion" 120 "Inbound" "Allow" "Tcp" "22" "$BASTION_SUBNET_PREFIX"

# Associera NSG:er till subnät
az network vnet subnet update \
  --resource-group "$RG" --vnet-name "$VNET_NAME" --name "$WEB_SUBNET" \
  --network-security-group "$NSG_WEB" --output none

az network vnet subnet update \
  --resource-group "$RG" --vnet-name "$VNET_NAME" --name "$DATA_SUBNET" \
  --network-security-group "$NSG_DB" --output none

echo "== STEG 2: Beräkningsresurser och Bastion =="

# Skapa VM om den inte finns (utan NSG på NIC-nivå)
if ! az vm show --resource-group "$RG" --name "$VM_NAME" &>/dev/null; then
    az vm create \
      --resource-group "$RG" --name "$VM_NAME" \
      --image Ubuntu2404 --size "$VM_SIZE" \
      --admin-username "$ADMIN_USER" --generate-ssh-keys \
      --vnet-name "$VNET_NAME" --subnet "$WEB_SUBNET" \
      --nsg "" \
      --custom-data "$CLOUD_INIT" \
      --output none
else
    echo "VM $VM_NAME finns redan."
fi

# Hämta publik IP
PUBLIC_IP=$(az vm list-ip-addresses --resource-group "$RG" --name "$VM_NAME" \
  --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv 2>/dev/null || echo "ingen")

# Publik IP för Bastion
if ! az network public-ip show --resource-group "$RG" --name "$BASTION_PIP_NAME" &>/dev/null; then
    az network public-ip create \
      --resource-group "$RG" --name "$BASTION_PIP_NAME" \
      --sku Standard --location "$LOCATION" --output none
else
    echo "Publik IP $BASTION_PIP_NAME finns redan."
fi

# Bastion
if ! az network bastion show --resource-group "$RG" --name "$BASTION_NAME" &>/dev/null; then
    az network bastion create \
      --resource-group "$RG" --name "$BASTION_NAME" \
      --vnet-name "$VNET_NAME" --public-ip-address "$BASTION_PIP_NAME" \
      --location "$LOCATION" --sku Standard --enable-tunneling true \
      --output none
else
    echo "Bastion $BASTION_NAME finns redan."
fi

echo "== STEG 3: Identitet och åtkomststyrning =="

RG_ID=$(az group show --name "$RG" --query id -o tsv)

# Funktion för att hämta eller skapa grupp – skriver endast GUID till stdout
get_or_create_group() {
    local display_name="$1"
    local mail_nickname="$2"
    local group_id

    group_id=$(az ad group show --group "$display_name" --query id -o tsv 2>/dev/null || true)
    if [ -z "$group_id" ]; then
        group_id=$(az ad group create --display-name "$display_name" --mail-nickname "$mail_nickname" --query id -o tsv)
        echo "Grupp $display_name skapades." >&2
        for i in {1..12}; do
            if az ad group show --group "$group_id" &>/dev/null; then
                break
            fi
            sleep 5
        done
    else
        echo "Grupp $display_name finns redan." >&2
    fi
    echo "$group_id"
}

DRIFT_GROUP_ID=$(get_or_create_group "$GROUP_DRIFT" "$GROUP_DRIFT")
DEV_GROUP_ID=$(get_or_create_group "$GROUP_DEV" "$GROUP_DEV")

# Funktion för idempotent rolltilldelning
assign_role_if_missing() {
    local assignee="$1"
    local role="$2"
    local scope="$3"
    local existing

    existing=$(az role assignment list \
        --assignee "$assignee" --role "$role" --scope "$scope" \
        --query "[0].id" -o tsv 2>/dev/null || true)

    if [ -z "$existing" ]; then
        for attempt in {1..5}; do
            if az role assignment create \
                --assignee-object-id "$assignee" \
                --assignee-principal-type Group \
                --role "$role" \
                --scope "$scope" --output none; then
                echo "Rolltilldelning $role för $assignee skapad."
                break
            else
                echo "Väntar 10 sekunder och försöker igen ($attempt/5)..." >&2
                sleep 10
            fi
        done
    else
        echo "Rolltilldelning $role för $assignee finns redan."
    fi
}

assign_role_if_missing "$DRIFT_GROUP_ID" "Contributor" "$RG_ID"
assign_role_if_missing "$DEV_GROUP_ID" "Reader" "$RG_ID"

# Managed Identity
if ! az identity show --resource-group "$RG" --name "$IDENTITY_APP" &>/dev/null; then
    az identity create --resource-group "$RG" --name "$IDENTITY_APP" --output none
else
    echo "Managed Identity $IDENTITY_APP finns redan."
fi

IDENTITY_ID=$(az identity show \
  --resource-group "$RG" --name "$IDENTITY_APP" \
  --query id -o tsv)

# Kontrollera om identiteten redan är tilldelad
CURRENT_IDENTITIES=$(az vm identity show --resource-group "$RG" --name "$VM_NAME" \
  --query "userAssignedIdentities[*].clientId" -o tsv 2>/dev/null || true)
IDENTITY_CLIENT_ID=$(az identity show --resource-group "$RG" --name "$IDENTITY_APP" --query clientId -o tsv)

if [[ "$CURRENT_IDENTITIES" != *"$IDENTITY_CLIENT_ID"* ]]; then
    az vm identity assign \
      --resource-group "$RG" \
      --name "$VM_NAME" \
      --identities "$IDENTITY_ID" --output none
else
    echo "Managed Identity redan tilldelad till VM."
fi

rm -f "$CLOUD_INIT"

echo "== STEG 4: Verifierar installation och trafik =="

# Självläkning och verifiering av nginx
SELF_HEAL_SCRIPT='
cloud-init status --wait > /tmp/civerify.log 2>&1 || true

if ! command -v nginx &> /dev/null; then
    echo "nginx saknas – installerar..."
    sudo apt-get update -y
    sudo apt-get install -y nginx
fi

if [ ! -f /var/www/html/index.html ]; then
    sudo mkdir -p /var/www/html
    sudo tee /var/www/html/index.html > /dev/null <<HTML_EOF
<!DOCTYPE html>
<html lang="sv">
<head>
  <meta charset="UTF-8">
  <title>Novatrix AB - Kundtjänst</title>
  <style>
    body { font-family: sans-serif; max-width: 500px; margin: 60px auto; }
    label { display: block; margin-top: 12px; }
    input, textarea { width: 100%; padding: 8px; box-sizing: border-box; }
    button { margin-top: 16px; padding: 10px 20px; }
  </style>
</head>
<body>
  <h1>Novatrix AB</h1>
  <p>Välkommen till vår kundtjänst. Fyll i formuläret nedan så återkommer vi så fort vi kan.</p>
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
HTML_EOF
fi

sudo systemctl enable nginx
sudo systemctl restart nginx

echo "----- cloud-init status -----"
cat /tmp/civerify.log 2>/dev/null || echo "Ingen logg"
echo "----- nginx service -----"
systemctl is-active nginx || true
systemctl status nginx --no-pager -l || true
echo "----- lokalt HTTP-svar -----"
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost || true
echo "----- senaste raderna i cloud-init-output.log -----"
tail -n 40 /var/log/cloud-init-output.log 2>/dev/null || true
'

az vm run-command invoke \
  --resource-group "$RG" --name "$VM_NAME" \
  --command-id RunShellScript \
  --scripts "$SELF_HEAL_SCRIPT" \
  --query "value[0].message" -o tsv

echo ""
echo "Klart! Miljön är redo."
if [ "$PUBLIC_IP" != "ingen" ]; then
    echo "Webb: http://$PUBLIC_IP"
else
    echo "Ingen publik IP hittades för VM."
fi
echo "Bastion SSH:"
echo "az network bastion ssh --name $BASTION_NAME -g $RG --target-resource-id \$(az vm show -g $RG -n $VM_NAME --query id -o tsv) --auth-type ssh-key --username $ADMIN_USER --ssh-key ~/.ssh/id_rsa"
