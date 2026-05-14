#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

log() {
  printf '\n==> %s\n' "$1"
}

as_root() {
  if [[ -n "${SUDO}" ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

install_coolify() {
  if [[ -n "${SUDO}" ]]; then
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
  else
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
  fi
}

detect_ip() {
  local ip
  ip="$(curl -4fsSL https://ifconfig.me 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  printf '%s' "${ip}"
}

export DEBIAN_FRONTEND=noninteractive

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    printf 'Warning: this script targets Ubuntu LTS, but detected %s.\n' "${PRETTY_NAME:-unknown}"
  fi
fi

log "Updating system packages"
as_root apt-get update
as_root apt-get upgrade -y
as_root apt-get install -y curl ca-certificates ufw

log "Configuring UFW"
as_root ufw allow 22/tcp
as_root ufw allow 80/tcp
as_root ufw allow 443/tcp
as_root ufw allow 8000/tcp
as_root ufw --force enable

log "Installing Coolify"
install_coolify

PUBLIC_IP="$(detect_ip)"

printf '\nCoolify install finished.\n'
if [[ -n "${PUBLIC_IP}" ]]; then
  printf 'Open http://%s:8000 to create the first admin account.\n' "${PUBLIC_IP}"
else
  printf 'Open http://YOUR_SERVER_IP:8000 to create the first admin account.\n'
fi
printf 'After you assign coolify.%s inside Coolify, you can close port 8000 if you want.\n' "${DOMAIN:-your-domain.com}"
