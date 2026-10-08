#!/usr/bin/env bash
# Deploys the exact commit over SSH. Backs up the database and public/assets
# first when those options are on, and records which copies this run created.
set -euo pipefail

if [[ -z "${SITEHOST_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

: "${SITEHOST_APP_PATH:?SITEHOST_APP_PATH is required}"
: "${GIT_REMOTE:?GIT_REMOTE is required}"
: "${DEPLOY_SHA:?DEPLOY_SHA is required}"

echo "Remote deploy script started"

log_dir="${DEPLOY_LOG_DIR:-/container/logs}"
dump="${log_dir}/deploy-rollback.sql.gz"
partial="${dump}.partial"
manifest="${log_dir}/deploy-rollback-manifest"
assets_live="${SITEHOST_APP_PATH}/public/assets"
assets_backup="${log_dir}/deploy-rollback-assets"
defaults=""

# Remove the partial dump and the temporary MySQL defaults file when the script exits.
cleanup() {
  rm -f "$partial"
  if [[ -n "$defaults" ]]; then
    rm -f "$defaults"
  fi
}
trap cleanup EXIT

# Run git with this app directory marked safe, so a different file owner does not block it.
gitc() {
  git -c safe.directory="$SITEHOST_APP_PATH" "$@"
}

# Delete every local branch. The checkout is detached, so none of them is current.
delete_other_branches() {
  local branch found
  if [[ "${CLEANUP_STALE_BRANCHES:-}" != "true" ]]; then
    return 0
  fi
  found=0
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    gitc branch -D "$branch"
    found=1
  done < <(gitc for-each-ref --format='%(refname:short)' refs/heads)
  if [[ "$found" -eq 0 ]]; then
    echo "No local branches to remove"
  fi
}

# Replace one KEY="value" line in the container .env, or append it.
write_env_assignment() {
  local key="$1"
  local content="$2"
  local env_file="${SITEHOST_APP_PATH}/.env"
  local line value tmp found
  case "$content" in
    *$'\n'*|*\"*|*\'*|*'#'*)
      echo "${key} contains a character that cannot be written to .env" >&2
      exit 1
      ;;
  esac
  line="${key}=\"${content}\""
  tmp="$(mktemp)"
  found=0
  if [[ -f "$env_file" ]]; then
    while IFS= read -r value || [[ -n "$value" ]]; do
      case "$value" in
        "${key}="*)
          printf '%s\n' "$line"
          found=1
          ;;
        *)
          printf '%s\n' "$value"
          ;;
      esac
    done < "$env_file" > "$tmp"
  fi
  if [[ "$found" -eq 0 ]]; then
    printf '%s\n' "$line" >> "$tmp"
  fi
  mv "$tmp" "$env_file"
}

# Write the release identity into the container .env. Existing lines are replaced.
write_talaria_release() {
  local env_file="${SITEHOST_APP_PATH}/.env"
  : "${TALARIA_RELEASE:?TALARIA_RELEASE is required}"
  : "${TALARIA_COMMIT_SHA:?TALARIA_COMMIT_SHA is required}"
  if [[ ! "$TALARIA_COMMIT_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "TALARIA_COMMIT_SHA must be a 40 character git commit" >&2
    exit 1
  fi
  write_env_assignment TALARIA_RELEASE "$TALARIA_RELEASE"
  write_env_assignment TALARIA_COMMIT_SHA "$TALARIA_COMMIT_SHA"
  echo "Wrote TALARIA_RELEASE=${TALARIA_RELEASE} and TALARIA_COMMIT_SHA to ${env_file}."
}

# Install PHP dependencies and rebuild the Silverstripe database schema.
build_site() {
  if ! command -v composer >/dev/null 2>&1; then
    echo "composer must be on PATH" >&2
    exit 1
  fi
  echo "Installing PHP dependencies..."
  composer install --optimize-autoloader --no-dev --no-progress --no-interaction --prefer-dist
  echo "Build Silverstripe"
  vendor/bin/sake dev/build flush=all
  echo "Silverstripe build completed."
}

# Reload PHP so the new code and .env are the process serving the site.
restart_php() {
  if ! command -v supervisorctl >/dev/null 2>&1; then
    echo "supervisorctl is not available, so php was not restarted." >&2
    exit 1
  fi
  echo "Restarting php"
  supervisorctl restart php
}

# Write a consistent database dump before any files change, so a failed deploy can restore it.
dump_database() {
  require_database_env backup
  if ! command -v mysqldump >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
    echo "Database backup requires mysqldump and gzip on the container." >&2
    exit 1
  fi
  mkdir -p "$log_dir"
  write_mysql_defaults
  echo "Dumping database ${SS_DATABASE_NAME} on ${SS_DATABASE_SERVER} before file changes"
  # --defaults-file must be first. It ignores ~/.my.cnf, which on these
  # containers still names the old mysql57 host. --host repeats
  # SS_DATABASE_SERVER so a later option file cannot replace it.
  if ! mysqldump \
    --defaults-file="$defaults" \
    --host="$SS_DATABASE_SERVER" \
    --protocol=TCP \
    --single-transaction \
    --no-tablespaces \
    --skip-lock-tables \
    "$SS_DATABASE_NAME" | gzip -c > "$partial"
  then
    echo "Could not dump ${SS_DATABASE_NAME} on ${SS_DATABASE_SERVER}. No application files were changed." >&2
    exit 1
  fi
  mv "$partial" "$dump"
  echo "Wrote database dump to ${dump}"
}

# Copy public/assets aside before any files change.
backup_assets() {
  if ! command -v rsync >/dev/null 2>&1; then
    echo "Assets backup requires rsync on the container." >&2
    exit 1
  fi
  if [[ ! -d "$assets_live" ]]; then
    echo "Assets directory not found: ${assets_live}. No application files were changed." >&2
    exit 1
  fi
  case "$assets_backup" in
    "$assets_live"|"$assets_live"/*)
      echo "Refusing to store the assets backup inside ${assets_live}" >&2
      exit 1
      ;;
  esac
  mkdir -p "$log_dir"
  rm -rf -- "$assets_backup"
  echo "Backing up ${assets_live} before file changes"
  rsync --archive --delete "${assets_live}/" "${assets_backup}/"
  echo "Wrote assets backup to ${assets_backup}"
}

# Record which backups this run created, after both copies have succeeded.
write_rollback_manifest() {
  local tmp
  if [[ ! "${ROLLBACK_RUN_ID:-}" =~ ^[0-9]+-[0-9]+$ ]]; then
    echo "ROLLBACK_RUN_ID must be the GitHub run id and attempt." >&2
    exit 1
  fi
  mkdir -p "$log_dir"
  tmp="$(mktemp)"
  printf 'run_id=%s\n' "$ROLLBACK_RUN_ID" > "$tmp"
  if [[ "${BACKUP_DATABASE:-}" == "true" ]]; then
    printf 'database\n' >> "$tmp"
  fi
  if [[ "${BACKUP_ASSETS:-}" == "true" ]]; then
    printf 'assets\n' >> "$tmp"
  fi
  mv "$tmp" "$manifest"
  echo "Recorded rollback manifest ${manifest}"
}

assert_absolute_path "SITEHOST_APP_PATH" "$SITEHOST_APP_PATH"
if [[ ! "$DEPLOY_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "DEPLOY_SHA must be a 40 character git commit" >&2
  exit 1
fi
if [[ ! "$GIT_REMOTE" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]]; then
  echo "GIT_REMOTE must be a GitHub SSH remote" >&2
  exit 1
fi
if [[ "${BACKUP_DATABASE:-}" == "true" ]]; then
  require_database_env backup
fi
if [[ "${BACKUP_DATABASE:-}" == "true" || "${BACKUP_ASSETS:-}" == "true" ]]; then
  if [[ ! "${ROLLBACK_RUN_ID:-}" =~ ^[0-9]+-[0-9]+$ ]]; then
    echo "ROLLBACK_RUN_ID must be the GitHub run id and attempt." >&2
    exit 1
  fi
fi
if ! command -v git >/dev/null 2>&1; then
  echo "git must be on PATH" >&2
  exit 1
fi
if [[ ! -d "$SITEHOST_APP_PATH/.git" ]]; then
  echo "No git checkout at ${SITEHOST_APP_PATH}. The container deploy key checkout must already exist." >&2
  exit 1
fi

if [[ "${BACKUP_DATABASE:-}" == "true" ]]; then
  dump_database
fi
if [[ "${BACKUP_ASSETS:-}" == "true" ]]; then
  backup_assets
fi
if [[ "${BACKUP_DATABASE:-}" == "true" || "${BACKUP_ASSETS:-}" == "true" ]]; then
  write_rollback_manifest
fi

cd "$SITEHOST_APP_PATH"
gitc remote set-url origin "$GIT_REMOTE"
echo "Fetching ${DEPLOY_SHA}"
gitc fetch origin "$DEPLOY_SHA"
gitc checkout --force --detach "$DEPLOY_SHA"
delete_other_branches
build_site
write_talaria_release
restart_php
echo "Deployed ${DEPLOY_SHA} at ${SITEHOST_APP_PATH}"
gitc rev-parse HEAD
gitc status -sb
