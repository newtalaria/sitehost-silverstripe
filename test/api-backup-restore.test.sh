#!/usr/bin/env bash
# End to end with a mocked SiteHost API: back up through the API, poll the job,
# pin the new snapshot, break the site, then restore the newest snapshot with
# its database. Also: a failed job, an API error, and a timeout stop the run.
# curl and mysql are stubs. No request leaves this machine.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
api="${root}/actions/ssh/sitehost-api.sh"
snapshots="${root}/actions/ssh/remote-snapshots.sh"
rollback="${root}/actions/ssh/remote-rollback.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "api-backup-restore: $1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" >&2
  fi
  exit 1
}

bin="${tmp}/bin"
mkdir -p "$bin"
# Fake SiteHost. backup.json writes a new dated snapshot, as SiteHost does on
# the container. job/get.json answers from JOB_STATES, one state per call.
cat > "${bin}/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  printf '%s\n' "$1" >> "$CURL_LOG"
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --write-out|--request|--form|--data-urlencode)
      printf '%s\n' "$2" >> "$CURL_LOG"
      shift 2
      ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */cloud/stack/backup.json)
    if [[ -n "${BACKUP_HTTP:-}" ]]; then
      printf '{"status":false,"msg":"Invalid API key"}' > "$out"
      printf '%s' "$BACKUP_HTTP"
      exit 0
    fi
    mkdir -p "${SITEHOST_BACKUP_ROOT}/${NEW_SNAPSHOT}/application" "${SITEHOST_BACKUP_ROOT}/${NEW_SNAPSHOT}/databases"
    printf 'good\n' > "${SITEHOST_BACKUP_ROOT}/${NEW_SNAPSHOT}/application/index.php"
    printf 'CREATE TABLE ok;\n' | gzip -c > "${SITEHOST_BACKUP_ROOT}/${NEW_SNAPSHOT}/databases/site.sql.gz"
    printf '{"status":true,"msg":"Successful","return":{"job":{"type":"scheduler","id":7319505}}}' > "$out"
    ;;
  */job/get.json)
    n="$(cat "$JOB_COUNTER" 2>/dev/null || echo 0)"
    n=$((n + 1))
    printf '%s' "$n" > "$JOB_COUNTER"
    state="$(printf '%s\n' "$JOB_STATES" | tr ',' '\n' | sed -n "${n}p")"
    [[ -n "$state" ]] || state="$(printf '%s\n' "$JOB_STATES" | tr ',' '\n' | tail -n 1)"
    printf '{"status":true,"msg":"Successful","return":{"state":"%s","logs":[{"message":"[backup] %s"}]}}' "$state" "$state" > "$out"
    ;;
  *)
    printf '{"status":false,"msg":"unexpected"}' > "$out"
    printf '404'
    exit 0
    ;;
esac
printf '200'
STUB
cat > "${bin}/mysql" <<'STUB'
#!/usr/bin/env bash
printf 'mysql %s\n' "$*" >> "$MYSQL_LOG"
cat >> "$MYSQL_LOG"
STUB
chmod +x "${bin}/curl" "${bin}/mysql"
export PATH="${bin}:${PATH}"

export CURL_LOG="${tmp}/curl.log"
export MYSQL_LOG="${tmp}/mysql.log"
export JOB_COUNTER="${tmp}/job-counter"
export SITEHOST_API_KEY="test-api-key-not-real"
export SITEHOST_CLIENT_ID="17"
export SITEHOST_SERVER="ch-servername"
export SITEHOST_CONTAINER="test.example.com"
export SITEHOST_STACK="cce6c3ce72078711"
export BACKUP_LABEL="predeploy-1-1-0123456789abcdef0123456789abcdef01234567"
export POLL_INTERVAL_SECONDS=1
export SNAPSHOT_WAIT_SECONDS=2
export SNAPSHOT_POLL_SECONDS=1
export SITEHOST_BACKUP_ROOT="${tmp}/backups"
export SITEHOST_APP_PATH="${tmp}/app"
export DEPLOY_LOG_DIR="${tmp}/logs"
export SS_DATABASE_SERVER="db.example"
export SS_DATABASE_USERNAME="app"
export SS_DATABASE_PASSWORD="secret"
export SS_DATABASE_NAME="site"
export NEW_SNAPSHOT="2026-11-03_09:15:00"
unset GITHUB_OUTPUT || true

mkdir -p "${SITEHOST_BACKUP_ROOT}/2026-11-01_02:00:00/application" "$SITEHOST_APP_PATH"
printf 'older\n' > "${SITEHOST_BACKUP_ROOT}/2026-11-01_02:00:00/application/index.php"
ln -s "2026-11-01_02:00:00" "${SITEHOST_BACKUP_ROOT}/latest"
printf 'good\n' > "${SITEHOST_APP_PATH}/index.php"

# 1. Backup success: record, backup, poll Running then Completed, pin.
: > "$CURL_LOG"
SNAPSHOT_MODE=record bash "$snapshots" >/dev/null
backup_out="$(bash "$api" backup)"
[[ "$backup_out" == *"job_type=scheduler"* && "$backup_out" == *"job_id=7319505"* ]] || fail "backup did not return the job" "$backup_out"
[[ "$backup_out" != *"$SITEHOST_API_KEY"* ]] || fail "backup printed the API key"
grep -qx "https://api.sitehost.nz/1.5/cloud/stack/backup.json" "$CURL_LOG" || fail "backup did not call /cloud/stack/backup.json" "$(cat "$CURL_LOG")"
grep -qxF "containers[0]=${SITEHOST_STACK}" "$CURL_LOG" || fail "backup did not target one container"
rm -f "$JOB_COUNTER"
poll_out="$(JOB_STATES="Running,Running,Completed" bash "$api" poll-job scheduler 7319505 30)"
[[ "$poll_out" == *"state=Running"*"state=Completed"* ]] || fail "poll did not wait for Completed" "$poll_out"
grep -q "https://api.sitehost.nz/1.5/job/get.json" "$CURL_LOG" || fail "poll did not call /job/get.json"
pin_out="$(SNAPSHOT_MODE=pin bash "$snapshots" 2>/dev/null)"
[[ "$pin_out" == "snapshot_id=${NEW_SNAPSHOT}" ]] || fail "pin did not report the new snapshot" "$pin_out"

# 2. A failed job stops with its last log line.
rm -f "$JOB_COUNTER"
set +e
failed_out="$(JOB_STATES="Running,Failed" bash "$api" poll-job scheduler 7319505 30 2>&1)"
failed_status=$?
set -e
[[ "$failed_status" -ne 0 && "$failed_out" == *"ended with state Failed"* && "$failed_out" == *"[backup] Failed"* ]] || fail "a failed job should stop the run" "$failed_out"

# 3. A job that never completes times out.
rm -f "$JOB_COUNTER"
set +e
slow_out="$(JOB_STATES="Running" bash "$api" poll-job scheduler 7319505 2 2>&1)"
slow_status=$?
set -e
[[ "$slow_status" -ne 0 && "$slow_out" == *"Timed out"* ]] || fail "a stuck job should time out" "$slow_out"

# 4. An API error on the backup stops before a job exists.
set +e
denied_out="$(BACKUP_HTTP=401 bash "$api" backup 2>&1)"
denied_status=$?
set -e
[[ "$denied_status" -ne 0 && "$denied_out" == *"HTTP 401"* && "$denied_out" == *"Invalid API key"* ]] || fail "an API error should stop the backup" "$denied_out"
[[ "$denied_out" != *"$SITEHOST_API_KEY"* ]] || fail "an API error printed the API key"

# 5. Restore: break the site, resolve the newest snapshot, restore files and database.
printf 'broken\n' > "${SITEHOST_APP_PATH}/index.php"
printf 'stray\n' > "${SITEHOST_APP_PATH}/stray.php"
newest_out="$(SNAPSHOT_MODE=newest bash "$snapshots" 2>/dev/null)"
[[ "$newest_out" == "snapshot_id=${NEW_SNAPSHOT}" ]] || fail "newest should pick the newest dated snapshot, not latest" "$newest_out"
SNAPSHOT_PATH="${SITEHOST_BACKUP_ROOT}/${NEW_SNAPSHOT}" ROLLBACK_CHECK_ONLY=true bash "$rollback" >/dev/null
: > "$MYSQL_LOG"
restore_out="$(SNAPSHOT_PATH="${SITEHOST_BACKUP_ROOT}/${NEW_SNAPSHOT}" RESTORE_SNAPSHOT_DATABASE=true bash "$rollback" 2>&1)"
[[ "$(cat "${SITEHOST_APP_PATH}/index.php")" == "good" ]] || fail "restore did not bring back the application files" "$restore_out"
[[ ! -e "${SITEHOST_APP_PATH}/stray.php" ]] || fail "restore left a file the snapshot does not have"
grep -q '^mysql .*--host=db.example .*site$' "$MYSQL_LOG" || fail "restore did not load the database" "$(cat "$MYSQL_LOG")"
grep -q 'CREATE TABLE ok;' "$MYSQL_LOG" || fail "restore loaded the wrong dump"
grep -q 'secret' "$MYSQL_LOG" && fail "the database password was passed on the mysql command line"

# 6. newest with no dated snapshot fails and says what to do.
empty="${tmp}/empty-backups"
mkdir -p "$empty/latest-not-dated/application"
set +e
none_out="$(SITEHOST_BACKUP_ROOT="$empty" SNAPSHOT_MODE=newest bash "$snapshots" 2>&1)"
none_status=$?
set -e
[[ "$none_status" -ne 0 && "$none_out" == *"No dated snapshot"* ]] || fail "newest with no dated snapshot should fail" "$none_out"

echo "api backup restore test passed"
