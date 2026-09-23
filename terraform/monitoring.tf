# Alerting for failure modes that are silent until they hurt. In August all of
# them happened at once and none of them reached anyone (see MIGRATION.md), so
# each alert below is paired with the question "what if this alert itself
# cannot see anything?".
#
#  1. A full disk. A full Postgres disk stops the database, a full Nextcloud
#     disk means failed uploads, a full OS disk stops the monitoring agent
#     itself. Azure cannot see inside the guest filesystem, so this needs the
#     Azure Monitor Agent reporting a performance counter — and a dead man's
#     switch that fires when those reports stop.
#  2. Exhausted CPU credits. The B-series throttles to its baseline once the
#     burst credits run out. Platform metric, needs no agent.
#  3. Errors from our own scripts (disk not mounted, update aborted, backup
#     failed), reported to syslog and collected by the same agent.
#
# Azure Backup job failures are covered separately, in backup.tf: the vault
# raises those alerts itself, they only need routing to the action group.

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

# Only B-series VMs emit this metric. If VM_SIZE is ever switched to a
# non-burstable size (e.g. Standard_D4as_v5) this alert simply stops receiving
# data — harmless, but delete it then so it isn't mistaken for working cover.
resource "azurerm_monitor_metric_alert" "cpu_credits" {
  name                = "alert-dpv-cpu-credits"
  resource_group_name = azurerm_resource_group.core.name
  scopes              = [azurerm_linux_virtual_machine.app.id]
  description         = "B-series burst credits running low — sustained load is being throttled to baseline. Consider Standard_D4as_v5."
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

# --- Disk fill level (needs the guest agent) ---------------------------------

resource "azurerm_log_analytics_workspace" "core" {
  name                = "log-dpv-core"
  location            = azurerm_resource_group.core.location
  resource_group_name = azurerm_resource_group.core.name
  sku                 = "PerGB2018"
  # 90 rather than the 30 included days. At a few tens of MB a month the extra
  # retention costs cents, and 30 days was too short to reconstruct the
  # August incident: the data from the day the disk filled was already gone.
  retention_in_days = 90
  tags              = var.TAGS
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
    streams      = ["Microsoft-Perf", "Microsoft-Syslog"]
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

    # Errors from our own scripts, which report via `logger -p user.err -t
    # dpv-*` (boot.sh / mount-data-disks.sh, update-containers.sh,
    # pgbackrest-full-backup.sh). Only error level and above on the "user"
    # facility, so the volume stays at a handful of lines on a bad day and
    # zero otherwise.
    syslog {
      name           = "dpv-errors"
      streams        = ["Microsoft-Syslog"]
      facility_names = ["user"]
      log_levels     = ["Error", "Critical", "Alert", "Emergency"]
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
# /data/apps and /data/nextcloud arrive about three minutes after the agent
# starts. This alert can still go blind, though — if the agent itself stops,
# no rows arrive and "nothing below 20%" looks exactly like "no data". That
# happened in August, when the full OS disk stopped the agent from starting.
# The perf_heartbeat alert further down exists to catch that case.
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

# --- Errors reported by our own scripts ---------------------------------------

# Everything that failed silently in August reports here now: a data disk that
# is not mounted (boot.sh refuses to start the stack), an aborted or rolled
# back weekly update, a failed nightly pgBackRest backup (which is also how
# broken WAL archiving shows up). Split by ProcessName, so the email says which
# of the three it is.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "script_errors" {
  name                 = "alert-dpv-script-errors"
  location             = azurerm_resource_group.core.location
  resource_group_name  = azurerm_resource_group.core.name
  scopes               = [azurerm_log_analytics_workspace.core.id]
  description          = "A dpv-* script reported an error (dpv-boot: stack not started / data disk missing, dpv-update: weekly update aborted or rolled back, dpv-backup: nightly backup failed). Details: Syslog in log-dpv-core, or journalctl on the VM."
  severity             = 1
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  tags                 = var.TAGS

  criteria {
    query                   = <<-KQL
      Syslog
      | where Facility == "user" and SeverityLevel in ("err", "crit", "alert", "emerg")
      | where ProcessName startswith "dpv-"
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"

    dimension {
      name     = "ProcessName"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }
}

# --- Dead man's switch for the monitoring itself ------------------------------

# Fires when NO disk samples have arrived for an hour, i.e. when the agent or
# the pipeline behind it is broken. Without this, a dead agent silences the
# disk_space alert above, and silence is indistinguishable from "all fine".
# `summarize count()` without `by` always returns exactly one row, so an empty
# Perf table yields n == 0 rather than no result.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "perf_heartbeat" {
  name                 = "alert-dpv-monitoring-blind"
  location             = azurerm_resource_group.core.location
  resource_group_name  = azurerm_resource_group.core.name
  scopes               = [azurerm_log_analytics_workspace.core.id]
  description          = "No disk fill-level samples for an hour — the Azure Monitor Agent on vm-dpv-core is not reporting, so the disk-space alert is blind. Check the AzureMonitorLinuxAgent extension status, and free space on / (a full OS disk stops the agent)."
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
