# V35 – IAM och identitet
Pontus Pihlström

<sub>Veckans uppgift är att skapa och hantera identiteter i Azure genom att följa least privilege samt att förbereda en identitet till en applikation.</sub>
---

## Delmoment 2 – Identiteter i Entra ID

Två grupper skapades manuellt i Entra ID för att representera Novatrix roller, med en testanvändare i respektive grupp:

- **Azure-Drift** — medlem: Anna (Drift)
- **Azure-Utveckling** — medlem: Erik (Utveckling)

Grupperna och medlemskapen skapades under **Microsoft Entra ID → Grupper → Ny grupp**, med respektive användare tillagd som direktmedlem.

**Verifiering:** Under respektive grupps flik **Medlemmar → Direktmedlemmar** bekräftades att rätt person låg i rätt grupp 

<img width="1635" height="747" alt="Skärmbild 2026-09-01 181532" src="https://github.com/user-attachments/assets/e65dd6ff-b9b3-40dc-b654-2e3211661516" />
<img width="1637" height="754" alt="Skärmbild 2026-09-01 181512" src="https://github.com/user-attachments/assets/9b90f1c0-0a53-48a0-bd92-d93b4dc30314" />


---

## Delmoment 3 – RBAC-tilldelningar (least privilege)

| Grupp | Roll | Motivering |
|---|---|---|
| Azure-Drift | Deltagare (Contributor) | Drift behöver kunna hantera och konfigurera resurserna i miljön löpande starta, stoppa, ändra inställningar, men ges ingen ägarbehörighet och kan därmed inte ändra åtkomstkontroller (IAM) på prenumerationsnivå. |
| Azure-Utveckling | Läsare (Reader) | Utveckling behöver kunna se konfiguration och status för felsökning i sin kod, men ska inte kunna starta, stoppa eller ändra infrastruktur av misstag. |

Rolltilldelningarna gjordes manuellt via **rg-novatrix-v35 → Åtkomstkontroll (IAM) → Lägg till → Lägg till rolltilldelning**, en tilldelning per grupp, med omfattning satt till resursgruppen.

**Verifiering:** Under **IAM → Rolltilldelningar** i resursgruppen syns tilldelningarna: Azure-Drift som Deltagare och Azure-Utveckling som Läsare, båda begränsade till resursgruppens omfattning. 

<img width="1324" height="705" alt="Skärmbild 2026-09-01 183409" src="https://github.com/user-attachments/assets/5f5a3428-9db0-4369-b3bd-c3fb5320e67b" />

---

## Delmoment 4 – Hanterad identitet för appen

En hanterad identitet skapades för att appen i framtiden ska kunna autentisera mot Azure-tjänster utan att lösenord eller nycklar behöver hanteras i koden. Identiteten har i dagsläget inga tilldelade behörigheter.

Identiteten skapades manuellt via **Managed Identities → Create**.

**Verifiering:** Identitetens översiktssida i portalen bekräftade att den skapats, med ett unikt **Klient-ID** och **Objekt-ID (huvudkonto)** synliga.

<img width="1602" height="498" alt="Skärmbild 2026-09-01 183535" src="https://github.com/user-attachments/assets/7700639d-b4c5-4958-8998-64798c202115" />


---

## Delmoment 5 – Verifiering av behörigheter

Åtkomsten testades genom att logga in som respektive testanvändare och utföra
en åtgärd som matchar deras tilldelade roll:

- **Erik (Utveckling, Läsare)** försökte starta om VM:en `vm-novatrix-web`,
  vilket **nekades** av Azure med felmeddelandet att kontot saknar behörighet
  att utföra åtgärden `restart` inom resursgruppens omfång.
- **Anna (Drift, Deltagare)** kunde både starta och stoppa VM:en utan problem,
  eftersom Deltagare-rollen ger den behörigheten.

Resultatet bekräftar att rolltilldelningarna fungerar enligt least
privilege-principen: varje roll kan utföra precis det den behöver, och inget
mer.

<img width="1909" height="904" alt="Skärmbild 2026-09-01 200725" src="https://github.com/user-attachments/assets/cfa6d21c-17da-431a-9016-2b941cf0c889" />
<img width="1912" height="933" alt="Skärmbild 2026-09-01 183910" src="https://github.com/user-attachments/assets/c4fc3d57-8e18-4205-b7c1-9ad2075f80be" />
