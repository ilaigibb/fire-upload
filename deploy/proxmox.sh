#!/usr/bin/env bash
set -Eeuo pipefail

APP="Fire Upload"
DEFAULT_CPU=1
DEFAULT_RAM=512
DEFAULT_SWAP=256
DEFAULT_DISK=8
created_ctid=""

fail() {
  echo "Error: $*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  if [[ -n "${created_ctid}" ]]; then
    echo >&2
    echo "Installation failed. LXC ${created_ctid} was kept so its logs can be inspected." >&2
  fi
  exit "${exit_code}"
}
trap on_error ERR

if [[ ${EUID} -ne 0 ]] || ! command -v pct >/dev/null 2>&1; then
  fail "Run this command in the shell of a Proxmox VE host as root."
fi

for command_name in curl pveam pvesh pvesm python3; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "Missing required command: ${command_name}"
done

prompt() {
  local message="$1"
  local default_value="${2:-}"
  local value

  if command -v whiptail >/dev/null 2>&1; then
    value="$(whiptail --backtitle "Fire Upload Proxmox Installer" --title "${APP}" \
      --inputbox "${message}" 10 72 "${default_value}" 3>&1 1>&2 2>&3)" || exit 1
  else
    read -r -p "${message} [${default_value}]: " value </dev/tty
    value="${value:-${default_value}}"
  fi

  printf '%s' "${value}"
}

prompt_secret() {
  local message="$1"
  local value

  if command -v whiptail >/dev/null 2>&1; then
    value="$(whiptail --backtitle "Fire Upload Proxmox Installer" --title "${APP}" \
      --passwordbox "${message}" 10 72 3>&1 1>&2 2>&3)" || exit 1
  else
    read -r -s -p "${message}: " value </dev/tty
    echo >/dev/tty
  fi

  printf '%s' "${value}"
}

first_storage_for() {
  pvesm status -content "$1" 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1; exit }'
}

select_mode() {
  if [[ -n "${FIRE_UPLOAD_INSTALL_MODE:-}" ]]; then
    printf '%s' "${FIRE_UPLOAD_INSTALL_MODE}"
    return
  fi

  if command -v whiptail >/dev/null 2>&1; then
    whiptail --backtitle "Fire Upload Proxmox Installer" --title "${APP}" \
      --menu "Choose an installation mode." 14 64 2 \
      "default" "Create a small LXC with sensible defaults" \
      "advanced" "Choose the LXC resources and storage" \
      3>&1 1>&2 2>&3
  else
    local choice
    read -r -p "Install mode: [1] Default  [2] Advanced: " choice </dev/tty
    [[ "${choice:-1}" == "2" ]] && printf 'advanced' || printf 'default'
  fi
}

mode="$(select_mode)"
[[ "${mode}" == "default" || "${mode}" == "advanced" ]] || fail "Install mode must be default or advanced."

repo="${FIRE_UPLOAD_REPO:-}"
[[ -n "${repo}" ]] || repo="$(prompt "GitHub repository containing Fire Upload (owner/repository)")"
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Repository must look like owner/repository."

github_token="${FIRE_UPLOAD_GITHUB_TOKEN:-}"
if [[ -z "${github_token}" ]]; then
  github_token="$(prompt_secret "GitHub token (leave blank only when the repository is public)")"
fi

duckdns_subdomain="${DUCKDNS_SUBDOMAIN:-}"
[[ -n "${duckdns_subdomain}" ]] || duckdns_subdomain="$(prompt "DuckDNS subdomain without .duckdns.org")"
[[ "${duckdns_subdomain}" =~ ^[A-Za-z0-9-]+$ ]] || fail "DuckDNS subdomain contains invalid characters."

duckdns_token="${DUCKDNS_TOKEN:-}"
[[ -n "${duckdns_token}" ]] || duckdns_token="$(prompt_secret "DuckDNS token")"
[[ -n "${duckdns_token}" ]] || fail "DuckDNS token is required."

ctid="${FIRE_UPLOAD_CTID:-$(pvesh get /cluster/nextid)}"
hostname="${FIRE_UPLOAD_HOSTNAME:-fire-upload}"
cores="${FIRE_UPLOAD_CORES:-${DEFAULT_CPU}}"
memory="${FIRE_UPLOAD_MEMORY:-${DEFAULT_RAM}}"
swap="${FIRE_UPLOAD_SWAP:-${DEFAULT_SWAP}}"
disk="${FIRE_UPLOAD_DISK:-${DEFAULT_DISK}}"
bridge="${FIRE_UPLOAD_BRIDGE:-vmbr0}"
container_storage="${FIRE_UPLOAD_STORAGE:-$(first_storage_for rootdir)}"
template_storage="${FIRE_UPLOAD_TEMPLATE_STORAGE:-$(first_storage_for vztmpl)}"

if [[ "${mode}" == "advanced" ]]; then
  ctid="$(prompt "Container ID" "${ctid}")"
  hostname="$(prompt "Hostname" "${hostname}")"
  cores="$(prompt "CPU cores" "${cores}")"
  memory="$(prompt "Memory in MiB" "${memory}")"
  swap="$(prompt "Swap in MiB" "${swap}")"
  disk="$(prompt "Disk size in GiB" "${disk}")"
  bridge="$(prompt "Network bridge" "${bridge}")"
  container_storage="$(prompt "Container storage" "${container_storage}")"
  template_storage="$(prompt "Template storage" "${template_storage}")"
fi

for numeric_value in "${ctid}" "${cores}" "${memory}" "${swap}" "${disk}"; do
  [[ "${numeric_value}" =~ ^[0-9]+$ ]] || fail "Container resources must be whole numbers."
done
[[ -n "${container_storage}" ]] || fail "No storage supporting LXC root filesystems was found."
[[ -n "${template_storage}" ]] || fail "No storage supporting LXC templates was found."
pvesm status -content rootdir | awk 'NR > 1 { print $1 }' | grep -Fxq "${container_storage}" || \
  fail "Storage ${container_storage} does not support containers."
pvesm status -content vztmpl | awk 'NR > 1 { print $1 }' | grep -Fxq "${template_storage}" || \
  fail "Storage ${template_storage} does not support LXC templates."
if pct status "${ctid}" >/dev/null 2>&1 || qm status "${ctid}" >/dev/null 2>&1; then
  fail "Container or VM ID ${ctid} is already in use."
fi

public_url="https://${duckdns_subdomain}.duckdns.org"
echo
echo "Fire Upload will create:"
echo "  LXC:       ${ctid} (${hostname})"
echo "  Resources: ${cores} CPU, ${memory} MiB RAM, ${disk} GiB disk"
echo "  Storage:   ${container_storage}"
echo "  URL:       ${public_url}"
echo
if [[ "${FIRE_UPLOAD_ASSUME_YES:-no}" != "yes" ]]; then
  read -r -p "Continue? [Y/n]: " confirmation </dev/tty
  [[ "${confirmation:-y}" =~ ^[Yy]$ ]] || exit 0
fi

api_headers=(-H "Accept: application/vnd.github+json")
asset_headers=(-H "Accept: application/octet-stream")
if [[ -n "${github_token}" ]]; then
  api_headers+=(-H "Authorization: Bearer ${github_token}")
  asset_headers+=(-H "Authorization: Bearer ${github_token}")
fi

echo "Downloading the latest Fire Upload release..."
release_json="$(curl -fsSL "${api_headers[@]}" "https://api.github.com/repos/${repo}/releases/latest")" || \
  fail "Could not read the latest GitHub release. Check the repository and token."
release_values="$(python3 -c '
import json, sys
release = json.load(sys.stdin)
asset = next((item for item in release.get("assets", []) if item.get("name") == "fire-upload.tar.gz"), None)
if not asset:
    raise SystemExit("The latest release has no fire-upload.tar.gz asset.")
print(release["tag_name"])
print(asset["url"])
' <<<"${release_json}")"
release_tag="$(sed -n '1p' <<<"${release_values}")"
asset_url="$(sed -n '2p' <<<"${release_values}")"

temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT
curl -fsSL "${asset_headers[@]}" "${asset_url}" -o "${temporary}/fire-upload.tar.gz"
tar -tzf "${temporary}/fire-upload.tar.gz" | grep -Eq '(^|/)install\.sh$' || \
  fail "The release is missing its guest installer."

echo "Downloading the Debian 13 LXC template..."
pveam update >/dev/null
template="$(pveam available --section system | awk '/debian-13-standard/ { print $2 }' | tail -n 1)"
[[ -n "${template}" ]] || fail "No Debian 13 LXC template is available."
if ! pveam list "${template_storage}" | awk 'NR > 1 { print $1 }' | grep -Fxq "${template_storage}:vztmpl/${template}"; then
  pveam download "${template_storage}" "${template}"
fi

echo "Creating LXC ${ctid}..."
pct create "${ctid}" "${template_storage}:vztmpl/${template}" \
  --hostname "${hostname}" \
  --cores "${cores}" \
  --memory "${memory}" \
  --swap "${swap}" \
  --rootfs "${container_storage}:${disk}" \
  --net0 "name=eth0,bridge=${bridge},ip=dhcp,firewall=1" \
  --unprivileged 1 \
  --onboot 1 \
  --start 1
created_ctid="${ctid}"

echo "Waiting for the container network..."
network_ready="no"
for _ in $(seq 1 30); do
  if pct exec "${ctid}" -- sh -c 'ip route | grep -q default' >/dev/null 2>&1; then
    network_ready="yes"
    break
  fi
  sleep 2
done
[[ "${network_ready}" == "yes" ]] || fail "The LXC did not receive a network connection."

echo "Installing Fire Upload ${release_tag}..."
pct exec "${ctid}" -- mkdir -p /root/fire-upload-install
pct push "${ctid}" "${temporary}/fire-upload.tar.gz" /root/fire-upload.tar.gz --perms 0600
pct exec "${ctid}" -- tar -xzf /root/fire-upload.tar.gz -C /root/fire-upload-install
pct exec "${ctid}" -- env \
  FIRE_UPLOAD_REPO="${repo}" \
  FIRE_UPLOAD_PUBLIC_URL="${public_url}" \
  FIRE_UPLOAD_RELEASE_TAG="${release_tag}" \
  FIRE_UPLOAD_GITHUB_TOKEN="${github_token}" \
  FIRE_UPLOAD_PR_GITHUB_TOKEN="${FIRE_UPLOAD_PR_GITHUB_TOKEN:-}" \
  DUCKDNS_SUBDOMAIN="${duckdns_subdomain}" \
  DUCKDNS_TOKEN="${duckdns_token}" \
  bash /root/fire-upload-install/install.sh

ip_address="$(pct exec "${ctid}" -- hostname -I | awk '{ print $1 }')"
created_ctid=""
trap - ERR

echo
echo "Fire Upload was installed successfully."
echo "LXC: ${ctid}"
echo "Local address: ${ip_address}"
echo "Public URL: ${public_url}"
echo
echo "Reserve ${ip_address} in the router, then forward TCP ports 80 and 443 to it."
echo "Do not expose the Proxmox dashboard or the app's internal port 8080."
