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
