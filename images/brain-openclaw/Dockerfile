# Brain image = upstream OpenClaw + the official external channel plugins the
# platform supports, pinned and installed at build time (the brain has no npm
# access at runtime; its egress proxy only allows channel APIs).
FROM ghcr.io/openclaw/openclaw:2026.11.1@sha256:db0e0809fbd0df375445e9eea8daf2a278ac7ac3a263fa6bfce8fb344ad3ad77
USER root
# Same version as the core (plugin compat: pluginApi >= core version).
RUN mkdir -p /opt/openclaw-plugins \
 && cd /opt/openclaw-plugins \
 && npm init -y >/dev/null \
 && npm install --omit=dev --legacy-peer-deps --no-audit --no-fund \
      @openclaw/msteams@2026.11.1 \
 && chown -R root:root /opt/openclaw-plugins && chmod -R a+rX,go-w /opt/openclaw-plugins
USER node
