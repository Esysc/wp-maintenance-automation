#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Rehearse production upgrade safely on a staging clone restored from backup.
# Flow: restore snapshot to staging -> upgrade staging -> healthcheck staging -> report.

if [[ -f ".env" ]]; then
  set -a
  source ".env"
  set +a
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

RESTORE_SCRIPT="$SCRIPT_DIR/restore_secure.sh"

require_var RESTIC_REPOSITORY
require_var RESTIC_PASSWORD_FILE
require_var STAGING_WP_SSH_HOST
require_var STAGING_WP_SSH_USER
require_var STAGING_WP_ROOT

SNAPSHOT="${1:-latest}"

STAGING_WP_CLI_BIN=${STAGING_WP_CLI_BIN:-wp}
STAGING_WP_CLI_EXTRA_ARGS=${STAGING_WP_CLI_EXTRA_ARGS:-}
STAGING_HEALTHCHECK_URL=${STAGING_HEALTHCHECK_URL:-}
STAGING_HEALTHCHECK_EXPECT_CODE=${STAGING_HEALTHCHECK_EXPECT_CODE:-200}
STAGING_HEALTHCHECK_RETRIES=${STAGING_HEALTHCHECK_RETRIES:-5}
STAGING_HEALTHCHECK_DELAY_SECONDS=${STAGING_HEALTHCHECK_DELAY_SECONDS:-15}
STAGING_HEALTHCHECK_TIMEOUT_SECONDS=${STAGING_HEALTHCHECK_TIMEOUT_SECONDS:-20}
STAGING_EXTRA_POST_UPGRADE_CHECK_CMD=${STAGING_EXTRA_POST_UPGRADE_CHECK_CMD:-}

STAGING_APPLY_CONFIGS=${STAGING_APPLY_CONFIGS:-no}
STAGING_DELETE_REMOTE_FILES=${STAGING_DELETE_REMOTE_FILES:-no}
STAGING_REMOTE_SUDO=${STAGING_REMOTE_SUDO:-no}

REPORT_DIR=${STAGING_REHEARSAL_REPORT_DIR:-./var/reports/wp_staging_rehearsal}
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
    echo "WordPress Staging Rehearsal Report"
    echo "Timestamp: $TS"
    echo "Snapshot: $SNAPSHOT"
    echo "Staging host: $STAGING_WP_SSH_HOST"
    echo "Staging path: $STAGING_WP_ROOT"
    echo "Healthcheck URL: ${STAGING_HEALTHCHECK_URL:-auto-detected}"
    echo ""
    echo "Step status"
    echo "- Restore to staging: $RESTORE_STATUS"
    echo "- Upgrade on staging: $UPGRADE_STATUS"
    echo "- Healthcheck on staging: $HEALTH_STATUS"
    echo ""
    echo "Final result: $FINAL_STATUS"
    echo "Reason: ${FINAL_REASON:-none}"
    echo "Log file: $LOG_FILE"
  } > "$REPORT_FILE"
}

staging_wp() {
  local wp_args="$1"
  ssh "$STAGING_WP_SSH_USER@$STAGING_WP_SSH_HOST" "cd '$STAGING_WP_ROOT' && $STAGING_WP_CLI_BIN $STAGING_WP_CLI_EXTRA_ARGS $wp_args"
}

derive_staging_healthcheck_url() {
  if [[ -n "$STAGING_HEALTHCHECK_URL" ]]; then
    return 0
  fi

  local detected
  detected=$(ssh "$STAGING_WP_SSH_USER@$STAGING_WP_SSH_HOST" "cd '$STAGING_WP_ROOT' && $STAGING_WP_CLI_BIN $STAGING_WP_CLI_EXTRA_ARGS option get home 2>/dev/null" || true)
  if [[ -n "$detected" ]]; then
    STAGING_HEALTHCHECK_URL="$detected"
  fi
}

run_restore_to_staging() {
  log "Restoring snapshot '$SNAPSHOT' to staging..."
  if WP_SSH_HOST="$STAGING_WP_SSH_HOST" \
    WP_SSH_USER="$STAGING_WP_SSH_USER" \
    WP_ROOT="$STAGING_WP_ROOT" \
    CONFIRM_RESTORE=yes \
    APPLY_DB=yes \
    APPLY_FILES=yes \
    APPLY_CONFIGS="$STAGING_APPLY_CONFIGS" \
    DELETE_REMOTE_FILES="$STAGING_DELETE_REMOTE_FILES" \
    REMOTE_SUDO="$STAGING_REMOTE_SUDO" \
    bash "$RESTORE_SCRIPT" "$SNAPSHOT" >> "$LOG_FILE" 2>&1; then
    RESTORE_STATUS="ok"
    return 0
  fi

  RESTORE_STATUS="failed"
  FINAL_REASON="staging restore failed"
  return 1
}

run_upgrade_on_staging() {
  log "Running full WordPress upgrade on staging..."

  if ! staging_wp "core update" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="staging core update failed"
    return 1
  fi

  if ! staging_wp "plugin update --all" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="staging plugin update failed"
    return 1
  fi

  if ! staging_wp "theme update --all" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="staging theme update failed"
    return 1
  fi

  if ! staging_wp "language core update" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="staging language core update failed"
    return 1
  fi

  if ! staging_wp "language plugin update --all" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="staging language plugin update failed"
    return 1
  fi

  if ! staging_wp "language theme update --all" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="staging language theme update failed"
    return 1
  fi

  if ! staging_wp "core update-db" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="staging core update-db failed"
    return 1
  fi

  UPGRADE_STATUS="ok"
  return 0
}

run_staging_healthcheck() {
  derive_staging_healthcheck_url

  if [[ -z "$STAGING_HEALTHCHECK_URL" ]]; then
    HEALTH_STATUS="failed"
    FINAL_REASON="staging healthcheck URL missing"
    return 1
  fi

  log "Running staging healthcheck on $STAGING_HEALTHCHECK_URL"

  local attempt code
  attempt=1
  while [[ "$attempt" -le "$STAGING_HEALTHCHECK_RETRIES" ]]; do
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time "$STAGING_HEALTHCHECK_TIMEOUT_SECONDS" "$STAGING_HEALTHCHECK_URL" || true)
    if [[ "$code" == "$STAGING_HEALTHCHECK_EXPECT_CODE" ]]; then
      log "Staging healthcheck passed with status $code on attempt $attempt"
      if [[ -n "$STAGING_EXTRA_POST_UPGRADE_CHECK_CMD" ]]; then
        log "Running extra staging post-upgrade check command"
        if ! ssh "$STAGING_WP_SSH_USER@$STAGING_WP_SSH_HOST" "cd '$STAGING_WP_ROOT' && $STAGING_EXTRA_POST_UPGRADE_CHECK_CMD" >> "$LOG_FILE" 2>&1; then
          HEALTH_STATUS="failed"
          FINAL_REASON="extra staging post-upgrade check failed"
          return 1
        fi
      fi
      HEALTH_STATUS="ok"
      return 0
    fi

    log "Staging healthcheck attempt $attempt/$STAGING_HEALTHCHECK_RETRIES failed (status=$code)."
    attempt=$((attempt + 1))
    if [[ "$attempt" -le "$STAGING_HEALTHCHECK_RETRIES" ]]; then
      sleep "$STAGING_HEALTHCHECK_DELAY_SECONDS"
    fi
  done

  HEALTH_STATUS="failed"
  FINAL_REASON="staging healthcheck failed after $STAGING_HEALTHCHECK_RETRIES attempts"
  return 1
}

RESTORE_STATUS="not-run"
UPGRADE_STATUS="not-run"
HEALTH_STATUS="not-run"
FINAL_STATUS="failed"
FINAL_REASON="unexpected"

if ! run_restore_to_staging; then
  write_report
  log "Report written to $REPORT_FILE"
  exit 1
fi

if ! run_upgrade_on_staging; then
  write_report
  log "Report written to $REPORT_FILE"
  exit 1
fi

if ! run_staging_healthcheck; then
  write_report
  log "Report written to $REPORT_FILE"
  exit 1
fi

FINAL_STATUS="success"
FINAL_REASON="staging rehearsal completed successfully"
write_report
log "Staging rehearsal completed successfully. Report written to $REPORT_FILE"
