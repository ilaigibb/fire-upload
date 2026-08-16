#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP="File Upload"
DEFAULT_CPU=1
DEFAULT_RAM=512
DEFAULT_SWAP=256
DEFAULT_DISK=8

created_ctid=""
temporary=""
log_file=""

cleanup() {
  [[ -z "${temporary}" || ! -d "${temporary}" ]] || rm -rf -- "${temporary}"
}

show_failure_context() {
  if [[ -n "${created_ctid}" ]] && pct status "${created_ctid}" >/dev/null 2>&1; then
    echo "LXC ${created_ctid} was kept for inspection. Nothing was automatically deleted." >&2
    echo "Inspect it with: pct enter ${created_ctid}" >&2
    echo "Remove it only if you choose: pct stop ${created_ctid}; pct destroy ${created_ctid}" >&2
  fi
  [[ -z "${log_file}" ]] || echo "Installer log: ${log_file}" >&2
}

fail() {
  echo "Error: $*" >&2
  show_failure_context
  exit 1
}

on_error() {
  local exit_code=$?
  local line_number="$1"
  trap - ERR
  echo "Installation stopped unexpectedly near line ${line_number}." >&2
  show_failure_context
  exit "${exit_code}"
}

on_signal() {
  trap - INT TERM
  echo >&2
  echo "Installation cancelled." >&2
  show_failure_context
  exit 130
}

trap 'on_error $LINENO' ERR
trap on_signal INT TERM
trap cleanup EXIT

require_host() {
  [[ -n "${BASH_VERSION:-}" ]] || fail "Run the installer with Bash."
  [[ "$(id -u)" -eq 0 ]] || fail "Open Proxmox → your node → Shell and run the installer as root."

  if [[ "$(ps -o comm= -p "${PPID}" 2>/dev/null | xargs)" == "sudo" ]]; then
    fail "Do not run this through sudo. Run 'sudo -i' first, then start the installer from the root shell."
  fi

  [[ -t 0 && -r /dev/tty ]] || fail "An interactive root terminal is required. Use the Proxmox node shell or a root SSH session."
  command -v pveversion >/dev/null 2>&1 || fail "This is not a Proxmox VE host. Do not run the host installer inside an LXC."

  local pve_version
  pve_version="$(pveversion | awk -F'[/ -]' 'NR == 1 { print $2 }')"
  if [[ "${pve_version}" =~ ^8\.([0-9]+) ]] && ((BASH_REMATCH[1] >= 4 && BASH_REMATCH[1] <= 9)); then
    :
  elif [[ "${pve_version}" =~ ^9\.([0-9]+) ]] && ((BASH_REMATCH[1] <= 2)); then
    :
  else
    fail "Proxmox VE ${pve_version:-unknown} is not supported. Supported versions are 8.4-8.9 and 9.0-9.2."
  fi

  [[ "$(dpkg --print-architecture)" == "amd64" ]] || fail "This release currently supports amd64 Proxmox hosts only."
  [[ -f /etc/pve/storage.cfg ]] || fail "The Proxmox cluster filesystem is unavailable: /etc/pve/storage.cfg is missing."
  mountpoint -q /etc/pve || fail "The Proxmox cluster filesystem is not mounted at /etc/pve."

  local command_name
  for command_name in awk curl cut find flock grep hostname ip mountpoint pct pveam pvesh pvesm python3 qm sed seq sort tar tee timeout wc xargs; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "The Proxmox host is missing required command: ${command_name}"
  done

  if [[ -f /etc/pve/corosync.conf ]]; then
    command -v pvecm >/dev/null 2>&1 || fail "This clustered host is missing pvecm."
    pvecm status | awk -F: '/^Quorate/ { gsub(/ /, "", $2); found=1; exit ($2 == "Yes" ? 0 : 1) } END { if (!found) exit 1 }' || \
      fail "The Proxmox cluster is not quorate. Restore quorum before creating a container."
  fi

  exec 9>/run/lock/file-upload-installer.lock
  flock -n 9 || fail "Another File Upload installer is already running on this host."
}

prompt() {
  local message="$1"
  local default_value="${2:-}"
  local value

  if command -v whiptail >/dev/null 2>&1; then
    value="$(whiptail --backtitle "File Upload Proxmox Installer" --title "${APP}" \
      --inputbox "${message}" 10 72 "${default_value}" 3>&1 1>&2 2>&3)" || exit 0
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
    value="$(whiptail --backtitle "File Upload Proxmox Installer" --title "${APP}" \
      --passwordbox "${message}" 10 72 3>&1 1>&2 2>&3)" || exit 0
  else
    read -r -s -p "${message}: " value </dev/tty
    echo >/dev/tty
  fi

  printf '%s' "${value}"
}

choose() {
  local title="$1"
  local message="$2"
  shift 2

  if command -v whiptail >/dev/null 2>&1; then
    whiptail --backtitle "File Upload Proxmox Installer" --title "${title}" \
      --menu "${message}" 18 72 8 "$@" 3>&1 1>&2 2>&3 || exit 0
    return
  fi

  local options=("$@")
  local index=0
  local number=1
  while ((index < ${#options[@]})); do
    printf '%s) %s - %s\n' "${number}" "${options[index]}" "${options[index + 1]}" >/dev/tty
    index=$((index + 2))
    number=$((number + 1))
  done

  local selected
  read -r -p "Choose [1]: " selected </dev/tty
  selected="${selected:-1}"
  [[ "${selected}" =~ ^[0-9]+$ ]] || fail "Invalid selection."
  index=$(((selected - 1) * 2))
  ((index >= 0 && index < ${#options[@]})) || fail "Invalid selection."
  printf '%s' "${options[index]}"
}

select_storage() {
  local content="$1"
  local label="$2"
  local preferred="${3:-}"
  local rows
  rows="$(pvesm status -content "${content}" 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 "|" $2 "|" $6 }')"
  [[ -n "${rows}" ]] || fail "No active Proxmox storage supports ${label}."

  if [[ -n "${preferred}" ]]; then
    cut -d'|' -f1 <<<"${rows}" | grep -Fxq "${preferred}" || fail "Storage ${preferred} does not support ${label} or is inactive."
    printf '%s' "${preferred}"
    return
  fi

  local count
  count="$(wc -l <<<"${rows}" | xargs)"
  if [[ "${count}" -eq 1 ]]; then
    cut -d'|' -f1 <<<"${rows}"
    return
  fi

  local menu=()
  local name type free_kib free_text
  while IFS='|' read -r name type free_kib; do
    free_text="unknown free space"
    [[ "${free_kib}" =~ ^[0-9]+$ ]] && free_text="$((free_kib / 1024 / 1024)) GiB free"
    menu+=("${name}" "${type}, ${free_text}")
  done <<<"${rows}"
  choose "${label}" "Choose where ${label,,} should be stored." "${menu[@]}"
}

select_bridge() {
  local preferred="${1:-}"
  if [[ -n "${preferred}" ]]; then
    [[ -d "/sys/class/net/${preferred}" ]] || fail "Network bridge ${preferred} does not exist."
    printf '%s' "${preferred}"
    return
  fi

  local bridges
  bridges="$(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | grep -E '^(vmbr|xapi|br)' || true)"
  [[ -n "${bridges}" ]] || fail "No Proxmox network bridge was found."
  if [[ "$(wc -l <<<"${bridges}" | xargs)" -eq 1 ]]; then
    printf '%s' "${bridges}"
    return
  fi

  local menu=()
  local bridge_name
  while IFS= read -r bridge_name; do
    menu+=("${bridge_name}" "Network bridge")
  done <<<"${bridges}"
  choose "Network bridge" "Choose the bridge used by the LXC." "${menu[@]}"
}

ctid_in_use() {
  local ctid="$1"
  local cluster_ids
  cluster_ids="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | python3 -c '
import json, sys
try:
    resources = json.load(sys.stdin)
except json.JSONDecodeError:
    resources = []
for resource in resources:
    vmid = resource.get("vmid")
    if isinstance(vmid, int):
        print(vmid)
' || true)"
  grep -qx "${ctid}" <<<"${cluster_ids}" && return 0

  local node_dir
  for node_dir in /etc/pve/nodes/*/; do
    [[ -f "${node_dir}qemu-server/${ctid}.conf" || -f "${node_dir}lxc/${ctid}.conf" ]] && return 0
  done
  return 1
}

validate_static_network() {
  local address="$1"
  local gateway="$2"
  local nameserver="$3"
  python3 - "${address}" "${gateway}" "${nameserver}" <<'PY'
import ipaddress
import sys

interface = ipaddress.ip_interface(sys.argv[1])
gateway = ipaddress.ip_address(sys.argv[2])
if interface.version != 4 or gateway.version != 4 or gateway not in interface.network:
    raise SystemExit("The address and gateway must be IPv4 addresses on the same network.")
if sys.argv[3]:
    ipaddress.ip_address(sys.argv[3])
PY
}

github_curl_config() {
  local path="$1"
  local accept="$2"
  local token="$3"
  {
    printf 'header = "Accept: %s"\n' "${accept}"
    [[ -z "${token}" ]] || printf 'header = "Authorization: Bearer %s"\n' "${token}"
  } >"${path}"
  chmod 0600 "${path}"
}

require_host

mode="${FILE_UPLOAD_INSTALL_MODE:-}"
[[ -n "${mode}" ]] || mode="$(choose "Install mode" "Choose how much of the LXC configuration to customize." \
  "default" "1 CPU, 512 MiB RAM, 8 GiB disk, DHCP" \
  "advanced" "Choose resources, storage, bridge, and IP configuration")"
[[ "${mode}" == "default" || "${mode}" == "advanced" ]] || fail "Install mode must be default or advanced."

repo="${FILE_UPLOAD_REPO:-ilaigibb/file-upload}"
[[ "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Repository must look like owner/repository."

github_token="${FILE_UPLOAD_GITHUB_TOKEN:-}"
[[ -n "${github_token}" ]] || github_token="$(prompt_secret "GitHub token for the private File Upload repository")"
[[ -n "${github_token}" ]] || fail "A GitHub token is required while the repository is private."
[[ "${github_token}" != *$'\n'* && "${github_token}" != *$'\r'* ]] || fail "GitHub token is invalid."

duckdns_subdomain="${DUCKDNS_SUBDOMAIN:-}"
[[ -n "${duckdns_subdomain}" ]] || duckdns_subdomain="$(prompt "DuckDNS subdomain without .duckdns.org")"
duckdns_subdomain="${duckdns_subdomain,,}"
[[ "${duckdns_subdomain}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "DuckDNS subdomain is invalid."

duckdns_token="${DUCKDNS_TOKEN:-}"
[[ -n "${duckdns_token}" ]] || duckdns_token="$(prompt_secret "DuckDNS token")"
[[ "${duckdns_token}" =~ ^[A-Za-z0-9-]+$ ]] || fail "DuckDNS token is invalid."

ctid="${FILE_UPLOAD_CTID:-$(pvesh get /cluster/nextid)}"
hostname="${FILE_UPLOAD_HOSTNAME:-file-upload}"
cores="${FILE_UPLOAD_CORES:-${DEFAULT_CPU}}"
memory="${FILE_UPLOAD_MEMORY:-${DEFAULT_RAM}}"
swap="${FILE_UPLOAD_SWAP:-${DEFAULT_SWAP}}"
disk="${FILE_UPLOAD_DISK:-${DEFAULT_DISK}}"

if [[ "${mode}" == "advanced" ]]; then
  ctid="$(prompt "Container ID" "${ctid}")"
  hostname="$(prompt "Hostname" "${hostname}")"
  cores="$(prompt "CPU cores" "${cores}")"
  memory="$(prompt "Memory in MiB" "${memory}")"
  swap="$(prompt "Swap in MiB" "${swap}")"
  disk="$(prompt "Disk size in GiB (this limits total uploaded-file storage)" "${disk}")"
fi

[[ "${ctid}" =~ ^[0-9]+$ && "${ctid}" -ge 100 && "${ctid}" -le 999999999 ]] || \
  fail "Container ID must be between 100 and 999999999."
ctid_in_use "${ctid}" && fail "Container or VM ID ${ctid} is already in use anywhere in the cluster."
[[ "${hostname}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ && ${#hostname} -le 63 ]] || fail "Hostname is invalid."
[[ "${cores}" =~ ^[0-9]+$ && "${cores}" -ge 1 ]] || fail "CPU cores must be at least 1."
[[ "${memory}" =~ ^[0-9]+$ && "${memory}" -ge 256 ]] || fail "Memory must be at least 256 MiB."
[[ "${swap}" =~ ^[0-9]+$ ]] || fail "Swap must be zero or a positive whole number."
[[ "${disk}" =~ ^[0-9]+$ && "${disk}" -ge 4 ]] || fail "Disk size must be at least 4 GiB."

container_storage="$(select_storage rootdir "container data" "${FILE_UPLOAD_STORAGE:-}")"
template_storage="$(select_storage vztmpl "Debian template" "${FILE_UPLOAD_TEMPLATE_STORAGE:-}")"
preferred_bridge="${FILE_UPLOAD_BRIDGE:-}"
[[ -n "${preferred_bridge}" || "${mode}" != "default" ]] || preferred_bridge="vmbr0"
bridge="$(select_bridge "${preferred_bridge}")"

network_mode="${FILE_UPLOAD_NETWORK_MODE:-dhcp}"
ip_address=""
gateway=""
nameserver=""
if [[ "${mode}" == "advanced" && -z "${FILE_UPLOAD_NETWORK_MODE:-}" ]]; then
  network_mode="$(choose "Network configuration" "DHCP is simplest; reserve the assigned address in your router afterward." \
    "dhcp" "Get an address from the router" \
    "static" "Assign a fixed IPv4 address now")"
fi
if [[ "${network_mode}" == "static" ]]; then
  ip_address="${FILE_UPLOAD_IP:-}"
  [[ -n "${ip_address}" ]] || ip_address="$(prompt "Static IPv4 address with CIDR, for example 192.168.1.50/24")"
  gateway="${FILE_UPLOAD_GATEWAY:-}"
  [[ -n "${gateway}" ]] || gateway="$(prompt "IPv4 gateway, for example 192.168.1.1")"
  nameserver="${FILE_UPLOAD_NAMESERVER:-}"
  [[ -n "${nameserver}" ]] || nameserver="$(prompt "DNS server" "${gateway}")"
  validate_static_network "${ip_address}" "${gateway}" "${nameserver}" || fail "Static network configuration is invalid."
elif [[ "${network_mode}" != "dhcp" ]]; then
  fail "Network mode must be dhcp or static."
fi

free_kib="$(pvesm status -storage "${container_storage}" | awk 'NR > 1 { print $6; exit }')"
requested_kib=$((disk * 1024 * 1024))
[[ "${free_kib}" =~ ^[0-9]+$ ]] || fail "Could not determine free space on ${container_storage}."
((free_kib >= requested_kib)) || fail "Storage ${container_storage} has less than ${disk} GiB available."

public_url="https://${duckdns_subdomain}.duckdns.org"
network_summary="DHCP on ${bridge}"
[[ "${network_mode}" == "dhcp" ]] || network_summary="${ip_address}, gateway ${gateway}, on ${bridge}"

echo
echo "File Upload installation plan"
echo "  Proxmox node:     $(hostname)"
echo "  New LXC:          ${ctid} (${hostname})"
echo "  Resources:        ${cores} CPU, ${memory} MiB RAM, ${swap} MiB swap"
echo "  Uploaded data:    ${disk} GiB on ${container_storage}"
echo "  Debian template:  ${template_storage}"
echo "  Network:          ${network_summary}"
echo "  Public URL:       ${public_url}"
echo "  Release source:   ${repo}"
echo
echo "The installer creates only LXC ${ctid}. It does not modify existing guests,"
echo "reconfigure Proxmox storage, open router ports, or automatically delete a failed LXC."
echo
read -r -p "Create this LXC and install File Upload? [y/N]: " confirmation </dev/tty
[[ "${confirmation}" =~ ^[Yy]$ ]] || exit 0

log_file="/var/log/file-upload-install-${ctid}-$(date +%Y%m%d-%H%M%S).log"
touch "${log_file}"
chmod 0600 "${log_file}"
exec > >(tee -a "${log_file}") 2>&1

temporary="$(mktemp -d /tmp/file-upload-install.XXXXXX)"
github_api_config="${temporary}/github-api.conf"
github_asset_config="${temporary}/github-asset.conf"
github_curl_config "${github_api_config}" "application/vnd.github+json" "${github_token}"
github_curl_config "${github_asset_config}" "application/octet-stream" "${github_token}"

echo "Checking the GitHub release..."
release_json="$(curl --config "${github_api_config}" --connect-timeout 10 --retry 3 --retry-all-errors -fsSL \
  "https://api.github.com/repos/${repo}/releases/latest")" || fail "Could not read the latest release. Check the repository token."
release_values="$(python3 -c '
import json, sys
release = json.load(sys.stdin)
asset = next((item for item in release.get("assets", []) if item.get("name") == "file-upload.tar.gz"), None)
if not asset:
    raise SystemExit("The latest release has no file-upload.tar.gz asset.")
print(release["tag_name"])
print(asset["url"])
' <<<"${release_json}")"
release_tag="$(sed -n '1p' <<<"${release_values}")"
asset_url="$(sed -n '2p' <<<"${release_values}")"
[[ "${release_tag}" =~ ^v[A-Za-z0-9._-]+$ ]] || fail "The latest release tag is invalid."
curl --config "${github_asset_config}" --connect-timeout 10 --retry 3 --retry-all-errors -fsSL \
  "${asset_url}" -o "${temporary}/file-upload.tar.gz"
if tar -tzf "${temporary}/file-upload.tar.gz" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  fail "The release archive contains an unsafe path."
fi
tar -tzf "${temporary}/file-upload.tar.gz" | grep -Eq '(^|/)install\.sh$' || fail "The release is missing its guest installer."

echo "Checking DuckDNS credentials..."
duckdns_response="$(curl --connect-timeout 10 --retry 3 --retry-all-errors -fsS \
  "https://www.duckdns.org/update?domains=${duckdns_subdomain}&token=${duckdns_token}&ip=")"
[[ "${duckdns_response}" == "OK" ]] || fail "DuckDNS rejected the subdomain or token."

echo "Preparing the Debian 13 template..."
template="$(pveam list "${template_storage}" 2>/dev/null | \
  awk '/debian-13-standard_.*_amd64\.tar\.(zst|xz|gz)$/ { sub(/^.*\//, "", $1); print $1 }' | sort -V | tail -n 1)"
if [[ -z "${template}" ]]; then
  timeout 60 pveam update >/dev/null || fail "The template catalog could not be updated. Check the Proxmox host network."
  template="$(pveam available --section system | \
    awk '/debian-13-standard_.*_amd64\.tar\.(zst|xz|gz)$/ { print $2 }' | sort -V | tail -n 1)"
fi
[[ -n "${template}" ]] || fail "No Debian 13 amd64 LXC template is available."

exec 8>"/tmp/template.${template}.lock"
flock -w 300 8 || fail "Another process is using the Debian template. Try again later."
if ! pveam list "${template_storage}" | awk 'NR > 1 { print $1 }' | grep -Fxq "${template_storage}:vztmpl/${template}"; then
  download_succeeded="no"
  for attempt in 1 2 3; do
    if pveam download "${template_storage}" "${template}"; then
      download_succeeded="yes"
      break
    fi
    sleep $((attempt * 3))
  done
  [[ "${download_succeeded}" == "yes" ]] || fail "The Debian template could not be downloaded after three attempts."
fi

net0="name=eth0,bridge=${bridge},firewall=1"
if [[ "${network_mode}" == "dhcp" ]]; then
  net0+=",ip=dhcp"
else
  net0+=",ip=${ip_address},gw=${gateway}"
fi

echo "Creating LXC ${ctid}..."
created_ctid="${ctid}"
pct_create=(
  pct create "${ctid}" "${template_storage}:vztmpl/${template}"
  --hostname "${hostname}"
  --ostype debian
  --cores "${cores}"
  --memory "${memory}"
  --swap "${swap}"
  --rootfs "${container_storage}:${disk}"
  --net0 "${net0}"
  --unprivileged 1
  --onboot 1
  --tags file-upload
)
[[ -z "${nameserver}" ]] || pct_create+=(--nameserver "${nameserver}")
"${pct_create[@]}"
pct start "${ctid}"

echo "Waiting for the LXC network..."
network_ready="no"
for _ in $(seq 1 45); do
  if pct exec "${ctid}" -- sh -c 'ip route | grep -q default && getent hosts deb.debian.org >/dev/null' >/dev/null 2>&1; then
    network_ready="yes"
    break
  fi
  sleep 2
done
[[ "${network_ready}" == "yes" ]] || fail "The LXC did not get working network and DNS within 90 seconds."

install_env="${temporary}/install.env"
{
  printf 'FILE_UPLOAD_LXC_INSTALL=1\n'
  printf 'FILE_UPLOAD_REPO=%q\n' "${repo}"
  printf 'FILE_UPLOAD_PUBLIC_URL=%q\n' "${public_url}"
  printf 'FILE_UPLOAD_RELEASE_TAG=%q\n' "${release_tag}"
  printf 'FILE_UPLOAD_GITHUB_TOKEN=%q\n' "${github_token}"
  printf 'FILE_UPLOAD_PR_GITHUB_TOKEN=%q\n' "${FILE_UPLOAD_PR_GITHUB_TOKEN:-}"
  printf 'DUCKDNS_SUBDOMAIN=%q\n' "${duckdns_subdomain}"
  printf 'DUCKDNS_TOKEN=%q\n' "${duckdns_token}"
} >"${install_env}"
chmod 0600 "${install_env}"

echo "Installing File Upload ${release_tag} inside LXC ${ctid}..."
pct exec "${ctid}" -- mkdir -p /root/file-upload-install
pct push "${ctid}" "${temporary}/file-upload.tar.gz" /root/file-upload.tar.gz --perms 0600
pct push "${ctid}" "${install_env}" /root/file-upload-install.env --perms 0600
pct exec "${ctid}" -- tar -xzf /root/file-upload.tar.gz -C /root/file-upload-install
pct exec "${ctid}" -- bash -c \
  'set -a; source /root/file-upload-install.env; set +a; exec bash /root/file-upload-install/install.sh'

lxc_address="$(pct exec "${ctid}" -- hostname -I | awk '{ print $1 }')"
created_ctid=""
trap - ERR INT TERM

echo
echo "File Upload was installed successfully."
echo "  LXC:           ${ctid}"
echo "  Local address: ${lxc_address}"
echo "  Public URL:    ${public_url}"
echo "  Log:           ${log_file}"
echo
if [[ "${network_mode}" == "dhcp" ]]; then
  echo "Reserve ${lxc_address} in the router so it does not change."
fi
echo "Forward router TCP ports 80 and 443 to ${lxc_address}."
echo "Do not expose the Proxmox dashboard or File Upload's internal port 8080."
