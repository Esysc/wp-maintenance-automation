#!/usr/bin/env bash
set -euo pipefail

mkdir -p /run/sshd /etc/ssh/sshd_config.d /root/.ssh

if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys /tmp/authorized_keys
  chmod 600 /tmp/authorized_keys
fi

cat > /etc/ssh/sshd_config.d/override.conf << EOF
AuthorizedKeysFile /tmp/authorized_keys
StrictModes no
PermitUserEnvironment yes
EOF

if [[ ! -f /etc/ssh/ssh_host_rsa_key ]]; then
  ssh-keygen -A > /dev/null 2>&1
fi

/usr/sbin/sshd

if [[ ! -f /var/www/html/wp-config.php ]]; then
  cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php
  tr -d $'\r' < /var/www/html/wp-config.php > /tmp/wp-config.tmp && mv /tmp/wp-config.tmp /var/www/html/wp-config.php

  sed -i "s/^define(\\s*'DB_NAME',[[:space:]]*'\(.*\)'[[:space:]]*);\$/define('DB_NAME', '${WORDPRESS_DB_NAME:-database_name_here}');/" /var/www/html/wp-config.php
  sed -i "s/^define(\\s*'DB_USER',[[:space:]]*'\(.*\)'[[:space:]]*);\$/define('DB_USER', '${WORDPRESS_DB_USER:-username_here}');/" /var/www/html/wp-config.php
  sed -i "s/^define(\\s*'DB_PASSWORD',[[:space:]]*'\(.*\)'[[:space:]]*);\$/define('DB_PASSWORD', '${WORDPRESS_DB_PASSWORD:-password_here}');/" /var/www/html/wp-config.php
  sed -i "s/^define(\\s*'DB_HOST',[[:space:]]*'\(.*\)'[[:space:]]*);\$/define('DB_HOST', '${WORDPRESS_DB_HOST:-localhost}');/" /var/www/html/wp-config.php

  if [[ -n "${WORDPRESS_CONFIG_EXTRA:-}" ]]; then
    printf "\n%s\n" "$WORDPRESS_CONFIG_EXTRA" >> /var/www/html/wp-config.php
  fi
fi

set +u
. /etc/apache2/envvars
set -u
exec apache2 -DFOREGROUND
