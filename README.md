# azure-docker

Neues Infra-Repo für den DPV-Stack: eine einzelne Azure-VM mit Docker Compose statt AKS.
Ersetzt schrittweise `azure-infrastructure` (das alte Repo bleibt in Betrieb, bis dieses
hier funktioniert und der DNS-Cutover erfolgt ist).

## Status: Kern-Phase

Dieser erste Ausbau deckt bewusst nur ab: VM, Netzwerk, Key Vault, Postgres (self-hosted
im Container + pgBackRest-Backups gegen Azure Blob), Keycloak, Caddy (automatisches HTTPS).

**Noch nicht enthalten** (spätere Schritte): Confluence, Nextcloud, Redis, Biber-Backend,
Standby-VM/Failover, automatisierte DNS-Umstellung für dpvonline.de, Container-Update-
Automatisierung (nur Platzhalter-Skript unter `scripts/update-containers.sh`).

## Architektur

- **1 Azure VM** (Ubuntu 24.04 LTS, Standard_B2ms), non-spot, Docker Compose betreibt
  Caddy + Keycloak + Postgres.
- **Postgres läuft self-hosted** im Container (nicht als Azure Database for PostgreSQL) —
  der Hauptvorteil von Managed Postgres (DB übersteht VM-Verlust) greift erst mit einer
  zweiten VM, was hier explizit nicht Teil der Kern-Phase ist. Datenverzeichnis liegt auf
  einer separaten **Premium SSD v2**-Platte (schnell, persistent — nicht Azures flüchtiger
  lokaler NVMe-Speicher).
- **pgBackRest** sichert kontinuierlich (WAL-Archiving, `archive-timeout=600s` → maximal
  10 Minuten Datenverlust im Idle-Fall, bei Schreibaktivität nahezu punktgenau) plus
  täglichem Full-Backup gegen einen eigenen Azure-Blob-Storage-Container. Auth über
  Managed Identity der VM (keine Keys auf der Platte).
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
  Repo) — nur die ACR-Rolle und jetzt der DNS-Record referenzieren `Infra` per `data`-Quelle,
  nichts davon wird hier verändert oder mitverwaltet.

## Offene Punkte, die beim ersten echten Deploy zu prüfen sind

- **Datenplatten-Gerätepfad**: cloud-init probiert beim Mounten mehrere bekannte
  `/dev/disk/azure/...`-Pfade mit Retry (60s) durch und dumpt `lsblk` nach
  `/var/log/dpv-boot-warnings.log`, falls keiner davon auftaucht. Sollte das
  passieren: `lsblk` auf der VM prüfen und ggf. einen weiteren Pfad in
  `scripts/cloud-init.yaml.tftpl` ergänzen.
- **Premium SSD v2 Regionsverfügbarkeit**: `germanywestcentral` sollte PremiumV2_LRS
  unterstützen, aber das ändert sich bei Azure gelegentlich — bei Fehlern in
  `terraform plan`/`apply` ggf. auf `Premium_LRS` in `terraform/vm.tf`
  (`azurerm_managed_disk.postgres_data`) zurückfallen.
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

## Repo-Struktur

```
bootstrap/    einmaliger Storage Account fürs Terraform-Remote-State (eigenes State)
terraform/    eigentliche Infrastruktur (VM, Netzwerk, Key Vault, Postgres-Backup-Storage, ACR-Zugriff)
compose/      Docker-Compose-Definitionen + Caddyfile, laufen auf der VM
scripts/      cloud-init-Template, Secret-Fetch-Skript, pgBackRest-Config-Template, Backup-Cron
```
