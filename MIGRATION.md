# Migrationsplan: AKS + Lightsail → eine Azure-VM

Arbeitsdokument für den Umzug aller verbliebenen Dienste auf `vm-dpv-core`.
Architektur und Betrieb der Ziel-VM stehen im [README](README.md); hier steht nur,
wie wir dorthin kommen.

## Ausgangslage

| Dienst | läuft heute auf | Datenbank | Domain |
|---|---|---|---|
| Keycloak | AKS (`azure-infrastructure`) | Postgres im Cluster | `auth.dpvonline.de` |
| Confluence | AKS | Postgres im Cluster | `wiki.dpvonline.de` |
| Nextcloud + Collabora | **AWS Lightsail** (Docker Compose) | MariaDB 10.5 | `cloud.` / `office.dpvonline.de` |
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
| 3 | Standard SSD | 256 GiB | `/data/nextcloud` | Nextcloud-Nutzerdaten (~150 GB) |

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
- **Offen:** AKS steht mit 0 Replikas für Keycloak und Confluence, die PVCs sind
  unangetastet. Abriss nach ein paar unauffälligen Tagen, bis dahin im alten Repo kein
  `terraform apply`.

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
- Die Testnamen `auth.` und `wiki.scout-tools.de` bedient die VM nach Schritt 9 nicht
  mehr; die DNS-Einträge dafür in Phase 5 aufräumen.
- `office.dpvonline.de` zeigt auf AKS, antwortet aber schon heute nicht (Stand
  23.09.). Das betrifft Collabora für Nextcloud und gehört zu Phase 3.

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
- Livepatch gibt es auf ARM64 nicht (`pro status`: `n/a`), ESM läuft.

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
Lightsail-Daten. DNS unverändert, keine Nutzer betroffen.

Der eigentliche Knackpunkt ist die DB-Konvertierung. Sie hat beim letzten Versuch
grundsätzlich funktioniert und nur bei der Forms-App gehakt — aktuell laufen keine
Umfragen, das ist also der günstigste Zeitpunkt.

### Schritte

1. **Compose aus `nextcloud-config` übernehmen und ausdünnen.** Es entfallen `proxy`
   und `letsencrypt-companion` (Caddy übernimmt) sowie `backup` (Azure Backup und
   pgBackRest übernehmen). Es bleiben `app`, `redis` und `office`.
2. **`app/Dockerfile` ausdünnen.** Die Datei ist im Kern das offizielle Beispiel aus
   der [nextcloud/docker](https://github.com/nextcloud/docker)-README — `ffmpeg`,
   `ghostscript` und die ImageMagick-Extras bleiben, die sind für Vorschaubilder da.
   Raus sollten:
   - **`imap`** — die Extension wurde in PHP 8.4 aus dem Core entfernt; da
     `nextcloud:production-apache` ein floating Tag ist, bricht der Build sonst
     irgendwann beim Update weg.
   - **`smbclient`** — nur nötig bei SMB-External-Storage, vorher mit
     `occ files_external:list` prüfen.
3. **MariaDB 10.5 temporär** als Container mit auf die VM, in derselben Version wie auf
   Lightsail. Nur für die Konvertierung, verschwindet danach.
4. **Dateien übertragen** — `rsync` von Lightsail nach `/data/nextcloud` (Platte 3).
   ~150 GB; die AWS-Egress-Kosten liegen bei ~0,09 $/GB, also ~14 $ einmalig.
5. **DB übertragen** — `mysqldump` von Lightsail in den MariaDB-Container, Nextcloud
   dagegen hochfahren und prüfen, dass es *vor* der Konvertierung läuft.
6. **Forms entfernen** — `occ app:remove forms` löscht die Tabellen der App, sodass
   `db:convert-type` gar nicht erst darüber stolpern kann. Kostet die historischen
   Formulardaten; bei null aktiven Umfragen der beste Moment dafür.
7. **Konvertieren** — `occ maintenance:mode --on`, dann
   `occ db:convert-type --all-apps pgsql nextcloud <host> nextcloud`. Danach MariaDB
   entfernen.
8. Caddy-Routen für `cloud.` und `office.`, vorerst `tls internal`.

### Verifikation

Dateizugriff und Upload, Sharing-Links, Kalender und Kontakte, SSO-Login,
Collabora-Dokumentbearbeitung, Desktop-Client-Sync gegen einen Testaccount.

### Rollback

Container stoppen, Lightsail läuft unverändert weiter.

---

## Phase 4 — Cutover B: Nextcloud live

**Ziel:** `cloud.` und `office.dpvonline.de` zeigen auf die neue VM. **Wartungsfenster,
Nutzer betroffen.**

### Schritte

1. TTLs vorher herunterdrehen, Fenster ankündigen.
2. Nextcloud auf Lightsail in den `maintenance:mode` (Schreibstopp).
3. Finaler `rsync`-Delta-Lauf — nur noch die Änderungen seit Phase 3, entsprechend kurz.
4. Finaler DB-Dump aus Lightsail, Konvertierung nach dem in Phase 3 geprobten Ablauf.
5. Caddy auf echtes Let's Encrypt umstellen.
6. A/AAAA-Records für `cloud.` und `office.` umstellen.
7. `occ files:scan --all` und `occ maintenance:mode --off`.

### Verifikation

Wie Phase 3, zusätzlich mit echten Nutzeraccounts und einem laufenden Desktop-Client.

### Rollback

DNS zurück, Lightsail aus dem Maintenance-Mode holen.

### Danach

Nach einer unauffälligen Woche: **Lightsail abschalten.**

---

## Phase 5 — Nacharbeiten

Kein Zeitdruck, alles nach dem letzten Cutover.

- **Keycloak-Client-Secrets rotieren** — jetzt sicher, weil beide Seiten auf derselben
  VM liegen.
- **Forms-App neu installieren** (ohne die alten Daten).
- **Nextcloud stufenweise hochziehen** — nur ein Major-Sprung pro Schritt.
- **`terraform/dns.tf` aufräumen** — der `auth`-Record in `scout-tools.de` wird nicht
  mehr gebraucht. Damit fällt die letzte Abhängigkeit zum alten Repo weg und
  `azure-docker` steht vollständig auf eigenen Füßen.
- **Altes Repo aufräumen** — migrierte Ressourcen aus `azure-infrastructure` entfernen.
- **Optional:** `imaginary` als eigener Container für Bildvorschauen; Nextcloud Primary
  Object Storage auf Blob mit Lifecycle-Tiering, falls die Daten je in den TB-Bereich
  wachsen (bei 150 GB spart das ~15 €/Monat und kostet einen nicht unterstützten
  Migrationspfad — lohnt sich derzeit nicht).

---

## Offene Fragen

Diese Punkte blockieren nichts vor Phase 1, müssen aber vor der jeweiligen Phase
geklärt sein:

| Frage | Gebraucht für | Wie herausfinden |
|---|---|---|
| Welche Confluence-Version läuft auf AKS? | Phase 1 | `kubectl -n wiki get deploy -o yaml \| grep image:` |
| Welche Nextcloud- und MariaDB-Version auf Lightsail? | Phase 3 | `occ status`, `mysql --version` |
| Tatsächliche Größe des Nextcloud-Datenverzeichnisses? | Phase 0 (Plattengröße) | `du -sh` auf Lightsail |
| Wird SMB-External-Storage genutzt? | Phase 3 (Dockerfile) | `occ files_external:list` |
| Wie groß sind die DBs im AKS-Postgres? | Phase 0 (Plattengröße) | `psql -c '\l+'` |

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

Bis zum Abriss kommt der AKS mit ~155 €/Monat dazu (Knoten, IP, Prometheus in `Infra`
und der `MC_`-Gruppe). Nach dem Abriss bleiben dort die DNS-Zone `scout-tools.de`
(~0,45 €) und eine Container Registry (~4,50 €), die mit Biber überflüssig ist.
