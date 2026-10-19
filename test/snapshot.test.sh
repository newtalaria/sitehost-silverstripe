#!/usr/bin/env bash
# The snapshot directory name is the rollback id. A container rollback can restore the database stored in that directory.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
snapshots="${root}/actions/ssh/remote-snapshots.sh"
rollback="${root}/actions/ssh/remote-rollback.sh"

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

export SITEHOST_BACKUP_ROOT="${tmp}/backups"
export DEPLOY_LOG_DIR="${tmp}/logs"
export SITEHOST_APP_PATH="${tmp}/application"
mkdir -p "$SITEHOST_BACKUP_ROOT/old/application" "$SITEHOST_APP_PATH"
printf 'old\n' > "$SITEHOST_BACKUP_ROOT/old/application/index.php"
printf 'live\n' > "$SITEHOST_APP_PATH/index.php"
ln -s old "$SITEHOST_BACKUP_ROOT/latest"

SNAPSHOT_MODE=record bash "$snapshots" >/dev/null

mkdir -p "$SITEHOST_BACKUP_ROOT/empty/application"
set +e
empty="$(SNAPSHOT_MODE=pin bash "$snapshots" 2>&1)"
empty_status=$?
set -e
if [[ "$empty_status" -eq 0 || "$empty" != *"empty application snapshot"* ]]; then
  echo "an empty application snapshot should not be pinned" >&2
  printf '%s\n' "$empty" >&2
  exit 1
fi
rm -rf "$SITEHOST_BACKUP_ROOT/empty"

mkdir -p "$SITEHOST_BACKUP_ROOT/2026-10-19-183000/application"
printf 'pinned\n' > "$SITEHOST_BACKUP_ROOT/2026-10-19-183000/application/index.php"

pin_out="$(SNAPSHOT_MODE=pin bash "$snapshots" 2>"${tmp}/pin.err")"
if [[ "$pin_out" != "snapshot_id=2026-10-19-183000" ]]; then
  echo "expected one snapshot_id on stdout" >&2
  printf '%s\n' "$pin_out" >&2
  exit 1
fi
if [[ "$(tr -d '\r\n' < "${DEPLOY_LOG_DIR}/deploy-snapshot-path.txt")" != "${SITEHOST_BACKUP_ROOT}/2026-10-19-183000" ]]; then
  echo "pinned path was not recorded" >&2
  exit 1
fi

mkdir -p "$SITEHOST_BACKUP_ROOT/second/application"
printf 'x\n' > "$SITEHOST_BACKUP_ROOT/second/application/index.php"
set +e
two="$(SNAPSHOT_MODE=pin bash "$snapshots" 2>&1)"
two_status=$?
set -e
if [[ "$two_status" -eq 0 || "$two" != *"found 2"* ]]; then
  echo "two new snapshot directories should fail the pin" >&2
  printf '%s\n' "$two" >&2
  exit 1
fi
rm -rf "$SITEHOST_BACKUP_ROOT/second"

pin_out="$(SNAPSHOT_MODE=pin bash "$snapshots" 2>/dev/null)"
if [[ "$pin_out" != "snapshot_id=2026-10-19-183000" ]]; then
  echo "pin should ignore the latest symlink" >&2
  printf '%s\n' "$pin_out" >&2
  exit 1
fi

export SNAPSHOT_PATH="${SITEHOST_BACKUP_ROOT}/2026-10-19-183000"
export SS_DATABASE_SERVER="db.example"
export SS_DATABASE_USERNAME="app"
export SS_DATABASE_PASSWORD="secret"
export SS_DATABASE_NAME="silverstripe"
unset RESTORE_SNAPSHOT_DATABASE || true

skipped="$(bash "$rollback")"
if [[ "$skipped" != *"Left the snapshot database"* ]]; then
  echo "rollback should leave the snapshot database when the local dump covers the run" >&2
  printf '%s\n' "$skipped" >&2
  exit 1
fi
if [[ "$(cat "$SITEHOST_APP_PATH/index.php")" != "pinned" ]]; then
  echo "rollback did not restore application files" >&2
  exit 1
fi

printf 'live-again\n' > "$SITEHOST_APP_PATH/index.php"
export RESTORE_SNAPSHOT_DATABASE=true
set +e
missing_db="$(bash "$rollback" 2>&1)"
missing_db_status=$?
set -e
if [[ "$missing_db_status" -eq 0 || "$missing_db" != *"silverstripe.sql.gz"* ]]; then
  echo "rollback should name the missing snapshot database dump" >&2
  printf '%s\n' "$missing_db" >&2
  exit 1
fi

mkdir -p "${SNAPSHOT_PATH}/databases"
printf 'SELECT 1;\n' | gzip -c > "${SNAPSHOT_PATH}/databases/silverstripe.sql.gz"
cat > "${tmp}/mysql" <<'EOF'
#!/usr/bin/env bash
cat > "$MYSQL_STDIN"
printf '%s\n' "$*" > "$MYSQL_ARGS"
EOF
chmod +x "${tmp}/mysql"
export PATH="${tmp}:${PATH}"
export MYSQL_STDIN="${tmp}/mysql-stdin.sql"
export MYSQL_ARGS="${tmp}/mysql-args"

restored="$(bash "$rollback")"
if [[ "$restored" != *"Snapshot database restore completed"* ]]; then
  echo "snapshot database restore did not finish" >&2
  printf '%s\n' "$restored" >&2
  exit 1
fi
if [[ "$(cat "$MYSQL_STDIN")" != "SELECT 1;" ]]; then
  echo "mysql did not receive the snapshot dump" >&2
  printf '%s\n' "$(cat "$MYSQL_STDIN")" >&2
  exit 1
fi
if [[ "$(cat "$MYSQL_ARGS")" != *"--host=db.example"* || "$(cat "$MYSQL_ARGS")" != *"silverstripe" ]]; then
  echo "mysql was not aimed at the Silverstripe database" >&2
  printf '%s\n' "$(cat "$MYSQL_ARGS")" >&2
  exit 1
fi

missing_root="${tmp}/missing-backups"
export SITEHOST_BACKUP_ROOT="$missing_root"
export DEPLOY_LOG_DIR="${tmp}/logs-missing"
recorded="$(SNAPSHOT_MODE=record bash "$snapshots")"
if [[ "$recorded" != *"does not exist yet"* ]]; then
  echo "record should allow a missing backup root" >&2
  printf '%s\n' "$recorded" >&2
  exit 1
fi
if [[ -s "${DEPLOY_LOG_DIR}/deploy-snapshots-before.txt" ]]; then
  echo "a missing backup root should record an empty list" >&2
  exit 1
fi
mkdir -p "${missing_root}/2026-10-19-190000/application"
printf 'first\n' > "${missing_root}/2026-10-19-190000/application/index.php"
first="$(SNAPSHOT_MODE=pin bash "$snapshots" 2>/dev/null)"
if [[ "$first" != "snapshot_id=2026-10-19-190000" ]]; then
  echo "the first snapshot should pin when the backup root was missing" >&2
  printf '%s\n' "$first" >&2
  exit 1
fi

echo "snapshot test passed"
