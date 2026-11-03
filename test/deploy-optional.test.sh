#!/usr/bin/env bash
# shellcheck disable=SC2016
# remote-deploy.sh without Talaria, with Talaria, and with Talaria unreachable.
# Local database and assets backups never run, even when a caller asks.
# git, composer, sake, supervisorctl, mysqldump, rsync, and the Talaria
# installer are stubs. Nothing leaves this machine.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
deploy="${root}/actions/ssh/remote-deploy.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "deploy-optional: $1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" >&2
  fi
  exit 1
}

bin="${tmp}/bin"
mkdir -p "$bin"
export CALLS="${tmp}/calls.log"
for cmd in git composer supervisorctl mysqldump mysql rsync; do
  cat > "${bin}/${cmd}" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "${cmd}" "\$*" >> "\$CALLS"
STUB
  chmod +x "${bin}/${cmd}"
done
export PATH="${bin}:${PATH}"

app="${tmp}/app"
mkdir -p "${app}/.git" "${app}/vendor/bin" "${app}/public/assets" "${app}/talaria/sitehost"
printf '{}\n' > "${app}/talaria/sitehost/monitors.json"
printf '#!/usr/bin/env bash\nprintf "sake %%s\\n" "$*" >> "$CALLS"\n' > "${app}/vendor/bin/sake"
cat > "${app}/vendor/bin/talaria-sitehost" <<'STUB'
#!/usr/bin/env bash
printf 'talaria-sitehost %s\n' "$*" >> "$CALLS"
exit "${INSTALLER_EXIT:-0}"
STUB
chmod +x "${app}/vendor/bin/sake" "${app}/vendor/bin/talaria-sitehost"

run_deploy() {
  : > "$CALLS"
  rm -f "${app}/.env"
  set +e
  out="$(
    env -u TALARIA_ENABLED -u TALARIA_REACHABLE -u TALARIA_API_KEY \
      -u SITEHOST_LIB_LOADED -u SITEHOST_RUNTIME_LOADED -u SITEHOST_COLLECTOR_LOADED \
      SITEHOST_APP_PATH="$app" \
      DEPLOY_LOG_DIR="${tmp}/logs" \
      GIT_REMOTE="git@github.com:example/site.git" \
      DEPLOY_SHA="0123456789abcdef0123456789abcdef01234567" \
      TALARIA_RELEASE="main@0123456" \
      TALARIA_COMMIT_SHA="0123456789abcdef0123456789abcdef01234567" \
      ROLLBACK_RUN_ID="1-1" \
      SS_DATABASE_SERVER=db SS_DATABASE_USERNAME=u SS_DATABASE_PASSWORD=p SS_DATABASE_NAME=site \
      "$@" bash "$deploy" 2>&1
  )"
  status=$?
  set -e
}

# 1. No Talaria, and BACKUP_* set on the container: the retained local backup code stays off.
run_deploy BACKUP_DATABASE=true BACKUP_ASSETS=true
[[ "$status" -eq 0 ]] || fail "a deploy without Talaria should succeed" "$out"
[[ "$out" == *"Local database and assets backups are disabled"* ]] || fail "should say local backups are disabled" "$out"
[[ "$out" == *"Talaria is off for this deploy"* ]] || fail "should say Talaria is off" "$out"
[[ "$out" == *"monitors.json is present, but no Talaria key is set"* ]] || fail "should mention unregistered monitors" "$out"
grep -q '^mysqldump' "$CALLS" && fail "ran mysqldump with local backups disabled"
grep -q '^rsync' "$CALLS" && fail "copied assets with local backups disabled"
grep -q '^talaria-sitehost' "$CALLS" && fail "ran the Talaria installer without Talaria"
[[ ! -e "${tmp}/logs/deploy-rollback-manifest" ]] || fail "wrote a local rollback manifest"
[[ ! -f "${app}/.env" ]] || ! grep -q TALARIA "${app}/.env" || fail "wrote TALARIA_RELEASE without Talaria"
grep -q '^git .*checkout --force --detach 0123456789abcdef0123456789abcdef01234567' "$CALLS" || fail "did not check out the commit" "$(cat "$CALLS")"
grep -q '^sake dev/build flush=all' "$CALLS" || fail "did not run dev/build"
grep -q '^supervisorctl restart php' "$CALLS" || fail "did not restart php"

# 2. Talaria on and reachable: release in .env, installer runs, its failure fails the deploy.
run_deploy TALARIA_ENABLED=true TALARIA_REACHABLE=true INSTALLER_EXIT=0 TALARIA_API_KEY=unused
# The installer stub succeeds, so the collector install runs next. It rejects
# the placeholder key before any download, which proves the Talaria path ran
# and fails closed.
[[ "$status" -ne 0 && "$out" == *"TALARIA_API_KEY must match"* ]] || fail "the collector should reject the placeholder key" "$out"
grep -q '^talaria-sitehost install' "$CALLS" || fail "Talaria on should run the installer" "$out"
grep -q '^TALARIA_RELEASE="main@0123456"$' "${app}/.env" || fail "Talaria on should write TALARIA_RELEASE"
run_deploy TALARIA_ENABLED=true TALARIA_REACHABLE=true INSTALLER_EXIT=3
[[ "$status" -ne 0 ]] || fail "an installer failure with Talaria reachable should fail" "$out"
grep -q '^supervisorctl restart php' "$CALLS" && fail "restarted php after a failed Talaria install"

# 3. Talaria on but unreachable at the key check: installer failure is a warning.
run_deploy TALARIA_ENABLED=true TALARIA_REACHABLE=false INSTALLER_EXIT=3
[[ "$status" -eq 0 ]] || fail "an outage should not fail the deploy" "$out"
[[ "$out" == *"::warning title=Talaria install skipped::"* ]] || fail "an outage should warn" "$out"
grep -q '^supervisorctl restart php' "$CALLS" || fail "an outage should still restart php"

echo "deploy optional test passed"
