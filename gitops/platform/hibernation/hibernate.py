"""Set spec.operatingMode on every agent computer opted into schedule-based
hibernation (label agentplatform.io/hibernate=schedule). Stdlib only.
MODE=Suspended (sleep) or Running (wake)."""
import json, os, ssl, sys, urllib.request

MODE = os.environ["MODE"]
assert MODE in ("Running", "Suspended"), MODE
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = "https://kubernetes.default.svc"
TOKEN = open(f"{SA}/token").read()
CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")

def call(method, path, body=None, ctype="application/json"):
    req = urllib.request.Request(API + path, method=method, data=body and json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": ctype})
    with urllib.request.urlopen(req, context=CTX, timeout=30) as r:
        return json.load(r)

items = call("GET", "/apis/agents.x-k8s.io/v1beta1/sandboxes?labelSelector=agentplatform.io%2Fhibernate%3Dschedule")["items"]
failed = 0
for s in items:
    ns, name = s["metadata"]["namespace"], s["metadata"]["name"]
    if s["spec"].get("operatingMode") == MODE:
        print(f"{ns}/{name}: already {MODE}")
        continue
    try:
        call("PATCH", f"/apis/agents.x-k8s.io/v1beta1/namespaces/{ns}/sandboxes/{name}",
             {"spec": {"operatingMode": MODE}}, "application/merge-patch+json")
        print(f"{ns}/{name}: -> {MODE}")
    except Exception as e:  # keep going for the other agents
        failed += 1
        print(f"{ns}/{name}: FAILED {e}", file=sys.stderr)
print(f"{len(items)} sandboxes, {failed} failed")
sys.exit(1 if failed else 0)
