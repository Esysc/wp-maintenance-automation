#!/usr/bin/env bash
set -euo pipefail

cd /var/www/html

# Only update DB_HOST in the backup's actual wp-config.php
# (credentials like DB_NAME/USER/PASSWORD stay as they were from the backup)
if [[ -f wp-config.php ]]; then
  sed -i "s/^define(\\s*'DB_HOST',[[:space:]]*'\(.*\)'[[:space:]]*);\$/define('DB_HOST', '${WORDPRESS_DB_HOST:-db:3306}');/" wp-config.php
fi
