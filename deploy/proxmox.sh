#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]] || ! command -v pct >/dev/null 2>&1; then
  echo "Run this script as root on a Proxmox VE host." >&2
  exit 1
fi

: "${FIRE_UPLOAD_REPO:?Set FIRE_UPLOAD_REPO to owner/repository}"
: "${FIRE_UPLOAD_PUBLIC_URL:?Set FIRE_UPLOAD_PUBLIC_URL, for example https://name.duckdns.org}"
: "${DUCKDNS_SUBDOMAIN:?Set DUCKDNS_SUBDOMAIN without .duckdns.org}"
: "${DUCKDNS_TOKEN:?Set DUCKDNS_TOKEN}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ctid="${FIRE_UPLOAD_CTID:-$(pvesh get /cluster/nextid)}"
storage="${FIRE_UPLOAD_STORAGE:-local-lvm}"
bridge="${FIRE_UPLOAD_BRIDGE:-vmbr0}"

pveam update
template="$(pveam available --section system | awk '/debian-13-standard/ {print $2}' | tail -n 1)"
[[ -n "${template}" ]] || { echo "No Debian 13 LXC template is available." >&2; exit 1; }
if ! pveam list local | grep -Fq "${template}"; then
  pveam download local "${template}"
fi

pct create "${ctid}" "local:vztmpl/${template}" \
  --hostname fire-upload \
  --cores 1 \
  --memory 512 \
  --swap 256 \
  --rootfs "${storage}:8" \
  --net0 "name=eth0,bridge=${bridge},ip=dhcp,firewall=1" \
  --unprivileged 1 \
  --onboot 1 \
  --start 1

for file in install.sh fire-upload.service update.sh duckdns-update.sh duckdns-update.service duckdns-update.timer; do
  pct push "${ctid}" "${script_dir}/${file}" "/root/${file}" --perms 0755
done

pct exec "${ctid}" -- env \
  FIRE_UPLOAD_REPO="${FIRE_UPLOAD_REPO}" \
  FIRE_UPLOAD_PUBLIC_URL="${FIRE_UPLOAD_PUBLIC_URL}" \
  FIRE_UPLOAD_GITHUB_TOKEN="${FIRE_UPLOAD_GITHUB_TOKEN:-}" \
  FIRE_UPLOAD_PR_GITHUB_TOKEN="${FIRE_UPLOAD_PR_GITHUB_TOKEN:-}" \
  DUCKDNS_SUBDOMAIN="${DUCKDNS_SUBDOMAIN}" \
  DUCKDNS_TOKEN="${DUCKDNS_TOKEN}" \
  bash /root/install.sh

ip_address="$(pct exec "${ctid}" -- hostname -I | awk '{print $1}')"
echo "Fire Upload LXC ${ctid} created at ${ip_address}."
echo "Forward router TCP ports 80 and 443 to ${ip_address}."
