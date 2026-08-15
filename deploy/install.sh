#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this installer as root inside a Debian guest." >&2
  exit 1
fi

: "${FIRE_UPLOAD_REPO:?Set FIRE_UPLOAD_REPO to owner/repository}"
: "${FIRE_UPLOAD_PUBLIC_URL:?Set FIRE_UPLOAD_PUBLIC_URL, for example https://name.duckdns.org}"
: "${DUCKDNS_SUBDOMAIN:?Set DUCKDNS_SUBDOMAIN without .duckdns.org}"
: "${DUCKDNS_TOKEN:?Set DUCKDNS_TOKEN}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for required in fire-upload.service update.sh duckdns-update.sh duckdns-update.service duckdns-update.timer; do
  [[ -f "${script_dir}/${required}" ]] || { echo "Missing deploy/${required}" >&2; exit 1; }
done

apt-get update
apt-get install -y ca-certificates caddy curl jq openssl
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

if ! id fire-upload >/dev/null 2>&1; then
  useradd --system --home /var/lib/fire-upload --shell /usr/sbin/nologin fire-upload
fi
install -d -o fire-upload -g fire-upload -m 0750 /var/lib/fire-upload /var/lib/fire-upload/files
install -d -o root -g root -m 0755 /opt/fire-upload/releases

upload_token="${FIRE_UPLOAD_TOKEN:-$(openssl rand -hex 32)}"
cat >/etc/fire-upload.env <<EOF
FIRE_UPLOAD_TOKEN=${upload_token}
FIRE_UPLOAD_PUBLIC_URL=${FIRE_UPLOAD_PUBLIC_URL}
FIRE_UPLOAD_PORT=8080
FIRE_UPLOAD_DATA_DIR=/var/lib/fire-upload
FIRE_UPLOAD_MAX_BYTES=${FIRE_UPLOAD_MAX_BYTES:-524288000}
FIRE_UPLOAD_GITHUB_TOKEN=${FIRE_UPLOAD_PR_GITHUB_TOKEN:-}
FIRE_UPLOAD_PR_POLL_MINUTES=${FIRE_UPLOAD_PR_POLL_MINUTES:-60}
FIRE_UPLOAD_CLEANUP_MINUTES=${FIRE_UPLOAD_CLEANUP_MINUTES:-10}
EOF
chmod 0600 /etc/fire-upload.env

cat >/etc/fire-upload-release.env <<EOF
FIRE_UPLOAD_REPO=${FIRE_UPLOAD_REPO}
FIRE_UPLOAD_GITHUB_TOKEN=${FIRE_UPLOAD_GITHUB_TOKEN:-}
EOF
chmod 0600 /etc/fire-upload-release.env

cat >/etc/fire-upload-duckdns.env <<EOF
DUCKDNS_SUBDOMAIN=${DUCKDNS_SUBDOMAIN}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN}
EOF
chmod 0600 /etc/fire-upload-duckdns.env

install -m 0644 "${script_dir}/fire-upload.service" /etc/systemd/system/fire-upload.service
install -m 0755 "${script_dir}/update.sh" /usr/local/sbin/fire-upload-update
install -m 0755 "${script_dir}/duckdns-update.sh" /usr/local/sbin/fire-upload-duckdns-update
install -m 0644 "${script_dir}/duckdns-update.service" /etc/systemd/system/fire-upload-duckdns-update.service
install -m 0644 "${script_dir}/duckdns-update.timer" /etc/systemd/system/fire-upload-duckdns-update.timer

hostname="${FIRE_UPLOAD_PUBLIC_URL#*://}"
hostname="${hostname%%/*}"
cat >/etc/caddy/Caddyfile <<EOF
${hostname} {
  reverse_proxy 127.0.0.1:8080
}
EOF

systemctl daemon-reload
systemctl enable fire-upload fire-upload-duckdns-update.timer caddy
/usr/local/sbin/fire-upload-duckdns-update
/usr/local/sbin/fire-upload-update
systemctl restart caddy
systemctl start fire-upload-duckdns-update.timer

cat <<EOF

Fire Upload is installed.
Public URL: ${FIRE_UPLOAD_PUBLIC_URL}
Upload token: ${upload_token}

Forward TCP ports 80 and 443 from the router to this guest.
The installer cannot detect carrier-grade NAT; compare the router WAN address
with a public-IP lookup. If they differ, direct DuckDNS hosting needs IPv6,
a public IP from the ISP, or an external relay.
EOF
