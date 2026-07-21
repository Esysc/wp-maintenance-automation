#!/usr/bin/env bash
set -euo pipefail

escape_sed_repl() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//&/\\&}"
  s="${s//\//\\/}"
  printf '%s\n' "$s"
}

cd /var/www/html

# Only update DB_HOST in the backup's actual wp-config.php
# (credentials like DB_NAME/USER/PASSWORD stay as they were from the backup)
if [[ -f wp-config.php ]]; then
  db_host=$(escape_sed_repl "${WORDPRESS_DB_HOST:-db:3306}")
  sed -i "s/^define(\\s*'DB_HOST',[[:space:]]*'\(.*\)'[[:space:]]*);\$/define('DB_HOST', '${db_host}');/" wp-config.php
fi
