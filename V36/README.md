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

---
