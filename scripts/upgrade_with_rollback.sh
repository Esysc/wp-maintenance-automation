#!/usr/bin/env bash
set -euo pipefail

# Orchestrates: backup -> full WordPress upgrade -> health checks -> optional rollback.
# Always generates a report and a detailed log file.

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

timestamp() { date +%Y%m%d_%H%M%S; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup_secure.sh"
RESTORE_SCRIPT="$SCRIPT_DIR/restore_secure.sh"

require_var WP_SSH_HOST
require_var WP_SSH_USER
require_var WP_ROOT
require_var RESTIC_REPOSITORY
require_var RESTIC_PASSWORD_FILE

REPORT_DIR=${UPGRADE_REPORT_DIR:-./var/reports/wp_upgrade}
HEALTHCHECK_URL=${HEALTHCHECK_URL:-}
HEALTHCHECK_EXPECT_CODE=${HEALTHCHECK_EXPECT_CODE:-200}
HEALTHCHECK_RETRIES=${HEALTHCHECK_RETRIES:-5}
HEALTHCHECK_DELAY_SECONDS=${HEALTHCHECK_DELAY_SECONDS:-15}
HEALTHCHECK_TIMEOUT_SECONDS=${HEALTHCHECK_TIMEOUT_SECONDS:-20}
AUTO_RESTORE_ON_FAILURE=${AUTO_RESTORE_ON_FAILURE:-yes}
APPLY_CONFIGS_ON_ROLLBACK=${APPLY_CONFIGS_ON_ROLLBACK:-no}
DELETE_REMOTE_FILES_ON_ROLLBACK=${DELETE_REMOTE_FILES_ON_ROLLBACK:-no}
REMOTE_SUDO_ON_ROLLBACK=${REMOTE_SUDO_ON_ROLLBACK:-no}
WP_CLI_BIN=${WP_CLI_BIN:-wp}
WP_CLI_EXTRA_ARGS=${WP_CLI_EXTRA_ARGS:-}
EXTRA_POST_UPGRADE_CHECK_CMD=${EXTRA_POST_UPGRADE_CHECK_CMD:-}

TS="$(timestamp)"
RUN_DIR="$REPORT_DIR/$TS"
mkdir -p "$RUN_DIR"
LOG_FILE="$RUN_DIR/run.log"
REPORT_FILE="$RUN_DIR/report.txt"

log() {
  local msg="$1"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] $msg" | tee -a "$LOG_FILE"
}

write_report() {
  {
    echo "WordPress Upgrade Run Report"
    echo "Timestamp: $TS"
    echo "Host: $WP_SSH_HOST"
    echo "WordPress path: $WP_ROOT"
    echo "Backup snapshot: ${BACKUP_SNAPSHOT_ID:-unknown}"
    echo "Healthcheck URL: ${HEALTHCHECK_URL:-auto-detected}"
    echo ""
    echo "Step status"
    echo "- Backup: $BACKUP_STATUS"
    echo "- Upgrade: $UPGRADE_STATUS"
    echo "- Healthcheck: $HEALTH_STATUS"
    echo "- Rollback: $ROLLBACK_STATUS"
    echo ""
    echo "Final result: $FINAL_STATUS"
    echo "Reason: ${FINAL_REASON:-none}"
    echo "Log file: $LOG_FILE"
  } > "$REPORT_FILE"
}

remote_wp() {
  local wp_args="$1"
  ssh "$WP_SSH_USER@$WP_SSH_HOST" "cd '$WP_ROOT' && $WP_CLI_BIN $WP_CLI_EXTRA_ARGS $wp_args"
}

derive_healthcheck_url() {
  if [[ -n "$HEALTHCHECK_URL" ]]; then
    return 0
  fi

  local detected
  detected=$(ssh "$WP_SSH_USER@$WP_SSH_HOST" "cd '$WP_ROOT' && $WP_CLI_BIN $WP_CLI_EXTRA_ARGS option get home 2>/dev/null" || true)
  if [[ -n "$detected" ]]; then
    HEALTHCHECK_URL="$detected"
  fi
}

run_backup() {
  local snapshot_file
  snapshot_file="$RUN_DIR/backup_snapshot_id.txt"

  log "Starting backup..."
  if BACKUP_SNAPSHOT_FILE="$snapshot_file" bash "$BACKUP_SCRIPT" >>"$LOG_FILE" 2>&1; then
    BACKUP_STATUS="ok"

    if [[ -s "$snapshot_file" ]]; then
      BACKUP_SNAPSHOT_ID=$(cat "$snapshot_file")
    else
      # Fallback when backup cannot provide snapshot id directly.
      BACKUP_SNAPSHOT_ID="latest"
    fi

    log "Backup completed. Snapshot: $BACKUP_SNAPSHOT_ID"
    return 0
  fi

  BACKUP_STATUS="failed"
  FINAL_STATUS="failed"
  FINAL_REASON="Backup failed, upgrade aborted"
  log "Backup failed. Aborting run."
  return 1
}

run_upgrade() {
  log "Starting WordPress full upgrade with WP-CLI..."

  if ! remote_wp "core update" >>"$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="core update failed"
    return 1
  fi

  if ! remote_wp "plugin update --all" >>"$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="plugin update failed"
    return 1
  fi

  if ! remote_wp "theme update --all" >>"$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="theme update failed"
    return 1
  fi

  # Keep language packs aligned with updated core/plugins/themes.
  if ! remote_wp "language core update" >>"$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="language core update failed"
    return 1
  fi

  if ! remote_wp "language plugin update --all" >>"$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="language plugin update failed"
    return 1
  fi

  if ! remote_wp "language theme update --all" >>"$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="language theme update failed"
    return 1
  fi

  if ! remote_wp "core update-db" >>"$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="core update-db failed"
    return 1
  fi

  UPGRADE_STATUS="ok"
  return 0
}

run_healthcheck() {
  derive_healthcheck_url

  if [[ -z "$HEALTHCHECK_URL" ]]; then
    HEALTH_STATUS="failed"
    FINAL_REASON="healthcheck URL missing (set HEALTHCHECK_URL in .env)"
    log "Healthcheck URL could not be auto-detected."
    return 1
  fi

  log "Running HTTP healthcheck on $HEALTHCHECK_URL"

  local attempt code
  attempt=1
  while [[ "$attempt" -le "$HEALTHCHECK_RETRIES" ]]; do
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time "$HEALTHCHECK_TIMEOUT_SECONDS" "$HEALTHCHECK_URL" || true)
    if [[ "$code" == "$HEALTHCHECK_EXPECT_CODE" ]]; then
      log "Healthcheck passed with status $code on attempt $attempt"
      if [[ -n "$EXTRA_POST_UPGRADE_CHECK_CMD" ]]; then
        log "Running extra post-upgrade check command"
        if ! ssh "$WP_SSH_USER@$WP_SSH_HOST" "cd '$WP_ROOT' && $EXTRA_POST_UPGRADE_CHECK_CMD" >>"$LOG_FILE" 2>&1; then
          HEALTH_STATUS="failed"
          FINAL_REASON="extra post-upgrade check failed"
          return 1
        fi
      fi
      HEALTH_STATUS="ok"
      return 0
    fi

    log "Healthcheck attempt $attempt/$HEALTHCHECK_RETRIES failed (status=$code)."
    attempt=$((attempt + 1))
    if [[ "$attempt" -le "$HEALTHCHECK_RETRIES" ]]; then
      sleep "$HEALTHCHECK_DELAY_SECONDS"
    fi
  done

  HEALTH_STATUS="failed"
  FINAL_REASON="healthcheck failed after $HEALTHCHECK_RETRIES attempts"
  return 1
}

run_rollback() {
  if [[ "$AUTO_RESTORE_ON_FAILURE" != "yes" ]]; then
    ROLLBACK_STATUS="skipped"
    log "Rollback disabled by AUTO_RESTORE_ON_FAILURE=$AUTO_RESTORE_ON_FAILURE"
    return 0
  fi

  log "Starting rollback using snapshot ${BACKUP_SNAPSHOT_ID:-latest}..."
  if CONFIRM_RESTORE=yes \
     APPLY_DB=yes \
     APPLY_FILES=yes \
     APPLY_CONFIGS="$APPLY_CONFIGS_ON_ROLLBACK" \
     DELETE_REMOTE_FILES="$DELETE_REMOTE_FILES_ON_ROLLBACK" \
     REMOTE_SUDO="$REMOTE_SUDO_ON_ROLLBACK" \
     bash "$RESTORE_SCRIPT" "${BACKUP_SNAPSHOT_ID:-latest}" >>"$LOG_FILE" 2>&1; then
    ROLLBACK_STATUS="ok"
    return 0
  fi

  ROLLBACK_STATUS="failed"
  FINAL_REASON="rollback failed"
  return 1
}

BACKUP_STATUS="not-run"
UPGRADE_STATUS="not-run"
HEALTH_STATUS="not-run"
ROLLBACK_STATUS="not-run"
FINAL_STATUS="failed"
FINAL_REASON="unexpected"
BACKUP_SNAPSHOT_ID=""

cd "$ROOT_DIR"

if ! run_backup; then
  write_report
  log "Report written to $REPORT_FILE"
  exit 1
fi

if ! run_upgrade; then
  log "Upgrade failed. Rolling back..."
  run_rollback || true
  write_report
  log "Report written to $REPORT_FILE"
  exit 1
fi

if ! run_healthcheck; then
  log "Healthcheck failed after upgrade. Rolling back..."
  run_rollback || true
  write_report
  log "Report written to $REPORT_FILE"
  exit 1
fi

ROLLBACK_STATUS="not-needed"
FINAL_STATUS="success"
FINAL_REASON="upgrade completed and healthcheck passed"
write_report
log "Run completed successfully. Report written to $REPORT_FILE"
