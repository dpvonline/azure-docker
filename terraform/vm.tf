resource "azurerm_managed_disk" "postgres_data" {
  name                 = "disk-dpv-postgres-data"
  location             = azurerm_resource_group.core.location
  resource_group_name  = azurerm_resource_group.core.name
  storage_account_type = "PremiumV2_LRS" # fast + persistent; NOT ephemeral local/temp disk
  create_option        = "Empty"
  disk_size_gb         = var.POSTGRES_DISK_SIZE_GB
  disk_iops_read_write = 3000
  disk_mbps_read_write = 125
  zone                 = "1" # must match the VM's zone below
  tags                 = var.TAGS
}

locals {
  pgbackrest_conf = templatefile("${path.module}/../scripts/pgbackrest.conf.tftpl", {
    backup_storage_account = azurerm_storage_account.backups.name
    backup_container       = azurerm_storage_container.pgbackrest.name
  })

  cloud_init = templatefile("${path.module}/../scripts/cloud-init.yaml.tftpl", {
    admin_username      = var.ADMIN_USERNAME
    key_vault_name      = azurerm_key_vault.core.name
    domain_auth         = var.DOMAIN_AUTH
    letsencrypt_email   = var.LETSENCRYPT_EMAIL
    github_repo_ssh_url = var.GITHUB_REPO_SSH_URL
    pgbackrest_conf_b64 = base64encode(local.pgbackrest_conf)
  })
}

resource "azurerm_linux_virtual_machine" "app" {
  name                  = "vm-dpv-core"
  location              = azurerm_resource_group.core.location
  resource_group_name   = azurerm_resource_group.core.name
  size                  = var.VM_SIZE
  admin_username        = var.ADMIN_USERNAME
  network_interface_ids = [azurerm_network_interface.vm.id]
  zone                  = "1"
  tags                  = var.TAGS

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.ADMIN_USERNAME
    public_key = var.ADMIN_SSH_PUBLIC_KEY
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 48
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(local.cloud_init)
}

resource "azurerm_virtual_machine_data_disk_attachment" "postgres_data" {
  managed_disk_id    = azurerm_managed_disk.postgres_data.id
  virtual_machine_id = azurerm_linux_virtual_machine.app.id
  lun                = 0
  caching            = "None" # Premium SSD v2 does not support host caching
}
