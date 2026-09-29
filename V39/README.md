# Azure - Uppgift 6 (V39)
I denna uppgift har jag knutit ihop Azure-infrastrukturen med Microsoft 365 för att skapa ett helt automatiserat och säkert ärendehanteringssystem för Novatrix kundtjänst. Lösningen uppfyller kraven för både G och VG eftersom flödet integrerar flera olika M365-tjänster i en sammanhängande kedja.

## Infrastruktur och uppsättning
Hela Azure-miljön rullas ut automatiskt via Infrastructure as Code. Uppsättningen bygger på tre huvudkomponenter:

* **Bicep (`main.bicep`):** Definierar alla resurser i Azure, inklusive nätverk, virtuell maskin, lagringskonto och Managed Identity. För veckans uppgift justerades VM-storleken för att hantera regionala resursbegränsningar. Dessutom i samband med byte av azure konto och prenumeration så sattes rättighetstilldelningen till enskild användare (principalType: 'User') för smidigare testning. I produktion rekommenderas egentligen gruppbaserad RBAC (principalType: 'Group') som jag också hade tidigare vecka i scriptet.
* **Parameterfil (`main-compact.parameters.json`):** Innehåller de specifika namnen och inställningarna som Bicep-skriptet använder vid uppbyggnaden
* **Cloud-init (`cloud-init.yaml`):** Sätter upp servern vid uppstart. Den installerar Nginx och sätter upp Python/Flask-applikationen (`app.py`). Koden har denna vecka utökats med logik för att koda om uppladdade filer till Base64, hantera tomma bilagor, och skicka en HTTP POST-payload till Power Automate.

*All kod för infrastrukturen och webbapplikationen finns tillgänglig i repot som main.bicep, parameters.json och cloud-init.yaml.*

## Arkitektur och säkerhet
Istället för att låta Power Automate hämta filer via en öppen länk från Azure, har jag valt en betydligt säkrare arkitektur. Azure Blob Storage har en stängd brandvägg (Deny by default). När ett formulär skickas in läser Python-appen (Flask) filen, gör om den till en textsträng (Base64) och skickar den direkt i en HTTP-payload till Power Automate. 

På detta sätt är lagringskontot skyddat från internet, samtidigt som filerna hanteras sömlöst, och de sparas säkert i mappar sorterade på unika ärende-ID:n i Azure-containern.

## Konfiguration

För att trigga flödet från Azure-miljön användes JSON-schemat nedan i Power Automates HTTP-trigger. Hade jag gjort om det så hade jag kanske satt en något simplare namngivning.

```json
{
  "type": "object",
  "properties": {
    "id": { "type": "string" },
    "name": { "type": "string" },
    "mail": { "type": "string" },
    "message": { "type": "string" },
    "created": { "type": "string" },
    "has_attachment": { "type": "boolean" },
    "attachment_name": { "type": "string" },
    "attachment_content_base64": { "type": "string" }
  }
} 
```

Utdrag ur Python-koden (app.py) som bygger payloaden och skickar anropet till Power Automate:
```python
if POWER_AUTOMATE_URL:
    pa_payload = {
        "id": ticket_id,
        "name": name,
        "mail": mail,
        "message": msg,
        "created": stamp,
        "has_attachment": has_attachment,
        "attachment_name": attachment_name,
        "attachment_content_base64": attachment_base64
    }
    try:
        requests.post(POWER_AUTOMATE_URL, json=pa_payload, timeout=10)
    except Exception as e:
        print(f"Fel vid anrop till Power Automate: {e}")
```
Hela flödets exporterade JSON-definition finns sparad i repot som definition.json.

## Flödets steg (Händelsekedjan)
Flödet triggas automatiskt via en HTTP-begäran från webbservern och utför sedan följande händelsekedja:

1. **SharePoint (Ärenderegister):** Flödet börjar med att hämta värdena från formuläret och skapar en ny rad i listan "Novatrix Tickets" i SharePoint. Här loggas kundens namn, e-post, meddelande, datum och en status för ärendet.
2. **Villkorsstyrd logik (Bilagor):** Flödet kontrollerar om anropet innehåller en bifogad fil. 
   * **Om Sant (fil finns):** Flödet återskapar filen från Base64 till binärkod, bifogar den till ärendet i SharePoint, och skickar sedan ett mail till supporten där filen ligger som bilaga.
   * **Om Falskt (ingen fil):** Flödet skickar ett mail till supporten om det nya ärendet, men utan att försöka hantera någon bilaga.
3. **Bekräftelse till kund:** Oavsett om en fil skickades med eller inte, avslutas flödet med att kunden får ett bekräftelsemail (Outlook) med sitt referensnummer, medan kundtjänst får en notis om det nya ärendet.

## Verifiering

Ett testärende skickades in via formuläret, med en bifogad
bild. Följande kontrollerades och bekräftades fungera:

- Flödets körningshistorik i Power Automate visade en lyckad körning (grönt),
  samtliga steg utfördes utan fel.
- En ny rad skapades i SharePoint-listan "Novatrix Tickets" med rätt namn,
  e-post, meddelande och status.
- Bilagan syntes korrekt bifogad på SharePoint-posten.
- Ett bekräftelsemail mottogs på testkundens adress med referensnumret.
- Kundtjänst mottog ett separat mail om det nya ärendet, med bilagan bifogad.

Sedan så kördes även ett testärende utan bilaga för att bekträfta att ärendet kom fram utan bilaga vilket det gjorde efter att ha fixat koden att skicka en tom sträng istället för null.

Bilagor med verifiering finns uppladdade i repot för denna veckan. 

## Motivering av design (VG)
Designen med Base64 och HTTP-trigger valdes primärt för att följa "least privilege"-principen i Azure. Genom att integrera flera tjänster (SharePoint för register och Outlook för dubbla mailutskick) skapas en komplett lösning som liknar ett riktigt ärendehanteringssystem. 

### Framtida utökning
Kedjan kan enkelt byggas ut ytterligare. Till exempel skulle man kunna lägga till en åtgärd som skickar ett adaptivt meddelande i en Teams-kanal som man skapar upp för kundtjänsten. Man skulle också kunna lägga på schemalagt flöde som bevakar SLA på ärenden och skickar mail eller teams meddelande för att uppmärksamma kundtjänsten. Automatisera utskick av enkät när ärendet markeras som löst skulle också kunna vara ett förslag.