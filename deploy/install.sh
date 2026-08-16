#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this installer as root inside a Debian guest." >&2
  exit 1
fi

if [[ "${FILE_UPLOAD_LXC_INSTALL:-}" != "1" ]]; then
  echo "This guest installer may only be started by the File Upload Proxmox installer." >&2
  exit 1
fi
if command -v pveversion >/dev/null 2>&1; then
  echo "Refusing to run the guest installer on a Proxmox host." >&2
  exit 1
fi
if [[ "$(systemd-detect-virt --container 2>/dev/null || true)" != "lxc" ]]; then
  echo "This installer must run inside the newly created LXC." >&2
  exit 1
fi
source /etc/os-release
if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "13" ]]; then
  echo "This installer requires Debian 13." >&2
  exit 1
fi

: "${FILE_UPLOAD_REPO:?FILE_UPLOAD_REPO is required}"
: "${FILE_UPLOAD_PUBLIC_URL:?FILE_UPLOAD_PUBLIC_URL is required}"
: "${FILE_UPLOAD_RELEASE_TAG:?FILE_UPLOAD_RELEASE_TAG is required}"
: "${DUCKDNS_SUBDOMAIN:?DUCKDNS_SUBDOMAIN is required}"
: "${DUCKDNS_TOKEN:?DUCKDNS_TOKEN is required}"
[[ "${FILE_UPLOAD_RELEASE_TAG}" =~ ^v[A-Za-z0-9._-]+$ ]] || { echo "Invalid release tag." >&2; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for required in server.js file-upload.service update.sh file-upload-update.service file-upload-update.timer duckdns-update.sh duckdns-update.service duckdns-update.timer; do
  [[ -f "${script_dir}/${required}" ]] || { echo "Release is missing ${required}." >&2; exit 1; }
done

echo "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates caddy curl gnupg jq openssl
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
  gpg --dearmor --yes -o /usr/share/keyrings/nodesource.gpg
chmod 0644 /usr/share/keyrings/nodesource.gpg
cat >/etc/apt/sources.list.d/nodesource.sources <<'EOF'
Types: deb
URIs: https://deb.nodesource.com/node_24.x
Suites: nodistro
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/nodesource.gpg
EOF
apt-get update
apt-get install -y nodejs
[[ "$(node --version)" == v24.* ]] || { echo "Node.js 24 installation failed." >&2; exit 1; }

if ! id file-upload >/dev/null 2>&1; then
  useradd --system --home /var/lib/file-upload --shell /usr/sbin/nologin file-upload
fi
install -d -o file-upload -g file-upload -m 0750 /var/lib/file-upload /var/lib/file-upload/files
install -d -o root -g root -m 0755 /opt/file-upload/releases

upload_token="${FILE_UPLOAD_TOKEN:-$(openssl rand -hex 32)}"
cat >/etc/file-upload.env <<EOF
FILE_UPLOAD_TOKEN=${upload_token}
FILE_UPLOAD_PUBLIC_URL=${FILE_UPLOAD_PUBLIC_URL}
FILE_UPLOAD_PORT=8080
FILE_UPLOAD_DATA_DIR=/var/lib/file-upload
FILE_UPLOAD_MAX_BYTES=${FILE_UPLOAD_MAX_BYTES:-524288000}
FILE_UPLOAD_GITHUB_TOKEN=${FILE_UPLOAD_PR_GITHUB_TOKEN:-}
FILE_UPLOAD_PR_POLL_MINUTES=${FILE_UPLOAD_PR_POLL_MINUTES:-60}
FILE_UPLOAD_CLEANUP_MINUTES=${FILE_UPLOAD_CLEANUP_MINUTES:-10}
EOF
chmod 0600 /etc/file-upload.env

cat >/etc/file-upload-release.env <<EOF
FILE_UPLOAD_REPO=${FILE_UPLOAD_REPO}
FILE_UPLOAD_GITHUB_TOKEN=${FILE_UPLOAD_GITHUB_TOKEN:-}
EOF
chmod 0600 /etc/file-upload-release.env

cat >/etc/file-upload-duckdns.env <<EOF
DUCKDNS_SUBDOMAIN=${DUCKDNS_SUBDOMAIN}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
EOF
chmod 0600 /etc/file-upload-duckdns.env

release_dir="/opt/file-upload/releases/${FILE_UPLOAD_RELEASE_TAG}"
install -d -o root -g root -m 0755 "${release_dir}"
install -o root -g root -m 0644 "${script_dir}/server.js" "${release_dir}/server.js"
ln -sfn "${release_dir}" /opt/file-upload/current

install -m 0644 "${script_dir}/file-upload.service" /etc/systemd/system/file-upload.service
install -m 0755 "${script_dir}/update.sh" /usr/local/sbin/file-upload-update
install -m 0644 "${script_dir}/file-upload-update.service" /etc/systemd/system/file-upload-update.service
install -m 0644 "${script_dir}/file-upload-update.timer" /etc/systemd/system/file-upload-update.timer
install -m 0755 "${script_dir}/duckdns-update.sh" /usr/local/sbin/file-upload-duckdns-update
install -m 0644 "${script_dir}/duckdns-update.service" /etc/systemd/system/file-upload-duckdns-update.service
install -m 0644 "${script_dir}/duckdns-update.timer" /etc/systemd/system/file-upload-duckdns-update.timer

hostname="${FILE_UPLOAD_PUBLIC_URL#*://}"
hostname="${hostname%%/*}"
cat >/etc/caddy/Caddyfile <<EOF
${hostname} {
  reverse_proxy 127.0.0.1:8080
}
EOF

systemctl daemon-reload
systemctl enable file-upload file-upload-update.timer file-upload-duckdns-update.timer caddy
/usr/local/sbin/file-upload-duckdns-update
systemctl restart file-upload caddy
systemctl start file-upload-update.timer file-upload-duckdns-update.timer

curl -fsS --retry 15 --retry-delay 1 http://127.0.0.1:8080/health >/dev/null
rm -rf -- /root/file-upload-install
rm -f -- /root/file-upload.tar.gz /root/file-upload-install.env

cat <<EOF

File Upload is installed.
Public URL: ${FILE_UPLOAD_PUBLIC_URL}
Upload token: ${upload_token}

Save the upload token now; it is also stored in /etc/file-upload.env.
Updates are checked automatically each day. Run file-upload-update for a manual update.
EOF
