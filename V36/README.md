# V36 – Nätverk och säkerhet

Pontus Pihlström

<sub>Veckans uppgift är att bygga ett nätverkslager med VNET, subnät, NSG och defense in depth helt enkelt. <sub>

---

## Delmoment 2 – Bygg det virtuella nätverket

Ett virtuellt nätverk skapades med två subnät. Ett publikt subnät för webbservern och ärendeformuläret, samt ett privat subnät förberett för lagringen som kopplas in i v37.

- **VNet:** `vnet-novatrix`
- **Publikt subnät:** `snet-web`, 10.0.1.0/24
- **Privat subnät:** `snet-db`, 10.0.2.0/24

**Verifiering:** Under vnet-novatrix → Undernät syns båda subnäten med korrekt adressintervall och 251 tillgängliga adresser vardera.

---

## Delmoment 3 – Säkra trafiken (NSG)

En Network Security Group, `nsg-web`, skapades och kopplades till det publika subnätet för att endast släppa igenom nödvändig trafik.

| Regel | Riktning | Port | Källa | Åtgärd | Motivering |
|---|---|---|---|---|---|
| allow-web | Inbound | 80 | Internet | Allow | Ärendeformuläret måste vara publikt nåbart |
| allow-ssh-admin | Inbound | 22 | Endast administratörens IP | Allow | Endast betrodd administratör ska kunna ansluta för drift, inte hela internet |
| DenyAllInBound | Inbound | * | Any | Deny | Standardregel som stänger allt annat som inte matchar en tillåtande regel ovan |

**Verifiering:** Deployment-loggen bekräftar att nsg-web skapades korrekt i resursgruppen. NSG:n testades sedan konkret i Delmoment 5.

---

## Delmoment 4 – Placera lösningen i nätverket

Den ursprungliga virtuella maskinen från tidigare veckor låg i ett annat nätverk och behövde flyttas in i det nya säkrade nätverket. Det gick inte att flytta det till ett annat VNet i efterhand, så den gamla VM:en togs bort medan dess OS-disk sparades. På så sätt bevarades den redan konfigurerade Nginx-installationen och ärendeformuläret utan att behöva sättas upp på nytt från grunden. En ny VM skapades sedan utifrån den sparade disken och placerades direkt i det publika subnätet snet-web.

Webbservern vm-novatrix-web ligger nu med nätverkskortet nic-vm-novatrix-web kopplat till vnet-novatrix/snet-web. Det privata subnätet snet-db lämnades tomt och utan publik åtkomstväg, förberett för lagringen i v37.

**Verifiering:** Nätverkskortets översiktssida bekräftar att VM:en är ansluten till rätt VNet och subnät, med endast en privat IP-adress (10.0.1.4) och ingen publik IP direkt på kortet. Sidan fortsatte visa Nginx-konfigurationen och formuläret efter återskapandet, vilket bekräftar att disken och konfigurationen återanvändes korrekt.

---

## Delmoment 5 – Verifiera och dokumentera

Trafikflödena testades med Azure Network Watchers verktyg IP flow verify, som avgör om en given trafiktyp tillåts eller nekas mot en resurs och visar vilken regel som styr utfallet.

**Test 1, HTTP mot webbservern på port 80.**
Resultat: Access allowed, via regeln allow-web i NSG:n nsg-web. Bekräftar att kundtjänstformuläret är nåbart som avsett.

**Test 2, SSH från en icke-godkänd IP-adress på port 22.**
Resultat: Access denied, via standardregeln DenyAllInBound. Bekräftar att servern inte går att administrera från obehöriga källor.

**Test 3, SSH från administratörens godkända IP-adress på port 22.**
Resultat: Access allowed, via regeln allow-ssh-admin. Bekräftar att administratören fortfarande har den åtkomst som behövs för drift.

Tillsammans visar de tre testerna att trafiken hanteras enligt principen om minsta möjliga öppning. Nödvändig trafik släpps igenom, medan allt annat nekas som standard.

**Nätverksdesign, enkel skiss:**
```
Internet
   |
   | HTTP (80) tillåtet för alla
   | SSH (22) tillåtet endast från admin-IP
   v
[ NSG: nsg-web ]
   |
[ Publikt subnät: snet-web (10.0.1.0/24) ]
   |
[ vm-novatrix-web, Nginx + ärendeformulär ]

[ Privat subnät: snet-db (10.0.2.0/24) ]
   Förberett för lagring i v37, ingen publik åtkomstväg
```
# Novatrix – VG (v36)
## Introduktion

I denna uppgift har jag implementerat en djupförsvarsmodell för Novatrix nätverksinfrastruktur i Azure. Hela nätverket, subnäten, säkerhetsgrupperna och den administrativa åtkomsten är definierade som kod i skriptet `deploy-novatrix-v36-final.sh` för att miljön enkelt ska kunna återskapas direkt från repot. Lösningen följer principen om **defense in depth** genom att kombinera flera säkerhetslager: nätverkssegmentering, nätverkssäkerhetsgrupper (NSG:er), begränsad administrativ åtkomst via Azure Bastion, och förberedelse för framtida skydd av dataskiktet.

---

## Nätverksdesign och segmentering

För att undvika ett platt nätverk där alla resurser når varandra har jag delat upp det virtuella nätverket **vnet-novatrix** (10.0.0.0/16) i tre isolerade subnät:

| Subnät               | Adressrymd      | Syfte                                      |
|----------------------|-----------------|--------------------------------------------|
| `snet-web`           | 10.0.1.0/24     | Dedikerat subnät för webbservern och offentliga tjänster. |
| `snet-db`            | 10.0.2.0/24     | Isolerat subnät reserverat för databasskiktet.          |
| `AzureBastionSubnet` | 10.0.3.0/26     | Avskilt subnät för säker administration via Azure Bastion. |

Trafiken mellan och inom subnäten styrs via två **Network Security Groups (NSG:er)**:

- **`nsg-web`** – associerad med `snet-web`. Regler:
  - Tillåter inkommande webbtrafik på port 80 (HTTP) och port 443 (HTTPS) från `Internet`.
  - Inkommande SSH på port 22 är begränsat så att det **enbart** tillåts om trafiken kommer internt från `AzureBastionSubnet` (10.0.3.0/26).

- **`nsg-db`** – associerad med `snet-db`. Har **inga inkommande regler** definierade, vilket innebär att all direkt inkommande trafik från internet eller andra subnät nekas enligt Azures standardregel (default deny). Detta skapar strikt isolering för det framtida databasskiktet.

### Viktigt om NSG-placering

NSG:erna är kopplade på **subnätnivå**, vilket innebär att reglerna tillämpas på all trafik till och från respektive subnät, oavsett vilka resurser som finns där. För att undvika att en extra NSG skapas automatiskt på VM:ens nätverksgränssnitt (NIC) används parametern `--nsg ""` vid skapandet av VM:en. Detta säkerställer att endast subnätets NSG styr trafiken och att inga motstridiga regler uppstår.

---

## Begränsad administrativ åtkomst (Bastion-design)

Inga administrativa portar är öppna mot det publika internet. Istället för en traditionell hoppvärd med en publik IP-adress har jag konfigurerat **Azure Bastion** (`bastion-novatrix`). Det gör att jag kan ansluta säkert via SSH till `vm-novatrix-web` direkt genom Azure Portal eller Azure CLI utan att exponera SSH-porten.

Trafiken krypteras över TLS via port 443 till Bastion-tjänsten, som i sin tur vidarebefordrar SSH-sessionen internt över `snet-web`. Eftersom Azure Bastion är en fullständigt hanterad tjänst ansvarar Microsoft för patchning och säkerhet av själva bastion-värden, vilket minskar risken för sårbarheter i OS eller SSH-demonen.

---

## Hotbild och skyddsmekanismer

Designen skyddar i första hand mot följande tre hotkategorier:

### 1. Slumpmässiga portskanningar och brute force-attacker mot SSH

**Hot:** Angripare skannar internet efter IP-adresser med öppen port 22 för att göra automatiserade inloggningsförsök med lösenord eller nycklar.

**Skydd:** SSH-porten på `vm-novatrix-web` är helt stängd mot internet i `nsg-web`. Nätverkssäkerhetsgruppen tillåter enbart SSH-anslutningar som härrör från IP-spannet `10.0.3.0/26` (AzureBastionSubnet).

### 2. Horisontell förflyttning vid ett eventuellt intrång i webbskiktet

**Hot:** Om en angripare lyckas ta sig in på webbservern via en sårbarhet i webbapplikationen försöker denne ofta röra sig vidare i nätverket för att nå databaser eller interna resurser.

**Skydd:** Segmenteringen med `snet-db` och regleverket i `nsg-db` förhindrar oauktoriserad direktåtkomst till databasskiktet. Webbservern ligger i en avgränsad zon och kan inte nå administrativa gränssnitt eller andra känsliga delar av nätverket utan explicit tillåtna regler.

### 3. Exponering av administrativa gränssnitt

**Hot:** Traditionella hoppvärdar eller publika SSH-servrar kan drabbas av sårbarheter i OS eller SSH-demonen om de står oskyddade mot internet.

**Skydd:** Genom att använda Azure Bastion som managed service sköts patchning och skydd av plattformen av Azure. SSH-protokollet exponeras aldrig externt utan nås enbart via autentiserade och krypterade sessioner.

---

## Nätverksskiss

                    Internet
                       |
          HTTP/HTTPS (80/443)
                       |
                       v
               [NSG: nsg-web]   (tillåter 80/443 från Internet,
                       |        SSH enbart från Bastion-subnet)
                       v
                snet-web (10.0.1.0/24)
                       |
                       | (ingen direkt trafik)
                       v
                snet-db (10.0.2.0/24)
                       |
                       v
               [NSG: nsg-db]   (default deny all trafik)

------------------------------------------------------------------

                    Användare
                       |
                       |  TLS (443)
                       v  Azure Bastion
                       |
                       |  SSH (22) internt
                       v  AzureBastionSubnet (10.0.3.0/26)
                       |
                       v  snet-web (VM)

---

## Återskapa nätverket från repot

Nätverksinfrastrukturen körs upp idempotent via Azure CLI. Skriptet skapar alla resurser, konfigurerar NSG:er, VM, Bastion samt identitets- och rollhantering. Det är utformat för att kunna köras flera gånger utan att orsaka fel.

### Krav

- Azure-prenumeration med tillräckliga behörigheter (t.ex. Owner/Contributor).
- Azure CLI installerat och inloggat (`az login`).

### Kör skriptet

```bash
chmod +x deploy-novatrix-v36-final.sh
./deploy-novatrix-v36-final.sh
