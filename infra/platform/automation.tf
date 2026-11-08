# Weekday start/stop of the whole AKS cluster (all node pools) to save cost.
# Free tier Automation account: 500 job-minutes/month included.

resource "azurerm_automation_account" "main" {
  name                = "${var.cluster_name}-automation"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [tags]
  }
}

# The runbook's identity may only start/stop this one cluster.
resource "azurerm_role_assignment" "automation_aks" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id

  lifecycle {
    # Imported with a lower-cased "resourcegroups" scope; same resource.
    ignore_changes = [scope]
  }
}

resource "azurerm_automation_runbook" "startstop" {
  name                    = "aks-startstop"
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  # Current Automation API model: "PowerShell" + a runtime environment.
  # (The legacy "PowerShell72" type is silently downgraded to 5.1 on update.)
  runbook_type             = "PowerShell"
  runtime_environment_name = "PowerShell-7.2"
  log_progress             = false
  log_verbose              = false
  description              = "Start/stop AKS cluster ${var.cluster_name}"
  content                  = file("${path.module}/../../scripts/aks-startstop.ps1")

  # Job schedules are managed inline: updating a runbook re-creates its job
  # schedules, so a separate azurerm_automation_job_schedule would lose its
  # parameters on every runbook change.
  dynamic "job_schedule" {
    for_each = local.schedules
    content {
      schedule_name = azurerm_automation_schedule.this[job_schedule.key].name
      parameters = {
        action = job_schedule.value.action # keys must be lower-case
      }
    }
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [tags]
  }
}

locals {
  schedules = {
    start = { name = "aks-start-weekdays", time = var.schedule_start_time, action = "Start" }
    stop  = { name = "aks-stop-weekdays", time = var.schedule_stop_time, action = "Stop" }
  }
}

resource "azurerm_automation_schedule" "this" {
  for_each = local.schedules

  name                    = each.value.name
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  frequency               = "Week"
  interval                = 1
  timezone                = var.schedule_timezone
  week_days               = var.schedule_weekdays
  # start_time only matters at creation; Azure moves it forward on every run.
  start_time = "2026-11-09T${each.value.time}:00-03:00"

  lifecycle {
    ignore_changes = [start_time]
  }
}
