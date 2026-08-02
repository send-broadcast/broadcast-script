#!/bin/bash

# Unit tests for the fix() convergence command (scripts/fix.sh), written
# TDD-first. fix repairs installation DRIFT idempotently — directories,
# ownership, executable bits, sudoers, docker group, systemd units, cron
# entries, encryption keys — and reports ok:/fixed: per check. It does NOT
# re-run one-time provisioning: a missing prerequisite like docker itself
# is reported as unfixable (exit 1) and points at ./broadcast.sh install.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    touch "$SANDBOX_ROOT/app/.env"
    touch "$SANDBOX_ROOT/broadcast.sh"
    chmod +x "$SANDBOX_ROOT/broadcast.sh"

    # systemctl with controllable is-enabled / is-active results
    harness_mock systemctl 'case "${1:-}" in
  is-enabled) exit "${SYSTEMCTL_IS_ENABLED_RC:-0}" ;;
  is-active) exit "${SYSTEMCTL_IS_ACTIVE_RC:-0}" ;;
esac
exit 0'
    # id: user exists; group list controllable
    harness_mock id 'if [ "${1:-}" = "-nG" ]; then echo "${ID_MOCK_GROUPS:-broadcast docker}"; fi
exit "${ID_MOCK_RC:-0}"'
    harness_mock usermod 'exit 0'
    harness_mock useradd 'exit 0'
    # crontab: -l prints the stored crontab, - installs from stdin.
    # The install path buffers to a temp file and mv's it into place:
    # real crontab has no shared file, but this mock does, and truncating
    # it directly would race the `crontab -l` running in the same pipeline.
    harness_mock crontab 'case "${1:-}" in
  -l) cat "${CRONTAB_MOCK_FILE:?}" 2>/dev/null || exit 1 ;;
  -) cat > "$CRONTAB_MOCK_FILE.tmp" && mv "$CRONTAB_MOCK_FILE.tmp" "$CRONTAB_MOCK_FILE" ;;
esac
exit 0'
    export CRONTAB_MOCK_FILE="$SANDBOX_ROOT/crontab.txt"
    # Present on a correct install; without this shim macOS (no inotifywait)
    # would take the install-inotify-tools repair path in every test
    harness_mock inotifywait 'exit 0'
}

teardown_sandbox() {
    unset CRONTAB_MOCK_FILE
    harness_destroy_sandbox
}

# Environment line passed to every sandbox_run so the crontab mock knows
# where its state lives inside the sandboxed shell.
FIX_ENV='export CRONTAB_MOCK_FILE="$BROADCAST_ROOT/crontab.txt"'

test_fix_recreates_missing_directories() {
    rm -rf "$SANDBOX_ROOT/app/triggers" "$SANDBOX_ROOT/logs/cron"

    local rc=0
    sandbox_run "fix" "$FIX_ENV" >/dev/null || rc=$?
    assert_equals "0" "$rc" "fix should succeed"

    if [ ! -d "$SANDBOX_ROOT/app/triggers" ]; then
        assert_equals "recreated" "missing" "app/triggers must be recreated"
    fi
    if [ ! -d "$SANDBOX_ROOT/logs/cron" ]; then
        assert_equals "recreated" "missing" "logs/cron must be recreated"
    fi
}

test_fix_restores_broadcast_sh_executable_bit() {
    chmod -x "$SANDBOX_ROOT/broadcast.sh"

    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    if [ ! -x "$SANDBOX_ROOT/broadcast.sh" ]; then
        assert_equals "executable" "not executable" "broadcast.sh must be made executable"
    fi
    assert_contains "$output" "fixed:" "the repair must be reported"
}

test_fix_repairs_ownership_drift() {
    # Sandbox files are owned by the test user, not broadcast — fix must
    # chown (mocked and logged) and report it.
    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    harness_assert_called "chown -R broadcast:broadcast" "ownership drift must be repaired"
}

test_fix_leaves_correct_ownership_alone() {
    harness_mock stat 'echo broadcast'

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    harness_assert_not_called "chown -R broadcast:broadcast" \
        "correct ownership must not be touched"
}

test_fix_recreates_missing_sudoers_entry() {
    rm -f "$SANDBOX_ROOT/etc/sudoers.d/broadcast"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_file_exists "$SANDBOX_ROOT/etc/sudoers.d/broadcast" "sudoers entry must be recreated"
    assert_contains "$(cat "$SANDBOX_ROOT/etc/sudoers.d/broadcast")" "NOPASSWD" \
        "the recreated entry must grant passwordless sudo"
}

test_fix_restores_docker_group_membership() {
    sandbox_run "fix" "$FIX_ENV" 'export ID_MOCK_GROUPS="broadcast"' >/dev/null 2>&1 || true
    local output
    output=$(sandbox_run "fix" "
$FIX_ENV
export ID_MOCK_GROUPS=broadcast")

    harness_assert_called "usermod -aG docker broadcast" \
        "missing docker group membership must be repaired"
}

test_fix_installs_missing_systemd_units() {
    # Sandbox systemd dir starts empty: broadcast.service, the cleanup
    # unit, and the watcher unit must all be installed
    local output
    output=$(sandbox_run "fix" "$FIX_ENV")

    assert_file_exists "$SANDBOX_ROOT/etc/systemd/system/broadcast.service" \
        "broadcast.service must be created"
    assert_file_exists "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service" \
        "the cleanup unit must be installed"
    assert_file_exists "$SANDBOX_ROOT/etc/systemd/system/broadcast-logs-watcher.service" \
        "the watcher unit must be installed"
    harness_assert_called "systemctl daemon-reload" "systemd must reload after unit installs"
}

test_fix_enables_and_starts_inactive_services() {
    # Units present but disabled/stopped
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-logs-watcher.service"

    sandbox_run "fix" "
$FIX_ENV
export SYSTEMCTL_IS_ENABLED_RC=1
export SYSTEMCTL_IS_ACTIVE_RC=1" >/dev/null

    harness_assert_called "systemctl enable broadcast.service" "disabled service must be enabled"
    harness_assert_called "systemctl start broadcast.service" "stopped service must be started"
    harness_assert_called "systemctl enable broadcast-logs-watcher" "watcher must be enabled"
    harness_assert_called "systemctl start broadcast-logs-watcher" "watcher must be started"
}

test_fix_adds_missing_cron_entries_once() {
    sandbox_run "fix" "$FIX_ENV" >/dev/null
    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_file_exists "$SANDBOX_ROOT/crontab.txt" "crontab must be installed"
    local cmd count
    for cmd in monitor trigger update; do
        count=$(/usr/bin/grep -c "broadcast.sh $cmd" "$SANDBOX_ROOT/crontab.txt")
        assert_equals "1" "$count" "cron entry for '$cmd' must exist exactly once after two runs"
    done
}

test_fix_preserves_existing_cron_entries() {
    echo "0 3 * * * /usr/local/bin/custom-backup.sh" > "$SANDBOX_ROOT/crontab.txt"

    sandbox_run "fix" "$FIX_ENV" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/crontab.txt")" "custom-backup.sh" \
        "unrelated cron entries must survive"
}

test_fix_generates_missing_encryption_keys() {
    sandbox_run "fix" "$FIX_ENV" >/dev/null

    local count
    count=$(/usr/bin/grep -c "ACTIVE_RECORD_ENCRYPTION" "$SANDBOX_ROOT/app/.env")
    assert_equals "3" "$count" "missing encryption keys must be generated"
}

test_fix_fails_on_missing_docker_prerequisite() {
    local output rc=0
    output=$(sandbox_run '
fix_has_command() { [ "$1" != "docker" ]; }
fix' "$FIX_ENV") || rc=$?

    assert_equals "1" "$rc" "a missing prerequisite must make fix exit 1"
    assert_contains "$output" "install" "the fix for a missing prerequisite is a reinstall"
}

test_fix_installs_inotify_tools_when_missing() {
    sandbox_run '
fix_has_command() { [ "$1" != "inotifywait" ]; }
fix' "$FIX_ENV" >/dev/null

    harness_assert_called "apt-get install -y inotify-tools" \
        "missing inotify-tools must be installed"
}

test_fix_reports_clean_on_healthy_system() {
    # Healthy: correct ownership, units present, cron populated, keys exist
    harness_mock stat 'echo broadcast'
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-post-upgrade-cleanup.service"
    touch "$SANDBOX_ROOT/etc/systemd/system/broadcast-logs-watcher.service"
    echo "broadcast ALL=(ALL) NOPASSWD:ALL" > "$SANDBOX_ROOT/etc/sudoers.d/broadcast"
    printf '* * * * * %s/broadcast.sh monitor\n* * * * * %s/broadcast.sh trigger\n0 0 * * * %s/broadcast.sh update\n' \
        "$SANDBOX_ROOT" "$SANDBOX_ROOT" "$SANDBOX_ROOT" > "$SANDBOX_ROOT/crontab.txt"
    cat >> "$SANDBOX_ROOT/app/.env" <<'ENV'
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=x
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=y
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=z
ENV

    local output rc=0
    output=$(sandbox_run "fix" "$FIX_ENV") || rc=$?

    assert_equals "0" "$rc" "a healthy system should exit 0"
    assert_contains "$output" "ok:" "healthy checks should be reported ok"
    if [[ "$output" == *"fixed:"* ]]; then
        assert_equals "nothing to fix" "something was fixed" \
            "a healthy system must not report repairs: $output"
    fi
}

run_fix_tests() {
    echo "Running Fix Command Tests"
    echo "========================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_fix_recreates_missing_directories" test_fix_recreates_missing_directories
    run_test "test_fix_restores_broadcast_sh_executable_bit" test_fix_restores_broadcast_sh_executable_bit
    run_test "test_fix_repairs_ownership_drift" test_fix_repairs_ownership_drift
    run_test "test_fix_leaves_correct_ownership_alone" test_fix_leaves_correct_ownership_alone
    run_test "test_fix_recreates_missing_sudoers_entry" test_fix_recreates_missing_sudoers_entry
    run_test "test_fix_restores_docker_group_membership" test_fix_restores_docker_group_membership
    run_test "test_fix_installs_missing_systemd_units" test_fix_installs_missing_systemd_units
    run_test "test_fix_enables_and_starts_inactive_services" test_fix_enables_and_starts_inactive_services
    run_test "test_fix_adds_missing_cron_entries_once" test_fix_adds_missing_cron_entries_once
    run_test "test_fix_preserves_existing_cron_entries" test_fix_preserves_existing_cron_entries
    run_test "test_fix_generates_missing_encryption_keys" test_fix_generates_missing_encryption_keys
    run_test "test_fix_fails_on_missing_docker_prerequisite" test_fix_fails_on_missing_docker_prerequisite
    run_test "test_fix_installs_inotify_tools_when_missing" test_fix_installs_inotify_tools_when_missing
    run_test "test_fix_reports_clean_on_healthy_system" test_fix_reports_clean_on_healthy_system

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_fix_tests
fi
