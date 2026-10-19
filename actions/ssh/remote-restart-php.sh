#!/usr/bin/env bash
# Restart php under supervisor after a restore. Does not change files.
set -euo pipefail

if ! command -v supervisorctl >/dev/null 2>&1; then
  echo "supervisorctl is not available, so php was not restarted." >&2
  exit 1
fi
echo "Restarting php"
supervisorctl restart php
