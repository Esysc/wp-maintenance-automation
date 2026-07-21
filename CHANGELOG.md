# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog.

## [Unreleased]

### Added
- Task runner (`Taskfile.yml`) with `task build`, `task backup`, `task restore`, `task upgrade`, `task rehearse`, `task test`, `task test:visual`, and restic management commands.
- Visual test environment (`task test:visual SNAPSHOT=latest`) — restores a snapshot into a local Docker WordPress stack for manual inspection. Now runs HTTPS on `https://localhost:8443` and upgrades WordPress core, plugins, and themes to verify upgrade success.
- HTTPS support in visual test container: self-signed SSL certificate generated at build time, Apache SSL vhost on port 443 (mapped to 8443).
- WordPress upgrade step in `task test:visual` — runs `wp core/plugin/theme update` inside the restored environment, shows versions before/after.
- `wp-config-gen.sh` — regenerates `wp-config.php` for the test container preserving backup's DB credentials, salts, and table prefix (only `DB_HOST` is updated).
- Table prefix restoration from backup `wp-config.php` after visual test environment setup.
- Upgrade progress messages (`[1/4] ...`, `[2/4] ...`) in backup scripts for real-time feedback.
- SSH port support (`WP_SSH_PORT` in `.env`).
- Auto-detection of SSH key when `SSH_KEY` is not explicitly configured.
- `RESTIC_PASSWORD_FILE_FALLBACK` for Docker container runs.
- Auto-detection of WordPress version from backup artifacts (`Makefile` reads `wp-includes/version.php`).
- Auto-detection of WordPress upgrade target from the WordPress API (`api.wordpress.org/core/version-check/1.7/`).
- Auto-detection of PHP version from `../.env` (`WP_PHP_VERSION`).
- `WP_PHP_VERSION` build arg and env variable for test infrastructure.
- Test environment `test.env` with `WP_PHP_VERSION=8.2` default.
- Explicit MariaDB `10.11` image tag in Docker Compose to match remote production.
- CI/automation documentation in README with non-interactive usage examples (`ASK_CONFIRM_BEFORE_UPGRADE=no`) and TTY requirements.
- Clarify upgrade workflow: explains why a fresh backup is made (safety net) and how test tasks relate (optional pre-flight checks, not part of upgrade pipeline).
- `ConnectTimeout=15` added to all SSH options to prevent hangs on unreachable hosts.
- `stdbuf -oL` on piped command output to force line-buffered output through pipes for real-time progress display.

### Changed
- **Test infrastructure**: switched `Dockerfile.wp` from the official `wordpress:*-php8.1-apache` image to a generic `debian:bookworm-slim` base. Apache, PHP 8.2, and WordPress are now installed at exact, pinned versions via `apt` and WordPress tarball download. This removes the dependency on Docker Hub `wordpress:*` tags for any WP version.
- `wp-entrypoint.sh` rewritten to generate `wp-config.php` from `wp-config-sample.php` at startup (via `sed`), start `sshd`, then launch Apache in the foreground — no longer relies on the upstream WordPress docker-entrypoint.
- **All Docker tasks** (backup, restore, upgrade, rehearse) now use `docker run --rm -it` and mount the SSH key as a volume (copied into place inside the container) instead of piping via stdin — enables TTY for unbuffered output.
- All command output in `upgrade_with_rollback.sh` now streams through `tee -a` to show progress on terminal while still logging to file.
- `Makefile` version detection: renamed `DETECTED_WP_INITIAL_VERSION` → `DETECTED_WP_VERSION`.
- `rsync` timeout and progress flags added for more robust transfers.

### Fixed
- `read_db_config()` in `scripts/lib.sh`: sed extraction now handles optional whitespace before `);` in `define()` statements.
- Apache `envvars` sourcing no longer fails under `set -u` (bash unbound variable).
- WordPress `wp-config-sample.php` CRLF line endings stripped before `sed` replacement (caused `$` anchor to fail).
- `restic-repo` directory cleanup in test suite uses `rm -rf` instead of `rm -f`.
- Docker container now passes `RESTIC_PASSWORD_FILE` via `-e` flag consistently across all Taskfile commands.
- Restic repository mounted into Docker container for local-repo operations.
- Various `set -u` safety fixes for restic fallback variables, mysql exit code handling, and `wp-config.php` grep whitespace handling.
- Pipe buffering no longer hides script output: all step outputs stream to terminal in real-time instead of being silently redirected to log file.
- SSH key permission errors on macOS Docker Desktop resolved by mounting as `:ro` volume and copying with `chmod 600` inside the container.
- Default Apache `index.html` removed in visual test container to prevent overriding WordPress.
- Self-signed SSL certificate SAN limited to `localhost` and `127.0.0.1` (removed production domain names).
- SQL values in visual test DB creation are now escaped against injection.
- `sed` replacement values in `wp-entrypoint.sh` and `wp-config-gen.sh` are escaped to prevent breakage on special characters (`&`, `\`, `/`).

### Security
- PHP hang issue in `read_db_config()` resolved by removing interactive `php -v` check.
- Hardened shell scripts against unbound variable errors with `set -u` compatibility.

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
