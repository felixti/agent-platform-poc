resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

data "azurerm_public_ip" "aks_outbound" {
  # AKS-managed outbound IP: the only public source the agents egress from.
  name                = element(split("/", tolist(azurerm_kubernetes_cluster.main.network_profile[0].load_balancer_profile[0].effective_outbound_ips)[0]), 8)
  resource_group_name = azurerm_kubernetes_cluster.main.node_resource_group
}

# Artifacts of durable agents. One private container per employee is created
# in employees.tf (later phase). No account keys: Entra ID + Workload Identity only.
resource "azurerm_storage_account" "artifacts" {
  name                            = "stagentpoc${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  access_tier                     = "Hot"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = [data.azurerm_public_ip.aks_outbound.ip_address]
  }

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

# Account-wide lifecycle rules (one policy per account, so it lives with the account).
# Chat harness PoC workspaces (uploads/outputs of conversations): deleted after 30 days.
resource "azurerm_storage_management_policy" "artifacts" {
  storage_account_id = azurerm_storage_account.artifacts.id

  rule {
    name    = "chat-workspaces-30d"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["chat-workspaces/"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 30
      }
      version {
        delete_after_days_since_creation = 7
      }
    }
  }
}
