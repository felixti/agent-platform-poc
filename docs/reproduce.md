# Agent Platform PoC — Decision Log and End-to-End Reproduction Guide

This document records **every decision** taken while building the PoC (what was
considered, what was chosen, why) and gives an **ordered, from-scratch procedure**
to rebuild it in another Azure subscription or in the company.

- Design summary: [`design.md`](design.md)
- Day-to-day operations: [`playbook.md`](playbook.md) / [`playbook.pt-br.md`](playbook.pt-br.md)
- Topology diagram: [`topology.html`](topology.html)

Time to reproduce from zero: **≈3–4 hours** of hands-on work (mostly waiting for AKS
operations), assuming the fixes in §5 are already in the code (they are).

---

## Contents

1. [Context and goal](#1-context-and-goal)
2. [Decision log](#2-decision-log)
3. [Prerequisites](#3-prerequisites)
4. [Reproduction procedure](#4-reproduction-procedure)
5. [Problems hit and how they were fixed](#5-problems-hit-and-how-they-were-fixed)
6. [Verification checklist](#6-verification-checklist)
7. [Costs](#7-costs)
8. [Teardown](#8-teardown)
9. [Open items](#9-open-items)

---

## 1. Context and goal

The company wants a **custom, always-on, durable AI agent** per employee, in the
style of xAI Grok Bot, OpenAI dots, Anthropic Claude Duet, Hermes Agent and
OpenClaw. The PoC must prove the **platform**, using an off-the-shelf agent
(OpenClaw) as a stand-in until the custom agent exists.

Hard constraints given at the start:

| Constraint | Value |
|---|---|
| Orchestrator | Kubernetes on **AKS** |
| Gateway | **Envoy Gateway** (ingress and egress control) |
| Persistence | Azure Storage Account (artifacts), **PostgreSQL**, **Redis-compatible** cache, Azure Disk **PVCs** |
| Licensing | **Open source only**, no commercial / source-available licenses |
| Maturity | Battle-tested |
| Security | High isolation, network policy, ingress/egress control |

Candidate stacks supplied for evaluation:

1. kubernetes-sigs/agent-sandbox + Kata Containers + Cloud Hypervisor or Firecracker
2. google/ax
3. agent-substrate/substrate + Kubernetes + gVisor

---

## 2. Decision log

Each row: the question, the options weighed, the decision, and the reason.
"Research" means it was settled by evidence (GitHub API, vendor docs, upstream
source), not by preference.

### 2.1 Requirements

| # | Question | Options | Decision | Why |
|---|---|---|---|---|
| D1 | Threat model | (a) hostile: LLM-generated code + internet content, many users · (b) one trusted team · (c) fixed tools only | **(a) hostile** | Always-on agents run shell and browse; any agent can be prompt-injected. Each agent gets its own isolation boundary. |
| D2 | Agent shape | (a) split: trusted brain outside, tools in sandboxes · (b) whole agent in one sandbox | **Hybrid: brain outside, persistent "computer" inside** | Research (D2-R) showed every production always-on agent separates brain/credentials from the computer. |
| D3 | Durability | (a) survive restarts · (b) + hibernate idle agents · (c) + exactly-once workflow steps | **(b)** | "Always-on but cheap". Workflow engines deferred. |
| D4 | Maturity bar | (a) strict GA/CNCF only · (b) mixed: security layers proven, orchestration layer may be beta | **(b)** | Agent-specific orchestration is months old everywhere; isolation runtime, CNI, gateway and DB must be proven. |
| D5 | Postgres/Redis | (a) in-cluster OSS · (b) Azure managed | **(a) CloudNativePG + Valkey** | Cost, and Redis 8 is RSAL/SSPL/AGPL; Valkey is BSD-3. |
| D6 | PoC cost ceiling | — | **Temporary sandbox pool, budget R$450/month** | Kata needs nested-virt VM sizes (B-series cannot). |

**D2-R (research):** xAI Grok Bot keeps OAuth tokens off the per-user computer;
Anthropic Managed Agents / Claude Duet document a stateless "brain" harness, an
append-only session log, credentials injected by a proxy and separate sandboxes
("hands"); OpenAI dots gives each dot its own computer but publishes little;
OpenClaw and Hermes run their gateway on the host with sandboxed tool backends.

### 2.2 Stack selection

| # | Question | Decision | Evidence / reason |
|---|---|---|---|
| D7 | google/ax | **Rejected as a sandbox** | It is an alpha (`ax.io/v1alpha1`) agent *orchestrator* that requires Substrate for isolation. |
| D8 | Substrate (+gVisor) | **Rejected for now, re-evaluate ~Feb 2027** | v1.0.0 shipped 2026-11-05; GKE assumptions (issues #2589, #2669); no PVCs; object store only `gs://`/`s3://` (Azure Blob plugin had no release); own network stack overlapping Envoy Gateway. Strongest alternative: real memory snapshots, <500 ms resume. |
| D9 | Firecracker | **Rejected** | Not in Kata's AKS CI; needs devmapper, no virtio-fs; unsupported on AKS. |
| D10 | gVisor on AKS | **Rejected** | Not supported by Microsoft; privileged node mutation; fragile across node-image upgrades. |
| D11 | **Final stack** | **agent-sandbox v1.0.10 + AKS Pod Sandboxing (Kata + Cloud Hypervisor on Hyper-V)** | Pod Sandboxing GA since Nov 2025, Microsoft-supported; agent-sandbox (SIG Apps, Apache-2.0) gives `Sandbox` CRD, PVC templates, `Suspended` mode; an OpenClaw-on-Kata-AKS example exists upstream. |
| D12 | Other OSS options seen | OpenSandbox (AAIF, RC), KubeVirt (CNCF, heavy), E2B (single-node self-host), Daytona (AGPL, archived) | Recorded as alternatives only. |

### 2.3 Platform design

| # | Question | Decision | Why |
|---|---|---|---|
| D13 | Egress control | **Azure CNI powered by Cilium (free, no ACNS) + default-deny NetworkPolicy + Envoy as the only exit** | Envoy Gateway has no transparent egress; ACNS FQDN policies are paid. |
| D14 | LLM credentials | **Injected by Envoy**, never in brain or sandbox | Prompt injection cannot leak what is not there. |
| D15 | Ingress | HTTPS + Entra ID OIDC via Envoy Gateway (**P3, not built yet**); PoC uses `kubectl port-forward` | — |
| D16 | Storage access | Workload Identity, per-employee container (**not built yet**) | No long-lived keys. |
| D17 | PoC agent | **OpenClaw**, with a **custom OpenAI-compatible provider** | Upstream AKS example; the company will use an internal OpenAI-compatible LLM gateway. |
| D18 | LLM provider (PoC) | **OpenRouter**, public, API key with credit limit; model `meta/muse-spark-1.3-contributor` | Stand-in for the company gateway. "contributor" models train on prompts: the OpenRouter account had to allow it. |
| D19 | TLS / DNS | sslip.io + Let's Encrypt (**P3**) | No corporate DNS needed in a personal subscription. |
| D20 | Channel | Telegram (**P3**) | Proves webhook → wake → reply. |
| D21 | IaC | **OpenTofu** (MPL-2.0) | Terraform is BSL 1.1 (source-available); Bicep is Azure-only and its Kubernetes extension is preview; Pulumi is a valid alternative. |
| D22 | GitOps | **Argo CD via Helm**, installed by OpenTofu; Argo owns everything in-cluster | CNCF Graduated, UI, ApplicationSets; portable. |
| D23 | Observability | Envoy access logs + pod logs; no Azure Monitor | Cost. |
| D24 | Brain durability | Off-the-shelf brains: StatefulSet + PVC. **Custom brain: stateless + Postgres event log** | OpenClaw keeps its own SQLite state; the custom agent follows the Anthropic `wake(sessionId)` pattern. |
| D25 | Admission policy | **ValidatingAdmissionPolicy** (native) | Blocks `io.katacontainers.*` annotations (2026 Kata CVEs), hostPath, host namespaces, privileged, non-Kata sandboxes. No Kyverno footprint. |
| D26 | Hibernation | Brain sets `Sandbox.spec.operatingMode: Suspended` after 15 min idle (**P3**) | agent-sandbox has no idle controller yet. |
| D27 | PVC safety | StorageClass `reclaimPolicy: Retain` + snapshots | agent-sandbox issue #2209 can delete PVCs. |
| D28 | Secrets | **Azure Key Vault + External Secrets Operator**; store usable only by namespaces labelled `agentplatform.io/secrets-access=true` | Employee namespaces never get Key Vault access. |
| D29 | Tenancy | **Single company; isolation unit = employee**: namespace `u-<id>`, PSS restricted, default-deny, quota | A compromised agent must not reach another employee's data. |
| D30 | Brain ↔ sandbox contract | **SSH (exec + SFTP)**, key-only, keys generated in-cluster | Supported natively by OpenClaw and Hermes; trivial for a custom agent. HTTP API (sandbox-router) is the phase-2 target. |
| D31 | Images | GHCR (public) in the PoC, pinned by digest; ACR in the company | Free. |
| D32 | Provisioning | GitOps: `employees/*.yaml` and `agents/<employee>/*.yaml` → ApplicationSets; **new agent = PR** | — |
| D33 | Repository | Public GitHub repo; secrets only in Key Vault; `terraform.tfvars` gitignored | — |
| D34 | Brain kinds | One `agent` chart with `brainKind` (`openclaw` now, `hermes`, `pi-durable` later) | Platform, not a single-agent demo. |

### 2.4 Infrastructure sizing and cost

| # | Question | Decision | Why |
|---|---|---|---|
| D35 | Node sizes | **D2ds_v5 with ephemeral OS disk** (not D2s_v5) | Same price class, no managed OS disk to pay (~R$55/month saved per pool), faster IO. Nested virtualization supported. |
| D36 | Kata pool | **Spot preferred + on-demand fallback** (`kata` + `kataod`, both 0–1) with the autoscaler **priority expander** | eastus returned `SkuNotAvailable` for D2ds_v5 Spot. |
| D37 | System pool | B2s, `only_critical_addons_enabled` | Keep platform workloads off the small node. |
| D38 | Platform pool | D2ds_v5 on-demand, **autoscale 1–2** | AKS add-ons (metrics-server, CoreDNS, WI webhook) land there and reserve ~0.8 vCPU. |
| D39 | Schedule | Stop 21:00 BRT weekdays (safety net); **auto-start disabled**, start on demand | Pay only while used. |
| D40 | Budget | R$450/month; forecast 85 %, actual 50/80/100 % e-mail alerts | Alerts only (Pay-As-You-Go has no hard cap). |

### 2.5 Decisions forced during implementation

| # | Problem | Decision | Rejected alternative |
|---|---|---|---|
| D41 | OpenClaw refuses a state dir not owned by its uid or with group-writable ancestors; Azure Disk root is `root:root` | **Golden snapshot**: empty ext4 with root `1000:1000 0700`, prepared once in namespace `platform-storage`; brain PVCs cloned from it; brain runs without `fsGroup`; employee namespaces stay PSS `restricted` | Root `chown` init container (needs PSS `baseline` in every employee namespace; blocked as a security weakening) · Azure Files SMB with uid mount options (SQLite on network FS corrupts) · user namespaces (unverified on AKS) |
| D42 | agent-sandbox v1.0 creates no Service | Chart adds ClusterIP Service `<agent>-computer:2222` | — |
| D43 | OpenClaw treats overwritten config as clobbered | Seed `openclaw.json` once (upstream k8s recipe); sticky `/tmp` | Re-copying config on every start |
| D44 | LLM gateway shape | Internal endpoint `http://llm-gateway.envoy-gateway-system.svc/api/v1`; Envoy `Backend` (FQDN, TLS) + `HTTPRouteFilter.credentialInjection` + local rate limit 120 req/min | Forward proxy with `HTTPS_PROXY` (not needed for LLM calls) |
| D45 | Sandbox internet access | **Per-agent Envoy egress proxy** (`<agent>-egress`, runc, platform pool): dynamic forward proxy for HTTP CONNECT + plain HTTP, `route_config` host allowlist from `agents/*.yaml` `egress.allow` (`host` and `host:443`), default vhost 403, stdout access log. Computer egress NetworkPolicy → its proxy only; proxy egress → `0.0.0.0/0` on 80/443 **except** RFC1918, CGNAT, link-local (IMDS) and `168.63.129.16` | AKS ACNS FQDN policies (paid add-on, ~US$0.025/node-h) · Squid (extra component) · proxy as sidecar (shares the pod network, agent could bypass) · Envoy Gateway `DynamicResolver` Backend (no documented host restriction) |
| D46 | Proxy for SSH sessions | Entrypoint appends `SetEnv HTTP(S)_PROXY/NO_PROXY` to a runtime copy of `sshd_config` (sessions do not inherit container env) | `/etc/environment` (needs PAM) |
| D47 | Browser for the agent | Headless Chromium **inside the Kata computer** (`--no-sandbox`: the microVM is the boundary), proxied via `--proxy-server`; OpenClaw `browser` profile `computer` = remote CDP `http://<agent>-computer:9222`, `attachOnly` | OpenClaw sandbox browser (Docker-only) · Chromium in the brain pod (runc, outside the VM) |
| D48 | Chromium DevTools only answers `Host: localhost/IP` and advertises `ws://` from that Host | `cdp-relay.py` in the image: listens `0.0.0.0:9222`, rewrites `Host` to `127.0.0.1:9223`, rewrites advertised `ws://` back to the client's host, pipes WebSockets. NetworkPolicy: brain-only | Fixed ClusterIP per agent · `--remote-debugging-address=0.0.0.0` (Host check still applies) |
| D49 | OpenClaw strict SSRF policy blocks private CDP endpoints and hostname navigation | Keep strict; `browser.ssrfPolicy.allowedHostnames` = computer host + `egress.allow` (same list enforced twice: OpenClaw and proxy). Browser tool enabled with `tools.alsoAllow` and `tools.sandbox.tools.alsoAllow` (`coding` profile and sandbox defaults exclude it) | `dangerouslyAllowPrivateNetwork: true` · `tools.profile: full` |
| D50 | Config seeded once (D43) would freeze browser/allowlist settings | Init container re-applies **platform-owned keys** (`browser`, `agents.defaults.sandbox.browser`, `tools.alsoAllow`, `tools.sandbox.tools.alsoAllow`) with `openclaw config set --batch-file` on every start | Reseeding the whole file |
| D51 | Ops UI | **Headlamp** 0.46.0 (kubernetes-sigs, Apache-2.0) via Argo CD, port-forward + short-lived SA token; custom portal deferred until employee-facing needs are known (it should write to git, not the API) | Kubernetes Dashboard (archived) · Backstage (heavy) · custom portal now |
| D52 | P3 public HTTPS hostname | `<ingress-ip>.sslip.io` + Let's Encrypt (cert-manager HTTP-01 via Envoy Gateway); static public IP (~R$20/month). Swap for the company domain when porting | Own domain now · self-signed |
| D53 | P3 authentication | Entra ID OIDC on Envoy Gateway `SecurityPolicy` in front of the OpenClaw UI and Headlamp (app registration in the subscription tenant); OpenClaw gateway token stays as a second factor | Port-forward only · OpenClaw token only |
| D54 | Telegram transport | **Long polling**; brain reaches only `api.telegram.org` through a dedicated **brain listener (:3129)** on the agent's egress proxy (platform-derived allowlist, separate from the computer's :3128 list); OpenClaw `channels.telegram.proxy`; `dmPolicy: pairing` | Webhook (needs public route; outbound to the Bot API is needed anyway) · giving the brain the computer's allowlist |
| D55 | Channel token storage | Separate Key Vault **`kv-agentch-<suffix>`** (agent channel secrets only, `<employee>-<agent>-<channel>`), ClusterSecretStore `agent-channels` limited to namespaces with label `agentplatform.io/employee`; token reaches the brain only as env `TELEGRAM_BOT_TOKEN`, never in `openclaw.json` | Label employee namespaces for the platform vault (would expose the OpenRouter key path) · Secret created by hand (breaks "secrets only in Key Vault"). Production: per-employee vault or per-secret RBAC with per-namespace identity |
| D57 | Ingress shape | Envoy Gateway `public` (ns `ingress`), LoadBalancer on static IP `pip-<cluster>-ingress` created in the **AKS node RG** (cluster identity already has rights; no role assignment). Listeners: `:80` (ACME + 301 to https), `:443` `*.<domain>` with **one Let's Encrypt cert listing every UI host** (HTTP-01; sslip.io has no DNS-01). **Gateway-wide** OIDC `SecurityPolicy` (all routes behind Entra); redirect URIs generated by OpenTofu from `agents/*/*.yaml` + Headlamp; app requires assignment | Per-route SecurityPolicy (secret would have to live in employee namespaces) · PIP in the main RG (needs Network Contributor for the cluster identity) · wildcard cert (needs DNS-01 on an owned domain) |
| D58 | Agent UI exposure | Agent chart adds `HTTPRoute <employee>-<name>.<domain>` → brain :18789, NetworkPolicy allowing **only** the public Envoy pods (`owning-gateway-name=public`) to the brain, and `https://<host>` in OpenClaw `gateway.controlUi.allowedOrigins` (platform-owned key). OpenClaw token still required | Exposing the brain Service directly · disabling the OpenClaw token |
| D56 | Computer hibernation | **Schedule-based** for the PoC (CronJob sets `Sandbox.spec.operatingMode` outside working hours); idle-based wake-up deferred to the custom brain (needs a controller, brains have no API token) | Idle-based controller now |

---

## 3. Prerequisites

### 3.1 Accounts

| Item | Notes |
|---|---|
| Azure subscription | Owner role (role assignments, Entra app later). Pay-As-You-Go is fine. |
| Quota (target region) | ≥ 8 vCPU total regional; ≥ 6 vCPU in the **DDSv5** family; ≥ 2 **low-priority** vCPU (Spot). Check: `az vm list-usage -l eastus -o table`. |
| GitHub account | Repo hosting, GitHub Actions, GHCR. |
| LLM endpoint | OpenAI-compatible URL + API key (PoC: OpenRouter key with a credit limit). Check the provider's data-training/privacy settings against the chosen model. |

### 3.2 Local tools

Pinned in `mise.toml` (`mise install`):

| Tool | Version |
|---|---|
| OpenTofu | 1.13.9 |
| Helm | 4.3.1 |
| kubectl | 1.36 |
| argocd CLI | 3.6.1 |

Also: `az` CLI (with `aks-preview` not required), `gh`, `git`, `docker` (optional, local image tests), `jq`, `python3`, `openssl`, `ssh-keygen`.

```bash
az login
gh auth login && gh auth setup-git
```

---

## 4. Reproduction procedure

Follow the phases in order. Each phase lists **what to change** in the repo when
reproducing in a different subscription, the **commands**, and a **check**.

### 4.0 Fork and adjust identifiers (≈15 min)

1. Fork or copy the repo; clone it.
2. Replace environment-specific values (search with
   `grep -rnE "felixti|9cee39bb|5f9bf155|kv-agentpoc|tfstate15184|28b38d55|snapshot-0ec8|aks-lab-aks-lab-9cee39" --include=*.tf --include=*.yaml .`):

| File | Value | Set to |
|---|---|---|
| `infra/*/terraform.tfvars` (create from `.example`) | `subscription_id`, `budget_contact_emails` | yours |
| `infra/bootstrap/terraform.tfvars` | `state_storage_account` | your state storage account (§4.1) |
| `infra/platform/versions.tf`, `infra/gitops-bootstrap/main.tf` | backend `storage_account_name`, encryption `vault_uri` | from §4.1 outputs |
| `infra/platform/aks.tf` | `dns_prefix` | any unique prefix |
| `infra/gitops-bootstrap/main.tf` | `repo_url` default | your repo URL |
| `gitops/apps/*.yaml` | `repoURL` | your repo URL |
| `gitops/platform/external-secrets/secret-store.yaml` | client-id, tenant-id, `vaultUrl` | from §4.2 outputs |
| `charts/agent/values.yaml` | `stateSnapshotHandle`, `computer.image` | from §4.5 and §4.3 |

3. Greenfield only: **delete `infra/platform/imports.tf`.** It adopted resources that were
   first created by hand in the original subscription; `import` fails when they don't exist.

### 4.1 State backend and encryption key (≈10 min)

1. Create a resource group and storage account for state (once per subscription):
   ```bash
   az group create -n tfstate -l eastus
   az storage account create -g tfstate -n <unique-name> --sku Standard_LRS \
     --min-tls-version TLS1_2 --allow-blob-public-access false
   ```
2. Apply the bootstrap stack (local state):
   ```bash
   cd infra/bootstrap
   tofu init && tofu plan -out=b.tfplan && tofu apply b.tfplan
   tofu output
   ```
   It creates: state container, `Storage Blob Data Contributor` for you, Key Vault
   `kv-agentpoc-tf-xxxx` (RBAC, purge protection) and RSA key `tofu-state`.
3. Copy `state_key_vault_uri` and the storage account name into `infra/platform/versions.tf`
   and `infra/gitops-bootstrap/main.tf`.

**Check:** `tofu output` shows the vault URI. Cost ≈ R$0.

### 4.2 Platform stack: AKS, pools, identities, budget (≈30–40 min)

```bash
cd infra/platform
tofu init
tofu plan -out=p.tfplan     # review: cluster, 3 user pools, storage, 2 identities, budget, automation
tofu apply p.tfplan
tofu output                 # eso_client_id, tenant_id, platform_key_vault_uri, oidc_issuer_url
```

What it creates (greenfield):

- **AKS:** Free tier; Azure CNI overlay **with the Cilium dataplane and Cilium network policy**; OIDC issuer + Workload Identity; priority expander.
- **System pool:** B2s, critical add-ons only.
- **Pools:** `platform` (D2ds_v5, 1–2), `kata` (D2ds_v5 Spot, KataVmIsolation, 0–1, tainted), `kataod` (on-demand fallback, 0–1).
- **Platform Key Vault** with the `Key Vault Secrets Officer` role for you.
- **Artifacts storage account:** keyless, network-restricted to the AKS egress IP.
- **ESO managed identity:** federated credential, `Key Vault Secrets User`.
- **Budget**, plus an Automation account with the PowerShell 7.2 start/stop runbook and weekday schedules (auto-start off, stop on).

Then:

1. Put `eso_client_id`, `tenant_id` and the platform vault URI into
   `gitops/platform/external-secrets/secret-store.yaml`.
2. Get credentials: `az aks get-credentials -g <rg> -n <cluster> --overwrite-existing`.
3. Apply the autoscaler priority expander ConfigMap once (Argo also manages it later):
   `kubectl apply -f gitops/platform/base/cluster-autoscaler-priority.yaml`.

**Check:**
- `az aks show ... --query networkProfile` shows `networkDataplane: cilium` and `networkPolicy: cilium`.
- `kubectl get runtimeclass` lists `kata-vm-isolation`.
- Kata smoke test from §6 item 1 passes.

### 4.3 Sandbox image (≈5 min)

1. Push the repo; GitHub Actions (`.github/workflows/images.yml`) builds
   `ghcr.io/<owner>/agent-sandbox-ssh` from `images/sandbox-ssh/`.
2. Make the GHCR package **public** (GitHub → Packages → settings) or add an `imagePullSecret`.
3. Get the digest and pin it in `charts/agent/values.yaml` (`computer.image`):
   ```bash
   T=$(curl -s "https://ghcr.io/token?scope=repository:<owner>/agent-sandbox-ssh:pull" | jq -r .token)
   curl -sI -H "Authorization: Bearer $T" \
     -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json" \
     https://ghcr.io/v2/<owner>/agent-sandbox-ssh/manifests/latest | grep -i docker-content-digest
   ```

The image is `node:22-bookworm-slim` with non-root `sshd` on port 2222 (uid 1000,
key-only, no forwarding), `tini` as PID 1, `python3` and GNU coreutils for the OpenClaw
SSH backend contract, headless Chromium + `cdp-relay.py` on :9222 (D47–D48), and a CLI
toolbox: git, gh, ripgrep, fd, jq, yq, curl, wget, Node 22 + npm, uv, build-essential, unzip.
Test it locally before pushing (`docker build`, then `curl -H 'Host: x:9222' localhost:<port>/json/version`).

### 4.4 Secrets in Key Vault (≈2 min)

Never paste secret values into chats or git. Read them from a prompt:

```bash
KV=<platform-vault-name>
az keyvault secret set --vault-name $KV -n valkey-default-password \
  --value "$(openssl rand -base64 32 | tr -d '/+=')" -o none
read -rsp "LLM API key: " K && az keyvault secret set --vault-name $KV -n openrouter-api-key --value "$K" -o none; unset K
```

### 4.5 GitOps bootstrap and platform components (≈15 min)

```bash
git push                          # Argo CD pulls from the repo
cd infra/gitops-bootstrap
tofu init && tofu plan -out=g.tfplan && tofu apply g.tfplan
kubectl -n argocd get applications -w
```

Argo CD then syncs, by sync wave:

| Wave | App | Content |
|---|---|---|
| -10 | `platform-base` | namespaces, StorageClass `agent-disk` (Retain), VolumeSnapshotClass, priority expander, ValidatingAdmissionPolicies |
| -5 | `envoy-gateway` | v1.10.0, Backend API enabled |
| 0 | `cert-manager`, `external-secrets`, `cloudnative-pg`, `agent-sandbox` | operators |
| 10 | `external-secrets-config`, `postgres`, `valkey-secrets` | ClusterSecretStore, CNPG cluster, Valkey password |
| 20 | `valkey`, `llm-gateway` | Valkey 9 with ACL; internal LLM gateway |
| 25 | `brain-disk-template` | golden brain state disk + snapshot |
| 30/40 | `employees`, `agents` ApplicationSets | per-employee namespaces and agents |

Once `brain-disk-template` is Healthy, read the golden snapshot handle and pin it:

```bash
VSC=$(kubectl -n platform-storage get volumesnapshot brain-state-golden -o jsonpath='{.status.boundVolumeSnapshotContentName}')
kubectl get volumesnapshotcontent $VSC -o jsonpath='{.status.snapshotHandle}{"\n"}'
# -> charts/agent/values.yaml: brain.stateSnapshotHandle, then commit + push
```

**Check:** all apps `Synced/Healthy`:
`kubectl -n argocd get applications -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status`.

### 4.6 First employee and agent (≈10 min)

```bash
cat > employees/alice.yaml <<'EOF'
id: alice
displayName: Alice
EOF
mkdir -p agents/alice && cat > agents/alice/assistant.yaml <<'EOF'
employee: alice
name: assistant
brainKind: openclaw
model: meta/muse-spark-1.3-contributor
egress:                     # optional; omit = no internet
  allow: [github.com, "*.github.com", "*.githubusercontent.com", pypi.org, files.pythonhosted.org, registry.npmjs.org]
EOF
git add employees agents && git commit -m "add alice/assistant" && git push
```

What gets created in `u-alice`:
- **ESO-generated secrets:** SSH client key, SSH host key (with `known_hosts`), UI token.
- **Brain:** StatefulSet with its disk cloned from the golden snapshot.
- **Computer:** a `Sandbox`, which becomes a Kata pod (1.5 vCPU / 3 GiB, headless Chromium) with a 4 GiB workspace PVC, plus its Service (:2222 SSH, :9222 CDP).
- **Egress proxy** (only with `egress.allow`): Deployment + Service `<agent>-egress:3128`.
- **Paired NetworkPolicies.**

First start: the Kata node scales from 0 (≈2–3 min).

**Check:** `kubectl -n u-alice get pods` shows both pods `Running`, then run §6.

### 4.6b Telegram channel (optional, ≈5 min)

1. Create a bot with @BotFather (`/newbot`).
2. Store the token (from your own terminal, not a chat):
   ```bash
   read -rs TG; printf %s "$TG" > /tmp/tg
   az keyvault secret set --vault-name kv-agentch-<suffix> -n alice-assistant-telegram --file /tmp/tg -o none
   shred -u /tmp/tg; unset TG
   ```
3. Add to `agents/alice/assistant.yaml` and push:
   ```yaml
   channels:
     telegram:
       enabled: true
   ```
   Enable it only **after** the secret exists: the brain waits for the Secret otherwise.
4. Open the bot by its exact `@username`, press **Start**, send a message; it answers with a pairing code. Approve it with `pairing approve telegram <CODE> --notify` (the first CLI approval also records the command owner).

### 4.6c Public HTTPS + Entra ID (≈20 min)

1. `tofu apply` in `infra/platform` creates the static IP, the Entra app (redirect URIs from `agents/*/*.yaml`), assigns you, and stores the client secret in the platform vault. Read the outputs:
   ```bash
   tofu output ingress_ip ingress_domain ingress_oidc_client_id ingress_ui_hosts
   ```
2. Put the domain and client ID in `gitops/platform/ingress/*.yaml` (`hostname`, certificate `dnsNames`, `clientID`, tenant in `issuer`) and in `charts/agent/values.yaml` (`ingress.domain`). Push.
3. Argo app `ingress` (wave 25) creates the Gateway, LB, certificate (≈1 min) and OIDC policy.
4. Check: `curl -sI https://headlamp.<domain>/` returns `302` to `login.microsoftonline.com`.

New agent: add its host to `certificate.yaml` and run `tofu apply` (redirect URI), then push.

### 4.7 Use it

See [`playbook.md` §1](playbook.md#1-daily-use-5-minutes): port-forward
`svc/assistant-brain 18789` and open `http://localhost:18789/#token=<token>`.
Ops UI: Headlamp (§6 item 10), or `https://headlamp.<domain>/` (§4.6c).

---

## 5. Problems hit and how they were fixed

All fixes are already in the code; this explains **why** the code looks the way it does.

| # | Symptom | Root cause | Fix (where) |
|---|---|---|---|
| P1 | After `tofu apply`, runbook ran on PowerShell 5.1 and schedules lost the `Action` parameter | azurerm treats legacy `PowerShell72` as `PowerShell` and re-creates job schedules on runbook update | `runbook_type = "PowerShell"` + `runtime_environment_name = "PowerShell-7.2"`, job schedules inline (`infra/platform/automation.tf`) |
| P2 | Imported role assignment planned for replacement | Scope case: `resourcegroups` vs `resourceGroups` | `ignore_changes = [scope]` |
| P3 | Kata node never scaled up | `SkuNotAvailable` for D2ds_v5 **Spot** in eastus | `kataod` on-demand pool + priority expander (`nodepools.tf`, `gitops/platform/base/cluster-autoscaler-priority.yaml`) |
| P4 | Argo `valkey-secrets` Degraded | ClusterSecretStore namespace condition worked as designed; `data` lacked the label | Label `agentplatform.io/secrets-access=true` on `data` |
| P5 | `cert-manager` OutOfSync forever | caBundle injected by cainjector; AKS admissions enforcer appends webhook `namespaceSelector` rules | `ignoreDifferences` + `RespectIgnoreDifferences` |
| P6 | Argo sync waves ignored | Argo ≥1.8 does not assess `Application` health | Lua health check for `argoproj.io_Application` in `gitops/argocd/values.yaml` |
| P7 | Platform node at 82 % CPU requests | AKS add-ons (2× metrics-server, CoreDNS, WI webhook) scheduled there | Platform pool autoscaler 1–2 |
| P8 | Brain pod rejected by quota | Employee ResourceQuota requires resources on **init** containers too | Resources on all init containers |
| P9 | Brain `EPERM fchmod`, then "SQLite staging ancestor must not allow another user to replace its child" | OpenClaw requires its state dir owned by its uid with no group/other write on ancestors (sticky allowed); Azure Disk root is root-owned; `fsGroup` adds group write | Golden snapshot disk (D41), no `fsGroup` on the brain |
| P10 | Deadlock: golden PVC Pending, Job never created | `WaitForFirstConsumer` + Job in a later Argo wave | PVC and Job in the same wave |
| P11 | Brain StatefulSet not updated after `volumeClaimTemplates` change | The field is immutable; a crash-looping StatefulSet does not roll | Delete StatefulSet + PVC + released PV + Azure disk, then sync; delete the pod after spec changes |
| P12 | "Gateway start blocked: missing gateway.mode" though the ConfigMap had it | OpenClaw restored its backup ring because the config was overwritten on each start | Seed config once (`/data/gateway/openclaw.json`), set `gateway.mode: local` |
| P13 | `EPERM fchmod` remained | OpenClaw chmods its temp dir; `emptyDir` root is root-owned | Sticky `1777` subdir via `subPath: gateway-tmp` on `/tmp` (upstream recipe) |
| P14 | Brain could not resolve `assistant-computer` | agent-sandbox v1.0 creates no Service | Chart Service `<agent>-computer` |
| P15 | LLM call returned 404 "Paid model training violation" | Provider account blocked training-on-prompts models | Allowed it in OpenRouter privacy settings (or pick a non-training model) |
| P16 | Lowering employee namespaces to PSS `baseline` was blocked by the safety classifier | Security weakening | Replaced by D41 (kept `restricted`) |
| P17 | `git push` failed: stale credential helper path | `gh` reinstalled via mise | `gh auth setup-git` |
| P18 | CDP relay hung on `/json/version` | Chromium keeps HTTP connections open despite `Connection: close` | Relay reads exactly `Content-Length` bytes |
| P19 | `Remote CDP ... is not reachable` / `Navigation blocked: strict browser SSRF policy requires an IP-literal URL` | OpenClaw strict SSRF mode blocks private CDP hosts and unlisted hostnames | `browser.ssrfPolicy.allowedHostnames` (D49) |
| P20 | Agent said "no browser tool available" | `coding` tool profile lacks `browser`; sandboxed sessions deny it by default (`openclaw sandbox explain`) | `tools.alsoAllow` + `tools.sandbox.tools.alsoAllow` (D49) |
| P21 | New computer image not used after sync | agent-sandbox v1.0 does not roll the pod on `podTemplate` change | `kubectl -n u-<id> delete pod <agent>-computer` (workspace PVC is kept) |
| P22 | `browser.profiles.*.color` rejected | Not in the OpenClaw 2026.11 schema | Removed; validate with `openclaw config set ... --dry-run` |
| P25 | `https://youtube.com` blocked though `www.youtube.com` was allowed; page loaded without images/fonts/video | Allowlists match exact hosts; `*.domain` excludes the apex (Envoy and OpenClaw SSRF alike); sites pull assets from other domains | List apex **and** `*.domain`; map the rest from the proxy 403 log (`logs deploy/<agent>-egress | grep -v " 200 "`), allow what the feature needs, leave ads/telemetry blocked |
| P24 | New agent `HTTPRoute` missing although the app showed Synced | Argo had not re-rendered the agent ApplicationSet app at the new revision | Hard refresh (`argocd.argoproj.io/refresh=hard`) on the agent Application |
| P23 | Bot "silent" on first DM; `pairing list` empty | The message never reached the bot (`channel_ingress_events` = 0, Bot API `pending_update_count` = 0): chat not started / wrong bot | Open `@<bot>` exactly, press **Start**, then message; check `channel_ingress_events` in `/data/.openclaw/state/openclaw.sqlite` before suspecting polling |

---

## 6. Verification checklist

Run after §4.6. Each item maps to an acceptance criterion in `design.md`.

1. **Kata isolation.** The guest kernel must differ from the node kernel:
   ```bash
   kubectl -n u-alice exec assistant-computer -- uname -r
   kubectl get node $(kubectl -n u-alice get pod assistant-computer -o jsonpath='{.spec.nodeName}') -o jsonpath='{.status.nodeInfo.kernelVersion}'
   ```
2. **Admission policies.** Expect denials:
   ```bash
   kubectl run t --image=busybox --dry-run=server --annotations=io.katacontainers.config.hypervisor.virtio_fs_extra_args='["x"]'
   ```
   Also apply a `Sandbox` without `runtimeClassName` with `--dry-run=server`; expect `sandbox-pod-template-guard` to deny it.
3. **No key in brain, LLM works via the gateway.** Expect HTTP 200:
   ```bash
   kubectl -n u-alice exec assistant-brain-0 -c brain -- sh -c 'env | grep -ci sk-or'   # expect 0
   kubectl -n u-alice exec assistant-brain-0 -c brain -- node -e 'fetch("http://llm-gateway.envoy-gateway-system.svc/api/v1/chat/completions",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({model:"<model>",max_tokens:20,messages:[{role:"user",content:"hi"}]})}).then(r=>console.log(r.status))'
   ```
4. **Brain → computer over SSH; internet only via the allowlist.** From the brain, run `ssh` with `$SSH_IDENTITY` and `$SSH_KNOWN_HOSTS` (see `playbook.md`). Expect `200`, `403`/exit 56, and a timeout (exit 28):
   ```bash
   kubectl -n u-alice exec assistant-computer -- curl -s -o /dev/null -w '%{http_code}' -x http://assistant-egress:3128 https://github.com
   kubectl -n u-alice exec assistant-computer -- curl -s -o /dev/null -w '%{http_code}' -x http://assistant-egress:3128 https://google.com
   kubectl -n u-alice exec assistant-computer -- curl -s -m 8 https://github.com    # direct, no proxy
   kubectl -n u-alice logs deploy/assistant-egress | tail                           # access log
   ```
5. **Agent turn executes in the sandbox:**
   ```bash
   kubectl -n u-alice exec assistant-brain-0 -c brain -- sh -c 'cd /app && node openclaw.mjs agent --session-id t -m "run uname -r with your exec tool"'
   ```
   The reply must show the guest kernel.
6. **Valkey auth.** `valkey-cli PING` without a password returns `NOAUTH`.
7. **Browser in the VM.** Expect `OK browser: running`, then a page snapshot:
   ```bash
   X="kubectl -n u-alice exec assistant-brain-0 -c brain -- env HOME=/data OPENCLAW_CONFIG_PATH=/data/gateway/openclaw.json node openclaw.mjs"
   $X browser doctor && $X browser open https://en.wikipedia.org/wiki/Kata_Containers && $X browser snapshot | head
   $X sandbox explain --agent main     # "browser" must be in the allow list
   ```
8. **Telegram (polling via the brain listener).** Gateway log shows `starting provider (@<bot>)` and
   `polling ingress started`; proxy log shows only `brain CONNECT api.telegram.org:443 -> 200`;
   the token is not in the config file:
   ```bash
   kubectl -n u-alice logs deploy/assistant-egress | grep brain | tail -3
   kubectl -n u-alice exec assistant-brain-0 -c brain -- sh -c 'grep -c "<token prefix>" /data/gateway/openclaw.json'   # expect 0
   ```
9. **Public HTTPS + Entra.** Expect `302` to `login.microsoftonline.com` on both hosts, `301` on http, a Let's Encrypt cert with both SANs, and `Accepted` on the policy:
   ```bash
   curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://alice-assistant.20-121-208-105.sslip.io/
   curl -s -o /dev/null -w '%{http_code}\n' http://headlamp.20-121-208-105.sslip.io/
   kubectl -n ingress get certificate,securitypolicy
   ```
10. **Headlamp.** `kubectl -n headlamp port-forward svc/headlamp 4466:80`, open `http://localhost:4466`, paste `kubectl -n headlamp create token headlamp --duration=1h`.

Not yet automated (P4): cross-employee isolation (alice × bob), snapshot restore,
Spot eviction, Postgres backup/restore.

---

## 7. Costs

Measured in eastus, BRL, Nov 2026 (Azure Retail Prices API):

| Item | Cost |
|---|---|
| Fixed while stopped (system OS disk, public IP, LB, PVCs, snapshots) | ≈ R$150/month |
| Running: B2s + 1× D2ds_v5 platform | ≈ R$0.83/h |
| Kata node (only while a sandbox runs) | R$0.13/h Spot · R$0.61/h on-demand |
| Key Vaults, storage, budget, automation | cents |
| Actual spend for the whole PoC build (3 sessions) | ≈ R$15–18 |

Every infrastructure change in this PoC was presented with a per-action cost table before applying.

---

## 8. Teardown

1. Delete Argo-managed content first so disks are released:
   `kubectl -n argocd delete applicationset agents employees`.
2. Because of `Retain`, also delete released PVs and their Azure disks:
   `kubectl get pv`, then `az disk delete`.
3. `tofu destroy` in `infra/gitops-bootstrap`, then `infra/platform`, then `infra/bootstrap`.
4. Key Vaults have purge protection, so their names stay reserved for 7 days.
5. Delete the GHCR package and the snapshots in the `MC_*` resource group if any remain.

---

## 9. Open items

| Phase | Item |
|---|---|
| P3 | In progress (D52–D58): Telegram ✔ → HTTPS + Entra ✔ → schedule-based hibernation |
| P3+ | Per-employee authorization on the Gateway (Entra group/claim per agent host); today any user assigned to the app can open any agent UI |
| P3+ | Egress: per-agent allowlist done (D45). Next: TLS-level checks (SNI must match CONNECT host), per-request audit to Log Analytics, Headlamp plugin "Agents" |
| P4 | Acceptance tests with evidence; CNPG backups to Blob; daily VolumeSnapshots |
| P5 | `hermes` brain kind |
| Phase 2 | Custom stateless brain (pi-durable + Postgres event log); agent-sandbox HTTP API instead of SSH; per-employee Blob containers via Workload Identity |
| Housekeeping | Rotate the PoC LLM key and the Telegram bot token (both were pasted in a chat; bot: @BotFather `/revoke`, then update `alice-assistant-telegram` in `kv-agentch-*`) |
