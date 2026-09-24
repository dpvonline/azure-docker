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

  # MUST be an Enhanced policy ("V2"). The default Standard policy cannot
  # protect a VM that has Premium SSD v2 or Ultra data disks at all — it fails
  # with UserErrorUltraAndPremiumSSDv2DiskNotSupportedWithStandardPolicy when
  # the protected item is created (hit in a real deploy). Two of the three data
  # disks here are PremiumV2_LRS, so Standard is simply not an option.
  #
  # Note this cannot be flipped in place later: Azure does not allow changing an
  # existing policy's type, and a protected item cannot move between a Standard
  # and an Enhanced policy — both would have to be recreated.
  policy_type = "V2"

  # 01:00 UTC — before the 02:00 pgbackrest full backup and the Sunday 03:30
  # container update run, so a night's snapshot is never taken mid-update.
  backup {
    frequency = "Daily"
    time      = "01:00"
  }

  # Enhanced policies allow up to 30 days of instant-restore snapshots (Standard
  # caps at 5). These snapshots live next to the disks and are what makes a
  # same-day restore fast, but they are billed as snapshot storage — 7 days is
  # the balance between a quick restore window and paying for ~150 GB of
  # Nextcloud data several times over.
  instant_restore_retention_days = 7

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

# source_vm_id is spelled out rather than taken from
# azurerm_linux_virtual_machine.app.id, deliberately. Both give the same
# string — Azure resource IDs are path-based, so a rebuilt VM keeps its ID —
# but on a rebuild Terraform only knows the new VM's ID after apply, and a
# changing source_vm_id forces replacing this item. Replacing it means
# stopping protection *and deleting the backup data*, after which the
# soft-deleted item (14 days) blocks protecting the rebuilt VM under the same
# name. With the fixed string the item is left alone: the next backup runs
# against the new VM behind the same ID, and the old recovery points stay
# restorable. MIGRATION.md ("Umzug auf ARM64") checks this with an on-demand
# backup right after the rebuild.
resource "azurerm_backup_protected_vm" "app" {
  resource_group_name = azurerm_resource_group.core.name
  recovery_vault_name = azurerm_recovery_services_vault.core.name
  source_vm_id        = "${azurerm_resource_group.core.id}/providers/Microsoft.Compute/virtualMachines/${local.vm_name}"
  backup_policy_id    = azurerm_backup_policy_vm.daily.id

  # Without this the first backup can race the disk attachments and protect an
  # incomplete VM. The attachments depend on the VM, so this also keeps the VM
  # ahead of this item now that source_vm_id no longer implies it.
  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.postgres_data,
    azurerm_virtual_machine_data_disk_attachment.apps_data,
    azurerm_virtual_machine_data_disk_attachment.nextcloud_data,
  ]
}
