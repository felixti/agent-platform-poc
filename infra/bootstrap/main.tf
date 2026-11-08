# Bootstrap stack: creates what the platform stack needs *before* it can
# use a remote, encrypted backend:
#   - a blob container for OpenTofu state (in an existing state storage account)
#   - a Key Vault + RSA key used by OpenTofu state/plan encryption
#
# This stack intentionally uses LOCAL state (it is tiny and fully re-creatable
# via `tofu import`). Do not commit terraform.tfstate.

terraform {
  required_version = ">= 1.13.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
  subscription_id     = var.subscription_id
  storage_use_azuread = true
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "state_resource_group" {
  description = "Existing resource group holding the shared state storage account."
  type        = string
  default     = "tfstate"
}

variable "state_storage_account" {
  description = "Existing storage account used for OpenTofu state."
  type        = string
}

variable "state_container" {
  type    = string
  default = "agent-platform-poc"
}

data "azurerm_client_config" "current" {}

data "azurerm_storage_account" "state" {
  name                = var.state_storage_account
  resource_group_name = var.state_resource_group
}

resource "azurerm_storage_container" "state" {
  name                  = var.state_container
  storage_account_id    = data.azurerm_storage_account.state.id
  container_access_type = "private"
}

# Lets the operator use Entra ID auth (no account keys) for the backend.
resource "azurerm_role_assignment" "state_blob" {
  scope                = azurerm_storage_container.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

resource "azurerm_key_vault" "tofu" {
  name                       = "kv-agentpoc-tf-${random_string.suffix.result}"
  location                   = var.location
  resource_group_name        = var.state_resource_group
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
}

resource "azurerm_role_assignment" "tofu_kv_crypto" {
  scope                = azurerm_key_vault.tofu.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_key" "state" {
  name         = "tofu-state"
  key_vault_id = azurerm_key_vault.tofu.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["encrypt", "decrypt", "wrapKey", "unwrapKey"]

  depends_on = [azurerm_role_assignment.tofu_kv_crypto]
}

output "state_storage_account" {
  value = data.azurerm_storage_account.state.name
}

output "state_resource_group" {
  value = var.state_resource_group
}

output "state_container" {
  value = azurerm_storage_container.state.name
}

output "state_key_vault_uri" {
  value = azurerm_key_vault.tofu.vault_uri
}

output "state_key_name" {
  value = azurerm_key_vault_key.state.name
}
