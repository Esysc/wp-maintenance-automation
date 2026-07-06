#!/usr/bin/env bash
set -euo pipefail

# Modern, secure WordPress backup using SSH + rsync + restic.
# Requirements:
# - SSH key-based access to the web server
# - rsync, gzip, restic installed locally
# - Optional: php CLI on remote for reliable wp-config parsing
# - Optional: rclone/SMB for repository storage

# Load environment from .env if present
if [[ -f ".env" ]]; then
  set -a
  source ".env"
  set +a
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

umask 077

# Required configuration
require_var WP_SSH_HOST       # e.g., example.com
require_var WP_SSH_USER       # e.g., ubuntu
require_var WP_ROOT           # e.g., /var/www/html
require_var RESTIC_REPOSITORY # e.g., b2:bucket:repo or /path/to/repo
require_var RESTIC_PASSWORD_FILE

# Optional configuration
BACKUP_DIR=${BACKUP_DIR:-./backup_artifacts}
RSYNC_EXCLUDES=${RSYNC_EXCLUDES:-wp-content/cache/}
RETENTION_FLAGS=${RETENTION_FLAGS:---keep-daily 14 --keep-weekly 8 --keep-monthly 12}
SERVER_CONFIG_PATHS=${SERVER_CONFIG_PATHS:-} # comma-separated absolute paths on server (e.g., /etc/nginx,/etc/letsencrypt)
DNS_BACKUP_SCRIPT=${DNS_BACKUP_SCRIPT:-}     # local script to export DNS (e.g., ./dns_export_cloudflare.sh)
LOCK_DIR=${LOCK_DIR:-$BACKUP_DIR/.backup.lock}
RESTIC_CHECK_AFTER_BACKUP=${RESTIC_CHECK_AFTER_BACKUP:-no}
RESTIC_CHECK_READ_DATA_SUBSET=${RESTIC_CHECK_READ_DATA_SUBSET:-}
BACKUP_SNAPSHOT_FILE=${BACKUP_SNAPSHOT_FILE:-}

preflight_local() {
  require_cmd ssh
  require_cmd rsync
  require_cmd gzip
  require_cmd restic
  require_cmd awk
  require_cmd sed
  require_cmd grep
}

preflight_remote() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$WP_SSH_USER@$WP_SSH_HOST" "test -f '$WP_ROOT/wp-config.php'" > /dev/null
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$WP_SSH_USER@$WP_SSH_HOST" "command -v mysqldump >/dev/null" > /dev/null
}

acquire_lock() {
  mkdir -p "$BACKUP_DIR"
  if ! mkdir "$LOCK_DIR" 2> /dev/null; then
    # Check for stale lock (process not running)
    if [[ -f "$LOCK_DIR/.pid" ]]; then
      local pid
      pid=$(cat "$LOCK_DIR/.pid" 2>/dev/null || true)
      if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        mkdir -p "$LOCK_DIR"
        echo "$$" > "$LOCK_DIR/.pid"
        return 0
      fi
    fi
    echo "ERROR: Backup lock exists at $LOCK_DIR. Another backup may be running." >&2
    exit 1
  fi
  echo "$$" > "$LOCK_DIR/.pid"
}

release_lock() {
  rm -rf "$LOCK_DIR" 2> /dev/null || true
}

TS=$(timestamp)
WORK_DIR="$BACKUP_DIR/$TS"
DB_DIR="$WORK_DIR/db"
WP_MIRROR_DIR="$WORK_DIR/wp"
CONFIG_DIR="$WORK_DIR/server_config"
DNS_DIR="$WORK_DIR/dns"
mkdir -p "$DB_DIR" "$WP_MIRROR_DIR"

cleanup() {
  release_lock
}
trap cleanup EXIT

write_manifest() {
  local file_count
  file_count=$(find "$WP_MIRROR_DIR" -type f | wc -l | tr -d ' ')
  {
    echo "timestamp=$TS"
    echo "host=$WP_SSH_HOST"
    echo "wp_root=$WP_ROOT"
    echo "db_name=$DB_NAME"
    echo "db_host=$DB_HOST"
    echo "db_dump_file=$(basename "$DB_DUMP_FILE")"
    echo "file_count=$file_count"
    echo "rsync_excludes=$RSYNC_EXCLUDES"
    echo "retention_flags=$RETENTION_FLAGS"
  } > "$WORK_DIR/manifest.txt"

  if command -v shasum > /dev/null 2>&1; then
    shasum -a 256 "$DB_DUMP_FILE" > "$WORK_DIR/manifest.sha256"
  fi
}

run_restic_check() {
  if [[ "$RESTIC_CHECK_AFTER_BACKUP" != "yes" ]]; then
    return 0
  fi

  echo "Running restic integrity check..."
  if [[ -n "$RESTIC_CHECK_READ_DATA_SUBSET" ]]; then
    restic --repo "$RESTIC_REPOSITORY" check --read-data-subset "$RESTIC_CHECK_READ_DATA_SUBSET"
  else
    restic --repo "$RESTIC_REPOSITORY" check
  fi
}

preflight_local
preflight_remote
acquire_lock

echo "[1/4] Reading DB credentials from remote wp-config.php..."
read_db_config

echo "[2/4] Dumping MySQL database via SSH..."
DB_DUMP_FILE="$DB_DIR/${TS}_${DB_NAME}.sql.gz"
# Avoid exposing password via process args; use base64-encoded password to prevent misinterpretation
DB_PASSWORD_B64=$(echo -n "$DB_PASSWORD" | base64 | tr -d '\n')
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$WP_SSH_USER@$WP_SSH_HOST" "export MYSQL_PWD=\$(echo '$DB_PASSWORD_B64' | base64 --decode); mysqldump --single-transaction --quick --lock-tables=false -u '$DB_USER' -h '$DB_HOST' '$DB_NAME'" | gzip > "$DB_DUMP_FILE"

echo "[3/4] Mirroring site files with rsync over SSH..."
EXCLUDE_FLAGS=()
IFS=',' read -r -a EXCLUDE_LIST <<< "$RSYNC_EXCLUDES"
for e in "${EXCLUDE_LIST[@]}"; do
  [[ -n "$e" ]] && EXCLUDE_FLAGS+=(--exclude "$e")
done
rsync -a --delete -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" "${EXCLUDE_FLAGS[@]}" "$WP_SSH_USER@$WP_SSH_HOST:$WP_ROOT/" "$WP_MIRROR_DIR/"

if [[ -n "$SERVER_CONFIG_PATHS" ]]; then
  echo "[4/6] Capturing server configs..."
  mkdir -p "$CONFIG_DIR"
  IFS=',' read -r -a CFG_LIST <<< "$SERVER_CONFIG_PATHS"
  for p in "${CFG_LIST[@]}"; do
    [[ -z "$p" ]] && continue
    # Preserve original directory structure under CONFIG_DIR
    dest="$CONFIG_DIR$p"
    mkdir -p "$(dirname "$dest")"
    rsync -a -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" "$WP_SSH_USER@$WP_SSH_HOST:$p" "$dest" || echo "WARN: Could not sync $p"
  done
fi

if [[ -n "$DNS_BACKUP_SCRIPT" ]]; then
  echo "[5/6] Exporting DNS records via $DNS_BACKUP_SCRIPT..."
  mkdir -p "$DNS_DIR"
  if [[ -x "$DNS_BACKUP_SCRIPT" || -f "$DNS_BACKUP_SCRIPT" ]]; then
    bash "$DNS_BACKUP_SCRIPT" "$DNS_DIR" || echo "WARN: DNS export failed"
  else
    echo "WARN: DNS_BACKUP_SCRIPT not found: $DNS_BACKUP_SCRIPT"
  fi
fi

write_manifest

echo "[6/6] Backing up with restic (encrypted, deduplicated)..."
export RESTIC_PASSWORD_FILE
RESTIC_BACKUP_OUTPUT=$(restic --repo "$RESTIC_REPOSITORY" backup "$WORK_DIR" --tag "wordpress" --tag "$WP_SSH_HOST" --tag "$TS" --json)
echo "$RESTIC_BACKUP_OUTPUT" > "$WORK_DIR/restic_backup.json"

SNAPSHOT_ID=$(echo "$RESTIC_BACKUP_OUTPUT" | jq -r '.snapshot_id // empty' | tail -n1)
if [[ -n "$SNAPSHOT_ID" ]]; then
  echo "$SNAPSHOT_ID" > "$WORK_DIR/restic_snapshot_id.txt"
  if [[ -n "$BACKUP_SNAPSHOT_FILE" ]]; then
    echo "$SNAPSHOT_ID" > "$BACKUP_SNAPSHOT_FILE"
  fi
fi

echo "Applying retention policy: $RETENTION_FLAGS"
restic --repo "$RESTIC_REPOSITORY" forget --prune $RETENTION_FLAGS

run_restic_check

echo "Backup completed. Artifacts in: $WORK_DIR"
