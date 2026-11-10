#!/usr/bin/env bash
# shellcheck disable=SC2015
# Talaria is optional. No key skips it with a warning. A wrong key fails early.
# A partial setup names what is missing. An outage warns and continues.
# curl is a stub. No request leaves this machine.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check="${root}/actions/ssh/talaria-check.sh"
# shellcheck disable=SC1091
source "${root}/actions/ssh/collector.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "talaria-check: $1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" >&2
  fi
  exit 1
}

# The stub records argv and the --config text on stdin, writes CURL_BODY,
# prints CURL_HTTP, and exits CURL_EXIT.
cat > "${tmp}/curl" <<'STUB'
#!/usr/bin/env bash
out=""
printf 'call\n' >> "$CURL_LOG"
while [[ $# -gt 0 ]]; do
  printf 'arg %s\n' "$1" >> "$CURL_LOG"
  case "$1" in
    --config)
      if [[ "$2" == "-" ]]; then
        sed 's/^/config /' >> "$CURL_LOG"
      fi
      shift 2
      ;;
    --output) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "${CURL_EXIT:-0}" -ne 0 ]]; then
  exit "$CURL_EXIT"
fi
printf '%s' "${CURL_BODY:-{\}}" > "$out"
printf '%s' "${CURL_HTTP:-200}"
STUB
chmod +x "${tmp}/curl"
export PATH="${tmp}:${PATH}"
export CURL_LOG="${tmp}/curl.log"
export TALARIA_CHECK_TIMEOUT=2

make_key() {
  local head="$1"
  local body
  body="${head}$(printf "${2:-b}%.0s" {1..43})"
  printf '%s%s' "$body" "$(talaria_collector_checksum "$body")"
}
api_key="$(make_key tal_sk_test_nz1_ a)"
release_key="$(make_key tal_sk_test_nz1_ b)"
pk_key="$(make_key tal_pk_test_nz1_ c)"
bad_sum="${api_key:0:$((${#api_key} - 6))}AAAAAA"

# Run the check with a clean Talaria environment plus the given assignments.
run_check() {
  : > "$CURL_LOG"
  : > "${tmp}/output"
  : > "${tmp}/summary"
  set +e
  out="$(
    env -u TALARIA_API_KEY -u TALARIA_BROWSER_API_KEY -u TALARIA_RELEASE_KEY -u TALARIA_URL -u UPLOAD_SOURCE_MAPS \
      GITHUB_OUTPUT="${tmp}/output" GITHUB_STEP_SUMMARY="${tmp}/summary" \
      DEPLOY_ENVIRONMENT=test "$@" bash "$check" 2>&1
  )"
  status=$?
  set -e
}

no_secret_leak() {
  local text="$1"
  local key
  for key in "$api_key" "$release_key"; do
    if [[ "$(printf '%s\n' "$text" | grep -v '^::add-mask::')" == *"$key"* ]]; then
      fail "printed a key" "$text"
    fi
  done
}

# 1. No keys: warning, summary, enabled=false, no request.
run_check
[[ "$status" -eq 0 ]] || fail "no keys should pass" "$out"
[[ "$out" == *"::warning title=Talaria skipped::Talaria keys are not set"* ]] || fail "no keys should warn" "$out"
grep -qx 'enabled=false' "${tmp}/output" || fail "no keys should write enabled=false"
grep -q 'Skipped' "${tmp}/summary" || fail "no keys should write a summary line"
[[ ! -s "$CURL_LOG" ]] || fail "no keys should not call Talaria"

# 1a. A browser key alone stays off, and a secret key is rejected before any request.
run_check TALARIA_BROWSER_API_KEY="$pk_key"
[[ "$status" -eq 0 ]] || fail "a publishable browser key alone should pass" "$out"
[[ "$out" == *"written to the SiteHost container"* ]] || fail "a browser key alone should say it will be written" "$out"
grep -qx 'enabled=false' "${tmp}/output" || fail "a browser key alone should leave Talaria off"
[[ ! -s "$CURL_LOG" ]] || fail "a browser key alone should not call Talaria"
grep -qxF "::add-mask::${pk_key}" <<<"$out" || fail "the browser key should be masked"
no_secret_leak "$out"
if [[ "$(printf '%s\n' "$out" | grep -v '^::add-mask::')" == *"$pk_key"* ]]; then
  fail "printed the browser key" "$out"
fi
run_check TALARIA_BROWSER_API_KEY="$api_key"
[[ "$status" -ne 0 && "$out" == *"TALARIA_BROWSER_API_KEY must be a publishable tal_pk_ key"* ]] || fail "a secret key must not be accepted as the browser key" "$out"
[[ ! -s "$CURL_LOG" ]] || fail "a secret browser key called Talaria"
bad_browser="${pk_key:0:$((${#pk_key} - 6))}AAAAAA"
run_check TALARIA_BROWSER_API_KEY="$bad_browser"
[[ "$status" -ne 0 && "$out" == *"TALARIA_BROWSER_API_KEY checksum is invalid"* ]] || fail "a bad browser checksum should name the browser key" "$out"

# 1b. Whitespace-only values count as unset.
run_check TALARIA_API_KEY="  " TALARIA_URL=" "
[[ "$status" -eq 0 ]] && grep -qx 'enabled=false' "${tmp}/output" || fail "blank keys should be treated as unset" "$out"

# 1c. upload_source_maps with no keys is still a skip, not a failure.
run_check UPLOAD_SOURCE_MAPS=true
[[ "$status" -eq 0 ]] && grep -qx 'enabled=false' "${tmp}/output" || fail "source maps with no keys should skip" "$out"

# 2. Partial setups fail and name the missing settings, before any request.
run_check TALARIA_RELEASE_KEY="$release_key"
[[ "$status" -ne 0 && "$out" == *"Missing: TALARIA_API_KEY"* ]] || fail "release key alone should name TALARIA_API_KEY" "$out"
[[ ! -s "$CURL_LOG" ]] || fail "a partial setup called Talaria"
run_check TALARIA_URL="https://talaria.example"
[[ "$status" -ne 0 && "$out" == *"Missing: TALARIA_API_KEY"* ]] || fail "TALARIA_URL alone should name TALARIA_API_KEY" "$out"
run_check TALARIA_API_KEY="$api_key" UPLOAD_SOURCE_MAPS=true
[[ "$status" -ne 0 && "$out" == *"Missing: TALARIA_RELEASE_KEY"* ]] || fail "source maps without a release key should name it" "$out"
no_secret_leak "$out"

# 3. Malformed keys fail before any request.
for bad in "tal_live_nope" "$bad_sum" "$pk_key" "tal_mon_nz1_$(printf 'a%.0s' {1..49})"; do
  run_check TALARIA_API_KEY="$bad"
  [[ "$status" -ne 0 ]] || fail "accepted a malformed key" "$out"
  [[ ! -s "$CURL_LOG" ]] || fail "a malformed key called Talaria"
done
run_check TALARIA_API_KEY="$bad_sum"
[[ "$out" == *"checksum is invalid"* ]] || fail "a bad checksum should say so" "$out"
run_check TALARIA_API_KEY="$api_key" TALARIA_RELEASE_KEY="$bad_sum"
[[ "$status" -ne 0 && "$out" == *"TALARIA_RELEASE_KEY checksum is invalid"* ]] || fail "a bad release key should name it" "$out"

# 4. A self cell needs TALARIA_URL.
self_key="$(make_key tal_sk_dev_self_ a)"
run_check TALARIA_API_KEY="$self_key"
[[ "$status" -ne 0 && "$out" == *"Set TALARIA_URL"* ]] || fail "a self key without TALARIA_URL should fail" "$out"

# 5. Valid keys: one GET /v1/sdk-config per key, Bearer on stdin, not argv.
run_check TALARIA_API_KEY="$api_key" TALARIA_BROWSER_API_KEY="$pk_key" TALARIA_RELEASE_KEY="$release_key" UPLOAD_SOURCE_MAPS=true CURL_HTTP=200
[[ "$status" -eq 0 ]] || fail "valid keys should pass" "$out"
grep -qx 'enabled=true' "${tmp}/output" || fail "valid keys should write enabled=true"
grep -qx 'reachable=true' "${tmp}/output" || fail "valid keys should write reachable=true"
[[ "$(grep -c '^call$' "$CURL_LOG")" == "2" ]] || fail "expected one probe per key" "$(cat "$CURL_LOG")"
grep -q '^arg https://ingest-nz1.newtalaria.com/v1/sdk-config$' "$CURL_LOG" || fail "probe should hit the cell's /v1/sdk-config" "$(cat "$CURL_LOG")"
grep -q "^config header = \"Authorization: Bearer ${api_key}\"$" "$CURL_LOG" || fail "probe should send the API key as Bearer"
grep -q "^config header = \"Authorization: Bearer ${release_key}\"$" "$CURL_LOG" || fail "probe should send the release key as Bearer"
if grep '^arg ' "$CURL_LOG" | grep -q 'tal_sk_'; then
  fail "a key was passed on the curl command line"
fi
[[ "$out" == *"::add-mask::${api_key}"* && "$out" == *"::add-mask::${release_key}"* ]] || fail "keys should be masked"
no_secret_leak "$out"
grep -q '^On\. ' "${tmp}/summary" || fail "valid keys should write a summary line"

# 5b. TALARIA_URL overrides the cell host.
run_check TALARIA_API_KEY="$api_key" TALARIA_URL="https://talaria.example/" CURL_HTTP=200
[[ "$status" -eq 0 ]] && grep -q '^arg https://talaria.example/v1/sdk-config$' "$CURL_LOG" || fail "TALARIA_URL should be the probe origin" "$out"

# 6. Rejected keys fail.
for code in 401 403; do
  run_check TALARIA_API_KEY="$api_key" CURL_HTTP="$code" CURL_BODY='{"error":{"code":"invalid_key"}}'
  [[ "$status" -ne 0 ]] || fail "HTTP ${code} should fail" "$out"
  [[ "$out" == *"rejected"*"HTTP ${code} (invalid_key)"* ]] || fail "HTTP ${code} should say the key was rejected" "$out"
  no_secret_leak "$out"
done
run_check TALARIA_API_KEY="$api_key" CURL_HTTP=404
[[ "$status" -ne 0 && "$out" == *"Check TALARIA_URL"* ]] || fail "HTTP 404 should point at TALARIA_URL" "$out"
run_check TALARIA_API_KEY="$api_key" CURL_HTTP=402 CURL_BODY='{"error":{"code":"quota_exceeded"}}'
[[ "$status" -eq 0 ]] || fail "HTTP 402 should not fail the deploy" "$out"
[[ "$out" == *"::warning title=Talaria quota::"*"quota_exceeded"* ]] || fail "HTTP 402 should warn that the quota is exceeded" "$out"
[[ "$out" != *"Check TALARIA_URL"* ]] || fail "HTTP 402 should not blame TALARIA_URL" "$out"
grep -qx 'enabled=true' "${tmp}/output" && grep -qx 'reachable=false' "${tmp}/output" || fail "HTTP 402 should write enabled=true reachable=false"
grep -q 'best effort' "${tmp}/summary" || fail "HTTP 402 should say best effort in the summary"

# 7. Outages warn and continue with reachable=false.
for code in 500 502 503 429; do
  run_check TALARIA_API_KEY="$api_key" CURL_HTTP="$code"
  [[ "$status" -eq 0 ]] || fail "HTTP ${code} should not fail the deploy" "$out"
  [[ "$out" == *"::warning title=Talaria unavailable::"*"HTTP ${code}"* ]] || fail "HTTP ${code} should warn" "$out"
  grep -qx 'enabled=true' "${tmp}/output" && grep -qx 'reachable=false' "${tmp}/output" || fail "HTTP ${code} should write enabled=true reachable=false"
done
run_check TALARIA_API_KEY="$api_key" CURL_EXIT=28
[[ "$status" -eq 0 && "$out" == *"::warning title=Talaria unreachable::"* ]] || fail "a timeout should warn and continue" "$out"
grep -qx 'reachable=false' "${tmp}/output" || fail "a timeout should write reachable=false"
grep -q 'best effort' "${tmp}/summary" || fail "an outage should say best effort in the summary"

echo "talaria check test passed"
