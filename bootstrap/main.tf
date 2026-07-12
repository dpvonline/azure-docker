terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.40"
    }
  }

  # Deliberately local state: this config creates the storage account that the
  # main terraform/ config uses as its remote backend, so it can't depend on
  # that backend itself. Runs once, rarely touched again afterwards.
}

provider "azurerm" {
  features {}
  subscription_id = var.SUBSCRIPTION_ID
}

resource "azurerm_resource_group" "state" {
  name     = "rg-dpv-tfstate"
  location = var.REGION
}

resource "azurerm_storage_account" "tfstate" {
  name                     = var.STATE_STORAGE_ACCOUNT_NAME
  resource_group_name      = azurerm_resource_group.state.name
  location                 = azurerm_resource_group.state.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}
