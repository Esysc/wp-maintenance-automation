# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

## [0.0.1] - 2026-07-06

### Added
- Secure backup workflow with SSH + rsync + restic in scripts/backup_secure.sh.
- Guided restore workflow in scripts/restore_secure.sh.
- Upgrade orchestration with backup, full WordPress update, healthcheck, optional rollback, and reporting in scripts/upgrade_with_rollback.sh.
- Docker support with Dockerfile and entrypoint.sh for one-shot runs on NAS or Docker hosts.
- Environment template .env.example and safety-focused .gitignore defaults.
- Optional DNS export helper scripts for Cloudflare.
- Synology task scheduler example script.
- Repository documentation for backup, restore, scheduling, and release operations.

### Security
- Introduced encrypted backups via restic.
- Introduced optional backup locking and integrity-check controls.
- Introduced secret handling through environment variables and RESTIC_PASSWORD_FILE.

### Notes
- This is the first tagged release line for the automation workflow.
