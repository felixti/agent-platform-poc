output "cluster_name" {
  value = azurerm_kubernetes_cluster.main.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}

output "artifacts_storage_account" {
  value = azurerm_storage_account.artifacts.name
}

output "platform_key_vault_uri" {
  value = azurerm_key_vault.platform.vault_uri
}

output "aks_outbound_ip" {
  value = data.azurerm_public_ip.aks_outbound.ip_address
}
