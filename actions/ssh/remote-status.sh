#!/usr/bin/env bash
# Read-only picture of one container: commit, release, disk, supervisor, snapshots.
# Does not fetch, back up, or change files. origin/main is read with ls-remote.
set -euo pipefail
export LC_ALL=C

if [[ -z "${SITEHOST_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
fi

: "${SITEHOST_APP_PATH:?SITEHOST_APP_PATH is required}"
: "${SITEHOST_BACKUP_ROOT:?SITEHOST_BACKUP_ROOT is required}"

assert_absolute_path "SITEHOST_APP_PATH" "$SITEHOST_APP_PATH"
assert_absolute_path "SITEHOST_BACKUP_ROOT" "$SITEHOST_BACKUP_ROOT"

if [[ ! -d "$SITEHOST_APP_PATH" ]]; then
  echo "App path does not exist: ${SITEHOST_APP_PATH}" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "git must be on PATH" >&2
  exit 1
fi

git_app() {
  git -c safe.directory="$SITEHOST_APP_PATH" -C "$SITEHOST_APP_PATH" "$@"
}

is_semver_tag() {
  [[ "$1" =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

sha="$(git_app rev-parse HEAD)"
printf 'sha=%s\n' "$sha"

origin_main=""
origin_source="none"
if origin_line="$(git_app ls-remote origin refs/heads/main 2>/dev/null)" && [[ -n "$origin_line" ]]; then
  origin_main="${origin_line%%[[:space:]]*}"
  origin_source="remote"
elif origin_main="$(git_app rev-parse --verify --quiet refs/remotes/origin/main)"; then
  origin_source="fetched"
fi
if [[ -z "$origin_main" ]]; then
  echo "on_main=unavailable"
  echo "origin_main=none"
else
  if [[ "$origin_main" == "$sha" ]]; then
    echo "on_main=yes"
  else
    echo "on_main=no"
  fi
  printf 'origin_main=%s\n' "$origin_main"
fi
printf 'origin_main_source=%s\n' "$origin_source"

tags_file="$(mktemp)"
cleanup() {
  rm -f "$tags_file"
}
trap cleanup EXIT

git_app tag --points-at "$sha" > "$tags_file" || true
if remote_tags="$(git_app ls-remote --tags origin 2>/dev/null)"; then
  while IFS=$'\t' read -r tag_sha tag_ref; do
    [[ -n "$tag_sha" && "$tag_sha" == "$sha" ]] || continue
    name="${tag_ref#refs/tags/}"
    name="${name%^*}"
    printf '%s\n' "$name"
  done <<< "$remote_tags" >> "$tags_file"
fi

semver_found=0
while IFS= read -r tag_name; do
  [[ -n "$tag_name" ]] || continue
  if is_semver_tag "$tag_name"; then
    printf 'semver_tag=%s\n' "$tag_name"
    semver_found=1
  fi
done < <(sort -u "$tags_file")
if [[ "$semver_found" -eq 0 ]]; then
  echo "semver_tag=none"
fi

env_file="${SITEHOST_APP_PATH}/.env"
release_line=""
if [[ -f "$env_file" ]]; then
  release_line="$(grep -E '^TALARIA_RELEASE=' "$env_file" | head -n 1 || true)"
fi
if [[ -n "$release_line" ]]; then
  printf '%s\n' "$release_line"
else
  echo "TALARIA_RELEASE=missing"
fi

disk_target="$SITEHOST_APP_PATH"
if [[ -d /container ]]; then
  disk_target=/container
fi
printf 'disk_target=%s\n' "$disk_target"
df -Pk "$disk_target" | awk 'NR==2 { printf "disk_size_kb=%s\ndisk_avail_kb=%s\ndisk_mount=%s\n", $2, $4, $NF }'

echo "supervisorctl:"
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl status || true
else
  echo "supervisorctl is not available"
fi

echo "snapshots:"
if [[ ! -d "$SITEHOST_BACKUP_ROOT" ]]; then
  echo "backup_root=missing"
  echo "snapshots=none"
  exit 0
fi
printf 'backup_root=%s\n' "$SITEHOST_BACKUP_ROOT"
snapshot_list="$(
  find -H "$SITEHOST_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
    | sed '/^latest$/d' \
    | sort -r \
    | awk 'NR<=10'
)"
if [[ -z "$snapshot_list" ]]; then
  echo "snapshots=none"
else
  printf '%s\n' "$snapshot_list"
fi
