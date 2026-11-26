#!/usr/bin/env bash
# Print the recent PHP lines from the Apache error log. A failed smoke check
# calls this so the job log shows the fatal. The body of an empty 500 does not.
# This step reports. It does not decide whether the deploy failed.
set -euo pipefail

log="${APACHE_ERROR_LOG:-/container/logs/apache2/error.log}"
if [[ ! -f "$log" ]]; then
  echo "Apache error log not found: ${log}"
  exit 0
fi

echo "Recent PHP lines from ${log}:"
matches="$(mktemp)"
cleanup() {
  rm -f "$matches"
}
trap cleanup EXIT
if ! grep -E "PHP Fatal|PHP message" "$log" > "$matches"; then
  echo "No PHP Fatal or PHP message lines in ${log}."
  exit 0
fi
tail -n 15 "$matches" | cut -c1-500
