# Platform secrets (OpenRouter key, Telegram token, OIDC client secret, per-agent
# SSH keys). Read by External Secrets Operator via Workload Identity and only
# materialised in the gateway / platform namespaces, never in sandboxes.
resource "azurerm_key_vault" "platform" {
  name                       = "kv-agentpoc-${random_string.suffix.result}"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  tags = var.tags
}

# Operator (you) can manage secrets.
resource "azurerm_role_assignment" "operator_kv_secrets" {
  scope                = azurerm_key_vault.platform.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
