#!/usr/bin/env bash
# Local database and assets backups are retained in the scripts but never run
# (Heath, 2026-11-03). BACKUP_DATABASE=true no longer dumps or checks the
# database, and remote-restore.sh is a no-op.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export SITEHOST_APP_PATH="/tmp/sitehost-silverstripe-not-a-checkout"
export GIT_REMOTE="git@github.com:example/site.git"
export DEPLOY_SHA="0123456789abcdef0123456789abcdef01234567"
export BACKUP_DATABASE=true
export BACKUP_ASSETS=true
export DEPLOY_LOG_DIR="${tmp}/logs"
unset SS_DATABASE_NAME ROLLBACK_RUN_ID || true

set +e
output="$(bash "${root}/actions/ssh/remote-deploy.sh" 2>&1)"
status=$?
set -e

if [[ "$output" != *"Local database and assets backups are disabled"* ]]; then
  echo "expected the deploy to say local backups are disabled" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
if [[ "$output" == *"SS_DATABASE_NAME"* || "$output" == *"ROLLBACK_RUN_ID"* || "$output" == *"Dumping database"* || "$output" == *"Backing up "* ]]; then
  echo "the deploy still ran or checked the local backup path" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
if [[ "$status" -eq 0 || "$output" != *"No git checkout"* ]]; then
  echo "expected the deploy to stop at the missing checkout" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi
if [[ -e "${tmp}/logs/deploy-rollback-manifest" ]]; then
  echo "the deploy wrote a local rollback manifest" >&2
  exit 1
fi

for action in restore discard; do
  mkdir -p "${tmp}/logs"
  printf 'run_id=1-1\ndatabase\n' > "${tmp}/logs/deploy-rollback-manifest"
  set +e
  output="$(SITEHOST_APP_PATH="$tmp" ROLLBACK_RUN_ID=1-1 RESTORE_ACTION="$action" bash "${root}/actions/ssh/remote-restore.sh" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne 0 || "$output" != *"Local database and assets backups are disabled"* ]]; then
    echo "remote-restore.sh ${action} should be a no-op" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ ! -f "${tmp}/logs/deploy-rollback-manifest" ]]; then
    echo "remote-restore.sh ${action} touched the local files" >&2
    exit 1
  fi
done

echo "backup env test passed"
