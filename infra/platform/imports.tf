# One-time adoption of resources that were created by hand (az CLI) before
# this stack existed. Safe to keep: import blocks are no-ops once in state.

locals {
  sub_id = "/subscriptions/${var.subscription_id}"
  rg_id  = "${local.sub_id}/resourceGroups/${var.resource_group_name}"
  aa_id  = "${local.rg_id}/providers/Microsoft.Automation/automationAccounts/${var.cluster_name}-automation"
  aks_id = "${local.rg_id}/providers/Microsoft.ContainerService/managedClusters/${var.cluster_name}"
  rb_id  = "${local.aa_id}/runbooks/aks-startstop"
}

import {
  to = azurerm_resource_group.main
  id = local.rg_id
}

import {
  to = azurerm_kubernetes_cluster.main
  id = local.aks_id
}

import {
  to = azurerm_consumption_budget_subscription.main
  id = "${local.sub_id}/providers/Microsoft.Consumption/budgets/my_budget"
}

import {
  to = azurerm_automation_account.main
  id = local.aa_id
}

import {
  to = azurerm_role_assignment.automation_aks
  id = "${local.aks_id}/providers/Microsoft.Authorization/roleAssignments/feeedb50-d82b-4e6b-8f12-8c960cc8771c"
}

import {
  to = azurerm_automation_runbook.startstop
  id = local.rb_id
}

import {
  for_each = local.schedules
  to       = azurerm_automation_schedule.this[each.key]
  id       = "${local.aa_id}/schedules/${each.value.name}"
}
