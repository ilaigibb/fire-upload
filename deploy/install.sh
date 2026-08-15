#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this installer as root inside a Debian guest." >&2
  exit 1
fi

: "${FIRE_UPLOAD_REPO:?FIRE_UPLOAD_REPO is required}"
: "${FIRE_UPLOAD_PUBLIC_URL:?FIRE_UPLOAD_PUBLIC_URL is required}"
: "${FIRE_UPLOAD_RELEASE_TAG:?FIRE_UPLOAD_RELEASE_TAG is required}"
: "${DUCKDNS_SUBDOMAIN:?DUCKDNS_SUBDOMAIN is required}"
: "${DUCKDNS_TOKEN:?DUCKDNS_TOKEN is required}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for required in server.js fire-upload.service update.sh fire-upload-update.service fire-upload-update.timer duckdns-update.sh duckdns-update.service duckdns-update.timer; do
  [[ -f "${script_dir}/${required}" ]] || { echo "Release is missing ${required}." >&2; exit 1; }
done

echo "Installing system packages..."
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

release_dir="/opt/fire-upload/releases/${FIRE_UPLOAD_RELEASE_TAG}"
install -d -o root -g root -m 0755 "${release_dir}"
install -o root -g root -m 0644 "${script_dir}/server.js" "${release_dir}/server.js"
ln -sfn "${release_dir}" /opt/fire-upload/current

install -m 0644 "${script_dir}/fire-upload.service" /etc/systemd/system/fire-upload.service
install -m 0755 "${script_dir}/update.sh" /usr/local/sbin/fire-upload-update
install -m 0644 "${script_dir}/fire-upload-update.service" /etc/systemd/system/fire-upload-update.service
install -m 0644 "${script_dir}/fire-upload-update.timer" /etc/systemd/system/fire-upload-update.timer
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
systemctl enable fire-upload fire-upload-update.timer fire-upload-duckdns-update.timer caddy
/usr/local/sbin/fire-upload-duckdns-update
systemctl restart fire-upload caddy
systemctl start fire-upload-update.timer fire-upload-duckdns-update.timer

curl -fsS --retry 15 --retry-delay 1 http://127.0.0.1:8080/health >/dev/null
rm -rf /root/fire-upload-install /root/fire-upload.tar.gz

cat <<EOF

Fire Upload is installed.
Public URL: ${FIRE_UPLOAD_PUBLIC_URL}
Upload token: ${upload_token}

Save the upload token now; it is also stored in /etc/fire-upload.env.
Updates are checked automatically each day. Run fire-upload-update for a manual update.
EOF
