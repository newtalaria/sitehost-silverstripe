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

echo "payload test passed"
