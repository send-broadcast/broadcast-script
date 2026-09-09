#!/bin/bash

# Unit tests for the two_factor command (scripts/two_factor.sh), written
# TDD-first. It is the self-hoster's recovery path when two-factor
# authentication has locked an administrator out: reset one user's
# factors, switch enforcement off, or list who has it enabled. Each
# subcommand runs the matching two_factor:* rake task inside the app
# container; the docker call is what these tests observe.

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

GUARD_STUBS='
includeDependencies() { :; }
check_root() { :; }
check_installation_domain() { :; }
check_license() { :; }
'

test_reset_runs_the_rake_task_for_the_email() {
    local output rc=0
    output=$(sandbox_run "two_factor reset admin@example.com") || rc=$?

    assert_equals "0" "$rc" "reset with an email should succeed"
    harness_assert_called 'docker exec app bin/rails two_factor:reset[admin@example.com]' \
        "reset should run the rake task inside the app container with the email"
}

test_reset_without_email_is_rejected_before_docker() {
    local output rc=0
    output=$(sandbox_run "two_factor reset") || rc=$?

    assert_equals "1" "$rc" "reset without an email must exit 1"
    assert_contains "$output" "two_factor reset <email>" "usage should name the missing email"
    harness_assert_not_called "docker" "nothing should run in the container"
}

test_reset_rejects_an_email_with_shell_metacharacters() {
    local output rc=0
    output=$(sandbox_run "two_factor reset 'a;b@example.com'") || rc=$?

    assert_equals "1" "$rc" "a suspicious email must be refused"
    assert_contains "$output" "does not look like an email address" "the refusal should say why"
    harness_assert_not_called "docker" "nothing should run in the container"
}

test_disable_enforcement_runs_the_rake_task() {
    local rc=0
    sandbox_run "two_factor disable_enforcement" >/dev/null || rc=$?

    assert_equals "0" "$rc" "disable_enforcement should succeed"
    harness_assert_called "docker exec app bin/rails two_factor:disable_enforcement" \
        "disable_enforcement should run the matching rake task"
}

test_status_runs_the_rake_task() {
    local rc=0
    sandbox_run "two_factor status" >/dev/null || rc=$?

    assert_equals "0" "$rc" "status should succeed"
    harness_assert_called "docker exec app bin/rails two_factor:status" \
        "status should run the matching rake task"
}

test_unknown_subcommand_shows_usage() {
    local output rc=0
    output=$(sandbox_run "two_factor bogus") || rc=$?

    assert_equals "1" "$rc" "an unknown subcommand must exit 1"
    assert_contains "$output" "reset <email>" "usage should list reset"
    assert_contains "$output" "disable_enforcement" "usage should list disable_enforcement"
    assert_contains "$output" "status" "usage should list status"
    harness_assert_not_called "docker" "nothing should run in the container"
}

test_failed_container_command_is_reported() {
    local output rc=0
    harness_mock docker 'echo "No user with email nobody@example.com"; exit 1'
    output=$(sandbox_run "two_factor reset nobody@example.com") || rc=$?

    assert_equals "1" "$rc" "a failing rake task must fail the command"
    assert_contains "$output" "No user with email" "the container's message should reach the operator"
}

test_main_routes_two_factor_with_arguments() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
two_factor() { echo \"TWO_FACTOR_CALLED argc=\$# sub=\${1:-none} arg=\${2:-none}\"; }
main two_factor reset admin@example.com")

    assert_contains "$output" "TWO_FACTOR_CALLED argc=2 sub=reset arg=admin@example.com" \
        "main must forward the subcommand and its argument"
}

test_help_mentions_two_factor() {
    local output
    output=$(sandbox_run "$GUARD_STUBS
main help")

    assert_contains "$output" "two_factor" "help should list the two_factor command"
}

run_two_factor_tests() {
    init_test_framework
    setup_test_env
    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_reset_runs_the_rake_task_for_the_email" test_reset_runs_the_rake_task_for_the_email
    run_test "test_reset_without_email_is_rejected_before_docker" test_reset_without_email_is_rejected_before_docker
    run_test "test_reset_rejects_an_email_with_shell_metacharacters" test_reset_rejects_an_email_with_shell_metacharacters
    run_test "test_disable_enforcement_runs_the_rake_task" test_disable_enforcement_runs_the_rake_task
    run_test "test_status_runs_the_rake_task" test_status_runs_the_rake_task
    run_test "test_unknown_subcommand_shows_usage" test_unknown_subcommand_shows_usage
    run_test "test_failed_container_command_is_reported" test_failed_container_command_is_reported
    run_test "test_main_routes_two_factor_with_arguments" test_main_routes_two_factor_with_arguments
    run_test "test_help_mentions_two_factor" test_help_mentions_two_factor

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_two_factor_tests
fi
