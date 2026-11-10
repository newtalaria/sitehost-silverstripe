#!/usr/bin/env bash
# Decide whether this deploy uses Talaria, before any backup or file change.
#
# Talaria is optional. The deploy and the SiteHost backup run the same way
# without it.
#
#   No Talaria setting at all    One ::warning::, a summary line, enabled=false.
#   Some settings, others needed Fail and name each missing setting.
#   Malformed key                Fail. Same grammar and checksum as the SDK.
#   Key rejected (401 or 403)    Fail. The key is wrong, revoked, or for another cell.
#   Quota exceeded (402)         ::warning:: and continue. The key was accepted
#                                and the plan quota is used up.
#   Other 4xx                    Fail. TALARIA_URL is most likely wrong.
#   Timeout, 408, 429, or 5xx    ::warning:: and continue with enabled=true and
#                                reachable=false. The deploy then treats each
#                                Talaria step as best effort, so a Talaria
#                                outage or a full quota does not block a deploy.
#
# The check is GET /v1/sdk-config with Authorization: Bearer. It accepts any
# pk or sk key, needs no scope, and writes nothing. It proves the key is live
# for this cell. It cannot prove releases:write or monitors:write without a
# write, so a missing scope still fails at the step that needs it.
#
# Reads TALARIA_API_KEY and TALARIA_URL as found by talaria-resolve.sh (the
# workflow value, else the SiteHost container), plus TALARIA_RELEASE_KEY,
# TALARIA_BROWSER_API_KEY, and UPLOAD_SOURCE_MAPS. A browser key must be a
# publishable tal_pk_ key. It does not turn Talaria on by itself.
# Writes enabled=true|false and reachable=true|false to GITHUB_OUTPUT.
# Never prints a key.
set -euo pipefail

if ! declare -F talaria_collector_key_cell >/dev/null; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/collector.sh"
fi

TALARIA_CHECK_TIMEOUT="${TALARIA_CHECK_TIMEOUT:-15}"
TALARIA_SDK_CONFIG_PATH="/v1/sdk-config"
environment="${DEPLOY_ENVIRONMENT:-this environment}"

api_key="$(talaria_collector_trim "${TALARIA_API_KEY:-}")"
release_key="$(talaria_collector_trim "${TALARIA_RELEASE_KEY:-}")"
browser_key="$(talaria_collector_trim "${TALARIA_BROWSER_API_KEY:-}")"
url="$(talaria_collector_trim "${TALARIA_URL:-}")"
upload_source_maps="${UPLOAD_SOURCE_MAPS:-false}"

# Record one key=value for the calling step.
output() {
  printf '%s\n' "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}

# Append markdown lines to the job summary when there is one.
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Mask every non-empty key so a later step cannot echo it.
mask() {
  local value
  for value in "$@"; do
    if [[ -n "$value" ]]; then
      echo "::add-mask::${value}"
    fi
  done
}

mask "$api_key" "$release_key" "$browser_key"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A browser key is optional. When the workflow sent one, it must be a
# publishable key before anything is written to the container.
if [[ -n "$browser_key" ]]; then
  if [[ "$browser_key" != tal_pk_* ]]; then
    echo "TALARIA_BROWSER_API_KEY must be a publishable tal_pk_ key. A secret or monitor key cannot be used here." >&2
    exit 1
  fi
  if ! talaria_collector_key_cell "$browser_key" >/dev/null 2>"${tmp}/err"; then
    sed "s/TALARIA_API_KEY/TALARIA_BROWSER_API_KEY/g" "${tmp}/err" >&2
    exit 1
  fi
fi

if [[ -z "$api_key" && -z "$release_key" && -z "$url" ]]; then
  if [[ -n "$browser_key" ]]; then
    echo "::warning title=Talaria skipped::TALARIA_API_KEY is not set, so releases, source maps, job check-ins, and the collector are skipped. TALARIA_BROWSER_API_KEY from the workflow is written to the SiteHost container. The backup and deploy continue."
    summary "### Talaria" "" "Skipped. No \`TALARIA_API_KEY\` is set for \`${environment}\`. \`TALARIA_BROWSER_API_KEY\` from the workflow is written to the SiteHost container."
  else
    echo "::warning title=Talaria skipped::Talaria keys are not set, so the Talaria integration is skipped. The backup and deploy continue."
    summary "### Talaria" "" "Skipped. No Talaria key is set for \`${environment}\`. Source maps, the release in \`.env\`, job check-ins, and the log collector did not run. Set \`TALARIA_API_KEY\` to turn them on."
  fi
  output enabled=false
  output reachable=false
  exit 0
fi

# Some Talaria settings are present. Every one this run needs must be present too.
missing=()
if [[ -z "$api_key" ]]; then
  missing+=(TALARIA_API_KEY)
fi
if [[ "$upload_source_maps" == "true" && -z "$release_key" ]]; then
  missing+=(TALARIA_RELEASE_KEY)
fi
if [[ "${#missing[@]}" -gt 0 ]]; then
  present=()
  [[ -n "$api_key" ]] && present+=(TALARIA_API_KEY)
  [[ -n "$release_key" ]] && present+=(TALARIA_RELEASE_KEY)
  [[ -n "$url" ]] && present+=(TALARIA_URL)
  echo "Talaria is partly configured for ${environment}. Set: ${present[*]}. Missing: ${missing[*]}." >&2
  echo "Set the missing names as secrets on the environment, the repository, or the organisation, and pass them in the caller's secrets map." >&2
  echo "To deploy without Talaria, remove every Talaria setting instead." >&2
  exit 1
fi

# Check the grammar, class, and checksum of one key, and print its ingest origin.
check_key() {
  local label="$1"
  local key="$2"
  local origin
  if [[ "$key" != tal_sk_* ]]; then
    echo "${label} must be a secret tal_sk_ key. A publishable or monitor key cannot be used here." >&2
    return 1
  fi
  if ! talaria_collector_key_cell "$key" >/dev/null 2>"${tmp}/err"; then
    sed "s/TALARIA_API_KEY/${label}/g" "${tmp}/err" >&2
    return 1
  fi
  if ! origin="$(talaria_collector_ingest_url "$url" "$key" 2>"${tmp}/err")"; then
    cat "${tmp}/err" >&2
    return 1
  fi
  if [[ ! "$origin" =~ ^https?://[^[:space:]\'\"%]+$ ]]; then
    echo "TALARIA_URL must be an http(s) ingest origin." >&2
    return 1
  fi
  printf '%s\n' "${origin%/}"
}

# Call GET /v1/sdk-config with the key. Returns 0 for live, 2 for an outage, 1 for a rejection.
probe_key() {
  local label="$1"
  local key="$2"
  local origin="$3"
  local http="" curl_status=0 code
  http="$(
    printf 'header = "Authorization: Bearer %s"\n' "$key" | curl --silent \
      --config - \
      --output "${tmp}/body" \
      --write-out '%{http_code}' \
      --max-time "$TALARIA_CHECK_TIMEOUT" \
      --connect-timeout 5 \
      --request GET \
      "${origin}${TALARIA_SDK_CONFIG_PATH}"
  )" || curl_status=$?
  code=""
  if [[ -s "${tmp}/body" ]] && command -v jq >/dev/null 2>&1; then
    code="$(jq -r '(.error.code // .code // .error // empty) | strings' "${tmp}/body" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ "$curl_status" -ne 0 || -z "$http" || "$http" == "000" ]]; then
    echo "::warning title=Talaria unreachable::Could not reach ${origin} to check ${label} (curl exit ${curl_status}). Talaria steps run as best effort. The deploy continues."
    return 2
  fi
  case "$http" in
    2??)
      echo "${label} is accepted by ${origin}."
      return 0
      ;;
    401|403)
      echo "${label} was rejected by ${origin} with HTTP ${http}${code:+ (${code})}." >&2
      echo "The key is wrong, revoked, or belongs to another cell. Replace the secret, or remove every Talaria setting to deploy without Talaria." >&2
      return 1
      ;;
    402)
      echo "::warning title=Talaria quota::${origin} returned HTTP 402${code:+ (${code})} while checking ${label}. The quota is exceeded, so Talaria steps run as best effort. The deploy continues."
      return 2
      ;;
    408|429|5??)
      echo "::warning title=Talaria unavailable::${origin} returned HTTP ${http} while checking ${label}. Talaria steps run as best effort. The deploy continues."
      return 2
      ;;
    *)
      echo "${origin}${TALARIA_SDK_CONFIG_PATH} returned HTTP ${http}${code:+ (${code})} for ${label}. Check TALARIA_URL." >&2
      return 1
      ;;
  esac
}

labels=(TALARIA_API_KEY)
keys=("$api_key")
if [[ -n "$release_key" && "$release_key" != "$api_key" ]]; then
  labels+=(TALARIA_RELEASE_KEY)
  keys+=("$release_key")
fi

origins=()
for i in "${!keys[@]}"; do
  origin="$(check_key "${labels[$i]}" "${keys[$i]}")" || exit 1
  origins+=("$origin")
done

outage=0
for i in "${!keys[@]}"; do
  status=0
  probe_key "${labels[$i]}" "${keys[$i]}" "${origins[$i]}" || status=$?
  case "$status" in
    0) ;;
    2) outage=1 ;;
    *) exit 1 ;;
  esac
done

if [[ "$outage" -eq 1 ]]; then
  summary "### Talaria" "" "On, best effort. The key check did not confirm Talaria. A Talaria step that fails in this run is a warning, not a failed deploy."
  output enabled=true
  output reachable=false
else
  summary "### Talaria" "" "On. ${labels[*]} accepted by \`${origins[0]}\`."
  output enabled=true
  output reachable=true
fi
