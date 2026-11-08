data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    # Created by hand before this stack existed; keep its original tags.
    ignore_changes = [tags]
  }
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "aks-lab-aks-lab-9cee39"
  sku_tier            = "Free"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  node_os_upgrade_channel = "NodeImage"

  # Priority expander: prefer the Spot sandbox pool, fall back to on-demand.
  auto_scaler_profile {
    expander = "priority"
  }

  identity {
    type = "SystemAssigned"
  }

  # Node pools are managed explicitly (no Node Auto-Provisioning/Karpenter).
  node_provisioning_profile {
    mode = "Manual"
  }

  # System pool: only critical add-ons (CoreDNS, konnectivity, CSI, ...).
  # Platform workloads go to the "platform" pool, sandboxes to "kata".
  default_node_pool {
    name                         = "nodepool1"
    vm_size                      = "Standard_B2s"
    node_count                   = 1
    os_disk_size_gb              = 32
    os_disk_type                 = "Managed"
    os_sku                       = "Ubuntu"
    max_pods                     = 250
    only_critical_addons_enabled = true
    temporary_name_for_rotation  = "systmp"

    upgrade_settings {
      max_surge = "10%"
    }
  }

  linux_profile {
    admin_username = "azureuser"
    ssh_key {
      key_data = trimspace(file(pathexpand("~/.ssh/id_rsa.pub")))
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    # Azure CNI powered by Cilium: in-place upgrade from the azure dataplane
    # (reimages nodes). Enforces Kubernetes NetworkPolicy; no ACNS (paid) needed.
    network_data_plane = "cilium"
    network_policy     = "cilium"
    load_balancer_sku  = "standard"
    outbound_type      = "loadBalancer"
    pod_cidr           = "10.244.0.0/16"
    service_cidr       = "10.0.0.0/16"
    dns_service_ip     = "10.0.0.10"
  }

  storage_profile {
    disk_driver_enabled         = true
    file_driver_enabled         = true
    snapshot_controller_enabled = true
    blob_driver_enabled         = false
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      tags,
      # Changed out-of-band by the start/stop runbook / AKS itself.
      default_node_pool[0].upgrade_settings,
      # Manual mode already; avoid writing an explicit default_node_pools value.
      node_provisioning_profile,
    ]
  }
}
