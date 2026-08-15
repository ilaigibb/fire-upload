#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this updater as root." >&2
  exit 1
fi

source /etc/fire-upload-release.env
: "${FIRE_UPLOAD_REPO:?FIRE_UPLOAD_REPO is required}"

headers=(-H "Accept: application/vnd.github+json")
if [[ -n "${FIRE_UPLOAD_GITHUB_TOKEN:-}" ]]; then
  headers+=(-H "Authorization: Bearer ${FIRE_UPLOAD_GITHUB_TOKEN}")
fi

release_json="$(curl -fsSL "${headers[@]}" "https://api.github.com/repos/${FIRE_UPLOAD_REPO}/releases/latest")"
tag="$(jq -er '.tag_name' <<<"${release_json}")"
asset_url="$(jq -er '.assets[] | select(.name == "fire-upload.tar.gz") | .url' <<<"${release_json}")"
release_dir="/opt/fire-upload/releases/${tag}"

if [[ -d "${release_dir}" ]]; then
  echo "Fire Upload ${tag} is already installed."
  exit 0
fi

temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT
download_headers=(-H "Accept: application/octet-stream")
if [[ -n "${FIRE_UPLOAD_GITHUB_TOKEN:-}" ]]; then
  download_headers+=(-H "Authorization: Bearer ${FIRE_UPLOAD_GITHUB_TOKEN}")
fi
curl -fsSL "${download_headers[@]}" "${asset_url}" -o "${temporary}/fire-upload.tar.gz"
tar -xzf "${temporary}/fire-upload.tar.gz" -C "${temporary}"
[[ -f "${temporary}/server.js" ]] || { echo "Release is missing server.js" >&2; exit 1; }

previous="$(readlink -f /opt/fire-upload/current 2>/dev/null || true)"
mkdir -p /opt/fire-upload/releases
mv "${temporary}" "${release_dir}"
trap - EXIT
ln -sfn "${release_dir}" /opt/fire-upload/current
chown -R root:root "${release_dir}"

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
