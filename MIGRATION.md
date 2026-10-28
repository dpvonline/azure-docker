# Migrationsplan: AKS + Lightsail → eine Azure-VM

Arbeitsdokument für den Umzug aller verbliebenen Dienste auf `vm-dpv-core`.
Architektur und Betrieb der Ziel-VM stehen im [README](README.md); hier steht nur,
wie wir dorthin kommen.

## Ausgangslage

| Dienst | läuft heute auf | Datenbank | Domain |
|---|---|---|---|
| Keycloak | AKS (`azure-infrastructure`) | Postgres im Cluster | `auth.dpvonline.de` |
| Confluence | AKS | Postgres im Cluster | `wiki.dpvonline.de` |
| Nextcloud + Collabora | **AWS Lightsail** (Docker Compose), Nutzerdaten auf AWS EFS | MariaDB 10.6 | `cloud.` / `office.dpvonline.de` |
| Redis | AKS (nur Cache) | – | – |
| Biber-Backend | **wird nicht mehr gebraucht** | – | – |

Auf der neuen VM laufen bereits Caddy, Keycloak und Postgres unter der Testdomain
`auth.scout-tools.de`. Die Nextcloud-Konfiguration liegt in
[dpvonline/nextcloud-config](https://github.com/dpvonline/nextcloud-config) und ist
bereits ein Compose-Stack — der Umzug ist im Kern ein `rsync` plus Anpassen der
Compose-Dateien, keine Neuinstallation.

## Zielbild

Eine VM (`Standard_D4ps_v6`, ARM64, bis zum Umzug unten `Standard_B4s_v2`), ein
Postgres, ein Reverse Proxy (Caddy), drei Platten:

| Platte | Typ | Größe | Mount | Inhalt |
|---|---|---|---|---|
| 1 | Premium SSD v2 | 32 GiB | `/data/postgres` | Postgres |
| 2 | Premium SSD v2 | 64 GiB | `/data/apps` | Confluence-Home, Nextcloud-App, Redis |
| 3 | Standard SSD | 256 GiB | `/data/nextcloud` | Nextcloud-Nutzerdaten (~158 GB, siehe Phase 3) |

## Grundsätze

Vier Entscheidungen, die sich durch alle Phasen ziehen — hier einmal begründet,
damit sie später nicht neu diskutiert werden müssen.

**Aufbau app-für-app, Cutover gebündelt.** Jede App wird einzeln auf der neuen VM
aufgebaut und mit einer *Kopie* der Produktivdaten geprüft, während DNS unverändert
auf das alte System zeigt. Erst wenn eine App nachweislich läuft, kommt sie in ein
Cutover-Fenster. So wird die Restore-Prozedur mehrfach geprobt, bevor sie zählt.

**Zwei Cutover statt einem.** Keycloak und Confluence teilen sich Postgres *und* die
Anmeldung, gehören also in ein Fenster. Nextcloud auf Lightsail teilt beides nicht und
bekommt ein eigenes. Voraussetzung dafür: in Cutover A behält Keycloak **denselben
Hostnamen, dieselbe Realm und dieselben Client-Secrets** — dann merkt das noch auf
Lightsail laufende Nextcloud vom Umzug nichts außer einer geänderten IP. Ein
vollständiger Dump/Restore erhält alle drei per Konstruktion.

**Testen unter eigenen Testnamen, als geschlossenes Paar.** Die Kopien laufen unter
`auth.scout-tools.de` und `wiki.scout-tools.de` (Variablen `DOMAIN_AUTH`,
`DOMAIN_WIKI`) mit echten Let's-Encrypt-Zertifikaten. Weil die Realm- und
Confluence-Daten absolute URLs auf `*.dpvonline.de` enthalten, werden in den *Kopien*
Base URL, Identity Provider und SAML-Client auf die Testnamen umgestellt, sodass sich
`wiki.scout-tools.de` gegen `auth.scout-tools.de` anmeldet (Details in Phase 1). Die
Produktion bleibt dabei unberührt. Beim Cutover bringen frische Dumps die
`dpvonline.de`-Werte zurück; zurückzustellen ist nichts, nur die beiden Secrets.

**Das alte System bleibt stehen, bis das neue sich bewährt hat.** AKS wird erst
abgerissen, wenn Cutover A eine Woche unauffällig gelaufen ist; Lightsail entsprechend
nach Cutover B. Bis dahin ist der Rollback in beiden Fällen: DNS zurückzeigen lassen.

---

## Phase 0 — Fundament

**Ziel:** Die VM auf den Zielzustand bringen, solange noch nichts Produktives darauf
läuft. Keine Nutzer betroffen.

Die Reihenfolge ist kein Zufall: `init-db.sql` wird von Postgres **ausschließlich bei
der Erstinitialisierung eines leeren Datenverzeichnisses** gelesen (siehe
[fetch-secrets.sh](scripts/fetch-secrets.sh)). Das Postgres-18-Upgrade ist damit die
einzige Gelegenheit, alle Datenbanken und Rollen kostenlos anzulegen — danach braucht
jede weitere App manuelles DDL per `psql`.

### Schritte

1. **Bugfix `update-containers.sh`** — `docker compose pull --ignore-buildable`.
   Ohne das schlägt *jeder* Update-Lauf fehl, weil `dpv-postgres:17-pgbackrest` nur
   lokal gebaut wird und in keiner Registry existiert; das löst ein unnötiges Rollback
   aus. (Bereits im Arbeitsverzeichnis umgesetzt, noch nicht gemergt.)

2. **Postgres 18, frisches Cluster.** Dockerfile auf `postgres:18`, und die Datenplatte
   gleich mit ersetzen lassen:
   `terraform apply -replace=azurerm_managed_disk.postgres_data`. Dann formatiert
   cloud-init eine leere Platte und Postgres initialisiert neu — kein `pg_upgrade`, kein
   Dump/Restore, nichts von Hand zu löschen. Die Keycloak-Daten auf der VM sind
   Wegwerfdaten aus `keycloak.dump`, die echten kommen erst beim Cutover.
   **Kein `terraform destroy`**: die Purge Protection des Key Vaults würde den Namen
   sieben Tage blockieren (siehe README).

3. **`init-db.sql.template` um alle Datenbanken erweitern** — `keycloak`, `confluence`,
   `nextcloud`, jeweils mit eigener Rolle. Passwörter als neue Key-Vault-Secrets
   (`postgres-confluence-password`, `postgres-nextcloud-password`) plus Ergänzung in
   `fetch-secrets.sh`. Die Apps kommen später, die Datenbanken müssen aber jetzt
   entstehen.

4. **Mounts von `/mnt/...` nach `/data/...`.** Auf VM-Größen mit Temp-Disk hängt Azures
   waagent die *ephemere* Platte nach `/mnt` — persistente Daten dort abzulegen ist ein
   bekannter Fallstrick. `Standard_B4s_v2` hat gar keine Temp-Disk mehr, und
   `/data/...` passt zu dem, was `nextcloud-config` schon verwendet.

5. **`VM_SIZE` → `Standard_B4s_v2`** (4 vCPU, 16 GiB, 6.400 IOPS, 145 MB/s, ~140 $/Mon).
   Gegenüber `B4ms` (2.880 IOPS, 35 MB/s, gleicher Preis) mehr als doppelte
   Disk-Leistung; gegenüber `D4as_v5` (~152 $) identische Disk-Limits, aber burstable
   CPU statt dedizierter.
   Das AMD-Pendant `B4as_v2` ist auf **jedem** von Azure ausgewiesenen Attribut
   identisch und ~14 $/Mon günstiger, scheitert hier aber an der Quota: „Standard Basv2
   Family vCPUs" steht auf 3, gebraucht werden 4 (Bsv2 dagegen auf 65). Falls die Quota
   je erhöht wird, ist der Wechsel eine Zeile in `tfvars` plus Neustart — `VM_SIZE`
   steckt nicht in `custom_data`, es braucht also keinen VM-Neuaufbau.
   *Abgelöst durch `Standard_D4ps_v6`, siehe „Umzug auf ARM64" nach Phase 2. Mehr
   Basv2-Quota gibt Microsoft in der Region nicht her.*

6. **Platten 2 und 3 anlegen** plus Mount-Logik in `cloud-init.yaml.tftpl`. Erst mit
   6.400 IOPS lohnt die Aufteilung: 3.000 + 3.000 + 500 Baseline gegen 6.400 VM-Limit.

7. **Biber/ACR entfernen** — `terraform/acr.tf`, der `acr_login_server`-Output, die
   `ACR_NAME`-Variable, die tfvars-Zeile, die README-Erwähnung. Die ACR-Verdrahtung
   existiert laut eigenem Kommentar ausschließlich für das Biber-Backend.

8. **Azure Backup** — Recovery Services Vault, Policy, VM eingebunden, **alle** Platten
   inklusive Postgres. Sichert alle Platten in einem gemeinsamen, untereinander
   konsistenten Wiederherstellungspunkt und kann einzelne Dateien zurückholen.
   pgBackRest bleibt daneben für Postgres-PITR. Kosten ~15–20 €/Monat.

9. **Alerts** — Füllstand > 80 % pro Platte, CPU-Credits gegen Null (B-Serie drosselt
   bei erschöpften Credits auf die Baseline).

10. **Dokumentation** — Wiederherstellungsablauf beider Backup-Ebenen ins README,
    inklusive der Ausrichtung: Platten-Snapshot von Zeitpunkt T wiederherstellen, dann
    Postgres per PITR auf genau T.

### Verifikation

- VM bootet, Keycloak unter `auth.scout-tools.de` erreichbar
- `psql -c '\l'` zeigt alle drei Datenbanken und Rollen
- Platten unter `/data/postgres`, `/data/apps`, `/data/nextcloud` gemountet
- `sudo systemctl start dpv-update.service` läuft ohne Rollback durch
- pgBackRest-Backup erfolgreich, erster Azure-Backup-Wiederherstellungspunkt vorhanden

### Rollback

Terraform-State und Platten bleiben; im Zweifel VM neu ausrollen. Kein Produktivbetrieb
betroffen.

> Das `terraform apply` fährt Philip selbst, weil `custom_data` sich ändert und die VM
> dabei neu gebaut wird.

---

## Phase 1 — Confluence aufbauen

**Ziel:** Confluence läuft auf der neuen VM mit einer Kopie der Produktivdaten unter
`wiki.scout-tools.de` und meldet sich gegen den Keycloak auf der VM
(`auth.scout-tools.de`) an. DNS für `wiki.dpvonline.de` unverändert, keine Nutzer
betroffen.

Confluence zuerst, weil es die aufwendigste App ist und weil danach der Weg für
Cutover A frei ist — und damit für den Abriss von AKS, dem teuersten Posten.

### Schritte (so umgesetzt, Vorlage für Cutover A)

1. **Version:** `atlassian/confluence:10.2.18`. Auf AKS läuft `:latest`, das ist
   derzeit bit-genau dieses Image (gleicher Digest). Kein Versionssprung beim Umzug.
2. **Datenbank:** `pg_dump -Fc` der `confluence`-DB aus dem AKS-Postgres, auf der VM in
   eine mit `en_US.utf8` neu angelegte Datenbank eingespielt (wie in Produktion).
   Dabei die Daten von `scheduler_run_details` weggelassen: 5,8 der 6 GB sind reines
   Job-Protokoll. Aus `pg_restore --list` die Zeile `TABLE DATA public
   scheduler_run_details` entfernen und mit `-L` einspielen. Ergebnis: 152 MB, Restore
   in 5 Sekunden, Inhaltszahlen identisch mit AKS.
3. **Home-Verzeichnis** per `tar` aus dem Pod, **ohne** `logs`, `log`,
   `analytics-logs`, `restore` (alte Importe), `temp`, `plugins-temp`,
   `plugins-osgi-cache`, `webresource-temp`, `bundled-plugins`, `lost+found`, Lock- und
   PID-Dateien — das erzeugt Confluence beim Start neu. Rund 1,3 GB. Die Übertragung
   über `kubectl exec` kann mittendrin abreißen: danach Dateizahl und Größe pro Eintrag
   mit dem Pod vergleichen und Fehlendes nachholen. Besitzer `2002:2002`.
4. **`confluence.cfg.xml`** zieht mit um und bleibt die Quelle der Konfiguration
   (`ATL_FORCE_CFG_UPDATE=false`). Confluence schreibt selbst Zustand hinein
   (`finalizedBuildNumber`, JWT-Schlüssel, Synchrony-Token), den die Vorlage des Images
   beim Neuerzeugen verwerfen würde. Anzupassen sind nur `hibernate.connection.url`
   (`jdbc:postgresql://postgres:5432/confluence`) und `hibernate.connection.password`
   (aus dem Key Vault, `postgres-confluence-password`).
5. **Nur für die Testkopie:** Base URL auf `https://wiki.scout-tools.de`. Seit Confluence 10
   liegen die globalen Einstellungen in **`plugin_setting`** (`_GLOBAL`,
   `atlassian.confluence.settings`, JSON-Feld `baseUrl`), dazu dort
   `synchrony_collaborative_editor_app_base_url` für den Editor. Der gleichnamige Eintrag
   in `bandana` ist ein wirkungsloser Rest aus älteren Versionen — dort geändert, meldet
   sich Confluence weiter mit dem alten Namen bei Keycloak. Confluence dafür stoppen.
   Identity Provider (`AO_ED669C_IDP_CONFIG`: `ISSUER`,
   `SSO_URL`) auf `auth.scout-tools.de`. In der Keycloak-Kopie den SAML-Client
   `https://wiki.dpvonline.de` umbenannt, samt Base-URL, Redirect-URI und
   `saml_assertion_consumer_url_post`. Keycloak dafür stoppen, es cacht Clients. Das
   Signaturzertifikat bleibt gültig, weil die Keycloak-Kopie dieselben Realm-Schlüssel
   trägt. **Beim Cutover A nichts zurückstellen:** die frischen Dumps bringen die
   `dpvonline.de`-Werte mit.
6. **Ausgehende Mails** sind in der Testkopie per `-Datlassian.mail.senddisabled=true`
   abgeschaltet, sonst verschickt sie mit echten Daten Mails an echte Nutzer.

**Laufender Betrieb:** Der Timer `dpv-confluence-prune` löscht täglich um 04:30 UTC
Scheduler-Protokoll älter als 7 Tage. Confluence hält es sonst fest 90 Tage (im Code,
nicht einstellbar) und die Tabelle wächst auf etwa 6 GB.

### Verifikation

Login über Keycloak-SSO, Seiten und Anhänge sichtbar, Volltextsuche nach
Index-Neuaufbau, Berechtigungen stichprobenartig gegen das alte System vergleichen.

### Rollback

Container stoppen. Das alte System läuft unverändert weiter.

---

## Phase 2 — Cutover A: Keycloak + Confluence live

**Ziel:** `auth.` und `wiki.dpvonline.de` laufen auf der VM, AKS ist abgeschaltet.
**Wartungsfenster, Nutzer betroffen.** Zwei Stunden ankündigen; der Ablauf selbst
dauert nach den Messungen aus Phase 1 etwa 45–60 Minuten.

### Stand 24.09.2026: durchgeführt

- **Keycloak** auf AKS gestoppt um 09:28 UTC, **Confluence** um 09:32 UTC. Der Stack auf
  der VM lief ab 09:37 UTC unter den echten Namen, das Wiki war ab etwa 09:40 UTC
  erreichbar. Freigegeben (Nur-Lese-Modus aus) nach den Prüfungen.
- Alle Prüfungen aus Schritt 10 grün, über IPv4 und IPv6: OIDC-Issuer und SAML-entityID
  `https://auth.dpvonline.de/realms/DPV`, Base URL `https://wiki.dpvonline.de`,
  Let's-Encrypt-Zertifikate bis 23.12., keine Fehler in Confluence und Keycloak.
  Inhaltszahlen der Datenbank identisch mit AKS, Home-Verzeichnis 17 von 17 Einträgen
  identisch. Full-Backup direkt danach (203 MB).
- **Beobachtet:** Bei `auth.dpvonline.de` hielt der DNS-Cache des Admin-Macs noch den
  alten Eintrag mit 6 Stunden TTL, weil Keycloak dort am selben Morgen aufgerufen worden
  war. Server und Resolver hatten den neuen Stand längst; nach ein paar Minuten bzw.
  `dscacheutil -flushcache` lief es. Für Cutover B: TTL mindestens einen Tag vorher
  senken, dann stellt sich die Frage nicht.
- AKS stand danach mit 0 Replikas für Keycloak und Confluence, bis zum Abriss am 28.10.
  (siehe „Zwischenschritt — AKS abreißen" nach Phase 4).

### Wer merkt was

| Zeitraum | Confluence | Anmeldung (Keycloak) | Nextcloud auf Lightsail |
|---|---|---|---|
| ab Schritt 1 | nur lesen | – | – |
| ab Schritt 2 bis Schritt 9 | nicht erreichbar für neue Logins | **weg** | bestehende Sessions laufen, **neue Logins scheitern** |
| ab Schritt 11 | normal | normal | normal |

### Vorbereitung

**Mindestens 7 Stunden vorher, besser am Vortag — IONOS:**
- TTL von `auth.dpvonline.de` (A **und** AAAA) von 21.600 auf **300** Sekunden
  setzen. Sonst zeigen manche Clients nach der Umstellung bis zu sechs Stunden auf
  AKS, und ein Rollback dauert genauso lange. Die neue TTL greift erst, wenn die alte
  abgelaufen ist. `wiki.dpvonline.de` steht bereits auf 60.
- Die aktuellen Werte für den Rollback notieren:
  A `72.144.24.168`, AAAA `2603:1020:c01:2::259` (für beide Namen gleich).

**Am Tag davor:**
- Cutover-PR vorbereiten, **aber nicht mergen**: entfernt die Zeile
  `JVM_SUPPORT_RECOMMENDED_ARGS` (Mail-Sperre) aus `docker-compose.confluence.yml`.
  Gemergt vorher, würde die Testkopie beim nächsten Neustart Mails an echte Nutzer
  verschicken.
- Wartungsfenster ankündigen, inklusive der Nextcloud-Logins.
- Zugangsdaten eines Confluence-Admins bereithalten (Nur-Lese-Modus ein/aus).

### Vorab-Checks im Fenster (5 Min.)

- IPv6 auf der VM funktioniert (PR „IPv6 für die VM", vorab getestet unter
  `scout-tools.de`).
- Eigene IP ist in `ADMIN_IP_CIDRS`, SSH auf die VM geht. Sonst erst `tfvars` +
  `terraform apply` (nur NSG).
- `kubectl` erreicht AKS (Zugangsdaten in eine eigene kubeconfig,
  `az aks get-credentials -g Infra -n Kubernetes-Cluster --file <datei>`).
- `dig +noall +answer auth.dpvonline.de @8.8.8.8` zeigt TTL ≤ 300.
- Auf der VM: `pgbackrest … check` mit Exit 0.
- **Im alten Repo `azure-infrastructure` während und nach dem Cutover kein
  `terraform apply`.** Die Deployments sind dort mit `replicas: 1` hinterlegt; ein
  `apply` würde Keycloak und Confluence auf AKS wieder hochfahren, und es gäbe zwei
  schreibende Instanzen.

### Schritte

| # | Schritt | Dauer | Rollback |
|---|---|---|---|
| 1 | Confluence auf AKS: *Administration → Allgemeine Konfiguration → Wartung → Nur-Lese-Modus* einschalten | 2 Min. | Modus ausschalten |
| 2 | Keycloak auf AKS stoppen: `kubectl -n keycloak scale deploy/keycloak --replicas=0` | 1 Min. | `--replicas=1` |
| 3 | Keycloak-Dump ziehen und auf der VM einspielen | 3 Min. | ab hier alles über Rollback A |
| 4 | Confluence-DB-Dump ziehen und einspielen | 3 Min. | |
| 5 | Confluence-Home kopieren und prüfen, dann Confluence auf AKS stoppen | 5–10 Min. | |
| 6 | `confluence.cfg.xml` anpassen | 2 Min. | |
| 7 | Cutover-PR mergen, Secrets umstellen, `terraform apply` | 3 Min. | |
| 8 | DNS bei IONOS umstellen | 5–10 Min. | **Rollback B** |
| 9 | Stack auf der VM neu starten | 5 Min. | |
| 10 | Prüfen | 15 Min. | |
| 11 | Nur-Lese-Modus auf der VM ausschalten — **ab hier kein verlustfreies Zurück** | 1 Min. | nur mit Datenverlust |

**3 — Keycloak.** Auf der VM Keycloak stoppen, die Datenbank neu anlegen, einspielen:

```
kubectl -n database exec <postgres-pod> -- pg_dump -U postgres -Fc keycloak > keycloak.dump
# auf der VM:
docker compose stop keycloak
psql -c "DROP DATABASE keycloak WITH (FORCE)" -c "CREATE DATABASE keycloak OWNER keycloak"
pg_restore --no-owner --no-privileges --role=keycloak -d keycloak < keycloak.dump
```

Kontrolle: Tabellenzahl, Realms `DPV` und `master`, und dass
`migration_model` die Version aus `docker-compose.keycloak.yml` zeigt (ein Downgrade
verweigert Keycloak). Die Test-Anpassungen aus Phase 1 (SAML-Client auf
`wiki.scout-tools.de`) werden dabei überschrieben — gewollt.

**4 — Confluence-Datenbank.** Auf der VM Confluence stoppen, die Datenbank mit
`en_US.utf8` neu anlegen, ohne das Scheduler-Protokoll einspielen (Details siehe
Phase 1, Schritt 2). Kontrolle: `select count(*) from content` und `from bodycontent`
müssen mit AKS übereinstimmen.

**5 — Home-Verzeichnis.** `/data/apps/confluence` auf der VM **leeren** — dort liegen
jetzt Test-Stände — und frisch aus dem Pod kopieren, mit denselben Ausschlüssen wie in
Phase 1. Danach Dateizahl und Größe pro Eintrag mit dem Pod vergleichen und Fehlendes
nachholen: `kubectl exec` hat in Phase 1 nach 72 Sekunden mitten im Archiv abgebrochen.
Erst wenn alle Einträge übereinstimmen:
`kubectl -n wiki scale deploy/confluence --replicas=0`.

**6 — `confluence.cfg.xml`.** Wie in Phase 1, Schritt 4: `hibernate.connection.url`
auf `jdbc:postgresql://postgres:5432/confluence`, `hibernate.connection.password`
aus dem Key Vault. Zusätzlich prüfen: `access.mode` steht auf `READ_ONLY`, weil die
Datei den Nur-Lese-Modus aus Schritt 1 mitgebracht hat. Base URL, Identity Provider
und Synchrony-Adresse **nicht** anfassen — die frischen Dumps enthalten bereits die
`dpvonline.de`-Werte.

**7 — Konfiguration.** Den vorbereiteten Cutover-PR mergen, lokal
`git checkout main && git pull`. In `terraform.tfvars`
`DOMAIN_AUTH = "auth.dpvonline.de"` und `DOMAIN_WIKI = "wiki.dpvonline.de"`, dann
`terraform apply` — der Plan darf nur die beiden Secrets in-place ändern.

**8 — DNS bei IONOS.** Für `auth` und `wiki`: A-Eintrag auf `4.182.232.115`,
AAAA-Eintrag auf die IPv6 der VM (`terraform output vm_public_ipv6`). **Beide**
umstellen: ein AAAA-Eintrag, der auf AKS stehen bleibt, schickt Browser, die IPv6
bevorzugen — also die meisten —, weiter dorthin. Warten, bis
`dig +short auth.dpvonline.de @8.8.8.8` und `… AAAA …` den neuen Stand zeigen.

**9 — Neustart.** Auf der VM `git pull` und `systemctl restart dpv-compose.service`.
Das schreibt die neuen Namen in die `.env`, Keycloak läuft danach als
`auth.dpvonline.de`, und Caddy holt sich die Zertifikate. Caddy braucht dafür, dass DNS
bereits auf die VM zeigt, deshalb Schritt 8 vorher. Confluence braucht mit frischem
Home-Verzeichnis ein paar Minuten, bis `/status` `RUNNING` meldet.

**10 — Prüfen.**
- `https://auth.dpvonline.de/realms/DPV/protocol/saml/descriptor`: `entityID` ist
  `https://auth.dpvonline.de/realms/DPV`, Zertifikat von Let's Encrypt.
- Beides zusätzlich per IPv6: `curl -6 …`.
- `https://wiki.dpvonline.de/status` meldet `RUNNING`, und
  `/rest/applinks/1.0/manifest` zeigt `<url>https://wiki.dpvonline.de</url>`.
- Login ins Wiki von einem Gerät ohne bestehende Session, Seiten, Anhänge, Suche.
- Anmeldung bei Nextcloud (Lightsail) mit einem Account, der gerade nicht eingeloggt ist.
- Confluence-Log auf `ERROR` prüfen.

**11 — Freigeben.** Auf der VM den Nur-Lese-Modus in Confluence ausschalten, eine
Testseite bearbeiten, über *Administration → Mailserver* eine Testmail schicken.
Wartungsende ankündigen.

### Rollback

**A — vor der DNS-Umstellung (Schritte 1–7).** Nichts ist verloren, AKS hat den
vollständigen Stand:
`kubectl -n keycloak scale deploy/keycloak --replicas=1`,
`kubectl -n wiki scale deploy/confluence --replicas=1`, auf AKS den Nur-Lese-Modus
ausschalten. Den Stand auf der VM einfach liegen lassen.

**B — nach der DNS-Umstellung, vor Schritt 11.** Bei IONOS A **und** AAAA auf die
notierten alten Werte zurück, dann wie A. Wegen des Nur-Lese-Modus hat auf der VM
niemand geschrieben, es geht also nichts verloren. Dauert bis zur TTL, also etwa
fünf Minuten.

**Nach Schritt 11** hat die VM Änderungen, die AKS nicht hat. Ein Rollback verliert
sie, oder sie müssten zurückmigriert werden. Deshalb Schritt 10 gründlich.

### Danach

- Direkt nach dem Fenster auf der VM ein Full-Backup: `pgbackrest-full-backup.sh`.
- AKS eine Woche auf 0 stehen lassen, PVCs **nicht** löschen. Dann **AKS abreißen** —
  das ist die große Einsparung. Außer `auth` und `wiki` bedient AKS nur noch Biber und
  pgAdmin (`anmeldung.`, `db.scout-tools.de`), beide werden nicht mehr gebraucht.
  Ablauf: „Zwischenschritt — AKS abreißen" nach Phase 4.
- Die Testnamen `auth.` und `wiki.scout-tools.de` bedient die VM nach Schritt 9 nicht
  mehr; die DNS-Einträge dafür fallen mit dem AKS-Abriss weg.
- `office.dpvonline.de` zeigt auf AKS, antwortet aber schon heute nicht (Stand
  23.09.). Auf AKS lief dafür nie etwas, nur eine Ingress-Regel; Collabora wird in
  Phase 3 auf der VM neu aufgesetzt.

> **Client-Secrets in diesem Fenster nicht rotieren.** Das noch auf Lightsail laufende
> Nextcloud authentifiziert gegen diese Keycloak-Instanz. Rotation erst in Phase 5.

---

## Zwischenschritt — Umzug auf ARM64 (`Standard_D4ps_v6`)

**Ziel:** Die VM läuft auf `Standard_D4ps_v6` statt `Standard_B4s_v2`. Das spart
~15 €/Monat, und die Kerne gehören der VM allein, statt über Burst-Credits zu drosseln.
**Wartungsfenster, Nutzer betroffen:** Keycloak und Wiki sind 30–45 Minuten weg.
1,5 Stunden ankündigen. Vor Phase 3, solange noch wenig Daten auf der VM liegen.

**Warum ein Neuaufbau:** Zwischen x86 und ARM64 gibt es kein Resize. Das Ubuntu-Image
ist je Architektur ein anderes, und ein anderes Image baut die VM neu. Die drei
Datenplatten sind eigene Ressourcen und bleiben, wie sie sind. Auch der
Azure-Backup-Eintrag bleibt stehen: `source_vm_id` ist in `terraform/backup.tf` als
fester Pfad geschrieben, sodass Terraform ihn nicht mit ersetzt und dabei die
Sicherungen löscht. Neu entstehen die OS-Platte, die Host-Keys, die Managed Identity
samt ihren zwei Rollenzuweisungen, der Monitoring-Agent und die
Let's-Encrypt-Zertifikate (Caddys Volume liegt auf der OS-Platte).

**Warum Postgres einfach weiterläuft:** Das Datenverzeichnis wird nicht migriert,
Postgres 18 auf ARM64 startet direkt darauf. x86-64 und ARM64 haben dasselbe
Byte-Layout (Little Endian, 64 Bit, gleiche Ausrichtung); Postgres prüft das beim Start
gegen `pg_control` und verweigert den Start, wenn es nicht passt, bricht also laut
statt leise. Der einzige bekannte Unterschied, das Vorzeichen von `char`, ist seit
Postgres 18 in `pg_control` festgehalten und wird berücksichtigt. glibc und damit
die Sortierung sind in `postgres:18` auf beiden Architekturen dieselben. Geprüft wird
es trotzdem, mit `amcheck` über alle Indizes; Dumps liegen als Rückfall bereit.

Getestet am 24.09.: In Zone 1 ist Hardware für `D4ps_v6` frei, auch mit Premium SSD v2
als Datenplatte. Eine Garantie für den Tag des Umzugs ist das nicht (siehe Rollback A).

### Stand 24.09.2026: durchgeführt

- Stack gestoppt um 13:28 UTC, `terraform apply` 13:30–13:49, Keycloak und Wiki wieder
  da ab 14:08. Ausfall 40 Minuten. Alle Prüfungen grün: gleiche Systemkennung,
  `amcheck` über 1.485 Indizes fehlerfrei, Zahlen identisch, pgBackRest `check` und
  Full-Backup, IPv4 und IPv6, Login.
- **Vorfall:** Azure brauchte 17 Minuten, um die Datenplatten an die neue VM zu
  hängen; cloud-init wartete damals nur 60 Sekunden je Platte. Eingehängt wurde nur
  `/data/apps`. Postgres legte daraufhin auf der OS-Platte ein leeres Cluster an,
  Keycloak und Wiki liefen von 13:38 bis 14:04 dagegen (Logins scheiterten).
  Geschrieben wurde in die echten Daten nichts, und pgBackRest wies das fremde
  Cluster wegen der anderen system-id ab. Behoben per Hand: Stack gestoppt, leeres
  Cluster nach `/root/pgdata-leeres-cluster-os-platte` verschoben, LUN 0 und 2
  eingehängt. Seitdem wartet cloud-init bis zu 30 Minuten, `boot.sh` startet den
  Stack nur mit allen drei Mounts, und Docker selbst startet erst, wenn sie da sind
  (`scripts/systemd/docker.service.d/`).
- Livepatch gibt es auf ARM64 nicht (`pro status`: `n/a`), ESM läuft. Livepatch für ARM64
  kam erst mit Ubuntu 26.04, siehe „Ubuntu 26.04 für Livepatch".

### Wer merkt was

| Zeitraum | Wiki | Anmeldung (Keycloak) | Nextcloud auf Lightsail |
|---|---|---|---|
| Schritt 2 bis 7 | weg | **weg** | bestehende Sessions laufen, **neue Logins scheitern** |
| ab Schritt 8 | normal | normal | normal |

### Vorbereitung

- PR „VM auf Standard_D4ps_v6 (ARM64)" mergen. Solange in `terraform.tfvars`
  `VM_SIZE = "Standard_B4s_v2"` steht, ändert ein `terraform apply` danach nur die
  Beschreibung des CPU-Credit-Alerts. Der Umzug beginnt erst mit Schritt 3.
- Fenster ankündigen, inklusive der Nextcloud-Logins. **Nicht** zwischen 01:00 und
  04:30 UTC (Azure Backup, pgBackRest, Sonntags-Update, Confluence-Prune).
- Eigene IP in `ADMIN_IP_CIDRS`, SSH auf die VM geht.

### Schritte

| # | Schritt | Dauer | Rollback |
|---|---|---|---|
| 1 | Sicherung: Zahlen notieren, Dumps, Full-Backup | 5 Min. | – |
| 2 | Stack sauber stoppen, `pg_control` notieren — **Ausfall beginnt** | 2 Min. | `docker compose up -d` |
| 3 | `VM_SIZE` umstellen, `terraform apply` | 5–10 Min. | **A** |
| 4 | Host-Key prüfen, cloud-init abwarten, **alle drei Mounts prüfen** | 10–30 Min. | A |
| 5 | Postgres prüfen | 5 Min. | **B** |
| 6 | pgBackRest prüfen, Full-Backup | 5 Min. | |
| 7 | Keycloak und Wiki prüfen | 10 Min. | A |
| 8 | Freigeben, Azure Backup und Monitoring prüfen | 15 Min. | wie A, auch danach |

**1 — Sicherung.** Auf der VM:

```
cd /opt/dpv/compose
sudo /opt/dpv/scripts/pgbackrest-full-backup.sh
sudo install -d -m 700 /data/apps/pre-arm64
for db in keycloak confluence; do
  sudo docker compose exec -T --user postgres postgres pg_dump -Fc $db \
    | sudo tee /data/apps/pre-arm64/$db.dump >/dev/null
done
sudo ls -la /data/apps/pre-arm64
sudo docker compose exec --user postgres postgres psql -d confluence -Atc \
  "select (select count(*) from content), (select count(*) from bodycontent)"
sudo docker compose exec --user postgres postgres psql -d keycloak -Atc \
  "select count(*) from user_entity"
```

Die drei Zahlen notieren. Die Dumps liegen auf der Apps-Platte, die den Neuaufbau
übersteht, und nur `root` kann sie lesen. Sie enthalten Passwort-Hashes, also nicht vom
Server herunterkopieren.

**2 — Stoppen.** Sauber herunterfahren, damit Postgres auf ARM64 ohne WAL-Replay startet:

```
sudo docker compose stop
sudo docker compose run --rm --no-deps --user postgres --entrypoint pg_controldata \
  postgres /var/lib/postgresql/data/pgdata | grep -iE "system identifier|cluster state|signedness"
```

`Database cluster state` muss `shut down` sein. Die Systemkennung notieren.

**3 — Neuaufbau.** Lokal in `terraform/terraform.tfvars`
`VM_SIZE = "Standard_D4ps_v6"`, dann `terraform plan`. Erwartet: **8 to add, 0 to
change, 9 to destroy**. Ersetzt werden die VM (`sku "server" -> "server-arm64"`),
die drei Plattenanbindungen, der Monitoring-Agent mit seiner DCR-Zuordnung und die zwei
Rollenzuweisungen. Gelöscht wird der CPU-Credit-Alert. **Nicht** im Plan dürfen stehen:
`azurerm_managed_disk.*`, `azurerm_backup_protected_vm.app`, irgendetwas aus Key Vault.
Passt das, `terraform apply`.

**4 — Host-Key und cloud-init.** Die VM hat neue Host-Keys. Fingerabdruck über Azure
holen, nicht blind annehmen:

```
az vm run-command invoke -g rg-dpv-core -n vm-dpv-core --command-id RunShellScript \
  --scripts "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub" --query "value[0].message" -o tsv
ssh-keygen -R 4.182.232.115
ssh -i ~/.ssh/dpv_core_vm_ed25519 dpvadmin@4.182.232.115   # Fingerabdruck vergleichen
```

Auf der VM:

```
cloud-init status --wait --long
sudo cat /var/log/dpv-boot-warnings.log
uname -m                                             # aarch64
for m in /data/postgres /data/apps /data/nextcloud; do findmnt -n "$m" || echo "$m FEHLT"; done
```

**Alle drei Platten müssen eingehängt sein, bevor es weitergeht.** cloud-init wartet
bis zu 30 Minuten auf sie, weil Terraform sie erst an die schon bootende VM hängt;
`cloud-init status --wait` kann also entsprechend lange dauern. Fehlt danach trotzdem
eine, startet `boot.sh` den Stack nicht (Eintrag in `dpv-boot-warnings.log`). Dann die
Platte mit `sudo mount /data/…` nachziehen, sobald `/dev/disk/azure/scsi1/lun<N>`
existiert (die Zeile in `/etc/fstab` schreibt cloud-init nur für eingehängte Platten:
`/dev/disk/azure/scsi1/lun<N> /data/… ext4 defaults,nofail 0 2`), und danach
`sudo systemctl restart dpv-compose.service`. **Nie `mkfs` von Hand:** die Platten
haben ihr Dateisystem schon, `blkid` zeigt es.

Scheitert cloud-init am Key Vault (`Forbidden` in `/var/log/cloud-init-output.log`),
war die neue Rollenzuweisung noch nicht wirksam: fünf Minuten warten, dann
`sudo cloud-init clean --logs --reboot`. Die Platten sind dabei sicher, `mkfs` läuft nur
auf Platten ohne Dateisystem.

**5 — Postgres.**

```
cd /opt/dpv/compose
sudo docker compose ps
sudo docker compose logs postgres | grep -iE "error|fatal|panic"
sudo docker compose exec --user postgres postgres pg_controldata /var/lib/postgresql/data/pgdata \
  | grep -iE "system identifier|signedness"
for db in keycloak confluence; do
  sudo docker compose exec -T --user postgres postgres psql -d $db -v ON_ERROR_STOP=1 -At \
    -c "create extension if not exists amcheck" \
    -c "select count(*) from (select bt_index_check(c.oid, true) from pg_index i
          join pg_class c on c.oid = i.indexrelid join pg_am am on am.oid = c.relam
          where am.amname = 'btree' and c.relpersistence <> 't' and i.indisvalid) s" \
    -c "drop extension amcheck" </dev/null && echo "$db ok"
done
sudo docker compose exec --user postgres postgres psql -Atc \
  "select datname, datcollversion = pg_database_collation_actual_version(oid) from pg_database where datallowconn"
```

Erwartet: dieselbe Systemkennung wie in Schritt 2, `keycloak ok` und `confluence ok`,
überall `t`. Dann die drei Zahlen aus Schritt 1 wiederholen, sie müssen gleich sein.

**6 — pgBackRest.** Die VM hat eine neue Identität und damit eine neue
Rollenzuweisung auf den Blob-Speicher; die braucht ein paar Minuten, bis sie wirkt.
Schlägt `check` fehl, kurz warten und wiederholen. Nicht einfach weiterlaufen lassen:
ohne Archivierung sammelt sich WAL auf der Postgres-Platte.

```
sudo docker compose exec --user postgres postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf stanza-create
sudo docker compose exec --user postgres postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf check
sudo /opt/dpv/scripts/pgbackrest-full-backup.sh
```

`stanza-create` meldet, dass die Stanza schon existiert und gültig ist. Das ist
richtig so: Systemkennung und Repository sind dieselben wie vorher.

**7 — Keycloak und Wiki.** Wie in Cutover A, Schritt 10: SAML-Descriptor und
`wiki.dpvonline.de/status` über IPv4 **und** IPv6 (`curl -4`/`curl -6`), Zertifikate
von Let's Encrypt (Caddy holt sie beim Start neu), Login ins Wiki, eine Seite mit
Anhang öffnen, Suche, Anmeldung bei Nextcloud, Confluence-Log auf `ERROR` prüfen.

**8 — Freigeben und Nacharbeiten.** Wartungsende ankündigen. Danach, ohne Zeitdruck:

- Azure Backup gegen die neue VM, mit dem bestehenden Eintrag:
  ```
  az backup protection backup-now -g rg-dpv-core -v rsv-dpv-core \
    --backup-management-type AzureIaasVM -c vm-dpv-core -i vm-dpv-core
  az backup job list -g rg-dpv-core -v rsv-dpv-core \
    --query "[0].{op:properties.operation,status:properties.status}" -o table
  ```
  Der Job muss durchlaufen, und die alten Wiederherstellungspunkte müssen weiter in
  der Liste stehen (`az backup recoverypoint list …`). Scheitert der Job mit einem
  Fehler zur VM: **nichts löschen**, Fehlermeldung sichern. Der nächste Versuch wäre
  `az backup protection disable … --delete-backup-data false`, dann
  `az backup protection resume … --policy-name policy-dpv-daily`. Die Daten bleiben dabei
  erhalten.
- Monitoring: nach ~15 Minuten kommen im Workspace `log-dpv-core` wieder Zeilen an:
  `Perf | where TimeGenerated > ago(30m) | summarize by Computer, InstanceName`.
- `pro status`: ESM ist aktiv; ob Livepatch auf ARM64 aktiv ist, notieren. Ist es das
  nicht, spielt `unattended-upgrades` Kernel-Updates trotzdem ein, sie greifen dann erst
  nach einem Neustart.
- `systemctl list-timers 'dpv-*'` zeigt beide Timer, `/etc/cron.d/pgbackrest-full`
  existiert.
- Nach einer unauffälligen Woche `/data/apps/pre-arm64` löschen.

### Rollback

**A — `apply` scheitert oder die VM kommt nicht sauber hoch.** Zum Beispiel keine
Hardware (`AllocationFailed`, `ZonalAllocationFailed`, `SkuNotAvailable`). In
`terraform.tfvars` wieder `VM_SIZE = "Standard_B4s_v2"`, `terraform apply`: Terraform
baut die VM wieder mit x86-Image, Schritte 4–7 wie oben. Die Daten sind unverändert,
Postgres wurde in Schritt 2 sauber gestoppt. Kontingent für `Bsv2` ist genug frei
(61 vCPUs).

**B — Postgres startet auf ARM64 nicht.** Dann hat es auch nichts geschrieben, also
zurück wie A. Startet es, aber `amcheck` meldet einen defekten Index: nur diesen Index
per `reindex index` neu bauen; bei mehreren `reindex database`. Beides geht bei den
paar hundert MB in Sekunden. Rückfall hinter beidem sind die Dumps aus Schritt 1:
Datenverzeichnis beiseite schieben, frisches Cluster, Dumps einspielen wie in Cutover A,
Schritt 3, dann die pgBackRest-Stanza zurücksetzen (README, Abschnitt
Postgres-18-Umstellung).

**Nach Schritt 8** schreiben Nutzer auf der ARM64-VM. Ein Zurück auf x86 geht trotzdem
jederzeit wie A, ohne Datenverlust: Das Datenverzeichnis ist in beide Richtungen
dasselbe.

---

## Phase 3 — Nextcloud aufbauen

**Ziel:** Nextcloud läuft auf der neuen VM auf Postgres, mit einer Kopie der
Lightsail-Daten, unter `cloud.scout-tools.de`, Collabora unter `office.scout-tools.de`.
DNS für `cloud.`/`office.dpvonline.de` unverändert, keine Nutzer betroffen.

Nach dem Muster von Phase 1: Die Kopie bekommt eigene Testnamen und einen eigenen
Keycloak-Client, schreibt keine Mails und hat keine Hintergrundjobs. Beim Cutover
bringt eine frische Kopie von `config.php` die Produktionswerte zurück; zurückzustellen
ist nichts.

### Stand 24.09.2026: Vorarbeiten auf Lightsail erledigt

Gemessen und gemacht, bevor irgendetwas kopiert wird — so wandern die teuren Daten
nur einmal (plus Delta) über die Leitung:

- **Ausgangslage:** Nextcloud 31.0.9 im unveränderten Image `nextcloud:31.0.9` (das
  eigene `app/Dockerfile` aus `nextcloud-config` war nicht in Gebrauch), MariaDB 10.6
  (458 MB), Redis ohne Passwort, Collabora `25.04.5.2`. Der Compose-Stack liegt in
  `~/workspace/nextcloud-config`, Branch `local-config` mit lokalen Änderungen. SSH:
  `ssh -p 1987 -i Lightsail-DPV-Cloud.pem ubuntu@cloud.dpvonline.de`. Die Instanz hat
  1 GB RAM (+7 GB Swap), Ubuntu 20.04.
- **Nutzerdaten liegen auf AWS EFS** (NFS, `/data/nextcloud/user_data`), die Backups des
  `backup`-Containers auf einem zweiten EFS (`/backup/nextcloud`, 113 GB). Ein
  Lightsail-Snapshot enthält **keines** der beiden, nur Systemplatte, App und MariaDB.
- **Hintergrundjobs liefen seit dem 20.08. nicht**: Modus `cron`, aber weder im
  Container noch auf dem Host ein Cron. Seitdem `/etc/cron.d/nextcloud-cron` auf dem
  Host, alle 5 Minuten, mit `flock`.
- `loglevel` 0 → 2, `overwrite.cli.url` auf `https://`, `nextcloud.log` (25 GB, wurde
  mangels Cron nie rotiert) geleert.
- **Update 31.0.9 → 31.0.14 → 32.0.15 → 33.0.9**, je 2–3 Minuten Wartungsmodus, alle
  Apps in stabilen Versionen mitgezogen. Grund: Postgres 18 unterstützt Nextcloud erst
  ab 33. Die Konvertierung läuft damit gegen eine offiziell unterstützte Kombination,
  und im Cutover steckt kein Upgrade. Vorher Snapshot und
  `/backup/nextcloud/pre-upgrade-31.0.9-2026-09-24-1436.sql.gz`. Die Meldung „The
  following apps have been disabled" des Image-Entrypoints beim ersten Sprung ist ein
  Anzeigefehler — alle Apps blieben aktiv.

**Was tatsächlich umzieht** (von 204 GB auf EFS):

| Inhalt | GB | kopieren |
|---|---:|---|
| Gruppenordner (20 Stück), Inhalt | ~114 | ja |
| Persönliche Dateien | 13,4 | ja |
| Versionen (Gruppenordner + persönlich) | 1,7 | ja |
| Papierkorb (Gruppenordner 23,8 + persönlich 3,9) | 27,7 | ja; läuft seit dem Cron nach 30 Tagen ab |
| Vorschaubilder (`appdata_*/preview`) | 20,5 | nein, entstehen neu |
| abgebrochene Uploads, Cache | 1,8 | nein |
| App-Verzeichnis (`/data/nextcloud/data`, Systemplatte) | 1,4 | ja, nach `/data/apps/nextcloud` |

Ergebnis ~158 GB auf der 256-GiB-Platte, AWS-Egress ~14 $ einmalig. `files_external`
ist aus; SSO läuft über die App `oidc_login` gegen den Keycloak-Client `nextcloud`
(ID = `preferred_username`). Keycloak lässt seit dem 24.09. per `pattern`-Validator
`^[a-zA-Z0-9 _.@'-]+$` nur noch Benutzernamen zu, die Nextcloud als ID akzeptiert —
Umlaute ließen `oidc_login` vorher still abstürzen.

### Aufbau auf der VM

Im Repo: [`docker-compose.nextcloud.yml`](compose/docker-compose.nextcloud.yml) mit
`nextcloud` (`nextcloud:33.0.9-apache`), `nextcloud-cron`, `redis` und `collabora`,
dazu zwei Blöcke im [Caddyfile](compose/Caddyfile). Zwei Sicherungen stecken in
[`fetch-secrets.sh`](scripts/fetch-secrets.sh):

- Die Datei kommt erst in `COMPOSE_FILE`, wenn `/data/apps/nextcloud/config/config.php`
  existiert. Auf einem leeren Verzeichnis zeigte das Image den öffentlichen
  Installationsassistenten.
- `nextcloud-cron` läuft nur, wenn `DOMAIN_CLOUD` `cloud.dpvonline.de` ist (Profil
  `nextcloud-live`). Die Kopie arbeitet mit echten Daten; ihre Kalender-Erinnerungen und
  Benachrichtigungen gingen sonst an echte Nutzer.

Collabora erreicht Nextcloud und umgekehrt über ihre öffentlichen Namen. Die sind als
Aliase von Caddy im Docker-Netz eingetragen, der Verkehr bleibt also auf der VM, und
das Zertifikat passt trotzdem.

### Stand 25.09.2026: Testkopie läuft auf Postgres

Unter `cloud.scout-tools.de`, SSO über den Client `nextcloud-test`, Gruppenordner und
Login von Philip geprüft. Was dabei herauskam und in die Skripte unter
[`scripts/nextcloud-migration/`](scripts/nextcloud-migration/) eingeflossen ist:

- **Kopieren:** 167 GB in 4 h 56 min, im Mittel 9,4 MB/s. Anfangs 30 MB/s, dann
  gedrosselt — die Grenze ist die Burst-Leistung von EFS, nicht die Leitung (das
  App-Verzeichnis von der Systemplatte kam mit 32 MB/s). Für den Cutover heißt das:
  am Vortag ein Delta-Lauf, im Fenster nur noch der Rest.
- **Agent-Forwarding taugt nicht** für einen Lauf über Stunden, er hängt an der offenen
  Sitzung auf dem Mac. Stattdessen ein eigener Schlüssel auf Lightsail
  (`/root/.ssh/dpv-migration_ed25519`), den die VM nur mit
  `from="3.65.3.213",no-pty,no-*-forwarding` annimmt; Host-Key der VM gegen Azure
  geprüft (`/root/.ssh/known_hosts.vm`). Nach Cutover B wieder entfernen.
- **Datenbank:** Dump und Import 17 s. 201 Tabellen, 263 Nutzer, 52.066
  Dateieinträge, 20 Gruppenordner auf beiden Seiten.
- **`db:convert-type` scheitert unter Nextcloud 33** am Ende, beim Nachziehen der
  Sequenzen: vier davon (`oc_jobs`, `oc_previews`, `oc_preview_locations`,
  `oc_preview_versions`) stammen aus der Zeit vor den Snowflake-IDs und gehören zu
  keiner Spalte mehr — das sieht der Code nicht vor, auch nicht in `master`. Alle
  Zeilen sind zu dem Zeitpunkt schon kopiert. `nc-convert.sh` erledigt die zwei
  fehlenden Schritte genauso wie Nextcloud selbst, ohne diese vier.
- **`dbport` bleibt sonst auf 3306** stehen — `db:convert-type` fasst es nicht an, und
  Nextcloud suchte Postgres auf dem MariaDB-Port.
- **Forms** ging ohne `app:remove` durch. Die Formulardaten bleiben erhalten.
- **Zeilenabgleich:** 190 von 191 Tabellen identisch. `oc_migrations` weicht ab, weil
  `db:convert-type` sie durch Ausführen der Migrationen füllt; die 25 fehlenden
  Einträge gehören zu Migrationen, die es im Code nicht mehr gibt. Nur in MariaDB
  stehen zehn Tabellen entfernter Apps (`announcements`, alte `app_api`,
  `oc_file_metadata`). `oc_federated_invites` entfernt danach
  `maintenance:repair` selbst (`DropFederatedInvitesTable`, leer).
- **Vorschaubilder:** nicht kopiert, aber in der Datenbank eingetragen — Nextcloud
  versuchte, die fehlenden Dateien zu lesen, statt neue zu erzeugen.
  `occ preview:cleanup` nach der Konvertierung behebt das.
- **Mit `config.php` auf der VM startet jeder Neustart Nextcloud mit.** Deshalb die
  Testkopie-Einstellungen (Schritt 4) sofort nach dem Kopieren setzen, notfalls per
  Einmal-Container, und vor dem Cutover nur `nc-sync.sh delta`, das `config.php`
  auslässt.
- **Eigene IP:** Die Admin-IP in `ADMIN_IP_CIDRS` ändert sich bei einer
  DSL-Neueinwahl; dann `terraform.tfvars` anpassen und `apply` (nur NSG).

### Vorbereitung (erledigt am 24.09.)

1. **Keycloak-Client `nextcloud-test`** in Realm `DPV`: Export von `nextcloud`,
   `clientId` geändert, `id`/`secret` entfernt, URLs auf `https://cloud.scout-tools.de…`,
   importiert, Secret neu erzeugt. Mapper kamen mit, der produktive Client blieb
   unberührt.
2. **Terraform:** `DOMAIN_CLOUD`/`DOMAIN_OFFICE` und `3.65.3.213/32` in
   `terraform.tfvars`, die vier DNS-Records einmalig importiert (sie gehörten bis zum
   24.09. dem alten Repo):
   ```
   # von Hand gebaut: `az network dns zone show` liefert "dnszones" und "infra"
   # kleingeschrieben, das lehnt der Provider ab
   Z="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/Infra/providers/Microsoft.Network/dnsZones/scout-tools.de"
   terraform import azurerm_dns_a_record.cloud     "$Z/A/cloud"
   terraform import azurerm_dns_aaaa_record.cloud  "$Z/AAAA/cloud"
   terraform import azurerm_dns_a_record.office    "$Z/A/office"
   terraform import azurerm_dns_aaaa_record.office "$Z/AAAA/office"
   ```
   Plan: 4 to add, 5 to change, 0 to destroy. Das `apply` meldete bei den DNS-Records
   Verbindungsabbrüche, die Änderungen waren trotzdem angekommen — ein zweiter `plan`
   zeigte „No changes". Danach auf der VM `git pull`, `restart dpv-compose.service`.
3. **Schlüssel für das Kopieren** (siehe oben): auf Lightsail
   `ssh-keygen -t ed25519 -f /root/.ssh/dpv-migration_ed25519`, öffentlichen Teil mit
   `from="3.65.3.213",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty`
   in `~dpvadmin/.ssh/authorized_keys` der VM,
   `ssh-keyscan -t ed25519 4.182.232.115 > /root/.ssh/known_hosts.vm` und den
   Fingerabdruck mit `az vm run-command invoke … ssh-keygen -lf …` vergleichen.

Die Skripte laufen auf Lightsail als `root` (hinkopieren per
`ssh … 'sudo install -m 700 /dev/stdin /root/<name>' < <name>`), auf der VM direkt aus
`/opt/dpv/scripts/nextcloud-migration/`. Lange Läufe in `tmux`.

### Schritte

**1 — Verzeichnisse** auf der VM:

```
sudo install -d -o 33 -g 33 -m 750 /data/apps/nextcloud
sudo chown 33:33 /data/nextcloud && sudo chmod 770 /data/nextcloud
```

**2 — Dateien**, auf Lightsail: `nc-sync.sh initial 2>&1 | tee -a /root/nc-sync.log`
(Stunden, siehe oben). Ohne Vorschaubilder, Log, abgebrochene Uploads und Cache;
ausgeschlossene Pfade wie `lost+found` löscht `--delete` auf der VM nicht.

**3 — Datenbank.** Auf der VM eine MariaDB 10.6 nur für die Konvertierung, unter
dem Namen `db`, den `config.php` erwartet:

```
DBPW="$(sudo docker run --rm -v /data/apps/nextcloud:/var/www/html nextcloud:33.0.9-apache \
  php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["dbpassword"];')"
sudo docker run -d --name nextcloud-mariadb --restart unless-stopped --network dpv --network-alias db \
  -v /data/apps/nextcloud-mariadb:/var/lib/mysql \
  -e MARIADB_RANDOM_ROOT_PASSWORD=1 -e MARIADB_DATABASE=nextcloud \
  -e MARIADB_USER=nextcloud -e MARIADB_PASSWORD="$DBPW" \
  mariadb:10.6 --transaction-isolation=READ-COMMITTED --binlog-format=ROW
```

Dann auf Lightsail `nc-db.sh`. Am Ende stehen die vier Kontrollzahlen beider Seiten.

**4 — Zur Testkopie machen, dann starten.** Gleich nach Schritt 2, noch bevor
irgendetwas Nextcloud startet — mit einem Einmal-Container, der keinen Webserver
hochfährt:

```
O="sudo docker run --rm -u www-data --network dpv -v /data/apps/nextcloud:/var/www/html \
  -v /data/nextcloud:/var/www/html/data nextcloud:33.0.9-apache php occ"
$O config:system:set mail_smtpmode --value=null          # keine Mails an echte Nutzer
$O config:app:set dav sendEventReminders --value=no      # doppelt hält besser
$O config:system:set trusted_domains 0 --value=cloud.scout-tools.de
$O config:system:set overwritehost --value=cloud.scout-tools.de
$O config:system:set overwrite.cli.url --value=https://cloud.scout-tools.de
$O config:system:set oidc_login_client_id --value=nextcloud-test
$O config:system:set oidc_login_client_secret --value='<Secret des Clients>'
$O config:system:set oidc_login_logout_url --value=https://cloud.scout-tools.de/apps/oidc_login/oidc
$O config:system:set maintenance_window_start --value=1 --type=integer
```

Dann `sudo systemctl restart dpv-compose.service` — `fetch-secrets.sh` findet die
`config.php` und nimmt Nextcloud dazu. Kurz prüfen, dass die Kopie **vor** der
Konvertierung läuft: SSO-Login, ein Gruppenordner, eine Datei. Sonst weiß man
hinterher nicht, woran es liegt.

**5 — Konvertieren**, auf der VM in `tmux`:
`sudo /opt/dpv/scripts/nextcloud-migration/nc-convert.sh 2>&1 | tee -a /root/nc-convert.log`.
Rund 2 Minuten für die Daten. Das Skript bricht ab, wenn `db:convert-type` an etwas
anderem scheitert als dem bekannten Sequenz-Fehler oder wenn Zeilenzahlen abweichen
(außer `oc_migrations`). Danach stoppt es MariaDB — läuft Nextcloud weiter, hängt es
nicht mehr daran. Zurück ginge es mit der gesicherten `/root/config.php.before-pgsql.*`
und `docker start nextcloud-mariadb`.

**6 — Collabora.**

```
O="sudo docker compose exec -T --user www-data nextcloud php occ"   # in /opt/dpv/compose
$O config:app:set richdocuments wopi_url --value=https://office.scout-tools.de
$O config:app:set richdocuments public_wopi_url --value=https://office.scout-tools.de
$O richdocuments:activate-config
```

Auf Lightsail stand `wopi_url` ohne `https://` und zeigte auf einen Namen, der zu AKS
führte — Collabora hat dort nie funktioniert. Nextcloud erreicht Collabora über den
Caddy-Alias (Antwort von der internen Adresse von Caddy, nicht der öffentlichen). Die
Gegenrichtung lässt sich nur mit einem echten Dokument prüfen: im Collabora-Image gibt
es weder `sh` noch `getent`.

**7 — Sichern:** `sudo /opt/dpv/scripts/pgbackrest-full-backup.sh`.
`nextcloud-mariadb` und `/data/apps/nextcloud-mariadb` bleiben bis nach dem Cutover
liegen — der Cutover braucht sie wieder.

**Probe `user_oidc`** (optional, in der Kopie kostenlos). Die offizielle App kann
Backchannel-Logout, Bearer-Tokens und den Login-Flow der Clients sauber. Damit die
bestehenden Konten bleiben, ohne Hash als ID und mit `soft_auto_provision` (Standard):
`user_oidc:provider` mit `--unique-uid=0`, `--mapping-uid=preferred_username`,
Gruppen aus `roles`, Kontingent aus `nextcloudquota`, dann `oidc_login` deaktivieren.
Zu prüfen: dieselben Konten mit denselben Dateien und Freigaben, **dieselben Gruppen**
(nicht doppelt angelegt — daran hängen die Gruppenordner) und der Login der Desktop-
und Mobil-Clients. Bekanntes Fehlerbild heute: Nach dem Keycloak-Login landet der
Client auf der Nextcloud-Passwortmaske. Beim Test die URL dieser Seite notieren.

### Verifikation

- SSO-Login von einem Gerät ohne Session, Logout.
- Gruppenordner (20), persönliche Dateien, Upload einer großen Datei (> 1 GB),
  Freigabelinks, Papierkorb und Versionen.
- Vorschaubilder entstehen beim Öffnen eines Bildordners neu.
- Kalender und Kontakte, auch per CalDAV/CardDAV über `/.well-known/…`.
- Collabora: Dokument öffnen, gleichzeitig zu zweit bearbeiten, speichern.
- Desktop-Client-Sync gegen einen Testaccount, Mobil-App.
- `$O setupchecks` ohne neue Fehler, Nextcloud-Log ohne `level ≥ 3`.
- Kopie per IPv4 und IPv6 (`curl -4`/`-6 https://cloud.scout-tools.de/status.php`).

### Rollback

`nextcloud` und `collabora` stoppen. Lightsail läuft unverändert weiter; die Kopie
hat dort nichts verändert.

---

## Phase 4 — Cutover B: Nextcloud live

**Ziel:** `cloud.` und `office.dpvonline.de` laufen auf der VM. **Wartungsfenster,
Nutzer betroffen.** Der Ablauf ist der aus Phase 3 mit denselben Skripten. Dauer: der
letzte Delta-Lauf (am Vortag messen) plus ~15 Minuten für Dump, Konvertierung und
Prüfen.

### Stand 23.10.2026: durchgeführt

- Vorher auf beiden Seiten auf Nextcloud **33.0.10** (PHP-Sicherheitsupdate). Der
  Renovate-PR dafür (#35) sprang versehentlich auf 35 und wurde mit #37 auf 33.0.10
  korrigiert, bevor die VM ihn zog. Seitdem öffnet Renovate je Major einen eigenen PR
  (`separateMultipleMajor`).
- `nc-sync.sh delta` vorab, im Fenster `nc-sync.sh cutover` in **27 Sekunden**
  (10:20 UTC), dann Datenbank, Konvertierung, DNS. Bilder, PDFs und Office-Dateien
  über Collabora funktionieren.
- Lightsail steht im Wartungsmodus, der Host-Cron ist entfernt. Erreichbar per SSH
  jetzt nur noch über die IP `3.65.3.213`, Port 1987 — `cloud.dpvonline.de` zeigt auf
  die VM.
- **Offen:** Aufräumen (siehe „Danach"), erst wenn alles als funktionsfähig gemeldet
  ist.

**Vorfall: PHP-Abstürze ab 23.10.** Nextcloud fiel wiederholt aus (Caddy: 502), bis
der Container neu gestartet wurde. Ursache: Apache-Kindprozesse beendeten sich mit
`Segmentation fault` — 502 am 23.10., 107 am 25.10., 68 am 28.10. Einmal begonnen,
stürzte jeder neue Prozess ab, bis Apache neu startete; der Container selbst lief
weiter (kein Neustart, kein OOM). Hauptverdacht ist der OPcache-JIT, den das Image
einschaltet (`opcache.jit=1255`): sein Code liegt in gemeinsamem Speicher, und er lief
erstmals unter echter Last, auf ARM64, mit dem neuen PHP 8.4.27. Bewiesen ist das
nicht (kein Core-Dump, der Kernel protokollierte nichts). Seit 28.10. ist der JIT aus
([`compose/nextcloud/zz-dpv-opcache-jit.ini`](compose/nextcloud/zz-dpv-opcache-jit.ini)).
Stürzt es weiter ab: Core-Dumps aktivieren und die Stelle bestimmen.

Nebenbefund: Am 27.10. war Postgres eine Stunde lang voll (236 abgelehnte
Verbindungen, Standard 100). Seitdem `max_connections=200`.

**Datenabgleich am 28.10.** Alle Dateien von Lightsail sind auf der VM, keine fehlt;
12 wurden seit dem Cutover auf der VM geändert. Gegen die Datenbank geprüft: 4
Papierkorb-Einträge ohne Datei wurden entfernt, 94 verwaiste `.part`-Dateien
abgebrochener Uploads (291 MB) gelöscht.

**SSO: seit 28.10. `user_oidc` statt `oidc_login`.** Umgestellt mit
[`nc-sso.sh`](scripts/nextcloud-migration/nc-sso.sh), das vorher Gruppen,
Mitgliedschaften, Kontingent und E-Mail sichert (`/root/sso/snapshot-*`). Zurück geht es
mit `nc-sso.sh to-oidc-login`, `oidc_login` bleibt dafür installiert. Der Provider
`DPV` nutzt denselben Keycloak-Client `nextcloud` und dessen Secret:

```
$O user_oidc:provider DPV --clientid=nextcloud --clientsecret='<Secret>' \
  --discoveryuri=https://auth.dpvonline.de/realms/DPV/.well-known/openid-configuration \
  --scope='openid profile email' --unique-uid=0 \
  --mapping-uid=preferred_username --mapping-display-name=nickname \
  --mapping-email=email --mapping-quota=nextcloudquota --mapping-groups=roles \
  --group-provisioning=1 --group-whitelist-regex='/^(?!admin$)/' --send-id-token-hint=1
$O config:system:set user_oidc enrich_login_id_token_with_userinfo --type=boolean --value=true
```

- `--unique-uid=0` und `soft_auto_provision` (Standard) übernehmen die bestehenden
  Konten mit ihrer ID; `oc_user_oidc` bleibt deshalb leer.
- Gruppen kommen bei jedem Login aus `roles`. Was dort fehlt, entfernt `user_oidc` —
  außer `admin`, die bleibt lokal (Whitelist). Daran hängen die Gruppenordner, deshalb
  in den ersten Tagen `nc-sso.sh diff` gegen die Momentaufnahme; `restore … --apply`
  stellt Mitgliedschaften wieder her.
- In Keycloak ist zusätzlich `https://cloud.dpvonline.de/apps/user_oidc/code` als
  Redirect-URI eingetragen.
- `/login` leitet direkt zu Keycloak (`allow_multiple_user_backends=0`), die lokale
  Anmeldung bleibt unter `/login?direct=1` erreichbar.
- Der Desktop-Client öffnet zum Anmelden den Browser und landet nicht mehr auf der
  Nextcloud-Passwortmaske.

### Vorbereitung

- **Mindestens einen Tag vorher bei IONOS** die TTL von `cloud.` und `office.dpvonline.de`
  (A und AAAA) auf 300 setzen (Lehre aus Cutover A). Alte Werte für den Rollback
  notieren: `cloud` A `3.65.3.213`, AAAA `2a05:d014:77e:a000:175b:8a8f:6acc:5b38`;
  `office` A `72.144.24.168` (AKS, antwortet nicht).
- **Am Vortag** auf Lightsail `nc-sync.sh delta` und die Dauer notieren — `delta` lässt
  `config.php` der Testkopie in Ruhe. Die eigene IP in `ADMIN_IP_CIDRS` prüfen.
- Fenster ankündigen, inklusive: Desktop-Clients pausieren nicht von selbst, sie
  synchronisieren nach dem Fenster weiter.

### Schritte

| # | Schritt | Rollback |
|---|---|---|
| 1 | Lightsail: `occ maintenance:mode --on`, `/etc/cron.d/nextcloud-cron` wegschieben — **Schreibstopp** | Modus aus, Cron zurück |
| 2 | Lightsail: `nc-sync.sh cutover` — jetzt **mit** `config.php` | wie 1 |
| 3 | Lightsail: `nc-db.sh` (startet MariaDB auf der VM, legt die DB neu an) | wie 1 |
| 4 | VM: `KEEP_MAINTENANCE=1 nc-convert.sh` | wie 1 |
| 5 | `terraform.tfvars`: `DOMAIN_CLOUD = "cloud.dpvonline.de"`, `DOMAIN_OFFICE = "office.dpvonline.de"`, `apply` (nur zwei Secrets in-place) | wie 1 |
| 6 | IONOS: A und AAAA von `cloud` und `office` auf die VM | DNS zurück, dann wie 1 |
| 7 | VM: `systemctl restart dpv-compose.service` — jetzt mit `nextcloud-cron`; Collabora-URLs auf `https://office.dpvonline.de` (Phase 3, Schritt 6); `maintenance_window_start` auf 1 | wie 6 |
| 8 | Prüfen wie in Phase 3, mit echten Konten und einem laufenden Desktop-Client | wie 6 |
| 9 | `occ maintenance:mode --off` auf der VM — **ab hier kein verlustfreies Zurück** | nur mit Datenverlust |

Anders als in Phase 3: Die in Schritt 2 kopierte `config.php` bringt die
Produktionswerte mit — Hostnamen, `oidc_login`-Client, Mailserver, MariaDB — und
`maintenance => true`. Deshalb **keine** Anpassungen aus Phase 3, Schritt 4, und erst
in Schritt 9 den Wartungsmodus lösen. `nextcloud` bleibt dabei laufen, `nc-convert.sh`
braucht es für `occ`. `files:scan` ist nicht nötig: Dateien und Datenbank stammen
beide aus dem eingefrorenen Stand.

### Danach

- Lightsail **im Wartungsmodus** weiterlaufen lassen, bis alles durchgetestet ist. So
  bleibt es Rollback-Ziel, aber Clients mit altem DNS-Eintrag schreiben nicht mehr
  dorthin.
- Aufräumen, wenn alles als funktionsfähig gemeldet ist:
  - `3.65.3.213/32` aus `ADMIN_IP_CIDRS`, `terraform apply`
  - Migrationsschlüssel aus `~dpvadmin/.ssh/authorized_keys` der VM, auf Lightsail
    `/root/.ssh/dpv-migration_ed25519*` löschen
  - `docker rm -f nextcloud-mariadb`, `/data/apps/nextcloud-mariadb`,
    `/root/config.php.before-pgsql.*`
  - Keycloak-Client `nextcloud-test`
  - `occ app:remove oidc_login`, die `oidc_login_*`-Werte aus `config.php` und die
    alte Redirect-URI `/apps/oidc_login/oidc` im Keycloak-Client; `/root/sso` und
    `/root/verify` auf der VM
- Beim Abschalten von Lightsail **auch beide EFS löschen** (Nutzerdaten und Backups,
  zusammen >300 GB) — sie hängen nicht an der Instanz und kosten allein weiter. Das
  EFS hat ein eigenes AWS-Backup; dessen Aufbewahrung vorher prüfen.

---

## Zwischenschritt — AKS abreißen

**Ziel:** Die Resource Group `Infra` ist weg, die Zone `scout-tools.de` liegt in
`rg-dpv-core` und gehört diesem Repo, `azure-infrastructure` ist archiviert. Das spart
~155 €/Monat. Keine Nutzer betroffen.

### Stand 28.10.2026: durchgeführt

- Den Cluster hat Philip am 28.10. von Hand gelöscht. Mit ihm ist die Gruppe
  `MC_Infra_Kubernetes-Cluster_germanywestcentral` weg: Knoten, Load Balancer und alle
  Platten, also auch das Postgres mit der Biber-Datenbank. Die Schritte unten liefen am
  selben Tag.
- Übrig waren in `Infra`: Registry `biber`, Log Analytics `kubernetes-analytics`,
  Prometheus-Workspace `kubernetes-monitoring` (mit der verwalteten Gruppe
  `MA_kubernetes-monitoring_…`), Datensammelregeln und -endpunkt, acht
  Prometheus-Regelgruppen (sechs davon aus dem Portal, nicht aus Terraform), VNet
  `k8s-network`, die beiden früheren Ingress-Adressen, ein Azure-Migrate-Projekt
  `keycloak` und die Zone `scout-tools.de`. Bis auf die Zone ist alles mit der Gruppe
  gelöscht; verwaiste Rollenzuweisungen blieben keine.
- Das alte Repo wurde nicht zurückgeschnitten: Sein State war vom 24.09. und kannte den
  Cluster noch, ein `terraform apply` hätte AKS neu aufgebaut. Stattdessen ging alles
  Übrige mit der Resource Group. Seit Cutover B zeigt `office.dpvonline.de` auf die VM,
  die früheren Ingress-Adressen konnten also mit weg, ohne dass ein Name ins Leere zeigt.
- In der Zone stand außerdem ein A-Record `agent` auf `3.122.236.130` (AWS, antwortete
  nicht), aus keinem der beiden Repos. Gelöscht: Ein Name auf eine freigegebene
  Cloud-Adresse lässt sich von deren nächstem Inhaber übernehmen.
- Die Zone liegt in `rg-dpv-core`, mit unveränderten Nameservern (`ns1-06` bis `ns4-06`)
  und nur noch NS und SOA. Import und Tags mit #45.
- Der Service Principal `Terraform` des alten Repos (Contributor und User Access
  Administrator auf der Subscription) ist gelöscht; sein einziges Secret war das aus der
  alten `variables.tfvars`. `azure-infrastructure` ist archiviert.
- **Offen:** Die lokalen Dateien aus Schritt 6 löschen, vorher Confluence-Lizenz und
  SMTP-Passwort aus der alten `variables.tfvars` sichern, falls sie sonst nirgends
  stehen. Der Hinweis im README des alten Repos fehlt; zum Bearbeiten das Repo kurz
  entarchivieren.

### Warum die Zone umzieht und nicht neu entsteht

`scout-tools.de` wird weiter gebraucht, derzeit aber ohne eigene Records. Die Zone wird
nach `rg-dpv-core` **verschoben**: Laut [DNS-FAQ](https://learn.microsoft.com/en-us/azure/dns/dns-faq)
bleiben die zugewiesenen Nameserver dabei gleich. Eine neue Zone gleichen Namens bekäme
andere, und die Domain löste nicht mehr auf, bis die Delegation beim Registrar angepasst
ist. Aus demselben Grund steht die Zone in [`terraform/dns.tf`](terraform/dns.tf) unter
`prevent_destroy`.

Vorher fallen alle Records weg, die nichts mehr bedienen: `auth`, `wiki`, `cloud` und
`office` (Testnamen aus diesem Repo) sowie `@`, `db` und `anmeldung` (Biber und pgAdmin
aus dem alten Repo), jeweils A und AAAA.

### Schritte

Nicht zwischen 01:00 und 04:30 UTC: Während des Umzugs sperrt Azure Quell- und
Zielgruppe für Änderungen, und das könnte Azure Backup in `rg-dpv-core` stören.

| # | Schritt | Rollback |
|---|---|---|
| 1 | Vorab: Locks prüfen, Nameserver und Records notieren | – |
| 2 | Records löschen: 8 per Terraform, 6 per `az` | nicht nötig, nichts nutzt sie |
| 3 | Zone verschieben, Nameserver vergleichen | zurückverschieben |
| 4 | Zone in diesem Repo importieren, vom PR-Branch `apply`, PR mergen | wie 3 |
| 5 | Resource Group `Infra` löschen — **ab hier kein Zurück** | – |
| 6 | Altes Repo archivieren, lokal aufräumen | – |

**1 — Vorab.**

```
az lock list -g Infra -o table
az lock list -g rg-dpv-core -o table
az network dns zone show -g Infra -n scout-tools.de --query nameServers -o tsv
az network dns record-set list -g Infra -z scout-tools.de --query "[].{name:name, type:type}" -o table
az role assignment list --scope "$(az network dns zone show -g Infra -n scout-tools.de --query id -o tsv)" -o table
```

Beide Lock-Listen müssen leer sein, ein Lock auf einer der Gruppen verhindert den Umzug.
Die vier Nameserver notieren. Rollenzuweisungen direkt auf der Zone ziehen nicht mit um;
steht dort etwas, nach Schritt 3 neu anlegen.

**2 — Records.** In diesem Repo, noch auf `main`, also mit dem alten `dns.tf`:

```
cd terraform
terraform destroy \
  -target=azurerm_dns_a_record.auth   -target=azurerm_dns_aaaa_record.auth \
  -target=azurerm_dns_a_record.wiki   -target=azurerm_dns_aaaa_record.wiki \
  -target=azurerm_dns_a_record.cloud  -target=azurerm_dns_aaaa_record.cloud \
  -target=azurerm_dns_a_record.office -target=azurerm_dns_aaaa_record.office
```

Erwartet: **8 to destroy**, nichts sonst. Dann die drei Namen aus dem alten Repo:

```
for n in @ db anmeldung; do
  az network dns record-set a    delete -g Infra -z scout-tools.de -n "$n" --yes
  az network dns record-set aaaa delete -g Infra -z scout-tools.de -n "$n" --yes
done
az network dns record-set list -g Infra -z scout-tools.de --query "[].{name:name, type:type}" -o table
```

Übrig bleiben NS und SOA, dazu alles aus Schritt 1, was nicht zu AKS gehörte; das zieht
mit um.

**3 — Umzug.**

```
az resource move --destination-group rg-dpv-core \
  --ids "$(az network dns zone show -g Infra -n scout-tools.de --query id -o tsv)"
az network dns zone show -g rg-dpv-core -n scout-tools.de --query nameServers -o tsv
dig +noall +answer SOA scout-tools.de @8.8.8.8
```

Dauert ein paar Minuten. Die Nameserver müssen dieselben sein wie in Schritt 1, und
`dig` muss eine Antwort zeigen. Sonst hier anhalten: `Infra` steht noch, und
`az resource move --destination-group Infra …` bringt die Zone zurück.

**4 — Übernehmen.** PR-Branch auschecken, in `terraform.tfvars` die Zeile
`OLD_REPO_RESOURCE_GROUP` löschen (sonst nur eine Warnung), dann:

```
terraform import azurerm_dns_zone.scout_tools \
  "/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-dpv-core/providers/Microsoft.Network/dnsZones/scout-tools.de"
terraform plan
```

Erwartet: **0 to add, 1 to change, 0 to destroy**, die Zone bekommt die Tags aus `TAGS`.
Steht dort ein `create` für die Zone, hat der Import nicht gegriffen: **nicht anwenden**,
Terraform legte sonst eine zweite Zone mit anderen Nameservern an. Passt der Plan,
`terraform apply`, PR mergen, `git checkout main && git pull`. Die VM braucht nichts
davon.

**5 — `Infra` löschen.**

```
az resource list -g Infra --query "[].{name:name, type:type}" -o table
az group delete -n Infra
az group list --query "[].name" -o tsv
az role assignment list --all --query "[?principalName==''].{role:roleDefinitionName, scope:scope}" -o table
```

In der ersten Liste darf `scout-tools.de` **nicht** mehr stehen. `az group delete` fragt
nach und braucht ein paar Minuten; `MA_kubernetes-monitoring_…` sollte mit dem
Monitor-Workspace verschwinden. Danach bleiben `rg-dpv-core`, `rg-dpv-tfstate`,
`AzureBackupRG_…` und `NetworkWatcherRG`. Die letzte Abfrage zeigt Rollenzuweisungen
gelöschter Identitäten, etwa die der Cluster-Identität; was sich auf `Infra` bezieht,
mit `az role assignment delete --ids …` entfernen.

**6 — Altes Repo.**

- Im README von `azure-infrastructure` auf dieses Repo verweisen, dann
  `gh repo archive dpvonline/azure-infrastructure`.
- Den Service Principal des alten Repos (`CLIENT_ID` in dessen `variables.tfvars`)
  löschen, wenn ihn sonst nichts nutzt:
  `az role assignment list --assignee <CLIENT_ID> --all -o table`, dann
  `az ad app delete --id <CLIENT_ID>`.
- Lokal im alten Repo-Verzeichnis löschen: `terraform.tfstate*` und `variables.tfvars`
  (Passwörter im Klartext), beide kubeconfig-Dateien, die `keycloak*.dump`
  (Passwort-Hashes).

### Rollback

Bis Schritt 4 steht `Infra` noch, die Zone lässt sich zurückverschieben. Schritt 5 ist
endgültig; gebraucht wird von dem, was dann noch in `Infra` liegt, nichts mehr.

---

## Zwischenschritt — Ubuntu 26.04 für Livepatch

**Ziel:** `vm-dpv-core` läuft auf Ubuntu 26.04 LTS (`resolute`) statt 24.04. Dann
greift Livepatch aus dem schon angemeldeten Ubuntu Pro: Kernel-Sicherheitsfixes wirken
ohne Neustart, und die VM muss für Kernel-Updates nur noch einmal im Monat neu starten
statt jede Woche (Folgeänderung, siehe „Neustarts danach").
**Wartungsfenster, Nutzer betroffen:** Anmeldung, Wiki, Nextcloud und Collabora sind
30–45 Minuten weg. 1,5 Stunden ankündigen.

**Warum 26.04:** Livepatch für ARM64 gibt es erst ab Ubuntu 26.04. Für ältere Releases
fehlte Kernel und Werkzeugen die nötige Unterstützung
([Ankündigung vom 23.06.2026](https://canonical.com/blog/canonical-announces-live-kernel-patching-for-arm64)),
deshalb zeigt `pro status` seit dem Umzug auf ARM64 bei Livepatch `n/a`. Laut
[Kernel-Tabelle](https://ubuntu.com/security/livepatch/docs/client/reference/platform/supported-kernels/)
ist für 26.04 auf arm64 der Kernel 7.0 (GA) abgedeckt, in den Varianten aws, **azure**,
fips, gcp, generic, gke, ibm, lowlatency und oracle. Damit ist `linux-azure` abgedeckt,
den das Azure-Image mitbringt (in `resolute-updates` derzeit `7.0.0-1019`). Für 24.04
hat die Tabelle keine einzige arm64-Zeile.

Was Livepatch nicht leistet: Es behebt nur Lücken der Stufen hoch und kritisch, und
jeder Kernel-Build bekommt Patches nur 9–13 Monate ab seinem Erscheinen (7.0 auf 26.04:
13). Neustarts in einen neuen Kernel bleiben nötig, nur seltener und geplant.

### Neuaufbau statt `do-release-upgrade`

Beides ginge: `do-release-upgrade` bietet 24.04 → 26.04.1 seit dem 29.09.2026 an.
Empfehlung: **Neuaufbau** per Terraform mit dem 26.04-Image, nach dem Muster von „Umzug
auf ARM64".

| | Neuaufbau (`UBUNTU_RELEASE = "26.04"`) | `do-release-upgrade` auf der VM |
|---|---|---|
| Rollback | `UBUNTU_RELEASE = "24.04"`, `apply`, wie Rollback A beim ARM64-Umzug | nur über eine OS-Platte aus Azure Backup, an Terraform vorbei, nie geprobt |
| cloud-init auf 26.04 | läuft jetzt einmal durch, im geplanten Fenster | läuft zum ersten Mal beim nächsten Neuaufbau, also womöglich im Ernstfall |
| Terraform | `vm.tf` beschreibt die VM, wie sie ist | `vm.tf` sagt weiter 24.04; das Image dort umzustellen baut die VM doch neu |
| Docker, Azure CLI | kommen gleich aus den `resolute`-Quellen | Das Upgrade schaltet beide Fremdquellen ab. Danach von Hand umstellen, bis dahin läuft Docker mit `noble`-Paketen |
| Ergebnis | wie eine Neuinstallation (chrony, Rust-Coreutils, sudo-rs, frische Konfiguration) | Mischstand aus alter Konfiguration und neuen Paketen |
| Verloren | alles auf der OS-Platte: Host-Keys, Managed Identity, Zertifikate, Docker-Images, Logs, Handarbeit außerhalb von cloud-init | nichts |
| Ausfall | 30–45 Min. (24.09.: 40) | ähnlich, Upgrade plus Neustart |

Den Ausschlag geben die ersten beiden Zeilen. Der Neuaufbau ist der Weg, den das Repo
für Änderungen an der VM vorsieht (Kommentar am Ende von `azurerm_linux_virtual_machine`
in `terraform/vm.tf`). Er ist erprobt, und sein Rollback ist derselbe Vorgang rückwärts.
Die Plattenpanne vom 24.09. ist behoben: cloud-init wartet bis zu 30 Minuten auf die
Platten, und weder `boot.sh` noch Docker starten den Stack ohne alle drei Mounts. Was
verloren geht, ist bekannt. Zertifikate und Images kommen von selbst wieder, Logs
sichert Schritt 1, Handarbeit erfasst die Vorbereitung.

Für Postgres ändert sich diesmal nur der Kernel darunter. Architektur, Image
`postgres:18`, glibc im Container (und damit die Sortierung) und Datenverzeichnis
bleiben gleich. Dumps und `amcheck` wie beim ARM64-Umzug braucht es deshalb nicht.
Rückfall sind das Full-Backup aus Schritt 1 und die Azure-Sicherung der Nacht.

### Kompatibilität (geprüft am 28.10.2026)

| Was | Ergebnis |
|---|---|
| Image | `Canonical:ubuntu-26_04-lts:server-arm64` in `germanywestcentral`, neueste Version `26.04.202610210`. Gen2, dieselben Features wie das 24.04-Image (Trusted Launch möglich, SCSI und NVMe), kein Marketplace-Plan. Nur das Offer ändert sich, die SKU bleibt `server-arm64`. |
| Livepatch | Kernel 7.0 GA, Variante `azure`, siehe oben. `pro attach` in cloud-init schaltet Livepatch mit ein, wo es verfügbar ist; cloud-init braucht dafür keine Änderung. |
| Docker-Repo | `download.docker.com/linux/ubuntu` hat `resolute` für arm64, mit denselben Versionen wie `noble` (`docker-ce` 29.9.2, Compose 5.6.1, containerd 2.4.2). `$VERSION_CODENAME` in `cloud-init.yaml.tftpl` liefert `resolute`. |
| Azure CLI | `InstallAzureCLIDeb` nimmt den eigenen Codenamen, wenn er unter `packages.microsoft.com/repos/azure-cli/dists/` steht, sonst still `jammy`. `resolute` steht dort, mit `azure-cli` 2.91 für arm64. |
| unattended-upgrades | Die Muster in `scripts/apt/52dpv-unattended-upgrades` nutzen `${distro_codename}`. Die Release-Dateien beider Fremdquellen (`Origin: Docker` bzw. `Origin: azure-cli resolute`, `Suite: resolute`) passen dazu. |
| Azure Monitor Agent | Ubuntu 26.04 LTS steht in der [Liste](https://learn.microsoft.com/en-us/azure/azure-monitor/agents/azure-monitor-agent-supported-operating-systems), „also supported on ARM64-based machines". Die Extension baut Terraform beim Neuaufbau ohnehin neu. |
| Azure Backup | Die [Matrix](https://learn.microsoft.com/en-us/azure/backup/backup-support-matrix-iaas) verweist auf die [von Azure unterstützten Distributionen](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/endorsed-distros), und dort steht Ubuntu 26.04 LTS. Enhanced Policy mit Premium SSD v2 bleibt unterstützt. ARM64 erwähnt die Matrix nicht, gesichert wird die ARM64-VM aber seit dem 24.09. |
| cloud-init | Version 26.1, laut Release Notes keine Änderungen für Azure. Das Template hat nichts Release-Spezifisches; ein Rollback auf 24.04 nutzt dasselbe. |
| Sonst in 26.04 | `sudo` ist sudo-rs (das bisherige heißt `sudo.ws`). Die Coreutils kommen aus Rust (uutils), außer `cp`, `mv` und `rm`; die Skripte nutzen nur gängige Optionen von `install`, `seq`, `chown` und `ln`. Zurück zu GNU: `sudo apt install coreutils-from-gnu coreutils-from-uutils- --allow-remove-essential`. systemd 259 kennt nur noch cgroup v2 (nutzt 24.04 schon), OpenSSH 10.2 hat kein DSA mehr (die VM nutzt ed25519), Python 3.14, chrony statt timesyncd. |

### Offene Risiken

1. **Postgres unter Linux 7.0.** Ubuntu führt als bekanntes Problem, dass eine Änderung
   in Linux 7.0 Durchsatz und Latenz von Postgres deutlich verschlechtern kann (Wegfall
   von `PREEMPT_NONE`); Systeme mit Huge Pages sind nicht betroffen. Gemeldet wurde ein
   halbierter Durchsatz auf einer großen Maschine unter Volllast. Bei 4 vCPU und der
   Last hier ist wenig zu erwarten, belegt ist es nicht. Womöglich läuft die VM aber
   schon darauf: `linux-azure` ist auch auf 24.04 bei 7.0 angekommen (`noble-updates`:
   `7.0.0-1017.17~24.04.1`). Zeigt `uname -r` auf der VM heute schon `7.0.…`, ist das
   Risiko längst im Betrieb und der Umzug ändert daran nichts. Sonst gilt: Unser Postgres
   läuft ohne Huge Pages, deshalb gibt es eine Messung vorher und nachher, und
   Rollback C schaltet Huge Pages ein.
2. **Kernelwechsel innerhalb von 26.04.** `linux-azure` zieht während eines LTS auf
   neuere Kernel nach: bei 24.04 von 6.8 bis heute auf 7.0, während
   `linux-azure-lts-24.04` bei 6.8 blieb. Bei 26.04 voraussichtlich ab 26.04.2 im Februar
   2027. Ob Livepatch diese Kernel auf arm64 abdeckt, steht noch nicht in Canonicals
   Tabelle; auf x86 tut es das, mit 9 statt 13 Monaten. Fehlt die Abdeckung, startet die
   VM wieder wöchentlich neu (siehe „Neustarts danach") — sicher, nur häufiger.
   Gegenmittel: auf den GA-Kernel festlegen, also `linux-azure-lts-26.04` installieren
   und die übrigen `linux-*azure`-Metapakete entfernen (`dpkg -l 'linux-*azure*'`). Auf
   26.04 sind heute beide derselbe Kernel. Im Februar 2027 prüfen.
3. **Plätze im Ubuntu-Pro-Abo.** Das kostenlose Personal-Abo deckt fünf Maschinen ab,
   und jeder Neuaufbau ist für Ubuntu Pro eine neue. Schritt 2 meldet die alte VM ab;
   vorher im [Dashboard](https://ubuntu.com/pro/dashboard) nachsehen, wie viele
   eingetragen sind. Scheitert `pro attach`, steht es in
   `/var/log/dpv-boot-warnings.log`, und es gibt kein Livepatch.
4. **Handarbeit auf der VM.** Was je von Hand eingerichtet wurde und nicht in cloud-init
   steht, ist nach dem Neuaufbau weg. Die Vorbereitung gleicht das einmal ab.
5. **Azure Backup auf 26.04.** Laut Liste unterstützt, belegt erst durch den ersten Job
   (Schritt 9). Scheitert er, gilt dasselbe wie beim ARM64-Umzug: nichts löschen.
6. **Keine Hardware.** Terraform löscht die alte VM, bevor es die neue anlegt. Gibt es in
   Zone 1 gerade keine `D4ps_v6`, hilft auch der Rollback auf 24.04 nicht (Rollback A).

### Wer merkt was

| Zeitraum | Wiki | Anmeldung (Keycloak) | Nextcloud, Collabora |
|---|---|---|---|
| Schritt 2 bis 4 | weg | **weg** | weg; Desktop-Clients synchronisieren danach von selbst weiter |
| Schritt 5 bis 7 | erreichbar, wird geprüft | erreichbar, wird geprüft | erreichbar, wird geprüft |
| ab Schritt 8 | normal | normal | normal |

### Vorbereitung

- Diesen PR mergen. Solange `UBUNTU_RELEASE` nicht in `terraform.tfvars` steht, ändert
  ein `terraform apply` nichts an der VM. `terraform plan` muss vorher **No changes**
  zeigen, sonst erst klären, was da ansteht.
- Den PR mit den OS-Updates (`unattended-upgrades`, `dpv-reboot-if-required`) vorher
  mergen. cloud-init klont das Repo beim Neuaufbau frisch, auf die VM kommt also, was an
  dem Tag auf `main` ist.
- **Handarbeit abgleichen**, auf der VM:
  ```
  ls /etc/systemd/system/ /etc/systemd/system/*.d /etc/cron.d /etc/sysctl.d
  ls /etc/apt/apt.conf.d /etc/apt/sources.list.d
  sudo crontab -l; sudo docker volume ls; sudo ls -la /root
  ```
  Jeder Eintrag muss aus cloud-init, von Ubuntu oder aus einem Paket stammen; was nicht,
  in cloud-init nachtragen oder bewusst fallen lassen. Unter `/root` liegen womöglich
  noch Reste aus früheren Schritten (etwa `pgdata-leeres-cluster-os-platte`,
  `config.php.before-pgsql.*`), die mit der OS-Platte verschwinden.
- **Vergleichswert für Postgres** (entfällt, wenn `uname -r` schon `7.0.…` zeigt, siehe
  Risiko 1), an einem ruhigen Abend, nicht zwischen 00:30 und 04:30 UTC:
  ```
  cd /opt/dpv/compose
  P="sudo docker compose exec -T --user postgres postgres"
  $P createdb pgbench_probe
  $P pgbench -i -s 20 -q pgbench_probe
  $P pgbench -c 8 -j 4 -T 60 -S pgbench_probe | grep -E "latency average|tps"
  $P pgbench -c 8 -j 4 -T 60 pgbench_probe | grep -E "latency average|tps"
  ```
  Beide Ergebnisse notieren. `pgbench_probe` (~300 MB) bleibt für den Vergleich danach
  stehen.
- Kontingent für eine ARM64-Ausweichgröße (Rollback A) prüfen:
  `az vm list-usage -l germanywestcentral -o table | grep -iE "ps.*family|regional"`.
  Am 28.10.: `Dpsv6` 4 von 350, `Bpsv2` 0 von 65, regional 4 von 13 vCPUs.
- Fenster ankündigen. **Nicht** zwischen 00:30 und 04:30 UTC (OS-Updates, Azure Backup,
  pgBackRest, Sonntags-Update mit Neustart, Confluence-Prune), und nicht am Tag nach
  einem Major-Update aus Renovate.
- Eigene IP in `ADMIN_IP_CIDRS`, SSH auf die VM geht.

### Schritte

| # | Schritt | Dauer | Rollback |
|---|---|---|---|
| 1 | Full-Backup, Logs sichern | 5 Min. | – |
| 2 | Stack stoppen, Zahlen und `pg_control` notieren, `pro detach` — **Ausfall beginnt** | 3 Min. | `pro attach`, `systemctl restart dpv-compose.service` |
| 3 | `UBUNTU_RELEASE = "26.04"`, `terraform apply` | 5–10 Min. | **A** |
| 4 | Host-Key, cloud-init, **alle drei Mounts**, Release prüfen | 10–30 Min. | A |
| 5 | Postgres prüfen | 5 Min. | A |
| 6 | pgBackRest prüfen, Full-Backup | 5 Min. | |
| 7 | Dienste prüfen | 15 Min. | A |
| 8 | Livepatch prüfen | 5 Min. | – |
| 9 | Freigeben, Azure Backup, Monitoring, Timer, Postgres-Vergleich | 30 Min. | wie A, auch danach; **C** |

**1 — Sicherung.** Auf der alten VM:

```
sudo /opt/dpv/scripts/pgbackrest-full-backup.sh
sudo install -d -m 700 /data/apps/pre-2604
sudo cp -a /var/log/dpv-update.log /var/log/dpv-boot-warnings.log \
  /var/log/unattended-upgrades /data/apps/pre-2604/
dpkg -l | sudo tee /data/apps/pre-2604/dpkg-24.04.txt >/dev/null
```

Fehlende Logs meldet `cp` und überspringt sie. Zweiter Rückfall ist die Azure-Sicherung
von 01:00:
`az backup recoverypoint list -g rg-dpv-core -v rsv-dpv-core --backup-management-type AzureIaasVM -c vm-dpv-core -i vm-dpv-core --query "[0].properties.recoveryPointTime" -o tsv`.

**2 — Stoppen.** Erst alles außer Postgres, dann zählen, dann Postgres. So ändern sich
die Zahlen bis Schritt 5 nicht mehr:

```
cd /opt/dpv/compose
P="sudo docker compose exec -T --user postgres postgres"
sudo docker compose stop $(sudo docker compose config --services | grep -vx postgres)
$P psql -d confluence -Atc "select (select count(*) from content), (select count(*) from bodycontent)"
$P psql -d keycloak -Atc "select count(*) from user_entity"
$P psql -d nextcloud -Atc "select (select count(*) from oc_filecache), (select count(*) from oc_share)"
sudo docker compose stop -t 120 postgres
sudo docker compose run --rm --no-deps --user postgres --entrypoint pg_controldata \
  postgres /var/lib/postgresql/data/pgdata | grep -iE "system identifier|cluster state"
sudo pro detach --assume-yes
```

`Database cluster state` muss `shut down` sein. Systemkennung und die fünf Zahlen
notieren. `pro detach` gibt den Platz im Abo frei (Risiko 3), die neue VM meldet sich in
cloud-init selbst an. Zurück vor Schritt 3: `pro attach` mit dem Token aus Key Vault (wie
in cloud-init), dann `sudo systemctl restart dpv-compose.service`.

**3 — Neuaufbau.** Lokal in `terraform/terraform.tfvars` `UBUNTU_RELEASE = "26.04"`, dann
`terraform plan`. Erwartet: **8 to add, 0 to change, 8 to destroy**. Ersetzt werden die
VM (`offer "ubuntu-24_04-lts" -> "ubuntu-26_04-lts"`), die drei Plattenanbindungen, der
Monitoring-Agent mit seiner DCR-Zuordnung und die zwei Rollenzuweisungen (Key Vault,
pgBackRest-Speicher). **Nicht** im Plan dürfen stehen: `azurerm_managed_disk.*`,
`azurerm_backup_protected_vm.app`, irgendetwas aus Key Vault. Passt das,
`terraform apply`.

**4 — Host-Key und cloud-init.** Genau wie beim ARM64-Umzug, Schritt 4: Fingerabdruck
über `az vm run-command`, `cloud-init status --wait --long`, `dpv-boot-warnings.log`,
alle drei Mounts. Die Hinweise dort zu fehlenden Platten und zu `Forbidden` gelten
unverändert. Zusätzlich:

```
. /etc/os-release; echo "$VERSION_ID $VERSION_CODENAME"   # 26.04 resolute
uname -mr                                                 # 7.0.0-…-azure aarch64
cat /etc/apt/sources.list.d/docker.list                   # … resolute stable
apt-cache policy docker-ce azure-cli | grep -E "^[a-z]|Installed"
```

**5 — Postgres.**

```
cd /opt/dpv/compose
P="sudo docker compose exec -T --user postgres postgres"
sudo docker compose ps
sudo docker compose logs postgres | grep -iE "error|fatal|panic"
$P pg_controldata /var/lib/postgresql/data/pgdata | grep -i "system identifier"
```

Dieselbe Systemkennung wie in Schritt 2, keine Fehler. Die Zahlen aus Schritt 2
wiederholen: gleich, bei Nextcloud höchstens ein paar mehr, weil Clients sofort wieder
synchronisieren, sobald Caddy läuft.

**6 — pgBackRest.** Wie beim ARM64-Umzug, Schritt 6: Die neue Identität braucht ein paar
Minuten, bis ihre Rollenzuweisung wirkt. `stanza-create` meldet die bestehende Stanza als
gültig, dann `check` und `pgbackrest-full-backup.sh`.

**7 — Dienste.** Keycloak und Wiki wie beim ARM64-Umzug, Schritt 7 (IPv4 und IPv6,
Zertifikate, Login, Seite mit Anhang, Suche, Confluence-Log). Nextcloud und Collabora
nach Phase 3, „Verifikation", in kurz: SSO-Login von einem Gerät ohne Session, eine
Datei hoch- und herunterladen, ein Dokument in Collabora öffnen und speichern,
`curl -4`/`-6 https://cloud.dpvonline.de/status.php`, Nextcloud-Log ohne `level ≥ 3`.

**8 — Livepatch.**

```
pro status                                     # livepatch: enabled
sudo canonical-livepatch status --verbose      # Kernel supported, Patches applied/nothing-to-apply
pro api u.pro.security.status.reboot_required.v1 | jq .data.attributes
```

Steht Livepatch auf `disabled`: `sudo pro enable livepatch`. Ist Pro gar nicht
angemeldet: `dpv-boot-warnings.log` lesen, meist sind die Plätze voll (Risiko 3);
Dashboard aufräumen, dann `pro attach` mit dem Token aus Key Vault. Ohne Livepatch läuft
alles weiter, nur mit wöchentlichen Neustarts.

**9 — Freigeben und Nacharbeiten.** Wartungsende ankündigen. Danach, ohne Zeitdruck:

- Azure Backup gegen die neue VM wie beim ARM64-Umzug, Schritt 8: `backup-now`, der Job
  muss durchlaufen, die alten Wiederherstellungspunkte müssen bleiben.
- Monitoring: nach ~15 Minuten kommen in `log-dpv-core` wieder Zeilen an,
  `Perf | where TimeGenerated > ago(30m) | summarize by Computer, InstanceName`.
- Timer und OS-Updates: `systemctl list-timers 'dpv-*' apt-daily-upgrade.timer`,
  `/etc/cron.d/pgbackrest-full` existiert, und
  `sudo unattended-upgrade --dry-run --debug 2>&1 | grep -A6 'Allowed origins'` zeigt
  `resolute`.
- Falls in der Vorbereitung gemessen: in einer ruhigen Stunde die beiden `pgbench`-Läufe
  wiederholen. Deutlich schlechter (mehr als ein Fünftel weniger `tps`) oder fühlbar
  langsamer: Rollback C. Danach `$P dropdb pgbench_probe`.
- Im Repo: Default von `UBUNTU_RELEASE` in `terraform/variables.tf` auf `"26.04"`, die
  Zeile aus `terraform.tfvars` nehmen, `terraform plan` zeigt **No changes**. README
  („Ubuntu 24.04 LTS" unter Architektur) und hier einen „Stand"-Absatz nachtragen.
- Nach einer unauffälligen Woche `/data/apps/pre-2604` löschen.

### Rollback

**A — `apply` scheitert, die VM kommt nicht sauber hoch, oder etwas läuft auf 26.04
nicht.** In `terraform.tfvars` `UBUNTU_RELEASE = "24.04"`, `terraform apply`: Terraform
baut die VM mit dem 24.04-Image und demselben cloud-init neu, Schritte 4–7 wie oben. Die
Daten sind unverändert. Das gilt auch nach Schritt 9: Das Datenverzeichnis ist unter
beiden Releases dasselbe, ein Zurück kostet also nur einen weiteren Ausfall, keine Daten.
Bei `AllocationFailed`/`ZonalAllocationFailed` gibt es in Zone 1 gerade keine
`D4ps_v6`, und der Rollback hilft nicht, weil er dieselbe Größe braucht. Dann
vorübergehend eine andere ARM64-Größe mit demselben Image, etwa
`VM_SIZE = "Standard_B4ps_v2"` (Kontingent siehe Vorbereitung), und später zurück; das
ist ein Resize mit Neustart, kein Neuaufbau.

**C — Postgres merklich langsamer (Risiko 1).** Huge Pages einschalten, statt
zurückzubauen. Auf der VM (`P` wie in Schritt 2) die nötige Zahl abfragen und mit
etwas Luft reservieren:

```
$P psql -Atc "show shared_memory_size_in_huge_pages"     # z. B. 80
echo "vm.nr_hugepages = 100" | sudo tee /etc/sysctl.d/60-dpv-postgres-hugepages.conf
sudo sysctl --system && grep HugePages_Total /proc/meminfo
```

Dann im Repo `"-c", "huge_pages=on"` in `compose/docker-compose.postgres.yml` (`on`
statt `try`, damit Postgres bei fehlenden Huge Pages nicht startet, statt leise ohne
weiterzulaufen) und die sysctl-Datei in cloud-init nachtragen. Nach dem Ausrollen:
`$P psql -Atc "show huge_pages_status"` zeigt `on`. Hilft das nicht, Rollback A.

### Neustarts danach (Folgeänderung)

Noch nicht umgesetzt, weil die Grundlage noch nicht auf `main` ist: Der PR mit den
OS-Updates (Branch `claude/improve-update-process-a80af9`) lässt `unattended-upgrades`
Updates jede Nacht einspielen, ohne selbst neu zu starten (`Automatic-Reboot "false"`).
Den Neustart, den ein Update verlangt, übernimmt `dpv-reboot-if-required.timer` am
Sonntag um 04:10 UTC. Darauf setzt diese Änderung auf, sobald jener PR gemergt ist.

**Vorschlag:** `dpv-reboot-if-required.service` bekommt eine zweite `ExecCondition`, die
Ubuntu Pro fragt (`pro api u.pro.security.status.reboot_required.v1`):

- `yes-kernel-livepatches-applied`: Es warten nur Kernelpakete, und Livepatch hat den
  laufenden Kernel schon gepatcht und deckt ihn ab. Dann startet die VM nur am **ersten
  Sonntag im Monat** neu.
- Alles andere startet an diesem Sonntag neu, wie bisher. Das ist `yes`, wenn ein
  anderes Paket den Neustart verlangt oder Livepatch den Kernel nicht abdeckt (24.04 auf
  ARM64, Pro nicht angemeldet, Kernel aus dem Patch-Fenster heraus, Risiko 2). Dasselbe
  gilt, wenn Pro gar nicht antwortet.

```
#!/usr/bin/env bash
# scripts/reboot-due.sh — exit 0: reboot this Sunday, exit 1: skip (not a failure)
set -uo pipefail
[ "$(date -u +%d)" -le 7 ] && exit 0      # first Sunday of the month
status=$(pro api u.pro.security.status.reboot_required.v1 2>/dev/null \
  | jq -r '.data.attributes.reboot_required // empty' 2>/dev/null)
[ "$status" = "yes-kernel-livepatches-applied" ] && exit 1
exit 0
```

Dazu in der Unit `ExecCondition=/opt/dpv/scripts/reboot-due.sh`. Das Skript läuft aus
dem Repo, Änderungen daran brauchen also keinen Neuaufbau. Die Unit-Änderung kommt wie
jede andere zweimal rein: per cloud-init und einmal von Hand auf der laufenden VM. Nur
auf `yes-kernel-livepatches-applied` ist Verlass: Laut Quellcode des Pro-Clients kommt
es nur, wenn ausschließlich `linux-image*`/`linux-base` in
`/run/reboot-required.pkgs` stehen, Livepatch genau den laufenden Kernel kennt, dessen
Status `applied` oder `nothing-to-apply` ist und er als `supported` gilt. Das Feld
`livepatch_enabled_and_kernel_patched` ist dagegen lockerer berechnet und taugt nicht als
Bedingung.

Monatlich statt gar nicht, weil Livepatch nur hohe und kritische Lücken abdeckt und der
laufende Kernel im Patch-Fenster bleiben muss. Fällt der erste Sonntag aus, weil das
Container-Update noch lief, wartet der Neustart bis zum nächsten Monat; das Fenster von
13 Monaten verträgt das. Auf 24.04 ändert die Regel nichts, weil Livepatch dort `n/a` ist
und die Antwort damit immer `yes`. Sie kann deshalb vor dem Umzug ausgerollt werden.

---

## Phase 5 — Nacharbeiten

Kein Zeitdruck, alles nach dem letzten Cutover.

- **Keycloak-Client-Secrets rotieren** — jetzt sicher, weil beide Seiten auf derselben
  VM liegen.
- **Nextcloud weiter hochziehen**, 33 → 34 → 35, ein Major pro Schritt; vorher prüfen,
  ob alle Apps die neue Version unterstützen (Stand 24.09.: ja, für beide). Auf der VM
  ist das ein Renovate-PR plus Pre-Update-Backup, statt Handarbeit auf Lightsail.
- *Erledigt am 28.10.:* auf `user_oidc` umgestellt (Phase 4).
- **`notify_push`** (Client-Push): entlastet den Server bei vielen Desktop-Clients,
  die sonst regelmäßig nach Änderungen fragen. Optional das Talk-Hochleistungs-Backend.
- *Erledigt mit dem AKS-Abriss:* `terraform/dns.tf` ist aufgeräumt, die Zone
  `scout-tools.de` gehört diesem Repo, und `azure-infrastructure` hat keine Ressourcen
  mehr.
- **Optional:** `imaginary` als eigener Container für Bildvorschauen; Nextcloud Primary
  Object Storage auf Blob mit Lifecycle-Tiering, falls die Daten je in den TB-Bereich
  wachsen (bei 150 GB spart das ~15 €/Monat und kostet einen nicht unterstützten
  Migrationspfad — lohnt sich derzeit nicht).

---

## Offene Fragen

Keine. Die Fragen aus der Planung sind beantwortet (Versionen, Größen, SMB: siehe
Phase 1 und Phase 3). `user_oidc` hat `oidc_login` ersetzt, und damit ist auch die
Passwortmaske im Desktop-Client verschwunden (Phase 4).

## Kostenüberblick

Gemessen an der Abrechnung für August 2026, dem ersten vollen Monat mit der VM (netto,
EUR). Das Abo ist ein Sponsorship über 2.000 $ (~1.720 €) im Jahr; was darüber
hinausgeht, wird mit Mehrwertsteuer berechnet. Das ergibt ein Budget von ~143 €/Monat.

| Posten | `B4s_v2` (gemessen) | `D4ps_v6` | nach Phase 3 |
|---|---:|---:|---:|
| VM | 125,50 | ~110 | ~110 |
| Premium SSD v2, 96 GiB (Basis-IOPS kostenlos) | 8,20 | 8,20 | 8,20 |
| Standard SSD: Nextcloud 256 GiB + OS 48 GiB | 21,10 | 21,10 | 21,10 |
| Plattenzugriffe | ~0,50 | ~0,50 | ~2 |
| IPv4 (IPv6 ist kostenlos) | 3,30 | 3,30 | 3,30 |
| Azure Backup: Gebühr für die VM, Speicher, Snapshots | 8,10 | 8,10 | ~20 |
| Monitoring (Log Analytics im Freikontingent, 2 Log-Alerts) | ~1 | ~1 | ~1 |
| Blob (pgBackRest), Key Vault, Traffic bis 100 GB | < 0,20 | < 0,20 | ~0,50 |
| **Summe pro Monat** | **~168 €** | **~152 €** | **~166 €** |

Unsicher ist nach Phase 3 vor allem der Traffic: Über 100 GB ausgehend im Monat kostet
jedes GB ~0,075 €. Eine VM-Reservierung lohnt sich nicht, solange die Credits laufen:
Credits können keine Reservierung bezahlen, die Reservierung ginge also samt
Mehrwertsteuer auf die Karte.

Bis zum Abriss am 28.10. kam der AKS mit ~155 €/Monat dazu (Knoten, IP, Prometheus in
`Infra` und der `MC_`-Gruppe). Übrig bleibt davon nur die DNS-Zone `scout-tools.de`
(~0,45 €), jetzt in `rg-dpv-core`; die Container Registry (~4,50 €) ging mit `Infra`.
