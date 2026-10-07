#!/usr/bin/env bash
# Restores or discards the database dump and assets copy recorded for this run.
set -euo pipefail

if [[ -z "${SITEHOST_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

: "${SITEHOST_APP_PATH:?SITEHOST_APP_PATH is required}"
: "${ROLLBACK_RUN_ID:?ROLLBACK_RUN_ID is required}"
: "${RESTORE_ACTION:?RESTORE_ACTION is required}"

log_dir="${DEPLOY_LOG_DIR:-/container/logs}"
dump="${log_dir}/deploy-rollback.sql.gz"
manifest="${log_dir}/deploy-rollback-manifest"
assets_live="${SITEHOST_APP_PATH}/public/assets"
assets_backup="${log_dir}/deploy-rollback-assets"
defaults=""

cleanup() {
  if [[ -n "$defaults" ]]; then
    rm -f "$defaults"
  fi
}
trap cleanup EXIT

remove_backups() {
  rm -f -- "$dump" "$manifest"
  if [[ -e "$assets_backup" ]]; then
    rm -rf -- "$assets_backup"
  fi
}

restore_database() {
  if [[ ! -f "$dump" ]]; then
    echo "Rollback manifest lists the database, but ${dump} is missing." >&2
    exit 1
  fi
  require_database_env restore
  if ! command -v mysql >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
    echo "mysql and gzip are required to restore the database" >&2
    exit 1
  fi
  write_mysql_defaults
  echo "Restoring database ${SS_DATABASE_NAME} on ${SS_DATABASE_SERVER} from ${dump}"
  gunzip -c "$dump" | mysql \
    --defaults-file="$defaults" \
    --host="$SS_DATABASE_SERVER" \
    --protocol=TCP \
    "$SS_DATABASE_NAME"
  echo "Database restore completed"
}

restore_assets() {
  if [[ ! -d "$assets_backup" ]]; then
    echo "Rollback manifest lists assets, but ${assets_backup} is missing." >&2
    exit 1
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is required to restore assets" >&2
    exit 1
  fi
  case "$assets_backup" in
    "$assets_live"|"$assets_live"/*)
      echo "Refusing to restore assets from inside ${assets_live}" >&2
      exit 1
      ;;
  esac
  mkdir -p "$assets_live"
  echo "Restoring ${assets_live} from ${assets_backup}"
  rsync --archive --delete "${assets_backup}/" "${assets_live}/"
  echo "Assets restore completed"
}

assert_absolute_path "SITEHOST_APP_PATH" "$SITEHOST_APP_PATH"
assert_absolute_path "log dir" "$log_dir"
case "$RESTORE_ACTION" in
  restore|discard) ;;
  *)
    echo "RESTORE_ACTION must be restore or discard" >&2
    exit 1
    ;;
esac
if [[ ! "$ROLLBACK_RUN_ID" =~ ^[0-9]+-[0-9]+$ ]]; then
  echo "ROLLBACK_RUN_ID must be the GitHub run id and attempt." >&2
  exit 1
fi

if [[ ! -f "$manifest" ]]; then
  echo "No rollback manifest at ${manifest}"
  exit 0
fi

recorded=""
want_database=0
want_assets=0
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    run_id=*)
      recorded="${line#run_id=}"
      ;;
    database)
      want_database=1
      ;;
    assets)
      want_assets=1
      ;;
    "")
      ;;
    *)
      echo "Unexpected rollback manifest line" >&2
      exit 1
      ;;
  esac
done < "$manifest"

if [[ "$recorded" != "$ROLLBACK_RUN_ID" ]]; then
  echo "Rollback manifest belongs to run ${recorded:-unknown}, not ${ROLLBACK_RUN_ID}. Left the backups in place."
  exit 0
fi

if [[ "$RESTORE_ACTION" == "discard" ]]; then
  remove_backups
  echo "Removed deploy backups for run ${ROLLBACK_RUN_ID}"
  exit 0
fi

if [[ "$want_database" -eq 1 ]]; then
  restore_database
else
  echo "This run did not back up the database"
fi
if [[ "$want_assets" -eq 1 ]]; then
  restore_assets
else
  echo "This run did not back up assets"
fi
remove_backups
echo "Rollback completed for run ${ROLLBACK_RUN_ID}"
