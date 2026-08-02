#!/bin/bash

# Unit tests for the health sender (scripts/health.sh), written TDD-first.
# The sender runs from cron every minute and reports to sendbroadcast.net's
# /health/report endpoint. Design contract under test:
#   - TRANSMISSION is opt-in, not just storage: until the server has said
#     monitoring is enabled, the install sends only a key+domain handshake
#     (no status, no probes, no system facts), at most hourly
#   - a .no_health_reports flag file silences the sender entirely — the
#     verifiable zero-phone-home switch, managed by monitor-enable/disable
#   - once enabled: probes every run; 3 consecutive failures before
#     declaring unhealthy (hysteresis); transitions send immediately;
#     steady-state heartbeats send only every heartbeat_interval seconds
#     (server-steered); failed sends back off exponentially and drop
#   - a "monitoring disabled" response returns the install to handshake
#     mode, silent for an hour

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

# --- opt-in transmission ---------------------------------------------------

test_fresh_install_handshakes_without_any_health_data() {
    local rc=0
    sandbox_run "health" >/dev/null || rc=$?
    assert_equals "0" "$rc" "health should exit 0"

    assert_equals "1" "$(sends_logged)" "the first run should hand-shake"
    harness_assert_called "key=test-license-key" "the handshake authenticates with the key"
    harness_assert_called "domain=test.example.com" "the handshake identifies the install"
    harness_assert_not_called "status=" "no status may leave before opt-in is confirmed"
    harness_assert_not_called "probes[" "no probe data may leave before opt-in is confirmed"
    harness_assert_not_called "system[" "no system facts may leave before opt-in is confirmed"
    harness_assert_called "https://sendbroadcast.net/health/report" \
        "the default endpoint must be the production API"
}

test_full_report_follows_an_enabled_handshake() {
    sandbox_run "health" >/dev/null   # handshake -> enabled
    sandbox_run "health" >/dev/null   # first full report

    assert_equals "2" "$(sends_logged)" "the run after an enabled handshake reports fully"
    harness_assert_called "status=healthy" "a healthy probe must report healthy"
    harness_assert_called "system[disk_used_percent]=42" "disk usage must be included"
    harness_assert_called "system[version]=2.23.0" "the Broadcast version must be included"
    harness_assert_called "system[reboot_required]=false" "reboot state must be included"
}

test_disabled_handshake_stays_in_handshake_mode_for_an_hour() {
    sandbox_run "health" 'export HEALTH_MOCK_RESPONSE="{\"monitoring\":\"disabled\"}"' >/dev/null
    sandbox_run "health" >/dev/null
    sandbox_run "health" >/dev/null

    assert_equals "1" "$(sends_logged)" \
        "after a disabled handshake, later runs must stay silent for the hour"
    harness_assert_not_called "status=" "a non-opted install must never send health data"
    assert_contains "$(cat "$SANDBOX_ROOT/.health_state")" "disabled_until=" \
        "the silence window must be persisted"
}

test_kill_switch_silences_the_sender_entirely() {
    touch "$SANDBOX_ROOT/.no_health_reports"

    local rc=0
    sandbox_run "health" >/dev/null || rc=$?
    assert_equals "0" "$rc" "the silenced sender must still exit 0 for cron"

    assert_equals "0" "$(sends_logged)" \
        "with the kill switch set, nothing may be sent — not even a handshake"
}

test_existing_reporting_installs_skip_the_handshake() {
    # Installs that were already reporting before handshake mode existed
    # have last_status but no server_enabled marker — they must continue
    # reporting without regressing into handshake mode.
    cat > "$SANDBOX_ROOT/.health_state" <<'STATE'
last_status=healthy
consecutive_failures=0
last_heartbeat=0
heartbeat_interval=300
disabled_until=0
backoff_until=0
send_failures=0
STATE

    sandbox_run "health" >/dev/null

    assert_equals "1" "$(sends_logged)" "a migrated install reports on its first run"
    harness_assert_called "status=healthy" "the migrated install sends a full report"
}

# --- enabled-mode behavior -------------------------------------------------

test_reports_reboot_required_when_flag_file_exists() {
    touch "$SANDBOX_ROOT/var/run/reboot-required"

    sandbox_run "health" >/dev/null
    sandbox_run "health" >/dev/null

    harness_assert_called "system[reboot_required]=true" \
        "the reboot-required flag file must be reported"
}

test_steady_state_stays_quiet_within_the_heartbeat_interval() {
    sandbox_run "health" >/dev/null   # handshake
    sandbox_run "health" >/dev/null   # full report
    sandbox_run "health" >/dev/null   # within interval

    assert_equals "2" "$(sends_logged)" \
        "a steady-state run inside the heartbeat interval must not send"
}

test_server_steers_the_heartbeat_interval() {
    sandbox_run "health" 'export HEALTH_MOCK_RESPONSE="{\"monitoring\":\"enabled\",\"heartbeat_interval\":60}"' >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.health_state")" "heartbeat_interval=60" \
        "the interval from the server response must be persisted"
}

test_hysteresis_needs_three_failures_before_unhealthy() {
    sandbox_run "health" >/dev/null   # handshake
    sandbox_run "health" >/dev/null   # healthy baseline

    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    assert_equals "2" "$(sends_logged)" \
        "one or two failed probes must not yet report unhealthy (flap guard)"

    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    assert_equals "3" "$(sends_logged)" \
        "the third consecutive failure must send immediately (transition)"
    harness_assert_called "status=unhealthy" "the transition must report unhealthy"
    harness_assert_called "probes[puma]=000" "probe results must travel with the alert"
}

test_recovery_sends_immediately() {
    sandbox_run "health" >/dev/null
    sandbox_run "health" >/dev/null
    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null

    sandbox_run "health" >/dev/null # healthy again

    assert_equals "4" "$(sends_logged)" "recovery must send immediately"
    assert_contains "$(cat "$SANDBOX_ROOT/.health_state")" "last_status=healthy" \
        "the recovered status must be recorded"
}

test_steady_unhealthy_does_not_respam() {
    local i
    for i in 1 2 3 4 5 6; do
        sandbox_run "health" 'export HEALTH_PUMA_CODE=000' >/dev/null
    done

    # Handshake, then two silent failures, then ONE unhealthy report;
    # steady unhealthy after that stays quiet
    assert_equals "2" "$(sends_logged)" \
        "an install that stays unhealthy must not spam the server every minute"
}

test_send_failure_backs_off_and_drops() {
    sandbox_run "health" >/dev/null   # handshake -> enabled

    sandbox_run "health" 'export HEALTH_SEND_RC=7' >/dev/null
    local rc=0
    sandbox_run "health" >/dev/null || rc=$?

    assert_equals "0" "$rc" "a failed send must never fail the cron run"
    assert_equals "2" "$(sends_logged)" \
        "during backoff no further sends may be attempted"
    assert_contains "$(cat "$SANDBOX_ROOT/.health_state")" "backoff_until=" \
        "the backoff window must be persisted"
}

test_endpoint_is_overridable_for_testing() {
    sandbox_run "health" 'export BROADCAST_HEALTH_URL="http://localhost:3002/health/report"' >/dev/null

    harness_assert_called "http://localhost:3002/health/report" \
        "BROADCAST_HEALTH_URL must override the endpoint"
}

# --- monitor-enable / monitor-disable --------------------------------------

test_monitor_disable_sets_the_kill_switch() {
    local output
    output=$(sandbox_run "monitor_disable")

    assert_file_exists "$SANDBOX_ROOT/.no_health_reports" "the flag file must be created"
    assert_contains "$output" "monitor-enable" "the way back must be mentioned"

    sandbox_run "health" >/dev/null
    assert_equals "0" "$(sends_logged)" "after disable, health must send nothing"
}

test_monitor_enable_clears_the_switch_and_checks_in_immediately() {
    touch "$SANDBOX_ROOT/.no_health_reports"
    cat > "$SANDBOX_ROOT/.health_state" <<'STATE'
last_status=
consecutive_failures=0
last_heartbeat=0
heartbeat_interval=300
disabled_until=9999999999
backoff_until=9999999999
send_failures=3
server_enabled=0
STATE

    local output
    output=$(sandbox_run "monitor_enable")

    assert_file_not_exists "$SANDBOX_ROOT/.no_health_reports" "the flag file must be removed"
    assert_equals "1" "$(sends_logged)" \
        "enable must clear the silence windows and check in immediately"
    assert_contains "$output" "dashboard" \
        "the user must be reminded the dashboard toggle also has to be on"
}

run_health_sender_tests() {
    echo "Running Health Sender Tests"
    echo "==========================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_fresh_install_handshakes_without_any_health_data" test_fresh_install_handshakes_without_any_health_data
    run_test "test_full_report_follows_an_enabled_handshake" test_full_report_follows_an_enabled_handshake
    run_test "test_disabled_handshake_stays_in_handshake_mode_for_an_hour" test_disabled_handshake_stays_in_handshake_mode_for_an_hour
    run_test "test_kill_switch_silences_the_sender_entirely" test_kill_switch_silences_the_sender_entirely
    run_test "test_existing_reporting_installs_skip_the_handshake" test_existing_reporting_installs_skip_the_handshake
    run_test "test_reports_reboot_required_when_flag_file_exists" test_reports_reboot_required_when_flag_file_exists
    run_test "test_steady_state_stays_quiet_within_the_heartbeat_interval" test_steady_state_stays_quiet_within_the_heartbeat_interval
    run_test "test_server_steers_the_heartbeat_interval" test_server_steers_the_heartbeat_interval
    run_test "test_hysteresis_needs_three_failures_before_unhealthy" test_hysteresis_needs_three_failures_before_unhealthy
    run_test "test_recovery_sends_immediately" test_recovery_sends_immediately
    run_test "test_steady_unhealthy_does_not_respam" test_steady_unhealthy_does_not_respam
    run_test "test_send_failure_backs_off_and_drops" test_send_failure_backs_off_and_drops
    run_test "test_endpoint_is_overridable_for_testing" test_endpoint_is_overridable_for_testing
    run_test "test_monitor_disable_sets_the_kill_switch" test_monitor_disable_sets_the_kill_switch
    run_test "test_monitor_enable_clears_the_switch_and_checks_in_immediately" test_monitor_enable_clears_the_switch_and_checks_in_immediately

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_health_sender_tests
fi
