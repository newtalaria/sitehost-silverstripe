#!/usr/bin/env bash
# SiteHost API v1.5 helper for container backup, release env updates, and job polling.
# Reads secrets from the environment and does not print the API key.
set -euo pipefail

API_BASE="${SITEHOST_API_BASE:-https://api.sitehost.nz/1.5}"

# Print how to run this script, then exit.
usage() {
  echo "Usage: sitehost-api.sh backup|set-release|poll-job TYPE ID [TIMEOUT_SECONDS]" >&2
  exit 1
}

# Stop if the named environment variable is missing or empty.
require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

# Stop if curl or jq is not available.
require_commands() {
  local missing=0
  local cmd
  for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Required command not found: ${cmd}" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

# Call the SiteHost API and print the JSON body only when status is true. Never print the API key.
sitehost_request() {
  local method="$1"
  local path="$2"
  shift 2
  local body_file http curl_status
  body_file="$(mktemp)"
  set +e
  http="$(
    curl --silent \
      --output "$body_file" \
      --write-out '%{http_code}' \
      --request "$method" \
      "$@" \
      "${API_BASE}${path}"
  )"
  curl_status=$?
  set -e
  if [[ "$curl_status" -ne 0 ]]; then
    echo "SiteHost API request failed for ${path}" >&2
    rm -f "$body_file"
    exit 1
  fi
  if [[ "$http" != "200" ]]; then
    echo "SiteHost API HTTP ${http} for ${path}" >&2
    jq -c '{status, msg}' "$body_file" >&2 || true
    rm -f "$body_file"
    exit 1
  fi
  local ok
  ok="$(jq -r 'if .status == true or .status == "true" then "true" else "false" end' "$body_file")"
  if [[ "$ok" != "true" ]]; then
    echo "SiteHost API status is not true for ${path}" >&2
    jq -c '{status, msg}' "$body_file" >&2 || true
    rm -f "$body_file"
    exit 1
  fi
  cat "$body_file"
  rm -f "$body_file"
}

# Check the job type and id, print them, and record them for the GitHub Actions step.
write_job_outputs() {
  local job_type="$1"
  local job_id="$2"
  if [[ -z "$job_type" || "$job_type" == "null" || -z "$job_id" || "$job_id" == "null" ]]; then
    echo "SiteHost response did not include a job type and id" >&2
    exit 1
  fi
  case "$job_type" in
    scheduler|daemon) ;;
    *)
      echo "Unexpected SiteHost job type: ${job_type}" >&2
      exit 1
      ;;
  esac
  if [[ ! "$job_id" =~ ^[0-9]+$ ]]; then
    echo "Unexpected SiteHost job id" >&2
    exit 1
  fi
  printf 'job_type=%s\n' "$job_type"
  printf 'job_id=%s\n' "$job_id"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'job_type=%s\n' "$job_type" >> "$GITHUB_OUTPUT"
    printf 'job_id=%s\n' "$job_id" >> "$GITHUB_OUTPUT"
  fi
}

# Read return.job.type and return.job.id from an API response.
job_from_body() {
  local body="$1"
  local job_type job_id
  job_type="$(jq -r '.return.job.type // empty' <<<"$body")"
  job_id="$(jq -r '.return.job.id // empty' <<<"$body")"
  write_job_outputs "$job_type" "$job_id"
}

# Ask SiteHost to back up this stack and return the scheduled job.
cmd_backup() {
  require_env SITEHOST_API_KEY
  require_env SITEHOST_CLIENT_ID
  require_env SITEHOST_SERVER
  require_env SITEHOST_STACK
  require_env BACKUP_LABEL

  local -a form=(
    --form "apikey=${SITEHOST_API_KEY}"
    --form "client_id=${SITEHOST_CLIENT_ID}"
    --form "server=${SITEHOST_SERVER}"
    --form "name=${SITEHOST_STACK}"
    --form "params[label]=${BACKUP_LABEL}"
  )
  if [[ -n "${SITEHOST_CONTAINER:-}" ]]; then
    form+=(--form "containers[0]=${SITEHOST_CONTAINER}")
  fi

  local body
  body="$(sitehost_request POST "/cloud/stack/backup.json" "${form[@]}")"
  job_from_body "$body"
}

# Update TALARIA_RELEASE and TALARIA_COMMIT_SHA. SiteHost restarts the container to apply them.
cmd_set_release() {
  require_env SITEHOST_API_KEY
  require_env SITEHOST_CLIENT_ID
  require_env SITEHOST_SERVER
  require_env SITEHOST_STACK
  require_env SITEHOST_SERVICE
  require_env TALARIA_RELEASE
  require_env TALARIA_COMMIT_SHA

  if [[ -z "$TALARIA_RELEASE" || "$TALARIA_RELEASE" == *$'\n'* ]]; then
    echo "TALARIA_RELEASE is empty or contains a newline" >&2
    exit 1
  fi
  if [[ ! "$TALARIA_COMMIT_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "TALARIA_COMMIT_SHA must be a 40 character git commit" >&2
    exit 1
  fi

  local body
  body="$(sitehost_request POST "/cloud/stack/environment/update.json" \
    --form "apikey=${SITEHOST_API_KEY}" \
    --form "client_id=${SITEHOST_CLIENT_ID}" \
    --form "server=${SITEHOST_SERVER}" \
    --form "project=${SITEHOST_STACK}" \
    --form "service=${SITEHOST_SERVICE}" \
    --form "variables[0][name]=TALARIA_RELEASE" \
    --form "variables[0][content]=${TALARIA_RELEASE}" \
    --form "variables[1][name]=TALARIA_COMMIT_SHA" \
    --form "variables[1][content]=${TALARIA_COMMIT_SHA}")"
  job_from_body "$body"
}

# Poll a SiteHost job until it completes, fails, or the timeout is reached.
cmd_poll_job() {
  require_env SITEHOST_API_KEY
  local job_type="${1:-}"
  local job_id="${2:-}"
  local timeout="${3:-${POLL_TIMEOUT_SECONDS:-2700}}"
  local interval="${POLL_INTERVAL_SECONDS:-15}"

  case "$job_type" in
    scheduler|daemon) ;;
    *)
      echo "poll-job requires a job type of scheduler or daemon" >&2
      exit 1
      ;;
  esac
  if [[ ! "$job_id" =~ ^[0-9]+$ ]]; then
    echo "poll-job requires a numeric job id" >&2
    exit 1
  fi
  if [[ ! "$timeout" =~ ^[0-9]+$ || "$timeout" -lt 1 ]]; then
    echo "poll-job timeout must be a positive number of seconds" >&2
    exit 1
  fi
  if [[ ! "$interval" =~ ^[0-9]+$ || "$interval" -lt 1 ]]; then
    echo "POLL_INTERVAL_SECONDS must be a positive number of seconds" >&2
    exit 1
  fi

  local start=$SECONDS
  while true; do
    local body state state_lc
    body="$(sitehost_request GET "/job/get.json" \
      --get \
      --data-urlencode "apikey=${SITEHOST_API_KEY}" \
      --data-urlencode "type=${job_type}" \
      --data-urlencode "id=${job_id}")"
    state="$(jq -r '.return.state // empty' <<<"$body")"
    state_lc="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    echo "Job ${job_type}/${job_id} state=${state:-unknown}"
    case "$state_lc" in
      completed)
        return 0
        ;;
      failed|error|cancelled|canceled)
        echo "SiteHost job ${job_type}/${job_id} ended with state ${state}" >&2
        jq -r '.return.logs[-1].message // empty' <<<"$body" >&2 || true
        return 1
        ;;
    esac
    if (( SECONDS - start >= timeout )); then
      echo "Timed out after ${timeout}s waiting for job ${job_type}/${job_id} (last state: ${state:-unknown})" >&2
      jq -r '.return.logs[-1].message // empty' <<<"$body" >&2 || true
      return 1
    fi
    sleep "$interval"
  done
}

# Run backup, set-release, or poll-job from the first argument.
main() {
  require_commands
  local command="${1:-}"
  if [[ $# -gt 0 ]]; then
    shift
  fi
  case "$command" in
    backup)
      [[ $# -eq 0 ]] || usage
      cmd_backup
      ;;
    set-release)
      [[ $# -eq 0 ]] || usage
      cmd_set_release
      ;;
    poll-job)
      [[ $# -eq 2 || $# -eq 3 ]] || usage
      cmd_poll_job "$@"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
