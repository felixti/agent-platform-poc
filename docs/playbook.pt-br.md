# Agent Platform PoC — Playbook (pt-BR)

> Versão em português das instruções. Termos técnicos, comandos e nomes de recursos ficam em inglês.
> Original: [`playbook.md`](playbook.md).

> **Agora:** com o cluster ligado, o custo é ~R$1,50/h. Desligue quando terminar:
> `az aks stop -g aks-lab -n aks-lab` (≈3 min).

Status em 2026-11-09: **P0, P1 e P2 concluídas, além de allowlist de egress, browser dentro da VM e Headlamp.** Um agente OpenClaw (`alice/assistant`) funciona de ponta a ponta.
Diagrama: [`docs/topology.html`](topology.html). Como recriar do zero e todas as decisões: [`reproduce.md`](reproduce.md).

---

## 1. Uso diário (5 minutos)

### Ligar e abrir a UI do agente

1. Ligue o cluster. O start automático está desligado; o stop das 21:00 BRT nos dias úteis continua ligado:
   `az aks start -g aks-lab -n aks-lab` — ≈5 min
2. Pegue as credenciais: `az aks get-credentials -g aks-lab -n aks-lab --overwrite-existing`
3. Abra o túnel e deixe rodando: `kubectl -n u-alice port-forward svc/assistant-brain 18789:18789`
4. Abra a UI com o token, num segundo terminal:
   ```bash
   xdg-open "http://localhost:18789/#token=$(kubectl -n u-alice get secret assistant-gateway-token -o jsonpath='{.data.password}' | base64 -d)"
   ```

Depois de ligar o cluster, a primeira mensagem pode levar ≈2 min: o node Kata sobe a partir de zero.

### Falar com o agente no Telegram

1. Mande uma mensagem para **@xppocopenclaw_bot**. Na primeira vez, ele responde com um código de pareamento.
2. Aprove o código (≈1 min):
   ```bash
   kubectl -n u-alice exec assistant-brain-0 -c brain -- env HOME=/data OPENCLAW_CONFIG_PATH=/data/gateway/openclaw.json node openclaw.mjs pairing approve telegram <CODE>
   ```

### UI de operação (Headlamp)

1. Abra o túnel: `kubectl -n headlamp port-forward svc/headlamp 4466:80`
2. Abra `http://localhost:4466` e cole um token válido por 1 h: `kubectl -n headlamp create token headlamp --duration=1h`
3. Para ver os sandboxes: menu lateral → Custom Resources → `agents.x-k8s.io` → Sandbox.

### Desligar

1. `az aks stop -g aks-lab -n aks-lab` — ≈3 min. Mesmo desligado, você paga os discos, o IP e o load balancer (~R$150/mês).

---

## 2. Criar um agente (10 minutos, 1 PR)

1. Se for um funcionário novo, crie `employees/<id>.yaml`:
   ```yaml
   id: carol
   displayName: Carol
   ```
2. Crie `agents/<id>/<name>.yaml`:
   ```yaml
   employee: carol
   name: assistant
   brainKind: openclaw
   model: meta/muse-spark-1.3-contributor
   egress:              # opcional: allowlist de internet (sem isso = sem internet)
     allow: [github.com, "*.github.com", pypi.org]
   ```
3. Faça commit e push na `main`. O Argo CD cria o namespace `u-carol` e o agente (≈3 min).
4. Para abrir a UI, repita os passos 3 e 4 da §1, trocando `u-alice` por `u-carol`.

### Mudar a allowlist de internet de um agente

1. Edite `egress.allow` em `agents/<id>/<name>.yaml` e faça commit e push. Em ≈3 min o proxy e a política do browser são atualizados.
2. Para ver o que o agente tentou acessar: `kubectl -n u-<id> logs deploy/<name>-egress | tail`. Um 403 significa bloqueado.

---

## 3. O que existe

### Azure (OpenTofu, `infra/`)

| Item | Detail | Custo/mês |
|---|---|---|
| AKS `aks-lab` (eastus, Free tier) | Cilium dataplane, Workload Identity, OIDC | R$0 control plane |
| Pool `nodepool1` | 1× B2s Ubuntu, system add-ons only | ~R$64 + disco R$28 |
| Pool `platform` | D2ds_v5 Azure Linux, autoscale 1–2, ephemeral OS | ~R$174 por node (horário útil) |
| Pools `kata` / `kataod` | D2ds_v5 KataVmIsolation, 0–1, Spot preferred, on-demand fallback | R$0,13–0,61/h só enquanto um sandbox roda |
| Key Vaults | `kv-agentpoc-tf-4a67` (state key), `kv-agentpoc-jt75` (platform secrets), `kv-agentch-jt75` (agent channel tokens) | centavos |

Também existem:
- **Storage account** `stagentpocjt75`: para artefatos, sem chaves, ainda não usado.
- **Budget** de R$450, com alertas de previsão (85%) e de gasto real (50/80/100%).
- **Automation runbook**: desliga às 21:00 BRT nos dias úteis. O agendamento de start existe, mas está desabilitado.
- **LB + public IP**: ~R$118/mês.

### No cluster (Argo CD, `gitops/`)

| Grupo | Components |
|---|---|
| Platform | Argo CD 3.6.1, Envoy Gateway 1.10.0, cert-manager 1.20.5, External Secrets 2.14.0, agent-sandbox 1.0.10 |
| Data | CloudNativePG 1.30.1 (`agents-pg`, 8 GiB), Valkey 9.1 (ACL, 4 GiB) |
| LLM gateway | Envoy `llm-gateway` (ClusterIP): injects the OpenRouter key from Key Vault, 120 req/min |
| Policy | ValidatingAdmissionPolicies (Kata annotations, hostPath, non-Kata sandboxes), StorageClass `agent-disk` (Retain), golden brain-disk snapshot |
| Por funcionário | `u-<id>`: default-deny, DNS only, quota, PSS restricted |

### Por agente (`charts/agent`)

| Peça | O que é |
|---|---|
| Brain | OpenClaw gateway, StatefulSet, runc, non-root, disk cloned from golden snapshot |
| Computer | agent-sandbox `Sandbox`, Kata microVM (1.5 vCPU / 3 GiB), non-root sshd :2222, headless Chromium (CDP :9222 via relay), CLI toolbox, 4 GiB workspace |
| Egress proxy | Envoy `<agent>-egress`: :3128 computer (allowlist from the agent YAML), :3129 brain (channel APIs only, e.g. `api.telegram.org`); blocks private/IMDS ranges; access log |
| Channels | Telegram (long polling, `dmPolicy: pairing`); token from `kv-agentch-*` as env, never in config |
| Keys | SSH client/host keys + UI token, generated in-cluster by ESO generators |
| Network | brain → own computer :2222/:9222 and LLM gateway only; computer ← own brain only; computer → own egress proxy only |

---

## 4. O que está provado (com evidência)

1. O sandbox roda numa VM própria: kernel do guest `6.18.52.mshv1-2`, diferente do kernel do node `6.18.34.mshv3-1`.
2. A key do LLM nunca aparece no brain nem no sandbox (0 ocorrências), e as chamadas funcionam porque o Envoy injeta a key.
3. O sandbox só acessa a internet pela allowlist:
   - github e pypi retornam 200;
   - google retorna 403;
   - o `curl` direto, sem proxy, dá timeout;
   - o IMDS retorna 403.
4. O agente executou `uname`/`id` e gravou `note.txt` no sandbox. O arquivo continua no Azure Disk.
5. A admission policy bloqueia anotações `io.katacontainers.*`, Sandbox sem Kata e Sandbox com hostPath.
6. O agente usou o tool `browser`: o Chromium, dentro da VM Kata, abriu a Wikipedia pelo proxy, e o `google.com` foi bloqueado.

Também verificado:
- o Valkey recusa cliente sem autenticação (`NOAUTH`);
- o acesso ao Key Vault negou um namespace sem o label de permissão;
- o runbook de start/stop roda em PowerShell 7.2.

---

## 5. Problemas corrigidos (leia antes de levar para a empresa)

| Sintoma | Causa | Correção |
|---|---|---|
| Schedules lost `Action` param, runbook on PS 5.1 | azurerm `PowerShell72` type downgrades on update | `runbook_type = "PowerShell"` + `runtime_environment_name = "PowerShell-7.2"`, inline `job_schedule` |
| Kata node never came up | Spot `SkuNotAvailable` (eastus D2ds_v5) | `kataod` on-demand pool + autoscaler priority expander |
| Argo apps OutOfSync forever | cert-manager caBundle + AKS-injected webhook `namespaceSelector` | `ignoreDifferences` |
| Brain `EPERM fchmod` / "ancestor must not allow another user" | OpenClaw requires a state dir owned by its uid, no group write; Azure Disk root is root-owned | Golden snapshot (uid 1000, 0700), no `fsGroup` on brain |
| Brain restored old config | OpenClaw treats overwrites as clobbering | Seed `openclaw.json` once; sticky `/tmp` (upstream k8s recipe) |

| Agent: "no browser tool available" | `coding` profile + sandbox default deny exclude `browser` | `tools.alsoAllow` + `tools.sandbox.tools.alsoAllow` (chart re-applies on start) |
| New computer image not running | agent-sandbox v1.0 does not roll the pod | `kubectl -n u-<id> delete pod <agent>-computer` |

Outros menores:
- as SSH keys do ESO precisam de `refreshInterval: "0"`;
- a quota exige `resources` também nos init containers;
- um StatefulSet em CrashLoop só atualiza depois de um `delete` manual do pod.

---

## 6. O que falta (próximas fases)

| Fase | O quê | Estimativa |
|---|---|---|
| P3 | Telegram webhook + HTTPS ingress com Entra ID OIDC; hibernação idle → `Suspended` | ≈1 noite |
| P3+ | Hardening do egress (checagem de SNI, auditoria no Log Analytics) e plugin "Agents" no Headlamp | ≈1 noite cada |
| P4 | Testes de aceite com evidência: isolamento alice × bob, snapshot restore, Spot eviction, Postgres backup | ≈1 noite |
| P5 | `hermes` brain kind | ≈2–3 h |
| Fase 2 | Brain custom stateless (pi-durable + Postgres event log) | projeto |

---

## 7. Pendências

1. **Rotacione a key do OpenRouter e o token do bot do Telegram**, porque os dois foram colados no chat. Para o bot: no @BotFather use `/revoke` e depois rode `az keyvault secret set --vault-name kv-agentch-jt75 -n alice-assistant-telegram --file <arquivo>`. Para o OpenRouter: Gere uma nova em openrouter.ai/settings/keys e depois rode:
   `az keyvault secret set --vault-name kv-agentpoc-jt75 -n openrouter-api-key --file <arquivo>` — ≈2 min
2. A sua conta do OpenRouter agora **permite treino com os prompts**, o que foi necessário para o modelo `contributor`. Desligue a opção se trocar de modelo.
3. Nunca faça commit do `terraform.tfvars`, que contém o subscription id e o e-mail. Ele já está no `.gitignore`.

---

## 8. Levando para a empresa (resumo)

| PoC | Empresa |
|---|---|
| OpenRouter | Internal OpenAI-compatible LLM gateway: trocar o Backend FQDN + o secret no Key Vault |
| GHCR public image | ACR com pull via managed identity |
| port-forward + token | Envoy Gateway HTTPS + Entra ID corporativo |
| OpenClaw brain + golden disk | Brain custom stateless (sem disco de brain) |
| Assinatura pessoal, agenda start/stop | Pools de produção, autoscaling, sem agenda |

Justificativas completas: [`design.md`](design.md).
