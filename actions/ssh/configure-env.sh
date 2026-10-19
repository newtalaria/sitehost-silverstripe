#!/usr/bin/env bash
# Trim SiteHost settings and write them to GITHUB_ENV for the rest of the job.
# Keys are masked. Empty values stay empty so a later check can name what is missing.
set -euo pipefail

if [[ -z "${GITHUB_ENV:-}" ]]; then
  echo "GITHUB_ENV is required" >&2
  exit 1
fi

trim() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

trim_block() {
  local value="$1"
  value="${value//$'\r'/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

mask_block() {
  local value="$1"
  local line
  [[ -z "$value" ]] && return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ((${#line} >= 8)); then
      echo "::add-mask::${line}"
    fi
  done <<< "$value"
}

write_block() {
  local name="$1"
  local value="$2"
  local keep_trailing_newline="${3:-}"
  local delim="SITEHOST_EOF_${RANDOM}${RANDOM}"
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$value"
    if [[ -n "$keep_trailing_newline" ]]; then
      printf '\n'
    fi
    printf '%s\n' "$delim"
  } >> "$GITHUB_ENV"
}

port="$(trim "${SITEHOST_SSH_PORT_RAW:-}")"
if [[ -z "$port" ]]; then
  port=22
fi
if [[ ! "$port" =~ ^[0-9]+$ ]]; then
  echo "SITEHOST_SSH_PORT must be a whole number." >&2
  exit 1
fi
container="$(trim "${SITEHOST_CONTAINER:-}")"
stack="$(trim "${SITEHOST_STACK:-}")"
service="$(trim "${SITEHOST_SERVICE:-}")"
if [[ -z "$service" ]]; then
  service="$container"
fi
app_path="$(trim "${SITEHOST_APP_PATH:-}")"
backup_root="$(trim "${SITEHOST_BACKUP_ROOT:-}")"
if [[ -z "$app_path" ]]; then
  app_path=/container/application
fi
if [[ -z "$backup_root" ]]; then
  backup_root=/container/backups/containers
fi
private_key="$(trim_block "${SITEHOST_SSH_PRIVATE_KEY_RAW:-}")"
api_key="$(trim_block "${SITEHOST_API_KEY_RAW:-}")"
mask_block "$private_key"
mask_block "$api_key"
{
  printf 'SITEHOST_SSH_PORT=%s\n' "$port"
  printf 'SITEHOST_SSH_HOST=%s\n' "$(trim "${SITEHOST_SSH_HOST_RAW:-}")"
  printf 'SITEHOST_SSH_USER=%s\n' "$(trim "${SITEHOST_SSH_USER_RAW:-}")"
  printf 'SITEHOST_SSH_HOST_FINGERPRINT=%s\n' "$(trim "${SITEHOST_SSH_HOST_FINGERPRINT_RAW:-}")"
  printf 'SITEHOST_CLIENT_ID=%s\n' "$(trim "${SITEHOST_CLIENT_ID:-}")"
  printf 'SITEHOST_SERVER=%s\n' "$(trim "${SITEHOST_SERVER:-}")"
  printf 'SITEHOST_SERVICE=%s\n' "$service"
  printf 'SITEHOST_STACK=%s\n' "$stack"
  printf 'SITEHOST_CONTAINER=%s\n' "$container"
  printf 'SITEHOST_APP_PATH=%s\n' "$app_path"
  printf 'SITEHOST_BACKUP_ROOT=%s\n' "$backup_root"
  printf 'SITEHOST_SITE_URL=%s\n' "$(trim "${SITEHOST_SITE_URL:-}")"
} >> "$GITHUB_ENV"
if [[ -n "$private_key" ]]; then
  write_block SITEHOST_SSH_PRIVATE_KEY "$private_key" keep-newline
else
  write_block SITEHOST_SSH_PRIVATE_KEY ""
fi
write_block SITEHOST_API_KEY "$api_key"
