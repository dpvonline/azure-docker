variable "SUBSCRIPTION_ID" {
  type      = string
  sensitive = true
}

variable "REGION" {
  type    = string
  default = "germanywestcentral"
}

variable "ADMIN_USERNAME" {
  type    = string
  default = "dpvadmin"
}

variable "ADMIN_SSH_PUBLIC_KEY" {
  type        = string
  description = "Public half of the SSH key used to log into the VM (e.g. contents of ~/.ssh/id_ed25519.pub)"
}

variable "ADMIN_IP_CIDRS" {
  type        = list(string)
  description = "CIDR ranges allowed to reach port 22 (SSH). Keep this tight — e.g. your home/office IP with /32."
}

# Standard_B4as_v2: 4 vCPU, 16 GiB, 6400 disk IOPS / 145 MBps, no temp disk.
# Deliberately the v2 B-series — the older B4ms caps at 2880 IOPS / 35 MBps,
# i.e. below a single Premium v2 disk's baseline, and costs more. D4as_v5 has
# identical disk limits but dedicated (non-burstable) CPU for ~26 $/month
# more; switch if the CPU-credit alert in monitoring.tf keeps firing.
variable "VM_SIZE" {
  type    = string
  default = "Standard_B4as_v2"
}

variable "POSTGRES_DISK_SIZE_GB" {
  type    = number
  default = 32
}

variable "APPS_DISK_SIZE_GB" {
  type        = number
  default     = 64
  description = "Confluence home, Nextcloud application directory, Redis"
}

variable "NEXTCLOUD_DISK_SIZE_GB" {
  type        = number
  default     = 256
  description = "Nextcloud user files — ~150 GB migrate off Lightsail, the rest is headroom (Azure disks expand online but never shrink)"
}

variable "ADMIN_GROUP_OBJECT_ID" {
  type        = string
  default     = null
  description = "Optional Entra ID group granted read access to Key Vault secrets, so looking up a database password does not depend on the one account that runs terraform. Create with: az ad group create --display-name 'DPV Infra Admins' --mail-nickname dpv-infra-admins"
}

variable "KEY_VAULT_NAME" {
  type        = string
  description = "Globally unique across Azure, 3-24 alphanumeric/hyphen characters"
}

variable "BACKUP_STORAGE_ACCOUNT_NAME" {
  type        = string
  description = "Globally unique across Azure, 3-24 lowercase letters/digits only, used for pgBackRest"
}

variable "DOMAIN_AUTH" {
  type        = string
  description = "Hostname Keycloak will be reachable under. Use a scout-tools.de subdomain for testing (see dns.tf, which manages the 'auth' record there); switch to a dpvonline.de subdomain for the eventual production cutover (manual DNS step, that zone lives outside this repo)."
}

variable "LETSENCRYPT_EMAIL" {
  type        = string
  description = "Contact address Caddy hands to Let's Encrypt"
}

variable "ALERT_EMAIL" {
  type        = string
  description = "Recipient for disk-fill and CPU-credit alerts (see monitoring.tf)"
}

variable "UBUNTU_PRO_TOKEN" {
  type        = string
  sensitive   = true
  description = "Free personal Ubuntu Pro token (ubuntu.com/pro) — attached for Livepatch + extended ESM"
}

variable "GITHUB_REPO_SSH_URL" {
  type        = string
  description = "SSH clone URL of this repo, e.g. git@github.com:org/azure-docker.git — the VM clones it at boot via the deploy key"
}

variable "OLD_REPO_RESOURCE_GROUP" {
  type        = string
  default     = "Infra"
  description = "Resource group of the existing azure-infrastructure repo, where the scout-tools.de DNS zone lives. Goes away once the production cutover moves off that test domain (see MIGRATION.md, phase 5)."
}

variable "TAGS" {
  type = map(string)
  default = {
    project    = "dpv-core"
    managed_by = "terraform"
  }
}
