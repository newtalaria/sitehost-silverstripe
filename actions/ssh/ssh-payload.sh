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

if [[ -f "${src_dir}/lib.sh" && "$(basename "$src")" != "lib.sh" ]]; then
  cat "${src_dir}/lib.sh" "$src" > "$body"
else
  cat "$src" > "$body"
fi

encoded="$(base64 < "$body" | tr -d '\n')"
exports=""
for name in "$@"; do
  value="${!name-}"
  escaped="${value//\'/\'\\\'\'}"
  exports+="export ${name}='${escaped}'; "
done

printf "/bin/bash -c 'set -o pipefail; %secho %s | base64 -d | /bin/bash'\n" "$exports" "$encoded" > "$dest"
