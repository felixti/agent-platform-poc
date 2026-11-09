# Agent "computer": the hands of an agent. Runs inside a Kata microVM.
# Holds NO credentials. Reached only by its brain over SSH (key-only).
# Satisfies the OpenClaw SSH backend contract: /bin/sh, python3, GNU stat/readlink.
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/felixti/agent-platform-poc" \
      org.opencontainers.image.description="Agent sandbox computer (non-root sshd) for Kata pods" \
      org.opencontainers.image.licenses="Apache-2.0"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server python3 coreutils ca-certificates curl git jq procps less \
 && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
 && groupadd -g 1000 agent \
 && useradd -u 1000 -g 1000 -m -d /home/agent -s /bin/bash agent \
 && mkdir -p /workspace /run/agent-ssh && chown agent:agent /workspace /run/agent-ssh && chmod 700 /run/agent-ssh

COPY sshd_config /etc/ssh/sshd_config.agent
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh && chmod 0644 /etc/ssh/sshd_config.agent

USER 1000:1000
WORKDIR /workspace
EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
