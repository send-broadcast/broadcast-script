#!/bin/bash

# Integration tests for the real workflow scripts: trigger.sh dispatch,
# backup.sh archive creation/retention, upgrade.sh entry sequence and
# update.sh remote migration. The unmodified scripts run inside the sandbox
# harness with external commands (systemctl, docker, su, git, ...) shimmed
# and logged; file operations are real.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    harness_stub_broadcast_sh
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    touch "$SANDBOX_ROOT/app/.env"
}

teardown_sandbox() {
    harness_destroy_sandbox
}

# --- upgrade entry sequence ----------------------------------------------

# Update runs BEFORE the stop (2026-08-04 incident: a failed git pull after
# the stop left the site down) — mirrors the unit-level order test.
test_upgrade_updates_stops_then_reexecs() {
    local rc=0
    sandbox_run "upgrade" >/dev/null || rc=$?
    assert_equals "0" "$rc" "upgrade entry should succeed"

    harness_assert_call_order \
        "broadcast.sh update" \
        "systemctl stop broadcast" \
        "broadcast.sh _upgrade_continue"
}

test_upgrade_forwards_target_version_through_reexec() {
    sandbox_run "upgrade 1.2.3" >/dev/null
    harness_assert_called "broadcast.sh _upgrade_continue 1.2.3" \
        "the re-exec must carry the requested version"
}

# --- trigger.sh -----------------------------------------------------------

test_trigger_upgrade_with_valid_version() {
    echo "1.2.3" > "$SANDBOX_ROOT/app/triggers/upgrade.txt"

    sandbox_run "trigger" >/dev/null

    harness_assert_called "broadcast.sh upgrade 1.2.3" "should upgrade to the requested version"
    assert_file_not_exists "$SANDBOX_ROOT/app/triggers/upgrade.txt" \
        "trigger file must be consumed"
}

test_trigger_upgrade_falls_back_on_invalid_version() {
    echo "not-a-version" > "$SANDBOX_ROOT/app/triggers/upgrade.txt"

    local output
    output=$(sandbox_run "trigger")

    harness_assert_called "broadcast.sh upgrade" "fallback should still upgrade"
    harness_assert_not_called "broadcast.sh upgrade not-a-version" \
        "invalid content must not be passed as a version"
    assert_contains "$output" "fallback mode" "fallback should be logged"
    assert_file_not_exists "$SANDBOX_ROOT/app/triggers/upgrade.txt" \
        "trigger file must be consumed even when invalid"
}

test_trigger_domains_updates_tls_and_restarts() {
    printf 'a.example.com\nb.example.com\n' > "$SANDBOX_ROOT/app/triggers/domains.txt"

    sandbox_run "trigger" >/dev/null

    assert_file_exists "$SANDBOX_ROOT/.other_domains" "domains.txt should be copied to .other_domains"

    local tls
    tls=$(/usr/bin/grep "^TLS_DOMAIN=" "$SANDBOX_ROOT/app/.env" | tail -1)
    assert_equals "TLS_DOMAIN=test.example.com,a.example.com,b.example.com" "$tls" \
        "TLS_DOMAIN should combine the primary and additional domains"

    harness_assert_called "chown -R broadcast:broadcast" "ownership should be reset"
    harness_assert_called "broadcast.sh restart" "services should restart after a domain change"
    assert_file_not_exists "$SANDBOX_ROOT/app/triggers/domains.txt" "trigger file must be consumed"
}

test_trigger_backup_db() {
    touch "$SANDBOX_ROOT/app/triggers/backup-db.txt"

    sandbox_run "trigger" >/dev/null

    harness_assert_called "broadcast.sh backup_database" "backup trigger should run backup_database"
    assert_file_not_exists "$SANDBOX_ROOT/app/triggers/backup-db.txt" "trigger file must be consumed"
}

test_trigger_restart_jobs() {
    touch "$SANDBOX_ROOT/app/triggers/restart-jobs.txt"

    sandbox_run "trigger" >/dev/null

    harness_assert_called "docker compose restart job" "restart-jobs should restart the job container"
    assert_file_not_exists "$SANDBOX_ROOT/app/triggers/restart-jobs.txt" "trigger file must be consumed"
}

test_trigger_adds_broadcast_managed_once() {
    sandbox_run "trigger" >/dev/null
    sandbox_run "trigger" >/dev/null

    local count
    count=$(/usr/bin/grep -c "^BROADCAST_MANAGED=true" "$SANDBOX_ROOT/app/.env")
    assert_equals "1" "$count" "BROADCAST_MANAGED must be added exactly once"
}

test_trigger_with_no_trigger_files_is_a_noop() {
    sandbox_run "trigger" >/dev/null

    harness_assert_not_called "broadcast.sh upgrade" "no upgrade without a trigger file"
    harness_assert_not_called "broadcast.sh restart" "no restart without a trigger file"
    harness_assert_not_called "broadcast.sh backup_database" "no backup without a trigger file"
}

# --- backup.sh ------------------------------------------------------------

test_backup_database_creates_versioned_archive_with_checksum() {
    echo "2.1.0" > "$SANDBOX_ROOT/.current_version"

    local rc=0
    sandbox_run "backup_database" >/dev/null || rc=$?
    assert_equals "0" "$rc" "backup_database should succeed"

    local archive
    archive=$(ls "$SANDBOX_ROOT/db/backups/"broadcast-backup-v2.1.0-*.tar.gz 2>/dev/null | head -1)
    if [ -z "$archive" ]; then
        assert_equals "archive created" "no archive" "a versioned tarball should exist in db/backups"
        return 0
    fi

    assert_file_exists "${archive}.sha256" "a checksum sidecar should accompany the tarball"

    # The intermediate dump and VERSION files must be cleaned up
    assert_file_not_exists "$SANDBOX_ROOT/db/backups/VERSION" "VERSION staging file should be removed"
    local leftover_dumps
    leftover_dumps=$(ls "$SANDBOX_ROOT/db/backups/"*.dump 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "0" "$leftover_dumps" "no raw .dump files should remain"

    # Archive contents: the pg_dump payload and the version marker
    local work
    work=$(mktemp -d)
    tar -xzf "$archive" -C "$work"
    assert_equals "2.1.0" "$(cat "$work/VERSION")" "VERSION inside the archive should match"
    local dump
    dump=$(ls "$work"/*.dump | head -1)
    assert_contains "$(cat "$dump")" "FAKE PG DUMP PAYLOAD" "dump should hold the pg_dump output"
    rm -rf "$work"

    # The dump must run WITHOUT a TTY (-T): an interactive run otherwise
    # pulls binary dump bytes through a pty, corrupting the backup — and the
    # checksum sidecar is computed after the corruption, so it cannot catch it.
    harness_assert_called "docker compose exec -T postgres pg_dump" \
        "pg_dump must run with -T so interactive backups are not TTY-corrupted"

    # The archive is copied into app storage for the Rails app to serve
    local staged
    staged=$(ls "$SANDBOX_ROOT/app/storage/"broadcast-backup-v2.1.0-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "1" "$staged" "archive should be copied to app/storage"
}

test_backup_database_retains_only_newest_backup() {
    echo "2.1.0" > "$SANDBOX_ROOT/.current_version"

    # Simulate older backups (explicit past mtimes so ls -t orders reliably)
    local old1="$SANDBOX_ROOT/db/backups/broadcast-backup-v1.0.0-2020-01-01-00-00-00.tar.gz"
    local old2="$SANDBOX_ROOT/db/backups/broadcast-backup-v1.1.0-2021-01-01-00-00-00.tar.gz"
    touch -t 202001010000 "$old1"
    touch -t 202101010000 "$old2"
    touch -t 202101010000 "${old2}.sha256"
    # Orphan sidecar whose tarball is already gone
    touch -t 202001010000 "$SANDBOX_ROOT/db/backups/broadcast-backup-v0.9.0-gone.tar.gz.sha256"

    sandbox_run "backup_database" >/dev/null

    assert_file_not_exists "$old1" "older backup should be pruned"
    assert_file_not_exists "$old2" "older backup should be pruned"
    assert_file_not_exists "${old2}.sha256" "sidecar of a pruned tarball should be pruned"
    assert_file_not_exists "$SANDBOX_ROOT/db/backups/broadcast-backup-v0.9.0-gone.tar.gz.sha256" \
        "orphan sidecars should be cleaned up"

    local remaining
    remaining=$(ls "$SANDBOX_ROOT/db/backups/"broadcast-backup-*.tar.gz | wc -l | tr -d ' ')
    assert_equals "1" "$remaining" "exactly one (the newest) backup should remain"
}

test_backup_database_handles_unknown_version() {
    rm -f "$SANDBOX_ROOT/.current_version"

    local rc=0
    sandbox_run "backup_database" >/dev/null || rc=$?
    assert_equals "0" "$rc" "backup should work without a version file"

    local archive
    archive=$(ls "$SANDBOX_ROOT/db/backups/"broadcast-backup-vunknown-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "1" "$archive" "archive should be tagged vunknown"
}

# --- update.sh ------------------------------------------------------------

test_update_migrates_legacy_furvur_remote() {
    sandbox_run "update" 'export GIT_MOCK_REMOTE_URL="https://github.com/Furvur/broadcast-script.git"' >/dev/null

    harness_assert_call_order \
        "git remote set-url origin https://github.com/send-broadcast/broadcast-script.git" \
        "git pull"
}

test_update_leaves_current_remote_alone() {
    sandbox_run "update" 'export GIT_MOCK_REMOTE_URL="https://github.com/send-broadcast/broadcast-script.git"' >/dev/null

    harness_assert_not_called "git remote set-url" "current remote must not be rewritten"
    harness_assert_called "git pull" "update should still pull"
}

run_workflow_tests() {
    echo "Running Workflow Integration Tests"
    echo "=================================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_upgrade_updates_stops_then_reexecs" test_upgrade_updates_stops_then_reexecs
    run_test "test_upgrade_forwards_target_version_through_reexec" test_upgrade_forwards_target_version_through_reexec
    run_test "test_trigger_upgrade_with_valid_version" test_trigger_upgrade_with_valid_version
    run_test "test_trigger_upgrade_falls_back_on_invalid_version" test_trigger_upgrade_falls_back_on_invalid_version
    run_test "test_trigger_domains_updates_tls_and_restarts" test_trigger_domains_updates_tls_and_restarts
    run_test "test_trigger_backup_db" test_trigger_backup_db
    run_test "test_trigger_restart_jobs" test_trigger_restart_jobs
    run_test "test_trigger_adds_broadcast_managed_once" test_trigger_adds_broadcast_managed_once
    run_test "test_trigger_with_no_trigger_files_is_a_noop" test_trigger_with_no_trigger_files_is_a_noop
    run_test "test_backup_database_creates_versioned_archive_with_checksum" test_backup_database_creates_versioned_archive_with_checksum
    run_test "test_backup_database_retains_only_newest_backup" test_backup_database_retains_only_newest_backup
    run_test "test_backup_database_handles_unknown_version" test_backup_database_handles_unknown_version
    run_test "test_update_migrates_legacy_furvur_remote" test_update_migrates_legacy_furvur_remote
    run_test "test_update_leaves_current_remote_alone" test_update_leaves_current_remote_alone

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_workflow_tests
fi
