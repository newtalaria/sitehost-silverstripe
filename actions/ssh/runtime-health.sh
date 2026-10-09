#!/usr/bin/env bash
# Re-apply SiteHost monitors by running the PHP installer in the app.
# ssh-payload.sh prepends this file onto the encoded deploy script, because that
# script is piped into bash and has no path of its own. A file run directly
# sources this file when SITEHOST_RUNTIME_LOADED is unset.
# Opt-in when the app has talaria/sitehost/monitors.json or TALARIA_INSTALL_PROBE is true.
# The installer owns registration. Cron still pings with curl, and the probe still reports.

export SITEHOST_RUNTIME_LOADED=1

talaria_runtime_wanted() {
  if [[ "${TALARIA_INSTALL_PROBE:-}" == "true" ]]; then
    return 0
  fi
  [[ -f "${SITEHOST_APP_PATH}/talaria/sitehost/monitors.json" ]]
}

install_talaria_runtime() {
  if ! talaria_runtime_wanted; then
    return 0
  fi
  local installer="${SITEHOST_APP_PATH}/vendor/bin/talaria-sitehost"
  if [[ ! -f "$installer" ]]; then
    echo "vendor/bin/talaria-sitehost is missing. Install talaria/silverstripe 2.1.1 or newer." >&2
    exit 1
  fi
  "$installer" install
}
