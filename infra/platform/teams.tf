# Microsoft Teams channel (D59/D60): one Azure Bot (F0, free) per agent whose
# file has a `channels.msteams` block. Flow:
#   1. add `channels: {msteams: {enabled: false}}` to agents/<employee>/<name>.yaml
#   2. tofu apply  -> Entra app + secret (agents vault) + Azure Bot + Teams channel
#   3. copy outputs teams_bots[...].app_id / tenant_id into the agent file,
#      set enabled: true, push
# Messaging endpoint = the agent's public host + /api/messages (ingress.tf domain).

locals {
  teams_agents = {
    for a in local.agent_specs : "${a.employee}-${a.name}" => a
    if try(a.channels.msteams, null) != null
  }
}

resource "azuread_application" "teams" {
  for_each         = local.teams_agents
  display_name     = "agent-${each.key}-teams"
  sign_in_audience = "AzureADMyOrg" # single tenant (multi-tenant bots are deprecated)
}

resource "azuread_service_principal" "teams" {
  for_each  = local.teams_agents
  client_id = azuread_application.teams[each.key].client_id
}

resource "azuread_application_password" "teams" {
  for_each       = local.teams_agents
  application_id = azuread_application.teams[each.key].id
  display_name   = "openclaw-msteams"
}

# ESO -> Secret <name>-msteams in the employee namespace (charts/agent channels.yaml).
resource "azurerm_key_vault_secret" "teams" {
  for_each     = local.teams_agents
  name         = "${each.key}-msteams"
  value        = azuread_application_password.teams[each.key].value
  key_vault_id = azurerm_key_vault.agents.id
  depends_on   = [azurerm_role_assignment.operator_kv_agents_secrets]
}

resource "azurerm_bot_service_azure_bot" "teams" {
  for_each                = local.teams_agents
  name                    = "bot-${each.key}-${random_string.suffix.result}"
  resource_group_name     = azurerm_resource_group.main.name
  location                = "global"
  sku                     = "F0"
  display_name            = "${each.value.employee} ${each.value.name}"
  microsoft_app_type      = "SingleTenant"
  microsoft_app_id        = azuread_application.teams[each.key].client_id
  microsoft_app_tenant_id = data.azurerm_client_config.current.tenant_id
  endpoint                = "https://${each.key}.${local.ingress_domain}/api/messages"
  tags                    = var.tags
}

resource "azurerm_bot_channel_ms_teams" "teams" {
  for_each            = local.teams_agents
  bot_name            = azurerm_bot_service_azure_bot.teams[each.key].name
  location            = azurerm_bot_service_azure_bot.teams[each.key].location
  resource_group_name = azurerm_resource_group.main.name
}

output "teams_bots" {
  value = {
    for k, a in local.teams_agents : k => {
      app_id    = azuread_application.teams[k].client_id
      tenant_id = data.azurerm_client_config.current.tenant_id
      bot       = azurerm_bot_service_azure_bot.teams[k].name
      endpoint  = azurerm_bot_service_azure_bot.teams[k].endpoint
    }
  }
}
