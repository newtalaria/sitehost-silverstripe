#!/usr/bin/env bash
# Trimmed SiteHost settings are written for later steps. A missing API name is named before any request.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
configure="${root}/actions/ssh/configure-env.sh"
require="${root}/actions/ssh/require-config.sh"

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

export GITHUB_ENV="${tmp}/env"
export SITEHOST_SSH_PORT_RAW=" 22 "
export SITEHOST_SSH_HOST_RAW=" 203.0.113.10 "
export SITEHOST_SSH_USER_RAW=" example "
export SITEHOST_SSH_HOST_FINGERPRINT_RAW=" SHA256:abc "
export SITEHOST_SSH_PRIVATE_KEY_RAW=$'line-of-key\n'
export SITEHOST_API_KEY_RAW=" api-key-value "
export SITEHOST_CONTAINER=" test.example.com "
export SITEHOST_STACK=" cce6c3ce72078711 "
export SITEHOST_CLIENT_ID=" 17 "
export SITEHOST_SERVER=" ch-server "
export SITEHOST_SITE_URL=" https://test.example.com "
export SITEHOST_APP_PATH=""
export SITEHOST_BACKUP_ROOT=""
unset SITEHOST_SERVICE || true

bash "$configure"
env_file="$(cat "$GITHUB_ENV")"
for needle in \
  "SITEHOST_SSH_PORT=22" \
  "SITEHOST_SSH_HOST=203.0.113.10" \
  "SITEHOST_SSH_USER=example" \
  "SITEHOST_CONTAINER=test.example.com" \
  "SITEHOST_STACK=cce6c3ce72078711" \
  "SITEHOST_SERVICE=test.example.com" \
  "SITEHOST_APP_PATH=/container/application" \
  "SITEHOST_BACKUP_ROOT=/container/backups/containers" \
  "SITEHOST_SITE_URL=https://test.example.com" \
  "SITEHOST_SSH_PRIVATE_KEY<<"
do
  if [[ "$env_file" != *"$needle"* ]]; then
    echo "configure-env missing: ${needle}" >&2
    exit 1
  fi
done

export DEPLOY_ENVIRONMENT="test"
export REQUIRE_CONFIG="api"
export SITEHOST_API_KEY="present"
export SITEHOST_CLIENT_ID="17"
export SITEHOST_SERVER="ch-server"
export SITEHOST_CONTAINER="test.example.com"
export SITEHOST_BACKUP_ROOT="/container/backups/containers"
unset SITEHOST_STACK || true
set +e
api_out="$(bash "$require" 2>&1)"
api_status=$?
set -e
if [[ "$api_status" -eq 0 || "$api_out" != *"SITEHOST_STACK"* || "$api_out" != *"mountinfo"* ]]; then
  echo "api configuration should name a missing stack id" >&2
  printf '%s\n' "$api_out" >&2
  exit 1
fi

export REQUIRE_CONFIG="restore"
export SITEHOST_SSH_PRIVATE_KEY="key"
export SITEHOST_SSH_HOST="203.0.113.10"
export SITEHOST_SSH_USER="example"
export SITEHOST_SSH_HOST_FINGERPRINT="SHA256:abc"
export SITEHOST_APP_PATH="/container/application"
export SITEHOST_SITE_URL="https://test.example.com"
bash "$require"

export SITEHOST_SITE_URL="test.example.com"
set +e
url_out="$(bash "$require" 2>&1)"
url_status=$?
set -e
if [[ "$url_status" -eq 0 || "$url_out" != *"http:// or https://"* ]]; then
  echo "restore configuration should reject a site URL without a scheme" >&2
  printf '%s\n' "$url_out" >&2
  exit 1
fi

echo "configure env test passed"
