# Agent Platform PoC — Playbook (pt-BR)

> Versão em português das instruções. Termos técnicos, comandos e nomes de recursos ficam em inglês.
> Original: [`playbook.md`](playbook.md).

> **Agora:** com o cluster ligado, o custo é ~R$1,50/h. Desligue quando terminar:
> `az aks stop -g aks-lab -n aks-lab` (≈3 min).

Status em 2026-11-09: **P0, P1 e P2 concluídas.** Um agente OpenClaw (`alice/assistant`) funciona de ponta a ponta.
Diagrama: [`docs/topology.html`](topology.html).

---

## 1. Uso diário (5 minutos)

### Ligar e abrir a UI do agente

1. Ligue o cluster. Nos dias úteis, entre 08:00 e 21:00 BRT, ele liga sozinho e você pode pular este passo:
   `az aks start -g aks-lab -n aks-lab` — ≈5 min
2. Pegue as credenciais: `az aks get-credentials -g aks-lab -n aks-lab --overwrite-existing`
3. Abra o túnel e deixe rodando: `kubectl -n u-alice port-forward svc/assistant-brain 18789:18789`
4. Abra a UI com o token, num segundo terminal:
   ```bash
   xdg-open "http://localhost:18789/#token=$(kubectl -n u-alice get secret assistant-gateway-token -o jsonpath='{.data.password}' | base64 -d)"
   ```

Depois de ligar o cluster, a primeira mensagem pode levar ≈2 min: o node Kata sobe a partir de zero.

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
   ```
3. Faça commit e push na `main`. O Argo CD cria o namespace `u-carol` e o agente (≈3 min).
4. Para abrir a UI, repita os passos 3 e 4 da §1, trocando `u-alice` por `u-carol`.

---

## 3. O que existe

### Azure (OpenTofu, `infra/`)

| Item | Detail | Custo/mês |
|---|---|---|
| AKS `aks-lab` (eastus, Free tier) | Cilium dataplane, Workload Identity, OIDC | R$0 control plane |
| Pool `nodepool1` | 1× B2s Ubuntu, system add-ons only | ~R$64 + disco R$28 |
| Pool `platform` | D2ds_v5 Azure Linux, autoscale 1–2, ephemeral OS | ~R$174 por node (horário útil) |
| Pools `kata` / `kataod` | D2ds_v5 KataVmIsolation, 0–1, Spot preferred, on-demand fallback | R$0,13–0,61/h só enquanto um sandbox roda |
| Key Vaults | `kv-agentpoc-tf-4a67` (state key), `kv-agentpoc-jt75` (platform secrets) | centavos |

Também existem:
- **Storage account** `stagentpocjt75`: para artefatos, sem chaves, ainda não usado.
- **Budget** de R$450, com alertas de previsão (85%) e de gasto real (50/80/100%).
- **Automation runbook**: liga às 08:00 e desliga às 21:00 BRT nos dias úteis.
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
| Computer | agent-sandbox `Sandbox`, Kata microVM, non-root sshd :2222, 4 GiB workspace |
| Keys | SSH client/host keys + UI token, generated in-cluster by ESO generators |
| Network | brain → own computer :2222 and LLM gateway only; computer ← own brain only, no internet |

---

## 4. O que está provado (com evidência)

1. O sandbox roda numa VM própria: kernel do guest `6.18.52.mshv1-2`, diferente do kernel do node `6.18.34.mshv3-1`.
2. A key do LLM nunca aparece no brain nem no sandbox (0 ocorrências), e as chamadas funcionam porque o Envoy injeta a key.
3. O sandbox não tem acesso à internet: o `curl` é bloqueado pela NetworkPolicy.
4. O agente executou `uname`/`id` e gravou `note.txt` no sandbox. O arquivo continua no Azure Disk.
5. A admission policy bloqueia anotações `io.katacontainers.*`, Sandbox sem Kata e Sandbox com hostPath.

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

Outros menores:
- as SSH keys do ESO precisam de `refreshInterval: "0"`;
- a quota exige `resources` também nos init containers;
- um StatefulSet em CrashLoop só atualiza depois de um `delete` manual do pod.

---

## 6. O que falta (próximas fases)

| Fase | O quê | Estimativa |
|---|---|---|
| P3 | Telegram webhook + HTTPS ingress com Entra ID OIDC; hibernação idle → `Suspended` | ≈1 noite |
| P3 | Internet egress do sandbox via Envoy FQDN allowlist | ≈1–2 h |
| P4 | Testes de aceite com evidência: isolamento alice × bob, snapshot restore, Spot eviction, Postgres backup | ≈1 noite |
| P5 | `hermes` brain kind | ≈2–3 h |
| Fase 2 | Brain custom stateless (pi-durable + Postgres event log) | projeto |

---

## 7. Pendências

1. **Rotacione a key do OpenRouter**, porque ela foi colada no chat. Gere uma nova em openrouter.ai/settings/keys e depois rode:
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
