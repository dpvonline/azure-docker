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

variable "VM_SIZE" {
  type    = string
  default = "Standard_B2ms"
}

variable "POSTGRES_DISK_SIZE_GB" {
  type    = number
  default = 32
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
  description = "Resource group of the existing azure-infrastructure repo, where the shared ACR lives"
}

variable "ACR_NAME" {
  type    = string
  default = "biber"
}

variable "TAGS" {
  type = map(string)
  default = {
    project    = "dpv-core"
    managed_by = "terraform"
  }
}
