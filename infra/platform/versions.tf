terraform {
  required_version = ">= 1.13.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Remote state in Azure Blob, Entra ID auth (no storage keys).
  # Values come from `infra/bootstrap` outputs.
  backend "azurerm" {
    resource_group_name  = "tfstate"
    storage_account_name = "tfstate15184"
    container_name       = "agent-platform-poc"
    key                  = "platform.tfstate"
    use_azuread_auth     = true
  }

  # State and plan files are encrypted client-side with a Key Vault RSA key.
  encryption {
    key_provider "azure_vault" "state" {
      vault_uri      = "https://kv-agentpoc-tf-4a67.vault.azure.net/"
      vault_key_name = "tofu-state"
      key_length     = 32
    }
    method "aes_gcm" "state" {
      keys = key_provider.azure_vault.state
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

provider "azurerm" {
  subscription_id     = var.subscription_id
  storage_use_azuread = true
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

provider "azuread" {}

provider "azapi" {
  subscription_id = var.subscription_id
}
