# Platform pool: Envoy Gateway, Argo CD, CloudNativePG, Valkey, ESO, agent brains.
resource "azurerm_kubernetes_cluster_node_pool" "platform" {
  name                  = "platform"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.platform_pool_vm_size
  os_sku                = "AzureLinux"
  os_disk_size_gb       = 64
  os_disk_type          = "Ephemeral" # OS on the VM cache/temp disk: no managed-disk cost, faster IO
  node_count            = 1
  mode                  = "User"

  node_labels = {
    "agentplatform.io/pool" = "platform"
  }

  upgrade_settings {
    max_surge = "10%"
  }

  tags = var.tags

  lifecycle {
    # Reported as 0 while the cluster is stopped by the schedule.
    ignore_changes = [node_count]
  }
}

# Sandbox pool: AKS Pod Sandboxing (Kata + Cloud Hypervisor) for agent sandboxes.
# - Azure Linux + nested-virt VM size are hard requirements.
# - Tainted so only sandbox pods (which tolerate it) land here.
# - Autoscaler 0..N: when every sandbox is Suspended the node goes away.
resource "azurerm_kubernetes_cluster_node_pool" "kata" {
  name                  = "kata"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.sandbox_pool_vm_size
  os_sku                = "AzureLinux"
  workload_runtime      = "KataVmIsolation"
  os_disk_size_gb       = 64
  os_disk_type          = "Ephemeral" # OS on the VM cache/temp disk: no managed-disk cost, faster IO
  mode                  = "User"

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = var.sandbox_pool_max_count

  priority        = var.sandbox_pool_spot ? "Spot" : "Regular"
  eviction_policy = var.sandbox_pool_spot ? "Delete" : null
  spot_max_price  = var.sandbox_pool_spot ? -1 : null

  node_labels = merge(
    { "agentplatform.io/pool" = "sandbox" },
    # AKS adds this label (and a matching taint) to Spot pools itself;
    # declaring it avoids a perpetual diff.
    var.sandbox_pool_spot ? { "kubernetes.azure.com/scalesetpriority" = "spot" } : {},
  )

  node_taints = concat(
    ["agentplatform.io/sandbox=true:NoSchedule"],
    var.sandbox_pool_spot ? ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"] : [],
  )

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}

# On-demand fallback for the sandbox pool. The cluster autoscaler's priority
# expander (see gitops/platform/cluster-autoscaler-priority.yaml) tries the
# Spot pool first and only scales this one when Spot capacity is unavailable.
resource "azurerm_kubernetes_cluster_node_pool" "kata_ondemand" {
  name                  = "kataod"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.sandbox_pool_vm_size
  os_sku                = "AzureLinux"
  workload_runtime      = "KataVmIsolation"
  os_disk_size_gb       = 64
  os_disk_type          = "Ephemeral"
  mode                  = "User"

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = var.sandbox_pool_max_count

  node_labels = {
    "agentplatform.io/pool" = "sandbox"
  }

  node_taints = ["agentplatform.io/sandbox=true:NoSchedule"]

  upgrade_settings {
    max_surge = "10%"
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count]
  }
}
