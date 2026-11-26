#!/usr/bin/env bash
# The smoke check prints the HTTP status and a body excerpt, and fails on a non-2xx answer.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
smoke="${root}/actions/ssh/smoke-site.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "smoke-site: $1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" >&2
  fi
  exit 1
}

mkdir -p "${tmp}/bin"
cat > "${tmp}/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --max-time|--write-out) shift 2 ;;
    --silent|--show-error|--location) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$BODY" > "$out"
printf '%s %s\n' "$CODE" "$url"
STUB
chmod +x "${tmp}/bin/curl"
export PATH="${tmp}/bin:${PATH}"
export SITEHOST_SITE_URL="https://test.example/"
export SMOKE_ATTEMPTS=2
export SMOKE_DELAY_SECONDS=0

export CODE=200 BODY="<html>ok</html>"
ok="$(bash "$smoke")"
[[ "$ok" == *"HTTP 200 https://test.example/"* ]] || fail "a 200 should pass" "$ok"

export CODE=500 BODY="<html><title>Server Error</title>LogHandlerFactory</html>"
set +e
bad="$(bash "$smoke" 2>"${tmp}/err")"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "a 500 should fail the smoke check" "$bad"
[[ "$bad" == *"HTTP 500"* && "$bad" == *"Response excerpt:"* && "$bad" == *"LogHandlerFactory"* ]] || fail "a 500 should print the status and an excerpt" "$bad"
[[ "$bad" == *"attempt 1"* && "$bad" == *"attempt 2"* ]] || fail "a 500 should be requested again" "$bad"
[[ "$bad" != *"<html>"* ]] || fail "the excerpt should drop the markup" "$bad"

echo "smoke site test passed"
