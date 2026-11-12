# Agent Platform PoC — Playbook

> **Right now:** the cluster costs ~R$1.50/h while running. Stop it when done:
> `az aks stop -g aks-lab -n aks-lab` (≈3 min).

PT-BR: [`playbook.pt-br.md`](playbook.pt-br.md).

Status on 2026-11-09: **P0, P1, P2 done + egress allowlist, in-VM browser, Headlamp.** One OpenClaw agent (`alice/assistant`) runs end to end.
Diagram: [`docs/topology.html`](topology.html). Rebuild from scratch + every decision: [`reproduce.md`](reproduce.md).

---

## 1. Daily use (5 minutes)

### Start and open the agent UI

### Open the agent UI (HTTPS, no tunnel)

1. Open `https://alice-assistant.20-121-208-105.sslip.io/` and sign in with your Microsoft account (Entra ID).
2. Paste the OpenClaw token when asked (second factor):
   `kubectl -n u-alice get secret assistant-gateway-token -o jsonpath='{.data.password}' | base64 -d`
3. Ops UI: `https://headlamp.20-121-208-105.sslip.io/`, then a token: `kubectl -n headlamp create token headlamp --duration=1h`.

The port-forward steps below still work as a fallback.


1. Start the cluster (auto-start is off; the 21:00 BRT weekday stop stays on):
   `az aks start -g aks-lab -n aks-lab` — ≈5 min
2. Get credentials: `az aks get-credentials -g aks-lab -n aks-lab --overwrite-existing`
3. Open a tunnel (leave it running): `kubectl -n u-alice port-forward svc/assistant-brain 18789:18789`
4. Open the UI with its token (second terminal):
   ```bash
   xdg-open "http://localhost:18789/#token=$(kubectl -n u-alice get secret assistant-gateway-token -o jsonpath='{.data.password}' | base64 -d)"
   ```

First message after a cold start can take ≈2 min: the Kata node scales up from zero.

### Talk to the agent on Telegram

1. Open **@xppocopenclaw_bot** (exact username), press **Start**, send a message. First time: it replies with a pairing code. (alice is already paired.)
2. Approve it (≈1 min):
   ```bash
   kubectl -n u-alice exec assistant-brain-0 -c brain -- env HOME=/data OPENCLAW_CONFIG_PATH=/data/gateway/openclaw.json node openclaw.mjs pairing approve telegram <CODE> --notify
   ```

### Talk to the agent on Microsoft Teams

Company tenant (tickets or automated): [runbooks/teams-bot-enterprise.md](runbooks/teams-bot-enterprise.md).

1. Build the app package (≈1 min): `python3 teams-app/build.py agents/alice/assistant.yaml`.
2. In Teams, signed in as the licensed user (`felix@felixtilive.onmicrosoft.com`): Apps → Manage your apps → Upload an app → *Upload a custom app* → `teams-app/dist/alice-assistant.zip`.
3. Open a chat with the bot. First message: it replies with a pairing code. Approve it:
   ```bash
   kubectl -n u-alice exec assistant-brain-0 -c brain -- env HOME=/data OPENCLAW_CONFIG_PATH=/data/gateway/openclaw.json node openclaw.mjs pairing approve msteams <CODE>
   ```

### Agent computers sleep at night

Computers (Kata VMs) sleep at **20:00 every day** and wake at **08:00 Mon-Fri** (Sao Paulo time). The brain stays up: Telegram/Teams keep answering, but browser/shell tools fail while the computer sleeps.

- Keep one awake out of hours (example: 3 h), then wake it now:
  ```bash
  kubectl -n u-alice annotate sandbox assistant-computer --overwrite agentplatform.io/awake-until=$(date -u -d '+3 hours' +%FT%TZ)
  kubectl -n agent-hibernation create job wake-now --from=cronjob/computers-schedule
  ```
- The schedule is a reconcile every 10 min, so it also fixes itself after `az aks start`.
- Opt an agent out: `computer: {hibernate: "off"}` in its agent file.

### Ops UI (Headlamp)

1. Tunnel: `kubectl -n headlamp port-forward svc/headlamp 4466:80`
2. Open `http://localhost:4466` and paste a 1 h token: `kubectl -n headlamp create token headlamp --duration=1h`
3. Sandboxes: left menu → Custom Resources → `agents.x-k8s.io` → Sandbox.

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
   egress:              # optional: internet allowlist (omit = no internet)
     allow: [github.com, "*.github.com", pypi.org]
   ```
3. Add `carol-assistant.<domain>` to `dnsNames` in `gitops/platform/ingress/certificate.yaml` (per-host TLS, no wildcard on sslip.io).
4. Telegram (optional, before the push): create a bot in @BotFather (`/newbot`), then store the token: `az keyvault secret set --vault-name kv-agentch-jt75 -n carol-assistant-telegram --file <token-file>` and add `channels: {telegram: {enabled: true}}`. Pushing first makes the brain wait for a missing Secret.
5. Commit + push to `main`. Argo CD creates namespace `u-carol` and the agent (≈3 min). The user opens the bot, sends a message, sends you the pairing code; approve with the §1 command using `u-carol`.

Capacity: each computer needs its own D2ds_v5 (1.5 vCPU). With `sandbox_pool_max_count = 1` the platform runs at most 2 awake computers (1 Spot + 1 on-demand). The UI is open to every user of the Entra tenant (no per-employee authorization yet): beta testers outside the team use Telegram only.

### Change an agent's internet allowlist

1. Edit `egress.allow` in `agents/<id>/<name>.yaml`, commit + push (≈3 min; proxy and browser policy both update).
2. See what it tried: `kubectl -n u-<id> logs deploy/<name>-egress | tail` (403 = blocked).
3. Mapping a site: list the apex **and** `*.domain` (wildcards exclude the apex), open it, then count blocked hosts: `kubectl -n u-<id> logs deploy/<name>-egress --since=5m | grep -v " 200 " | awk '{print $4}' | sort | uniq -c | sort -rn`. Example: alice's YouTube set in `agents/alice/assistant.yaml`. If the proxy log shows `200` but the page still says blocked, the site itself refuses cloud IPs (Reddit, P26): allowlisting cannot fix that.

---

## 3. What exists

### Azure (OpenTofu, `infra/`)

| Item | Detail | Cost/month |
|---|---|---|
| AKS `aks-lab` (eastus, Free tier) | Cilium dataplane, Workload Identity, OIDC | R$0 control plane |
| Pool `nodepool1` | 1× B2s Ubuntu, system add-ons only | ~R$64 + disk R$28 |
| Pool `platform` | D2ds_v5 Azure Linux, autoscale 1–2, ephemeral OS | ~R$174 per node (weekday hours) |
| Pools `kata` / `kataod` | D2ds_v5 KataVmIsolation, 0–1, Spot preferred, on-demand fallback | R$0.13–0.61/h only while a sandbox runs |
| Key Vaults | `kv-agentpoc-tf-4a67` (state key), `kv-agentpoc-jt75` (platform secrets), `kv-agentch-jt75` (agent channel tokens) | cents |

Also: Storage account `stagentpocjt75` (artifacts, keyless, unused yet), budget R$450 with alerts (forecast 85 %, actual 50/80/100 %), Automation runbook stop 21:00 BRT weekdays (start schedule exists, disabled), LB + public IP (~R$118).

### In the cluster (Argo CD, `gitops/`)

| Group | Components |
|---|---|
| Platform | Argo CD 3.6.1, Envoy Gateway 1.10.0, cert-manager 1.20.5, External Secrets 2.14.0, agent-sandbox 1.0.10 |
| Data | CloudNativePG 1.30.1 (`agents-pg`, 8 GiB), Valkey 9.1 (ACL, 4 GiB) |
| LLM gateway | Envoy `llm-gateway` (ClusterIP): injects the OpenRouter key from Key Vault, 120 req/min |
| Policy | ValidatingAdmissionPolicies (Kata annotations, hostPath, non-Kata sandboxes), StorageClass `agent-disk` (Retain), golden brain-disk snapshot |
| Per employee | `u-<id>`: default-deny, DNS only, quota, PSS restricted |
| Public ingress | Envoy `public` on static IP 20.121.208.105, Let's Encrypt `*.20-121-208-105.sslip.io` hosts, Entra ID OIDC on every route, Headlamp + agent UIs |

### Per agent (`charts/agent`)

| Piece | What it is |
|---|---|
| Brain | OpenClaw gateway, StatefulSet, runc, non-root, disk cloned from golden snapshot |
| Computer | agent-sandbox `Sandbox`, Kata microVM (1.5 vCPU / 3 GiB), non-root sshd :2222, headless Chromium (CDP :9222 via relay), CLI toolbox, 4 GiB workspace |
| Egress proxy | Envoy `<agent>-egress`: :3128 computer (allowlist from the agent YAML), :3129 brain (channel APIs only, e.g. `api.telegram.org`); blocks private/IMDS ranges; access log |
| Hibernation | CronJob `computers-schedule` (every 10 min) in `agent-hibernation`: computers awake Mon-Fri 08:00-20:00 (America/Sao_Paulo), asleep otherwise; override with `agentplatform.io/awake-until`; brains always on |
| Channels | Telegram (long polling, `dmPolicy: pairing`); Microsoft Teams (Azure Bot F0 webhook `/api/messages`, Bot Framework JWT at the Gateway, replies via proxy :3129); secrets from `kv-agentch-*` as env, never in config |
| Keys | SSH client/host keys + UI token, generated in-cluster by ESO generators |
| Network | brain → own computer :2222/:9222 and LLM gateway only; computer ← own brain only; computer → own egress proxy only |

---

## 4. Proven (with evidence)

1. Sandbox runs in its own VM: guest kernel `6.18.52.mshv1-2` ≠ node `6.18.34.mshv3-1`.
2. LLM key is never in brain or sandbox (0 matches); calls succeed via Envoy injection.
3. Sandbox internet only via its allowlist: github/pypi 200, google 403, direct `curl` times out, IMDS 403.
4. Agent ran `uname`/`id`/wrote `note.txt` in the sandbox; file persists on its Azure Disk.
5. Admission denies: `io.katacontainers.*` annotations, Sandbox without Kata, Sandbox with hostPath.
6. Agent used the `browser` tool: Chromium in the Kata VM opened Wikipedia through the proxy; `google.com` blocked.

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

| Agent: "no browser tool available" | `coding` profile + sandbox default deny exclude `browser` | `tools.alsoAllow` + `tools.sandbox.tools.alsoAllow` (chart re-applies on start) |
| New computer image not running | agent-sandbox v1.0 does not roll the pod | `kubectl -n u-<id> delete pod <agent>-computer` |

More, smaller: ESO SSH keys need `refreshInterval: "0"`; quota requires resources on init containers; StatefulSet in CrashLoop needs a manual pod delete to roll.

---

## 6. Not done yet (next phases)

| Phase | What | Estimate |
|---|---|---|
| P3 | Telegram webhook + HTTPS ingress with Entra ID OIDC; idle → `Suspended` hibernation | ≈1 evening |
| P3+ | Egress hardening (SNI check, audit to Log Analytics), Headlamp "Agents" plugin | ≈1 evening each |
| P4 | Acceptance tests with evidence: alice × bob isolation, snapshot restore, Spot eviction, Postgres backup | ≈1 evening |
| P5 | `hermes` brain kind | ≈2–3 h |
| Phase 2 | Custom stateless brain (pi-durable + Postgres event log) | project |

---

## 7. Housekeeping

0. **M365 trial (Teams):** turn recurring billing off on day 1, then check and cancel **5 days before the end date**. Steps: [runbooks/m365-trial.md](runbooks/m365-trial.md).

1. **Rotate the OpenRouter key and the Telegram bot token** (both pasted in chat). Bot: @BotFather `/revoke`, then `az keyvault secret set --vault-name kv-agentch-jt75 -n alice-assistant-telegram --file <file>`. OpenRouter key — openrouter.ai/settings/keys, then:
   `az keyvault secret set --vault-name kv-agentpoc-jt75 -n openrouter-api-key --file <file>` — ≈2 min
2. OpenRouter account now **allows training on prompts** (needed for the `contributor` model). Turn it off if you switch models.
3. Never commit `terraform.tfvars` (subscription id, e-mail) — it is gitignored.

---

## 8. Porting to the company (summary)

| PoC | Company |
|---|---|
| OpenRouter | Internal OpenAI-compatible LLM gateway: change Backend FQDN + Key Vault secret |
| GHCR public image | ACR with managed-identity pull |
| sslip.io + Let's Encrypt HTTP-01, one SAN per host | Company domain, wildcard cert via DNS-01; corporate Entra ID tenant |
| OpenClaw brain + golden disk | Custom stateless brain (no brain disk needed) |
| Personal subscription, start/stop schedule | Production pools, autoscaling, no schedule |

Full rationale: [`design.md`](design.md).
