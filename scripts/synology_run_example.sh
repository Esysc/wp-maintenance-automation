#!/usr/bin/env bash
set -euo pipefail

# Example one-shot backup run for Synology Task Scheduler.
# Replace the paths and image tag with your own.

IMAGE="yourrepo/wp-backup:latest"

# Host paths on the NAS
SSH_DIR="/volume1/homes/youruser/.ssh"
ENV_FILE="/volume1/wp-backup/.env"
RESTIC_PASS_FILE="/volume1/wp-backup/restic_pass"
ARTIFACTS_DIR="/volume1/wp-backup/artifacts"
RESTIC_REPO_DIR="/volume1/wp-backup/restic_repo"  # optional if using local repo

# Ensure required dirs/files exist
mkdir -p "$ARTIFACTS_DIR"

docker run --rm \
  -v "$SSH_DIR:/root/.ssh:ro" \
  -v "$ENV_FILE:/app/.env:ro" \
  -v "$RESTIC_PASS_FILE:/app/restic_pass:ro" \
  -e RESTIC_PASSWORD_FILE=/app/restic_pass \
  -v "$ARTIFACTS_DIR:/app/backup_artifacts" \
  -v "$RESTIC_REPO_DIR:/restic_repo" \
  "$IMAGE"
