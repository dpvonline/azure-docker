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

Eine VM (`Standard_B4as_v2`), ein Postgres, ein Reverse Proxy (Caddy), drei Platten:

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

**Testen mit echten Hostnamen, ohne DNS anzufassen.** Produktiv-Hostnamen lokal in
`/etc/hosts` auf die neue VM-IP zeigen lassen und Caddy für die Testphase auf
`tls internal` stellen (Let's Encrypt kann nicht validieren, solange öffentliches DNS
noch aufs alte System zeigt — Browser-Warnung wegklicken). Nötig, weil die Keycloak-
Realm-Daten absolute Redirect-URIs auf `*.dpvonline.de` enthalten; unter
`scout-tools.de` würden Login-Flows scheitern und man debuggt ein Problem, das es in
Produktion nicht gibt.

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
   bekannter Fallstrick. `Standard_B4as_v2` hat gar keine Temp-Disk mehr, und
   `/data/...` passt zu dem, was `nextcloud-config` schon verwendet.

5. **`VM_SIZE` → `Standard_B4as_v2`** (4 vCPU, 16 GiB, 6.400 IOPS, 145 MB/s, ~126 $/Mon).
   Gegenüber `B4ms` (2.880 IOPS, 35 MB/s, ~140 $) mehr als doppelte Disk-Leistung bei
   geringerem Preis; gegenüber `D4as_v5` (~152 $) identische Disk-Limits, aber
   burstable CPU statt dedizierter.

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

**Ziel:** Confluence läuft auf der neuen VM mit einer Kopie der Produktivdaten,
erreichbar über `/etc/hosts`. DNS unverändert, keine Nutzer betroffen.

Confluence zuerst, weil es die aufwendigste App ist (JVM-Tuning, Atlassian-Image,
Lizenzschlüssel) und weil danach der Weg für Cutover A frei ist — und damit für den
Abriss von AKS, dem teuersten Posten.

### Schritte

1. `compose/docker-compose.confluence.yml`, Home-Verzeichnis auf `/data/apps/confluence`.
   Umgebungsvariablen aus dem alten [confluence.tf](../azure-infrastructure/kubernetes/confluence.tf)
   übernehmen: `ATL_JDBC_*`, `ATL_PROXY_NAME`, `ATL_TOMCAT_SCHEME/SECURE`,
   `JVM_MINIMUM_MEMORY=1024m`, `JVM_MAXIMUM_MEMORY=3072m`.
2. `CONFLUENCE_LICENSE` als Key-Vault-Secret, `fetch-secrets.sh` und `COMPOSE_FILE`
   erweitern.
3. Caddy-Route für `wiki.dpvonline.de`, vorerst mit `tls internal`.
4. `pg_dump` der `confluence`-DB aus dem AKS-Postgres → Restore in die neue Instanz.
5. Confluence-Home (Anhänge) aus dem AKS-PVC (20 GiB) auf Platte 2 kopieren.
6. **Exakt dieselbe Confluence-Version wie auf AKS** verwenden. Ein Versionssprung
   gehört nicht in eine Migration.

### Verifikation

Login über Keycloak-SSO, Seiten und Anhänge sichtbar, Volltextsuche nach
Index-Neuaufbau, Berechtigungen stichprobenartig gegen das alte System vergleichen.

### Rollback

Container stoppen. Das alte System läuft unverändert weiter.

---

## Phase 2 — Cutover A: Keycloak + Confluence live

**Ziel:** `auth.` und `wiki.dpvonline.de` zeigen auf die neue VM. **Wartungsfenster,
Nutzer betroffen.**

### Vorbereitung (Tage vorher)

- TTL der betroffenen Records bei eurem externen DNS-Anbieter herunterdrehen
- Wartungsfenster ankündigen — währenddessen scheitern auch **neue Nextcloud-Logins**,
  weil Keycloak kurz weg ist (bestehende Sessions laufen weiter)
- Ablauf einmal trocken durchgehen, inklusive Rollback

### Schritte

1. AKS-Deployments für Keycloak und Confluence auf 0 skalieren (Schreibstopp).
2. Finale Dumps beider Datenbanken.
3. Restore in die neue Postgres-Instanz.
4. Confluence-Home-Delta nachziehen.
5. `domain-auth`-Secret auf `auth.dpvonline.de` ändern, Caddy-Routen auf echtes
   Let's Encrypt umstellen (`tls internal` entfernen). Laut
   [fetch-secrets.sh](scripts/fetch-secrets.sh) genügt dafür `terraform apply` plus
   `systemctl restart dpv-compose.service` — kein VM-Neubau.
6. A/AAAA-Records für `auth.` und `wiki.` auf die neue VM-IP.

> **Client-Secrets in diesem Fenster nicht rotieren.** Das noch auf Lightsail laufende
> Nextcloud authentifiziert gegen diese Keycloak-Instanz. Rotation erst in Phase 5.

### Verifikation

SSO-Login von einem Gerät ohne bestehende Session, Confluence-Zugriff über SSO,
Zertifikate ausgestellt, Nextcloud auf Lightsail kann sich weiterhin anmelden.

### Rollback

DNS-Records zurück auf die alte IP, AKS-Deployments wieder hochskalieren. Deshalb die
niedrige TTL.

### Danach

Nach einer unauffälligen Woche: **AKS abreißen.** Das ist die große Einsparung. Im alten
Repo die migrierten Ressourcen aus dem State entfernen; die DNS-Zone `scout-tools.de`
bleibt vorerst.

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
| VM `Standard_B4as_v2` | – | ~126 $/Mon |
| Platten (32 + 64 GiB Premium v2, 256 GiB Standard SSD) | – | ~26 $/Mon |
| Azure Backup | – | ~15–20 €/Mon |
| Blob (pgBackRest) | – | wenige € |

Listenpreise für Germany West Central. Beim Sponsorship-Abo gegen den tatsächlichen
Credit-Verbrauch gegenrechnen.
