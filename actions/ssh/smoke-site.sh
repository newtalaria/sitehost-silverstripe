#!/usr/bin/env bash
# Request SITEHOST_SITE_URL from the runner. A 2xx status passes. Anything else
# fails the job after printing the status and a short excerpt of the body.
# Retries cover the window after php restarts. This script does not SSH.
set -euo pipefail

: "${SITEHOST_SITE_URL:?SITEHOST_SITE_URL is required}"

attempts="${SMOKE_ATTEMPTS:-9}"
delay="${SMOKE_DELAY_SECONDS:-10}"
if [[ ! "$attempts" =~ ^[1-9][0-9]*$ || ! "$delay" =~ ^[0-9]+$ ]]; then
  echo "SMOKE_ATTEMPTS must be a positive whole number and SMOKE_DELAY_SECONDS a whole number" >&2
  exit 1
fi

case "$SITEHOST_SITE_URL" in
  https://*|http://*) ;;
  *)
    echo "SITEHOST_SITE_URL must start with http:// or https://" >&2
    exit 1
    ;;
esac

meta="$(mktemp)"
body="$(mktemp)"
cleanup() {
  rm -f "$meta" "$body"
}
trap cleanup EXIT

attempt=1
while true; do
  code="000"
  final="$SITEHOST_SITE_URL"
  : > "$meta"
  : > "$body"
  if curl --silent --show-error --location \
    --output "$body" \
    --max-time 30 \
    --write-out '%{http_code} %{url_effective}' \
    "$SITEHOST_SITE_URL" > "$meta"; then
    line="$(tr -d '\r' < "$meta")"
    code="${line%% *}"
    if [[ "$line" == *" "* ]]; then
      final="${line#* }"
    fi
  else
    echo "Smoke check attempt ${attempt}: the request did not finish for ${SITEHOST_SITE_URL}" >&2
    code="000"
  fi
  echo "Smoke check attempt ${attempt}: HTTP ${code} ${final}"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    exit 0
  fi
  if [[ "$attempt" -ge "$attempts" ]]; then
    break
  fi
  echo "Retrying in ${delay}s."
  sleep "$delay"
  attempt=$((attempt + 1))
done

if [[ -s "$body" ]]; then
  excerpt="$(tr '\n\r' '  ' < "$body" | sed 's/<[^>]*>//g; s/[[:space:]]\+/ /g' | cut -c1-400)"
  echo "Response excerpt: ${excerpt}"
else
  echo "Response body was empty."
fi
echo "Smoke check failed: HTTP ${code} ${final}" >&2
exit 1
