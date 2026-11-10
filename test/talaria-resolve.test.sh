#!/usr/bin/env bash
# TALARIA_API_KEY comes from the workflow when set, otherwise from the SiteHost
# container environment. No key, or a failed lookup, warns and never fails.
# curl is a stub. No request leaves this machine.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
resolve="${root}/actions/ssh/talaria-resolve.sh"
check="${root}/actions/ssh/talaria-check.sh"
# shellcheck disable=SC1091
source "${root}/actions/ssh/collector.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "talaria-resolve: $1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" >&2
  fi
  exit 1
}

# The stub records argv, writes CURL_BODY, prints CURL_HTTP, and exits CURL_EXIT.
cat > "${tmp}/curl" <<'STUB'
#!/usr/bin/env bash
out=""
printf 'call\n' >> "$CURL_LOG"
while [[ $# -gt 0 ]]; do
  printf 'arg %s\n' "$1" >> "$CURL_LOG"
  case "$1" in
    --config)
      [[ "$2" == "-" ]] && cat >/dev/null
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

make_key() {
  local head="$1"
  local body
  body="${head}$(printf "${2:-b}%.0s" {1..43})"
  printf '%s%s' "$body" "$(talaria_collector_checksum "$body")"
}
workflow_key="$(make_key tal_sk_test_nz1_ a)"
container_key="$(make_key tal_sk_test_nz1_ c)"
db_password="s3cret-db-password-value"

env_body() {
  jq -cn --arg key "$1" --arg pw "$db_password" '{status: true, msg: "Successful", return: [
    {name: "SS_DATABASE_PASSWORD", content: $pw},
    {name: "TALARIA_API_KEY", content: $key},
    {name: "TALARIA_BROWSER_API_KEY", content: "tal_pk_browser_value"}
  ]}'
}

# Run the resolver with a clean environment plus the given assignments.
run_resolve() {
  : > "$CURL_LOG"
  : > "${tmp}/output"
  : > "${tmp}/summary"
  : > "${tmp}/env"
  set +e
  out="$(
    env -u TALARIA_API_KEY -u TALARIA_BROWSER_API_KEY -u TALARIA_URL -u SITEHOST_API_KEY -u SITEHOST_CLIENT_ID \
      -u SITEHOST_SERVER -u SITEHOST_STACK -u SITEHOST_CONTAINER \
      GITHUB_OUTPUT="${tmp}/output" GITHUB_STEP_SUMMARY="${tmp}/summary" GITHUB_ENV="${tmp}/env" \
      "$@" bash "$resolve" 2>&1
  )"
  status=$?
  set -e
}

# Read NAME from the GITHUB_ENV file the resolver wrote. Last write wins.
env_value() {
  awk -v name="$1" '
    $0 ~ "^" name "<<" { delim = substr($0, length(name) + 3); inside = 1; value = ""; next }
    inside && $0 == delim { inside = 0; found = value; next }
    inside { value = (value == "" ? $0 : value "\n" $0) }
    END { printf "%s", found }
  ' "${tmp}/env"
}

# The log may hold the key only inside an ::add-mask:: command.
assert_no_leak() {
  local secret
  for secret in "$@"; do
    if grep -v '^::add-mask::' <<<"$out" | grep -qF -- "$secret"; then
      fail "printed a secret" "$out"
    fi
    if grep -qF -- "$secret" "${tmp}/summary" "${tmp}/output"; then
      fail "wrote a secret to the summary or outputs" "$(cat "${tmp}/summary" "${tmp}/output")"
    fi
  done
}

sitehost=(SITEHOST_API_KEY=sitehost-api-key-value SITEHOST_CLIENT_ID=17 SITEHOST_SERVER=ch-servername SITEHOST_STACK=cce6c3ce72078711 SITEHOST_CONTAINER=test.example.com)

# 1. The workflow key wins and the API is not called.
run_resolve CURL_BODY="$(env_body "$container_key")" TALARIA_API_KEY="  ${workflow_key} " "${sitehost[@]}"
[[ "$status" -eq 0 ]] || fail "workflow key should pass" "$out"
[[ "$(env_value TALARIA_API_KEY)" == "$workflow_key" ]] || fail "workflow key was not written to GITHUB_ENV" "$(cat "${tmp}/env")"
[[ "$(env_value TALARIA_API_KEY_SOURCE)" == "workflow" ]] || fail "source should be workflow"
grep -qx 'source=workflow' "${tmp}/output" || fail "output should say source=workflow"
grep -qF "from the workflow (\`${workflow_key:0:8}…\`)" "${tmp}/summary" || fail "summary should name the workflow source" "$(cat "${tmp}/summary")"
grep -qxF "::add-mask::${workflow_key}" <<<"$out" || fail "workflow key was not masked" "$out"
[[ ! -s "$CURL_LOG" ]] || fail "workflow key should not call the SiteHost API"
assert_no_leak "$workflow_key" sitehost-api-key-value
browser_key="$(make_key tal_pk_test_nz1_ p)"
run_resolve TALARIA_API_KEY="$workflow_key" TALARIA_BROWSER_API_KEY=" ${browser_key} " "${sitehost[@]}"
[[ "$status" -eq 0 ]] || fail "workflow browser key should pass" "$out"
[[ "$(env_value TALARIA_BROWSER_API_KEY)" == "$browser_key" ]] || fail "workflow browser key was not written to GITHUB_ENV"
[[ "$(env_value TALARIA_BROWSER_API_KEY_SOURCE)" == "workflow" ]] || fail "browser source should be workflow"
grep -qx 'browser_source=workflow' "${tmp}/output" || fail "output should say browser_source=workflow"
grep -qxF "::add-mask::${browser_key}" <<<"$out" || fail "browser key was not masked" "$out"
assert_no_leak "$browser_key" "$workflow_key"

# 2. No workflow key: the container key is used.
run_resolve CURL_BODY="$(env_body "$container_key")" TALARIA_URL="" "${sitehost[@]}"
[[ "$status" -eq 0 ]] || fail "container key should pass" "$out"
[[ "$(env_value TALARIA_API_KEY)" == "$container_key" ]] || fail "container key was not written to GITHUB_ENV" "$(cat "${tmp}/env")"
[[ "$(env_value TALARIA_API_KEY_SOURCE)" == "container" ]] || fail "source should be container"
grep -qx 'source=container' "${tmp}/output" || fail "output should say source=container"
[[ -z "$(env_value TALARIA_BROWSER_API_KEY)" ]] || fail "a container browser key must not be copied"
[[ "$(env_value TALARIA_BROWSER_API_KEY_SOURCE)" == "none" ]] || fail "browser source should be none when the workflow did not send one"
grep -qx 'browser_source=none' "${tmp}/output" || fail "output should say browser_source=none"
grep -qF "from the SiteHost container (\`${container_key:0:8}…\`)" "${tmp}/summary" || fail "summary should name the container source" "$(cat "${tmp}/summary")"
grep -qxF "::add-mask::${container_key}" <<<"$out" || fail "container key was not masked" "$out"
grep -qxF "::add-mask::sitehost-api-key-value" <<<"$out" || fail "SiteHost API key was not masked" "$out"
grep -q 'arg https://api.sitehost.nz/1.5/cloud/stack/environment/get.json' "$CURL_LOG" || fail "did not call environment/get.json" "$(cat "$CURL_LOG")"
grep -qx 'arg project=cce6c3ce72078711' "$CURL_LOG" || fail "project must be the stack id" "$(cat "$CURL_LOG")"
grep -qx 'arg service=cce6c3ce72078711' "$CURL_LOG" || fail "service must be the stack id" "$(cat "$CURL_LOG")"
grep -qx 'arg --get' "$CURL_LOG" || fail "environment/get must be a GET"
assert_no_leak "$container_key" "$db_password" tal_pk_browser_value sitehost-api-key-value

# The resolved container key reaches talaria-check.sh, which accepts it.
: > "$CURL_LOG"
set +e
check_out="$(
  env -u TALARIA_RELEASE_KEY -u UPLOAD_SOURCE_MAPS \
    TALARIA_API_KEY="$(env_value TALARIA_API_KEY)" TALARIA_URL="$(env_value TALARIA_URL)" \
    GITHUB_OUTPUT="${tmp}/check-output" CURL_BODY='{}' CURL_HTTP=200 TALARIA_CHECK_TIMEOUT=2 \
    bash "$check" 2>&1
)"
check_status=$?
set -e
[[ "$check_status" -eq 0 ]] || fail "talaria-check should accept the container key" "$check_out"
grep -qx 'enabled=true' "${tmp}/check-output" || fail "talaria-check should turn Talaria on" "$check_out"

# A container key in the wrong format is still caught by talaria-check.sh.
run_resolve CURL_BODY="$(env_body "tal_live_oldformatkey")" "${sitehost[@]}"
[[ "$status" -eq 0 && "$(env_value TALARIA_API_KEY_SOURCE)" == "container" ]] || fail "an old container key should still be found" "$out"
set +e
check_out="$(env -u TALARIA_RELEASE_KEY -u TALARIA_URL TALARIA_API_KEY="$(env_value TALARIA_API_KEY)" bash "$check" 2>&1)"
check_status=$?
set -e
[[ "$check_status" -ne 0 ]] || fail "talaria-check should fail an invalid container key" "$check_out"

# A container TALARIA_URL is used with a container key. A workflow URL wins.
body="$(jq -cn --arg key "$container_key" '{status: true, msg: "ok", return: [{name: "TALARIA_API_KEY", content: $key}, {name: "TALARIA_URL", content: "https://ingest.self.example"}]}')"
run_resolve CURL_BODY="$body" "${sitehost[@]}"
[[ "$(env_value TALARIA_URL)" == "https://ingest.self.example" ]] || fail "container TALARIA_URL should follow the container key"
run_resolve CURL_BODY="$body" TALARIA_URL="https://ingest.workflow.example" "${sitehost[@]}"
[[ "$(env_value TALARIA_URL)" == "https://ingest.workflow.example" ]] || fail "workflow TALARIA_URL should win"

# 3. Neither: no key, a clear note, and talaria-check skips with a warning.
run_resolve CURL_BODY='{"status":true,"msg":"ok","return":[{"name":"OTHER","content":"x"}]}' "${sitehost[@]}"
[[ "$status" -eq 0 ]] || fail "no key anywhere should pass" "$out"
[[ -z "$(env_value TALARIA_API_KEY)" ]] || fail "no key should leave TALARIA_API_KEY empty"
[[ "$(env_value TALARIA_API_KEY_SOURCE)" == "none" ]] || fail "source should be none"
grep -q 'not set in the workflow or on the SiteHost container' "${tmp}/summary" || fail "summary should say no key was found"
set +e
check_out="$(env -u TALARIA_RELEASE_KEY -u TALARIA_URL TALARIA_API_KEY="" GITHUB_OUTPUT="${tmp}/check-output" bash "$check" 2>&1)"
check_status=$?
set -e
[[ "$check_status" -eq 0 && "$check_out" == *"::warning title=Talaria skipped::"* ]] || fail "talaria-check should warn and skip" "$check_out"

# No SiteHost API settings: the lookup is skipped, not failed.
run_resolve
[[ "$status" -eq 0 && "$(env_value TALARIA_API_KEY_SOURCE)" == "none" ]] || fail "missing API settings should mean no key" "$out"
[[ "$out" == *"Missing: SITEHOST_API_KEY"* ]] || fail "should name the missing API settings" "$out"
[[ ! -s "$CURL_LOG" ]] || fail "missing API settings should not call the API"

# 4. API errors warn and count as no key. They never fail the step.
for case in "CURL_HTTP=401" "CURL_EXIT=7" "CURL_HTTP=200|CURL_BODY={\"status\":false,\"msg\":\"Access denied\"}" "CURL_HTTP=200|CURL_BODY=notjson" "CURL_HTTP=200|CURL_BODY={\"status\":true,\"return\":{}}"; do
  IFS='|' read -r -a extra <<<"$case"
  run_resolve "${extra[@]}" "${sitehost[@]}"
  [[ "$status" -eq 0 ]] || fail "API error (${case}) must not fail the step" "$out"
  [[ "$out" == *"::warning title=Talaria key lookup failed::"* ]] || fail "API error (${case}) should warn" "$out"
  [[ "$(env_value TALARIA_API_KEY_SOURCE)" == "none" && -z "$(env_value TALARIA_API_KEY)" ]] || fail "API error (${case}) should mean no key"
  assert_no_leak sitehost-api-key-value
done

# A hostname as the stack is rejected before any request, as a warning.
run_resolve SITEHOST_API_KEY=sitehost-api-key-value SITEHOST_CLIENT_ID=17 SITEHOST_SERVER=ch-servername SITEHOST_STACK=test.example.com
[[ "$status" -eq 0 && "$out" == *"::warning title=Talaria key lookup failed::"* ]] || fail "a bad stack should warn" "$out"
[[ ! -s "$CURL_LOG" ]] || fail "a bad stack should not call the API"

echo "talaria resolve test passed"
