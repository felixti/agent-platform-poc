# Runbook: Microsoft 365 Business Basic trial (Teams channel)

Why it exists: the Teams channel (D59) needs a work tenant with a Teams license.
The PoC uses a **30-day Microsoft 365 Business Basic trial** in the AKS tenant
`felixtilive.onmicrosoft.com`. Personal/free Teams does not allow custom bots.

Cost: R$0 during the trial. If it converts, about US$6 (~R$35) per user per month.
Rule: **recurring billing off on day 1**; check again **5 days before the end**.

## Day 1: activate (≈15 min)

1. Sign in to https://admin.microsoft.com as the tenant's Global Administrator.
2. Billing → Purchase services → *Microsoft 365 Business Basic* → **Start free trial**.
3. Users → Active users → `felix@felixtilive.onmicrosoft.com` → Licenses → assign
   Business Basic. The user already exists (created 2026-11-09, `usageLocation: BR`,
   must change the password at first sign-in). Your `@live.com` login is a guest and
   cannot hold the license. Initial password:
   ```bash
   az keyvault secret show --vault-name kv-agentpoc-jt75 -n teams-user-felix-initial-password --query value -o tsv
   ```
4. Billing → Your products → Business Basic → **Recurring billing: Off**. Without it,
   the trial expires instead of converting to paid.
5. Write down the end date. Then set a calendar reminder for **end date − 5 days**
   that links to this runbook:
   ```bash
   az rest --url https://graph.microsoft.com/v1.0/directory/subscriptions \
     --query "value[].{sku:skuPartNumber,trial:isTrial,status:status,next:nextLifecycleDateTime}" -o table
   ```
   `next` is the end date. If you activate on 2026-11-09, the end date is
   ≈2026-12-09 and the check date is ≈**2026-12-04**.

## End date − 5 days: cancel (≈5 min)

1. Run the `az rest` command above.
   - `status: Enabled` and `trial: True` means it is still the trial. Continue.
   - `trial: False` means it already converted. Go to step 3 now, because a refund
     window may apply.
2. Decide: keep Teams for the PoC (pay) or stop it.
3. To stop it, go to admin.microsoft.com → Billing → Your products → Business Basic.
   - Check that **Recurring billing is Off**.
   - Or choose **Cancel subscription**. If the button is missing, open a ticket:
     Support → New service request.
4. Platform side: disable the channel so the agent does not keep retrying.
   - Set `channels.msteams.enabled: false` in `agents/alice/assistant.yaml`, then push.
   - Optional: delete the Azure Bot resource (F0, free).
5. Check: Billing → Bills & payments has no upcoming charge, and the `az rest` output
   shows `status: Warning`/`Suspended` after the end date (not `Enabled` with
   `trial: False`).

## After expiry (for reference)

Microsoft moves an expired subscription through **Expired → Disabled → Deleted**
(about 30 + 90 days). Teams stops working at Disabled. Nothing to do unless you
want the data back. Check the current timings in the Microsoft 365 admin docs.
