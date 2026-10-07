#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"
bash "${dir}/payload.test.sh"
bash "${dir}/backup-env.test.sh"
