#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Restore WordPress from restic backup.
# Modes:
# - Local extract only (default): restores artifacts to a local directory.
# - Remote apply (optional): push files/configs to server and import DB.

RESTIC_PASSWORD_FILE_FALLBACK="${RESTIC_PASSWORD_FILE:-}"
if [[ -f ".env" ]]; then
  set -a
  source ".env"
  set +a
fi
if [[ -n "${RESTIC_PASSWORD_FILE:-}" && ! -f "${RESTIC_PASSWORD_FILE:-}" ]] && [[ -n "${RESTIC_PASSWORD_FILE_FALLBACK:-}" && -f "${RESTIC_PASSWORD_FILE_FALLBACK:-}" ]]; then
  RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE_FALLBACK"
fi
RESTIC_REPOSITORY_FALLBACK="${RESTIC_REPOSITORY_FALLBACK:-}"
if [[ "${RESTIC_REPOSITORY:-}" == /* && ! -d "${RESTIC_REPOSITORY:-}" ]] && [[ -n "${RESTIC_REPOSITORY_FALLBACK:-}" && -d "${RESTIC_REPOSITORY_FALLBACK:-}" ]]; then
  RESTIC_REPOSITORY="$RESTIC_REPOSITORY_FALLBACK"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
if [[ -n "${WP_SSH_PORT:-}" ]]; then
  SSH_OPTS+=(-o "Port=${WP_SSH_PORT}")
fi

# Always required for restic restore
require_var RESTIC_REPOSITORY
require_var RESTIC_PASSWORD_FILE

SNAPSHOT="${1:-latest}"
RESTORE_DIR=${RESTORE_DIR:-./restore}
APPLY_DB=${APPLY_DB:-no}
APPLY_FILES=${APPLY_FILES:-no}
APPLY_CONFIGS=${APPLY_CONFIGS:-no}
DELETE_REMOTE_FILES=${DELETE_REMOTE_FILES:-no}
REMOTE_SUDO=${REMOTE_SUDO:-no}
CONFIRM_RESTORE=${CONFIRM_RESTORE:-no}

if [[ "$APPLY_DB" == "yes" || "$APPLY_FILES" == "yes" || "$APPLY_CONFIGS" == "yes" ]]; then
  require_var WP_SSH_HOST
  require_var WP_SSH_USER
  require_var WP_ROOT

  if [[ "$CONFIRM_RESTORE" != "yes" ]]; then
    echo "ERROR: Remote apply requested but CONFIRM_RESTORE is not 'yes'." >&2
    echo "Set CONFIRM_RESTORE=yes to proceed."
    exit 1
  fi
fi

TS=$(timestamp)
TARGET="$RESTORE_DIR/$TS"
mkdir -p "$TARGET"

echo "[1/5] Restoring snapshot '$SNAPSHOT' to $TARGET..."
export RESTIC_PASSWORD_FILE
restic --repo "$RESTIC_REPOSITORY" restore "$SNAPSHOT" --target "$TARGET"

ARTIFACT_ROOT="$TARGET"
found=$(find "$TARGET" -type d -name "backup_artifacts" 2> /dev/null | head -n1 || true)
if [[ -n "$found" ]]; then
  latest_sub=$(ls -1t "$found" 2> /dev/null | head -n1 || true)
  if [[ -n "$latest_sub" && -d "$found/$latest_sub" ]]; then
    ARTIFACT_ROOT="$found/$latest_sub"
  else
    ARTIFACT_ROOT="$found"
  fi
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

restore_db() {
  if [[ ! -d "$DB_DIR" ]]; then
    echo "Skip DB restore: no db directory found"
    return
  fi
  local dump
  dump=$(ls -1 "$DB_DIR"/*.gz 2> /dev/null | sort | tail -n1 || true)
  if [[ -z "$dump" ]]; then
    echo "Skip DB restore: no dump file found"
    return
  fi
  echo "Restoring DB from $dump to $WP_SSH_HOST/$DB_NAME..."
  local mysql_cnf_remote
  mysql_cnf_remote="/tmp/mysql_restore_$(timestamp).cnf"
  local mysql_cnf_content mysql_cnf_b64
  mysql_cnf_content=$(printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "$DB_USER" "$DB_PASSWORD" "$DB_HOST")
  mysql_cnf_b64=$(printf '%s' "$mysql_cnf_content" | base64 | tr -d '\n')
  gunzip -c "$dump" | ssh "${SSH_OPTS[@]}" "$WP_SSH_USER@$WP_SSH_HOST" "echo '$mysql_cnf_b64' | base64 --decode > '$mysql_cnf_remote' && chmod 600 '$mysql_cnf_remote' && mysql --defaults-extra-file='$mysql_cnf_remote' '$DB_NAME'; rc=\$?; rm -f '$mysql_cnf_remote'; exit \$rc"
}

restore_files() {
  if [[ ! -d "$WP_DIR" ]]; then
    echo "Skip file restore: no wp directory found"
    return
  fi
  echo "Syncing files to $WP_SSH_HOST:$WP_ROOT ..."
  flags=(-a --no-owner --no-group --timeout=60 -e "ssh ${SSH_OPTS[*]}")
  if [[ "$DELETE_REMOTE_FILES" == "yes" ]]; then
    echo "WARNING: --delete is enabled. Files on the remote not present in the backup will be removed."
    flags+=(--delete)
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
    rsync -a --no-owner --no-group --timeout=60 -e "ssh ${SSH_OPTS[*]}" --rsync-path "$RSYNC_PATH" "$entry/" "$WP_SSH_USER@$WP_SSH_HOST:$dest/"
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
