# Read-only reference to the ACR already managed by the old azure-infrastructure
# repo — not recreated here. Role assignment is granted now (even though the
# Biber backend isn't deployed in this core phase yet) so no re-apply is needed
# once it is.

data "azurerm_container_registry" "biber" {
  name                = var.ACR_NAME
  resource_group_name = var.OLD_REPO_RESOURCE_GROUP
}

resource "azurerm_role_assignment" "vm_acr_pull" {
  scope                = data.azurerm_container_registry.biber.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_virtual_machine.app.identity[0].principal_id
}
