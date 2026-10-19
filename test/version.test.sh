#!/usr/bin/env bash
# Semver bumps. A latest tag that is not MAJOR.MINOR.PATCH starts at 1.0.0.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${root}/actions/version.sh"

expect_next() {
  local bump="$1"
  local latest="$2"
  local want="$3"
  local got
  got="$(bash "$version" next "$bump" "$latest")"
  if [[ "$got" != "$want" ]]; then
    echo "next ${bump} from '${latest}' was '${got}', expected '${want}'" >&2
    exit 1
  fi
}

expect_next patch "1.2.5" "1.2.6"
expect_next minor "1.2.5" "1.3.0"
expect_next major "1.2.5" "2.0.0"
expect_next patch "v1.2.5" "v1.2.6"
expect_next minor "v1.2.5" "v1.3.0"
expect_next major "v1.2.5" "v2.0.0"
expect_next patch "v1" "1.0.0"
expect_next minor "" "1.0.0"
expect_next major "nightly" "1.0.0"
expect_next patch "main" "1.0.0"

set +e
bad="$(bash "$version" next beta "1.2.5" 2>&1)"
bad_status=$?
set -e
if [[ "$bad_status" -eq 0 || "$bad" != *"patch, minor, or major"* ]]; then
  echo "an unknown bump should fail" >&2
  printf '%s\n' "$bad" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

git init -b main "$tmp/repo" >/dev/null
git -C "$tmp/repo" config user.email test@example.com
git -C "$tmp/repo" config user.name test
echo start > "$tmp/repo/file"
git -C "$tmp/repo" add file
git -C "$tmp/repo" commit -m "Start the app" >/dev/null
git -C "$tmp/repo" tag 1.2.6
git -C "$tmp/repo" tag v1

(
  cd "$tmp/repo"
  set +e
  exists="$(bash "$version" require-absent 1.2.6 2>&1)"
  exists_status=$?
  set -e
  if [[ "$exists_status" -eq 0 || "$exists" != *"already exists"* ]]; then
    echo "an existing target tag should fail" >&2
    printf '%s\n' "$exists" >&2
    exit 1
  fi
  bash "$version" require-absent 1.2.7 >/dev/null

  notes="$(bash "$version" notes "")"
  if [[ "$notes" != *"No previous tag"* || "$notes" != *"Start the app"* ]]; then
    echo "notes for a repo with no tag should start at 1.0.0 and list commits" >&2
    printf '%s\n' "$notes" >&2
    exit 1
  fi
  ignored="$(bash "$version" notes "v1")"
  if [[ "$ignored" != *"not a semver release"* || "$ignored" != *"v1"* || "$ignored" != *"Start the app"* ]]; then
    echo "notes should ignore a latest tag that is not semver" >&2
    printf '%s\n' "$ignored" >&2
    exit 1
  fi
)

echo next > "$tmp/repo/file"
git -C "$tmp/repo" add file
git -C "$tmp/repo" commit -m "Ship the next change" >/dev/null
git -C "$tmp/repo" tag 1.2.5 HEAD~1
since="$(
  cd "$tmp/repo"
  bash "$version" notes 1.2.5
)"
if [[ "$since" != *"Ship the next change"* || "$since" == *"Start the app"* ]]; then
  echo "notes should list commits since the previous semver tag" >&2
  printf '%s\n' "$since" >&2
  exit 1
fi

echo "version test passed"
