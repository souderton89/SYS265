#!/usr/bin/env bash
#secure-ssh.sh
#author hamed
#creates a new ssh user using $1 parameter
#adds a public key from the local repo or curled from the remote repo
#removes roots ability to ssh in

set -euo pipefail

# Usage: sudo ./secure-ssh.sh sys265
# This creates a user and installs WEB01's public key for passwordless SSH.

USERNAME="${1:-}"
PUBKEY_SRC="web01/public-key/id_rsa.pub"   # adjust if your repo path is different

if [[ -z "$USERNAME" ]]; then
  echo "Usage: sudo $0 <username>"
  exit 1
fi

HOME_DIR="/home/$USERNAME"
SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

# Must run as root (because we create users + write into /home/*)
if [[ $EUID -ne 0 ]]; then
  echo "[!] Run as root: sudo $0 <username>"
  exit 1
fi

# 1) Create the user if it doesn't already exist
if id "$USERNAME" &>/dev/null; then
  echo "[*] User '$USERNAME' already exists"
else
  echo "[*] Creating user '$USERNAME'"
  useradd -m -d "$HOME_DIR" -s /bin/bash "$USERNAME"
fi

# 2) Create .ssh directory
echo "[*] Creating $SSH_DIR"
mkdir -p "$SSH_DIR"

# 3) Copy public key into authorized_keys
if [[ ! -f "$PUBKEY_SRC" ]]; then
  echo "[!] Public key not found: $PUBKEY_SRC"
  echo "    Fix PUBKEY_SRC in the script or place the key at that path."
  exit 1
fi

echo "[*] Installing public key from: $PUBKEY_SRC"
cp "$PUBKEY_SRC" "$AUTH_KEYS"

# 4) Permissions + ownership (critical for SSH)
echo "[*] Setting permissions and ownership"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
chown "$USERNAME:$USERNAME" "$AUTH_KEYS"

echo "[+] Done. Test from WEB01:"
echo "    ssh ${USERNAME}@<server-hostname-or-ip>"

