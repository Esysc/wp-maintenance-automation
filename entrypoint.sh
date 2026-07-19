#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

cd /app

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

exec /app/scripts/backup_secure.sh
