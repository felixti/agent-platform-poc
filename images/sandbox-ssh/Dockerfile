# Agent "computer": the hands of an agent. Runs inside a Kata microVM.
# Holds NO credentials. Reached only by its brain: SSH (:2222) and a headless
# Chromium DevTools endpoint (:9222). Internet only via the agent's egress proxy.
# Satisfies the OpenClaw SSH backend contract: /bin/sh, python3, GNU stat/readlink.
FROM ghcr.io/astral-sh/uv:0.13.7 AS uv

FROM node:22-bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/felixti/agent-platform-poc" \
      org.opencontainers.image.description="Agent sandbox computer (non-root sshd, headless Chromium, CLI tools) for Kata pods" \
      org.opencontainers.image.licenses="Apache-2.0"

ARG YQ_VERSION=v4.54.3

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server tini python3 python3-venv coreutils ca-certificates curl wget gnupg \
      git jq procps less unzip ripgrep fd-find build-essential \
      chromium fonts-liberation fonts-noto-color-emoji \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq \
 && chmod 0755 /usr/local/bin/yq \
 && ln -s /usr/bin/fdfind /usr/local/bin/fd \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
 && userdel -r node \
 && groupadd -g 1000 agent \
 && useradd -u 1000 -g 1000 -m -d /home/agent -s /bin/bash agent \
 && mkdir -p /workspace /run/agent-ssh && chown agent:agent /workspace /run/agent-ssh && chmod 700 /run/agent-ssh

COPY --from=uv /uv /uvx /usr/local/bin/
COPY sshd_config /etc/ssh/sshd_config.agent
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY cdp-relay.py /usr/local/bin/cdp-relay.py
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/cdp-relay.py && chmod 0644 /etc/ssh/sshd_config.agent

USER 1000:1000
WORKDIR /workspace
EXPOSE 2222 9222
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
