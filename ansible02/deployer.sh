#!/usr/bin/env bash
# deployer-ssh-setup.sh
# Sets up SSH key authentication for deployer user

set -euo pipefail

USER_NAME="deployer"
PUBKEY_SOURCE="/home/hamed/SYS265/controller01/public-key/id_rsa.pub"
SSH_DIR="/home/${USER_NAME}/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
PRIVATE_KEY="${SSH_DIR}/id_rsa"

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

echo "[+] Starting ssh-agent and loading private key..."

# Run ssh-agent + ssh-add as deployer
sudo -u ${USER_NAME} bash <<EOF
if [ -f "${PRIVATE_KEY}" ]; then
    eval "\$(ssh-agent -s)" >/dev/null
    ssh-add -t 14400 
    echo "[+] Private key loaded into ssh-agent (4 hour lifetime)."
else
    echo "[!] Private key not found at ${PRIVATE_KEY}"
fi
EOF

echo "[+] SSH setup complete for ${USER_NAME}."
