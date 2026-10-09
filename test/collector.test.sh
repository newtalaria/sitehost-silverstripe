#!/usr/bin/env bash
# Collector preset merge, supervisord reconcile, and validate-before-restart.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/actions/ssh/collector.sh"

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "$1" >&2
  exit 1
}

preset="${root}/collector/preset.yaml"
if ! grep -q 'on_error: send_quiet' "$preset"; then
  fail "preset dropped send_quiet"
fi
if grep -q 'on_error: send$' "$preset" || grep -q 'on_error: send ' "$preset"; then
  fail "preset still uses on_error: send"
fi
if ! grep -q 'X-API-Key: ${env:TALARIA_API_KEY}' "$preset"; then
  fail "preset does not read the API key from the environment"
fi
if grep -q 'tal_live_' "$preset"; then
  fail "preset contains an API key"
fi
for path in \
  '/container/logs/apache2/error.log' \
  '/container/logs/php-fpm/*.log' \
  '/container/logs/cron-*.log' \
  '/container/logs/sitehost/sitehost.log' \
  '/container/logs/rsyslog/*' \
  'file_storage' \
  'receivers: [file_log]' \
  'exporters: [otlp_http]'
do
  if ! grep -F -q "$path" "$preset"; then
    fail "preset is missing ${path}"
  fi
done
if grep -q 'metrics:' "$preset"; then
  fail "preset opens a metrics pipeline"
fi

endpoint="$(talaria_collector_endpoint "https://ingest.newtalaria.com/")"
if [[ "$endpoint" != "https://ingest.newtalaria.com/otlp" ]]; then
  fail "endpoint was ${endpoint}"
fi
endpoint="$(talaria_collector_endpoint "https://ingest.newtalaria.com/otlp")"
if [[ "$endpoint" != "https://ingest.newtalaria.com/otlp" ]]; then
  fail "endpoint replaced an existing /otlp suffix: ${endpoint}"
fi
if talaria_collector_endpoint "not a url" >/dev/null 2>"${tmp}/endpoint.err"; then
  fail "bare text was accepted as a DSN"
fi
if ! grep -q 'TALARIA_DSN' "${tmp}/endpoint.err"; then
  fail "DSN error did not name TALARIA_DSN"
fi
if talaria_collector_attribute "service.name" "has space" >/dev/null 2>"${tmp}/attr.err"; then
  fail "attribute with a space was accepted"
fi

app="${tmp}/app"
mkdir -p "${app}/.talaria" "${app}/talaria"
command_line="$(talaria_collector_command "$app" "https://ingest.newtalaria.com/otlp" "silverstripe" "web" "test")"
if [[ "$command_line" != *"--config=file:${app}/.talaria/collector-preset.yaml"* ]]; then
  fail "command omitted the preset"
fi
if [[ "$command_line" == *"talaria/collector.yaml"* ]]; then
  fail "command included a project file that does not exist"
fi
if [[ "$command_line" != *"--set=exporters.otlp_http.endpoint=https://ingest.newtalaria.com/otlp" ]]; then
  fail "command did not lock the endpoint last: ${command_line}"
fi
printf 'receivers: {}\n' > "${app}/talaria/collector.yaml"
command_line="$(talaria_collector_command "$app" "https://ingest.newtalaria.com/otlp" "silverstripe" "web" "test")"
if [[ "$command_line" != *"--config=file:${app}/talaria/collector.yaml --set="* ]]; then
  fail "project file was not merged before --set: ${command_line}"
fi
if [[ "$command_line" == *"tal_live_"* ]]; then
  fail "command line contains an API key"
fi

existing="[program:cron]
command=cron -f

${TALARIA_COLLECTOR_BEGIN}
command=old
${TALARIA_COLLECTOR_END}
"
once="$(talaria_collector_reconcile "$existing" "$command_line" "$app")"
twice="$(talaria_collector_reconcile "$once" "$command_line" "$app")"
if [[ "$once" != "$twice" ]]; then
  fail "reconcile was not idempotent"
fi
if [[ "$(printf '%s\n' "$twice" | grep -c '\[program:talaria-otelcol\]')" != "1" ]]; then
  fail "reconcile left more than one collector program"
fi
if [[ "$twice" != *"[program:cron]"* || "$twice" == *"command=old"* ]]; then
  fail "reconcile did not keep cron or still has the old command"
fi
if talaria_collector_reconcile "${TALARIA_COLLECTOR_BEGIN}
command=old
" "$command_line" "$app" >/dev/null 2>"${tmp}/broken.err"; then
  fail "a collector block without an end marker was accepted"
fi
if ! grep -q 'end-talaria-otelcol' "${tmp}/broken.err"; then
  fail "broken block error did not name the end marker"
fi

# A failed validate must not rewrite supervisord or restart the program.
mkdir -p "${tmp}/bin"
cat > "${tmp}/bin/otelcol-contrib" <<'EOF'
#!/bin/sh
if [ "$1" = "validate" ]; then
  exit 1
fi
exit 0
EOF
chmod 0755 "${tmp}/bin/otelcol-contrib"
cp "${tmp}/bin/otelcol-contrib" "${app}/.talaria/otelcol-contrib"
printf '%s\n' "$TALARIA_COLLECTOR_VERSION" > "${app}/.talaria/otelcol-contrib.version"
printf '%s\n' "$existing" > "${tmp}/supervisord.conf"
cat > "${tmp}/bin/supervisorctl" <<'EOF'
#!/bin/sh
echo "$@" >> "${SUPERVISOR_LOG:?}"
exit 0
EOF
chmod 0755 "${tmp}/bin/supervisorctl"
export SUPERVISOR_LOG="${tmp}/supervisor.log"
export PATH="${tmp}/bin:${PATH}"
export SITEHOST_APP_PATH="$app"
export SITEHOST_SUPERVISORD="${tmp}/supervisord.conf"
export TALARIA_DSN="https://ingest.newtalaria.com"
export TALARIA_API_KEY="tal_live_test"
export TALARIA_SERVICE_NAME="silverstripe"
export TALARIA_CONTAINER_NAME="web"
export TALARIA_ENVIRONMENT="test"
export TALARIA_COLLECTOR_PRESET_B64
TALARIA_COLLECTOR_PRESET_B64="$(base64 < "$preset" | tr -d '\n')"
# The version stamp points at app/.talaria, but ensure_binary uses that path.
# The fake binary is already there, so curl is not used.
if install_talaria_collector; then
  fail "install succeeded when validate failed"
fi
if [[ "$(cat "${tmp}/supervisord.conf")" != "$(printf '%s\n' "$existing")" ]]; then
  fail "failed validate rewrote supervisord"
fi
if [[ -f "$SUPERVISOR_LOG" ]]; then
  fail "failed validate restarted the collector"
fi
if ! grep -q 'file_storage' "${app}/.talaria/collector-preset.yaml"; then
  fail "preset was not written before validation"
fi

cat > "${app}/.talaria/otelcol-contrib" <<'EOF'
#!/bin/sh
if [ "$1" = "validate" ]; then
  printf '%s\n' "$@" > "${VALIDATE_LOG:?}"
  exit 0
fi
exit 0
EOF
chmod 0755 "${app}/.talaria/otelcol-contrib"
export VALIDATE_LOG="${tmp}/validate.log"
: > "$SUPERVISOR_LOG"
install_talaria_collector
if ! grep -q 'update' "$SUPERVISOR_LOG" || ! grep -q 'restart talaria-otelcol' "$SUPERVISOR_LOG"; then
  fail "successful validate did not reload the collector: $(cat "$SUPERVISOR_LOG")"
fi
if ! grep -q -- "--config=file:${app}/talaria/collector.yaml" "$VALIDATE_LOG"; then
  fail "validate did not include the project file"
fi
if ! grep -q -- "--set=exporters.otlp_http.endpoint=https://ingest.newtalaria.com/otlp" "$VALIDATE_LOG"; then
  fail "validate did not lock the endpoint"
fi
written="$(cat "${tmp}/supervisord.conf")"
if [[ "$written" != *"--config=file:${app}/.talaria/collector-preset.yaml"* ]]; then
  fail "supervisord command omitted the preset"
fi
if [[ "$written" == *"tal_live_"* ]]; then
  fail "supervisord config contains the API key"
fi

echo "collector test passed"
