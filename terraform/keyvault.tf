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

resource "azurerm_key_vault_secret" "ubuntu_pro_token" {
  name         = "ubuntu-pro-token"
  value        = var.UBUNTU_PRO_TOKEN
  key_vault_id = azurerm_key_vault.core.id
  depends_on   = [azurerm_role_assignment.deployer_kv_officer]
}
