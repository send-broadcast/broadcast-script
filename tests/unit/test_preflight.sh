#!/bin/bash

# Unit tests for the upgrade preflight (scripts/preflight.sh).
#
# The check reads Postgres directly rather than asking the app, for the same
# reason the queue and database collectors in diagnose do: a wedged or dead
# app container must not be able to block or skew the answer, and a wedged app
# is exactly when someone reaches for an upgrade.
#
# What blocks: jobs a worker has already claimed (killing one can cut a send
# off partway through a batch) and broadcasts in queueing/sending. What does
# NOT block: queued-but-unclaimed work, which lives in the database and is
# picked up again after the restart.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

setup_sandbox() {
    harness_make_sandbox
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    mkdir -p "$SANDBOX_ROOT/logs/cron"

    # psql answers are keyed off the table each query names, so a test can
    # simulate in-flight work independently for jobs and broadcasts.
    harness_mock docker 'case "$*" in
  *pg_terminate_backend*) echo "${TERMINATED_MOCK:-0}" ;;
  *pg_stat_activity*) printf "%s\n" "${SESSIONS_MOCK:-}" ;;
  *solid_queue_claimed_executions*) echo "${CLAIMED_MOCK:-0}" ;;
  *broadcasts*) echo "${SENDING_MOCK:-0}" ;;
  *) echo "" ;;
esac
exit 0'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

test_preflight_passes_when_nothing_is_in_flight() {
    local rc=0
    sandbox_run "upgrade_preflight" >/dev/null || rc=$?

    assert_equals "0" "$rc" "an idle system must be safe to upgrade"
}

test_preflight_blocks_while_a_job_is_mid_execution() {
    local rc=0
    sandbox_run "upgrade_preflight" 'export CLAIMED_MOCK=3' >/dev/null || rc=$?

    assert_not_equals "0" "$rc" "claimed jobs must block the upgrade"
}

test_preflight_blocks_while_a_broadcast_is_sending() {
    local rc=0
    sandbox_run "upgrade_preflight" 'export SENDING_MOCK=1' >/dev/null || rc=$?

    assert_not_equals "0" "$rc" "a sending broadcast must block the upgrade"
}

test_preflight_names_what_is_blocking() {
    local output
    output=$(sandbox_run "upgrade_preflight" 'export CLAIMED_MOCK=2; export SENDING_MOCK=1' || true)

    assert_contains "$output" "2" "the count of in-flight jobs must be reported"
    assert_contains "$output" "broadcast" "the blocking broadcast must be named"
}

test_preflight_does_not_block_on_queued_work() {
    # Queued-but-unclaimed jobs survive a restart; blocking on them would stall
    # upgrades on any busy server for no safety gain.
    local rc=0
    sandbox_run "upgrade_preflight" 'export READY_MOCK=5000' >/dev/null || rc=$?

    assert_equals "0" "$rc" "a queue backlog alone must not block an upgrade"
}

test_preflight_passes_when_the_database_cannot_be_reached() {
    # If postgres is unreachable no worker can be running a job either, and
    # refusing here would block the very restart that recovers the system.
    local rc=0
    sandbox_run "upgrade_preflight" \
        'docker() { exit 1; }; export -f docker' >/dev/null || rc=$?

    assert_equals "0" "$rc" "an unreachable database must not block recovery"
}

# --- deferral bookkeeping ---------------------------------------------------
# An automated upgrade defers instead of failing, but a server that is busy
# forever would then stop upgrading silently. Record it so diagnose can say so.

test_preflight_records_a_deferral_for_automated_runs() {
    sandbox_run "upgrade_preflight --automated" 'export CLAIMED_MOCK=1' >/dev/null || true

    assert_file_exists "$SANDBOX_ROOT/.upgrade_deferred" \
        "an automated deferral must be recorded"
}

test_preflight_clears_the_deferral_record_once_clear() {
    echo "3" > "$SANDBOX_ROOT/.upgrade_deferred"

    sandbox_run "upgrade_preflight --automated" >/dev/null || true

    assert_file_not_exists "$SANDBOX_ROOT/.upgrade_deferred" \
        "a successful preflight must clear the deferral record"
}

# --- wiring into upgrade ----------------------------------------------------
# A preflight nothing calls is decoration. The check must run BEFORE the
# service is stopped, which is the point of no return for in-flight work.

test_upgrade_aborts_before_stopping_when_work_is_in_flight() {
    harness_stub_broadcast_sh
    local rc=0
    sandbox_run "upgrade" 'export CLAIMED_MOCK=2' >/dev/null || rc=$?

    assert_not_equals "0" "$rc" "an interactive upgrade must fail when work is in flight"
    harness_assert_not_called "systemctl stop broadcast" \
        "the service must not be stopped once the preflight has blocked"
}

test_upgrade_force_bypasses_the_preflight() {
    harness_stub_broadcast_sh
    sandbox_run "upgrade --force" 'export CLAIMED_MOCK=2' >/dev/null || true

    harness_assert_called "systemctl stop broadcast" \
        "--force must proceed past the preflight"
}

test_upgrade_proceeds_normally_when_nothing_is_in_flight() {
    harness_stub_broadcast_sh
    sandbox_run "upgrade" >/dev/null || true

    harness_assert_called "systemctl stop broadcast" \
        "an idle system must upgrade as before"
}

test_automated_upgrade_defers_without_reporting_failure() {
    # Exit 0: a deferral is not an error, and a nonzero exit here would turn
    # every busy night into cron failure mail.
    harness_stub_broadcast_sh
    local rc=0
    sandbox_run "upgrade --automated" 'export CLAIMED_MOCK=1' >/dev/null || rc=$?

    assert_equals "0" "$rc" "a deferred automated upgrade must not report failure"
    harness_assert_not_called "systemctl stop broadcast" \
        "a deferred upgrade must not stop the service"
}

# --- disconnecting database clients before shutdown -------------------------
# Postgres under SIGTERM does a SMART shutdown: it waits for existing clients
# to disconnect. The official image sets STOPSIGNAL SIGINT to get a fast
# shutdown instead, but compose still only allows 10s before SIGKILL, and a
# shutdown checkpoint on a multi-GB database can exceed that on its own. A
# SIGKILLed postgres does WAL crash recovery on the next boot, the healthcheck
# stays unhealthy, and `depends_on: service_healthy` makes the app sit and
# wait — which is what "the upgrade hangs" looks like from the operator's
# chair. Closing client sessions first makes the shutdown deterministic.

test_disconnect_terminates_client_backends() {
    sandbox_run "disconnect_database_clients" \
        'export SESSIONS_MOCK="203.0.113.9 DBeaver idle-in-transaction"; export TERMINATED_MOCK=1' >/dev/null

    harness_assert_called "pg_terminate_backend" \
        "lingering client sessions must be terminated before shutdown"
}

test_disconnect_names_the_sessions_it_closed() {
    # The support signal: this line turns "the upgrade hung" into "we closed a
    # remote DBeaver session that was idle in transaction".
    local output
    output=$(sandbox_run "disconnect_database_clients" \
        'export SESSIONS_MOCK="203.0.113.9 DBeaver idle-in-transaction"; export TERMINATED_MOCK=1')

    assert_contains "$output" "203.0.113.9" "the disconnected session must be named"
    assert_contains "$output" "DBeaver" "the client application must be named"
}

test_disconnect_never_aborts_when_postgres_is_unreachable() {
    # This runs on the shutdown path of an upgrade. Failing here would abort
    # the upgrade over a cleanup step that is only an optimisation.
    local rc=0
    sandbox_run "disconnect_database_clients" \
        'docker() { exit 1; }; export -f docker' >/dev/null || rc=$?

    assert_equals "0" "$rc" "an unreachable database must not abort the caller"
}

test_upgrade_disconnects_clients_before_stopping_the_service() {
    harness_stub_broadcast_sh
    sandbox_run "upgrade" 'export SESSIONS_MOCK="203.0.113.9 DBeaver idle"' >/dev/null || true

    harness_assert_call_order "pg_terminate_backend" "systemctl stop broadcast"
}

test_stop_disconnects_clients_before_stopping_the_service() {
    sandbox_run 'source "$BROADCAST_ROOT/scripts/stop.sh"; stop' \
        'export SESSIONS_MOCK="203.0.113.9 DBeaver idle"' >/dev/null || true

    harness_assert_call_order "pg_terminate_backend" "systemctl stop broadcast"
}

run_preflight_tests() {
    init_test_framework
    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_preflight_passes_when_nothing_is_in_flight" test_preflight_passes_when_nothing_is_in_flight
    run_test "test_preflight_blocks_while_a_job_is_mid_execution" test_preflight_blocks_while_a_job_is_mid_execution
    run_test "test_preflight_blocks_while_a_broadcast_is_sending" test_preflight_blocks_while_a_broadcast_is_sending
    run_test "test_preflight_names_what_is_blocking" test_preflight_names_what_is_blocking
    run_test "test_preflight_does_not_block_on_queued_work" test_preflight_does_not_block_on_queued_work
    run_test "test_preflight_passes_when_the_database_cannot_be_reached" test_preflight_passes_when_the_database_cannot_be_reached
    run_test "test_preflight_records_a_deferral_for_automated_runs" test_preflight_records_a_deferral_for_automated_runs
    run_test "test_preflight_clears_the_deferral_record_once_clear" test_preflight_clears_the_deferral_record_once_clear
    run_test "test_upgrade_aborts_before_stopping_when_work_is_in_flight" test_upgrade_aborts_before_stopping_when_work_is_in_flight
    run_test "test_upgrade_force_bypasses_the_preflight" test_upgrade_force_bypasses_the_preflight
    run_test "test_upgrade_proceeds_normally_when_nothing_is_in_flight" test_upgrade_proceeds_normally_when_nothing_is_in_flight
    run_test "test_automated_upgrade_defers_without_reporting_failure" test_automated_upgrade_defers_without_reporting_failure
    run_test "test_disconnect_terminates_client_backends" test_disconnect_terminates_client_backends
    run_test "test_disconnect_names_the_sessions_it_closed" test_disconnect_names_the_sessions_it_closed
    run_test "test_disconnect_never_aborts_when_postgres_is_unreachable" test_disconnect_never_aborts_when_postgres_is_unreachable
    run_test "test_upgrade_disconnects_clients_before_stopping_the_service" test_upgrade_disconnects_clients_before_stopping_the_service
    run_test "test_stop_disconnects_clients_before_stopping_the_service" test_stop_disconnects_clients_before_stopping_the_service

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_preflight_tests
fi
