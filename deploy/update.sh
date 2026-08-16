#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this updater as root." >&2
  exit 1
fi
if command -v pveversion >/dev/null 2>&1 || [[ "$(systemd-detect-virt --container 2>/dev/null || true)" != "lxc" ]]; then
  echo "Refusing to run the updater outside the File Upload LXC." >&2
  exit 1
fi

source /etc/file-upload-release.env
: "${FILE_UPLOAD_REPO:?FILE_UPLOAD_REPO is required}"

temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT
api_config="${temporary}/github-api.conf"
asset_config="${temporary}/github-asset.conf"
{
  printf 'header = "Accept: application/vnd.github+json"\n'
  [[ -z "${FILE_UPLOAD_GITHUB_TOKEN:-}" ]] || printf 'header = "Authorization: Bearer %s"\n' "${FILE_UPLOAD_GITHUB_TOKEN}"
} >"${api_config}"
{
  printf 'header = "Accept: application/octet-stream"\n'
  [[ -z "${FILE_UPLOAD_GITHUB_TOKEN:-}" ]] || printf 'header = "Authorization: Bearer %s"\n' "${FILE_UPLOAD_GITHUB_TOKEN}"
} >"${asset_config}"
chmod 0600 "${api_config}" "${asset_config}"

release_json="$(curl --config "${api_config}" -fsSL "https://api.github.com/repos/${FILE_UPLOAD_REPO}/releases/latest")"
tag="$(jq -er '.tag_name' <<<"${release_json}")"
asset_url="$(jq -er '.assets[] | select(.name == "file-upload.tar.gz") | .url' <<<"${release_json}")"
release_dir="/opt/file-upload/releases/${tag}"

if [[ -d "${release_dir}" ]]; then
  echo "File Upload ${tag} is already installed."
  exit 0
fi

curl --config "${asset_config}" -fsSL "${asset_url}" -o "${temporary}/file-upload.tar.gz"
if tar -tzf "${temporary}/file-upload.tar.gz" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo "Release archive contains an unsafe path." >&2
  exit 1
fi
tar -xzf "${temporary}/file-upload.tar.gz" -C "${temporary}"
for required in server.js update.sh file-upload.service file-upload-update.service file-upload-update.timer; do
  [[ -f "${temporary}/${required}" ]] || { echo "Release is missing ${required}" >&2; exit 1; }
done

previous="$(readlink -f /opt/file-upload/current 2>/dev/null || true)"
mkdir -p /opt/file-upload/releases
mv "${temporary}" "${release_dir}"
trap - EXIT
ln -sfn "${release_dir}" /opt/file-upload/current
chown -R root:root "${release_dir}"

install -m 0755 "${release_dir}/update.sh" /usr/local/sbin/file-upload-update
install -m 0644 "${release_dir}/file-upload.service" /etc/systemd/system/file-upload.service
install -m 0644 "${release_dir}/file-upload-update.service" /etc/systemd/system/file-upload-update.service
install -m 0644 "${release_dir}/file-upload-update.timer" /etc/systemd/system/file-upload-update.timer
if [[ -f "${release_dir}/duckdns-update.sh" ]]; then
  install -m 0755 "${release_dir}/duckdns-update.sh" /usr/local/sbin/file-upload-duckdns-update
  install -m 0644 "${release_dir}/duckdns-update.service" /etc/systemd/system/file-upload-duckdns-update.service
  install -m 0644 "${release_dir}/duckdns-update.timer" /etc/systemd/system/file-upload-duckdns-update.timer
fi
systemctl daemon-reload
systemctl enable file-upload-update.timer file-upload-duckdns-update.timer >/dev/null

systemctl restart file-upload
if ! curl -fsS --retry 10 --retry-delay 1 http://127.0.0.1:8080/health >/dev/null; then
  if [[ -n "${previous}" && -d "${previous}" ]]; then
    ln -sfn "${previous}" /opt/file-upload/current
    systemctl restart file-upload
  fi
  echo "Update failed its health check; restored the previous release." >&2
  exit 1
fi

echo "Updated File Upload to ${tag}."
