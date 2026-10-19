#!/usr/bin/env bash
# Fail with the missing SiteHost setting names before SSH or the API is called.
# REQUIRE_CONFIG is operate, restore, or api.
set -euo pipefail

: "${REQUIRE_CONFIG:?REQUIRE_CONFIG is required}"
environment="${DEPLOY_ENVIRONMENT:-this environment}"
missing=0

require_name() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing ${name}. Set it on the ${environment} environment, the repository, or the organisation." >&2
    missing=1
  fi
}

case "$REQUIRE_CONFIG" in
  operate|restore)
    for name in \
      SITEHOST_SSH_PRIVATE_KEY \
      SITEHOST_SSH_HOST \
      SITEHOST_SSH_USER \
      SITEHOST_SSH_HOST_FINGERPRINT \
      SITEHOST_APP_PATH \
      SITEHOST_BACKUP_ROOT
    do
      require_name "$name"
    done
    if [[ "$REQUIRE_CONFIG" == "restore" ]]; then
      require_name SITEHOST_SITE_URL
      case "${SITEHOST_SITE_URL:-}" in
        https://*|http://*) ;;
        *)
          echo "SITEHOST_SITE_URL must start with http:// or https://" >&2
          missing=1
          ;;
      esac
    fi
    if [[ "$missing" -ne 0 ]]; then
      echo "Use a secret for keys and a variable for host, user, and URL. A secret is used when both are set." >&2
      exit 1
    fi
    ;;
  api)
    for name in \
      SITEHOST_API_KEY \
      SITEHOST_CLIENT_ID \
      SITEHOST_SERVER \
      SITEHOST_CONTAINER \
      SITEHOST_STACK \
      SITEHOST_BACKUP_ROOT
    do
      require_name "$name"
    done
    if [[ "$missing" -ne 0 ]]; then
      echo "SITEHOST_SERVER is the API server name, such as ch-servername, not the SSH address." >&2
      echo "SITEHOST_CONTAINER is the hostname, such as test.example.com." >&2
      echo "SITEHOST_STACK is the id from this command on the container:" >&2
      echo "  awk '\$5 == \"/container\" { n=\$4; sub(\".*/\", \"\", n); print n }' /proc/self/mountinfo" >&2
      echo "Leave the API key IP allowlist empty. A listed address rejects GitHub-hosted runners." >&2
      exit 1
    fi
    ;;
  *)
    echo "REQUIRE_CONFIG must be operate, restore, or api" >&2
    exit 1
    ;;
esac
