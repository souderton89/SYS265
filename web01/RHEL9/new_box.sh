#!/usr/bin/env bash
set -euo pipefail

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root (use sudo)."
    exit 1
  fi
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: /etc/os-release not found; cannot detect OS."
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"

  # Normalize to two families we care about
  if [[ "$OS_ID" == "rocky" ]] || [[ "$OS_LIKE" == *"rhel"* ]] || [[ "$OS_LIKE" == *"fedora"* ]]; then
    OS_FAMILY="rhel"
  elif [[ "$OS_ID" == "ubuntu" ]] || [[ "$OS_LIKE" == *"debian"* ]]; then
    OS_FAMILY="debian"
  else
    OS_FAMILY="unknown"
  fi
}

user_exists() {
  local u="$1"
  id "$u" &>/dev/null
}

add_to_group_if_needed() {
  local u="$1"
  local grp="$2"

  if id -nG "$u" | tr ' ' '\n' | grep -qx "$grp"; then
    echo "User '$u' is already in group '$grp'."
  else
    usermod -aG "$grp" "$u"
    echo "Added '$u' to group '$grp'."
  fi
}

add_admin_user_rhel() {
  read -r -p "Enter username to create: " u
  [[ -n "$u" ]] || { echo "Username cannot be blank."; return; }

  if user_exists "$u"; then
    echo "User '$u' already exists. Skipping creation."
  else
    useradd -m -s /bin/bash "$u"
    echo "Created user '$u' (useradd)."
  fi

  echo "Set password for '$u':"
  passwd "$u"

  add_to_group_if_needed "$u" "wheel"
  echo "Done. '$u' is now an admin user via 'wheel'."
}

add_admin_user_debian() {
  read -r -p "Enter username to create: " u
  [[ -n "$u" ]] || { echo "Username cannot be blank."; return; }

  if user_exists "$u"; then
    echo "User '$u' already exists. Skipping creation."
  else
    # Interactive: asks password + user details
    adduser "$u"
    echo "Created user '$u' (adduser)."
  fi

  add_to_group_if_needed "$u" "sudo"
  echo "Done. '$u' is now an admin user via 'sudo'."
}

set_hostname() {
  local current
  current="$(hostnamectl --static 2>/dev/null || hostname)"
  echo "Current hostname: $current"

  read -r -p "Enter NEW hostname: " new_host
  [[ -n "$new_host" ]] || { echo "Hostname cannot be blank."; return; }

  # Basic validation: letters/numbers/hyphen, no spaces
  if ! [[ "$new_host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "ERROR: Invalid hostname. Use letters/numbers/hyphens (no spaces)."
    return
  fi

  hostnamectl set-hostname "$new_host"
  echo "Hostname set to: $new_host"

  # Update hosts (helps Ubuntu; harmless on Rocky)
  if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${new_host}/" /etc/hosts
  else
    printf "\n127.0.1.1\t%s\n" "$new_host" >> /etc/hosts
  fi

  echo "Updated /etc/hosts."
}

menu() {
  echo
  echo "=============================="
  echo " System Setup Menu"
  echo " OS Detected: $OS_ID ($OS_FAMILY)"
  echo "=============================="
  echo "1) Add a sudo/admin user"
  echo "2) Set hostname"
  echo "3) Exit"
  echo
  read -r -p "Choose an option [1-3]: " choice
  echo

  case "$choice" in
    1)
      if [[ "$OS_FAMILY" == "rhel" ]]; then
        add_admin_user_rhel
      elif [[ "$OS_FAMILY" == "debian" ]]; then
        add_admin_user_debian
      else
        echo "ERROR: Unsupported OS for user creation (ID=$OS_ID)."
      fi
      ;;
    2)
      set_hostname
      ;;
    3)
      echo "Exiting."
      exit 0
      ;;
    *)
      echo "Invalid choice."
      ;;
  esac
}

main() {
  require_root
  detect_os

  if [[ "$OS_FAMILY" == "unknown" ]]; then
    echo "ERROR: Unsupported OS (ID=$OS_ID, ID_LIKE=$OS_LIKE)."
    exit 1
  fi

  while true; do
    menu
  done
}

main "$@"
