#!/usr/bin/env bash
# ssh-payload.sh writes one line, and the decoded body matches the script it encoded.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
payload_sh="${root}/actions/ssh/ssh-payload.sh"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

cat > "${tmp}/hello.sh" <<'EOF'
#!/usr/bin/env bash
echo hello-from-payload
EOF

SAMPLE_VALUE="quote's here"
export SAMPLE_VALUE
bash "$payload_sh" "${tmp}/hello.sh" "${tmp}/payload.sh" SAMPLE_VALUE

lines="$(wc -l < "${tmp}/payload.sh" | tr -d ' ')"
if [[ "$lines" != "1" ]]; then
  echo "expected one payload line, got ${lines}" >&2
  exit 1
fi

payload="$(cat "${tmp}/payload.sh")"
encoded="$(printf '%s\n' "$payload" | sed -n 's/.*echo \([^ ]*\) | base64 -d.*/\1/p')"
if [[ -z "$encoded" ]]; then
  echo "could not find the base64 body" >&2
  exit 1
fi
decoded="$(printf '%s' "$encoded" | base64 -d)"
expected="$(cat "${tmp}/hello.sh")"
if [[ "$decoded" != "$expected" ]]; then
  echo "round trip did not match the source script" >&2
  exit 1
fi
if [[ "$payload" != *"export SAMPLE_VALUE="* ]]; then
  echo "payload did not export SAMPLE_VALUE" >&2
  exit 1
fi
if [[ "$payload" != *"quote"* || "$payload" != *"here"* ]]; then
  echo "payload dropped the sample value" >&2
  exit 1
fi

# A script beside lib.sh is encoded with the library prepended.
bash "$payload_sh" "${root}/actions/ssh/remote-deploy.sh" "${tmp}/deploy-payload.sh"
deploy_payload="$(cat "${tmp}/deploy-payload.sh")"
deploy_encoded="$(printf '%s\n' "$deploy_payload" | sed -n 's/.*echo \([^ ]*\) | base64 -d.*/\1/p')"
deploy_decoded="$(printf '%s' "$deploy_encoded" | base64 -d)"
if [[ "$deploy_decoded" != *"SITEHOST_LIB_LOADED=1"* || "$deploy_decoded" != *"Remote deploy script started"* ]]; then
  echo "remote deploy payload did not include lib.sh and the script" >&2
  exit 1
fi
if [[ "$deploy_decoded" != *"composer install --optimize-autoloader --no-dev --no-progress --no-interaction --prefer-dist"* || "$deploy_decoded" != *"vendor/bin/sake dev/build flush=all"* ]]; then
  echo "remote deploy payload did not include the Silverstripe build" >&2
  exit 1
fi
lib_count="$(printf '%s\n' "$deploy_decoded" | grep -c 'SITEHOST_LIB_LOADED=1')"
if [[ "$lib_count" != "1" ]]; then
  echo "expected lib.sh once in the payload, found ${lib_count}" >&2
  exit 1
fi
if [[ "$deploy_decoded" != *"install_talaria_runtime"* || "$deploy_decoded" != *"install_talaria_collector"* ]]; then
  echo "remote deploy payload did not include the runtime health functions" >&2
  exit 1
fi
preset_b64="$(printf '%s\n' "$deploy_decoded" | sed -n "s/^TALARIA_COLLECTOR_PRESET_B64='\\(.*\\)'$/\\1/p")"
if [[ -z "$preset_b64" ]]; then
  echo "remote deploy payload did not embed the collector preset" >&2
  exit 1
fi
printf '%s' "$preset_b64" | base64 -d > "${tmp}/preset.yaml"
if ! cmp -s "${tmp}/preset.yaml" "${root}/collector/preset.yaml"; then
  echo "embedded collector preset does not match collector/preset.yaml" >&2
  exit 1
fi
if [[ "$deploy_decoded" != *"vendor/bin/talaria-sitehost"* || "$deploy_decoded" != *'"$installer" install'* ]]; then
  echo "remote deploy payload did not invoke talaria-sitehost install" >&2
  exit 1
fi
if [[ "$deploy_decoded" == *"python3"* ]]; then
  echo "remote deploy payload still shells out to python3" >&2
  exit 1
fi
runtime_count="$(printf '%s\n' "$deploy_decoded" | grep -c 'SITEHOST_RUNTIME_LOADED=1')"
if [[ "$runtime_count" != "1" ]]; then
  echo "expected runtime-health.sh once in the payload, found ${runtime_count}" >&2
  exit 1
fi

# The container runs the payload on stdin, where BASH_SOURCE is unset.
printf '%s' "$deploy_encoded" | base64 -d | /bin/bash >"${tmp}/deploy.out" 2>"${tmp}/deploy.err" || true
if grep -q 'BASH_SOURCE' "${tmp}/deploy.err"; then
  echo "piped deploy still evaluates BASH_SOURCE" >&2
  cat "${tmp}/deploy.err" >&2
  exit 1
fi
if ! grep -q 'SITEHOST_APP_PATH is required' "${tmp}/deploy.err"; then
  echo "piped deploy did not reach the argument check" >&2
  cat "${tmp}/deploy.err" >&2
  exit 1
fi

echo "payload test passed"
