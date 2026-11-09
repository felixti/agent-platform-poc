# Public HTTPS ingress (P3, D52/D53): static IP for the Envoy Gateway "public"
# Gateway, hostnames under <ip-with-dashes>.sslip.io (Let's Encrypt), and an
# Entra ID app registration used by Envoy SecurityPolicy (OIDC) in front of
# every UI. Swap sslip.io for the company domain when porting.

# In the AKS node resource group: the cluster identity can already use it
# (no extra role assignment). Deleted together with the cluster.
resource "azurerm_public_ip" "ingress" {
  name                = "pip-${var.cluster_name}-ingress"
  resource_group_name = azurerm_kubernetes_cluster.main.node_resource_group
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

locals {
  ingress_domain = "${replace(azurerm_public_ip.ingress.ip_address, ".", "-")}.sslip.io"
  # One UI host per agent file (agents/<employee>/<name>.yaml) + Headlamp.
  agent_specs = [for f in fileset("${path.module}/../../agents", "*/*.yaml") : yamldecode(file("${path.module}/../../agents/${f}"))]
  ui_hosts = concat(
    ["headlamp.${local.ingress_domain}"],
    [for a in local.agent_specs : "${a.employee}-${a.name}.${local.ingress_domain}"],
  )
}

resource "azuread_application" "ingress" {
  display_name     = "agent-platform-poc-ingress"
  sign_in_audience = "AzureADMyOrg"

  web {
    redirect_uris = [for h in local.ui_hosts : "https://${h}/oauth2/callback"]
  }

  # Microsoft Graph delegated: openid, profile, email (sign-in only).
  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000"
    resource_access {
      id   = "37f7f235-527c-4136-accd-4a02d197296e" # openid
      type = "Scope"
    }
    resource_access {
      id   = "14dad69e-099b-42c9-810b-d002981feec1" # profile
      type = "Scope"
    }
    resource_access {
      id   = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0" # email
      type = "Scope"
    }
  }
}

# Only users explicitly assigned to the app can sign in.
resource "azuread_service_principal" "ingress" {
  client_id                    = azuread_application.ingress.client_id
  app_role_assignment_required = true
}

resource "azuread_app_role_assignment" "operator" {
  app_role_id         = "00000000-0000-0000-0000-000000000000" # default access
  principal_object_id = data.azurerm_client_config.current.object_id
  resource_object_id  = azuread_service_principal.ingress.object_id
}

resource "azuread_application_password" "ingress" {
  application_id = azuread_application.ingress.id
  display_name   = "envoy-gateway-oidc"
}

# Read by ESO into the ingress namespace only (platform vault).
resource "azurerm_key_vault_secret" "ingress_oidc" {
  name         = "ingress-oidc-client-secret"
  value        = azuread_application_password.ingress.value
  key_vault_id = azurerm_key_vault.platform.id
  depends_on   = [azurerm_role_assignment.operator_kv_secrets]
}

output "ingress_ip" {
  value = azurerm_public_ip.ingress.ip_address
}

output "ingress_domain" {
  value = local.ingress_domain
}

output "ingress_oidc_client_id" {
  value = azuread_application.ingress.client_id
}

output "ingress_ui_hosts" {
  value = local.ui_hosts
}
