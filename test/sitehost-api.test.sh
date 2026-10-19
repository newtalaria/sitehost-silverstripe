#!/usr/bin/env bash
# The SiteHost backup command targets one container and does not call curl until that input is valid.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
api="${root}/actions/ssh/sitehost-api.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cat > "${tmp}/curl" <<'EOF'
#!/usr/bin/env bash
output=""
while [[ $# -gt 0 ]]; do
  printf '%s\n' "$1" >> "$CURL_LOG"
  case "$1" in
    --output|--write-out|--request)
      printf '%s\n' "$2" >> "$CURL_LOG"
      if [[ "$1" == "--output" ]]; then
        output="$2"
      fi
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -z "$output" ]]; then
  echo "curl stub did not receive --output" >&2
  exit 1
fi
printf '%s' "$CURL_BODY" > "$output"
printf '%s' "${CURL_HTTP:-200}"
EOF
chmod +x "${tmp}/curl"

export PATH="${tmp}:${PATH}"
export CURL_LOG="${tmp}/curl.log"
export CURL_BODY='{"status":true,"msg":"Successful","return":{"job":{"type":"scheduler","id":42}}}'
export SITEHOST_API_KEY="test-api-key"
export SITEHOST_CLIENT_ID="17"
export SITEHOST_SERVER="ch-servername"
export BACKUP_LABEL="predeploy-1-1-0123456789abcdef0123456789abcdef01234567"
unset SITEHOST_STACK || true

: > "$CURL_LOG"
unset SITEHOST_CONTAINER || true
set +e
missing="$(bash "$api" backup 2>&1)"
missing_status=$?
set -e
if [[ "$missing_status" -eq 0 ]]; then
  echo "backup without SITEHOST_CONTAINER should fail" >&2
  printf '%s\n' "$missing" >&2
  exit 1
fi
if [[ "$missing" != *"SITEHOST_CONTAINER"* ]]; then
  echo "expected the missing container name in the error" >&2
  printf '%s\n' "$missing" >&2
  exit 1
fi
if [[ -s "$CURL_LOG" ]]; then
  echo "backup without a container called the API" >&2
  exit 1
fi

export SITEHOST_CONTAINER="example.nz"
: > "$CURL_LOG"
set +e
missing_stack="$(bash "$api" backup 2>&1)"
missing_stack_status=$?
set -e
if [[ "$missing_stack_status" -eq 0 || "$missing_stack" != *"SITEHOST_STACK"* || "$missing_stack" != *"mountinfo"* ]]; then
  echo "backup without SITEHOST_STACK should explain how to read the id" >&2
  printf '%s\n' "$missing_stack" >&2
  exit 1
fi
if [[ -s "$CURL_LOG" ]]; then
  echo "backup without a stack called the API" >&2
  exit 1
fi

export SITEHOST_STACK="example.nz"
: > "$CURL_LOG"
set +e
hostname_stack="$(bash "$api" backup 2>&1)"
hostname_stack_status=$?
set -e
if [[ "$hostname_stack_status" -eq 0 || "$hostname_stack" != *"SITEHOST_STACK"* ]]; then
  echo "a hostname must not be accepted as the stack id" >&2
  printf '%s\n' "$hostname_stack" >&2
  exit 1
fi
if [[ -s "$CURL_LOG" ]]; then
  echo "a hostname stack called the API" >&2
  exit 1
fi

export SITEHOST_STACK="cce6c3ce72078711"
export BACKUP_LABEL="bad label"
: > "$CURL_LOG"
set +e
bad_label="$(bash "$api" backup 2>&1)"
bad_label_status=$?
set -e
if [[ "$bad_label_status" -eq 0 || "$bad_label" != *"BACKUP_LABEL"* ]]; then
  echo "expected a rejected backup label" >&2
  printf '%s\n' "$bad_label" >&2
  exit 1
fi
if [[ -s "$CURL_LOG" ]]; then
  echo "an invalid label called the API" >&2
  exit 1
fi

export BACKUP_LABEL="predeploy-1-1-0123456789abcdef0123456789abcdef01234567"
: > "$CURL_LOG"
backup_out="$(bash "$api" backup 2>&1)"
if [[ "$backup_out" != *"container example.nz"* || "$backup_out" != *"stack cce6c3ce72078711"* || "$backup_out" != *"job_type=scheduler"* || "$backup_out" != *"job_id=42"* ]]; then
  echo "backup did not report the container, the stack, and the scheduler job" >&2
  printf '%s\n' "$backup_out" >&2
  exit 1
fi
if [[ "$backup_out" == *"test-api-key"* ]]; then
  echo "backup printed the API key" >&2
  exit 1
fi
if ! grep -qx 'containers\[0\]=example.nz' "$CURL_LOG"; then
  echo "backup did not send containers[0]" >&2
  exit 1
fi
if ! grep -qx 'name=cce6c3ce72078711' "$CURL_LOG"; then
  echo "backup did not send SITEHOST_STACK as the stack name" >&2
  exit 1
fi
if grep -qx 'name=example.nz' "$CURL_LOG"; then
  echo "backup sent the container hostname as the stack name" >&2
  exit 1
fi
if ! grep -q '/cloud/stack/backup.json' "$CURL_LOG"; then
  echo "backup did not call /cloud/stack/backup.json" >&2
  exit 1
fi

: > "$CURL_LOG"
set +e
bad_job="$(bash "$api" poll-job disk 93 2>&1)"
bad_job_status=$?
set -e
if [[ "$bad_job_status" -eq 0 || "$bad_job" != *"scheduler or daemon"* ]]; then
  echo "poll-job should reject a server snapshot job type" >&2
  printf '%s\n' "$bad_job" >&2
  exit 1
fi
if [[ -s "$CURL_LOG" ]]; then
  echo "an invalid job type called the API" >&2
  exit 1
fi

echo "sitehost api test passed"
