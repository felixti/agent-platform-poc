#!/bin/sh
# Keys are mounted read-only from Kubernetes Secrets (generated in-cluster by
# External Secrets). sshd refuses group-readable host keys, so copy them into
# a private tmpfs with strict permissions first.
#
# Optional env (set by charts/agent):
#   EGRESS_PROXY     http://<agent>-egress:3128 — the only way out to the internet
#   BROWSER_ENABLED  "true" starts headless Chromium + the CDP relay on :9222
set -eu
umask 077
mkdir -p /run/agent-ssh
cp /etc/agent-ssh/host/privateKey /run/agent-ssh/ssh_host_ed25519_key
cp /etc/agent-ssh/client/publicKey /run/agent-ssh/authorized_keys
chmod 600 /run/agent-ssh/ssh_host_ed25519_key /run/agent-ssh/authorized_keys
mkdir -p /workspace/sandboxes

# SSH sessions do not inherit the container env: pass the proxy via SetEnv.
cp /etc/ssh/sshd_config.agent /run/agent-ssh/sshd_config
if [ -n "${EGRESS_PROXY:-}" ]; then
  np="localhost,127.0.0.1,::1"
  echo "SetEnv HTTP_PROXY=$EGRESS_PROXY HTTPS_PROXY=$EGRESS_PROXY http_proxy=$EGRESS_PROXY https_proxy=$EGRESS_PROXY NO_PROXY=$np no_proxy=$np" \
    >> /run/agent-ssh/sshd_config
fi

if [ "${BROWSER_ENABLED:-false}" = "true" ]; then
  profile=/workspace/.browser-profile
  mkdir -p "$profile"
  (
    while true; do
      rm -f "$profile"/Singleton*   # stale locks after a pod restart
      chromium --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --no-first-run --no-default-browser-check \
        --remote-debugging-address=127.0.0.1 --remote-debugging-port=9223 \
        --user-data-dir="$profile" \
        ${EGRESS_PROXY:+--proxy-server="$EGRESS_PROXY"} \
        about:blank || true
      echo "chromium exited; restarting in 5s" >&2
      sleep 5
    done
  ) &
  python3 /usr/local/bin/cdp-relay.py &
fi

echo "agent computer ready: $(uname -r) $(nproc) vCPU proxy=${EGRESS_PROXY:-none} browser=${BROWSER_ENABLED:-false}"
exec /usr/sbin/sshd -D -e -f /run/agent-ssh/sshd_config
