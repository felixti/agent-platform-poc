"""Schedule-based hibernation (D62/D63) as a reconcile loop: every run computes
the desired spec.operatingMode from the clock, so a cluster that was stopped
(missed CronJobs) converges on the next run.

Awake: Mon-Fri 08:00-20:00 America/Sao_Paulo (UTC-3, no DST since 2019).
Override: annotation agentplatform.io/awake-until=<UTC ISO time> keeps a
computer Running until then. Applies to Sandboxes labelled
agentplatform.io/hibernate=schedule. Stdlib only."""
import datetime as dt, json, os, ssl, sys, urllib.request

LOCAL = dt.timezone(dt.timedelta(hours=-3))
START, END = int(os.environ.get("AWAKE_FROM", "8")), int(os.environ.get("AWAKE_TO", "20"))
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://kubernetes.default.svc"
TOKEN = open(f"{SA}/token").read()
CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")

def call(method, path, body=None, ctype="application/json"):
    req = urllib.request.Request(API + path, method=method, data=body and json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": ctype})
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        return json.load(r)

now = dt.datetime.now(dt.timezone.utc)
local = now.astimezone(LOCAL)
working = local.weekday() < 5 and START <= local.hour < END

items = call("GET", "/apis/agents.x-k8s.io/v1beta1/sandboxes?labelSelector=agentplatform.io%2Fhibernate%3Dschedule")["items"]
failed = 0
for s in items:
    ns, name = s["metadata"]["namespace"], s["metadata"]["name"]
    until = (s["metadata"].get("annotations") or {}).get("agentplatform.io/awake-until")
    override = False
    if until:
        try:
            override = now < dt.datetime.fromisoformat(until.replace("Z", "+00:00"))
        except ValueError:
            print(f"{ns}/{name}: bad awake-until {until!r}, ignored", file=sys.stderr)
    want = "Running" if (working or override) else "Suspended"
    have = s["spec"].get("operatingMode", "Running")
    if have == want:
        continue
    try:
        call("PATCH", f"/apis/agents.x-k8s.io/v1beta1/namespaces/{ns}/sandboxes/{name}",
             {"spec": {"operatingMode": want}}, "application/merge-patch+json")
        print(f"{ns}/{name}: {have} -> {want}" + (" (awake-until)" if override and not working else ""))
    except Exception as e:  # keep going for the other agents
        failed += 1
        print(f"{ns}/{name}: FAILED {e}", file=sys.stderr)
print(f"{local:%a %H:%M} local, working={working}, {len(items)} sandboxes, {failed} failed")
sys.exit(1 if failed else 0)
