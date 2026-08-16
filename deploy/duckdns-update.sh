#!/usr/bin/env bash
set -euo pipefail

source /etc/file-upload-duckdns.env
: "${DUCKDNS_SUBDOMAIN:?DUCKDNS_SUBDOMAIN is required}"
: "${DUCKDNS_TOKEN:?DUCKDNS_TOKEN is required}"

response="$(curl -fsS "https://www.duckdns.org/update?domains=${DUCKDNS_SUBDOMAIN}&token=${DUCKDNS_TOKEN}&ip=")"
[[ "${response}" == "OK" ]] || { echo "DuckDNS update failed: ${response}" >&2; exit 1; }
