# Values are supplied via `terraform init -backend-config=backend.hcl`
# (see backend.hcl.example) — kept out of this file so nothing environment-
# specific needs to be hardcoded or committed.
terraform {
  backend "azurerm" {
    container_name = "tfstate"
    key            = "core.tfstate"
  }
}
