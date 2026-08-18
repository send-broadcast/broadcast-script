#!/bin/bash

# Unit tests for the real upgrade/downgrade continuation logic in
# scripts/upgrade.sh and scripts/downgrade.sh: the _upgrade_continue /
# _downgrade_continue functions that run after the re-exec, plus downgrade's
# input validation. External commands are shimmed and logged by the sandbox
# harness; file operations (service unit installs, .env edits, .image
# writes, version history) are real.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "2.0.0" > "$SANDBOX_ROOT/.current_version"
    touch "$SANDBOX_ROOT/app/.env"

    # crontab: -l prints the stored crontab, - installs from stdin (buffered
    # through a temp file to avoid racing the -l in the same pipeline)
    harness_mock crontab 'case "${1:-}" in
  -l) cat "$BROADCAST_ROOT/crontab.txt" 2>/dev/null || exit 1 ;;
  -) cat > "$BROADCAST_ROOT/crontab.txt.tmp" && mv "$BROADCAST_ROOT/crontab.txt.tmp" "$BROADCAST_ROOT/crontab.txt" ;;
esac
exit 0'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

# --- downgrade input validation ------------------------------------------

test_downgrade_requires_a_version() {
    local rc=0
    sandbox_run 'downgrade ""' >/dev/null || rc=$?
    assert_not_equals "0" "$rc" "downgrade without a version must fail"
    harness_assert_not_called "systemctl" "services must not be touched on a rejected downgrade"
}

test_downgrade_rejects_invalid_version_format() {
    local rc=0 output
    output=$(sandbox_run 'downgrade "v1.2.3"') || rc=$?
    assert_not_equals "0" "$rc" "downgrade with a non-semver version must fail"
    assert_contains "$output" "Invalid version format" "the rejection should be explained"
    harness_assert_not_called "systemctl" "services must not be touched on a rejected downgrade"
}

# The script update (git pull) must run BEFORE the stop: a git failure —
# dirty tree from a hand-edited compose file (the 2026-08-04 firstborngroup
# incident), unreachable GitHub — must never take the site down.
test_downgrade_updates_before_stopping() {
    harness_stub_broadcast_sh
    local rc=0
    sandbox_run "downgrade 1.5.0" >/dev/null || rc=$?
    assert_equals "0" "$rc" "a valid downgrade should proceed"

    harness_assert_call_order \
        "broadcast.sh update" \
        "systemctl stop broadcast" \
        "broadcast.sh _downgrade_continue 1.5.0"
}

# --- _upgrade_continue ----------------------------------------------------

test_upgrade_continue_full_sequence_with_version() {
    local rc=0
    sandbox_run "_upgrade_continue 2.5.0" >/dev/null || rc=$?
    assert_equals "0" "$rc" "_upgrade_continue should succeed"

    # Image and version state written for the requested version
    assert_contains "$(cat "$SANDBOX_ROOT/.image")" ":2.5.0" ".image should pin the requested tag"
    assert_equals "2.5.0" "$(cat "$SANDBOX_ROOT/.current_version")" \
        ".current_version should track the new version"

    # Pull as the broadcast user, then service start, then deferred cleanup
    harness_assert_call_order \
        "su - broadcast" \
        "systemctl start broadcast" \
        "systemctl start broadcast-post-upgrade-cleanup.service --no-block"

    # Audit trail records the transition
    assert_contains "$(cat "$SANDBOX_ROOT/.version_history")" "upgrade | 2.0.0 | 2.5.0" \
        "version history should record from/to versions"
}

test_upgrade_continue_defaults_to_latest() {
    sandbox_run "_upgrade_continue" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.image")" ":latest" "no version should mean :latest"
    assert_contains "$(cat "$SANDBOX_ROOT/.version_history")" "upgrade | 2.0.0 | latest" \
        "history should record the latest upgrade"
}

test_upgrade_continue_installs_cleanup_service_when_missing() {
    local output
    output=$(sandbox_run "_upgrade_continue 2.5.0")

    assert_contains "$output" "Installing post-upgrade Docker image cleanup service" \
        "a missing cleanup service should be installed"
    assert_file_exists "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service" \
        "the unit file should be copied into systemd"
    harness_assert_called "systemctl daemon-reload" "systemd must reload after the unit install"
}

test_upgrade_continue_skips_cleanup_service_when_present() {
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service"

    local output
    output=$(sandbox_run "_upgrade_continue 2.5.0")

    if [[ "$output" == *"Installing post-upgrade Docker image cleanup service"* ]]; then
        assert_equals "skip install" "reinstalled" \
            "an existing cleanup service must not be reinstalled"
    fi
}

test_upgrade_continue_installs_logs_watcher_when_not_enabled() {
    local output
    output=$(sandbox_run "_upgrade_continue 2.5.0" 'export SYSTEMCTL_IS_ENABLED_RC=1')

    assert_contains "$output" "Installing log streaming trigger watcher" \
        "a disabled watcher should be installed"
    assert_file_exists "$SANDBOX_ROOT/etc/systemd/system/broadcast-logs-watcher.service" \
        "the watcher unit file should be copied into systemd"
    harness_assert_call_order \
        "systemctl enable broadcast-logs-watcher" \
        "systemctl start broadcast-logs-watcher"
}

test_upgrade_continue_restarts_logs_watcher_to_pick_up_new_scripts() {
    sandbox_run "_upgrade_continue 2.5.0" >/dev/null
    harness_assert_called "systemctl restart broadcast-logs-watcher" \
        "the watcher must restart so updated scripts take effect"
}

test_upgrade_continue_adds_encryption_keys_when_missing() {
    sandbox_run "_upgrade_continue 2.5.0" >/dev/null

    local count
    count=$(/usr/bin/grep -c "ACTIVE_RECORD_ENCRYPTION" "$SANDBOX_ROOT/app/.env")
    assert_equals "3" "$count" "all three encryption keys should be added"
}

test_upgrade_continue_preserves_existing_encryption_keys() {
    cat >> "$SANDBOX_ROOT/app/.env" <<'ENV'
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=preexisting-primary
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=preexisting-det
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=preexisting-salt
ENV

    sandbox_run "_upgrade_continue 2.5.0" >/dev/null

    local count
    count=$(/usr/bin/grep -c "ACTIVE_RECORD_ENCRYPTION" "$SANDBOX_ROOT/app/.env")
    assert_equals "3" "$count" "existing keys must not be duplicated"
    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "preexisting-primary" \
        "existing key values must survive an upgrade untouched"
}

test_upgrade_continue_adds_health_cron_for_older_installs() {
    # Existing installs pull new script FILES via the daily update, but
    # nothing adds new cron ENTRIES on their machines — the upgrade path
    # must backfill the health-reporting cron (same pattern as the
    # logs-watcher install for upgrades from older versions).
    echo "* * * * * $SANDBOX_ROOT/broadcast.sh monitor" > "$SANDBOX_ROOT/crontab.txt"

    sandbox_run "_upgrade_continue 2.5.0" >/dev/null
    sandbox_run "_upgrade_continue 2.5.0" >/dev/null

    local count
    count=$(/usr/bin/grep -c "broadcast.sh health" "$SANDBOX_ROOT/crontab.txt")
    assert_equals "1" "$count" \
        "the health cron entry must be added exactly once across upgrades"
    assert_contains "$(cat "$SANDBOX_ROOT/crontab.txt")" "broadcast.sh monitor" \
        "existing cron entries must survive"
}

test_upgrade_continue_adds_recover_cron_for_older_installs() {
    # Auto-recovery is worthless if it is never scheduled. install.sh and fix
    # add the cron entry, but fix is a manual support command -- so without
    # this the customer whose outage motivated recover.sh would upgrade and
    # still have nothing restarting their server.
    echo "* * * * * $SANDBOX_ROOT/broadcast.sh monitor" > "$SANDBOX_ROOT/crontab.txt"

    sandbox_run "_upgrade_continue 2.5.0" >/dev/null
    sandbox_run "_upgrade_continue 2.5.0" >/dev/null

    local count
    count=$(/usr/bin/grep -c "broadcast.sh recover" "$SANDBOX_ROOT/crontab.txt")
    assert_equals "1" "$count" \
        "the recover cron entry must be added exactly once across upgrades"
    assert_contains "$(cat "$SANDBOX_ROOT/crontab.txt")" "broadcast.sh monitor" \
        "existing cron entries must survive"
}

test_upgrade_continue_refreshes_stale_broadcast_unit() {
    # The unit file is written once at install; existing servers kept the
    # pre-incident template (no RestartSec / StartLimitIntervalSec /
    # network-online ordering) forever because no path rewrote it. The
    # upgrade path is the delivery vehicle for unit fixes.
    cat > "$SANDBOX_ROOT/etc/systemd/system/broadcast.service" <<'STALE'
[Unit]
Description=Broadcast
Requires=docker.service
After=docker.service

[Service]
Type=simple
ExecStart=/bin/bash -c "docker compose up"
Restart=always
User=broadcast

[Install]
WantedBy=multi-user.target
STALE

    sandbox_run "_upgrade_continue 2.5.0" >/dev/null

    local unit
    unit=$(cat "$SANDBOX_ROOT/etc/systemd/system/broadcast.service")
    assert_contains "$unit" "StartLimitIntervalSec=0" \
        "upgrade must rewrite a stale broadcast.service unit"
    assert_contains "$unit" "RestartSec=" \
        "the refreshed unit must space out restart attempts"

    # The reload must land before the service is started with the new unit
    harness_assert_call_order \
        "systemctl daemon-reload" \
        "systemctl start broadcast"
}

test_upgrade_continue_leaves_current_broadcast_unit_alone() {
    sandbox_run "create_broadcast_service" >/dev/null
    local before
    before=$(cat "$SANDBOX_ROOT/etc/systemd/system/broadcast.service")

    local output
    output=$(sandbox_run "_upgrade_continue 2.5.0")

    assert_equals "$before" "$(cat "$SANDBOX_ROOT/etc/systemd/system/broadcast.service")" \
        "an already-current unit must survive an upgrade byte-identical"
    if [[ "$output" == *"broadcast.service unit refreshed"* ]]; then
        assert_equals "no refresh message" "refresh message printed" \
            "upgrade must not claim to refresh a unit that was already current"
    fi
}

# --- _downgrade_continue --------------------------------------------------

test_downgrade_continue_full_sequence() {
    local rc=0
    sandbox_run "_downgrade_continue 1.5.0" >/dev/null || rc=$?
    assert_equals "0" "$rc" "_downgrade_continue should succeed"

    assert_contains "$(cat "$SANDBOX_ROOT/.image")" ":1.5.0" ".image should pin the target tag"
    assert_equals "1.5.0" "$(cat "$SANDBOX_ROOT/.current_version")" \
        ".current_version should track the downgraded version"

    harness_assert_call_order \
        "docker image prune -f" \
        "su - broadcast" \
        "systemctl start broadcast"

    assert_contains "$(cat "$SANDBOX_ROOT/.version_history")" "downgrade | 2.0.0 | 1.5.0" \
        "version history should record the downgrade"
}

# --- update: dirty-tree protection -----------------------------------------
# 2026-08-04 (firstborngroup): a hand-edited docker-compose.yml made every
# nightly `git pull` fail silently for weeks and killed the upgrade. update
# must detect local modifications BEFORE pulling and say what to do instead.

test_update_refuses_a_dirty_tree_with_guidance() {
    harness_mock git 'case "$*" in
  *"status --porcelain"*) echo " M docker-compose.yml" ;;
esac
exit 0'

    local rc=0 output
    output=$(sandbox_run "update") || rc=$?
    assert_not_equals "0" "$rc" "update must refuse to pull over local modifications"
    assert_contains "$output" "docker-compose.yml" "the modified file must be named"
    assert_contains "$output" "docker-compose.override.yml" \
        "the supported customization path must be pointed at"
    harness_assert_not_called "git pull" "the pull must not be attempted on a dirty tree"
}

test_update_pulls_on_a_clean_tree() {
    local rc=0
    sandbox_run "update" >/dev/null || rc=$?
    assert_equals "0" "$rc" "update should succeed on a clean tree"
    harness_assert_called "git pull" "a clean tree must be pulled"
}

# --- fail-safe: a failed upgrade/downgrade must leave the old version up ---
# The stop->start window: broadcast.sh runs under `set -e`, so any failure
# after `systemctl stop broadcast` and before the final start used to leave
# the service STOPPED (customer outage, 2026-08-04; smoke Phase 7b). These
# tests pin the fail-safe trap: report failure, roll the image pin back,
# start the previous version on the way out.

test_upgrade_continue_failsafe_restarts_service_on_pull_failure() {
    harness_mock su 'exit 1'   # the explicit `docker compose pull` step fails

    local rc=0
    sandbox_run "_upgrade_continue 2.5.0" >/dev/null || rc=$?
    assert_not_equals "0" "$rc" "a failed upgrade must still exit nonzero"

    harness_assert_called "systemctl start broadcast" \
        "fail-safe must start the service after a mid-window failure"
    assert_contains "$(cat "$SANDBOX_ROOT/.image")" ":2.0.0" \
        ".image must be rolled back to the pre-upgrade version"
    assert_equals "2.0.0" "$(cat "$SANDBOX_ROOT/.current_version")" \
        ".current_version must be rolled back to the pre-upgrade version"
}

test_upgrade_continue_starts_service_exactly_once_on_success() {
    sandbox_run "_upgrade_continue 2.5.0" >/dev/null

    local count
    count=$(/usr/bin/grep -c "^systemctl start broadcast$" "$SANDBOX_CALLS")
    assert_equals "1" "$count" \
        "the fail-safe must be disarmed on success — no second start from the trap"
}

test_upgrade_updates_before_stopping() {
    harness_stub_broadcast_sh
    local rc=0
    sandbox_run "upgrade" >/dev/null || rc=$?
    assert_equals "0" "$rc" "upgrade should proceed"

    harness_assert_call_order \
        "broadcast.sh update" \
        "systemctl stop broadcast" \
        "broadcast.sh _upgrade_continue"
}

test_upgrade_update_failure_never_touches_the_service() {
    # Stub broadcast.sh so the `update` dispatch fails — a dirty tree or
    # unreachable GitHub. Since the update now precedes the stop, the
    # failure must abort the upgrade with the service NEVER stopped.
    cat > "$SANDBOX_ROOT/broadcast.sh" <<STUB
#!/bin/bash
echo "broadcast.sh \$*" >> "$SANDBOX_CALLS"
[ "\${1:-}" = "update" ] && exit 1
exit 0
STUB
    chmod +x "$SANDBOX_ROOT/broadcast.sh"

    local rc=0
    sandbox_run "upgrade" >/dev/null || rc=$?
    assert_not_equals "0" "$rc" "upgrade must fail when the script update fails"

    harness_assert_not_called "systemctl stop broadcast" \
        "a failed script update must abort BEFORE the service is stopped"
}

test_downgrade_continue_failsafe_restarts_service_on_pull_failure() {
    harness_mock su 'exit 1'

    local rc=0
    sandbox_run "_downgrade_continue 1.5.0" >/dev/null || rc=$?
    assert_not_equals "0" "$rc" "a failed downgrade must still exit nonzero"

    harness_assert_called "systemctl start broadcast" \
        "fail-safe must start the service after a mid-window failure"
    assert_contains "$(cat "$SANDBOX_ROOT/.image")" ":2.0.0" \
        ".image must be rolled back to the pre-downgrade version"
    assert_equals "2.0.0" "$(cat "$SANDBOX_ROOT/.current_version")" \
        ".current_version must be rolled back to the pre-downgrade version"
}

run_upgrade_downgrade_tests() {
    echo "Running Upgrade/Downgrade Continuation Tests"
    echo "============================================"

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_downgrade_requires_a_version" test_downgrade_requires_a_version
    run_test "test_downgrade_rejects_invalid_version_format" test_downgrade_rejects_invalid_version_format
    run_test "test_downgrade_updates_before_stopping" test_downgrade_updates_before_stopping
    run_test "test_upgrade_continue_full_sequence_with_version" test_upgrade_continue_full_sequence_with_version
    run_test "test_upgrade_continue_defaults_to_latest" test_upgrade_continue_defaults_to_latest
    run_test "test_upgrade_continue_installs_cleanup_service_when_missing" test_upgrade_continue_installs_cleanup_service_when_missing
    run_test "test_upgrade_continue_skips_cleanup_service_when_present" test_upgrade_continue_skips_cleanup_service_when_present
    run_test "test_upgrade_continue_installs_logs_watcher_when_not_enabled" test_upgrade_continue_installs_logs_watcher_when_not_enabled
    run_test "test_upgrade_continue_restarts_logs_watcher_to_pick_up_new_scripts" test_upgrade_continue_restarts_logs_watcher_to_pick_up_new_scripts
    run_test "test_upgrade_continue_adds_encryption_keys_when_missing" test_upgrade_continue_adds_encryption_keys_when_missing
    run_test "test_upgrade_continue_preserves_existing_encryption_keys" test_upgrade_continue_preserves_existing_encryption_keys
    run_test "test_upgrade_continue_adds_health_cron_for_older_installs" test_upgrade_continue_adds_health_cron_for_older_installs
    run_test "test_upgrade_continue_adds_recover_cron_for_older_installs" test_upgrade_continue_adds_recover_cron_for_older_installs
    run_test "test_upgrade_continue_refreshes_stale_broadcast_unit" test_upgrade_continue_refreshes_stale_broadcast_unit
    run_test "test_upgrade_continue_leaves_current_broadcast_unit_alone" test_upgrade_continue_leaves_current_broadcast_unit_alone
    run_test "test_downgrade_continue_full_sequence" test_downgrade_continue_full_sequence
    run_test "test_update_refuses_a_dirty_tree_with_guidance" test_update_refuses_a_dirty_tree_with_guidance
    run_test "test_update_pulls_on_a_clean_tree" test_update_pulls_on_a_clean_tree
    run_test "test_upgrade_continue_failsafe_restarts_service_on_pull_failure" test_upgrade_continue_failsafe_restarts_service_on_pull_failure
    run_test "test_upgrade_continue_starts_service_exactly_once_on_success" test_upgrade_continue_starts_service_exactly_once_on_success
    run_test "test_upgrade_updates_before_stopping" test_upgrade_updates_before_stopping
    run_test "test_upgrade_update_failure_never_touches_the_service" test_upgrade_update_failure_never_touches_the_service
    run_test "test_downgrade_continue_failsafe_restarts_service_on_pull_failure" test_downgrade_continue_failsafe_restarts_service_on_pull_failure

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_upgrade_downgrade_tests
fi
