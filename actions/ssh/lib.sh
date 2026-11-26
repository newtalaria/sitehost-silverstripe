#!/usr/bin/env bash
# Path checks and MySQL client defaults shared by the remote scripts.
# ssh-payload.sh prepends this file onto the encoded script, so the container
# receives the functions in the same bash process. A script run as a file
# sources this file when SITEHOST_LIB_LOADED is unset.

# Remote scripts skip their own source when this is already set.
export SITEHOST_LIB_LOADED=1

# Reject a path that is relative, contains "..", or is the filesystem root.
assert_absolute_path() {
  local label="$1"
  local value="$2"
  case "$value" in
    /*) ;;
    *)
      echo "${label} must be an absolute path" >&2
      exit 1
      ;;
  esac
  case "$value" in
    *..*)
      echo "${label} must not contain .." >&2
      exit 1
      ;;
  esac
  if [[ "$value" == "/" ]]; then
    echo "Refusing to use / as ${label}" >&2
    exit 1
  fi
}

# Escape a value so it can sit inside a quoted MySQL option-file entry.
mysql_ini_value() {
  local value="${1//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

# Stop unless the four Silverstripe database variables are set and contain no newlines.
# purpose is "backup" or "restore" and is included in the error text.
require_database_env() {
  local purpose="$1"
  local name
  for name in SS_DATABASE_SERVER SS_DATABASE_USERNAME SS_DATABASE_PASSWORD SS_DATABASE_NAME; do
    if [[ -z "${!name:-}" ]]; then
      echo "Database ${purpose} requires ${name} in the SSH session before any file changes." >&2
      exit 1
    fi
    case "${!name}" in
      *$'\n'*)
        echo "${name} contains a newline and cannot be used for the database ${purpose}." >&2
        exit 1
        ;;
    esac
  done
}

# Wait for the backup root to appear. SiteHost links it to an automounted
# directory that is only mounted once something opens it, so the first check
# in a fresh SSH session can miss it. Listing it starts the mount.
wait_for_backup_root() {
  local wait_seconds="${BACKUP_ROOT_WAIT_SECONDS:-30}"
  local poll_seconds="${BACKUP_ROOT_POLL_SECONDS:-2}"
  if [[ ! "$wait_seconds" =~ ^[0-9]+$ || ! "$poll_seconds" =~ ^[0-9]+$ || "$poll_seconds" -lt 1 ]]; then
    echo "BACKUP_ROOT_WAIT_SECONDS and BACKUP_ROOT_POLL_SECONDS must be whole numbers" >&2
    exit 1
  fi
  local start=$SECONDS
  while true; do
    ls -A "${SITEHOST_BACKUP_ROOT%/}/" >/dev/null 2>&1 || true
    if [[ -d "$SITEHOST_BACKUP_ROOT" ]]; then
      return 0
    fi
    if (( SECONDS - start >= wait_seconds )); then
      return 1
    fi
    echo "Waiting for the backup root to mount: ${SITEHOST_BACKUP_ROOT}" >&2
    sleep "$poll_seconds"
  done
}

# Silverstripe stores compiled config in a per-user directory under the system
# temp dir. The SSH session and php-fpm are different containers and do not
# share /tmp, so `sake dev/build flush=all` never clears the cache the site
# serves. Silverstripe prefers <app>/silverstripe-cache when that directory
# exists, and both containers see the application path. Recreate it empty so
# the next web request compiles the files now on disk.
reset_silverstripe_web_cache() {
  local cache="${SITEHOST_APP_PATH}/silverstripe-cache"
  local old_umask
  assert_absolute_path "SITEHOST_APP_PATH" "$SITEHOST_APP_PATH"
  echo "Resetting the Silverstripe cache the web server reads: ${cache}"
  rm -rf -- "$cache"
  old_umask="$(umask)"
  umask 0
  mkdir -m 0777 "$cache"
  umask "$old_umask"
  printf '%s\n' 'Require all denied' > "${cache}/.htaccess"
  chmod 0777 "$cache"
}

# Reload PHP so the process serving the site reads the new code and .env.
restart_php_supervisor() {
  if ! command -v supervisorctl >/dev/null 2>&1; then
    echo "supervisorctl is not available, so php was not restarted." >&2
    exit 1
  fi
  echo "Restarting php"
  supervisorctl restart php
}

# Write the database host, user, and password to a private MySQL defaults file.
# Sets the global `defaults` path. The caller's EXIT trap removes that file.
write_mysql_defaults() {
  defaults="$(mktemp)"
  chmod 600 "$defaults"
  {
    printf '%s\n' '[client]'
    printf 'host="%s"\n' "$(mysql_ini_value "$SS_DATABASE_SERVER")"
    if [[ -n "${SS_DATABASE_PORT:-}" ]]; then
      printf 'port="%s"\n' "$(mysql_ini_value "$SS_DATABASE_PORT")"
    fi
    printf 'user="%s"\n' "$(mysql_ini_value "$SS_DATABASE_USERNAME")"
    printf 'password="%s"\n' "$(mysql_ini_value "$SS_DATABASE_PASSWORD")"
  } > "$defaults"
}
