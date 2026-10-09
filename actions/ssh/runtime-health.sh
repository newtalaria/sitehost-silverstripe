#!/usr/bin/env bash
# Re-apply the SiteHost probe and crontab check-ins after an image replacement.
# ssh-payload.sh prepends this file onto the encoded deploy script, because that
# script is piped into bash and has no path of its own. A file run directly
# sources this file when SITEHOST_RUNTIME_LOADED is unset.
# Opt-in when the app has talaria/sitehost/monitors.json or TALARIA_INSTALL_PROBE is true.

export SITEHOST_RUNTIME_LOADED=1

talaria_runtime_wanted() {
  if [[ "${TALARIA_INSTALL_PROBE:-}" == "true" ]]; then
    return 0
  fi
  [[ -f "${SITEHOST_APP_PATH}/talaria/sitehost/monitors.json" ]]
}

talaria_probe_block() {
  local app="$1"
  cat <<EOF
# talaria-sitehost-probe
[program:talaria-sitehost-probe]
command=${app}/vendor/bin/talaria-sitehost-probe
directory=${app}
autostart=true
autorestart=true
stdout_logfile=/container/logs/talaria-sitehost-probe.log
stderr_logfile=/container/logs/talaria-sitehost-probe.err
# end-talaria-sitehost-probe
EOF
}

# Print one crontab line that check-ins around a command.
# talaria_crontab_line SLUG CRONTAB TOKEN URL COMMAND
talaria_crontab_line() {
  local slug="$1"
  local schedule="$2"
  local token="$3"
  local url="$4"
  local command="$5"
  printf '%s # talaria-monitor:%s\n' \
    "${schedule} curl -fsS -m 15 -X POST -H 'X-Monitor-Token: ${token}' -H 'Content-Type: application/json' -d '{\"status\":\"in_progress\"}' '${url}/monitors/ping'; ${command}; talaria_status=\$?; if [ \"\$talaria_status\" -eq 0 ]; then curl -fsS -m 15 -X POST -H 'X-Monitor-Token: ${token}' -H 'Content-Type: application/json' -d '{\"status\":\"ok\"}' '${url}/monitors/ping'; else curl -fsS -m 15 -X POST -H 'X-Monitor-Token: ${token}' -H 'Content-Type: application/json' -d '{\"status\":\"error\"}' '${url}/monitors/ping'; fi; exit \"\$talaria_status\"" \
    "$slug"
}

install_talaria_runtime() {
  if ! talaria_runtime_wanted; then
    return 0
  fi
  local conf="/container/config/supervisord.conf"
  local probe
  probe="$(talaria_probe_block "$SITEHOST_APP_PATH")"
  if [[ -f "$conf" ]] && ! grep -q 'talaria-sitehost-probe' "$conf"; then
    printf '\n%s\n' "$probe" >> "$conf"
    echo "Added the Talaria SiteHost probe to ${conf}"
  fi
  if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl reread >/dev/null 2>&1 || true
    supervisorctl update talaria-sitehost-probe >/dev/null 2>&1 || true
  fi
  install_talaria_crontab
}

install_talaria_crontab() {
  local spec="${SITEHOST_APP_PATH}/talaria/sitehost/monitors.json"
  local cron_file="/container/crontabs/crontab"
  local url="${TALARIA_DSN:-}"
  local key="${TALARIA_API_KEY:-}"
  local token_file="${SITEHOST_APP_PATH}/.talaria-monitor-tokens"
  [[ -f "$spec" ]] || return 0
  [[ -n "$url" && -n "$key" ]] || {
    echo "talaria/sitehost/monitors.json is present. Set TALARIA_DSN and TALARIA_API_KEY to register check-ins."
    return 0
  }
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to read monitors.json" >&2
    return 0
  fi
  mkdir -p "$(dirname "$cron_file")"
  touch "$cron_file" "$token_file"
  chmod 600 "$token_file"
  python3 - "$spec" <<'PY' | while IFS=$'\t' read -r slug schedule timezone max margin command; do
import json, sys
doc = json.load(open(sys.argv[1]))
for job in doc.get("jobs", []):
    print("\t".join([
        job["slug"],
        job["crontab"],
        job.get("timezone", "UTC"),
        str(job.get("maxRuntimeSeconds", "")),
        str(job.get("marginSeconds", "")),
        job["command"],
    ]))
PY
    [[ -z "$slug" ]] && continue
    local token
    token="$(awk -F= -v slug="$slug" '$1==slug {print $2}' "$token_file" | tail -n 1)"
    if [[ -z "$token" ]]; then
      local body response revealed
      body="$(python3 - "$slug" "$schedule" "$timezone" "$max" "$margin" <<'PY'
import json, sys
body = {
  "input": {
    "__className__": "CheckInInput",
    "slug": sys.argv[1],
    "status": "ok",
    "crontab": sys.argv[2],
    "timezone": sys.argv[3],
  }
}
if sys.argv[4]:
    body["input"]["maxRuntimeSeconds"] = int(sys.argv[4])
if sys.argv[5]:
    body["input"]["marginSeconds"] = int(sys.argv[5])
print(json.dumps(body))
PY
)"
      response="$(curl -fsS -m 20 -X POST \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${key}" \
        -d "$body" \
        "${url%/}/monitors/checkIn" || true)"
      revealed="$(printf '%s' "$response" | python3 -c 'import json,sys
raw=sys.stdin.read()
try:
    data=json.loads(raw)
except Exception:
    data={}
print(data.get("pingToken") or data.get("result",{}).get("pingToken") or "")')"
      if [[ -n "$revealed" ]]; then
        printf '%s=%s\n' "$slug" "$revealed" >> "$token_file"
        token="$revealed"
      fi
    fi
    if [[ -z "$token" ]]; then
      echo "No ping token for ${slug}. The crontab line was not written."
      continue
    fi
    if grep -q "# talaria-monitor:${slug}$" "$cron_file"; then
      continue
    fi
    talaria_crontab_line "$slug" "$schedule" "$token" "${url%/}" "$command" >> "$cron_file"
    echo "Added crontab check-in for ${slug}"
  done
}
