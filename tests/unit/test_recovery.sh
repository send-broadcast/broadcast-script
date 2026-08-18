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
    # docker mock:
    #   inspect .State.Running    -> RECOVERY_CONTAINER_RUNNING (default true)
    #   inspect .State.StartedAt  -> RECOVERY_STARTED_AT (default a fixed instant)
    #   an absent container is RECOVERY_CONTAINER_RUNNING=absent: no output, exit 1
    #   exec ... curl             -> RECOVERY_PUMA_CODE (default 200)
    harness_mock docker 'case "$*" in
  *inspect*State.Running*)
    if [ "${RECOVERY_CONTAINER_RUNNING:-true}" = "absent" ]; then exit 1; fi
    printf "%s" "${RECOVERY_CONTAINER_RUNNING:-true}"
    ;;
  *inspect*State.StartedAt*)
    if [ "${RECOVERY_CONTAINER_RUNNING:-true}" = "absent" ]; then exit 1; fi
    printf "%s" "${RECOVERY_STARTED_AT:-2026-08-01T00:00:00Z}"
    ;;
  exec\ *curl*)
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
        sandbox_run "recover" \
            "export RECOVERY_PUMA_CODE=$code; export RECOVERY_CONTAINER_RUNNING='${CONTAINER_RUNNING:-true}'; export RECOVERY_STARTED_AT='${STARTED_AT:-2026-08-01T00:00:00Z}'" >/dev/null
    done
}

# A container we have been watching for a while: past its boot grace, so the
# ordinary three-failure threshold governs. Most tests want this, because the
# failure they model is a server that has been up for days and then breaks.
settle_container() {
    run_probes 200 12
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
    settle_container
    run_probes 000 3
    assert_equals "1" "$(restarts_logged)" \
        "three consecutive failed Puma probes is the 2026-08-15 signature and must trigger recovery"
}

test_a_success_resets_the_failure_count() {
    settle_container
    run_probes 000 2
    run_probes 200 1
    run_probes 000 2
    assert_equals "0" "$(restarts_logged)" \
        "failures must be CONSECUTIVE; an intervening success resets the count"
}

# --- flap guard ------------------------------------------------------------

test_no_second_restart_within_the_cooldown() {
    settle_container
    run_probes 000 3
    run_probes 000 3
    assert_equals "1" "$(restarts_logged)" \
        "a server that cannot stay up must be restarted once and left alone, not flapped every three minutes"
}

test_restarts_again_after_the_cooldown_expires() {
    settle_container
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
    settle_container
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
    settle_container
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
    settle_container
    run_probes 000 2
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

# --- container-state guard -------------------------------------------------
#
# `upgrade` runs: systemctl stop broadcast (compose down removes the
# containers) -> docker compose pull -> systemctl start broadcast. Between the
# stop and the start there is NO app container, and the image pull sits in the
# middle of it, so that window is minutes rather than seconds. A probe cannot
# reach Puma because there is nothing to reach, which is indistinguishable from
# the outage unless recovery looks at the container itself.

test_does_not_act_when_the_container_is_absent() {
    settle_container
    CONTAINER_RUNNING=absent run_probes 000 6
    assert_equals "0" "$(restarts_logged)" \
        "an absent container is an upgrade or a stop, not an outage -- restarting the service here fights the upgrade that removed it"
}

test_does_not_act_when_the_container_is_not_running() {
    settle_container
    CONTAINER_RUNNING=false run_probes 000 6
    assert_equals "0" "$(restarts_logged)" \
        "a stopped container is Docker's business; restart: always owns that case"
}

test_still_acts_when_the_container_is_running() {
    settle_container
    run_probes 000 3
    assert_equals "1" "$(restarts_logged)" \
        "the guard must not swallow the case it exists for: container Running, Puma dead"
}

# --- boot grace ------------------------------------------------------------
#
# A freshly started container is booting, not broken. Migrations run before Puma
# listens, and to a probe that only asks "is Puma answering" the two look the
# same. Measured in probes rather than seconds so it is the same unit the cron
# cadence uses (one probe per minute) and tests can exercise it without sleeping.

test_does_not_act_within_the_boot_grace_of_a_new_container() {
    settle_container
    # A new container instance: same name, new StartedAt.
    STARTED_AT=2026-08-02T00:00:00Z run_probes 000 5
    assert_equals "0" "$(restarts_logged)" \
        "five failed probes against a just-started container is a slow boot, not an outage"
}

test_acts_once_the_boot_grace_has_passed() {
    settle_container
    STARTED_AT=2026-08-02T00:00:00Z run_probes 000 12
    assert_equals "1" "$(restarts_logged)" \
        "the grace must expire; a container that is still dead long after starting is genuinely broken"
}

test_a_restarted_container_gets_a_fresh_boot_grace() {
    settle_container
    run_probes 000 3
    assert_equals "1" "$(restarts_logged)" "precondition: the first recovery fired"

    # The restart produces a new container instance. Its boot must be protected
    # again -- otherwise recovery restarts the thing it just restarted.
    STARTED_AT=2026-08-03T00:00:00Z run_probes 000 5
    assert_equals "1" "$(restarts_logged)" \
        "the container recovery just restarted must get its own boot grace"
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
    run_test "test_does_not_act_when_the_container_is_absent" test_does_not_act_when_the_container_is_absent
    run_test "test_does_not_act_when_the_container_is_not_running" test_does_not_act_when_the_container_is_not_running
    run_test "test_still_acts_when_the_container_is_running" test_still_acts_when_the_container_is_running
    run_test "test_does_not_act_within_the_boot_grace_of_a_new_container" test_does_not_act_within_the_boot_grace_of_a_new_container
    run_test "test_acts_once_the_boot_grace_has_passed" test_acts_once_the_boot_grace_has_passed
    run_test "test_a_restarted_container_gets_a_fresh_boot_grace" test_a_restarted_container_gets_a_fresh_boot_grace

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_recovery_tests
fi
