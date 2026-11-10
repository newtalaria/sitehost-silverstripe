#!/usr/bin/env bash
# Find TALARIA_API_KEY for this deploy, before talaria-check.sh validates it.
#
#   1. The workflow value (a GitHub secret or variable) wins when it is set.
#   2. Otherwise the SiteHost container environment, the variables set in the
#      control panel, read with GET /cloud/stack/environment/get.json.
#   3. Otherwise no key. talaria-check.sh then warns and skips Talaria.
#
# TALARIA_URL follows the key. A workflow TALARIA_URL always wins. The
# container TALARIA_URL is used only when the key also came from the container.
# TALARIA_RELEASE_KEY is GitHub-only and is not read here.
#
# A failed API lookup is a warning and counts as no key. It never fails the
# step, so it cannot block the backup or the deploy.
#
# Writes TALARIA_API_KEY, TALARIA_URL, and TALARIA_API_KEY_SOURCE to
# GITHUB_ENV, and source=workflow|container|none to GITHUB_OUTPUT.
# TALARIA_BROWSER_API_KEY is recorded only when the workflow supplied it.
# The container value is left where it is. Every value is masked before
# anything else happens. A key is never printed. The summary shows at most
# the first 8 characters of TALARIA_API_KEY.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

trim() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

output() {
  printf '%s\n' "$1"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  fi
}

# Mask a value, line by line, so a later step cannot echo it.
mask() {
  local line
  [[ -z "$1" ]] && return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$line" ]]; then
      echo "::add-mask::${line}"
    fi
  done <<< "$1"
}

# Write one single-line value to GITHUB_ENV with a random delimiter.
write_env() {
  local name="$1"
  local value="$2"
  local delim="TALARIA_EOF_${RANDOM}${RANDOM}${RANDOM}"
  if [[ -z "${GITHUB_ENV:-}" ]]; then
    return 0
  fi
  {
    printf '%s<<%s\n' "$name" "$delim"
    printf '%s\n' "$value"
    printf '%s\n' "$delim"
  } >> "$GITHUB_ENV"
}

finish() {
  local source="$1"
  local key="$2"
  local url="$3"
  local label
  write_env TALARIA_API_KEY "$key"
  write_env TALARIA_URL "$url"
  write_env TALARIA_API_KEY_SOURCE "$source"
  output "source=${source}"
  case "$source" in
    workflow) label="workflow" ;;
    container) label="SiteHost container" ;;
    *) label="" ;;
  esac
  if [[ -n "$label" ]]; then
    echo "TALARIA_API_KEY source: ${label}."
    summary "### Talaria key source" "" "\`TALARIA_API_KEY\` from the ${label} (\`${key:0:8}…\`)."
  else
    echo "TALARIA_API_KEY is not set in the workflow or on the SiteHost container."
    summary "### Talaria key source" "" "None. \`TALARIA_API_KEY\` is not set in the workflow or on the SiteHost container."
  fi
  exit 0
}

# Record the workflow browser key before any exit. An empty value stays empty
# so a later step cannot mistake a container key for one the workflow sent.
record_browser_key() {
  local browser
  browser="$(trim "${TALARIA_BROWSER_API_KEY:-}")"
  mask "$browser"
  if [[ -n "$browser" ]]; then
    write_env TALARIA_BROWSER_API_KEY "$browser"
    write_env TALARIA_BROWSER_API_KEY_SOURCE workflow
    output "browser_source=workflow"
  else
    write_env TALARIA_BROWSER_API_KEY ""
    write_env TALARIA_BROWSER_API_KEY_SOURCE none
    output "browser_source=none"
  fi
}

workflow_key="$(trim "${TALARIA_API_KEY:-}")"
workflow_url="$(trim "${TALARIA_URL:-}")"
mask "$workflow_key"
record_browser_key

if [[ -n "$workflow_key" ]]; then
  finish workflow "$workflow_key" "$workflow_url"
fi

# No workflow key. Ask SiteHost for the container environment.
api_key="$(trim "${SITEHOST_API_KEY:-}")"
mask "$api_key"
missing=()
[[ -z "$api_key" ]] && missing+=(SITEHOST_API_KEY)
for name in SITEHOST_CLIENT_ID SITEHOST_SERVER SITEHOST_STACK; do
  [[ -z "$(trim "${!name:-}")" ]] && missing+=("$name")
done
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "Not reading the SiteHost container environment. Missing: ${missing[*]}."
  finish none "" "$workflow_url"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
status=0
SITEHOST_API_KEY="$api_key" \
  SITEHOST_CLIENT_ID="$(trim "${SITEHOST_CLIENT_ID}")" \
  SITEHOST_SERVER="$(trim "${SITEHOST_SERVER}")" \
  SITEHOST_STACK="$(trim "${SITEHOST_STACK}")" \
  SITEHOST_CONTAINER="$(trim "${SITEHOST_CONTAINER:-}")" \
  bash "${here}/sitehost-api.sh" get-env "${tmp}/env.json" >"${tmp}/log" 2>&1 || status=$?
if [[ "$status" -ne 0 || ! -s "${tmp}/env.json" ]]; then
  # The API helper never prints a value, only the status and message.
  sed 's/^/  /' "${tmp}/log" >&2 || true
  echo "::warning title=Talaria key lookup failed::Could not read the SiteHost container environment, so TALARIA_API_KEY from the container is treated as not set. The backup and deploy continue."
  finish none "" "$workflow_url"
fi

container_key="$(jq -r '[.[] | select(.name == "TALARIA_API_KEY") | .content][-1] // ""' "${tmp}/env.json")"
container_key="$(trim "$container_key")"
mask "$container_key"
container_url="$(jq -r '[.[] | select(.name == "TALARIA_URL") | .content][-1] // ""' "${tmp}/env.json")"
container_url="$(trim "$container_url")"
rm -f "${tmp}/env.json"

if [[ "$container_key" == *$'\n'* || "$container_url" == *$'\n'* ]]; then
  echo "::warning title=Talaria key lookup failed::The container TALARIA_API_KEY or TALARIA_URL spans more than one line, so it is not used. The backup and deploy continue."
  finish none "" "$workflow_url"
fi

if [[ -z "$container_key" ]]; then
  finish none "" "$workflow_url"
fi
finish container "$container_key" "${workflow_url:-$container_url}"
