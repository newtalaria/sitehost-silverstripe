#!/usr/bin/env bash
# Places otelcol-contrib on a SiteHost container and starts one supervisord program.
# The preset is Collector YAML. talaria/collector.yaml, when present, is a second
# --config. The collector merges them. ssh-payload.sh prepends this file and sets
# TALARIA_COLLECTOR_PRESET_B64. A file run directly is sourced by runtime-health.sh.

export SITEHOST_COLLECTOR_LOADED=1

TALARIA_COLLECTOR_VERSION=0.162.0
TALARIA_COLLECTOR_SHA256=fcc063749f730f8c21fe29f2d340ff174f5f1c5885bd3156fb6c985a3036fcc3
TALARIA_COLLECTOR_BEGIN="# talaria-otelcol"
TALARIA_COLLECTOR_END="# end-talaria-otelcol"

# Trim surrounding whitespace.
talaria_collector_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# API origin plus /otlp. A value that already ends in /otlp is kept.
talaria_collector_endpoint() {
  local dsn="$1"
  dsn="$(talaria_collector_trim "$dsn")"
  dsn="${dsn%/}"
  if [[ "$dsn" != */otlp ]]; then
    dsn="${dsn}/otlp"
  fi
  if [[ ! "$dsn" =~ ^https?://[^[:space:]\'\"%]+/otlp$ ]]; then
    echo "Set TALARIA_DSN to the API origin" >&2
    return 1
  fi
  printf '%s\n' "$dsn"
}

# Resource attributes are written onto the supervisord command. Reject anything
# that would split that command or expand inside Collector YAML.
talaria_collector_attribute() {
  local label="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9_.:@+-]{1,128}$ ]]; then
    echo "${label} cannot be passed to the collector" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

# Supervisord command. The endpoint --set is last, so a project file cannot retarget it.
talaria_collector_command() {
  local app="$1"
  local endpoint="$2"
  local service="$3"
  local container="$4"
  local environment="$5"
  local binary="${app}/.talaria/otelcol-contrib"
  local args="--config=file:${app}/.talaria/collector-preset.yaml"
  if [[ -f "${app}/talaria/collector.yaml" ]]; then
    args+=" --config=file:${app}/talaria/collector.yaml"
  fi
  printf '/usr/bin/env SITEHOST_APP_PATH=%s TALARIA_SERVICE_NAME=%s TALARIA_CONTAINER_NAME=%s TALARIA_ENVIRONMENT=%s %s %s --set=exporters.otlp_http.endpoint=%s\n' \
    "$app" "$service" "$container" "$environment" "$binary" "$args" "$endpoint"
}

# Replace every collector block with one program. A missing end marker fails.
talaria_collector_reconcile() {
  local existing="$1"
  local command_line="$2"
  local app="$3"
  local -a kept=()
  local line trimmed in_block=0 depth=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="$(talaria_collector_trim "$line")"
    if [[ "$in_block" -eq 0 ]]; then
      if [[ "$trimmed" == "$TALARIA_COLLECTOR_BEGIN" ]]; then
        in_block=1
        depth=0
        continue
      fi
      kept+=("$line")
      continue
    fi
    depth=$((depth + 1))
    if [[ "$trimmed" == "$TALARIA_COLLECTOR_END" ]]; then
      in_block=0
      continue
    fi
    if [[ "$depth" -gt 40 ]]; then
      echo "supervisord collector block is missing # end-talaria-otelcol" >&2
      return 1
    fi
  done <<<"$existing"
  if [[ "$in_block" -eq 1 ]]; then
    echo "supervisord collector block is missing # end-talaria-otelcol" >&2
    return 1
  fi
  while [[ ${#kept[@]} -gt 0 ]]; do
    trimmed="$(talaria_collector_trim "${kept[$((${#kept[@]} - 1))]}")"
    if [[ -n "$trimmed" ]]; then
      break
    fi
    unset "kept[$((${#kept[@]} - 1))]"
  done
  local block
  block="$(printf '%s\n' \
    "$TALARIA_COLLECTOR_BEGIN" \
    "[program:talaria-otelcol]" \
    "command=${command_line}" \
    "directory=${app}" \
    "autostart=true" \
    "autorestart=true" \
    "stdout_logfile=/container/logs/talaria-otelcol.log" \
    "stderr_logfile=/container/logs/talaria-otelcol.err" \
    "$TALARIA_COLLECTOR_END")"
  if [[ ${#kept[@]} -eq 0 ]]; then
    printf '%s\n' "$block"
  else
    printf '%s\n' "${kept[@]}"
    printf '\n%s\n' "$block"
  fi
}

# Download the pinned linux amd64 binary when the version stamp does not match.
talaria_collector_ensure_binary() {
  local app="$1"
  local dir="${app}/.talaria"
  local binary="${dir}/otelcol-contrib"
  local stamp="${dir}/otelcol-contrib.version"
  mkdir -p "$dir"
  if [[ -x "$binary" && -f "$stamp" ]]; then
    local installed
    installed="$(talaria_collector_trim "$(cat "$stamp")")"
    if [[ "$installed" == "$TALARIA_COLLECTOR_VERSION" ]]; then
      return 0
    fi
  fi
  if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
    echo "otelcol-contrib ${TALARIA_COLLECTOR_VERSION} is published for linux amd64" >&2
    return 1
  fi
  local tar="${dir}/otelcol-contrib.tar.gz"
  local url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${TALARIA_COLLECTOR_VERSION}/otelcol-contrib_${TALARIA_COLLECTOR_VERSION}_linux_amd64.tar.gz"
  if ! curl -fsSL --retry 2 --max-time 180 -o "$tar" "$url"; then
    rm -f "$tar"
    echo "Could not download otelcol-contrib ${TALARIA_COLLECTOR_VERSION}" >&2
    return 1
  fi
  local hash
  hash="$(sha256sum "$tar" | awk '{print $1}')"
  if [[ "$hash" != "$TALARIA_COLLECTOR_SHA256" ]]; then
    rm -f "$tar"
    echo "otelcol-contrib checksum did not match" >&2
    return 1
  fi
  if ! tar -xzf "$tar" -C "$dir" otelcol-contrib; then
    rm -f "$tar"
    echo "Could not unpack otelcol-contrib" >&2
    return 1
  fi
  rm -f "$tar"
  chmod 0755 "$binary"
  printf '%s\n' "$TALARIA_COLLECTOR_VERSION" > "$stamp"
}

# Copy the payload preset. The running collector still uses its previous command.
talaria_collector_write_preset() {
  local dest="$1"
  local tmp="${dest}.talaria.tmp"
  if [[ -z "${TALARIA_COLLECTOR_PRESET_B64:-}" ]]; then
    echo "Collector preset is missing from the deploy payload" >&2
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  if ! printf '%s' "$TALARIA_COLLECTOR_PRESET_B64" | base64 -d > "$tmp"; then
    rm -f "$tmp"
    echo "Collector preset could not be decoded" >&2
    return 1
  fi
  mv "$tmp" "$dest"
}

# Validate, then replace the supervisord program. A failed validate does not restart.
install_talaria_collector() {
  local app supervisor endpoint service container_name environment command_line rendered tmp
  app="$(talaria_collector_trim "${SITEHOST_APP_PATH:-}")"
  app="${app%/}"
  if [[ ! "$app" =~ ^/ ]] || [[ "$app" == *".."* ]] || [[ "$app" == "/" ]]; then
    echo "SITEHOST_APP_PATH must be an absolute path" >&2
    return 1
  fi
  if [[ -z "${TALARIA_API_KEY:-}" ]]; then
    echo "Set TALARIA_API_KEY before installing the collector" >&2
    return 1
  fi
  endpoint="$(talaria_collector_endpoint "${TALARIA_DSN:-${TALARIA_BASE_URL:-}}")" || return 1
  service="$(talaria_collector_attribute "service.name" "${TALARIA_SERVICE_NAME:-silverstripe}")" || return 1
  container_name="$(talaria_collector_attribute "container.name" "${TALARIA_CONTAINER_NAME:-$(hostname)}")" || return 1
  environment="$(talaria_collector_attribute "deployment.environment.name" "${TALARIA_ENVIRONMENT:-production}")" || return 1
  supervisor="${SITEHOST_SUPERVISORD:-/container/config/supervisord.conf}"
  if [[ ! -f "$supervisor" ]]; then
    echo "supervisord config is missing at ${supervisor}" >&2
    return 1
  fi
  talaria_collector_ensure_binary "$app" || return 1
  talaria_collector_write_preset "${app}/.talaria/collector-preset.yaml" || return 1
  command_line="$(talaria_collector_command "$app" "$endpoint" "$service" "$container_name" "$environment")"
  local -a validate_args=(--config="file:${app}/.talaria/collector-preset.yaml")
  if [[ -f "${app}/talaria/collector.yaml" ]]; then
    validate_args+=(--config="file:${app}/talaria/collector.yaml")
  fi
  validate_args+=(--set="exporters.otlp_http.endpoint=${endpoint}")
  if ! env \
    SITEHOST_APP_PATH="$app" \
    TALARIA_SERVICE_NAME="$service" \
    TALARIA_CONTAINER_NAME="$container_name" \
    TALARIA_ENVIRONMENT="$environment" \
    TALARIA_API_KEY="$TALARIA_API_KEY" \
    "${app}/.talaria/otelcol-contrib" validate \
    "${validate_args[@]}"
  then
    echo "Collector config failed validation. The running process was left in place." >&2
    return 1
  fi
  rendered="$(talaria_collector_reconcile "$(cat "$supervisor")" "$command_line" "$app")" || return 1
  tmp="$(mktemp)"
  printf '%s\n' "$rendered" > "$tmp"
  mv "$tmp" "$supervisor"
  if ! supervisorctl update; then
    echo "supervisorctl update failed" >&2
    return 1
  fi
  if ! supervisorctl restart talaria-otelcol; then
    echo "supervisorctl restart talaria-otelcol failed" >&2
    return 1
  fi
  rm -f /container/config/talaria-otelcol.yaml
  echo "Collector ${TALARIA_COLLECTOR_VERSION} is configured for ${endpoint}"
}
