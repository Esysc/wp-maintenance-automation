#!/usr/bin/env bash
set -euo pipefail

cd /app

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

exec /app/scripts/backup_secure.sh
