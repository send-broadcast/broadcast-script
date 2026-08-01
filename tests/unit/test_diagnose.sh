#!/bin/bash

# Unit tests for the diagnose() support-bundle command (scripts/diagnose.sh).
# Written TDD-first from broadcast/TROUBLESHOOT.md (firstborngroup 520 case):
# the command must capture evidence BEFORE anything can destroy it, filter
# Thruster access-log noise so crashes surface, probe each layer separately
# (Puma direct, Thruster HTTP, HTTPS origin), and interpret the
# Thruster-up/Puma-down fingerprint that cost that customer a 2-day outage.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    mkdir -p "$SANDBOX_ROOT/logs"

    # docker: emits canned container logs (app log includes Thruster access
    # noise around a Puma crash line) and a Puma probe controlled by
    # DIAGNOSE_PUMA_CODE. Everything else succeeds quietly.
    harness_mock docker 'case "$*" in
  "logs app")
    echo "{\"msg\":\"Request\",\"path\":\"/track/open/1\"}"
    echo "{\"msg\":\"Request\",\"path\":\"/webhooks/ses\"}"
    echo "Puma caught this error: Broken pipe (Errno::EPIPE)"
    echo "{\"msg\":\"Request\",\"path\":\"/track/click/2\"}"
    ;;
  "logs job") echo "job container log line" ;;
  "logs postgres") echo "postgres container log line" ;;
  exec\ app\ curl*)
    printf "%s" "${DIAGNOSE_PUMA_CODE:-200}"
    if [ "${DIAGNOSE_PUMA_CODE:-200}" = "000" ]; then exit 7; fi
    ;;
  ps*) echo "NAMES STATUS: app Up 2 days" ;;
  stats*) echo "NAME CPU MEM: app 1% 512MB" ;;
esac
exit 0'
    # journalctl is Linux-only; canned output via JOURNALCTL_MOCK
    harness_mock journalctl 'echo "${JOURNALCTL_MOCK:-}"'
    # System metrics (free does not exist on macOS)
    harness_mock free 'echo "Mem: 8000 4000 4000"'
    harness_mock df 'echo "/dev/root 100G 40G 60G 40% /"'
    harness_mock uptime 'echo " 12:00:00 up 10 days, load average: 0.50, 0.40, 0.30"'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

# The single diagnose-<timestamp> bundle directory created by the run
bundle_dir() {
    ls -d "$SANDBOX_ROOT/logs/diagnose-"*/ 2>/dev/null | head -1
}

test_diagnose_creates_bundle_and_tarball() {
    local rc=0
    sandbox_run "diagnose" >/dev/null || rc=$?
    assert_equals "0" "$rc" "diagnose should exit 0"

    local dir
    dir=$(bundle_dir)
    if [ -z "$dir" ]; then
        assert_equals "bundle dir" "missing" "a diagnose-<timestamp> directory should exist under logs/"
        return 0
    fi

    local tarball
    tarball=$(ls "$SANDBOX_ROOT/logs/"diagnose-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "1" "$tarball" "a tarball of the bundle should be produced for emailing"
}

test_diagnose_captures_full_container_logs_first() {
    sandbox_run "diagnose" >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_file_exists "${dir}app.log" "full app log must be captured"
    assert_file_exists "${dir}job.log" "full job log must be captured"
    assert_file_exists "${dir}postgres.log" "full postgres log must be captured"

    assert_contains "$(cat "${dir}app.log")" "Puma caught this error" \
        "the raw app log must contain the crash evidence"

    # Full dump, never --tail: a days-old crash scrolls out of any tail
    harness_assert_not_called "docker logs --tail" \
        "log capture must be a full dump, not a tail"

    # Evidence before probes: log capture must precede any docker exec probe
    harness_assert_call_order "docker logs app" "docker exec app curl"
}

test_diagnose_filters_thruster_noise_from_app_log() {
    sandbox_run "diagnose" >/dev/null

    local dir filtered
    dir=$(bundle_dir)
    assert_file_exists "${dir}app-filtered.log" "a filtered app log must be produced"
    filtered=$(cat "${dir}app-filtered.log")

    assert_contains "$filtered" "Puma caught this error" \
        "the crash line must survive the filter"
    if [[ "$filtered" == *'"msg":"Request"'* ]]; then
        assert_equals "noise removed" "noise present" \
            "Thruster access-log lines must be filtered out"
    fi
}

test_diagnose_records_layered_probes() {
    sandbox_run "diagnose" 'export DIAGNOSE_PUMA_CODE=200
export CURL_MOCK_HTTP_CODE=200' >/dev/null

    local dir probes
    dir=$(bundle_dir)
    assert_file_exists "${dir}probes.txt" "probe results must be recorded"
    probes=$(cat "${dir}probes.txt")

    assert_contains "$probes" "Puma" "the direct Puma probe must be recorded"
    assert_contains "$probes" "Thruster" "the Thruster HTTP probe must be recorded"
    assert_contains "$probes" "test.example.com" \
        "the HTTPS origin probe must use the installation domain"

    # The HTTPS origin probe must use --resolve (Host-header curls break SNI)
    harness_assert_called "--resolve test.example.com:443:127.0.0.1" \
        "HTTPS origin probe must pin the domain to localhost via --resolve"
}

test_diagnose_flags_thruster_up_puma_down_fingerprint() {
    local output
    output=$(sandbox_run "diagnose" 'export DIAGNOSE_PUMA_CODE=000
export CURL_MOCK_HTTP_CODE=502')

    local dir summary
    dir=$(bundle_dir)
    assert_file_exists "${dir}summary.txt" "an interpretation summary must be written"
    summary=$(cat "${dir}summary.txt")

    assert_contains "$summary" "Puma" "the summary must name the dead layer"
    assert_contains "$summary" "Thruster" "the summary must name the surviving layer"
    assert_contains "$output" "Puma" "the fingerprint must also be printed to the operator"
}

test_diagnose_reports_healthy_when_all_probes_pass() {
    sandbox_run "diagnose" 'export DIAGNOSE_PUMA_CODE=200
export CURL_MOCK_HTTP_CODE=200' >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_contains "$(cat "${dir}summary.txt")" "healthy" \
        "all-200 probes should be summarized as healthy"
}

test_diagnose_treats_thruster_301_redirect_as_healthy() {
    # On a healthy install, plain-HTTP /up gets Thruster's 301 redirect to
    # HTTPS — proof Thruster is alive, not a failure (TROUBLESHOOT.md,
    # confirmed on a real installation 2026-08-01). Puma 200 + Thruster 301
    # must read as healthy, not "Thruster HTTP probe failed".
    sandbox_run "diagnose" 'export DIAGNOSE_PUMA_CODE=200
export CURL_MOCK_HTTP_CODE=301' >/dev/null

    local dir summary
    dir=$(bundle_dir)
    summary=$(cat "${dir}summary.txt")
    assert_contains "$summary" "healthy" \
        "Puma 200 + Thruster 301 is a healthy system"
    if [[ "$summary" == *"probe failed"* ]]; then
        assert_equals "healthy verdict" "false alarm" \
            "a 301 redirect must not be reported as a failed probe"
    fi
}

test_diagnose_prints_copy_paste_report() {
    # Customers paste better than they attach (TROUBLESHOOT.md friction 6):
    # stdout must end with a clearly delimited report — summary, probes,
    # container/system state, and the filtered log tail — that a customer
    # can copy into a support email without touching the tarball.
    local output
    output=$(sandbox_run "diagnose")

    assert_contains "$output" "COPY" "the report must be visibly delimited for copying"
    assert_contains "$output" "Puma direct" "the report must include the probe results"
    assert_contains "$output" "Puma caught this error" \
        "the report must include the filtered app log so crashes travel in the paste"
}

test_diagnose_includes_oom_check_and_system_state() {
    sandbox_run "diagnose" 'export JOURNALCTL_MOCK="kernel: Out of memory: Killed process 1234 (ruby)"' >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_file_exists "${dir}oom.txt" "the kernel OOM check must be recorded"
    assert_contains "$(cat "${dir}oom.txt")" "Out of memory" \
        "OOM events must be captured when present"

    assert_file_exists "${dir}system.txt" "disk/memory/load state must be recorded"
    assert_file_exists "${dir}docker-ps.txt" "container state must be recorded"
}

test_diagnose_survives_every_collector_failing() {
    # A diagnose that dies mid-collection is worse than useless — it must
    # produce whatever bundle it can and still exit 0.
    harness_mock docker 'exit 1'
    harness_mock journalctl 'exit 1'
    harness_mock curl 'exit 7'
    rm -f "$SANDBOX_ROOT/.domain"

    local rc=0
    sandbox_run "diagnose" >/dev/null || rc=$?
    assert_equals "0" "$rc" "diagnose must exit 0 even when every collector fails"

    local dir
    dir=$(bundle_dir)
    if [ -z "$dir" ]; then
        assert_equals "bundle dir" "missing" "a bundle should exist even on total failure"
    fi
}

run_diagnose_tests() {
    echo "Running Diagnose Command Tests"
    echo "=============================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_diagnose_creates_bundle_and_tarball" test_diagnose_creates_bundle_and_tarball
    run_test "test_diagnose_captures_full_container_logs_first" test_diagnose_captures_full_container_logs_first
    run_test "test_diagnose_filters_thruster_noise_from_app_log" test_diagnose_filters_thruster_noise_from_app_log
    run_test "test_diagnose_records_layered_probes" test_diagnose_records_layered_probes
    run_test "test_diagnose_flags_thruster_up_puma_down_fingerprint" test_diagnose_flags_thruster_up_puma_down_fingerprint
    run_test "test_diagnose_reports_healthy_when_all_probes_pass" test_diagnose_reports_healthy_when_all_probes_pass
    run_test "test_diagnose_treats_thruster_301_redirect_as_healthy" test_diagnose_treats_thruster_301_redirect_as_healthy
    run_test "test_diagnose_prints_copy_paste_report" test_diagnose_prints_copy_paste_report
    run_test "test_diagnose_includes_oom_check_and_system_state" test_diagnose_includes_oom_check_and_system_state
    run_test "test_diagnose_survives_every_collector_failing" test_diagnose_survives_every_collector_failing

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_diagnose_tests
fi
