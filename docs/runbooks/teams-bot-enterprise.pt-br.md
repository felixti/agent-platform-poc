# Runbook: bot do Microsoft Teams para um agente (tenant da empresa)

Este runbook mostra como ligar um agente da plataforma ao Microsoft Teams num tenant corporativo que já tem Microsoft 365 e Teams. Há dois caminhos:

- **Parte A, manual:** chamados e portais, sem Claude Code e sem scripts obrigatórios.
- **Parte B, automatizado:** o que a plataforma faz a partir de um único pull request.

A implementação da PoC está em `docs/reproduce.md` (D59–D61, §4.6d). A versão em inglês está em [teams-bot-enterprise.md](teams-bot-enterprise.md).

## Como funciona (leia uma vez)

```
Cliente Teams ──► Microsoft Bot Framework ──► https://<host-do-agente>/api/messages
                                               │  (público, SEM SSO da empresa neste caminho;
                                               │   JWT do Bot Framework validado no gateway)
                                               ▼
                                          brain do agente (plugin msteams do OpenClaw)
                                               │ respostas e token, pelo proxy de saída do agente
                                               ▼
                      login.microsoftonline.com, *.botframework.com, smba.trafficmanager.net
```

Cada agente tem um bot próprio. Um bot é formado por três objetos, e os três precisam ter o mesmo **App ID**:

| Objeto | Onde fica | O que guarda |
|---|---|---|
| Registro de app no Entra | Entra ID | App (client) ID, tenant ID, credencial (secret ou federada) |
| Recurso Azure Bot | Assinatura Azure | Endpoint de mensagens, canal Teams |
| Pacote do app Teams | Teams admin center | `manifest.json` com `botId = App ID` e 2 ícones |

## Parte A: manual, com chamados

### A.0 Quem faz o quê

| Papel | Normalmente | Chamados |
|---|---|---|
| Solicitante | Time de plataforma | abre todos os chamados e é dono do arquivo do agente |
| Admin do Entra | Time de identidade (Application Administrator) | A.1 |
| Dono do Azure | Time de cloud (Contributor no resource group do bot) | A.2 |
| Rede/Segurança | Rede e AppSec | A.3 |
| Admin do Teams | Time de M365/colaboração (Teams Administrator) | A.5, A.6 |
| Admin Global/Privileged Role | Time de identidade | A.6, só se precisar de permissões do Graph |

Prazo total com chamados: **3 a 10 dias úteis**. Trabalho efetivo: cerca de 2 h.

Antes de começar, reúna:
- o nome do agente (`<funcionario>-<nome>`);
- o host público (`<funcionario>-<nome>.<dominio-da-empresa>`);
- os usuários do piloto (UPNs);
- o dono do agente;
- o Key Vault dos secrets de canais (`kv-agentch-*`).

### A.1 Chamado → admin do Entra: registro do app

Texto para colar:

> Por favor, criem um registro de app no Entra ID para um bot do Teams.
> - Nome: `agent-<funcionario>-<nome>-teams`
> - Tipos de conta: **somente este diretório organizacional (single tenant)**
> - Sem redirect URI e sem permissões de API.
> - Credencial: **client secret**, validade de 12 meses, descrição `openclaw-msteams`.
>   Gravem o **valor** do secret direto no Key Vault `<kv-agentch-*>`, no secret
>   `<funcionario>-<nome>-msteams`. Não enviem por e-mail nem por chat.
> - Donos: `<solicitante>`, `<dono do agente>`.
> - Respondam com: Application (client) ID e Directory (tenant) ID.

Observações:
- O app precisa ser single tenant, porque a Microsoft deixou de aceitar bots multi-tenant novos depois de 31/07/2025.
- Coloque a data de expiração do secret no calendário do time. A rotação está em A.9.
- Se o time de identidade aceitar, há uma opção melhor: dispensar o secret e usar uma **credencial federada** com a workload identity do AKS (Parte B, B.2).

### A.2 Chamado → dono do Azure: recurso Azure Bot

> Por favor, criem um recurso **Azure Bot**.
> - Bot handle: `bot-<funcionario>-<nome>`; resource group: `<RG da plataforma>`; plano **F0**.
>   O Teams é canal padrão; o S1 só é necessário se quisermos SLA pago.
> - Type of App: **Single Tenant**; Creation type: **usar registro de app existente**;
>   App ID `<de A.1>`; Tenant ID `<de A.1>`.
> - Configuration → Messaging endpoint: `https://<funcionario>-<nome>.<dominio-da-empresa>/api/messages`
> - Channels → **Microsoft Teams** → aceitar os termos → Save.
> - Respondam com o resource ID.

### A.3 Chamado → Rede/Segurança: endpoint e saída

> O agente `<funcionario>-<nome>` precisa de um webhook do Teams.
> 1. **Entrada:** DNS público `<funcionario>-<nome>.<dominio-da-empresa>` apontando para o IP do gateway da plataforma, com certificado TLS da CA da empresa ou via ACME. O caminho `POST /api/messages` precisa ser acessível pela internet **sem SSO**, porque o Bot Framework não faz login. Todos os outros caminhos desse host continuam atrás do SSO. Nesse caminho, o gateway valida o JWT do Bot Framework (issuer `https://api.botframework.com`, audience = App ID, JWKS `https://login.botframework.com/v1/.well-known/keys`), e o SDK do bot valida de novo.
> 2. **Saída** a partir do egress da plataforma, se houver firewall ou proxy da empresa na frente: `login.microsoftonline.com`, `login.botframework.com`, `*.botframework.com` e `smba.trafficmanager.net`, na porta 443. Adicionem `graph.microsoft.com` somente se A.6 for aprovado.
> 3. WAF: não bloquear `POST` com corpo JSON de até 1 MB nesse caminho; timeout de pelo menos 15 s.

Na plataforma isso já está no chart (`charts/agent/templates/ingress.yaml` e `agent.brainEgressAllow`). O chamado serve para DNS, certificado e firewall da empresa na frente do cluster.

### A.4 Mudança na plataforma (solicitante, ≈10 min)

1. Em `agents/<funcionario>/<nome>.yaml`:
   ```yaml
   channels:
     msteams:
       enabled: true
       appId: <App ID de A.1>
       tenantId: <tenant ID>
       dmPolicy: pairing          # ou allowlist + allowFrom (object IDs do Entra)
   ```
2. Abra o PR, consiga a revisão e faça o merge. O Argo CD aplica a rota, a política de JWT e o mapeamento do secret, e reinicia o brain.
3. Confira o log do brain: `[msteams] starting provider account default (Gateway route /api/messages)`.
4. Confira a proteção: `curl -X POST https://<host>/api/messages -d '{}'` deve devolver **401**.
5. Teste opcional antes do Teams: no portal Azure, abra o bot → **Test in Web Chat** → mande "oi". O log do proxy deve mostrar `login.microsoftonline.com 200` e a resposta do bot.

### A.5 Gerar o pacote do app Teams

Com o repositório: `python3 teams-app/build.py agents/<funcionario>/<nome>.yaml` gera `teams-app/dist/<funcionario>-<nome>.zip`.

Sem o repositório, à mão (≈20 min):
1. Abra https://dev.teams.microsoft.com (Teams **Developer Portal**) → Apps → New app.
2. Em Basic information, preencha: nome curto `<nome> (<funcionario>)`, descrições, nome do desenvolvedor, URLs de site, privacidade e termos (páginas da wiki interna servem) e versão `1.0.0`.
3. Em Branding, envie o ícone colorido 192×192 PNG e o ícone de contorno 32×32 PNG (branco em fundo transparente).
4. Em App features → **Bot** → *Enter a bot ID*, use o App ID de A.1.
   - Escopo: **Personal**. Adicione Team e Group chat só se o agente for participar de canais ou grupos.
   - Supports files: ligado.
5. Em Permissions → Resource-specific consent (só para escopos de equipe ou grupo), use a lista de `teams-app/build.py` (`ChannelMessage.Read.Group`, `ChatMessage.Read.Chat`, ...).
6. Em Publish → **Download app package**, baixe o zip.

### A.6 Chamado → admin do Teams: aprovar e publicar o app

> Por favor, publiquem o app customizado do Teams `<nome> (<funcionario>)` no catálogo da organização e liberem para o grupo do piloto.
> 1. Teams admin center → Teams apps → **Manage apps** → **Upload new app** → zip em anexo. Se enviamos pelo Developer Portal com "Publish to your org", basta aprovar em Manage apps → *Pending approval*.
> 2. Revisem: somente bot, App ID `<A.1>`, publisher `<empresa>`, permissões = lista RSC, sem permissões de aplicação do Graph.
> 3. Status **Allowed**; Publishing status **Published**.
> 4. Disponibilidade: **usuários ou grupos específicos** → grupo `<grupo do piloto>`, ou uma app permission policy que libere este app para o grupo.
> 5. Opcional: uma setup policy para o grupo **instalar e fixar** o app, para que ninguém precise procurá-lo.
> 6. Em Org-wide app settings → Custom apps, a opção precisa estar ligada (normalmente já está).

Se o agente precisar do Graph (histórico de canal, arquivos em grupos), abra outro chamado para um Privileged Role/Global admin dar **admin consent** às permissões de aplicação listadas no app de A.1. A PoC não precisa disso.

Propagação: o app aparece no Teams entre 15 min e 24 h depois.

### A.7 Primeira conversa e pareamento

1. O usuário abre o Teams → Apps → *Criados para sua organização* → o agente → **Adicionar** → Abrir.
2. O usuário manda qualquer mensagem. Com `dmPolicy: pairing`, o bot responde com um código de pareamento.
3. O dono do agente aprova o código. O operador da plataforma roda:
   ```bash
   kubectl -n u-<funcionario> exec <nome>-brain-0 -c brain -- env HOME=/data \
     OPENCLAW_CONFIG_PATH=/data/gateway/openclaw.json node openclaw.mjs pairing approve msteams <CODIGO>
   ```
4. Em grupos e canais, adicione o app à equipe ou ao chat e **mencione** o bot com @, porque `requireMention` vem ligado por padrão.

### A.8 Checklist de aceite

- [ ] O log do brain mostra o provider msteams iniciado em `/api/messages`.
- [ ] `POST /api/messages` sem autenticação devolve 401, e a UI do agente continua pedindo SSO.
- [ ] O teste pelo Web Chat teve resposta.
- [ ] Depois do pareamento, a DM no Teams teve resposta.
- [ ] No log do proxy, o brain só acessa os quatro hosts da Microsoft.
- [ ] A data de expiração do secret está no calendário e o dono está cadastrado no registro do app.

### A.9 Operação

- **Rotação do secret** (antes de vencer):
  1. O admin do Entra cria um secret novo e atualiza o secret no Key Vault.
  2. O External Secrets sincroniza em até 1 h.
  3. Reinicie o brain.
  4. Remova o secret antigo.
- **Nova versão do app** (ícone, nome, escopos):
  1. Aumente o `version` no manifest.
  2. No Teams admin, vá em Manage apps → o app → **Upload file** (atualização).
  O App ID continua o mesmo e os usuários mantêm as conversas.
- **Desligamento**, nesta ordem:
  1. Coloque `enabled: false` ou apague o arquivo do agente.
  2. O admin do Teams bloqueia ou apaga o app.
  3. O dono do Azure apaga o bot.
  4. O admin do Entra apaga o registro do app.
  5. Apague o secret no Key Vault.

## Parte B: automatizado (um pull request)

O objetivo é que os únicos passos humanos sejam **revisar o PR** e, se a empresa exigir, **um clique de aprovação** do admin do Teams.

| Passo | Manual (Parte A) | Automatizado | Onde no repositório |
|---|---|---|---|
| Registro do app e credencial | chamado A.1 | OpenTofu `azuread_application` por arquivo de agente | `infra/platform/teams.tf` ✔ |
| Entrega do secret | admin do Entra → Key Vault | OpenTofu grava no KV e o ESO mapeia | `teams.tf`, `charts/agent/templates/channels.yaml` ✔ |
| Azure Bot e canal Teams | chamado A.2 | `azurerm_bot_service_azure_bot` F0 + `azurerm_bot_channel_ms_teams` | `teams.tf` ✔ |
| Rota, JWT, saída | chamado A.3 | chart Helm a partir de `channels.msteams` | `charts/agent` ✔ |
| Pacote do app | Developer Portal | `teams-app/build.py` no CI, um artefato por agente | `teams-app/` ✔ (passo de CI: a fazer) |
| Publicação e aprovação | chamado A.6 | Graph envia para revisão, o admin aprova (ou publica automático) | a fazer (B.3) |
| Instalação para o usuário | usuário procura na loja | instalação proativa via Graph | a fazer (B.4) |
| Pareamento | operador aprova código | `dmPolicy: allowlist` + object ID do dono no Entra | a fazer (B.5) |

### B.1 Fluxo

```
PR: agents/alice/assistant.yaml (channels.msteams: {enabled: true})
 ├─ CI  tofu plan ─► revisor aprova ─► tofu apply (app, credencial, bot, canal, KV)
 ├─ CI  grava appId/tenantId no arquivo (output do bot) e gera o zip do Teams
 ├─ CI  Graph: envia o app ao catálogo da org (requiresReview=true)
 │        └─► admin do Teams: 1 clique em "Publicar" (ou publicação automática, se a política permitir)
 ├─ Argo CD aplica rota + política JWT + secret + config do brain
 └─ CI  Graph: instala o app para o dono do agente; o bot manda um card de boas-vindas
```

### B.2 Sem secret: workload identity

1. Troque o client secret por uma **credencial de identidade federada** no registro do app:
   - issuer = URL do OIDC issuer do AKS;
   - subject = `system:serviceaccount:u-<funcionario>:<nome>-brain`;
   - audience = `api://AzureADTokenExchange`.
2. Coloque o label `azure.workload.identity/use: "true"` no pod do brain.
3. Configure `channels.msteams.authType: federated` e `useManagedIdentity` conforme a doc de autenticação do msteams do OpenClaw.

Não sobra nada para rotacionar. No OpenTofu, o recurso é `azuread_application_federated_identity_credential`.

### B.3 Publicar no catálogo da org (Microsoft Graph)

- Enviar para revisão (permissão delegada `AppCatalog.Submit`):
  `POST https://graph.microsoft.com/v1.0/appCatalogs/teamsApps?requiresReview=true`, com o zip no corpo (`Content-Type: application/zip`).
- Aprovar (admin do Teams, ou uma identidade de pipeline com `AppCatalog.ReadWrite.All`):
  `PATCH /appCatalogs/teamsApps/{appId}/appDefinitions/{definitionId}` com o corpo `{"publishingState": "published"}`.
- Atualizar um app existente: `POST /appCatalogs/teamsApps/{appId}/appDefinitions`, com o zip novo.
- Alternativa por CLI: `@microsoft/teams.cli` (`teams app create/update`, versão preview).

Antes de montar o pipeline, confira as permissões e chamadas exatas na documentação atual do Microsoft Graph, porque as APIs do Teams mudam com frequência.

### B.4 Instalar para o usuário e políticas

- Instalação proativa (permissão `TeamsAppInstallation.ReadWriteForUser.All`):
  `POST /users/{id-do-dono}/teamwork/installedApps` com o corpo
  `{"teamsApp@odata.bind": "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/{catalogAppId}"}`.
- Disponibilidade por grupo, via Teams PowerShell (módulo `MicrosoftTeams`):
  - para "disponível para usuários/grupos específicos": app permission policy ou app centric management (`Update-M365TeamsApp`);
  - para fixar o app: setup policy (`Grant-CsTeamsAppSetupPolicy`).

### B.5 Acabar com o pareamento manual

Coloque o **object ID** do dono no arquivo do agente e gere `dmPolicy: allowlist` com `allowFrom: [<object-id>]`. O bot responde ao dono na hora e ignora todos os outros. Mantenha `pairing` para agentes compartilhados.

### B.6 Limites para o pipeline

- A identidade do pipeline recebe só o necessário:
  - Application Administrator restrito aos próprios apps (ou `Application.ReadWrite.OwnedBy`);
  - Contributor no resource group dos bots;
  - Key Vault Secrets Officer no `kv-agentch-*`;
  - `AppCatalog.Submit`.
- **Publicar continua sendo um clique humano**, a menos que o time de segurança aprove a publicação automática.
- Nunca peça permissões de aplicação do Graph por padrão, porque elas exigem admin consent separado.
