#!/usr/bin/env bash
# A database backup stops before any file changes when SS_DATABASE_NAME is missing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

export SITEHOST_APP_PATH="/tmp/sitehost-silverstripe-not-a-checkout"
export GIT_REMOTE="git@github.com:example/site.git"
export DEPLOY_SHA="0123456789abcdef0123456789abcdef01234567"
export BACKUP_DATABASE=true
export SS_DATABASE_SERVER="db.example"
export SS_DATABASE_USERNAME="app"
export SS_DATABASE_PASSWORD="secret"
unset SS_DATABASE_NAME || true
unset BACKUP_ASSETS || true

set +e
output="$(bash "${root}/actions/ssh/remote-deploy.sh" 2>&1)"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "expected the deploy script to fail" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
if [[ "$output" != *"SS_DATABASE_NAME"* ]]; then
  echo "expected the error to name SS_DATABASE_NAME" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
if [[ "$output" == *"Fetching "* || "$output" == *"Dumping database"* ]]; then
  echo "the script continued after the missing database name" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

echo "backup env test passed"
