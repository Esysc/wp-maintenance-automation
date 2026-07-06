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

  if ssh -o BatchMode=yes "$remote_host" "command -v wp >/dev/null" > /dev/null 2>&1; then
    out=$(ssh "$remote_host" "cd '$remote_wp_root' && wp config get DB_NAME --type=constant 2>/dev/null; wp config get DB_USER --type=constant 2>/dev/null; wp config get DB_PASSWORD --type=constant 2>/dev/null; wp config get DB_HOST --type=constant 2>/dev/null")
    DB_NAME=$(echo "$out" | sed -n '1p')
    DB_USER=$(echo "$out" | sed -n '2p')
    DB_PASSWORD=$(echo "$out" | sed -n '3p')
    DB_HOST=$(echo "$out" | sed -n '4p')
  elif ssh -o BatchMode=yes "$remote_host" "php -v" > /dev/null 2>&1; then
    out=$(ssh "$remote_host" "php -r '\
      \$cfg=file_get_contents(\"$remote_wp_config\");\
      foreach ([\"DB_NAME\",\"DB_USER\",\"DB_PASSWORD\",\"DB_HOST\"] as \$k) {\
        if (preg_match(\"/define\\s*\\(\\s*[\\x27\\\"]\".\$k.\"[\\x27\\\"]\\s*,\\s*[\\x27\\\"](.*?)[\\x27\\\"]\\s*\\)\\s*;/\", \$cfg, \$m)) echo \$m[1].PHP_EOL; else echo PHP_EOL;\
      }\
    '")
    DB_NAME=$(echo "$out" | sed -n '1p')
    DB_USER=$(echo "$out" | sed -n '2p')
    DB_PASSWORD=$(echo "$out" | sed -n '3p')
    DB_HOST=$(echo "$out" | sed -n '4p')
  else
    out=$(ssh "$remote_host" "grep -E \"^define\\\('DB_(NAME|USER|PASSWORD|HOST)'\" \"$remote_wp_config\"" | tr -d ' ')
    DB_NAME=$(echo "$out" | awk -F"'" "/DB_NAME/{print \$4}")
    DB_USER=$(echo "$out" | awk -F"'" "/DB_USER/{print \$4}")
    DB_PASSWORD=$(echo "$out" | awk -F"'" "/DB_PASSWORD/{print \$4}")
    DB_HOST=$(echo "$out" | awk -F"'" "/DB_HOST/{print \$4}")
  fi

  if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASSWORD" || -z "$DB_HOST" ]]; then
    echo "ERROR: Could not parse DB credentials from $remote_wp_config on $remote_host" >&2
    exit 1
  fi
}
