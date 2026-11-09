# Agent Platform PoC — Playbook

> **Right now:** the cluster costs ~R$1.50/h while running. Stop it when done:
> `az aks stop -g aks-lab -n aks-lab` (≈3 min).

PT-BR: [`playbook.pt-br.md`](playbook.pt-br.md).

Status on 2026-11-09: **P0, P1, P2 done.** One OpenClaw agent (`alice/assistant`) runs end to end.
Diagram: [`docs/topology.html`](topology.html).

---

## 1. Daily use (5 minutes)

### Start and open the agent UI

1. Start the cluster (skip on weekdays 08:00–21:00 BRT, it starts by itself):
   `az aks start -g aks-lab -n aks-lab` — ≈5 min
2. Get credentials: `az aks get-credentials -g aks-lab -n aks-lab --overwrite-existing`
3. Open a tunnel (leave it running): `kubectl -n u-alice port-forward svc/assistant-brain 18789:18789`
4. Open the UI with its token (second terminal):
   ```bash
   xdg-open "http://localhost:18789/#token=$(kubectl -n u-alice get secret assistant-gateway-token -o jsonpath='{.data.password}' | base64 -d)"
   ```

First message after a cold start can take ≈2 min: the Kata node scales up from zero.

### Stop

1. `az aks stop -g aks-lab -n aks-lab` — ≈3 min. Disks, IP and load balancer keep billing (~R$150/month).

---

## 2. Add an agent (10 minutes, one PR)

1. New employee? Create `employees/<id>.yaml`:
   ```yaml
   id: carol
   displayName: Carol
   ```
2. Create `agents/<id>/<name>.yaml`:
   ```yaml
   employee: carol
   name: assistant
   brainKind: openclaw
   model: meta/muse-spark-1.3-contributor
   ```
3. Commit + push to `main`. Argo CD creates namespace `u-carol` and the agent (≈3 min).
4. Open its UI: repeat §1 steps 3–4 with `u-carol`.

---

## 3. What exists

### Azure (OpenTofu, `infra/`)

| Item | Detail | Cost/month |
|---|---|---|
| AKS `aks-lab` (eastus, Free tier) | Cilium dataplane, Workload Identity, OIDC | R$0 control plane |
| Pool `nodepool1` | 1× B2s Ubuntu, system add-ons only | ~R$64 + disk R$28 |
| Pool `platform` | D2ds_v5 Azure Linux, autoscale 1–2, ephemeral OS | ~R$174 per node (weekday hours) |
| Pools `kata` / `kataod` | D2ds_v5 KataVmIsolation, 0–1, Spot preferred, on-demand fallback | R$0.13–0.61/h only while a sandbox runs |
| Key Vaults | `kv-agentpoc-tf-4a67` (state key), `kv-agentpoc-jt75` (platform secrets) | cents |

Also: Storage account `stagentpocjt75` (artifacts, keyless, unused yet), budget R$450 with alerts (forecast 85 %, actual 50/80/100 %), Automation runbook start 08:00 / stop 21:00 BRT weekdays, LB + public IP (~R$118).

### In the cluster (Argo CD, `gitops/`)

| Group | Components |
|---|---|
| Platform | Argo CD 3.6.1, Envoy Gateway 1.10.0, cert-manager 1.20.5, External Secrets 2.14.0, agent-sandbox 1.0.10 |
| Data | CloudNativePG 1.30.1 (`agents-pg`, 8 GiB), Valkey 9.1 (ACL, 4 GiB) |
| LLM gateway | Envoy `llm-gateway` (ClusterIP): injects the OpenRouter key from Key Vault, 120 req/min |
| Policy | ValidatingAdmissionPolicies (Kata annotations, hostPath, non-Kata sandboxes), StorageClass `agent-disk` (Retain), golden brain-disk snapshot |
| Per employee | `u-<id>`: default-deny, DNS only, quota, PSS restricted |

### Per agent (`charts/agent`)

| Piece | What it is |
|---|---|
| Brain | OpenClaw gateway, StatefulSet, runc, non-root, disk cloned from golden snapshot |
| Computer | agent-sandbox `Sandbox`, Kata microVM, non-root sshd :2222, 4 GiB workspace |
| Keys | SSH client/host keys + UI token, generated in-cluster by ESO generators |
| Network | brain → own computer :2222 and LLM gateway only; computer ← own brain only, no internet |

---

## 4. Proven (with evidence)

1. Sandbox runs in its own VM: guest kernel `6.18.52.mshv1-2` ≠ node `6.18.34.mshv3-1`.
2. LLM key is never in brain or sandbox (0 matches); calls succeed via Envoy injection.
3. Sandbox has no internet (`curl` blocked by NetworkPolicy).
4. Agent ran `uname`/`id`/wrote `note.txt` in the sandbox; file persists on its Azure Disk.
5. Admission denies: `io.katacontainers.*` annotations, Sandbox without Kata, Sandbox with hostPath.

Also verified: Valkey rejects unauthenticated clients (`NOAUTH`); Key Vault store denied an unlabelled namespace; start/stop runbook runs on PowerShell 7.2.

---

## 5. Gotchas fixed (read before porting)

| Symptom | Cause | Fix |
|---|---|---|
| Schedules lost `Action` param, runbook on PS 5.1 | azurerm `PowerShell72` type downgrades on update | `runbook_type = "PowerShell"` + `runtime_environment_name = "PowerShell-7.2"`, inline `job_schedule` |
| Kata node never came up | Spot `SkuNotAvailable` (eastus D2ds_v5) | `kataod` on-demand pool + autoscaler priority expander |
| Argo apps OutOfSync forever | cert-manager caBundle + AKS-injected webhook `namespaceSelector` | `ignoreDifferences` |
| Brain `EPERM fchmod` / "ancestor must not allow another user" | OpenClaw requires a state dir owned by its uid, no group write; Azure Disk root is root-owned | Golden snapshot (uid 1000, 0700), no `fsGroup` on brain |
| Brain restored old config | OpenClaw treats overwrites as clobbering | Seed `openclaw.json` once; sticky `/tmp` (upstream k8s recipe) |

More, smaller: ESO SSH keys need `refreshInterval: "0"`; quota requires resources on init containers; StatefulSet in CrashLoop needs a manual pod delete to roll.

---

## 6. Not done yet (next phases)

| Phase | What | Estimate |
|---|---|---|
| P3 | Telegram webhook + HTTPS ingress with Entra ID OIDC; idle → `Suspended` hibernation | ≈1 evening |
| P3 | Sandbox internet egress via Envoy FQDN allowlist | ≈1–2 h |
| P4 | Acceptance tests with evidence: alice × bob isolation, snapshot restore, Spot eviction, Postgres backup | ≈1 evening |
| P5 | `hermes` brain kind | ≈2–3 h |
| Phase 2 | Custom stateless brain (pi-durable + Postgres event log) | project |

---

## 7. Housekeeping

1. **Rotate the OpenRouter key** (it was pasted in chat) — openrouter.ai/settings/keys, then:
   `az keyvault secret set --vault-name kv-agentpoc-jt75 -n openrouter-api-key --file <file>` — ≈2 min
2. OpenRouter account now **allows training on prompts** (needed for the `contributor` model). Turn it off if you switch models.
3. Never commit `terraform.tfvars` (subscription id, e-mail) — it is gitignored.

---

## 8. Porting to the company (summary)

| PoC | Company |
|---|---|
| OpenRouter | Internal OpenAI-compatible LLM gateway: change Backend FQDN + Key Vault secret |
| GHCR public image | ACR with managed-identity pull |
| port-forward + token | Envoy Gateway HTTPS + corporate Entra ID |
| OpenClaw brain + golden disk | Custom stateless brain (no brain disk needed) |
| Personal subscription, start/stop schedule | Production pools, autoscaling, no schedule |

Full rationale: [`design.md`](design.md).
