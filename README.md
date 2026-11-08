# agent-platform-poc

Proof of concept of an open-source platform for **always-on, durable AI agents** on AKS:
agent-sandbox + Kata (AKS Pod Sandboxing), Envoy Gateway, CloudNativePG, Valkey,
Azure Storage, OpenTofu and Argo CD.

See [docs/design.md](docs/design.md) for the full design and decisions.

## Layout

```
infra/bootstrap/   OpenTofu, local state: state container + Key Vault key for state encryption
infra/platform/    OpenTofu, remote encrypted state: AKS, node pools, storage, Key Vault, budget, automation
gitops/            Argo CD apps (platform components)          [P1]
charts/agent/      Helm chart for one agent (brain + sandbox)  [P2]
employees/         One YAML per employee (drives OpenTofu)     [P2]
agents/            One YAML per agent (drives Argo CD)         [P2]
scripts/           Runbooks and helper scripts
docs/              Design and runbooks
```

## Tooling

Pinned with [mise](https://mise.jdx.dev): `mise install` (OpenTofu, Helm, kubectl, argocd).

## Usage

```bash
az login
cd infra/bootstrap && tofu init && tofu apply     # once
cd ../platform     && tofu init && tofu plan -out=p.tfplan && tofu apply p.tfplan
az aks get-credentials -g aks-lab -n aks-lab
```

The cluster is started 08:00 and stopped 21:00 (America/Sao_Paulo) on weekdays.
Start it manually with `az aks start -g aks-lab -n aks-lab`.
