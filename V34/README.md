# V34 – Compute och kom igång

Pontus Pihlström

---

## Delmoment 1 – GitHub-repo

Ett publikt GitHub-repo skapades för kursen med en README innehållande namn, kursnamn och rubrik för veckan.

---

## Delmoment 2 – Provisionera virtuell server

En resursgrupp skapades i Azure Portal:

- **Namn:** `rg-novatrix-v34`
- **Region:** Sweden Central

Därefter provisionerades en virtuell maskin:

- **Namn:** `vm-novatrix-web`
- **Image:** Ubuntu Server 24.04 LTS
- **Autentisering:** SSH-nyckelpar (genererat av Azure vid skapande)

<img width="1008" height="942" alt="Skärmbild 2026-08-20 112411" src="https://github.com/user-attachments/assets/c0ea404f-9063-4393-afd8-702af08acf46" />


**Verifiering:** VM:en visades som `Running` i portalen efter deploy, med tilldelad publik IP-adress.



---

## Delmoment 3 – Konfigurera värdmiljön

Den nedladdade SSH-nyckeln sparades lokalt i `MOV25\Azure`. Åtkomsten till filen låstes ner så att endast den egna användaren kan läsa den:

```powershell
icacls .\vm-novatrix-web_key.pem /inheritance:r
icacls .\vm-novatrix-web_key.pem /grant:r "$($env:USERNAME):R"
```

Anslutning till servern via SSH:

```powershell
ssh -i .\vm-novatrix-web_key.pem azureuser@20.240.162.33
```

Vid första anslutningen bekräftades serverns fingeravtryck (`yes`), och en Ubuntu 24.04.4 LTS-session öppnades.

<img width="739" height="1000" alt="Skärmbild 2026-08-20 114050" src="https://github.com/user-attachments/assets/250f4115-b317-413d-9dd0-f917d489e534" />


Paketlistan uppdaterades och Nginx installerades:

```bash
sudo apt update
sudo apt install nginx -y
```

**Verifiering:** `sudo systemctl status nginx` visade tjänsten som `active (running)`.

<img width="1160" height="368" alt="Skärmbild 2026-08-20 114713" src="https://github.com/user-attachments/assets/9275b2c8-7b15-4ef2-af9e-1a7b17d90a72" />


---

## Delmoment 4 – Driftsätt kundtjänstsidan

<img width="1908" height="980" alt="Skärmbild 2026-08-20 115417" src="https://github.com/user-attachments/assets/43aa9aee-2067-4d7a-ab8f-b2c448ddcef2" />


Standardsidan i `/var/www/html/` ersattes med en sida som presenterar Novatrix och ett ärendeformulär med fälten namn, e-post och meddelande:

```html
<!DOCTYPE html>
<html lang="sv">
<head>
  <meta charset="UTF-8">
  <title>Novatrix AB – Kundtjänst</title>
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
```

**Verifiering:** Sidan kontrollerades i webbläsaren via serverns publika IP-adress (`http://20.240.162.33`) och visade Novatrix startsida med ärendeformuläret korrekt renderat.

<img width="1907" height="981" alt="Skärmbild 2026-08-20 121242" src="https://github.com/user-attachments/assets/8b53ef31-3881-42c2-b08f-416340ff6aa4" />


---

## Delmoment 5 – Kostnadshantering

Efter avslutat arbetspass stoppades den virtuella maskinen i Azure Portal för att undvika onödig förbrukning av startkrediten. Sedan efter uppgift klarskrivits raderades V34 resursgruppen för att spara resurser. Jag skapade också budget med varningar via e-post för att ha bättre kontroll i fall någon kostnad skulle sticka iväg. 
