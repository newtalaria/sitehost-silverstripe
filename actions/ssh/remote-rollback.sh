#!/usr/bin/env bash
# Restores one container's application files from a pinned snapshot, then the
# pre-deploy database dump when that dump exists. Does not follow "latest".
set -euo pipefail

if [[ -z "${SITEHOST_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

: "${SITEHOST_APP_PATH:?SITEHOST_APP_PATH is required}"
: "${SITEHOST_BACKUP_ROOT:?SITEHOST_BACKUP_ROOT is required}"

log_dir="${DEPLOY_LOG_DIR:-/container/logs}"
pinned_file="${log_dir}/deploy-snapshot-path.txt"
dump="${log_dir}/deploy-rollback.sql.gz"
defaults=""

# Remove the temporary MySQL defaults file when the script exits.
cleanup() {
  if [[ -n "$defaults" ]]; then
    rm -f "$defaults"
  fi
}
trap cleanup EXIT

if [[ -z "${SNAPSHOT_PATH:-}" ]]; then
  if [[ ! -f "$pinned_file" ]]; then
    echo "No pinned snapshot path at ${pinned_file}" >&2
    exit 1
  fi
  SNAPSHOT_PATH="$(tr -d '\r\n' < "$pinned_file")"
fi

assert_absolute_path "SITEHOST_APP_PATH" "$SITEHOST_APP_PATH"
assert_absolute_path "SITEHOST_BACKUP_ROOT" "$SITEHOST_BACKUP_ROOT"
assert_absolute_path "SNAPSHOT_PATH" "$SNAPSHOT_PATH"

prefix="${SITEHOST_BACKUP_ROOT%/}/"
case "$SNAPSHOT_PATH" in
  "$prefix"*) ;;
  *)
    echo "Snapshot path is outside SITEHOST_BACKUP_ROOT" >&2
    exit 1
    ;;
esac
name="${SNAPSHOT_PATH#"$prefix"}"
case "$name" in
  ""|.*|*/*|*$'\n'*|*'..'*)
    echo "Unexpected snapshot directory name" >&2
    exit 1
    ;;
esac
if [[ "$SNAPSHOT_PATH" == "$SITEHOST_APP_PATH" ]]; then
  echo "Refusing to roll back because the snapshot path is the app path" >&2
  exit 1
fi

app_snapshot="${SNAPSHOT_PATH}/application"
if [[ ! -d "$app_snapshot" ]]; then
  echo "Snapshot application directory not found: ${app_snapshot}" >&2
  exit 1
fi
if [[ -z "$(ls -A "$app_snapshot")" ]]; then
  echo "Refusing to roll back from an empty snapshot: ${app_snapshot}" >&2
  exit 1
fi
if [[ ! -d "$SITEHOST_APP_PATH" ]]; then
  echo "App path does not exist: ${SITEHOST_APP_PATH}" >&2
  exit 1
fi
if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required to roll back application files" >&2
  exit 1
fi

echo "Restoring application files from ${app_snapshot}"
rsync --archive --stats --delete "${app_snapshot}/" "${SITEHOST_APP_PATH}/"

if [[ -f "$dump" ]]; then
  require_database_env restore
  if ! command -v mysql >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
    echo "mysql and gzip are required to restore the database" >&2
    exit 1
  fi
  write_mysql_defaults
  echo "Restoring database from ${dump}"
  gunzip -c "$dump" | mysql \
    --defaults-file="$defaults" \
    --host="$SS_DATABASE_SERVER" \
    --protocol=TCP \
    "$SS_DATABASE_NAME"
  rm -f "$dump"
  echo "Database restore completed"
else
  echo "No database dump at ${dump}; skipped database restore"
fi
