# Workload identities for platform components (Entra ID, no secrets).

# External Secrets Operator: read-only access to the platform Key Vault.
resource "azurerm_user_assigned_identity" "eso" {
  name                = "id-${var.cluster_name}-external-secrets"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "eso" {
  name                      = "external-secrets"
  user_assigned_identity_id = azurerm_user_assigned_identity.eso.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:external-secrets:external-secrets-kv-reader"
}

resource "azurerm_role_assignment" "eso_kv_secrets_user" {
  scope                = azurerm_key_vault.platform.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}

output "eso_client_id" {
  value = azurerm_user_assigned_identity.eso.client_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}
