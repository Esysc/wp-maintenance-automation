#!/usr/bin/env bash
set -euo pipefail

# Restore WordPress from restic backup.
# Modes:
# - Local extract only (default): restores artifacts to a local directory.
# - Remote apply (optional): push files/configs to server and import DB.

if [[ -f ".env" ]]; then
  set -a
  source ".env"
  set +a
fi

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: Required variable '$name' is not set." >&2
    exit 1
  fi
}

# Required for remote apply
require_var WP_SSH_HOST
require_var WP_SSH_USER
require_var WP_ROOT
require_var RESTIC_REPOSITORY
require_var RESTIC_PASSWORD_FILE

SNAPSHOT="${1:-latest}"
RESTORE_DIR=${RESTORE_DIR:-./restore}
APPLY_DB=${APPLY_DB:-no}
APPLY_FILES=${APPLY_FILES:-no}
APPLY_CONFIGS=${APPLY_CONFIGS:-no}
DELETE_REMOTE_FILES=${DELETE_REMOTE_FILES:-no}
REMOTE_SUDO=${REMOTE_SUDO:-no} # use sudo on remote when writing configs
CONFIRM_RESTORE=${CONFIRM_RESTORE:-no}

if [[ "$APPLY_DB" == "yes" || "$APPLY_FILES" == "yes" || "$APPLY_CONFIGS" == "yes" ]]; then
  if [[ "$CONFIRM_RESTORE" != "yes" ]]; then
    echo "ERROR: Remote apply requested but CONFIRM_RESTORE is not 'yes'." >&2
    echo "Set CONFIRM_RESTORE=yes to proceed."
    exit 1
  fi
fi

timestamp() { date +%Y%m%d_%H%M%S; }
TS=$(timestamp)
TARGET="$RESTORE_DIR/$TS"
mkdir -p "$TARGET"

echo "[1/5] Restoring snapshot '$SNAPSHOT' to $TARGET..."
export RESTIC_PASSWORD_FILE
restic --repo "$RESTIC_REPOSITORY" restore "$SNAPSHOT" --target "$TARGET"

# Locate artifact root (backup_artifacts/<ts>) under target
ARTIFACT_ROOT=""
if [[ -d "$TARGET/backup_artifacts" ]]; then
  # pick the most recent subfolder if multiple
  latest_sub=$(ls -1 "$TARGET/backup_artifacts" | sort | tail -n1 || true)
  if [[ -n "$latest_sub" && -d "$TARGET/backup_artifacts/$latest_sub" ]]; then
    ARTIFACT_ROOT="$TARGET/backup_artifacts/$latest_sub"
  else
    ARTIFACT_ROOT="$TARGET/backup_artifacts"
  fi
else
  ARTIFACT_ROOT="$TARGET"
fi

DB_DIR="$ARTIFACT_ROOT/db"
WP_DIR="$ARTIFACT_ROOT/wp"
CFG_DIR="$ARTIFACT_ROOT/server_config"
DNS_DIR="$ARTIFACT_ROOT/dns"

echo "Artifacts found:"
[[ -d "$DB_DIR" ]] && echo " - DB: $DB_DIR" || echo " - DB: (none)"
[[ -d "$WP_DIR" ]] && echo " - Files: $WP_DIR" || echo " - Files: (none)"
[[ -d "$CFG_DIR" ]] && echo " - Server configs: $CFG_DIR" || echo " - Server configs: (none)"
[[ -d "$DNS_DIR" ]] && echo " - DNS: $DNS_DIR" || echo " - DNS: (none)"

read_db_config() {
  local out
  REMOTE_WP_CONFIG="$WP_ROOT/wp-config.php"
  if ssh -o BatchMode=yes "$WP_SSH_USER@$WP_SSH_HOST" "php -v" >/dev/null 2>&1; then
    out=$(ssh "$WP_SSH_USER@$WP_SSH_HOST" "php -r 'include \"$REMOTE_WP_CONFIG\"; echo DB_NAME.\"\\n\".DB_USER.\"\\n\".DB_PASSWORD.\"\\n\".DB_HOST;'")
    DB_NAME=$(echo "$out" | sed -n '1p')
    DB_USER=$(echo "$out" | sed -n '2p')
    DB_PASSWORD=$(echo "$out" | sed -n '3p')
    DB_HOST=$(echo "$out" | sed -n '4p')
  else
    out=$(ssh "$WP_SSH_USER@$WP_SSH_HOST" "grep -E \"^define\\\('DB_(NAME|USER|PASSWORD|HOST)'\" \"$REMOTE_WP_CONFIG\"" | tr -d ' ')
    DB_NAME=$(echo "$out" | awk -F"'" "/DB_NAME/{print \$4}")
    DB_USER=$(echo "$out" | awk -F"'" "/DB_USER/{print \$4}")
    DB_PASSWORD=$(echo "$out" | awk -F"'" "/DB_PASSWORD/{print \$4}")
    DB_HOST=$(echo "$out" | awk -F"'" "/DB_HOST/{print \$4}")
  fi
  if [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASSWORD" || -z "$DB_HOST" ]]; then
    echo "ERROR: Could not parse DB credentials from remote wp-config.php" >&2
    exit 1
  fi
}

restore_db() {
  if [[ ! -d "$DB_DIR" ]]; then
    echo "Skip DB restore: no db directory found"
    return
  fi
  local dump
  dump=$(ls -1 "$DB_DIR"/*.gz 2>/dev/null | sort | tail -n1 || true)
  if [[ -z "$dump" ]]; then
    echo "Skip DB restore: no dump file found"
    return
  fi
  echo "Restoring DB from $dump to $WP_SSH_HOST/$DB_NAME..."
  gunzip -c "$dump" | ssh "$WP_SSH_USER@$WP_SSH_HOST" "export MYSQL_PWD='$DB_PASSWORD'; mysql -u '$DB_USER' -h '$DB_HOST' '$DB_NAME'"
}

restore_files() {
  if [[ ! -d "$WP_DIR" ]]; then
    echo "Skip file restore: no wp directory found"
    return
  fi
  echo "Syncing files to $WP_SSH_HOST:$WP_ROOT ..."
  flags=( -a -e ssh )
  if [[ "$DELETE_REMOTE_FILES" == "yes" ]]; then
    flags+=( --delete )
  fi
  rsync "${flags[@]}" "$WP_DIR/" "$WP_SSH_USER@$WP_SSH_HOST:$WP_ROOT/"
}

restore_configs() {
  if [[ ! -d "$CFG_DIR" ]]; then
    echo "Skip configs restore: no server_config directory found"
    return
  fi
  echo "Restoring server configs to remote..."
  RSYNC_PATH="rsync"
  if [[ "$REMOTE_SUDO" == "yes" ]]; then
    RSYNC_PATH="sudo rsync"
  fi
  # Iterate through first-level entries under CFG_DIR and sync to root
  # Preserves original path structure captured during backup
  while IFS= read -r -d '' entry; do
    rel=${entry#"$CFG_DIR"}
    dest="$rel"
    echo " - $dest"
    rsync -a -e ssh --rsync-path "$RSYNC_PATH" "$entry/" "$WP_SSH_USER@$WP_SSH_HOST:$dest/"
  done < <(find "$CFG_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
}

echo "[2/5] Local extract complete in $ARTIFACT_ROOT"

if [[ "$APPLY_DB" == "yes" ]]; then
  echo "[3/5] Reading DB credentials from remote..."
  read_db_config
  echo "[4/5] Restoring database..."
  restore_db
fi

if [[ "$APPLY_FILES" == "yes" ]]; then
  echo "[5/5] Restoring files..."
  restore_files
fi

if [[ "$APPLY_CONFIGS" == "yes" ]]; then
  echo "[5/5] Restoring server configs..."
  restore_configs
fi

echo "Restore finished. Review: $ARTIFACT_ROOT"
