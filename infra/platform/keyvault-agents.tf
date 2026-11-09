# Agent channel secrets (e.g. Telegram bot tokens), one secret per agent named
# "<employee>-<agent>-<channel>". Separate from the platform vault so employee
# namespaces can pull their agents' channel tokens without any path to platform
# secrets (OpenRouter key, OIDC client secrets). Read by ESO via a dedicated
# ClusterSecretStore limited to employee namespaces.
# Production: one vault (or per-secret RBAC + per-namespace identity) per employee.
resource "azurerm_key_vault" "agents" {
  name                       = "kv-agentch-${random_string.suffix.result}"
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  tags = var.tags
}

resource "azurerm_role_assignment" "operator_kv_agents_secrets" {
  scope                = azurerm_key_vault.agents.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "eso_kv_agents_secrets_user" {
  scope                = azurerm_key_vault.agents.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}

output "agents_key_vault_name" {
  value = azurerm_key_vault.agents.name
}

output "agents_key_vault_uri" {
  value = azurerm_key_vault.agents.vault_uri
}
