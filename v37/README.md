# V37 – Azure Uppgift 4

Pontus Pihlström  
---

## Delmoment 2 – Skapa lagring

Ett Storage Account skapades i Azure Portal under namnet `stnovatrix11` tillsammans med blob-containern `arenden`. Kontot konfigurerades med Standard Hot tier och lokalt redundant lagring (LRS) för lägsta kostnad i testmiljön.

- **Storage Account:** `stnovatrix11`
- **Container:** `arenden`
- **Lagringsnivå:** Standard Hot med LRS

- **Kostnadsmotivering:** Standard med LRS valdes för att ge lägsta möjliga kostnad i testmiljön eftersom data inte behöver speglas i flera regioner. Hot tier valdes eftersom inkommande ärenden och bilder läses och skrivs direkt när de skickas in.

---

## Delmoment 3 – Koppla formuläret till lagringen

Formuläret i `index.html` postar inskickad data till sökvägen `/submit`. Nginx proxar förfrågan vidare till en Flask-backend som körs lokalt på servern på port 5000. 

Backenden tar emot namn, e-post, meddelande och bild, skapar ett tidsstämplat ärende ID och laddar upp filerna till containern `arenden`. I containern skapas en undermapp med ärendets ID där uppgifterna sparas i `arende.json` tillsammans med den bifogade bilden.

---

## Delmoment 4 – Säkra åtkomsten

Åtkomsten till lagringen har säkrats i flera lager helt utan att använda kontonycklar eller anslutningssträngar i koden:

- **Stängd publik åtkomst:** Anonym publik åtkomst har inaktiverats på storage account-nivå så att inga blobbar kan läsas öppet från internet.
- **Hanterad identitet:** En system-tilldelad hanterad identitet aktiverades på webbserverns VM.
- **RBAC med minst behörighet:** Identiteten tilldelades rollen `Storage Blob Data Contributor` begränsat till lagringskontot `stnovatrix11`.
- **Token-baserad autentisering:** Koden använder `DefaultAzureCredential` som automatiskt hämtar en säker token via serverns identitet.


**Sammanställning av åtkomst:**

| Resurs / Container | Åtkomstmetod | Behörighet | Vem når resurserna |
|---|---|---|---|
| `stnovatrix11` (Konto) | Anonym / Publik | Inaktiverad (`false`) | Ingen (blockeras på kontonivå) |
| `arenden` (Container) | RBAC via Identitet | Storage Blob Data Contributor | Endast webbserverns VM-identitet |
| `arenden` (Container) | Kontonycklar / SAS | Ej använt i kod | Inga nycklar finns sparade i koden |

---

## Delmoment 5 – Verifiera och dokumentera

Lösningen verifierades genom att skicka in ett ärende med bild via formuläret i webbläsaren. Sidan svarade med en bekräftelse som visade det genererade ärende ID:t. Därefter kontrollerades containern `arenden` i Azure Portal samt med Azure CLI för att bekräfta att mappen med JSON-filen och bildfilen sparats i lagringen.
