#!/bin/bash

# Unit tests for the real command dispatch in broadcast.sh's main().
# The root/domain/license guards are stubbed (they are interactive or
# require root); the command handlers under test are either the real
# functions (arg validation paths) or recording stubs (to observe what the
# case statement forwards). The case routing itself is always the real code.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    echo "test-license" > "$SANDBOX_ROOT/.license"
}

teardown_sandbox() {
    harness_destroy_sandbox
}

# Neutralize the interactive/root-only guards, keep everything else real.
# includeDependencies is stubbed because sandbox_run has already sourced
# every script — letting main() re-source them would clobber these stubs
# (and any per-test function overrides) with the real definitions.
GUARD_STUBS='
includeDependencies() { :; }
check_root() { :; }
check_installation_domain() { :; }
check_license() { :; }
'

test_no_arguments_shows_help() {
    local output rc=0
    output=$(sandbox_run "$GUARD_STUBS
main") || rc=$?

    assert_contains "$output" "Error: No argument provided" "missing command should be reported"
    assert_contains "$output" "Usage:" "help should be displayed"
}

test_unknown_command_fails_with_usage() {
    local output rc=0
    output=$(sandbox_run "$GUARD_STUBS
main bogus-command") || rc=$?

    assert_equals "1" "$rc" "unknown command must exit 1"
    assert_contains "$output" "Usage:" "usage should be displayed"
}

test_help_command_lists_all_commands() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
main help")

    local cmd
    for cmd in install update upgrade downgrade restart backup restore monitor trigger diagnose; do
        assert_contains "$output" "$cmd" "help should mention '$cmd'"
    done
}

test_downgrade_without_version_is_rejected_before_dispatch() {
    local output rc=0
    output=$(sandbox_run "$GUARD_STUBS
main downgrade") || rc=$?

    assert_equals "1" "$rc" "downgrade without a version must exit 1"
    assert_contains "$output" "Target version is required" "the missing version should be named"
    harness_assert_not_called "systemctl" "no service action on a rejected downgrade"
}

test_logs_without_service_is_rejected() {
    local output rc=0
    output=$(sandbox_run "$GUARD_STUBS
main logs") || rc=$?

    assert_equals "1" "$rc" "logs without a service must exit 1"
    assert_contains "$output" "logs <app|job|db>" "usage should show the valid services"
}

test_upgrade_routes_with_and_without_version() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
upgrade() { echo \"UPGRADE_CALLED argc=\$# version=\${1:-none}\"; }
main upgrade 9.9.9")
    assert_contains "$output" "UPGRADE_CALLED argc=1 version=9.9.9" \
        "a provided version must be forwarded to upgrade()"

    output=$(sandbox_run "$GUARD_STUBS
upgrade() { echo \"UPGRADE_CALLED argc=\$# version=\${1:-none}\"; }
main upgrade")
    assert_contains "$output" "UPGRADE_CALLED argc=0 version=none" \
        "no version must call upgrade() with no arguments"
}

test_internal_continue_commands_forward_version() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
_upgrade_continue() { echo \"UC version=\${1:-empty}\"; }
_downgrade_continue() { echo \"DC version=\${1:-empty}\"; }
main _upgrade_continue 1.2.3
main _downgrade_continue 1.0.0")

    assert_contains "$output" "UC version=1.2.3" "_upgrade_continue should receive the version"
    assert_contains "$output" "DC version=1.0.0" "_downgrade_continue should receive the version"
}

test_restore_forwards_file_and_confirmation_flag() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
restore() { echo \"RESTORE_CALLED file=\${1:-none} flag=\${2:-none}\"; }
main restore backup.tar.gz --yes")

    assert_contains "$output" "RESTORE_CALLED file=backup.tar.gz flag=--yes" \
        "both the file and the --yes flag must be forwarded"
}

test_restore_without_file_reaches_real_validation() {
    local output rc=0
    output=$(sandbox_run "$GUARD_STUBS
main restore") || rc=$?

    assert_equals "1" "$rc" "restore without a file must fail"
    assert_contains "$output" "No backup file specified" \
        "the real restore validation should reject the empty argument"
}

test_install_pins_image_to_latest_before_installing() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
install() { echo \"INSTALL_CALLED image=\$(cat \"$SANDBOX_ROOT/.image\" | head -1)\"; }
main install")

    assert_contains "$output" "INSTALL_CALLED image=DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast:latest" \
        "install must run with the image already pinned to :latest"
    assert_equals "latest" "$(cat "$SANDBOX_ROOT/.current_version")" \
        ".current_version should be set before install runs"
}

test_simple_commands_route_to_their_functions() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
start() { echo ROUTED_start; }
stop() { echo ROUTED_stop; }
restart() { echo ROUTED_restart; }
backup_database() { echo ROUTED_backup_database; }
monitor() { echo ROUTED_monitor; }
trigger() { echo ROUTED_trigger; }
diagnose() { echo ROUTED_diagnose; }
main start; main stop; main restart; main backup_database; main monitor; main trigger; main diagnose")

    local cmd
    for cmd in start stop restart backup_database monitor trigger diagnose; do
        assert_contains "$output" "ROUTED_$cmd" "'$cmd' should route to $cmd()"
    done
}

run_broadcast_routing_tests() {
    echo "Running broadcast.sh Routing Tests"
    echo "=================================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_no_arguments_shows_help" test_no_arguments_shows_help
    run_test "test_unknown_command_fails_with_usage" test_unknown_command_fails_with_usage
    run_test "test_help_command_lists_all_commands" test_help_command_lists_all_commands
    run_test "test_downgrade_without_version_is_rejected_before_dispatch" test_downgrade_without_version_is_rejected_before_dispatch
    run_test "test_logs_without_service_is_rejected" test_logs_without_service_is_rejected
    run_test "test_upgrade_routes_with_and_without_version" test_upgrade_routes_with_and_without_version
    run_test "test_internal_continue_commands_forward_version" test_internal_continue_commands_forward_version
    run_test "test_restore_forwards_file_and_confirmation_flag" test_restore_forwards_file_and_confirmation_flag
    run_test "test_restore_without_file_reaches_real_validation" test_restore_without_file_reaches_real_validation
    run_test "test_install_pins_image_to_latest_before_installing" test_install_pins_image_to_latest_before_installing
    run_test "test_simple_commands_route_to_their_functions" test_simple_commands_route_to_their_functions

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_broadcast_routing_tests
fi
