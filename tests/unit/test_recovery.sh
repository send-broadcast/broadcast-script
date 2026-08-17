#!/bin/bash

# Unit tests for local auto-recovery (scripts/recover.sh), written TDD-first.
#
# Why this exists. Customer incident 2026-08-15: the app exhausted its file
# descriptors and stopped serving, but the PROCESS never exited. So the
# container stayed Running, `restart: always` never fired, `docker ps` showed it
# Up, and systemd recorded one unbroken run of broadcast.service. Every signal
# Docker exposes said healthy while the site returned nothing but 502s. It took
# 31 minutes and a human to fix, and the only thing on the box that could see
# through it was health.sh's direct Puma probe -- which reported the failure to
# a dashboard and did nothing about it.
#
# Design contract under test:
#   - probes Puma DIRECTLY (docker exec ... localhost:3000/up), because that is
#     the probe that saw the outage; Thruster answered fine throughout
#   - hysteresis: 3 consecutive failures before acting, so a deploy blip or a
#     slow boot never triggers a restart
#   - cooldown: at most one restart per 15 minutes, so a server that cannot
#     stay up gets restarted, not flapped
#   - independent of health.sh's opt-in telemetry: an install that opted out of
#     monitoring entirely still recovers itself, because recovery is local and
#     phones nobody
#   - its own kill switch (.no_auto_recovery) for operators who want to be the
#     only thing that restarts their server
#   - every recovery calls an admin-notification seam, currently a local log
#     line, so alerting can be added without touching the decision logic

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    echo "test-license-key" > "$SANDBOX_ROOT/.license"

    # docker: the Puma probe's status code is controlled by RECOVERY_PUMA_CODE
    harness_mock docker 'case "$*" in
  exec\ app\ curl*)
    printf "%s" "${RECOVERY_PUMA_CODE:-200}"
    if [ "${RECOVERY_PUMA_CODE:-200}" = "000" ]; then exit 7; fi
    ;;
esac
exit 0'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

# Drives N consecutive runs with Puma answering $1.
run_probes() {
    local code="$1" times="$2" i
    for ((i = 1; i <= times; i++)); do
        sandbox_run "recover" "export RECOVERY_PUMA_CODE=$code" >/dev/null
    done
}

restarts_logged() {
    /usr/bin/grep -c "systemctl restart broadcast" "$SANDBOX_CALLS" 2>/dev/null || true
}

# --- healthy path ----------------------------------------------------------

test_healthy_puma_never_restarts() {
    run_probes 200 5
    assert_equals "0" "$(restarts_logged)" \
        "a healthy Puma must never trigger a restart"
}

# --- hysteresis ------------------------------------------------------------

test_two_consecutive_failures_do_not_restart() {
    run_probes 000 2
    assert_equals "0" "$(restarts_logged)" \
        "two failures is a blip; restarting there would make deploys and slow boots self-inflicted outages"
}

test_third_consecutive_failure_restarts_the_service() {
    run_probes 000 3
    assert_equals "1" "$(restarts_logged)" \
        "three consecutive failed Puma probes is the 2026-08-15 signature and must trigger recovery"
}

test_a_success_resets_the_failure_count() {
    run_probes 000 2
    run_probes 200 1
    run_probes 000 2
    assert_equals "0" "$(restarts_logged)" \
        "failures must be CONSECUTIVE; an intervening success resets the count"
}

# --- flap guard ------------------------------------------------------------

test_no_second_restart_within_the_cooldown() {
    run_probes 000 3
    run_probes 000 3
    assert_equals "1" "$(restarts_logged)" \
        "a server that cannot stay up must be restarted once and left alone, not flapped every three minutes"
}

test_restarts_again_after_the_cooldown_expires() {
    run_probes 000 3
    # Age the recovery stamp past the cooldown window
    sandbox_run 'sed -i.bak "s/^last_recovery_at=.*/last_recovery_at=1/" "$BROADCAST_ROOT/.recovery_state"' >/dev/null
    run_probes 000 3
    assert_equals "2" "$(restarts_logged)" \
        "once the cooldown has passed, a still-dead server must be retried"
}

# --- independence from telemetry ------------------------------------------

test_recovery_runs_even_when_health_reporting_is_disabled() {
    touch "$SANDBOX_ROOT/.no_health_reports"
    run_probes 000 3
    assert_equals "1" "$(restarts_logged)" \
        "recovery is local and phones nobody, so opting out of monitoring must not opt out of coming back up"
}

# --- kill switch -----------------------------------------------------------

test_kill_switch_disables_auto_recovery() {
    touch "$SANDBOX_ROOT/.no_auto_recovery"
    run_probes 000 5
    assert_equals "0" "$(restarts_logged)" \
        "operators who want to be the only thing that restarts their server need a switch"
}

# --- admin notification seam ----------------------------------------------

test_recovery_notifies_admins_through_the_extension_point() {
    run_probes 000 3
    assert_file_exists "$SANDBOX_ROOT/logs/recovery.log" \
        "every recovery must leave an operator-visible record"
    assert_contains "$(cat "$SANDBOX_ROOT/logs/recovery.log")" "RECOVERY" \
        "the notification seam must record that a recovery happened, so alerting can be attached to it later"
}

test_no_notification_when_nothing_was_recovered() {
    run_probes 200 3
    if [ -s "$SANDBOX_ROOT/logs/recovery.log" ]; then
        assert_not_contains_recovery
    fi
}

assert_not_contains_recovery() {
    if /usr/bin/grep -q "RECOVERY" "$SANDBOX_ROOT/logs/recovery.log" 2>/dev/null; then
        echo "Assertion failed: a healthy run must not announce a recovery"
        TEST_FAILED=true
    fi
}

# --- overridable action ----------------------------------------------------

test_recovery_command_is_overridable() {
    sandbox_run "recover" "export RECOVERY_PUMA_CODE=000" >/dev/null
    sandbox_run "recover" "export RECOVERY_PUMA_CODE=000" >/dev/null
    sandbox_run "recover" "export RECOVERY_PUMA_CODE=000; export RECOVERY_COMMAND='docker restart app'" >/dev/null

    harness_assert_called "docker restart app" \
        "the recovery action must be overridable so it can be exercised against containers in integration tests"
    assert_equals "0" "$(restarts_logged)" \
        "the override must replace the default action, not run alongside it"
}

test_probe_target_container_is_overridable() {
    sandbox_run "recover" "export RECOVERY_PUMA_CODE=200; export RECOVERY_CONTAINER='other-app'" >/dev/null
    harness_assert_called "exec other-app curl" \
        "the probed container must be overridable so integration tests can point at a disposable container"
}

#######################
# Runner
#######################

run_recovery_tests() {
    echo "Running Auto-Recovery Tests"
    echo "==========================="

    init_test_framework
    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_healthy_puma_never_restarts" test_healthy_puma_never_restarts
    run_test "test_two_consecutive_failures_do_not_restart" test_two_consecutive_failures_do_not_restart
    run_test "test_third_consecutive_failure_restarts_the_service" test_third_consecutive_failure_restarts_the_service
    run_test "test_a_success_resets_the_failure_count" test_a_success_resets_the_failure_count
    run_test "test_no_second_restart_within_the_cooldown" test_no_second_restart_within_the_cooldown
    run_test "test_restarts_again_after_the_cooldown_expires" test_restarts_again_after_the_cooldown_expires
    run_test "test_recovery_runs_even_when_health_reporting_is_disabled" test_recovery_runs_even_when_health_reporting_is_disabled
    run_test "test_kill_switch_disables_auto_recovery" test_kill_switch_disables_auto_recovery
    run_test "test_recovery_notifies_admins_through_the_extension_point" test_recovery_notifies_admins_through_the_extension_point
    run_test "test_no_notification_when_nothing_was_recovered" test_no_notification_when_nothing_was_recovered
    run_test "test_recovery_command_is_overridable" test_recovery_command_is_overridable
    run_test "test_probe_target_container_is_overridable" test_probe_target_container_is_overridable

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_recovery_tests
fi
