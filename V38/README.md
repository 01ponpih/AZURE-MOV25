# Azure - Uppgift 5 (v38)

Detta repository innehåller infrastrukturen för Novatrix ärendehanteringssystem, skriven helt som kod (IaC) via Azure Bicep (som automatiskt kompileras till ARM-templates vid driftsättning). Lösningen provisionerar VM, nätverk, säkerhet, identiteter och lagring i ett enda automatiserat flöde utan behov av manuella portalsteg.

## Infrastruktur och Säkerhetsarkitektur
Miljön är deklarativ och helt parametriserad för hög återanvändbarhet och bygger på "Least Privilege"-principen:

* **Compute:** Ubuntu VM (`Standard_D2als_v6`) konfigurerad automatiserat via `cloud-init` (Nginx, Flask och applikationskod). B serien gick inte att få åtkomst till dessvärre efter uppgrade till pay as you go, därför blev det D2als_v6.
* **Nätverk (VNet & NSG):** Eget virtuellt nätverk med dedikerade subnät. Nätverkssäkerhetsgruppen (NSG) tillåter publik HTTP-trafik men begränsar SSH-åtkomst till en specifik administratörs-IP.
* **Storage Account:** Konfigurerat med Standard Hot (LRS). Lagringen är nätverksisolerad (`defaultAction: Deny`) och tillåter enbart trafik från webbserverns subnät (via Service Endpoints) och administratörens IP.
* **Identitet & RBAC (Auth utan nycklar):**
* **Maskin:** VM:en använder en *System-Assigned Managed Identity* som automatiskt tilldelas rollen *Storage Blob Data Contributor* för blob-containern.
* **Människa:** Säkerhetsgruppen `azure-drift` tilldelas samma roll på lagringskontonivå för säker administration.
* *Härdning:* Shared Key Access och publik blob-åtkomst är inaktiverat. All åtkomst sker via Microsoft Entra ID-tokens (`DefaultAzureCredential`).
 
## Återskapa miljön från kod 
Miljön kan återskapas exakt likadant i valfri resursgrupp genom att köra nedanstående kommando i Azure CLI.

1. Klona repot och navigera till rätt mapp.
2. Skapa resursgruppen om den inte redan finns:
   
       az group create --name <din-resursgrupp> --location swedencentral
   
3. Säkerställ att du uppdaterat `parameters.json` med din egen publika IP, SSH-nyckel, önskade namn och `adminGroupId` (Object ID för säkerhetsgruppen `azure-drift`, hämtas med `az ad group show --group "Azure-Drift" --query id -o tsv`).

4. Validera templaten innan deploy:

       az deployment group validate \
         --resource-group <din-resursgrupp> \
         --template-file main.bicep \
         --parameters @parameters.json
   
   
5. Förhandsgranska vad deployen faktiskt skulle göra:

       az deployment group what-if \
         --resource-group <din-resursgrupp> \
         --template-file main.bicep \
         --parameters @parameters.json

6. Kör deployen:

       az deployment group create \
         --resource-group <din-resursgrupp> \
         --template-file main.bicep \
         --parameters @parameters.json

## Verifiering

Efter en lyckad deploy verifieras resultatet i Azure Portal:

* **Formuläret nåbart:** `webUrl` (från deployens Outputs-flik) öppnades i webbläsaren, kundtjänstformuläret laddades korrekt.
* **Ärendet sparas:** ett testärende skickades in via formuläret. I portalen, under storage-kontot → **Containers** → `arenden`, syns den nya blobben med det inskickade ärendet.
* **Outputs:** under **Resursgrupp → Deployments → (senaste deployen) → Outputs** visas samma värden (webbadress, storage-kontonamn, VM-namn) som annars hade behövt letas fram manuellt i portalen.

## Versionshantering

Templaten är versionshanterad i detta GitHub-repo. Historiken över samtliga ändringar visas under repots **Commits**-flik på GitHub.

Versionshanteringen gör att varje ändring i infrastrukturen är spårbar, vem gjorde vad och när, vilket underlättar både drift (att kunna se vad som ändrats innan ett fel uppstod och vid behov återgå till en tidigare, fungerande version) och samarbete (flera personer kan arbeta mot samma template utan att skriva över varandras ändringar, och ändringar kan granskas innan de slås samman).

Under projektets gång har flera ändringar committats till exempel byte av VM-storlek till `Standard_D2als_v6`.

Allt arbete med Git har utförts via terminalen (Git Bash) i Visual Studio Code:

```bash
# 1. Markera ändrade filer
git add main.bicep

# 2. Skapa en commit med beskrivande meddelande
git commit -m "Byter VM-storlek till Standard_D2als_v6"

# 3. Skicka ändringarna till GitHub
git push origin main

# 4. Visa historiken över commits
git log --oneline
```
