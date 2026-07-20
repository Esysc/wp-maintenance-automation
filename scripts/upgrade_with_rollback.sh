#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Orchestrates: backup -> full WordPress upgrade -> health checks -> optional rollback.
# Always generates a report and a detailed log file.

if [[ -f ".env" ]]; then
  set -a
  source ".env"
  set +a
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup_secure.sh"
RESTORE_SCRIPT="$SCRIPT_DIR/restore_secure.sh"
STAGING_REHEARSAL_SCRIPT="$SCRIPT_DIR/staging_rehearsal.sh"

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
VALIDATE_BACKUP_BEFORE_UPGRADE=${VALIDATE_BACKUP_BEFORE_UPGRADE:-yes}
RUN_STAGING_REHEARSAL_BEFORE_UPGRADE=${RUN_STAGING_REHEARSAL_BEFORE_UPGRADE:-no}
ASK_CONFIRM_BEFORE_UPGRADE=${ASK_CONFIRM_BEFORE_UPGRADE:-yes}
FORCE_UPGRADE=${FORCE_UPGRADE:-no}
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
    echo "- Backup validation: $BACKUP_VALIDATION_STATUS"
    echo "- Staging rehearsal: $STAGING_REHEARSAL_STATUS"
    echo "- Upgrade approval: $UPGRADE_APPROVAL_STATUS"
    echo "- Upgrade: $UPGRADE_STATUS"
    echo "- Healthcheck: $HEALTH_STATUS"
    echo "- Rollback: $ROLLBACK_STATUS"
    echo ""
    echo "Final result: $FINAL_STATUS"
    echo "Reason: ${FINAL_REASON:-none}"
    echo "Log file: $LOG_FILE"
  } > "$REPORT_FILE"
}

ssh_opts_for_host() {
  local port_var="${1:-WP_SSH_PORT}"
  local opts=()
  if [[ -n "${!port_var:-}" ]]; then
    opts+=(-p "${!port_var}")
  fi
  echo "${opts[@]}"
}

remote_wp() {
  local wp_args="$1"
  # shellcheck disable=SC2046
  ssh $(ssh_opts_for_host WP_SSH_PORT) "$WP_SSH_USER@$WP_SSH_HOST" "cd '$WP_ROOT' && $WP_CLI_BIN $WP_CLI_EXTRA_ARGS $wp_args"
}

derive_healthcheck_url() {
  if [[ -n "$HEALTHCHECK_URL" ]]; then
    return 0
  fi

  local detected
  # shellcheck disable=SC2046
  detected=$(ssh $(ssh_opts_for_host WP_SSH_PORT) "$WP_SSH_USER@$WP_SSH_HOST" "cd '$WP_ROOT' && $WP_CLI_BIN $WP_CLI_EXTRA_ARGS option get home 2>/dev/null" || true)
  if [[ -n "$detected" ]]; then
    HEALTHCHECK_URL="$detected"
  fi
}

run_backup() {
  local snapshot_file
  snapshot_file="$RUN_DIR/backup_snapshot_id.txt"

  log "Starting backup..."
  if BACKUP_SNAPSHOT_FILE="$snapshot_file" bash "$BACKUP_SCRIPT" >> "$LOG_FILE" 2>&1; then
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

run_backup_validation() {
  if [[ "$VALIDATE_BACKUP_BEFORE_UPGRADE" != "yes" ]]; then
    BACKUP_VALIDATION_STATUS="skipped"
    log "Backup validation skipped by VALIDATE_BACKUP_BEFORE_UPGRADE=$VALIDATE_BACKUP_BEFORE_UPGRADE"
    return 0
  fi

  local validation_dir restore_root latest_sub artifact_root db_dir wp_dir dump
  validation_dir="$RUN_DIR/backup_validation"

  log "Validating backup snapshot ${BACKUP_SNAPSHOT_ID:-latest} via local restore extract..."
  if ! RESTORE_DIR="$validation_dir" \
    APPLY_DB=no \
    APPLY_FILES=no \
    APPLY_CONFIGS=no \
    CONFIRM_RESTORE=no \
    bash "$RESTORE_SCRIPT" "${BACKUP_SNAPSHOT_ID:-latest}" >> "$LOG_FILE" 2>&1; then
    BACKUP_VALIDATION_STATUS="failed"
    FINAL_REASON="backup validation restore extract failed"
    return 1
  fi

  restore_root=$(ls -1t "$validation_dir" 2> /dev/null | head -n1 || true)
  if [[ -z "$restore_root" ]]; then
    BACKUP_VALIDATION_STATUS="failed"
    FINAL_REASON="backup validation could not locate restored artifacts"
    return 1
  fi

  artifact_root="$validation_dir/$restore_root"
  if [[ -d "$artifact_root/backup_artifacts" ]]; then
    latest_sub=$(ls -1t "$artifact_root/backup_artifacts" 2> /dev/null | head -n1 || true)
    if [[ -n "$latest_sub" && -d "$artifact_root/backup_artifacts/$latest_sub" ]]; then
      artifact_root="$artifact_root/backup_artifacts/$latest_sub"
    else
      artifact_root="$artifact_root/backup_artifacts"
    fi
  fi

  db_dir="$artifact_root/db"
  wp_dir="$artifact_root/wp"

  if [[ ! -d "$db_dir" || ! -d "$wp_dir" ]]; then
    BACKUP_VALIDATION_STATUS="failed"
    FINAL_REASON="backup validation missing db or wp artifact directories"
    return 1
  fi

  dump=$(ls -1 "$db_dir"/*.gz 2> /dev/null | sort | tail -n1 || true)
  if [[ -z "$dump" ]]; then
    BACKUP_VALIDATION_STATUS="failed"
    FINAL_REASON="backup validation missing database dump"
    return 1
  fi

  if ! gzip -t "$dump" > /dev/null 2>&1; then
    BACKUP_VALIDATION_STATUS="failed"
    FINAL_REASON="backup validation database dump integrity check failed"
    return 1
  fi

  if [[ ! -f "$wp_dir/wp-config.php" ]]; then
    BACKUP_VALIDATION_STATUS="failed"
    FINAL_REASON="backup validation missing wp-config.php in restored files"
    return 1
  fi

  BACKUP_VALIDATION_STATUS="ok"
  log "Backup validation succeeded."
  return 0
}

run_staging_rehearsal() {
  local missing=()

  if [[ "$RUN_STAGING_REHEARSAL_BEFORE_UPGRADE" != "yes" ]]; then
    STAGING_REHEARSAL_STATUS="skipped"
    log "Staging rehearsal skipped by RUN_STAGING_REHEARSAL_BEFORE_UPGRADE=$RUN_STAGING_REHEARSAL_BEFORE_UPGRADE"
    return 0
  fi

  for v in STAGING_WP_SSH_HOST STAGING_WP_SSH_USER STAGING_WP_ROOT; do
    if [[ -z "${!v:-}" ]]; then
      missing+=("$v")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    STAGING_REHEARSAL_STATUS="failed"
    FINAL_REASON="staging rehearsal required but missing vars: ${missing[*]}"
    log "Staging rehearsal blocked: missing required variables: ${missing[*]}"
    return 1
  fi

  log "Running staging rehearsal from snapshot ${BACKUP_SNAPSHOT_ID:-latest}..."
  if bash "$STAGING_REHEARSAL_SCRIPT" "${BACKUP_SNAPSHOT_ID:-latest}" >> "$LOG_FILE" 2>&1; then
    STAGING_REHEARSAL_STATUS="ok"
    return 0
  fi

  STAGING_REHEARSAL_STATUS="failed"
  FINAL_REASON="staging rehearsal failed"
  return 1
}

run_upgrade_approval() {
  local reply

  if [[ "$FORCE_UPGRADE" == "yes" ]]; then
    UPGRADE_APPROVAL_STATUS="forced"
    log "Upgrade approval overridden by FORCE_UPGRADE=yes"
    return 0
  fi

  if [[ "$ASK_CONFIRM_BEFORE_UPGRADE" != "yes" ]]; then
    UPGRADE_APPROVAL_STATUS="not-required"
    log "Upgrade confirmation skipped by ASK_CONFIRM_BEFORE_UPGRADE=$ASK_CONFIRM_BEFORE_UPGRADE"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    UPGRADE_APPROVAL_STATUS="failed"
    FINAL_REASON="upgrade confirmation required in non-interactive mode; set FORCE_UPGRADE=yes"
    log "Cannot prompt for confirmation: non-interactive shell detected."
    return 1
  fi

  echo ""
  echo "Backup and validation completed for snapshot: ${BACKUP_SNAPSHOT_ID:-latest}"
  read -r -p "Proceed with full production upgrade now? [y/N]: " reply
  case "$reply" in
    y | Y | yes | YES)
      UPGRADE_APPROVAL_STATUS="approved"
      log "Upgrade approved interactively by operator."
      return 0
      ;;
    *)
      UPGRADE_APPROVAL_STATUS="declined"
      FINAL_STATUS="cancelled"
      FINAL_REASON="upgrade declined by operator"
      log "Upgrade declined by operator."
      return 2
      ;;
  esac
}

run_upgrade() {
  log "Starting WordPress full upgrade with WP-CLI..."

  if ! remote_wp "core update" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="core update failed"
    return 1
  fi

  if ! remote_wp "plugin update --all" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="plugin update failed"
    return 1
  fi

  if ! remote_wp "theme update --all" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="theme update failed"
    return 1
  fi

  # Keep language packs aligned with updated core/plugins/themes.
  if ! remote_wp "language core update" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="language core update failed"
    return 1
  fi

  if ! remote_wp "language plugin update --all" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="language plugin update failed"
    return 1
  fi

  if ! remote_wp "language theme update --all" >> "$LOG_FILE" 2>&1; then
    UPGRADE_STATUS="failed"
    FINAL_REASON="language theme update failed"
    return 1
  fi

  if ! remote_wp "core update-db" >> "$LOG_FILE" 2>&1; then
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
        # shellcheck disable=SC2046
        if ! ssh $(ssh_opts_for_host WP_SSH_PORT) "$WP_SSH_USER@$WP_SSH_HOST" "cd '$WP_ROOT' && $EXTRA_POST_UPGRADE_CHECK_CMD" >> "$LOG_FILE" 2>&1; then
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
    bash "$RESTORE_SCRIPT" "${BACKUP_SNAPSHOT_ID:-latest}" >> "$LOG_FILE" 2>&1; then
    ROLLBACK_STATUS="ok"
    return 0
  fi

  ROLLBACK_STATUS="failed"
  FINAL_REASON="rollback failed"
  return 1
}

BACKUP_STATUS="not-run"
BACKUP_VALIDATION_STATUS="not-run"
STAGING_REHEARSAL_STATUS="not-run"
UPGRADE_APPROVAL_STATUS="not-run"
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

if ! run_backup_validation; then
  write_report
  log "Report written to $REPORT_FILE"
  exit 1
fi

if ! run_staging_rehearsal; then
  write_report
  log "Report written to $REPORT_FILE"
  exit 1
fi

set +e
run_upgrade_approval
approval_rc=$?
set -e
if [[ "$approval_rc" -eq 1 ]]; then
  write_report
  log "Report written to $REPORT_FILE"
  exit 1
fi
if [[ "$approval_rc" -eq 2 ]]; then
  write_report
  log "Report written to $REPORT_FILE"
  exit 0
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
