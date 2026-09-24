# Alerting for the two failure modes that are silent until they hurt:
#
#  1. A full disk. Postgres and the application data share a VM, and since the
#     Postgres disk is separate a full *apps* disk no longer takes the database
#     down — but a full Postgres disk still does, and a full Nextcloud disk
#     means failed uploads. Azure cannot see inside the guest filesystem, so
#     this needs the Azure Monitor Agent reporting a performance counter.
#  2. Exhausted CPU credits — only on a burstable B-series VM_SIZE. The
#     B-series throttles to its baseline once the burst credits run out;
#     sustained load from Confluence's JVM plus PHP and Collabora is exactly
#     the profile that can get there. This one is a platform metric and needs
#     no agent. Standard_D4ps_v6 has dedicated cores, so there it is not
#     created at all.

resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-dpv-ops"
  resource_group_name = azurerm_resource_group.core.name
  short_name          = "dpvops"
  tags                = var.TAGS

  email_receiver {
    name          = "ops"
    email_address = var.ALERT_EMAIL
  }
}

# --- CPU credits (platform metric, no agent) ---------------------------------

# Only B-series VMs emit this metric. On any other size the alert would never
# receive data and look like working cover without being any, hence the count.
resource "azurerm_monitor_metric_alert" "cpu_credits" {
  count = startswith(lower(var.VM_SIZE), "standard_b") ? 1 : 0

  name                = "alert-dpv-cpu-credits"
  resource_group_name = azurerm_resource_group.core.name
  scopes              = [azurerm_linux_virtual_machine.app.id]
  description         = "B-series burst credits running low — sustained load is being throttled to baseline. Consider a size with dedicated cores (e.g. Standard_D4ps_v6)."
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT1H"
  tags                = var.TAGS

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "CPU Credits Remaining"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 50
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# Was a single resource before the count above.
moved {
  from = azurerm_monitor_metric_alert.cpu_credits
  to   = azurerm_monitor_metric_alert.cpu_credits[0]
}

# --- Disk fill level (needs the guest agent) ---------------------------------

resource "azurerm_log_analytics_workspace" "core" {
  name                = "log-dpv-core"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.TAGS
}

resource "azurerm_virtual_machine_extension" "azure_monitor_agent" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.app.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  tags                       = var.TAGS
}

resource "azurerm_monitor_data_collection_rule" "vm_perf" {
  name                = "dcr-dpv-vm-perf"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  tags                = var.TAGS

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.core.id
      name                  = "la-dest"
    }
  }

  data_flow {
    streams      = ["Microsoft-Perf"]
    destinations = ["la-dest"]
  }

  data_sources {
    # Deliberately only this one counter — Log Analytics bills by ingested
    # volume, and a filesystem sample every 5 minutes costs cents per month
    # where collecting everything would not.
    performance_counter {
      name                          = "diskspace"
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 300
      counter_specifiers            = ["Logical Disk(*)\\% Free Space"]
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "vm_perf" {
  name                    = "dcra-dpv-vm-perf"
  target_resource_id      = azurerm_linux_virtual_machine.app.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.vm_perf.id
  depends_on              = [azurerm_virtual_machine_extension.azure_monitor_agent]
}

# The counter specifier above is verified: rows for /, /data/postgres,
# /data/apps and /data/nextcloud arrive a few minutes after the agent starts.
# This alert can still go blind if the agent itself stops reporting — then no
# rows arrive, and "nothing below 20%" looks exactly like "no data". A full OS
# disk is one way that happens, since the agent needs free space to start.
# disk_space_blind below catches that case.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "disk_space" {
  name                 = "alert-dpv-disk-space"
  location             = azurerm_resource_group.core.location
  resource_group_name  = azurerm_resource_group.core.name
  scopes               = [azurerm_log_analytics_workspace.core.id]
  description          = "A filesystem is over 80% full. Azure disks expand online: az disk update --size-gb N, then resize2fs on the VM."
  severity             = 2
  evaluation_frequency = "PT30M"
  window_duration      = "PT1H"
  tags                 = var.TAGS

  criteria {
    query                   = <<-KQL
      Perf
      | where ObjectName == "Logical Disk" and CounterName == "% Free Space"
      | where InstanceName == "/" or InstanceName startswith "/data"
      | summarize FreePercent = avg(CounterValue) by Computer, InstanceName
      | where FreePercent < 20
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }
}

# Dead man's switch for the alert above: fires when NO disk samples have
# arrived for an hour, i.e. when the agent or the pipeline behind it is broken.
# `summarize count()` without `by` always returns exactly one row, so an empty
# Perf table yields n == 0 rather than no result at all.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "disk_space_blind" {
  name                 = "alert-dpv-disk-space-blind"
  location             = azurerm_resource_group.core.location
  resource_group_name  = azurerm_resource_group.core.name
  scopes               = [azurerm_log_analytics_workspace.core.id]
  description          = "No disk fill-level samples for an hour — the Azure Monitor Agent on vm-dpv-core is not reporting, so the disk-space alert is blind. Check the AzureMonitorLinuxAgent extension and free space on / (a full OS disk stops the agent)."
  severity             = 2
  evaluation_frequency = "PT1H"
  window_duration      = "PT1H"
  tags                 = var.TAGS

  criteria {
    query                   = <<-KQL
      Perf
      | where ObjectName == "Logical Disk" and CounterName == "% Free Space"
      | summarize n = count()
      | where n == 0
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }
}
