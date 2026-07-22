#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

TEST_PASS=0
TEST_FAIL=0
TEST_SKIP=0
TEST_CLEANUP_DONE=false

cleanup_test() {
  if [[ "$TEST_CLEANUP_DONE" == "true" ]]; then
    return
  fi
  TEST_CLEANUP_DONE=true
  rm -f /tmp/restic-pass /tmp/backup_snapshot_id.txt /tmp/backup_output.log /tmp/restore_output.log /tmp/restore_apply.log /tmp/snapshots.log
  rm -rf /tmp/restic-repo /tmp/backup_artifacts /tmp/restore_output /tmp/id_rsa
}
trap cleanup_test EXIT

pass() {
  TEST_PASS=$((TEST_PASS + 1))
  echo "  PASS: $1"
}

fail() {
  TEST_FAIL=$((TEST_FAIL + 1))
  echo "  FAIL: $1"
}

skip() {
  TEST_SKIP=$((TEST_SKIP + 1))
  echo "  SKIP: $1"
}

check_regex() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    pass "$label"
  else
    echo "    expected pattern: $expected"
    echo "    got: $actual"
    fail "$label"
  fi
}

# ---- Setup ----

echo "=== Test Suite: backupWordPress ==="
echo ""

TEST_POST_TITLE="Test Post for Backup Verification"
TEST_POST_CONTENT="This is a test post used to verify backup and restore integrity."
TEST_PAGE_TITLE="Test Page for Backup Verification"
TEST_PAGE_CONTENT="This is a test page used to verify backup and restore integrity."

echo "--- Phase 0: Environment Setup ---"

mkdir -p /root/.ssh
cp /root/.ssh/id_rsa /tmp/id_rsa
chmod 600 /tmp/id_rsa

# SSH config so backup_secure.sh's internal SSH connections work without extra flags
cat > /root/.ssh/config << EOF
Host wp-site
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  IdentityFile /tmp/id_rsa
  LogLevel error
EOF
chmod 600 /root/.ssh/config

SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error -i /tmp/id_rsa root@wp-site"

if echo "test" | $SSH_CMD "echo test" 2> /dev/null; then
  pass "SSH connectivity to wp-site"
else
  fail "SSH connectivity to wp-site"
  echo "FATAL: Cannot reach wp-site via SSH"
  exit 1
fi

echo "test" > /tmp/restic-pass

restic init --repo /tmp/restic-repo --password-file /tmp/restic-pass > /dev/null 2>&1 &&
  pass "restic repository initialized" ||
  fail "restic repository initialization"

$SSH_CMD "wp core is-installed 2>/dev/null" && WP_INSTALLED=true || WP_INSTALLED=false
if [[ "$WP_INSTALLED" != "true" ]]; then
  echo "  Installing WordPress..."
  $SSH_CMD "wp core install \
    --url='http://wp-site' \
    --title='Test Site' \
    --admin_user='admin' \
    --admin_password='admin' \
    --admin_email='admin@example.com' \
    --skip-email" > /dev/null 2>&1 && pass "WordPress installed" || fail "WordPress installation"
else
  pass "WordPress already installed"
fi

WP_VERSION_INITIAL=$($SSH_CMD "wp core version")
echo "  Initial WP version: $WP_VERSION_INITIAL"

TEST_POST_ID=$($SSH_CMD "wp post create \
  --post_type=post \
  --post_title='$TEST_POST_TITLE' \
  --post_content='$TEST_POST_CONTENT' \
  --post_status=publish \
  --porcelain" 2> /dev/null || true)
if [[ "$TEST_POST_ID" =~ ^[0-9]+$ ]]; then
  pass "Test post created"
else
  fail "Test post creation"
fi

TEST_PAGE_ID=$($SSH_CMD "wp post create \
  --post_type=page \
  --post_title='$TEST_PAGE_TITLE' \
  --post_content='$TEST_PAGE_CONTENT' \
  --post_status=publish \
  --porcelain" 2> /dev/null || true)
if [[ "$TEST_PAGE_ID" =~ ^[0-9]+$ ]]; then
  pass "Test page created"
else
  fail "Test page creation"
fi

echo "  Test post ID: $TEST_POST_ID"
echo "  Test page ID: $TEST_PAGE_ID"

$SSH_CMD "wp plugin install classic-editor --version=1.6.3 --activate" > /dev/null 2>&1 &&
  pass "Plugin 'Classic Editor' 1.6.3 installed" ||
  skip "Plugin 'Classic Editor' install (may already be present)"

$SSH_CMD "wp theme install twentytwentyfour --activate" > /dev/null 2>&1 &&
  pass "Theme 'Twenty Twenty-Four' installed" ||
  skip "Theme 'Twenty Twenty-Four' install (may already be present)"

echo ""

# ---- Phase 1: Backup ----
echo "--- Phase 1: Backup at version $WP_VERSION_INITIAL ---"

cd /app

export WP_SSH_HOST=wp-site
export WP_SSH_USER=root
export WP_ROOT=/var/www/html
export RESTIC_REPOSITORY=/tmp/restic-repo
export RESTIC_PASSWORD_FILE=/tmp/restic-pass
export BACKUP_DIR=/tmp/backup_artifacts
export RSYNC_EXCLUDES=
export RETENTION_FLAGS="--keep-daily 1"
export BACKUP_SNAPSHOT_FILE=/tmp/backup_snapshot_id.txt

bash /app/scripts/backup_secure.sh > /tmp/backup_output.log 2>&1 &&
  pass "backup_secure.sh completed successfully" ||
  {
    echo "    --- backup output ---"
    cat /tmp/backup_output.log
    echo "    --- end ---"
    fail "backup_secure.sh failed (see /tmp/backup_output.log)"
  }

if [[ -f /tmp/backup_snapshot_id.txt ]]; then
  SNAPSHOT_ID=$(cat /tmp/backup_snapshot_id.txt)
  echo "  Snapshot ID: $SNAPSHOT_ID"
  pass "Backup snapshot ID captured"
else
  SNAPSHOT_ID="latest"
  echo "  No snapshot ID file, using 'latest'"
  fail "Backup snapshot ID file missing"
fi

restic --repo /tmp/restic-repo --password-file /tmp/restic-pass snapshots > /tmp/snapshots.log 2>&1
check_regex "Restic snapshot exists" "$SNAPSHOT_ID" "$(cat /tmp/snapshots.log)"

echo ""

# ---- Phase 2: Upgrade ----
echo "--- Phase 2: Upgrade WordPress ---"

TARGET_WP_VERSION="${WP_UPGRADE_VERSION:-latest}"

echo "  Upgrading core to ${TARGET_WP_VERSION}..."
$SSH_CMD "wp core update --version=${TARGET_WP_VERSION}" > /dev/null 2>&1 &&
  pass "WordPress core upgraded" ||
  fail "WordPress core upgrade"

$SSH_CMD "wp plugin update --all" > /dev/null 2>&1 &&
  pass "Plugins updated" ||
  fail "Plugin update"

$SSH_CMD "wp theme update --all" > /dev/null 2>&1 &&
  pass "Themes updated" ||
  fail "Theme update"

$SSH_CMD "wp core update-db" > /dev/null 2>&1 &&
  pass "Database updated" ||
  fail "Database update"

WP_VERSION_AFTER_UPGRADE=$($SSH_CMD "wp core version")
echo "  WP version after upgrade: $WP_VERSION_AFTER_UPGRADE"

if [[ "$TARGET_WP_VERSION" == "latest" ]]; then
  if [[ "$WP_VERSION_AFTER_UPGRADE" != "$WP_VERSION_INITIAL" ]]; then
    pass "WordPress version changed (upgrade occurred)"
  else
    fail "WordPress version unchanged after upgrade"
  fi
else
  if [[ "$WP_VERSION_AFTER_UPGRADE" == "$TARGET_WP_VERSION" ]]; then
    pass "WordPress version matches requested target ($TARGET_WP_VERSION)"
  else
    fail "WordPress version mismatch: expected $TARGET_WP_VERSION, got $WP_VERSION_AFTER_UPGRADE"
  fi
fi

# ---- Phase 3: Verify after upgrade ----
echo ""
echo "--- Phase 3: Post-Upgrade Verification ---"

POST_EXISTS_AFTER_UPGRADE=$($SSH_CMD "wp post get '$TEST_POST_ID' --field=ID 2>/dev/null" || echo "")
if [[ "$POST_EXISTS_AFTER_UPGRADE" == "$TEST_POST_ID" ]]; then
  pass "Test post ID preserved after upgrade"
else
  fail "Test post missing after upgrade"
fi

PAGE_EXISTS_AFTER_UPGRADE=$($SSH_CMD "wp post get '$TEST_PAGE_ID' --field=ID 2>/dev/null" || echo "")
if [[ "$PAGE_EXISTS_AFTER_UPGRADE" == "$TEST_PAGE_ID" ]]; then
  pass "Test page ID preserved after upgrade"
else
  fail "Test page missing after upgrade"
fi

POST_TITLE_AFTER=$($SSH_CMD "wp post get '$TEST_POST_ID' --field=post_title 2>/dev/null" || echo "")
if [[ "$POST_TITLE_AFTER" == "$TEST_POST_TITLE" ]]; then
  pass "Test post title preserved after upgrade"
else
  fail "Test post title changed after upgrade"
fi

POST_CONTENT_AFTER=$($SSH_CMD "wp post get '$TEST_POST_ID' --field=post_content 2>/dev/null" || echo "")
if [[ "$POST_CONTENT_AFTER" == "$TEST_POST_CONTENT" ]]; then
  pass "Test post content preserved after upgrade"
else
  fail "Test post content changed after upgrade"
fi

PAGE_TITLE_AFTER=$($SSH_CMD "wp post get '$TEST_PAGE_ID' --field=post_title 2>/dev/null" || echo "")
if [[ "$PAGE_TITLE_AFTER" == "$TEST_PAGE_TITLE" ]]; then
  pass "Test page title preserved after upgrade"
else
  fail "Test page title changed after upgrade"
fi

PAGE_CONTENT_AFTER=$($SSH_CMD "wp post get '$TEST_PAGE_ID' --field=post_content 2>/dev/null" || echo "")
if [[ "$PAGE_CONTENT_AFTER" == "$TEST_PAGE_CONTENT" ]]; then
  pass "Test page content preserved after upgrade"
else
  fail "Test page content changed after upgrade"
fi

echo ""

# ---- Phase 4: Restore ----
echo "--- Phase 4: Restore from Backup ---"

echo "  Running restore_secure.sh (local extract)..."
export RESTORE_DIR=/tmp/restore_output
rm -rf "$RESTORE_DIR"

bash /app/scripts/restore_secure.sh "$SNAPSHOT_ID" > /tmp/restore_output.log 2>&1 &&
  pass "restore_secure.sh local extract completed" ||
  fail "restore_secure.sh local extract failed (see /tmp/restore_output.log)"

export APPLY_DB=yes
export APPLY_FILES=yes
export APPLY_CONFIGS=no
export DELETE_REMOTE_FILES=yes
export CONFIRM_RESTORE=yes

echo "  Running restore_secure.sh (remote apply)..."
bash /app/scripts/restore_secure.sh "$SNAPSHOT_ID" > /tmp/restore_apply.log 2>&1 &&
  pass "restore_secure.sh remote apply completed" ||
  fail "restore_secure.sh remote apply failed (see /tmp/restore_apply.log)"

echo ""

# ---- Phase 5: Post-Restore Verification ----
echo "--- Phase 5: Post-Restore Verification ---"

WP_VERSION_AFTER_RESTORE=$($SSH_CMD "wp core version 2>/dev/null" || echo "unknown")
echo "  WP version after restore: $WP_VERSION_AFTER_RESTORE"

if [[ "$WP_VERSION_AFTER_RESTORE" == "$WP_VERSION_INITIAL" ]]; then
  pass "WordPress version restored to $WP_VERSION_INITIAL"
else
  fail "WordPress version mismatch: expected $WP_VERSION_INITIAL, got $WP_VERSION_AFTER_RESTORE"
fi

POST_EXISTS_AFTER_RESTORE=$($SSH_CMD "wp post get '$TEST_POST_ID' --field=ID 2>/dev/null" || echo "")
if [[ "$POST_EXISTS_AFTER_RESTORE" == "$TEST_POST_ID" ]]; then
  pass "Test post ID preserved after restore"
else
  fail "Test post missing after restore"
fi

PAGE_EXISTS_AFTER_RESTORE=$($SSH_CMD "wp post get '$TEST_PAGE_ID' --field=ID 2>/dev/null" || echo "")
if [[ "$PAGE_EXISTS_AFTER_RESTORE" == "$TEST_PAGE_ID" ]]; then
  pass "Test page ID preserved after restore"
else
  fail "Test page missing after restore"
fi

POST_TITLE_RESTORED=$($SSH_CMD "wp post get '$TEST_POST_ID' --field=post_title 2>/dev/null" || echo "")
if [[ "$POST_TITLE_RESTORED" == "$TEST_POST_TITLE" ]]; then
  pass "Test post title preserved after restore"
else
  fail "Test post title changed after restore"
fi

POST_CONTENT_RESTORED=$($SSH_CMD "wp post get '$TEST_POST_ID' --field=post_content 2>/dev/null" || echo "")
if [[ "$POST_CONTENT_RESTORED" == "$TEST_POST_CONTENT" ]]; then
  pass "Test post content preserved after restore"
else
  fail "Test post content changed after restore"
fi

PAGE_TITLE_RESTORED=$($SSH_CMD "wp post get '$TEST_PAGE_ID' --field=post_title 2>/dev/null" || echo "")
if [[ "$PAGE_TITLE_RESTORED" == "$TEST_PAGE_TITLE" ]]; then
  pass "Test page title preserved after restore"
else
  fail "Test page title changed after restore"
fi

PAGE_CONTENT_RESTORED=$($SSH_CMD "wp post get '$TEST_PAGE_ID' --field=post_content 2>/dev/null" || echo "")
if [[ "$PAGE_CONTENT_RESTORED" == "$TEST_PAGE_CONTENT" ]]; then
  pass "Test page content preserved after restore"
else
  fail "Test page content changed after restore"
fi

echo ""

# ---- Summary ----
echo "=== Test Summary ==="
echo "  Passed: $TEST_PASS"
echo "  Failed: $TEST_FAIL"
echo "  Skipped: $TEST_SKIP"
echo ""

if [[ "$TEST_FAIL" -gt 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
fi

echo "ALL TESTS PASSED"
exit 0
