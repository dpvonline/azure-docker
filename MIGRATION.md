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

Eine VM (`Standard_B4s_v2`), ein Postgres, ein Reverse Proxy (Caddy), drei Platten:

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

| | heute | danach |
|---|---|---|
| AKS-Cluster | entfällt | – |
| Lightsail | entfällt | – |
| VM `Standard_B4s_v2` | – | ~140 $/Mon |
| Platten (32 + 64 GiB Premium v2, 256 GiB Standard SSD) | – | ~26 $/Mon |
| Azure Backup | – | ~15–20 €/Mon |
| Blob (pgBackRest) | – | wenige € |

Listenpreise für Germany West Central. Beim Sponsorship-Abo gegen den tatsächlichen
Credit-Verbrauch gegenrechnen.
