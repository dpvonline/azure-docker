# Read-only SSH deploy key so the VM can `git clone` this repo without any
# secret living in the repo itself. Public half goes to GitHub (added once,
# outside Terraform, via `gh repo deploy-key add`); private half lives only
# in Key Vault, fetched by the VM at boot via its managed identity.

resource "tls_private_key" "deploy_key" {
  algorithm = "ED25519"
}

resource "azurerm_key_vault_secret" "deploy_key_private" {
  name         = "git-deploy-key-private"
  value        = tls_private_key.deploy_key.private_key_openssh
  key_vault_id = azurerm_key_vault.core.id
  depends_on = [
    azurerm_role_assignment.vm_kv_secrets_user,
    azurerm_role_assignment.deployer_kv_officer,
  ]
}

output "deploy_key_public" {
  value       = tls_private_key.deploy_key.public_key_openssh
  description = "Add this as a read-only Deploy Key on the GitHub repo (Settings → Deploy keys)"
}
