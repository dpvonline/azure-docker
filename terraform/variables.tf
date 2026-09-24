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

# Standard_D4ps_v6: 4 vCPU (ARM64, Azure Cobalt 100), 16 GiB, 6400 disk IOPS /
# ~200 MBps, dedicated (non-burstable) CPU, no temp disk.
#
# Chosen on price: ~105 €/month list against ~120 € for the Intel
# Standard_B4s_v2 it replaced, and dedicated cores instead of burst credits on
# top. Every x86 size with 4 vCPU / 16 GiB in this region costs as much or
# more, except the AMD Standard_B4as_v2 — which needs one more "Standard Basv2
# Family vCPUs" than the quota of 3 allows, and Microsoft grants no more of it
# here. Standard_B4ps_v2 (ARM64 as well, burstable) would be ~9 € cheaper
# still. Capacity for both was verified in zone 1 on 2026-09-24.
#
# The whole stack runs on ARM64: every image in compose/ is multi-arch.
#
# Switching between ARM64 and x86 sizes is NOT a resize: the OS image differs
# per architecture (see local.vm_arm64 in vm.tf), so Terraform rebuilds the VM.
# The data disks survive that. Switching within one architecture is an
# in-place resize plus reboot. See MIGRATION.md before changing this.
variable "VM_SIZE" {
  type    = string
  default = "Standard_D4ps_v6"
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

variable "DOMAIN_WIKI" {
  type        = string
  description = "Hostname Confluence will be reachable under — used by Caddy and as Confluence's proxy name. Same pattern as DOMAIN_AUTH: a scout-tools.de subdomain for testing (dns.tf manages the 'wiki' record there), wiki.dpvonline.de at the production cutover."
}

variable "DOMAIN_CLOUD" {
  type        = string
  description = "Hostname Nextcloud will be reachable under. cloud.scout-tools.de for the test copy (dns.tf manages the 'cloud' record there), cloud.dpvonline.de at Cutover B. Switching to cloud.dpvonline.de also turns on Nextcloud's background jobs (see fetch-secrets.sh)."
}

variable "DOMAIN_OFFICE" {
  type        = string
  description = "Hostname Collabora Online will be reachable under. Same pattern as DOMAIN_CLOUD: office.scout-tools.de for testing, office.dpvonline.de at Cutover B."
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
