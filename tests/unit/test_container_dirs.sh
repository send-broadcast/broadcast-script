#!/bin/bash

# Unit tests for the container-uid ownership helpers in scripts/common.sh,
# written TDD-first. chown_container_writable_dirs hands the container-written
# bind mounts (app/storage, app/uploads, app/triggers, ssl) to uid 1000. It
# must be cheap when nothing is wrong (touch only what needs changing, never
# a blanket chown -R), leave the host-written app/monitor alone, and never
# fail silently: a chown that does not take must be reported and returned.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    # Something to find inside each container-written dir, plus a decoy in
    # the host-written monitor dir. Sandbox files are owned by the developer,
    # never uid 1000, so the real find sees every one of them as drift.
    touch "$SANDBOX_ROOT/app/storage/upload.bin" "$SANDBOX_ROOT/app/uploads/a.png" \
          "$SANDBOX_ROOT/app/triggers/.keep" "$SANDBOX_ROOT/ssl/.keep" \
          "$SANDBOX_ROOT/app/monitor/system.json"
}

teardown_sandbox() {
    harness_destroy_sandbox
}

test_chowns_only_what_is_not_already_owned_by_the_container_uid() {
    sandbox_run "chown_container_writable_dirs" >/dev/null

    harness_assert_called "chown 1000:1000" "drifted paths must be re-owned to the container uid"
    harness_assert_called "app/storage/upload.bin" "files inside the dirs must be covered, not just the dir"
    harness_assert_not_called "chown -R" "no blanket recursive chown: it walks the whole upload tree on every upgrade"
}

test_leaves_host_written_dirs_alone() {
    sandbox_run "chown_container_writable_dirs" >/dev/null

    harness_assert_not_called "app/monitor" "app/monitor is written by the host and must keep its owner"
    harness_assert_not_called "/logs" "logs are written by the host and must keep their owner"
}

test_is_a_no_op_when_ownership_is_already_correct() {
    # Nothing owned by the wrong uid: find reports nothing, so chown never runs
    harness_mock find 'exit 0'

    local rc=0
    sandbox_run "chown_container_writable_dirs" >/dev/null || rc=$?

    assert_equals "0" "$rc" "correct ownership must succeed"
    # The find mock's own argument line mentions chown (-exec chown ...), so
    # look for chown as an invoked command, not as a substring.
    if /usr/bin/grep -q '^chown' "$SANDBOX_CALLS"; then
        echo "Assertion failed: chown was invoked although nothing needed changing"
        TEST_FAILED=true
        return 1
    fi
}

test_reports_and_returns_failure_when_chown_does_not_take() {
    harness_mock chown 'echo "chown: changing ownership: Read-only file system" >&2; exit 1'

    local output rc=0
    output=$(sandbox_run "chown_container_writable_dirs") || rc=$?

    assert_equals "1" "$rc" "a chown that did not take must be returned, not swallowed"
    assert_contains "$output" "could not" "the failure must be visible to the operator"
    assert_contains "$output" "app/triggers" "the warning must name the affected directory"
}

test_container_dirs_need_chown_detects_nested_drift() {
    local rc=0
    sandbox_run "container_writable_dirs_need_chown" >/dev/null || rc=$?
    assert_equals "0" "$rc" "files inside a dir owned by the wrong uid must count as drift"

    harness_mock find 'exit 0'
    rc=0
    sandbox_run "container_writable_dirs_need_chown" >/dev/null || rc=$?
    assert_equals "1" "$rc" "no drift anywhere must report clean"
}

run_container_dirs_tests() {
    init_test_framework
    setup_test_env
    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_chowns_only_what_is_not_already_owned_by_the_container_uid" test_chowns_only_what_is_not_already_owned_by_the_container_uid
    run_test "test_leaves_host_written_dirs_alone" test_leaves_host_written_dirs_alone
    run_test "test_is_a_no_op_when_ownership_is_already_correct" test_is_a_no_op_when_ownership_is_already_correct
    run_test "test_reports_and_returns_failure_when_chown_does_not_take" test_reports_and_returns_failure_when_chown_does_not_take
    run_test "test_container_dirs_need_chown_detects_nested_drift" test_container_dirs_need_chown_detects_nested_drift

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_container_dirs_tests
fi
