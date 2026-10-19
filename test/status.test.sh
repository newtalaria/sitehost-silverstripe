#!/usr/bin/env bash
# Status prints the commit, release, disk, supervisor, and snapshot names. It does not follow latest.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
status="${root}/actions/ssh/remote-status.sh"
restart="${root}/actions/ssh/remote-restart-php.sh"

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

app="${tmp}/application"
origin="${tmp}/origin.git"
backups="${tmp}/backups"
mkdir -p "$app" "$backups/2026-10-18_14:33:56" "$backups/2026-10-19_09:43:28"
ln -s old "$backups/latest"
git init -b main "$app" >/dev/null
git -C "$app" config user.email test@example.com
git -C "$app" config user.name test
printf 'live\n' > "$app/index.php"
printf 'TALARIA_RELEASE=main@abc1234\nSS_DATABASE_PASSWORD=secret\n' > "$app/.env"
git -C "$app" add index.php .env
git -C "$app" commit -m start >/dev/null
git init --bare "$origin" >/dev/null
git -C "$app" remote add origin "$origin"
git -C "$app" push origin main >/dev/null
git -C "$app" tag 1.2.5
git -C "$app" tag v1
git -C "$app" push origin 1.2.5 v1 >/dev/null

mkdir -p "${tmp}/bin"
cat > "${tmp}/bin/supervisorctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SUPERVISOR_ARGS"
echo "php                            RUNNING"
EOF
chmod +x "${tmp}/bin/supervisorctl"

export SITEHOST_APP_PATH="$app"
export SITEHOST_BACKUP_ROOT="$backups"
export SUPERVISOR_ARGS="${tmp}/supervisor-args"
export PATH="${tmp}/bin:${PATH}"

report="$(bash "$status")"
if [[ "$report" == *"secret"* ]]; then
  echo "status printed a value from .env that is not TALARIA_RELEASE" >&2
  exit 1
fi
for needle in \
  "on_main=yes" \
  "origin_main_source=remote" \
  "semver_tag=1.2.5" \
  "TALARIA_RELEASE=main@abc1234" \
  "disk_avail_kb=" \
  "php                            RUNNING" \
  "2026-10-19_09:43:28" \
  "2026-10-18_14:33:56"
do
  if [[ "$report" != *"$needle"* ]]; then
    echo "status report missing: ${needle}" >&2
    printf '%s\n' "$report" >&2
    exit 1
  fi
done
if [[ "$report" == *"semver_tag=v1"* || "$report" == *$'\nlatest\n'* || "$report" == *"snapshots:"*$'\n'"latest"* ]]; then
  echo "status should skip the v1 tag and the latest snapshot name" >&2
  printf '%s\n' "$report" >&2
  exit 1
fi

printf 'changed\n' >> "$app/index.php"
git -C "$app" add index.php
git -C "$app" commit -m changed >/dev/null
ahead="$(bash "$status")"
if [[ "$ahead" != *"on_main=no"* || "$ahead" != *"semver_tag=none"* ]]; then
  echo "a commit that is not main and has no semver tag should say so" >&2
  printf '%s\n' "$ahead" >&2
  exit 1
fi

restart_out="$(bash "$restart")"
if [[ "$restart_out" != *"Restarting php"* || "$(cat "$SUPERVISOR_ARGS")" != "restart php" ]]; then
  echo "php restart should call supervisorctl restart php" >&2
  printf '%s\n' "$restart_out" >&2
  exit 1
fi

export PATH="/usr/bin:/bin"
set +e
missing_supervisor="$(bash "$restart" 2>&1)"
missing_status=$?
set -e
if [[ "$missing_status" -eq 0 || "$missing_supervisor" != *"not available"* ]]; then
  echo "php restart should fail when supervisorctl is missing" >&2
  printf '%s\n' "$missing_supervisor" >&2
  exit 1
fi

echo "status test passed"
