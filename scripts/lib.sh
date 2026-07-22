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
  local ssh_opts_base=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
  if [[ -n "${WP_SSH_PORT:-}" ]]; then
    ssh_opts_base+=(-o "Port=${WP_SSH_PORT}")
  fi

  if out=$(ssh "${ssh_opts_base[@]}" "$remote_host" "grep -E \"^define\\([[:space:]]*'DB_(NAME|USER|PASSWORD|HOST)'\" \"$remote_wp_config\"" 2> /dev/null); then
    DB_NAME=$(echo "$out" | sed -n "s/^define([[:space:]]*'DB_NAME',[[:space:]]*'\(.*\)'[[:space:]]*);/\1/p" | sed "s/\\\\'/'/g")
    DB_USER=$(echo "$out" | sed -n "s/^define([[:space:]]*'DB_USER',[[:space:]]*'\(.*\)'[[:space:]]*);/\1/p" | sed "s/\\\\'/'/g")
    DB_PASSWORD=$(echo "$out" | sed -n "s/^define([[:space:]]*'DB_PASSWORD',[[:space:]]*'\(.*\)'[[:space:]]*);/\1/p" | sed "s/\\\\'/'/g")
    DB_HOST=$(echo "$out" | sed -n "s/^define([[:space:]]*'DB_HOST',[[:space:]]*'\(.*\)'[[:space:]]*);/\1/p" | sed "s/\\\\'/'/g")
  elif ssh "${ssh_opts_base[@]}" "$remote_host" "cd '$remote_wp_root' && wp config get DB_NAME --type=constant >/dev/null 2>&1"; then
    out=$(ssh "${ssh_opts_base[@]}" "$remote_host" "cd '$remote_wp_root' && wp config get DB_NAME --type=constant 2>/dev/null; wp config get DB_USER --type=constant 2>/dev/null; wp config get DB_PASSWORD --type=constant 2>/dev/null; wp config get DB_HOST --type=constant 2>/dev/null")
    DB_NAME=$(echo "$out" | sed -n '1p')
    DB_USER=$(echo "$out" | sed -n '2p')
    DB_PASSWORD=$(echo "$out" | sed -n '3p')
    DB_HOST=$(echo "$out" | sed -n '4p')
  elif ssh "${ssh_opts_base[@]}" "$remote_host" "php -r 'require \"$remote_wp_config\"; echo DB_NAME . \"\n\" . DB_USER . \"\n\" . DB_PASSWORD . \"\n\" . DB_HOST;'"; then
    out=$(ssh "${ssh_opts_base[@]}" "$remote_host" "php -r 'require \"$remote_wp_config\"; echo DB_NAME . \"\n\" . DB_USER . \"\n\" . DB_PASSWORD . \"\n\" . DB_HOST;'")
    DB_NAME=$(echo "$out" | sed -n '1p')
    DB_USER=$(echo "$out" | sed -n '2p')
    DB_PASSWORD=$(echo "$out" | sed -n '3p')
    DB_HOST=$(echo "$out" | sed -n '4p')
  fi

  if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASSWORD" || -z "$DB_HOST" ]]; then
    echo "ERROR: Could not parse DB credentials from $remote_wp_config on $remote_host" >&2
    exit 1
  fi
}
