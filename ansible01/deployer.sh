#!/usr/bin/env bash
# deployer-ssh-setup.sh
# Sets up SSH key authentication for deployer user

set -euo pipefail

USER_NAME="deployer"
PUBKEY_SOURCE="/hamed/SYS265/controller01/public-key/id_rsa.pub"
SSH_DIR="/home/${USER_NAME}/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

# Must be run as root
if [[ $EUID -ne 0 ]]; then
  echo "Run this script with sudo or as root."
  exit 1
fi

echo "[+] Creating .ssh directory if it does not exist..."
mkdir -p "$SSH_DIR"

echo "[+] Copying public key..."
cp "$PUBKEY_SOURCE" "$AUTHORIZED_KEYS"

echo "[+] Setting permissions..."
chmod 700 "$SSH_DIR"
chmod 600 "$AUTHORIZED_KEYS"

echo "[+] Setting ownership..."
chown -R ${USER_NAME}:${USER_NAME} "$SSH_DIR"

echo "[+] SSH setup complete for ${USER_NAME}."
