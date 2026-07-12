output "vm_public_ip" {
  value = azurerm_public_ip.vm.ip_address
}

output "vm_managed_identity_principal_id" {
  value = azurerm_linux_virtual_machine.app.identity[0].principal_id
}

output "key_vault_name" {
  value = azurerm_key_vault.core.name
}

output "backup_storage_account_name" {
  value = azurerm_storage_account.backups.name
}

output "acr_login_server" {
  value = data.azurerm_container_registry.biber.login_server
}
