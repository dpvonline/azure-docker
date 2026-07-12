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
- **DNS** für `dpvonline.de` liegt extern (nicht Azure DNS) — der Umstieg der A/AAAA-Records
  auf die neue VM-IP ist ein manueller Schritt beim Cutover, nicht Teil dieses Repos.

## Offene Punkte, die beim ersten echten Deploy zu prüfen sind

- **Premium SSD v2 Regionsverfügbarkeit**: `germanywestcentral` sollte PremiumV2_LRS
  unterstützen, aber das ändert sich bei Azure gelegentlich — bei Fehlern in
  `terraform plan`/`apply` ggf. auf `Premium_LRS` in `terraform/vm.tf`
  (`azurerm_managed_disk.postgres_data`) zurückfallen.
- **pgBackRest Managed-Identity-Auth aus dem Container**: `repo1-azure-key-type=msi`
  setzt voraus, dass der Postgres-Container die Azure Instance Metadata Service (IMDS,
  `169.254.169.254`) über Docker's Bridge-Netzwerk erreichen kann. Das funktioniert auf
  Azure-VMs i. d. R., sollte aber nach dem ersten Deploy mit
  `docker compose exec postgres pgbackrest --stanza=main check` verifiziert werden. Falls
  nicht erreichbar: auf ein SAS-Token umstellen (`repo1-azure-key-type=sas`, Token in
  Key Vault ablegen, `pgbackrest.conf.tftpl` anpassen).
- **GitHub-Repo-Sichtbarkeit**: als **privat** angelegt. Die VM klont es über einen
  Deploy-Key (read-only, SSH), dessen privater Schlüssel in Key Vault liegt — es gibt also
  keine Secrets im Repo selbst, aber der Klon-Mechanismus braucht den Deploy-Key.

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
   gh repo deploy-key add <(terraform output -raw deploy_key_public) --title "vm-dpv-core" --read-only -R philip5/azure-docker

   # Schritt 2b: jetzt der Rest, inkl. VM — Deploy-Key ist bereits hinterlegt
   terraform apply
   ```

3. Nach dem ersten Boot der VM (cloud-init braucht ein paar Minuten):
   - `ssh <ADMIN_USERNAME>@<vm_public_ip>`
   - `sudo docker compose -f /opt/dpv/compose/docker-compose.yml ... ps` prüfen, ob alle Container laufen
   - `sudo -u postgres docker compose exec postgres pgbackrest --stanza=main --config=/etc/pgbackrest/pgbackrest.conf stanza-create` (einmalig, initialisiert das Backup-Repository)
   - DNS: `auth.dpvonline.de` (oder den in `DOMAIN_AUTH` gewählten Namen) manuell auf die
     Terraform-Output-IP `vm_public_ip` zeigen lassen — danach stellt Caddy automatisch ein
     Let's-Encrypt-Zertifikat aus.

4. Verifikation: siehe Plan-Datei bzw. `curl -I https://<DOMAIN_AUTH>` und
   `curl http://localhost:9000/health/ready` (Keycloak-Health, von der VM aus).

## Repo-Struktur

```
bootstrap/    einmaliger Storage Account fürs Terraform-Remote-State (eigenes State)
terraform/    eigentliche Infrastruktur (VM, Netzwerk, Key Vault, Postgres-Backup-Storage, ACR-Zugriff)
compose/      Docker-Compose-Definitionen + Caddyfile, laufen auf der VM
scripts/      cloud-init-Template, Secret-Fetch-Skript, pgBackRest-Config-Template, Backup-Cron
```
