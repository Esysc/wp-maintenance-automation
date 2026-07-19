# shellcheck shell=bash
require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: Required variable '$name' is not set." >&2
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' is not installed." >&2
    exit 1
  fi
}

timestamp() { date +%Y%m%d_%H%M%S; }

read_db_config() {
  local remote_host="$WP_SSH_USER@$WP_SSH_HOST"
  local remote_wp_root="$WP_ROOT"
  local remote_wp_config="$remote_wp_root/wp-config.php"
  local out

  if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$remote_host" "cd '$remote_wp_root' && wp config get DB_NAME --type=constant >/dev/null 2>&1" > /dev/null 2>&1; then
    out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$remote_host" "cd '$remote_wp_root' && wp config get DB_NAME --type=constant 2>/dev/null; wp config get DB_USER --type=constant 2>/dev/null; wp config get DB_PASSWORD --type=constant 2>/dev/null; wp config get DB_HOST --type=constant 2>/dev/null")
    DB_NAME=$(echo "$out" | sed -n '1p')
    DB_USER=$(echo "$out" | sed -n '2p')
    DB_PASSWORD=$(echo "$out" | sed -n '3p')
    DB_HOST=$(echo "$out" | sed -n '4p')
  elif ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$remote_host" "php -r 'require \"$remote_wp_config\"; echo DB_NAME . \"\n\" . DB_USER . \"\n\" . DB_PASSWORD . \"\n\" . DB_HOST;'" > /dev/null 2>&1; then
    out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$remote_host" "php -r 'require \"$remote_wp_config\"; echo DB_NAME . \"\n\" . DB_USER . \"\n\" . DB_PASSWORD . \"\n\" . DB_HOST;'")
    DB_NAME=$(echo "$out" | sed -n '1p')
    DB_USER=$(echo "$out" | sed -n '2p')
    DB_PASSWORD=$(echo "$out" | sed -n '3p')
    DB_HOST=$(echo "$out" | sed -n '4p')
  else
    out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$remote_host" "grep -E \"^define\\('DB_(NAME|USER|PASSWORD|HOST)'\" \"$remote_wp_config\"")
    DB_NAME=$(echo "$out" | sed -n "s/^define('DB_NAME',[[:space:]]*'\(.*\)');/\1/p" | sed "s/\\\\'/'/g")
    DB_USER=$(echo "$out" | sed -n "s/^define('DB_USER',[[:space:]]*'\(.*\)');/\1/p" | sed "s/\\\\'/'/g")
    DB_PASSWORD=$(echo "$out" | sed -n "s/^define('DB_PASSWORD',[[:space:]]*'\(.*\)');/\1/p" | sed "s/\\\\'/'/g")
    DB_HOST=$(echo "$out" | sed -n "s/^define('DB_HOST',[[:space:]]*'\(.*\)');/\1/p" | sed "s/\\\\'/'/g")
  fi

  if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASSWORD" || -z "$DB_HOST" ]]; then
    echo "ERROR: Could not parse DB credentials from $remote_wp_config on $remote_host" >&2
    exit 1
  fi
}
