resource "azurerm_key_vault" "core" {
  name                       = var.KEY_VAULT_NAME
  location                   = azurerm_resource_group.core.location
  resource_group_name        = azurerm_resource_group.core.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  tags                       = var.TAGS
}

# The VM reads secrets at boot via its managed identity.
resource "azurerm_role_assignment" "vm_kv_secrets_user" {
  scope                = azurerm_key_vault.core.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

# Whoever runs `terraform apply` needs write access to create the secrets below
# (rbac_authorization_enabled = true means Key Vault's own access policies don't apply).
resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.core.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Human read access, granted to an Entra ID *group* rather than to a person.
# The assignment above only covers whoever happens to run terraform: nobody
# else can look up a database password, and the access disappears along with
# that one account. Optional — leave ADMIN_GROUP_OBJECT_ID unset and only the
# deployer keeps access.
resource "azurerm_role_assignment" "admins_kv_secrets_user" {
  count                = var.ADMIN_GROUP_OBJECT_ID == null ? 0 : 1
  scope                = azurerm_key_vault.core.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.ADMIN_GROUP_OBJECT_ID
}

resource "random_password" "postgres_superuser" {
  length  = 32
  special = false
}

resource "random_password" "postgres_keycloak" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_admin" {
  length  = 24
  special = false
}

# Created ahead of the applications themselves — init-db.sql needs them during
# the cluster's first initialization, which happens long before Confluence and
# Nextcloud are deployed (see MIGRATION.md).
resource "random_password" "postgres_confluence" {
  length  = 32
  special = false
}

resource "random_password" "postgres_nextcloud" {
  length  = 32
  special = false
}

# These secrets deliberately do NOT depend on azurerm_role_assignment.vm_kv_secrets_user:
# that role assignment needs the VM's identity to exist, which would make secret
# creation depend on the VM — backwards from what we need, since the VM's boot
# script reads these secrets and so they must exist BEFORE the VM boots. See the
# explicit depends_on on azurerm_linux_virtual_machine.app in vm.tf instead.

resource "azurerm_key_vault_secret" "postgres_superuser" {
  name         = "postgres-superuser-password"
  value        = random_password.postgres_superuser.result
  key_vault_id = azurerm_key_vault.core.id
  depends_on   = [azurerm_role_assignment.deployer_kv_officer]
}

resource "azurerm_key_vault_secret" "postgres_keycloak" {
  name         = "postgres-keycloak-password"
  value        = random_password.postgres_keycloak.result
  key_vault_id = azurerm_key_vault.core.id
  depends_on   = [azurerm_role_assignment.deployer_kv_officer]
}

resource "azurerm_key_vault_secret" "keycloak_admin" {
  name         = "keycloak-admin-password"
  value        = random_password.keycloak_admin.result
  key_vault_id = azurerm_key_vault.core.id
  depends_on   = [azurerm_role_assignment.deployer_kv_officer]
}

resource "azurerm_key_vault_secret" "postgres_confluence" {
  name         = "postgres-confluence-password"
  value        = random_password.postgres_confluence.result
  key_vault_id = azurerm_key_vault.core.id
  depends_on   = [azurerm_role_assignment.deployer_kv_officer]
}

resource "azurerm_key_vault_secret" "postgres_nextcloud" {
  name         = "postgres-nextcloud-password"
  value        = random_password.postgres_nextcloud.result
  key_vault_id = azurerm_key_vault.core.id
  depends_on   = [azurerm_role_assignment.deployer_kv_officer]
}

resource "azurerm_key_vault_secret" "ubuntu_pro_token" {
  name         = "ubuntu-pro-token"
  value        = var.UBUNTU_PRO_TOKEN
  key_vault_id = azurerm_key_vault.core.id
  depends_on   = [azurerm_role_assignment.deployer_kv_officer]
}

# Not secret in the usual sense, but stored here (rather than baked into
# custom_data) so changing them is just "terraform apply" + a service
# restart on the VM — no VM replacement needed. See fetch-secrets.sh.
resource "azurerm_key_vault_secret" "domain_auth" {
  name         = "domain-auth"
  value        = var.DOMAIN_AUTH
  key_vault_id = azurerm_key_vault.core.id
  depends_on   = [azurerm_role_assignment.deployer_kv_officer]
}

resource "azurerm_key_vault_secret" "letsencrypt_email" {
  name         = "letsencrypt-email"
  value        = var.LETSENCRYPT_EMAIL
  key_vault_id = azurerm_key_vault.core.id
  depends_on   = [azurerm_role_assignment.deployer_kv_officer]
}
