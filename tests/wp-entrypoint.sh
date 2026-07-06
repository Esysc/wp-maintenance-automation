#!/bin/bash
set -euo pipefail

mkdir -p /run/sshd /etc/ssh/sshd_config.d

mkdir -p /root/.ssh

if [[ -f /root/.ssh/authorized_keys ]]; then
  cp /root/.ssh/authorized_keys /tmp/authorized_keys
  chmod 600 /tmp/authorized_keys
fi

env | grep '^WORDPRESS_' > /root/.ssh/environment 2> /dev/null || true

cat > /etc/ssh/sshd_config.d/override.conf << EOF
AuthorizedKeysFile /tmp/authorized_keys
StrictModes no
PermitUserEnvironment yes
EOF

if [[ ! -f /etc/ssh/ssh_host_rsa_key ]]; then
  ssh-keygen -A > /dev/null 2>&1
fi

/usr/sbin/sshd

# Create a real wp-config.php (without getenv_docker calls) so that
# backup/restore scripts can parse credentials via SSH.
if [[ ! -f /var/www/html/wp-config.php ]] && [[ -f /usr/src/wordpress/wp-config-docker.php ]]; then
  if [[ ! -f /var/www/html/index.php ]]; then
    cp -r /usr/src/wordpress/* /var/www/html/
  fi
  cp /usr/src/wordpress/wp-config-docker.php /var/www/html/wp-config.php
  for var in WORDPRESS_DB_HOST WORDPRESS_DB_USER WORDPRESS_DB_PASSWORD WORDPRESS_DB_NAME; do
    value="${!var:-}"
    if [[ -n "$value" ]]; then
      escaped_value=$(printf '%s\n' "$value" | sed 's/[\/&]/\\&/g')
      sed -i "s/getenv_docker('$var', '[^']*')/'$escaped_value'/" /var/www/html/wp-config.php
    fi
  done
  if [[ -n "${WORDPRESS_CONFIG_EXTRA:-}" ]]; then
    printf "\n%s\n" "$WORDPRESS_CONFIG_EXTRA" >> /var/www/html/wp-config.php
  fi
fi

exec docker-entrypoint.sh "$@"
