#!/usr/bin/env bash
# Choose the next semver tag, refuse a tag that already exists, and draft notes.
#   version.sh next <patch|minor|major> [latest-tag]
#   version.sh require-absent <tag>
#   version.sh notes [latest-tag]
# A latest tag that is not MAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH yields 1.0.0.
# This does not move the action repository's v1 pin.
set -euo pipefail

is_semver_tag() {
  [[ "$1" =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

cmd_next() {
  local bump="$1"
  local latest="${2:-}"
  local prefix="" rest major minor patch
  case "$bump" in
    patch|minor|major) ;;
    *)
      echo "bump must be patch, minor, or major." >&2
      exit 1
      ;;
  esac
  if [[ -z "$latest" ]] || ! is_semver_tag "$latest"; then
    printf '%s\n' "1.0.0"
    return 0
  fi
  if [[ "$latest" == v* ]]; then
    prefix="v"
  fi
  rest="${latest#v}"
  IFS=. read -r major minor patch <<< "$rest"
  case "$bump" in
    patch) patch=$((10#$patch + 1)) ;;
    minor) minor=$((10#$minor + 1)); patch=0 ;;
    major) major=$((10#$major + 1)); minor=0; patch=0 ;;
  esac
  printf '%s%s.%s.%s\n' "$prefix" "$major" "$minor" "$patch"
}

cmd_require_absent() {
  local tag="$1"
  if ! is_semver_tag "$tag"; then
    echo "Refusing to create ${tag}." >&2
    exit 1
  fi
  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    echo "Tag ${tag} already exists." >&2
    exit 1
  fi
}

cmd_notes() {
  local latest="${1:-}"
  if [[ -z "$latest" ]]; then
    echo "No previous tag. Starting at 1.0.0."
    echo
    git log -30 --pretty=tformat:%s
    return 0
  fi
  if is_semver_tag "$latest"; then
    git log "${latest}..HEAD" --pretty=tformat:%s
    return 0
  fi
  echo "Previous tag ${latest} is not a semver release. Starting at 1.0.0."
  echo
  git log -30 --pretty=tformat:%s
}

case "${1:-}" in
  next)
    shift
    cmd_next "$@"
    ;;
  require-absent)
    shift
    cmd_require_absent "$@"
    ;;
  notes)
    shift
    cmd_notes "$@"
    ;;
  *)
    echo "Usage: version.sh next|require-absent|notes ..." >&2
    exit 1
    ;;
esac
