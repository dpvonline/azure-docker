resource "azurerm_storage_account" "backups" {
  name                     = var.BACKUP_STORAGE_ACCOUNT_NAME
  resource_group_name      = azurerm_resource_group.core.name
  location                 = azurerm_resource_group.core.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = var.TAGS
}

resource "azurerm_storage_container" "pgbackrest" {
  name                  = "pgbackrest"
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "vm_backup_blob_contributor" {
  scope                = azurerm_storage_account.backups.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.app.identity[0].principal_id
}
