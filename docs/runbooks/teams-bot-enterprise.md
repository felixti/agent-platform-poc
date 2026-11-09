# Runbook: Microsoft Teams bot for an agent (company tenant)

How to connect an agent of the platform to Microsoft Teams in a company tenant
that already has Microsoft 365 + Teams. Two ways:

- **Part A — manual**: tickets and portals, no Claude Code, no scripts required.
- **Part B — automated**: what the platform does from one pull request.

The PoC implementation is described in `docs/reproduce.md` (D59–D61, §4.6d).
pt-BR version: [teams-bot-enterprise.pt-br.md](teams-bot-enterprise.pt-br.md).

## How it works (read once)

```
Teams client ──► Microsoft Bot Framework ──► https://<agent-host>/api/messages
                                              │  (public, NO company SSO on this path;
                                              │   Bot Framework JWT checked at the gateway)
                                              ▼
                                         agent brain (OpenClaw msteams plugin)
                                              │ replies / token, via the agent's egress proxy
                                              ▼
                     login.microsoftonline.com, *.botframework.com, smba.trafficmanager.net
```

One bot per agent. Each bot is three objects that must share the same **App ID**:

| Object | Where | What it holds |
|---|---|---|
| Entra app registration | Entra ID | App (client) ID, tenant ID, credential (secret or federated) |
| Azure Bot resource | Azure subscription | Messaging endpoint, Teams channel |
| Teams app package | Teams admin center | `manifest.json` with `botId = App ID`, 2 icons |

## Part A — Manual, with tickets

### A.0 Who does what

| Role | Usually | Tickets |
|---|---|---|
| Requester | Platform team | opens all tickets, owns the agent file |
| Entra admin | Identity team (Application Administrator) | A.1 |
| Azure owner | Cloud team (Contributor on the bot resource group) | A.2 |
| Network/Security | Network + AppSec | A.3 |
| Teams admin | Collaboration/M365 team (Teams Administrator) | A.5, A.6 |
| Global/Privileged Role admin | Identity team | A.6 only if Graph permissions are needed |

Total lead time with tickets: **3–10 business days**. Hands-on work: about 2 h.

Collect before starting: agent name (`<employee>-<name>`), its public host
(`<employee>-<name>.<company-domain>`), the pilot users (UPNs), the owner of the
agent, and the Key Vault where agent channel secrets live (`kv-agentch-*`).

### A.1 Ticket → Entra admin: app registration

Text to paste:

> Please create an Entra ID app registration for a Teams bot.
> - Name: `agent-<employee>-<name>-teams`
> - Supported account types: **Accounts in this organizational directory only (single tenant)**
> - No redirect URI, no API permissions.
> - Credential: **client secret**, expiry 12 months, description `openclaw-msteams`.
>   Store the secret **value** directly in Key Vault `<kv-agentch-*>` as secret
>   `<employee>-<name>-msteams`. Do not send it by email or chat.
> - Owners: `<requester>`, `<agent owner>`.
> - Reply with: Application (client) ID and Directory (tenant) ID.

Notes:
- Single tenant is required: new multi-tenant bots were deprecated after 2025-07-31.
- Put the secret expiry date in the team calendar (rotation: A.9).
- Better option when the identity team accepts it: no secret, **federated credential**
  for the AKS workload identity (Part B, B.2).

### A.2 Ticket → Azure owner: Azure Bot resource

> Please create an **Azure Bot** resource.
> - Bot handle: `bot-<employee>-<name>`; resource group: `<platform RG>`; pricing tier **F0**
>   (Teams is a standard channel; S1 only if we need the paid SLA).
> - Type of App: **Single Tenant**; Creation type: **Use existing app registration**;
>   App ID `<from A.1>`; Tenant ID `<from A.1>`.
> - Configuration → Messaging endpoint: `https://<employee>-<name>.<company-domain>/api/messages`
> - Channels → **Microsoft Teams** → accept terms → Save.
> - Reply with the resource ID.

### A.3 Ticket → Network/Security: endpoint and egress

> Agent `<employee>-<name>` needs a Teams webhook.
> 1. **Inbound**: public DNS `<employee>-<name>.<company-domain>` → platform gateway IP, TLS cert
>    from the company CA or ACME. Path `POST /api/messages` must be reachable from the internet
>    **without SSO** (the Bot Framework cannot log in). Every other path on that host stays
>    behind SSO. The gateway validates the Bot Framework JWT on that path
>    (issuer `https://api.botframework.com`, audience = App ID, JWKS
>    `https://login.botframework.com/v1/.well-known/keys`); the bot SDK validates it again.
> 2. **Outbound** from the platform egress (if the company has a firewall/proxy in front):
>    `login.microsoftonline.com`, `login.botframework.com`, `*.botframework.com`,
>    `smba.trafficmanager.net` on 443. Add `graph.microsoft.com` only if A.6 is approved.
> 3. WAF: do not block `POST` with JSON bodies up to 1 MB on that path; timeout ≥ 15 s.

On the platform this is already templated (`charts/agent/templates/ingress.yaml`,
`agent.brainEgressAllow`), so the ticket is about company DNS, certificates and any
firewall in front of the cluster.

### A.4 Platform change (requester, ≈10 min)

1. In `agents/<employee>/<name>.yaml`:
   ```yaml
   channels:
     msteams:
       enabled: true
       appId: <App ID from A.1>
       tenantId: <tenant ID>
       dmPolicy: pairing          # or allowlist + allowFrom (Entra object IDs)
   ```
2. Open the pull request, get review, merge. Argo CD deploys the route, the JWT policy,
   the secret mapping and restarts the brain.
3. Check the brain log: `[msteams] starting provider account default (Gateway route /api/messages)`.
4. Check the protection: `curl -X POST https://<host>/api/messages -d '{}'` returns **401**.
5. Optional smoke test before Teams: Azure portal → the bot → **Test in Web Chat** → send
   "hi". The agent proxy log shows `login.microsoftonline.com 200` and a reply.

### A.5 Build the Teams app package

With the repo: `python3 teams-app/build.py agents/<employee>/<name>.yaml` →
`teams-app/dist/<employee>-<name>.zip`.

Without the repo, by hand (≈20 min):
1. Open https://dev.teams.microsoft.com (Teams **Developer Portal**) → Apps → New app.
2. Basic information: short name `<name> (<employee>)`, descriptions, developer
   name/website/privacy/terms URLs (internal wiki pages are fine), version `1.0.0`.
3. Branding: color icon 192×192 PNG, outline icon 32×32 PNG (white on transparent).
4. App features → **Bot** → *Enter a bot ID* = App ID from A.1. Scopes: **Personal**
   (add Team and Group chat only if the agent should live in channels/groups).
   Supports files: on.
5. Permissions → Resource-specific consent (only for team/group scope): the list in
   `teams-app/build.py` (`ChannelMessage.Read.Group`, `ChatMessage.Read.Chat`, ...).
6. Publish → **Download app package** (zip).

### A.6 Ticket → Teams admin: approve and publish the app

> Please publish the custom Teams app `<name> (<employee>)` to the organization catalog
> and make it available to the pilot group.
> 1. Teams admin center → Teams apps → **Manage apps** → **Upload new app** → attached zip.
>    (Or approve it under Manage apps → *Pending approval* if we submitted it from the
>    Developer Portal with "Publish to your org".)
> 2. Review: bot only, App ID `<A.1>`, publisher `<company>`, permissions = RSC list
>    (no Graph application permissions requested).
> 3. Status **Allowed**; Publishing status **Published**.
> 4. Availability: **Specific users or groups** → group `<pilot group>` (or an app
>    permission policy that allows this app for the group).
> 5. Optional: setup policy for the group to **install and pin** the app, so users do not
>    need to search for it.
> 6. Org-wide app settings → Custom apps: must be on (usually already).

If the agent needs Graph (channel history, files in group chats): a separate ticket to a
Privileged Role/Global admin for **admin consent** of the listed application permissions
on the app from A.1. The PoC does not need it.

Propagation: the app shows up in Teams in 15 min to 24 h.

### A.7 First conversation and pairing

1. The user opens Teams → Apps → *Built for your org* → the agent → **Add** → Open.
2. Sends any message. With `dmPolicy: pairing` the bot replies with a pairing code.
3. The agent owner approves (platform operator runs):
   ```bash
   kubectl -n u-<employee> exec <name>-brain-0 -c brain -- env HOME=/data \
     OPENCLAW_CONFIG_PATH=/data/gateway/openclaw.json node openclaw.mjs pairing approve msteams <CODE>
   ```
4. Group chats/channels: add the app to the team/chat and **@mention** it
   (`requireMention` is on by default).

### A.8 Acceptance checklist

- [ ] Brain log shows the msteams provider started on `/api/messages`.
- [ ] Unauthenticated `POST /api/messages` → 401; the agent UI still asks for SSO.
- [ ] Web Chat smoke test answered.
- [ ] Teams DM answered after pairing.
- [ ] Proxy log: only the four Microsoft hosts for the brain.
- [ ] Secret expiry date in the calendar; owner listed on the app registration.

### A.9 Operations

- **Secret rotation** (before expiry): Entra admin adds a new secret → updates the Key
  Vault secret → External Secrets refreshes within 1 h → restart the brain → remove the old
  secret.
- **New version of the app** (icon, name, scopes): bump `version` in the manifest → Teams
  admin → Manage apps → the app → **Upload file** (update). Same App ID, users keep chats.
- **Offboarding**: set `enabled: false` (or delete the agent file) → Teams admin blocks or
  deletes the app → Azure owner deletes the bot → Entra admin deletes the app registration →
  delete the Key Vault secret.

## Part B — Automated (one pull request)

Goal: the only human steps are **reviewing the pull request** and, if the company requires
it, **one approval click** by the Teams admin.

| Step | Manual (Part A) | Automated | Where in the repo |
|---|---|---|---|
| App registration + credential | A.1 ticket | OpenTofu `azuread_application` per agent file | `infra/platform/teams.tf` ✔ |
| Secret delivery | Entra admin → Key Vault | OpenTofu writes the KV secret; ESO maps it | `teams.tf`, `charts/agent/templates/channels.yaml` ✔ |
| Azure Bot + Teams channel | A.2 ticket | `azurerm_bot_service_azure_bot` F0 + `azurerm_bot_channel_ms_teams` | `teams.tf` ✔ |
| Route, JWT, egress | A.3 ticket | Helm chart from `channels.msteams` | `charts/agent` ✔ |
| App package | Developer Portal | `teams-app/build.py` in CI, artifact per agent | `teams-app/` ✔ (CI step: to do) |
| Publish + approval | A.6 ticket | Graph submit for review → admin approves (or auto-publish) | to do (B.3) |
| Install for the user | user searches the store | Graph proactive install | to do (B.4) |
| Pairing | operator approves a code | `dmPolicy: allowlist` + owner's Entra object ID | to do (B.5) |

### B.1 Flow

```
PR: agents/alice/assistant.yaml (channels.msteams: {enabled: true})
 ├─ CI  tofu plan  ─► reviewer approves ─► tofu apply (app, credential, bot, channel, KV)
 ├─ CI  writes appId/tenantId back (bot output) and builds the Teams zip
 ├─ CI  Graph: submit app to the org catalog (requiresReview=true)
 │        └─► Teams admin: 1 click "Publish" (or auto-publish if policy allows)
 ├─ Argo CD deploys route + JWT policy + secret + brain config
 └─ CI  Graph: install the app for the agent owner; bot sends a welcome card
```

### B.2 No secret: workload identity

Replace the client secret with a **federated identity credential** on the app
registration (issuer = AKS OIDC issuer URL, subject =
`system:serviceaccount:u-<employee>:<name>-brain`, audience `api://AzureADTokenExchange`),
label the brain pod `azure.workload.identity/use: "true"` and set
`channels.msteams.authType: federated` + `useManagedIdentity` per the OpenClaw msteams
authentication docs. Nothing to rotate. In OpenTofu:
`azuread_application_federated_identity_credential`.

### B.3 Publish to the org catalog (Microsoft Graph)

- Submit for review (permission `AppCatalog.Submit`, delegated):
  `POST https://graph.microsoft.com/v1.0/appCatalogs/teamsApps?requiresReview=true`
  with the zip as body (`Content-Type: application/zip`).
- Approve (Teams admin, or a pipeline identity with `AppCatalog.ReadWrite.All`):
  `PATCH /appCatalogs/teamsApps/{appId}/appDefinitions/{definitionId}`
  body `{"publishingState": "published"}`.
- Update an existing app: `POST /appCatalogs/teamsApps/{appId}/appDefinitions` with the new zip.
- Alternative CLI: `@microsoft/teams.cli` (`teams app create/update`, preview).

Check the exact permissions and calls against the current Microsoft Graph docs before
wiring the pipeline; Teams APIs change often.

### B.4 Install for the user and policies

- Proactive install (permission `TeamsAppInstallation.ReadWriteForUser.All`):
  `POST /users/{owner-id}/teamwork/installedApps` with
  `{"teamsApp@odata.bind": "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/{catalogAppId}"}`.
- Availability per group: Teams PowerShell (`MicrosoftTeams` module) —
  app permission policy / app centric management (`Update-M365TeamsApp` for
  "available to specific users/groups") and setup policy (`Grant-CsTeamsAppSetupPolicy`) for pinning.

### B.5 Remove manual pairing

Put the owner's Entra **object ID** in the agent file and render
`dmPolicy: allowlist` + `allowFrom: [<object-id>]`; the bot answers the owner immediately and
ignores everyone else. Keep `pairing` for shared agents.

### B.6 Guardrails for the pipeline

- The pipeline identity gets only what it needs: Application Administrator scoped to its
  own apps (or `Application.ReadWrite.OwnedBy`), Contributor on the bot resource group,
  Key Vault Secrets Officer on `kv-agentch-*`, `AppCatalog.Submit`.
- **Publishing stays a human click** unless the security team signs off on auto-publish.
- Never request Graph application permissions by default; they need a separate admin consent.
