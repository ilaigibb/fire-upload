#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this updater as root." >&2
  exit 1
fi
if command -v pveversion >/dev/null 2>&1 || [[ "$(systemd-detect-virt --container 2>/dev/null || true)" != "lxc" ]]; then
  echo "Refusing to run the updater outside the Fire Upload LXC." >&2
  exit 1
fi

source /etc/fire-upload-release.env
: "${FIRE_UPLOAD_REPO:?FIRE_UPLOAD_REPO is required}"

temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT
api_config="${temporary}/github-api.conf"
asset_config="${temporary}/github-asset.conf"
{
  printf 'header = "Accept: application/vnd.github+json"\n'
  [[ -z "${FIRE_UPLOAD_GITHUB_TOKEN:-}" ]] || printf 'header = "Authorization: Bearer %s"\n' "${FIRE_UPLOAD_GITHUB_TOKEN}"
} >"${api_config}"
{
  printf 'header = "Accept: application/octet-stream"\n'
  [[ -z "${FIRE_UPLOAD_GITHUB_TOKEN:-}" ]] || printf 'header = "Authorization: Bearer %s"\n' "${FIRE_UPLOAD_GITHUB_TOKEN}"
} >"${asset_config}"
chmod 0600 "${api_config}" "${asset_config}"

release_json="$(curl --config "${api_config}" -fsSL "https://api.github.com/repos/${FIRE_UPLOAD_REPO}/releases/latest")"
tag="$(jq -er '.tag_name' <<<"${release_json}")"
asset_url="$(jq -er '.assets[] | select(.name == "fire-upload.tar.gz") | .url' <<<"${release_json}")"
release_dir="/opt/fire-upload/releases/${tag}"

if [[ -d "${release_dir}" ]]; then
  echo "Fire Upload ${tag} is already installed."
  exit 0
fi

curl --config "${asset_config}" -fsSL "${asset_url}" -o "${temporary}/fire-upload.tar.gz"
if tar -tzf "${temporary}/fire-upload.tar.gz" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo "Release archive contains an unsafe path." >&2
  exit 1
fi
tar -xzf "${temporary}/fire-upload.tar.gz" -C "${temporary}"
for required in server.js update.sh fire-upload.service fire-upload-update.service fire-upload-update.timer; do
  [[ -f "${temporary}/${required}" ]] || { echo "Release is missing ${required}" >&2; exit 1; }
done

previous="$(readlink -f /opt/fire-upload/current 2>/dev/null || true)"
mkdir -p /opt/fire-upload/releases
mv "${temporary}" "${release_dir}"
trap - EXIT
ln -sfn "${release_dir}" /opt/fire-upload/current
chown -R root:root "${release_dir}"

install -m 0755 "${release_dir}/update.sh" /usr/local/sbin/fire-upload-update
install -m 0644 "${release_dir}/fire-upload.service" /etc/systemd/system/fire-upload.service
install -m 0644 "${release_dir}/fire-upload-update.service" /etc/systemd/system/fire-upload-update.service
install -m 0644 "${release_dir}/fire-upload-update.timer" /etc/systemd/system/fire-upload-update.timer
if [[ -f "${release_dir}/duckdns-update.sh" ]]; then
  install -m 0755 "${release_dir}/duckdns-update.sh" /usr/local/sbin/fire-upload-duckdns-update
  install -m 0644 "${release_dir}/duckdns-update.service" /etc/systemd/system/fire-upload-duckdns-update.service
  install -m 0644 "${release_dir}/duckdns-update.timer" /etc/systemd/system/fire-upload-duckdns-update.timer
fi
systemctl daemon-reload
systemctl enable fire-upload-update.timer fire-upload-duckdns-update.timer >/dev/null

systemctl restart fire-upload
if ! curl -fsS --retry 10 --retry-delay 1 http://127.0.0.1:8080/health >/dev/null; then
  if [[ -n "${previous}" && -d "${previous}" ]]; then
    ln -sfn "${previous}" /opt/fire-upload/current
    systemctl restart fire-upload
  fi
  echo "Update failed its health check; restored the previous release." >&2
  exit 1
fi

echo "Updated Fire Upload to ${tag}."
