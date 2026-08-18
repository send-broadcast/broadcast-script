#!/bin/bash

# Unit tests for the real monitor() function in scripts/monitor.sh.
# The Linux-only metric commands (nproc, free, df -B1, uptime) are shimmed
# with fixed outputs so the arithmetic and JSON assembly under test are the
# real script's. The `su` shim executes its command string so the JSON write
# actually lands in the sandbox.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

MONITOR_JSON=""

setup_sandbox() {
    harness_make_sandbox
    MONITOR_JSON="$SANDBOX_ROOT/app/monitor/system.json"

    # Fixed metric outputs: 4 cores, load 1.50, 8GB RAM with 2GB used
    # (75% free), 100GB disk with 40GB used (60% free)
    harness_mock nproc 'echo 4'
    harness_mock uptime 'echo " 12:00:00 up 10 days,  2:11,  1 user,  load average: 1.50, 1.20, 1.00"'
    harness_mock free 'printf "               total        used        free\nMem:      8000000000  2000000000  6000000000\n"'
    harness_mock df 'if [ "${1:-}" = "-B1" ]; then
  printf "Filesystem 1B-blocks Used Available Use%%%% Mounted\n/dev/root 100000000000 40000000000 60000000000 40%%%% /\n"
else
  printf "Filesystem Size Used Avail Use%%%% Mounted\n/dev/root 100G 40G 60G 40%%%% /\n"
fi'
    # monitor() writes through `su - broadcast -c "<cmd>"`; execute the
    # command string so the redirect into app/monitor/system.json happens.
    # docker: fd count for the app container's processes, and the soft limit
    harness_mock docker 'case "$*" in
  *proc*fd*) echo 412 ;;
  *ulimit*) echo 65536 ;;
esac
exit 0'
    harness_mock su 'bash -c "${@: -1}"'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

test_monitor_writes_valid_json() {
    echo "2.1.0" > "$SANDBOX_ROOT/.current_version"

    local rc=0
    sandbox_run "monitor" >/dev/null || rc=$?
    assert_equals "0" "$rc" "monitor should succeed"

    assert_file_exists "$MONITOR_JSON" "system.json should be written"
    if ! jq empty "$MONITOR_JSON" 2>/dev/null; then
        assert_equals "valid JSON" "invalid JSON" "system.json must parse as JSON"
        return 0
    fi
}

test_monitor_reports_expected_metrics() {
    echo "2.1.0" > "$SANDBOX_ROOT/.current_version"
    sandbox_run "monitor" >/dev/null

    assert_equals "4" "$(jq -r .cpu_cores "$MONITOR_JSON")" "cpu_cores from nproc"
    assert_equals "1.50" "$(jq -r .cpu_load "$MONITOR_JSON")" "cpu_load parsed from uptime"
    assert_equals "8000000000" "$(jq -r .memory_total "$MONITOR_JSON")" "memory_total from free"
    assert_equals "2000000000" "$(jq -r .memory_used "$MONITOR_JSON")" "memory_used from free"
    assert_equals "75.00" "$(jq -r .memory_free_percent "$MONITOR_JSON")" \
        "free memory percentage should be computed from total/used"
    assert_equals "100000000000" "$(jq -r .disk_space_total "$MONITOR_JSON")" "disk total from df -B1"
    assert_equals "40000000000" "$(jq -r .disk_space_used "$MONITOR_JSON")" "disk used from df -B1"
    assert_equals "60" "$(jq -r .disk_space_free_percent "$MONITOR_JSON")" \
        "disk free percent should be 100 minus df use%"
    assert_equals "2.1.0" "$(jq -r .current_version "$MONITOR_JSON")" "version from .current_version"
}

# The 2026-08-15 outage was file-descriptor exhaustion in the app process, and
# nothing on the box recorded fd usage -- so we could not tell a burst that
# exhausted a low ceiling from a slow leak that had been climbing for days. The
# daily 09:00 UTC webhook burst means a per-burst leak shows as a step change
# within a day or two, but only if something is counting.
test_monitor_reports_app_file_descriptors() {
    sandbox_run "monitor" >/dev/null

    assert_equals "412" "$(jq -r .app_open_files "$MONITOR_JSON")" \
        "open descriptor count for the app container must be recorded"
    assert_equals "65536" "$(jq -r .app_open_files_limit "$MONITOR_JSON")" \
        "the ceiling must be recorded too -- a count means nothing without it"
}

test_monitor_reports_unknown_descriptors_when_the_container_is_down() {
    harness_mock docker 'exit 1'
    sandbox_run "monitor" >/dev/null

    assert_equals "0" "$(jq -r .app_open_files "$MONITOR_JSON")" \
        "an unreachable container must not break the metrics file"
}

test_monitor_reports_unknown_version_without_version_file() {
    rm -f "$SANDBOX_ROOT/.current_version"
    sandbox_run "monitor" >/dev/null

    assert_equals "unknown" "$(jq -r .current_version "$MONITOR_JSON")" \
        "missing .current_version should be reported as unknown"
}

test_monitor_writes_as_broadcast_user() {
    echo "2.1.0" > "$SANDBOX_ROOT/.current_version"
    sandbox_run "monitor" >/dev/null

    harness_assert_called "su - broadcast" \
        "the JSON write must go through the broadcast user"
}

test_monitor_prints_metrics_when_run_interactively() {
    # Manual runs should confirm what was written; the terminal check is
    # behind monitor_output_is_terminal so it can be forced here.
    echo "2.1.0" > "$SANDBOX_ROOT/.current_version"
    local output
    output=$(sandbox_run 'monitor_output_is_terminal() { return 0; }
monitor')

    assert_contains "$output" "system.json" "interactive runs should name the output file"
    assert_contains "$output" "cpu_cores" "interactive runs should show the metrics written"
}

test_monitor_stays_silent_for_cron() {
    # Cron runs every minute with stdout appended to a log file — success
    # must produce no output there.
    echo "2.1.0" > "$SANDBOX_ROOT/.current_version"
    local output
    output=$(sandbox_run 'monitor_output_is_terminal() { return 1; }
monitor')

    assert_equals "" "$output" "non-interactive runs must stay silent"
}

run_monitor_tests() {
    echo "Running Monitor Function Tests"
    echo "=============================="

    init_test_framework

    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_monitor_writes_valid_json" test_monitor_writes_valid_json
    run_test "test_monitor_reports_expected_metrics" test_monitor_reports_expected_metrics
    run_test "test_monitor_reports_app_file_descriptors" test_monitor_reports_app_file_descriptors
    run_test "test_monitor_reports_unknown_descriptors_when_the_container_is_down" test_monitor_reports_unknown_descriptors_when_the_container_is_down
    run_test "test_monitor_reports_unknown_version_without_version_file" test_monitor_reports_unknown_version_without_version_file
    run_test "test_monitor_writes_as_broadcast_user" test_monitor_writes_as_broadcast_user
    run_test "test_monitor_prints_metrics_when_run_interactively" test_monitor_prints_metrics_when_run_interactively
    run_test "test_monitor_stays_silent_for_cron" test_monitor_stays_silent_for_cron

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_monitor_tests
fi
