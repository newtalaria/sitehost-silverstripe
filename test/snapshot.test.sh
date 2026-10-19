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
empty="$(SNAPSHOT_WAIT_SECONDS=0 SNAPSHOT_MODE=pin bash "$snapshots" 2>&1)"
empty_status=$?
set -e
if [[ "$empty_status" -eq 0 || "$empty" != *"found 1"* ]]; then
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

saved_snapshot="$SNAPSHOT_PATH"
export SNAPSHOT_PATH="${SITEHOST_BACKUP_ROOT}/latest"
set +e
latest_out="$(bash "$rollback" 2>&1)"
latest_status=$?
set -e
if [[ "$latest_status" -eq 0 || "$latest_out" != *"named latest"* ]]; then
  echo "rollback should refuse a snapshot named latest" >&2
  printf '%s\n' "$latest_out" >&2
  exit 1
fi

export SNAPSHOT_PATH="${SITEHOST_BACKUP_ROOT}/not-a-snapshot"
set +e
missing_out="$(bash "$rollback" 2>&1)"
missing_status=$?
set -e
if [[ "$missing_status" -eq 0 || "$missing_out" != *"not found"* ]]; then
  echo "rollback should reject a missing snapshot directory" >&2
  printf '%s\n' "$missing_out" >&2
  exit 1
fi

printf 'stay\n' > "$SITEHOST_APP_PATH/index.php"
export SNAPSHOT_PATH="$saved_snapshot"
export ROLLBACK_CHECK_ONLY=true
checked="$(bash "$rollback")"
if [[ "$checked" != *"restore candidate"* ]]; then
  echo "a check should accept an explicit snapshot path without copying files" >&2
  printf '%s\n' "$checked" >&2
  exit 1
fi
if [[ "$(cat "$SITEHOST_APP_PATH/index.php")" != "stay" ]]; then
  echo "a check should not copy application files" >&2
  exit 1
fi
unset ROLLBACK_CHECK_ONLY
export SNAPSHOT_PATH="$saved_snapshot"

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

link_root="${tmp}/link-backups"
mkdir -p "${tmp}/real-backups/2026-10-18_14:33:56/application"
printf 'nightly\n' > "${tmp}/real-backups/2026-10-18_14:33:56/application/index.php"
ln -s nightly-target "${tmp}/real-backups/latest"
ln -s "${tmp}/real-backups" "$link_root"
export SITEHOST_BACKUP_ROOT="$link_root"
export DEPLOY_LOG_DIR="${tmp}/logs-link"
linked="$(SNAPSHOT_MODE=record bash "$snapshots")"
if [[ "$linked" != *"Recorded 1 existing snapshot directories"* ]]; then
  echo "record should follow the backup root symlink and skip latest" >&2
  printf '%s\n' "$linked" >&2
  exit 1
fi
if ! grep -qx '2026-10-18_14:33:56' "${DEPLOY_LOG_DIR}/deploy-snapshots-before.txt"; then
  echo "a timestamp with colons should be recorded" >&2
  exit 1
fi

delay_root="${tmp}/delay-backups"
mkdir -p "$delay_root/old/application"
printf 'old\n' > "$delay_root/old/application/index.php"
export SITEHOST_BACKUP_ROOT="$delay_root"
export DEPLOY_LOG_DIR="${tmp}/logs-delay"
SNAPSHOT_MODE=record bash "$snapshots" >/dev/null
(
  sleep 1
  mkdir -p "$delay_root/2026-10-19_09:35:25/application"
  printf 'late\n' > "$delay_root/2026-10-19_09:35:25/application/index.php"
) &
delayed="$(SNAPSHOT_WAIT_SECONDS=5 SNAPSHOT_POLL_SECONDS=1 SNAPSHOT_MODE=pin bash "$snapshots" 2>"${tmp}/delay.err")"
wait || true
if [[ "$delayed" != "snapshot_id=2026-10-19_09:35:25" ]]; then
  echo "pin should wait until the snapshot directory appears" >&2
  printf '%s\n' "$delayed" >&2
  cat "${tmp}/delay.err" >&2
  exit 1
fi

echo "snapshot test passed"
