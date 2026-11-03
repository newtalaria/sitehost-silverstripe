#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
bash "${dir}/payload.test.sh"
bash "${dir}/backup-env.test.sh"
bash "${dir}/sitehost-api.test.sh"
bash "${dir}/api-backup-restore.test.sh"
bash "${dir}/snapshot.test.sh"
bash "${dir}/status.test.sh"
bash "${dir}/version.test.sh"
bash "${dir}/configure-env.test.sh"
bash "${dir}/collector.test.sh"
bash "${dir}/talaria-check.test.sh"
bash "${dir}/talaria-resolve.test.sh"
bash "${dir}/deploy-optional.test.sh"
python3 "${dir}/workflow.test.py"
