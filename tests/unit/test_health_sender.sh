#!/bin/bash

# Unit tests for the health sender (scripts/health.sh), written TDD-first.
# The sender runs from cron every minute and reports to sendbroadcast.net's
# /health/report endpoint. Design contract under test:
#   - probes every run; 3 consecutive failures before declaring unhealthy
#     (hysteresis against flaps)
#   - status TRANSITIONS send immediately; steady-state heartbeats send
#     only every heartbeat_interval seconds (server-steered)
#   - send failures back off exponentially and drop reports (lossy — no
#     queued backlog that would spike the server on recovery)
#   - a "monitoring disabled" response silences sends for an hour
#   - payload carries probes + whitelisted system facts, nothing else

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    echo "test-license-key" > "$SANDBOX_ROOT/.license"
    echo "2.23.0" > "$SANDBOX_ROOT/.current_version"

    # docker: Puma probe controlled by HEALTH_PUMA_CODE
    harness_mock docker 'case "$*" in
  exec\ app\ curl*)
    printf "%s" "${HEALTH_PUMA_CODE:-200}"
    if [ "${HEALTH_PUMA_CODE:-200}" = "000" ]; then exit 7; fi
    ;;
esac
exit 0'
    # curl: the /health/report send returns a JSON body (controllable);
    # probe curls return a plain status code like the harness default
    harness_mock curl 'case "$*" in
  *health/report*)
    if [ "${HEALTH_SEND_RC:-0}" != "0" ]; then exit "${HEALTH_SEND_RC}"; fi
    printf "%s" "${HEALTH_MOCK_RESPONSE:-{\"monitoring\":\"enabled\",\"heartbeat_interval\":300}}"
    ;;
  *)
    printf "%s" "${CURL_MOCK_HTTP_CODE:-301}"
    ;;
esac
exit 0'
    # System fact sources
    harness_mock nproc 'echo 2'
    harness_mock uptime 'echo " 12:00:00 up 10 days, load average: 0.52, 0.40, 0.30"'
    harness_mock free 'printf "               total        used\nMem:      8000000000  4000000000\n"'
    harness_mock df 'printf "Filesystem Size Used Avail Use%%%% Mounted\n/dev/root 100G 42G 58G 42%%%% /\n"'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

sends_logged() {
    /usr/bin/grep -c "health/report" "$SANDBOX_CALLS" || true
}

test_first_run_sends_a_healthy_heartbeat_with_system_facts() {
    local rc=0
    sandbox_run "health" >/dev/null || rc=$?
    assert_equals "0" "$rc" "health should exit 0"

    assert_equals "1" "$(sends_logged)" "the first run must report in"
    harness_assert_called "key=test-license-key" "the license key must authenticate the report"
    harness_assert_called "domain=test.example.com" "the domain must identify the install"
    harness_assert_called "status=healthy" "a healthy probe must report healthy"
    harness_assert_called "system[disk_used_percent]=42" "disk usage must be included"
    harness_assert_called "system[version]=2.23.0" "the Broadcast version must be included"
    harness_assert_called "system[reboot_required]=false" "reboot state must be included"
    harness_assert_called "https://sendbroadcast.net/health/report" \
        "the default endpoint must be the production API"
}

test_reports_reboot_required_when_flag_file_exists() {
    touch "$SANDBOX_ROOT/var/run/reboot-required"

    sandbox_run "health" >/dev/null

    harness_assert_called "system[reboot_required]=true" \
        "the reboot-required flag file must be reported"
}

test_second_run_within_interval_stays_quiet() {
    sandbox_run "health" >/dev/null
    sandbox_run "health" >/dev/null

    assert_equals "1" "$(sends_logged)" \
        "a steady-state run inside the heartbeat interval must not send"
}

test_server_steers_the_heartbeat_interval() {
    sandbox_run "health" 'export HEALTH_MOCK_RESPONSE="{\"monitoring\":\"enabled\",\"heartbeat_interval\":60}"' >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.health_state")" "heartbeat_interval=60" \
        "the interval from the server response must be persisted"
}

test_hysteresis_needs_three_failures_before_unhealthy() {
    sandbox_run "health" >/dev/null # healthy baseline

    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    assert_equals "1" "$(sends_logged)" \
        "one or two failed probes must not yet report unhealthy (flap guard)"

    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    assert_equals "2" "$(sends_logged)" \
        "the third consecutive failure must send immediately (transition)"
    harness_assert_called "status=unhealthy" "the transition must report unhealthy"
    harness_assert_called "probes[puma]=000" "probe results must travel with the alert"
}

test_recovery_sends_immediately() {
    sandbox_run "health" >/dev/null
    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null

    sandbox_run "health" >/dev/null # healthy again

    assert_equals "3" "$(sends_logged)" "recovery must send immediately"
    assert_contains "$(cat "$SANDBOX_ROOT/.health_state")" "last_status=healthy" \
        "the recovered status must be recorded"
}

test_steady_unhealthy_does_not_respam() {
    local i
    for i in 1 2 3 4 5; do
        sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    done

    # First run sends (first report), third failure would be a transition —
    # but the first report already said unhealthy, so only ONE send total
    assert_equals "1" "$(sends_logged)" \
        "an install that stays unhealthy must not spam the server every minute"
}

test_disabled_response_silences_sends_for_an_hour() {
    sandbox_run "health" 'export HEALTH_MOCK_RESPONSE="{\"monitoring\":\"disabled\"}"' >/dev/null
    sandbox_run "health" >/dev/null
    sandbox_run "health" >/dev/null

    assert_equals "1" "$(sends_logged)" \
        "after a disabled response, later runs must stay silent"
    assert_contains "$(cat "$SANDBOX_ROOT/.health_state")" "disabled_until=" \
        "the silence window must be persisted"
}

test_send_failure_backs_off_and_drops() {
    sandbox_run "health" 'export HEALTH_SEND_RC=7' >/dev/null
    local rc=0
    sandbox_run "health" >/dev/null || rc=$?

    assert_equals "0" "$rc" "a failed send must never fail the cron run"
    assert_equals "1" "$(sends_logged)" \
        "during backoff no further sends may be attempted"
    assert_contains "$(cat "$SANDBOX_ROOT/.health_state")" "backoff_until=" \
        "the backoff window must be persisted"
}

test_endpoint_is_overridable_for_testing() {
    sandbox_run "health" 'export BROADCAST_HEALTH_URL="http://localhost:3002/health/report"' >/dev/null

    harness_assert_called "http://localhost:3002/health/report" \
        "BROADCAST_HEALTH_URL must override the endpoint"
}

run_health_sender_tests() {
    echo "Running Health Sender Tests"
    echo "==========================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_first_run_sends_a_healthy_heartbeat_with_system_facts" test_first_run_sends_a_healthy_heartbeat_with_system_facts
    run_test "test_reports_reboot_required_when_flag_file_exists" test_reports_reboot_required_when_flag_file_exists
    run_test "test_second_run_within_interval_stays_quiet" test_second_run_within_interval_stays_quiet
    run_test "test_server_steers_the_heartbeat_interval" test_server_steers_the_heartbeat_interval
    run_test "test_hysteresis_needs_three_failures_before_unhealthy" test_hysteresis_needs_three_failures_before_unhealthy
    run_test "test_recovery_sends_immediately" test_recovery_sends_immediately
    run_test "test_steady_unhealthy_does_not_respam" test_steady_unhealthy_does_not_respam
    run_test "test_disabled_response_silences_sends_for_an_hour" test_disabled_response_silences_sends_for_an_hour
    run_test "test_send_failure_backs_off_and_drops" test_send_failure_backs_off_and_drops
    run_test "test_endpoint_is_overridable_for_testing" test_endpoint_is_overridable_for_testing

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_health_sender_tests
fi
