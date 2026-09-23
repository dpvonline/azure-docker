# Three data disks, deliberately separate rather than one big one. Premium SSD
# v2 bills purely per GiB plus provisioned IOPS above the baseline, with no
# per-disk floor, and each disk gets its own 3000 IOPS / 125 MBps baseline
# included — so splitting Postgres and the application data gives roughly
# double the usable IOPS at the same storage cost.
#
# That only pays off because the VM is a Standard_B4s_v2 (6400 IOPS /
# 145 MBps). On the older B-series (B4ms: 2880 IOPS / 35 MBps) the VM caps
# below a single disk's baseline and the split would buy nothing — see
# MIGRATION.md before changing VM_SIZE.

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

# Confluence home (attachments + Lucene index), Nextcloud's application
# directory and Redis. Latency-sensitive but small, hence Premium v2 again.
resource "azurerm_managed_disk" "apps_data" {
  name                 = "disk-dpv-apps-data"
  location             = azurerm_resource_group.core.location
  resource_group_name  = azurerm_resource_group.core.name
  storage_account_type = "PremiumV2_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.APPS_DISK_SIZE_GB
  disk_iops_read_write = 3000
  disk_mbps_read_write = 125
  zone                 = "1"
  tags                 = var.TAGS
}

# Nextcloud user files (~150 GB today). Standard SSD rather than Premium: the
# access pattern is bulk file serving, where the extra cost of Premium buys
# little. Standard HDD would be cheaper still but adds seek latency that users
# notice on thumbnails and many-small-file listings.
#
# Azure disks do not grow by themselves. They CAN be expanded online without
# downtime (`az disk update --size-gb N` then `resize2fs` on the mounted
# filesystem) but never shrunk, hence the generous headroom over the current
# ~150 GB plus the fill-level alert in monitoring.tf.
resource "azurerm_managed_disk" "nextcloud_data" {
  name                 = "disk-dpv-nextcloud-data"
  location             = azurerm_resource_group.core.location
  resource_group_name  = azurerm_resource_group.core.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.NEXTCLOUD_DISK_SIZE_GB
  zone                 = "1"
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

  # cloud-init reads these at boot — they must exist beforehand, which the
  # secrets' own depends_on (see keyvault.tf / deploy-key.tf) deliberately
  # does NOT guarantee, to avoid a circular dependency on the VM itself.
  depends_on = [
    azurerm_key_vault_secret.postgres_superuser,
    azurerm_key_vault_secret.postgres_keycloak,
    azurerm_key_vault_secret.postgres_confluence,
    azurerm_key_vault_secret.postgres_nextcloud,
    azurerm_key_vault_secret.keycloak_admin,
    azurerm_key_vault_secret.ubuntu_pro_token,
    azurerm_key_vault_secret.domain_auth,
    azurerm_key_vault_secret.letsencrypt_email,
    azurerm_key_vault_secret.deploy_key_private,
  ]
}

# The LUN numbers are the contract with cloud-init, which mounts by LUN
# (/dev/disk/azure/scsi1/lun<N>) rather than by device name — do not renumber
# without changing scripts/cloud-init.yaml.tftpl to match.
resource "azurerm_virtual_machine_data_disk_attachment" "postgres_data" {
  managed_disk_id    = azurerm_managed_disk.postgres_data.id
  virtual_machine_id = azurerm_linux_virtual_machine.app.id
  lun                = 0
  caching            = "None" # Premium SSD v2 does not support host caching
}

resource "azurerm_virtual_machine_data_disk_attachment" "apps_data" {
  managed_disk_id    = azurerm_managed_disk.apps_data.id
  virtual_machine_id = azurerm_linux_virtual_machine.app.id
  lun                = 1
  caching            = "None"
}

resource "azurerm_virtual_machine_data_disk_attachment" "nextcloud_data" {
  managed_disk_id    = azurerm_managed_disk.nextcloud_data.id
  virtual_machine_id = azurerm_linux_virtual_machine.app.id
  lun                = 2
  caching            = "ReadOnly" # Standard SSD does support host caching
}
