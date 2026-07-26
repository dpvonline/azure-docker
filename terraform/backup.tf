# Azure Backup for the VM and ALL its data disks.
#
# This is the second of two backup layers and covers the *files*: Nextcloud
# user data, the Confluence home directory, and the OS disk. All disks land in
# one recovery point taken at the same instant, so a full restore is
# internally consistent without any coordination on our side. Individual files
# can be pulled back from a recovery point without restoring the whole VM.
#
# pgBackRest (see backup-storage.tf and the postgres container) remains the
# PRIMARY path for Postgres, because a disk snapshot is only crash-consistent
# — Postgres recovers from it via WAL replay, but it gives no point-in-time
# recovery and no verified backups. The Postgres disk is deliberately included
# here anyway: it is cheap, and it puts a second, independent copy in a
# different Azure service in case the pgBackRest blob container is ever lost
# or its configuration rots.
#
# Restoring both layers to the same moment: restore the disks from the
# recovery point at time T, then run a pgBackRest PITR to exactly T. Because
# pgBackRest can target any second, the two can always be aligned — see README.

resource "azurerm_recovery_services_vault" "core" {
  name                = "rsv-dpv-core"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  sku                 = "Standard"
  storage_mode_type   = "LocallyRedundant"
  tags                = var.TAGS
  # Soft delete is on by default and no longer configurable — deleted recovery
  # points stay restorable for 14 days, which also means a `terraform destroy`
  # of this vault needs those cleared out first.
}

resource "azurerm_backup_policy_vm" "daily" {
  name                = "policy-dpv-daily"
  resource_group_name = azurerm_resource_group.core.name
  recovery_vault_name = azurerm_recovery_services_vault.core.name

  # 01:00 UTC — before the 02:00 pgbackrest full backup and the Sunday 03:30
  # container update run, so a night's snapshot is never taken mid-update.
  backup {
    frequency = "Daily"
    time      = "01:00"
  }

  retention_daily {
    count = 14
  }

  retention_weekly {
    count    = 6
    weekdays = ["Sunday"]
  }

  retention_monthly {
    count    = 6
    weekdays = ["Sunday"]
    weeks    = ["First"]
  }
}

# NOTE: the VM is replaced whenever custom_data changes (cloud-init edits), and
# protection is briefly interrupted while that happens. Azure resource IDs are
# path-based, so the rebuilt VM keeps the same ID and the same name — existing
# recovery points are retained rather than orphaned.
resource "azurerm_backup_protected_vm" "app" {
  resource_group_name = azurerm_resource_group.core.name
  recovery_vault_name = azurerm_recovery_services_vault.core.name
  source_vm_id        = azurerm_linux_virtual_machine.app.id
  backup_policy_id    = azurerm_backup_policy_vm.daily.id

  # Without this the first backup can race the disk attachments and protect an
  # incomplete VM.
  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.postgres_data,
    azurerm_virtual_machine_data_disk_attachment.apps_data,
    azurerm_virtual_machine_data_disk_attachment.nextcloud_data,
  ]
}
