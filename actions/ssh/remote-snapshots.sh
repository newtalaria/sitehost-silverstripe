#!/usr/bin/env bash
# Records container backup directories and pins the one created for this deploy.
# The pinned path is stored on the container. The script never follows "latest".
set -euo pipefail
export LC_ALL=C

if [[ -z "${SITEHOST_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

: "${SITEHOST_BACKUP_ROOT:?SITEHOST_BACKUP_ROOT is required}"
: "${SNAPSHOT_MODE:?SNAPSHOT_MODE is required}"

log_dir="${DEPLOY_LOG_DIR:-/container/logs}"
before_file="${log_dir}/deploy-snapshots-before.txt"
pinned_file="${log_dir}/deploy-snapshot-path.txt"

# Require SITEHOST_BACKUP_ROOT to be an existing absolute directory, and not /.
assert_backup_root() {
  assert_absolute_path "SITEHOST_BACKUP_ROOT" "$SITEHOST_BACKUP_ROOT"
  if [[ ! -d "$SITEHOST_BACKUP_ROOT" ]]; then
    echo "Backup root does not exist: ${SITEHOST_BACKUP_ROOT}" >&2
    exit 1
  fi
}

# List real snapshot directories under SITEHOST_BACKUP_ROOT, skipping the latest symlink.
list_snapshot_names() {
  find "$SITEHOST_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

# Reject an empty, hidden, nested, or path-traversal snapshot name.
assert_snapshot_name() {
  local name="$1"
  case "$name" in
    ""|.*|*/*|*$'\n'*|*'..'*)
      echo "Unexpected snapshot directory name: ${name}" >&2
      exit 1
      ;;
  esac
}

# Save the snapshot names that already exist before this deploy's backup starts.
record_snapshots() {
  mkdir -p "$log_dir"
  list_snapshot_names > "$before_file"
  echo "Recorded $(wc -l < "$before_file" | tr -d ' ') existing snapshot directories"
}

# Keep the single new snapshot directory and store its path for rollback.
pin_snapshot() {
  if [[ ! -f "$before_file" ]]; then
    echo "Missing snapshot list from before the backup: ${before_file}" >&2
    exit 1
  fi
  local current new_names count name path
  current="$(mktemp)"
  list_snapshot_names > "$current"
  new_names="$(comm -13 "$before_file" "$current")"
  rm -f "$current"
  count="$(printf '%s\n' "$new_names" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$count" != "1" ]]; then
    echo "Expected exactly one new snapshot directory under ${SITEHOST_BACKUP_ROOT}, found ${count}" >&2
    printf '%s\n' "$new_names" >&2
    exit 1
  fi
  name="$(printf '%s\n' "$new_names" | sed '/^$/d')"
  assert_snapshot_name "$name"
  path="${SITEHOST_BACKUP_ROOT%/}/${name}"
  if [[ ! -d "${path}/application" ]]; then
    echo "Pinned snapshot has no application directory: ${path}/application" >&2
    exit 1
  fi
  if [[ -z "$(ls -A "${path}/application")" ]]; then
    echo "Refusing to pin an empty application snapshot: ${path}/application" >&2
    exit 1
  fi
  printf '%s\n' "$path" > "$pinned_file"
  echo "Pinned snapshot ${path}"
}

# Delete the temporary snapshot list, pinned path, and database dump after a successful deploy.
cleanup_deploy_files() {
  if [[ -d "$log_dir" ]]; then
    rm -f \
      "$before_file" \
      "$pinned_file" \
      "${log_dir}/deploy-rollback.sql.gz" \
      "${log_dir}/deploy-rollback.sql.gz.partial"
  fi
  echo "Removed deploy rollback files from ${log_dir}"
}

case "$SNAPSHOT_MODE" in
  record)
    assert_backup_root
    record_snapshots
    ;;
  pin)
    assert_backup_root
    pin_snapshot
    ;;
  cleanup)
    cleanup_deploy_files
    ;;
  *)
    echo "SNAPSHOT_MODE must be record, pin, or cleanup" >&2
    exit 1
    ;;
esac
