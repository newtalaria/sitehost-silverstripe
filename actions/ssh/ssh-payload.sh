#!/usr/bin/env bash
# Write a one-line remote command that runs a bash script on the container.
# The SSH action would otherwise run only the first line, and "bash -s" exits
# before the deploy script starts.
# When lib.sh sits next to SOURCE, it is prepended so the remote bash process
# has the shared functions without a second file on the container.
set -euo pipefail

if [[ "$#" -lt 2 ]]; then
  echo "Usage: ssh-payload.sh SOURCE DEST ENV_NAME..." >&2
  exit 1
fi

src="$1"
dest="$2"
shift 2

for name in "$@"; do
  if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "Refusing to export ${name}" >&2
    exit 1
  fi
done

src_dir="$(cd "$(dirname "$src")" && pwd)"
body="$(mktemp)"
cleanup() {
  rm -f "$body"
}
trap cleanup EXIT

parts=()
base="$(basename "$src")"
if [[ -f "${src_dir}/lib.sh" && "$base" != "lib.sh" ]]; then
  parts+=("${src_dir}/lib.sh")
fi
if [[ -f "${src_dir}/collector.sh" && "$base" != "collector.sh" ]]; then
  parts+=("${src_dir}/collector.sh")
fi
if [[ -f "${src_dir}/runtime-health.sh" && "$base" != "runtime-health.sh" ]]; then
  parts+=("${src_dir}/runtime-health.sh")
fi
if [[ "${#parts[@]}" -gt 0 ]]; then
  cat "${parts[@]}" "$src" > "$body"
else
  cat "$src" > "$body"
fi

# The remote bash process has no checkout of this action. Embed the preset
# when the collector adapter is part of the payload.
payload_root="$(cd "$(dirname "$0")/../.." && pwd)"
preset="${payload_root}/collector/preset.yaml"
if [[ -f "${src_dir}/collector.sh" && "$base" != "collector.sh" && -f "$preset" ]]; then
  preset_b64="$(base64 < "$preset" | tr -d '\n')"
  {
    printf "TALARIA_COLLECTOR_PRESET_B64='%s'\n" "$preset_b64"
    cat "$body"
  } > "${body}.with-preset"
  mv "${body}.with-preset" "$body"
fi

encoded="$(base64 < "$body" | tr -d '\n')"
exports=""
for name in "$@"; do
  value="${!name-}"
  escaped="${value//\'/\'\\\'\'}"
  exports+="export ${name}='${escaped}'; "
done

printf "/bin/bash -c 'set -o pipefail; %secho %s | base64 -d | /bin/bash'\n" "$exports" "$encoded" > "$dest"
