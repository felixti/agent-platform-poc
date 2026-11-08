# Agent Platform PoC — Design

Status: agreed 2026-11-08. Scope: proof of concept on a personal Azure subscription,
designed to be ported to the company platform.

## 1. Goal

A portable, fully open-source platform on AKS to run **always-on, durable AI agents**,
one or more per employee, with a selectable agent "brain" (OpenClaw, Hermes,
a custom agent built on pi-durable).

Hard constraints:

- Kubernetes (AKS), Envoy Gateway, Azure Storage Account, PostgreSQL, Redis-compatible cache, Azure PVCs.
- Open source only. No commercial / source-available licenses (BSL, SSPL, RSAL).
- Battle-tested security layers; high isolation; ingress **and** egress control.

## 2. Threat model

Agents execute **LLM-generated code** and process **untrusted internet content**
(web pages, emails, chat messages). Any agent may be prompt-injected at any time.
The platform must ensure a compromised agent cannot:

1. escape to the node or other agents (compute isolation),
2. reach other employees' data (tenant isolation),
3. exfiltrate data or credentials to arbitrary destinations (egress control),
4. read long-lived credentials (credential isolation).

## 3. Stack decision

| Layer | Choice | License | Why |
|---|---|---|---|
| Sandbox orchestration | [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) | Apache-2.0 | SIG Apps; `Sandbox` CRD with stable identity, PVC `volumeClaimTemplates`, `Suspended` mode, warm pools, NetworkPolicy generation |
| Isolation runtime | **AKS Pod Sandboxing** (Kata Containers + Cloud Hypervisor on Hyper-V), RuntimeClass `kata-vm-isolation` | Apache-2.0 | GA (Nov 2025), Microsoft-supported, tested in Kata upstream CI on AKS |
| Network dataplane | Azure CNI powered by Cilium (no ACNS) | Apache-2.0 | Enforces NetworkPolicy; free |
| Gateway | Envoy Gateway (ingress + explicit egress forward proxy) | Apache-2.0 | Gateway API, OIDC/JWT, rate limiting, header injection |
| PostgreSQL | CloudNativePG | Apache-2.0 | CNCF; operator-managed HA, backups to Blob |
| Cache/queues | Valkey | BSD-3-Clause | Redis 8 is RSAL/SSPL/AGPL |
| Secrets | Azure Key Vault + External Secrets Operator | Apache-2.0 | No secrets in git; Workload Identity |
| IaC | OpenTofu | MPL-2.0 | Terraform is BSL 1.1 |
| GitOps | Argo CD | Apache-2.0 | CNCF Graduated, ApplicationSet, UI |

### Alternatives evaluated

| Option | Verdict |
|---|---|
| agent-substrate/substrate (+ google/ax) | Strongest alternative (memory snapshots, <500 ms resume, credential-injecting egress). Rejected for now: v1.0.0 shipped 2026-11-05, GKE assumptions (#2589, #2669), no PVCs, Azure Blob object store only via an unreleased plugin, overlapping network stack. **Re-evaluate ~Feb 2027.** |
| google/ax | Not a sandbox: an alpha (`v1alpha1`) agent orchestrator that requires Substrate. |
| Kata + Firecracker (self-managed) | Not in Kata's AKS CI, devmapper snapshotter, no virtio-fs; unsupported on AKS. |
| gVisor (self-installed) | Unsupported on AKS; privileged node mutation, fragile across node-image upgrades. |
| OpenSandbox (AAIF) | Promising (can use agent-sandbox + Kata underneath); RC, untested on AKS. |
| KubeVirt | Conservative fallback (full VM per agent); heavy. |
| E2B self-host / Daytona / Arrakis | Single-node only / AGPL / archived. Excluded. |

## 4. Agent architecture: "brain outside, computer inside"

Matches how production always-on agents are built (Anthropic Managed Agents / Claude Duet,
xAI Grok Bot, OpenAI dots): a persistent per-agent computer holds only the *hands*; the
agent loop, durable state and credentials live outside it.

```
             Telegram / Web UI
                    │  (HTTPS, Entra ID OIDC)
            ┌───────▼────────┐
            │ Envoy Gateway  │  ingress
            └───────┬────────┘
   namespace u-<employee>    │
   ┌─────────────────────────▼───────────────────────┐
   │  Brain (runc pod)            Sandbox (Kata VM)   │
   │  agent loop, channels  ─SSH─▶ shell, code, files │
   │  state: PVC or Postgres       PVC /workspace     │
   │        │                      no credentials     │
   └────────┼──────────────────────────┼──────────────┘
            │ HTTPS_PROXY              │ HTTPS_PROXY
            ▼                          ▼
     ┌──────────────────────────────────────┐
     │ Envoy egress proxy: FQDN allowlist,  │──▶ openrouter.ai (key injected)
     │ credential injection, rate limit     │──▶ allowlisted hosts
     └──────────────────────────────────────┘
   Default-deny NetworkPolicy: pods can only reach DNS, the proxy, and their own peers.
```

- **Brain kinds** (`brainKind`): `openclaw` (PoC), `hermes` (optional), `pi-durable` (phase 2).
  Off-the-shelf brains run as a 1-replica StatefulSet with a PVC; the custom brain is
  stateless with an append-only event log in Postgres (`wake(sessionId)` pattern).
- **Brain ↔ sandbox contract**: SSH (exec + SFTP), one key per agent stored in Key Vault,
  hardened `sshd` (key-only, no root), NetworkPolicy allows only that agent's brain on :22.
  Phase 2 target: agent-sandbox HTTP API via sandbox-router.
- **Hibernation**: the brain sets its `Sandbox` to `Suspended` after 15 min idle and back
  to `Running` on the next message. The PVC is kept. On AKS this is a cold restart
  (memory snapshots are GKE-only). The Kata node pool autoscales to zero when all
  sandboxes are suspended.

## 5. Tenancy

Single company, isolation unit = **employee**.

| Concern | Per-employee scope |
|---|---|
| Kubernetes | Namespace `u-<id>`, Pod Security `restricted`, default-deny, ResourceQuota |
| Azure | User-assigned managed identity + federated credential; Blob container `u-<id>` (Storage Blob Data Contributor on that container only) |
| PostgreSQL | Role + schema per employee |
| Valkey | ACL user restricted to key prefix `u-<id>:` |
| Agents | One brain + one Kata sandbox per agent, NetworkPolicy pairs them |

Provisioning is GitOps: `employees/*.yaml` drives OpenTofu (Azure identity, container);
`agents/<employee>/*.yaml` drives an Argo CD ApplicationSet (the `agent` Helm chart).
**New agent = pull request.**

## 6. Security controls

- Kata microVM per sandbox (`kata-vm-isolation`), Azure Linux nodes, tainted pool.
- ValidatingAdmissionPolicy: deny `io.katacontainers.*` annotations, `hostPath`,
  privileged/hostNetwork pods, and `Sandbox` objects not created from approved templates
  (mitigates 2026 Kata CVEs such as CVE-2026-44210 / CVE-2026-86072).
- No secrets in sandboxes or brains: LLM keys injected by the egress proxy.
- Storage account: no shared keys, Entra ID only, network-restricted to the AKS egress IP.
- PVC StorageClass `reclaimPolicy: Retain` + daily VolumeSnapshots (mitigates agent-sandbox #2209).

## 7. Infrastructure

| Pool | Size | Purpose |
|---|---|---|
| `nodepool1` (system) | 1× B2s, Ubuntu | Critical add-ons only (`CriticalAddonsOnly` taint) |
| `platform` | 1× D2ds_v5, Azure Linux, ephemeral OS | Gateway, Argo CD, CNPG, Valkey, ESO, brains |
| `kata` | 0–1× D2ds_v5 **Spot**, Azure Linux, `KataVmIsolation`, ephemeral OS | Agent sandboxes (preferred) |
| `kataod` | 0–1× D2ds_v5 on-demand, same config | Fallback when Spot has no capacity (autoscaler priority expander) |

The whole cluster is started 08:00 and stopped 21:00 BRT on weekdays by an Azure
Automation runbook. Budget: R$450/month with forecast (85%) and actual (50/80/100%) alerts.

## 8. Acceptance criteria

1. Sandbox processes run inside a Kata microVM; forbidden fields are rejected at admission.
2. Employee A's agent cannot reach employee B's sandbox, Blob container, Postgres schema or Valkey keys.
3. Sandboxes reach the internet only via the Envoy allowlist; denied attempts are logged.
4. No LLM key is present in sandbox or brain (env, files) while LLM calls succeed.
5. Pod deletion / node drain / snapshot restore lose no data.
6. Idle → `Suspended` → Telegram message → wake → reply.
7. Ingress requires HTTPS + Entra ID login; Telegram webhook works.
8. Spot eviction loses no data.
9. Spend stays within budget.

## 9. Phases

| Phase | Content |
|---|---|
| P0 | Repo, OpenTofu foundation, Cilium dataplane, node pools, budget |
| P1 | Argo CD bootstrap; cert-manager, Envoy Gateway, ESO, CNPG, Valkey, agent-sandbox, policies |
| P2 | `agent` chart: OpenClaw brain + SSH sandbox; egress proxy with key injection |
| P3 | Ingress (OIDC, Telegram); hibernation |
| P4 | Acceptance test runbook + evidence |
| P5 | Hermes brain kind (optional) |

## 10. Known risks

- Spot capacity: on 2026-11-08 eastus returned `SkuNotAvailable` for D2ds_v5 Spot.
  Mitigated with the `kataod` on-demand fallback pool + priority expander.
- AKS Kata patch level vs. 2026 Kata CVEs is not published.
- virtio-fs PVC performance (2-3x slower on many small files, Azure/AKS#5920).
- OpenClaw SSH backend coverage (fallback: whole agent inside Kata for the PoC).

## 11. Porting to the company

| PoC | Company |
|---|---|
| OpenRouter | Internal OpenAI-compatible LLM gateway (M2M or API key), via private network |
| GHCR (public) | Azure Container Registry (managed identity pull) |
| sslip.io + Let's Encrypt | Corporate DNS + corporate CA / Let's Encrypt |
| Personal Entra tenant | Corporate Entra ID app registration |
| Single small cluster, start/stop schedule | Production node pools, autoscaling, no schedule |
| Argo CD via Helm | Argo CD via Helm or the AKS Argo CD extension |
