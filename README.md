# azure-docker

Neues Infra-Repo für den DPV-Stack: eine einzelne Azure-VM mit Docker Compose statt AKS.
Ersetzt schrittweise `azure-infrastructure` (das alte Repo bleibt in Betrieb, bis dieses
hier funktioniert und der DNS-Cutover erfolgt ist).

## Status: Kern-Phase

Dieser erste Ausbau deckt bewusst nur ab: VM, Netzwerk, Key Vault, Postgres (self-hosted
im Container + pgBackRest-Backups gegen Azure Blob), Keycloak, Caddy (automatisches HTTPS).

**Noch nicht enthalten** (spätere Schritte): Confluence, Nextcloud, Redis,
Standby-VM/Failover, automatisierte DNS-Umstellung für dpvonline.de. Das Biber-Backend
wird nicht mehr gebraucht und entfällt ersatzlos.

Wie diese Dienste von AKS bzw. AWS Lightsail hierher kommen, steht in
**[MIGRATION.md](MIGRATION.md)** — Phasen, Cutover-Fenster, Rollback pro Schritt.

Container-Updates sind seitdem automatisiert (Renovate + wöchentlicher Rollout mit
Rollback) — siehe unten.

## Architektur

- **1 Azure VM** (Ubuntu 24.04 LTS, **Standard_B4as_v2**), non-spot, Docker Compose
  betreibt Caddy + Keycloak + Postgres. Bewusst die **v2**-B-Serie: die alte
  (`B4ms`) deckelt den Plattendurchsatz bei 2.880 IOPS / 35 MB/s — unterhalb der
  Baseline einer einzigen Premium-v2-Platte — und kostet dabei mehr. `D4as_v5` hätte
  identische Plattenwerte, aber dedizierte statt burstbarer CPU für ~26 $/Monat mehr;
  der Wechsel lohnt, sobald der CPU-Credit-Alert regelmäßig auslöst.
- **Drei Datenplatten**, alle unter `/data` (nicht unter `/mnt` — dort hängt der Azure-
  Agent auf Größen mit Temp-Disk den *flüchtigen* Datenträger ein, was ein bekannter
  Weg ist, persistente Daten zu verlieren; `B4as_v2` hat gar keine Temp-Disk):

  | LUN | Mount | Typ | Größe | Inhalt |
  |---|---|---|---|---|
  | 0 | `/data/postgres` | Premium SSD v2 | 32 GiB | Postgres |
  | 1 | `/data/apps` | Premium SSD v2 | 64 GiB | Confluence-Home, Nextcloud-App, Redis |
  | 2 | `/data/nextcloud` | Standard SSD | 256 GiB | Nextcloud-Nutzerdaten |

  Getrennt statt eine große Platte, weil Premium v2 pro GiB abrechnet (kein Sockel je
  Platte) und **jede** Platte ihre eigenen 3.000 IOPS Baseline mitbringt — die
  Aufteilung verdoppelt also die nutzbaren IOPS zum gleichen Speicherpreis. Die
  LUN-Nummern sind der Vertrag zwischen `terraform/vm.tf` und der Mount-Logik in
  `scripts/cloud-init.yaml.tftpl`.
- **Postgres läuft self-hosted** im Container (nicht als Azure Database for PostgreSQL) —
  der Hauptvorteil von Managed Postgres (DB übersteht VM-Verlust) greift erst mit einer
  zweiten VM, was hier explizit nicht Teil der Kern-Phase ist.
- **Zwei Backup-Ebenen mit getrennten Aufgaben**: **pgBackRest** sichert Postgres
  kontinuierlich (WAL-Archiving, `archive-timeout=600s` → maximal 10 Minuten
  Datenverlust im Idle-Fall) plus täglichem Full-Backup gegen einen eigenen
  Azure-Blob-Container, Auth über Managed Identity. **Azure Backup**
  (`terraform/backup.tf`) sichert täglich die VM samt *aller* Platten in einem
  gemeinsamen, untereinander konsistenten Wiederherstellungspunkt und kann einzelne
  Dateien zurückholen. Details und der Wiederherstellungsablauf weiter unten.
- **Alerting** (`terraform/monitoring.tf`) für die zwei Fehlerfälle, die sonst
  unbemerkt bleiben: volllaufende Platte (per Azure Monitor Agent, da Azure nicht ins
  Gast-Dateisystem sieht) und aufgebrauchte CPU-Credits der B-Serie.
- **Azure Key Vault** hält alle Secrets (Postgres-Passwörter, Keycloak-Admin-Passwort,
  Ubuntu-Pro-Token, Git-Deploy-Key). Die VM zieht sie beim Boot per Managed Identity.
- **Caddy** übernimmt automatisches Let's-Encrypt-HTTPS (HTTP-01), kein separates
  cert-manager/nginx-ingress nötig.
- **Terraform-State liegt remote** in einem Azure Storage Account (`bootstrap/` legt ihn
  einmalig an, da der Storage Account nicht sein eigenes Backend sein kann).
- **DNS zum Testen**: `auth.scout-tools.de` — die Zone `scout-tools.de` gehört weiterhin dem
  alten Repo (`azure-infrastructure`, `azure/domain.tf`), dieses Repo referenziert sie nur
  per `data`-Quelle und verwaltet einen einzelnen neuen Record (`auth`, dort aktuell
  auskommentiert/nicht angelegt) über `terraform/dns.tf`. **Für den echten Cutover** liegt
  `dpvonline.de` extern (nicht Azure DNS) — der Umstieg der A/AAAA-Records auf die neue
  VM-IP bleibt dann ein manueller Schritt, nicht Teil dieses Repos.
- **Resource Group**: bewusst eine neue (`rg-dpv-core`), getrennt von `Infra` (dem alten
  Repo) — nur noch der DNS-Record referenziert `Infra` per `data`-Quelle, nichts davon
  wird hier verändert oder mitverwaltet. (Die ACR-Referenz gab es ausschließlich für das
  Biber-Backend und ist mit diesem entfallen.)

## Einmalige Umstellung auf Postgres 18 (Phase 0)

> Gilt nur für das eine `apply`, das diese Änderung ausrollt. Danach ist der Ablauf
> wieder der normale aus der Setup-Reihenfolge weiter unten.

Der Sprung von Postgres 17 auf 18 ist **kein** Image-Tausch: das Datenverzeichnis-Format
ändert sich zwischen Hauptversionen. Ein normales `terraform apply` löst das nicht mit —
die Datenplatte überlebt den VM-Neuaufbau absichtlich, also läge danach das alte
17er-Verzeichnis unter dem neuen Mount und Postgres 18 startet nicht, sondern läuft in
eine Restart-Schleife.

Das ist hier unkritisch, weil auf der VM bisher nur Wegwerf-Keycloak-Daten aus
`keycloak.dump` liegen — die echten Daten kommen erst beim Cutover (siehe
[MIGRATION.md](MIGRATION.md)). Deshalb: neu anfangen statt migrieren, kein `pg_upgrade`.

Der saubere Weg ist, die Datenplatte gleich mit ersetzen zu lassen:

```bash
terraform apply -replace=azurerm_managed_disk.postgres_data
```

Damit hängt am neuen Boot eine leere Platte, cloud-init formatiert sie (`blkid` findet
kein Dateisystem → `mkfs.ext4`), und Postgres initialisiert ein frisches Cluster — ohne
dass irgendwo von Hand gelöscht werden muss.

> ⚠️ **Kein `terraform destroy`**, auch nicht „weil eh nichts drauf ist". Der Key Vault
> hat `purge_protection_enabled = true` bei 7 Tagen Aufbewahrung. Purge Protection lässt
> sich nicht abschalten, und ein soft-deleted Vault kann vor Ablauf der Frist nicht
> gepurgt werden — der Name `dpv-core-kv01` bliebe also eine Woche blockiert und das
> anschließende `apply` würde daran scheitern. `-replace` auf die einzelne Ressource
> erreicht dasselbe ohne diesen Nebeneffekt.

Falls das `apply` doch ohne `-replace` gelaufen ist und Postgres deshalb in der
Restart-Schleife hängt, geht es auch nachträglich:

```bash
cd /opt/dpv/compose
sudo docker compose down
sudo rm -rf /data/postgres/pgdata
sudo docker compose up -d --build
```

Beim Hochfahren initialisiert Postgres ein frisches Cluster und führt dabei
`init-db.sql` aus — das legt **alle** Datenbanken an (`keycloak`, `confluence`,
`nextcloud`), auch die für noch nicht ausgerollte Anwendungen. Das ist Absicht: die
Datei wird ausschließlich bei der Erstinitialisierung eines leeren Datenverzeichnisses
gelesen, jede später fehlende Datenbank muss von Hand per `psql` nachgezogen werden.

Danach die pgBackRest-Stanza zurücksetzen. Ein frisches Cluster hat eine neue
Datenbank-System-ID, die nicht zu den Backups des alten 17er-Clusters im Blob-Repo
passt — ein einfaches `stanza-create` scheitert deshalb mit einem Mismatch:

```bash
cd /opt/dpv/compose
sudo docker compose exec --user postgres postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf stop
sudo docker compose exec --user postgres postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf stanza-delete --force
sudo docker compose exec --user postgres postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf stanza-create
sudo docker compose exec --user postgres postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf start
```

Zum Schluss `keycloak.dump` wieder einspielen und prüfen:

```bash
sudo docker compose exec --user postgres postgres psql -c '\l'   # alle drei DBs da?
sudo systemctl start dpv-update.service                          # läuft ohne Rollback durch?
```

## Offene Punkte, die beim ersten echten Deploy zu prüfen sind

- **Datenplatten-Gerätepfad**: cloud-init mountet die drei Platten über ihre LUN
  (`mount_lun 0|1|2`) und probiert dabei mehrere bekannte `/dev/disk/azure/...`-Pfade
  mit Retry (60s) durch; taucht keiner auf, landet `lsblk` in
  `/var/log/dpv-boot-warnings.log`. Sollte das passieren: `lsblk` und
  `findmnt /data/postgres /data/apps /data/nextcloud` auf der VM prüfen und ggf. einen
  weiteren Pfad in `scripts/cloud-init.yaml.tftpl` ergänzen.
- **Premium SSD v2 Regionsverfügbarkeit**: `germanywestcentral` sollte PremiumV2_LRS
  unterstützen, aber das ändert sich bei Azure gelegentlich — bei Fehlern in
  `terraform plan`/`apply` ggf. auf `Premium_LRS` in `terraform/vm.tf`
  (`azurerm_managed_disk.postgres_data`, `.apps_data`) zurückfallen.
- **Füllstands-Alert liefert nur mit passendem Zähler**: der Alert in
  `terraform/monitoring.tf` hängt am Azure Monitor Agent. Ein falscher
  `counter_specifiers`-Wert lässt `apply` durchlaufen, es kommen nur nie Daten an — und
  ein Alert, der nie auslöst, sieht aus wie einer, der nichts zu melden hat. Rund 15
  Minuten nach dem ersten Boot im Workspace `log-dpv-core` gegenprüfen:
  `Perf | where ObjectName == "Logical Disk" | summarize by InstanceName, CounterName`.
- **pgBackRest Managed-Identity-Auth aus dem Container**: `repo1-azure-key-type=auto`
  setzt voraus, dass der Postgres-Container die Azure Instance Metadata Service (IMDS,
  `169.254.169.254`) über Docker's Bridge-Netzwerk erreichen kann. Das funktioniert auf
  Azure-VMs i. d. R., sollte aber nach dem ersten Deploy mit
  `docker compose exec --user postgres postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf check`
  verifiziert werden. Falls
  nicht erreichbar: auf ein SAS-Token umstellen (`repo1-azure-key-type=sas`, Token in
  Key Vault ablegen, `pgbackrest.conf.tftpl` anpassen).
- **GitHub-Repo**: `dpvonline/azure-docker`, **public** (wie auch `azure-infrastructure`).
  Die VM klont es trotzdem über einen Deploy-Key (read-only, SSH), dessen privater
  Schlüssel in Key Vault liegt — nicht weil das Repo Secrets enthält (tut es nicht,
  alles Sensible läuft über Key Vault), sondern weil es unter `dpvonline` liegt und
  so unabhängig von persönlichen GitHub-Berechtigungen einzelner Personen bleibt.

## Repo-Absicherung (GitHub)

- **Branch protection auf `main`**: PR + mindestens 1 Review nötig, `enforce_admins`
  aktiv (gilt auch für Admins/Maintainer — niemand kann direkt pushen oder force-pushen),
  Löschen des Branches blockiert. Nicht-Mitglieder von `dpvonline` konnten ohnehin schon
  vorher nicht direkt pushen (GitHub-Standardverhalten bei public Repos ohne
  Schreibrechte) — das betrifft also v. a. bestehende Org-Mitglieder/Collaborators.
- **Secret Scanning + Push Protection** aktiviert: GitHub blockt Pushes, die wie Secrets
  aussehen, schon vor dem Landen im Repo — zusätzliches Netz, falls mal versehentlich
  eine echte `terraform.tfvars`/`backend.hcl` statt der `.example`-Version committed würde.
- **Bekannter Rest-Punkt**: die Org `dpvonline` hat aktuell `default_repository_permission:
  admin` gesetzt — alle 10 Org-Mitglieder haben dadurch Admin-Rechte auf dieses (und jedes
  andere) Repo, inkl. Settings/Deploy-Keys/Secrets und der Möglichkeit, Branch Protection
  selbst wieder abzuschalten. Das ist eine Org-weite Einstellung, keine Repo-spezifische —
  sie wurde hier bewusst nicht angefasst, weil sie alle Repos der Organisation betrifft.

## SSH-Zugang einrichten

`ADMIN_USERNAME` ist frei wählbar (Default `dpvadmin`) — einfach ein Linux-Benutzername für
den SSH-Login auf die VM, keine Registrierung nötig. `ADMIN_SSH_PUBLIC_KEY` ist die
öffentliche Hälfte eines SSH-Schlüsselpaars. Dediziert für diese VM erzeugen (nicht den
privaten SSH-Key wiederverwenden):
```
ssh-keygen -t ed25519 -f ~/.ssh/dpv_core_vm_ed25519 -N "" -C "dpvadmin@vm-dpv-core"
cat ~/.ssh/dpv_core_vm_ed25519.pub   # das kommt in ADMIN_SSH_PUBLIC_KEY
```
Der private Schlüssel (`~/.ssh/dpv_core_vm_ed25519`, ohne `.pub`) bleibt lokal und wird
später für `ssh -i ~/.ssh/dpv_core_vm_ed25519 dpvadmin@<vm_public_ip>` gebraucht — nirgends
committen.

## Setup-Reihenfolge

1. **Bootstrap** (einmalig, legt den Storage Account fürs Terraform-State an):
   ```
   cd bootstrap
   cp terraform.tfvars.example terraform.tfvars   # ausfüllen
   az login
   terraform init
   terraform apply
   ```
   Die Ausgabe (`storage_account_name`) wird für Schritt 2 gebraucht.

2. **Hauptkonfiguration** — in zwei Schritten, damit der Deploy-Key auf GitHub liegt,
   *bevor* die VM zum ersten Mal bootet und versucht, das Repo zu klonen:
   ```
   cd ../terraform
   cp backend.hcl.example backend.hcl   # storage_account_name aus Schritt 1 eintragen
   cp terraform.tfvars.example terraform.tfvars   # ausfüllen (SSH-Key, Admin-IP, Domain, ...)
   terraform init -backend-config=backend.hcl

   # Schritt 2a: erst Key Vault + Deploy-Key (noch keine VM)
   terraform apply -target=azurerm_key_vault.core -target=tls_private_key.deploy_key -target=azurerm_key_vault_secret.deploy_key_private
   gh repo deploy-key add <(terraform output -raw deploy_key_public) --title "vm-dpv-core" -R dpvonline/azure-docker

   # Schritt 2b: jetzt der Rest, inkl. VM — Deploy-Key ist bereits hinterlegt
   terraform apply
   ```
   Änderungen an `cloud-init.yaml.tftpl` (oder an sonst was, das in `custom_data`
   einfließt) erzwingen bei jedem künftigen `apply` einen VM-Replace — Terraform
   kann `custom_data` auf einer laufenden VM nicht aktualisieren, nur neu erstellen.
   Erwartet und unkritisch, solange noch keine echten Daten auf der Platte liegen.

   `DOMAIN_AUTH`/`LETSENCRYPT_EMAIL` sind davon **nicht** betroffen — die liegen
   bewusst in Key Vault statt in `custom_data`. Eine Domain-Änderung braucht also
   nur `terraform apply` (aktualisiert nur das Secret) und danach auf der VM
   `sudo systemctl restart dpv-compose.service` — kein VM-Neuaufbau nötig.

3. Nach dem ersten Boot der VM (cloud-init braucht ein paar Minuten):
   - `ssh <ADMIN_USERNAME>@<vm_public_ip>`
   - `cd /opt/dpv/compose && sudo docker compose ps` prüfen, ob alle Container laufen
     (`COMPOSE_FILE` in `.env` listet alle drei Compose-Dateien, `-f`-Flags sind nicht nötig)
   - `sudo docker compose exec --user postgres postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf stanza-create`
     (einmalig, initialisiert das Backup-Repository — `--user postgres` ist hier der Container-interne
     Postgres-User, nicht mit einem Linux-User auf der VM zu verwechseln, den es nicht gibt;
     `docker exec`/`compose exec` läuft sonst als `root`, und pgBackRest verbindet sich lokal
     dann fälschlich als Rolle `root` statt `postgres`)
   - DNS für `auth.scout-tools.de` ist bereits durch `terraform/dns.tf` gesetzt (zeigt auf
     `vm_public_ip`) — sobald das propagiert ist, stellt Caddy automatisch ein
     Let's-Encrypt-Zertifikat aus. Für den späteren Produktiv-Cutover auf eine
     `dpvonline.de`-Subdomain bleibt das ein manueller DNS-Schritt (siehe oben).

4. Verifikation: `curl -I https://<DOMAIN_AUTH>` (von außen) und, da Keycloaks Port 9000
   absichtlich nicht auf den Host published ist (nur Caddy erreicht ihn intern), von der VM aus:
   `cd /opt/dpv/compose && sudo docker compose exec caddy wget -qO- http://keycloak:9000/health/ready`.

## Backup & Restore (pgBackRest)

### Konfiguration

- **Config-Datei**: `/etc/pgbackrest/pgbackrest.conf` *im Postgres-Container* (nicht auf der
  VM selbst) — gebaut aus `scripts/pgbackrest.conf.tftpl`, von Terraform mit
  Storage-Account-/Container-Namen befüllt und über `compose/postgres/Dockerfile`
  (`COPY pgbackrest.conf ...`) ins Image gebacken. Änderungen daran heißen: Terraform
  ändert die gerenderte Datei → `custom_data` ändert sich → VM-Replace beim nächsten
  `apply` (siehe oben).
- **Repository**: eigener Azure Storage Account (`BACKUP_STORAGE_ACCOUNT_NAME`,
  `terraform/backup-storage.tf`), Blob-Container `pgbackrest` — bewusst getrennt vom
  Terraform-State-Storage-Account aus `bootstrap/`.
- **Auth**: Managed Identity (`repo1-azure-key-type=auto`), keine Keys/SAS-Tokens
  irgendwo abgelegt. Die VM-Identity hat dafür die Rolle `Storage Blob Data Contributor`
  auf genau diesen Storage Account (`azurerm_role_assignment.vm_backup_blob_contributor`).
- **Kontinuierliches WAL-Archiving**: `archive_mode=on` +
  `archive_command=pgbackrest ... archive-push %p` + `archive_timeout=600`, konfiguriert
  im `command:`-Block von `compose/docker-compose.postgres.yml`. Damit ist der maximale
  Datenverlust im Idle-Fall 10 Minuten, bei aktiver Schreiblast quasi punktgenau.
- **Täglicher Full-Backup**: Cron-Job `/etc/cron.d/pgbackrest-full` (von cloud-init
  angelegt), läuft `scripts/pgbackrest-full-backup.sh` jede Nacht um 02:00 UTC, loggt nach
  `/var/log/pgbackrest-full.log`.
- **Retention**: `repo1-retention-full=7` — die letzten 7 Full-Backups (+ zugehörige WAL)
  bleiben erhalten, ältere werden automatisch von pgBackRest selbst expired.
- **Kompression**: `compress-type=zst`.
- **Einmalig nach jedem VM-Neuaufbau nötig**: `stanza-create` (siehe Setup-Reihenfolge,
  Schritt 3) — das Backup-Repository muss einmal initialisiert werden, bevor Archiving/
  Backups funktionieren. Wurde dabei auch das *Cluster* neu initialisiert (frisches
  Datenverzeichnis, z. B. beim Postgres-18-Wechsel), passt die neue Datenbank-System-ID
  nicht mehr zur bestehenden Stanza und `stanza-create` scheitert — dann vorher
  `stop` + `stanza-delete --force`, siehe den Abschnitt zur Postgres-18-Umstellung.

Alle manuellen `pgbackrest`-Aufrufe (Check, Restore, Backup) müssen im Container als
`--user postgres` laufen (`docker exec`/`compose exec` ist sonst `root`, und pgBackRest
verbindet sich lokal über die Rolle des aufrufenden OS-Users, die für `root` nicht
existiert):

```bash
# Backup-Historie ansehen (welche Full-Backups/WAL-Zeitpunkte existieren)
sudo docker exec -u postgres dpv-core-postgres-1 pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf info

# Repository-Verbindung + WAL-Archiving testen
sudo docker exec -u postgres dpv-core-postgres-1 pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf check
```

### Restore

Der Postgres-Container darf während des Restores nicht parallel laufen — Restore läuft
über einen temporären Container, der dieselben Volumes/dieselbe Config mountet:

```bash
cd /opt/dpv/compose
sudo docker compose stop postgres

# Neuester Stand:
sudo docker compose run --rm --entrypoint bash postgres -c '
  set -e
  rm -rf /var/lib/postgresql/data/pgdata/*
  gosu postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf restore
'

sudo docker compose up -d postgres
```

**Point-in-Time-Restore** (auf einen bestimmten Zeitpunkt statt den neuesten Stand):
im `restore`-Aufruf zusätzlich `--type=time --target="2026-07-12 10:00:00"` (o. ä.)
anhängen — nutzt die kontinuierlich archivierten WAL-Segmente.

Nach dem Restore: `sudo docker compose ps` prüfen, dass Postgres/Keycloak wieder sauber
hochkommen (Keycloak greift auf dieselbe DB zu und braucht ggf. einen Moment, um die
Verbindung neu aufzubauen).

**Empfehlung**: einen Restore ab und zu unabhängig davon testen, ob gerade ein Vorfall
vorliegt — ein Backup, das nie erfolgreich zurückgespielt wurde, ist nicht wirklich
verifiziert.

## Backup-Ebene 2: Azure Backup (Dateien)

pgBackRest deckt Postgres ab — und sonst nichts. Die Nutzerdateien von Nextcloud, das
Confluence-Home und die OS-Platte brauchen eine eigene Sicherung, dafür steht
`terraform/backup.tf`: ein Recovery Services Vault mit täglichem VM-Backup um 01:00 UTC
(vor dem 02:00-pgBackRest-Lauf und dem Sonntags-Update um 03:30), Aufbewahrung 14 Tage
täglich / 6 Wochen / 6 Monate.

Zwei Eigenschaften, die im Ernstfall zählen:

- **Alle Platten in einem Wiederherstellungspunkt**, zum selben Zeitpunkt aufgenommen —
  eine vollständige Rücksicherung ist damit in sich konsistent, ohne dass wir etwas
  koordinieren müssten.
- **Einzelne Dateien** lassen sich aus einem Wiederherstellungspunkt zurückholen (Azure
  hängt ihn per iSCSI ein), man muss also nicht die ganze VM zurückrollen, um eine
  gelöschte Datei zu retten.

Die Postgres-Platte ist bewusst mitgesichert, obwohl pgBackRest sie schon abdeckt: das
kostet wenig und legt eine zweite, unabhängige Kopie in einen anderen Azure-Dienst —
für den Fall, dass der pgBackRest-Blob-Container mal gelöscht wird oder seine
Konfiguration verrottet. **Primär bleibt pgBackRest**, weil ein Platten-Snapshot nur
crash-consistent ist: Postgres fährt daraus per WAL-Recovery hoch, aber Point-in-Time-
Recovery gibt es damit nicht.

### Welche Ebene wann

| Situation | Weg |
|---|---|
| VM verloren, Platte defekt | Azure Backup, alles konsistent vom Snapshot-Zeitpunkt |
| Einzelne Datei gelöscht | Azure Backup, File-Level-Recovery |
| DB zerlegt (fehlerhafte Migration, `DROP TABLE`) | pgBackRest PITR auf die Sekunde vor dem Fehler |

### Beide Ebenen auf denselben Stand bringen

Wenn Dateien *und* Datenbank zurück müssen, dürfen sie nicht auseinanderlaufen — sonst
verweisen Nextcloud-Metadaten auf nicht mehr vorhandene Dateien (oder umgekehrt), und
Shares und Versionen brechen. Der Ablauf:

1. Platten aus dem Azure-Backup-Wiederherstellungspunkt von Zeitpunkt **T** zurückholen.
2. Postgres per pgBackRest-PITR auf **genau T** setzen:
   `--type=time --target="<T>"`.

Das geht immer auf, weil pgBackRest jeden beliebigen Zeitpunkt treffen kann — eine Seite
ist zeitlich fix, die andere frei wählbar. Gleichzeitige Backups sind dafür also nicht
nötig.

Wird **nur** Postgres per PITR zurückgedreht, laufen DB und Dateien bewusst auseinander.
Bei Nextcloud fängt `occ files:scan --all` das meiste wieder ein; Confluence' Lucene-Index
lässt sich ohnehin jederzeit neu bauen.

## Zugriff auf Secrets und Datenbanken

Alle Passwörter liegen in Key Vault, nirgends sonst — auch die für Anwendungen, die noch
gar nicht ausgerollt sind (siehe [MIGRATION.md](MIGRATION.md)).

```bash
# Welche Secrets gibt es?
az keyvault secret list --vault-name dpv-core-kv01 --query "[].name" -o tsv

# Einzelnes Passwort auslesen
az keyvault secret show --vault-name dpv-core-kv01 --name postgres-superuser-password --query value -o tsv
```

Der Zugriff hängt an einer Rollenzuweisung. `Key Vault Secrets Officer` hat das Konto,
das `terraform apply` ausführt — das reicht für Terraform, heißt aber auch: niemand sonst
kommt an die Passwörter, und mit diesem einen Konto verschwindet der Zugang. Deshalb gibt
es zusätzlich die optionale Variable `ADMIN_GROUP_OBJECT_ID`: eine Entra-ID-Gruppe, die
`Key Vault Secrets User` bekommt. Personen aufzunehmen ist dann eine Gruppenmitgliedschaft
und keine Terraform-Änderung.

```bash
az ad group create --display-name "DPV Infra Admins" --mail-nickname dpv-infra-admins
# zurückgegebene id als ADMIN_GROUP_OBJECT_ID in terraform.tfvars eintragen
```

### Datenbank mit einem GUI-Client

Postgres ist an `127.0.0.1:5432` gebunden — nur auf der VM selbst erreichbar, nicht auf
der öffentlichen Schnittstelle (die NSG blockt 5432 zusätzlich). Für pgAdmin, DBeaver
oder TablePlus also ein SSH-Tunnel:

```bash
ssh -L 5432:localhost:5432 dpvadmin@<vm_public_ip>
```

Danach verbindet sich der Client lokal gegen `localhost:5432`, Benutzer `postgres`, mit
dem Passwort aus `postgres-superuser-password`. Ohne Tunnel geht es direkt auf der VM:

```bash
cd /opt/dpv/compose && sudo docker compose exec --user postgres postgres psql
```

## Automatisierte Container-Updates (Renovate)

Zwei getrennte Bausteine: **Erkennen** neuer Image-/Provider-Versionen (GitHub-seitig,
per PR) und **Ausrollen** auf der VM (wöchentlich, automatisch, mit Rollback).

### Versions-Erkennung

[Renovate](https://github.com/apps/renovate) (gehostete Mend-App) statt Dependabot,
weil es zusätzlich **Terraform-Provider-Versionen** abdeckt (`azurerm`/`random`/`tls`)
und eingebautes Auto-Merge direkt in der Config hat (kein separater GitHub-Actions-
Workflow nötig — praktisch, da unser `gh`-Token ohnehin keinen `workflow`-Scope hat).
Konfiguriert in `renovate.json`: wöchentlich sonntags, `packageRules` mit Automerge nur
für Patch/Minor — Major-Bumps (z. B. ein Sprung von `postgres:17` auf `18`) bleiben
immer manuell zu mergen, weil sowas bei Postgres kein simpler Image-Swap ist
(inkompatibles Datenverzeichnis, braucht `pg_upgrade`/Dump-Restore) und bei Keycloak
größere Migrationen mit sich bringen kann.

**Einmalig nötig** (schon erledigt): die Renovate-GitHub-App muss über
https://github.com/apps/renovate auf `dpvonline/azure-docker` installiert werden —
bewusst kein Schritt, den Terraform oder ich automatisieren, weil das eine
Drittanbieter-Berechtigung ist, die jemand mit Repo-Admin-Rechten bewusst bestätigen
sollte.

### Rollout auf der VM

`scripts/update-containers.sh`, ausgelöst wöchentlich durch den systemd-Timer
`dpv-update.timer` (Sonntag 03:30 UTC, nach dem nächtlichen 02:00-Backup-Cron;
`Persistent=true` holt einen verpassten Lauf nach, falls die VM zu dem Zeitpunkt aus
war). Ablauf:

1. Aktuellen Git-Commit merken (für einen möglichen Rollback).
2. **Vor** jeder Änderung: zusätzliches `pgbackrest`-Full-Backup als Sicherheitsnetz —
   schlägt das fehl, bricht der Lauf sofort ab, ohne irgendetwas anzufassen.
3. `git pull` (holt gemergte Renovate-PRs + sonstige `main`-Änderungen).
4. `docker compose pull && docker compose up -d --build`.
5. Health-Check-Schleife (bis zu 5 Minuten): alle Services `running`, Keycloak-Health
   (`/health/ready`), Postgres (`pg_isready`).
6. Bei Erfolg: Log-Eintrag nach `/var/log/dpv-update.log`, fertig.
7. Bei Fehlschlag (Pull/Build/Health-Check): `git reset --hard` auf den gemerkten
   Commit + `docker compose up -d --build` — Rollback auf den vorherigen Stand (alte
   Images liegen i. d. R. noch lokal im Cache, kein erneuter Pull nötig).

**Ehrliche Grenze**: das Rollback bringt den Container-Stand zurück, aber falls eine
DB-Migration (Keycloak führt bei *jeder* Versionsänderung welche aus, nicht nur bei
Major-Versionen) vor dem Fehlschlag bereits teilweise gegriffen hat, ist das nicht
automatisch mit rückgängig gemacht — dafür ist das Vor-Update-Backup da (manueller
Restore nach dem oben beschriebenen Ablauf).

Manuell antriggern (z. B. zum Testen, nicht bis Sonntag warten):
```bash
sudo systemctl start dpv-update.service
sudo tail -f /var/log/dpv-update.log
```

Die systemd-Unit-Dateien (`scripts/systemd/dpv-update.{service,timer}`) sind bewusst
**statische Dateien im Repo**, nicht in `custom_data` gerendert — künftige Änderungen an
Schedule/Logik brauchen dadurch keinen VM-Rebuild mehr, nur diese initiale Einführung
brauchte noch einen (weil `cloud-init.yaml.tftpl`s `runcmd` sich geändert hat, um die
Dateien einmalig zu kopieren).

## Repo-Struktur

```
bootstrap/    einmaliger Storage Account fürs Terraform-Remote-State (eigenes State)
terraform/    eigentliche Infrastruktur (VM, Platten, Netzwerk, Key Vault, Backup, Monitoring)
compose/      Docker-Compose-Definitionen + Caddyfile, laufen auf der VM
scripts/      cloud-init-Template, Secret-Fetch-Skript, pgBackRest-Config-Template, Backup-Cron, Update-Skript + systemd-Units
```
