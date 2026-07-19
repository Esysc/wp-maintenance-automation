#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

SSH_DIR="$(cd "$(dirname "$0")" && pwd)/ssh"
mkdir -p "$SSH_DIR"

if [[ -f "$SSH_DIR/id_rsa" ]]; then
  echo "SSH keys already exist in $SSH_DIR"
  exit 0
fi

echo "Generating SSH key pair in $SSH_DIR..."
ssh-keygen -t rsa -b 4096 -f "$SSH_DIR/id_rsa" -N "" -C "backupwordpress-test"

cp "$SSH_DIR/id_rsa.pub" "$SSH_DIR/authorized_keys"

chmod 600 "$SSH_DIR/id_rsa"
chmod 644 "$SSH_DIR/id_rsa.pub" "$SSH_DIR/authorized_keys"

echo "SSH keys generated successfully"
