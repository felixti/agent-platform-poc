#!/bin/sh
# Keys are mounted read-only from Kubernetes Secrets (generated in-cluster by
# External Secrets). sshd refuses group-readable host keys, so copy them into
# a private tmpfs with strict permissions first.
set -eu
umask 077
mkdir -p /run/agent-ssh
cp /etc/agent-ssh/host/privateKey /run/agent-ssh/ssh_host_ed25519_key
cp /etc/agent-ssh/client/publicKey /run/agent-ssh/authorized_keys
chmod 600 /run/agent-ssh/ssh_host_ed25519_key /run/agent-ssh/authorized_keys
mkdir -p /workspace/sandboxes
echo "agent computer ready: $(uname -r) $(nproc) vCPU"
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config.agent
