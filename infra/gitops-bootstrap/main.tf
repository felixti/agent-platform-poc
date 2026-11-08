# GitOps bootstrap: installs Argo CD and the root "app of apps" once.
# From then on Argo CD owns every in-cluster component (gitops/apps/*).
# Kept separate from infra/platform so that stack can be planned while the
# cluster is stopped.

terraform {
  required_version = ">= 1.13.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.13"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }

  backend "azurerm" {
    resource_group_name  = "tfstate"
    storage_account_name = "tfstate15184"
    container_name       = "agent-platform-poc"
    key                  = "gitops-bootstrap.tfstate"
    use_azuread_auth     = true
  }

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

variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  type    = string
  default = "aks-lab"
}

variable "cluster_name" {
  type    = string
  default = "aks-lab"
}

variable "repo_url" {
  type    = string
  default = "https://github.com/felixti/agent-platform-poc.git"
}

variable "repo_revision" {
  type    = string
  default = "main"
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

data "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  resource_group_name = var.resource_group_name
}

locals {
  kube = data.azurerm_kubernetes_cluster.main.kube_config[0]
}

provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.17.0"
  values           = [file("${path.module}/../../gitops/argocd/values.yaml")]
  wait             = true
  timeout          = 900
}

resource "helm_release" "root_app" {
  name       = "root-app"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.7"

  values = [yamlencode({
    applications = {
      root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.repo_url
          targetRevision = var.repo_revision
          path           = "gitops/apps"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]

  depends_on = [helm_release.argocd]
}
