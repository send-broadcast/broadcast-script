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
  "logs job")
    echo "job container log line"
    echo "SolidQueue::Job Exception: something broke"
    ;;
  "logs postgres")
    echo "postgres container log line"
    echo "FATAL:  too many connections for role broadcast"
    ;;
  exec\ app\ curl*)
    printf "%s" "${DIAGNOSE_PUMA_CODE:-200}"
    if [ "${DIAGNOSE_PUMA_CODE:-200}" = "000" ]; then exit 7; fi
    ;;
  exec\ app\ bin/rails*) echo "${RAILS_MOCK_STATUS:-up     20260101000000  Create things}" ;;
  exec\ postgres\ psql*client_addr*) printf "%s\n" "${PSQL_SOURCES_MOCK:-172.18.0.3 broadcast_primary_production idle 12}" ;;
  exec\ postgres\ psql*max_connections*) echo "${PSQL_MAX_CONN_MOCK:-100}" ;;
  exec\ postgres\ psql*) echo "${PSQL_MOCK_OUTPUT:-42}" ;;
  inspect\ -f\ *Gateway*) echo "${DOCKER_GATEWAY_MOCK:-172.18.0.1}" ;;
  inspect\ -f\ *IPAddress*)
    # docker inspect prints the containers it found and exits non-zero when
    # any named container is missing (DOCKER_IPS_PARTIAL simulates a downed
    # app container).
    if [ -n "${DOCKER_IPS_PARTIAL:-}" ]; then
      printf "172.18.0.3\n"
      exit 1
    fi
    printf "172.18.0.2\n172.18.0.3\n172.18.0.4\n"
    ;;
  inspect*) echo "/app: restarts=0 started=2026-07-31T11:48:19Z OOMKilled=false" ;;
  ps*) echo "NAMES STATUS: app Up 2 days" ;;
  stats*) echo "NAME CPU MEM: app 1% 512MB" ;;
esac
exit 0'
    # Timeline / storage / network helpers
    harness_mock du 'echo "1.2G ${!#}"'
    harness_mock last 'echo "reboot   system boot  6.8.0-generic Thu Jul 31 11:47"'
    harness_mock timeout 'exit "${TIMEOUT_MOCK_RC:-0}"'
    echo "2026-07-31 11:00:00 | upgrade | 2.22.0 | 2.23.0" > "$SANDBOX_ROOT/.version_history"
    mkdir -p "$SANDBOX_ROOT/logs/cron"
    # journalctl is Linux-only; canned output via JOURNALCTL_MOCK
    harness_mock journalctl 'echo "${JOURNALCTL_MOCK:-}"'
    # System metrics (free does not exist on macOS)
    harness_mock free 'echo "Mem: 8000 4000 4000"'
    harness_mock df 'echo "/dev/root 100G 40G 60G 40% /"'
    harness_mock uptime 'echo " 12:00:00 up 10 days, load average: 0.50, 0.40, 0.30"'
    # Identity / specs / ports / SSL collectors (Linux-only or host-variant)
    harness_mock whoami 'echo root'
    harness_mock id 'if [ "${1:-}" = "-nG" ]; then echo "broadcast docker"; else echo "uid=0(root) gid=0(root) groups=0(root)"; fi'
    harness_mock nproc 'echo 4'
    # Realistic length (header + 15 rows, matching the script's `head -16`) so
    # truncation bugs in the copy-paste report surface. A distinct marker per
    # sort order tells the memory and CPU blocks apart.
    harness_mock ps 'if [[ "$*" == *"-%cpu"* ]]; then marker="cpu-hungry-process"; else marker="some-heavy-process"; fi
printf "USER PID %%CPU %%MEM COMMAND\n"
printf "root 100 90.0 45.0 %s\n" "$marker"
i=2
while [ "$i" -le 15 ]; do printf "broadcast %s 1.0 5.0 filler-process-%s\n" "$((200 + i))" "$i"; i=$((i + 1)); done'
    harness_mock ss 'printf "LISTEN 0 4096 0.0.0.0:80 users((docker-proxy,pid=900))\nLISTEN 0 4096 0.0.0.0:443 users((docker-proxy,pid=901))\n"'
    harness_mock timedatectl 'printf "%s\n" "${TIMEDATECTL_MOCK:-System clock synchronized: yes
              NTP service: active}"'
    harness_mock ufw 'echo "Status: active"'
    harness_mock openssl 'if [ "${1:-}" = "x509" ]; then
  printf "subject=CN=test.example.com\nissuer=CN=LetsEncrypt\nnotBefore=Jul  1 00:00:00 2026 GMT\nnotAfter=Sep 29 00:00:00 2026 GMT\n"
else
  echo "CONNECTED"
fi'

    # Version state read by the versions collector
    echo "2.23.0" > "$SANDBOX_ROOT/.current_version"
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast-arm:2.23.0" > "$SANDBOX_ROOT/.image"
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

# --- journald log capture ---------------------------------------------------
# With the compose journald logging driver, container logs survive
# `compose down` in the systemd journal — including logs of containers that
# no longer exist, which `docker logs` can never see. diagnose must prefer
# that durable history and only fall back to `docker logs` on servers whose
# containers still run the old json-file driver (empty journal).

test_diagnose_captures_logs_from_journald_when_present() {
    sandbox_run "diagnose" \
        'export JOURNALCTL_MOCK=$'"'"'{"msg":"Request","path":"/track/open/1"}\nPuma caught this error: Broken pipe (Errno::EPIPE)\njournal line from a REMOVED container'"'"'' >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_contains "$(cat "${dir}app.log")" "journal line from a REMOVED container" \
        "the journal history (incl. removed containers) must be what gets captured"

    harness_assert_called "journalctl CONTAINER_NAME=app" \
        "capture must query the journal per container"
    harness_assert_not_called "docker logs app" \
        "docker logs must not be used when the journal has history"

    # The filtered app log must be built from the journal capture too
    assert_contains "$(cat "${dir}app-filtered.log")" "Puma caught this error" \
        "the crash line must survive filtering of the journal capture"

    # Evidence before probes, same discipline as the docker-logs path
    harness_assert_call_order "journalctl CONTAINER_NAME=app" "docker exec app curl"
}

test_diagnose_falls_back_to_docker_logs_without_journal_history() {
    # Default JOURNALCTL_MOCK is empty — a pre-migration server whose
    # containers still log to json-file. Capture must not silently produce
    # empty log files; it must fall back to docker logs.
    sandbox_run "diagnose" >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_contains "$(cat "${dir}app.log")" "Puma caught this error" \
        "an empty journal must fall back to docker logs for the evidence"
    harness_assert_called "docker logs app" \
        "the fallback path must run when the journal has no history"
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

test_diagnose_records_identity() {
    sandbox_run "diagnose" >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_file_exists "${dir}identity.txt" "who ran the command must be recorded"
    assert_contains "$(cat "${dir}identity.txt")" "root" "identity should record the invoking user"
}

test_diagnose_doctor_flags_wrong_ownership() {
    # Sandbox files are owned by the test user, not "broadcast" — the
    # permission doctor must flag that instead of staying silent.
    touch "$SANDBOX_ROOT/app/.env"
    sandbox_run "diagnose" >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_file_exists "${dir}doctor.txt" "the permission doctor must run"
    assert_contains "$(cat "${dir}doctor.txt")" "WARN" \
        "wrong ownership must produce a WARN line"
}

test_diagnose_doctor_passes_on_a_correct_install() {
    touch "$SANDBOX_ROOT/app/.env"
    chmod +x "$SANDBOX_ROOT/broadcast.sh" 2>/dev/null || touch "$SANDBOX_ROOT/broadcast.sh"
    chmod +x "$SANDBOX_ROOT/broadcast.sh"
    mkdir -p "$SANDBOX_ROOT/etc/sudoers.d"
    echo "broadcast ALL=(ALL) NOPASSWD:ALL" > "$SANDBOX_ROOT/etc/sudoers.d/broadcast"
    # Ownership as install.sh leaves it
    harness_mock stat 'echo broadcast'

    sandbox_run "diagnose" >/dev/null

    local dir doctor
    dir=$(bundle_dir)
    doctor=$(cat "${dir}doctor.txt")
    if [[ "$doctor" == *"WARN"* ]]; then
        assert_equals "no warnings" "WARN present" \
            "a correctly-installed system must produce a clean doctor report: $doctor"
    fi
}

test_diagnose_records_system_specs_and_os() {
    sandbox_run "diagnose" >/dev/null

    local dir sysinfo
    dir=$(bundle_dir)
    sysinfo=$(cat "${dir}system.txt")
    assert_contains "$sysinfo" "cores" "CPU core count must be recorded"
    assert_contains "$sysinfo" "Mem:" "memory state must be recorded"
    assert_contains "$sysinfo" "/dev/root" "disk state must be recorded"
    assert_contains "$sysinfo" "clock synchronized" "time sync state must be recorded"
}

test_diagnose_records_top_processes() {
    sandbox_run "diagnose" >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_file_exists "${dir}processes.txt" "top processes must be recorded"
    assert_contains "$(cat "${dir}processes.txt")" "some-heavy-process" \
        "heavy non-Broadcast processes must be visible"
}

# --- progress feedback -----------------------------------------------------
# diagnose runs for minutes on a busy server and used to print one line and
# then nothing until the report. A customer mid-outage reads that as a hang
# and Ctrl-Cs it, destroying the bundle. Each collector must announce itself
# BEFORE it runs, so the step that is taking the time names itself.

test_diagnose_announces_each_step_before_running_it() {
    local output
    output=$(sandbox_run "diagnose")

    assert_contains "$output" "1/20]" "steps must be numbered so progress is visible"
    assert_contains "$output" "container logs" "the first step must name itself"
    assert_contains "$output" "health probes" "later steps must name themselves too"
}

test_diagnose_step_count_matches_the_declared_total() {
    # DIAGNOSE_STEP_TOTAL is hand-maintained, so a step added without bumping
    # it would print "[21/20]" to customers. Assert the last step is the total.
    local output last
    output=$(sandbox_run "diagnose")
    last=$(echo "$output" | grep -o '\[ *[0-9]*/20\]' | tail -1 | tr -d '[] ' | cut -d/ -f1)

    assert_equals "20" "$last" \
        "the final step number must equal DIAGNOSE_STEP_TOTAL"
}

test_diagnose_progress_flags_the_slow_step() {
    # The log capture dominates the runtime; saying so up front is the
    # difference between "it is working" and "it has hung".
    assert_contains "$(sandbox_run "diagnose")" "slowest" \
        "the log capture step must warn that it is the slow one"
}

test_diagnose_reports_elapsed_time_per_step_and_total() {
    local output
    output=$(sandbox_run "diagnose")

    assert_contains "$output" "s)" "each completed step must report its elapsed seconds"
    assert_contains "$output" "collected in" "the run must report a total duration"
}

# --- copy-paste report completeness ----------------------------------------

test_diagnose_report_includes_top_processes_by_cpu() {
    # processes.txt holds the memory block (17 lines) then the CPU block, so
    # a head -20 on the report stopped one line into the CPU header and the
    # section printed empty in every real bundle.
    local output
    output=$(sandbox_run "diagnose")

    assert_contains "$output" "Top processes by CPU" "the CPU block header must print"
    assert_contains "$output" "cpu-hungry-process" \
        "the CPU block must print its rows, not just the header"
    assert_contains "$output" "some-heavy-process" "the memory block must still print"
}

# --- bounded log capture ---------------------------------------------------
# Under the json-file driver a "full dump" was capped at 10m x 3 per
# container. journald has no such cap, so the same code now scans multi-GB
# journals: 2m12s runs and 734MB of logs/ on a real server.

test_diagnose_bounds_the_journal_capture_to_a_window() {
    sandbox_run "diagnose" >/dev/null

    harness_assert_called "journalctl CONTAINER_NAME=app --since" \
        "journal capture must be bounded by a time window"
}

test_diagnose_still_never_tails_container_logs() {
    # Bounding by time must not regress into --tail: a days-old crash has to
    # stay inside the captured window.
    sandbox_run "diagnose" >/dev/null

    harness_assert_not_called "docker logs --tail" \
        "log capture must be bounded by time, never by line tail"
}

test_diagnose_prunes_old_bundles() {
    local i
    for i in 1 2 3 4 5; do
        mkdir -p "$SANDBOX_ROOT/logs/diagnose-2026-01-0$i-00-00-00"
        echo stale > "$SANDBOX_ROOT/logs/diagnose-2026-01-0$i-00-00-00/app.log"
        echo stale > "$SANDBOX_ROOT/logs/diagnose-2026-01-0$i-00-00-00.tar.gz"
    done

    sandbox_run "diagnose" >/dev/null

    local remaining
    remaining=$(ls -d "$SANDBOX_ROOT/logs/diagnose-"*/ 2>/dev/null | wc -l | tr -d ' ')
    if [ "$remaining" -gt 3 ]; then
        assert_equals "at most 3 bundles" "$remaining bundles" \
            "old diagnose bundles must be pruned so logs/ cannot grow without limit"
    fi

    # The bundle from THIS run must always survive the prune.
    assert_file_exists "$(bundle_dir)app.log" "the current bundle must not be pruned"
}

# --- clock sync ------------------------------------------------------------

test_diagnose_warns_when_the_clock_is_not_synchronized() {
    # Observed on a real server: NTP inactive, printed without comment. Clock
    # skew breaks provider request signatures, which fails as auth errors.
    sandbox_run "diagnose" \
        'export TIMEDATECTL_MOCK="System clock synchronized: no
              NTP service: n/a"' >/dev/null

    assert_contains "$(cat "$(bundle_dir)system.txt")" "WARN" \
        "an unsynchronized clock must warn"
}

test_diagnose_does_not_warn_when_the_clock_is_synchronized() {
    local system
    sandbox_run "diagnose" >/dev/null
    system=$(cat "$(bundle_dir)system.txt")

    if [[ "$system" == *"WARN"* ]]; then
        assert_equals "no warning" "WARN present" \
            "a synchronized clock with active NTP must not warn"
    fi
}

test_diagnose_records_ports_without_warning_for_docker() {
    sandbox_run "diagnose" >/dev/null

    local dir ports
    dir=$(bundle_dir)
    assert_file_exists "${dir}ports.txt" "port listeners must be recorded"
    ports=$(cat "${dir}ports.txt")
    assert_contains "$ports" "docker-proxy" "the healthy docker-proxy listeners should be listed"
    if [[ "$ports" == *"WARN"* ]]; then
        assert_equals "no warning" "WARN present" \
            "docker-proxy on 80/443 is healthy and must not warn"
    fi
}

test_diagnose_warns_when_foreign_webserver_holds_ports() {
    harness_mock ss 'printf "LISTEN 0 511 0.0.0.0:80 users((nginx,pid=800))\nLISTEN 0 511 0.0.0.0:443 users((nginx,pid=800))\n"'

    sandbox_run "diagnose" >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_contains "$(cat "${dir}ports.txt")" "WARN" \
        "a non-Docker listener on 80/443 (e.g. nginx) must be flagged"
}

test_diagnose_records_ssl_certificate_status() {
    sandbox_run "diagnose" >/dev/null

    local dir ssl
    dir=$(bundle_dir)
    assert_file_exists "${dir}ssl.txt" "certificate status must be recorded"
    ssl=$(cat "${dir}ssl.txt")
    assert_contains "$ssl" "notAfter" "certificate expiry must be recorded"
    harness_assert_called "s_client -servername test.example.com" \
        "the live cert must be fetched with SNI for the installation domain"
}

test_diagnose_records_versions_and_container_state() {
    sandbox_run "diagnose" >/dev/null

    local dir versions
    dir=$(bundle_dir)
    assert_file_exists "${dir}versions.txt" "version info must be recorded"
    versions=$(cat "${dir}versions.txt")
    assert_contains "$versions" "2.23.0" "the Broadcast version must be recorded"
    assert_contains "$versions" "DOCKER_IMAGE" "the deployed image must be recorded"
}

test_diagnose_report_includes_new_sections() {
    local output
    output=$(sandbox_run "diagnose")

    assert_contains "$output" "broadcast version" "the paste report must lead with the version"
    assert_contains "$output" "notAfter" "the paste report must include certificate expiry"
    assert_contains "$output" "Permission doctor" "the paste report must include the doctor verdicts"
    assert_contains "$output" "docker-proxy" "the paste report must include the port listeners"
}

test_diagnose_records_queue_health_and_warns_on_failed_jobs() {
    # Queue state is read via psql against the postgres container, NOT via
    # Rails — a wedged or dead app container must not block queue inspection.
    sandbox_run "diagnose" >/dev/null

    local dir queue
    dir=$(bundle_dir)
    assert_file_exists "${dir}queue.txt" "job queue health must be recorded"
    queue=$(cat "${dir}queue.txt")
    assert_contains "$queue" "ready jobs" "queue depth must be recorded"
    assert_contains "$queue" "failed jobs" "failed-job count must be recorded"
    # The psql mock reports 42 failed jobs — that must produce a warning
    assert_contains "$queue" "WARN" "a non-zero failed-job count must warn"
}

test_diagnose_records_database_health() {
    sandbox_run "diagnose" >/dev/null

    local dir db
    dir=$(bundle_dir)
    assert_file_exists "${dir}database.txt" "database health must be recorded"
    db=$(cat "${dir}database.txt")
    assert_contains "$db" "active connections" "connection count must be recorded"
    assert_contains "$db" "max_connections" "the connection ceiling must be recorded"
    assert_contains "$db" "no pending migrations" \
        "an up-to-date schema should be reported as ok"
}

# --- database connection sources -------------------------------------------
# A remote client (psql, a BI tool, an SSH tunnel) holding connections looks
# exactly like an app hang: requests time out while Postgres itself is fine.
# The bare active/max counts cannot tell the two apart, so diagnose must also
# record WHO is connected (firstborngroup 2026-08-04 case).

test_diagnose_records_database_connection_sources() {
    sandbox_run "diagnose" >/dev/null

    local dir db
    dir=$(bundle_dir)
    db=$(cat "${dir}database.txt")
    assert_contains "$db" "Connections by source" \
        "the connection breakdown must be recorded"
    assert_contains "$db" "172.18.0.3" \
        "each connecting client address must be listed"
}

test_diagnose_warns_on_external_database_client() {
    # An address that belongs to no Broadcast container is a foreign client
    # eating the connection ceiling — the whole point of the breakdown.
    sandbox_run "diagnose" \
        'export PSQL_SOURCES_MOCK="203.0.113.9 broadcast_primary_production idle 40"' >/dev/null

    assert_contains "$(cat "$(bundle_dir)database.txt")" "WARN" \
        "a client outside the Broadcast containers must warn"
}

test_diagnose_warns_on_connections_through_published_port() {
    # docker-proxy rewrites the source to the bridge gateway, so gateway
    # sessions arrived through the published 5432 port rather than from a
    # sibling container.
    sandbox_run "diagnose" \
        'export PSQL_SOURCES_MOCK="172.18.0.1 broadcast_primary_production idle 5"' >/dev/null

    assert_contains "$(cat "$(bundle_dir)database.txt")" "published" \
        "gateway sessions must be reported as arriving through the published port"
}

test_diagnose_accepts_connections_from_broadcast_containers() {
    # The default mock is the app container: normal, must not cry wolf.
    local db
    sandbox_run "diagnose" >/dev/null
    db=$(cat "$(bundle_dir)database.txt")

    if [[ "$db" == *"WARN"* ]]; then
        assert_equals "no warning" "WARN present" \
            "container-sourced connections well under the ceiling must not warn"
    fi
}

test_diagnose_counts_only_client_backends() {
    # pg_stat_activity includes background workers (checkpointer, autovacuum,
    # walwriter) which hold no max_connections slot. Counting them overstates
    # usage and skews the ceiling warning.
    sandbox_run "diagnose" >/dev/null

    harness_assert_called "backend_type" \
        "the connection count must exclude postgres background workers"
}

test_diagnose_does_not_cry_wolf_when_a_container_is_down() {
    # The crash case: the app container is gone, so `docker inspect app job
    # postgres` exits non-zero while still printing the survivors. The
    # surviving containers' own sessions must not be called external — a false
    # alarm exactly when support is reading the bundle most carefully.
    local db
    sandbox_run "diagnose" 'export DOCKER_IPS_PARTIAL=1' >/dev/null
    db=$(cat "$(bundle_dir)database.txt")

    if [[ "$db" == *"not from a Broadcast container"* ]]; then
        assert_equals "no false alarm" "external-client WARN present" \
            "a surviving container's own sessions must not be called external"
    fi
}

test_diagnose_warns_when_connections_near_ceiling() {
    sandbox_run "diagnose" 'export PSQL_MOCK_OUTPUT=95' >/dev/null

    assert_contains "$(cat "$(bundle_dir)database.txt")" "WARN" \
        "connection use at or above 80% of the ceiling must warn"
}

test_diagnose_warns_on_pending_migrations() {
    sandbox_run "diagnose" 'export RAILS_MOCK_STATUS="  down    20260801000000  Add new things"' >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_contains "$(cat "${dir}database.txt")" "WARN" \
        "pending migrations must produce a warning"
}

test_diagnose_reports_fresh_backup_as_ok() {
    touch "$SANDBOX_ROOT/db/backups/broadcast-backup-v2.23.0-2026-08-01-00-00-00.tar.gz"

    sandbox_run "diagnose" >/dev/null

    local dir backups
    dir=$(bundle_dir)
    assert_file_exists "${dir}backups.txt" "backup freshness must be recorded"
    backups=$(cat "${dir}backups.txt")
    assert_contains "$backups" "broadcast-backup-v2.23.0" "the newest backup must be listed"
    assert_contains "$backups" "ok:" "a fresh backup should be reported ok"
}

test_diagnose_warns_when_no_backups_exist() {
    sandbox_run "diagnose" >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_contains "$(cat "${dir}backups.txt")" "WARN" \
        "an install with no backups must be flagged"
}

test_diagnose_attributes_disk_usage() {
    sandbox_run "diagnose" >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_file_exists "${dir}storage.txt" "disk attribution must be recorded"
    assert_contains "$(cat "${dir}storage.txt")" "uploads" \
        "per-directory usage (e.g. uploads) must be attributed"
}

test_diagnose_records_timeline() {
    sandbox_run "diagnose" >/dev/null

    local dir timeline
    dir=$(bundle_dir)
    assert_file_exists "${dir}timeline.txt" "incident timeline must be recorded"
    timeline=$(cat "${dir}timeline.txt")
    assert_contains "$timeline" "upgrade | 2.22.0 | 2.23.0" \
        "version history must be included"
    assert_contains "$timeline" "reboot" "reboot history must be included"
    assert_contains "$timeline" "OOMKilled" \
        "container OOM flags must be included (cgroup kills miss the kernel journal)"
}

test_diagnose_cron_liveness_keys_off_monitor_heartbeat() {
    # The real failure mode (2026-08-04 customer bundle): successful cron
    # runs emit no stdout, so cron logs sit 0-byte with stale mtimes forever
    # — log mtime is a false-positive WARN generator. The true heartbeat is
    # app/monitor/system.json, rewritten every minute by the monitor cron.
    touch -t 202601010000 "$SANDBOX_ROOT/logs/cron/monitor.log"   # stale log
    echo '{}' > "$SANDBOX_ROOT/app/monitor/system.json"           # fresh heartbeat
    sandbox_run "diagnose" >/dev/null
    local dir
    dir=$(bundle_dir)
    assert_contains "$(cat "${dir}cron.txt")" "ok:" \
        "a fresh monitor heartbeat means cron is alive, whatever the log mtimes say"

    # Stale heartbeat → WARN (new bundle in the same sandbox)
    touch -t 202601010000 "$SANDBOX_ROOT/app/monitor/system.json"
    sandbox_run "diagnose" >/dev/null
    dir=$(ls -dt "$SANDBOX_ROOT/logs/diagnose-"*/ | head -1)
    assert_contains "$(cat "${dir}cron.txt")" "WARN" \
        "a stale heartbeat means cron is dead and must warn"
}

test_diagnose_cron_section_tails_update_and_trigger_logs() {
    # The 2026-08-04 incident (git pull failing nightly for weeks) was
    # invisible in the bundle — update.log/trigger.log were never captured.
    echo "error: Your local changes would be overwritten by merge" > "$SANDBOX_ROOT/logs/cron/update.log"
    echo "upgrade triggered with target version: 2.25.0" > "$SANDBOX_ROOT/logs/cron/trigger.log"
    sandbox_run "diagnose" >/dev/null

    local dir cron
    dir=$(bundle_dir)
    cron=$(cat "${dir}cron.txt")
    assert_contains "$cron" "overwritten by merge" "the update.log tail must be captured"
    assert_contains "$cron" "upgrade triggered" "the trigger.log tail must be captured"
}

test_diagnose_reports_auto_recovery_activity() {
    # A server that has been restarting itself is the single most important
    # thing support can know before reading anything else, and the operator
    # will not mention it because it happened without them. recover.sh writes
    # logs/recovery.log; the bundle has to carry it.
    mkdir -p "$SANDBOX_ROOT/logs"
    echo "[Sat Aug 15 09:03:00 UTC 2026] RECOVERY: Puma unreachable on :3000 for 3 consecutive probes" \
        > "$SANDBOX_ROOT/logs/recovery.log"

    sandbox_run "diagnose" >/dev/null

    local dir cron
    dir=$(bundle_dir)
    cron=$(cat "${dir}cron.txt")
    assert_contains "$cron" "RECOVERY" \
        "the bundle must show that auto-recovery has been restarting this server"
}

test_diagnose_notes_when_auto_recovery_is_disabled() {
    touch "$SANDBOX_ROOT/.no_auto_recovery"

    sandbox_run "diagnose" >/dev/null

    local dir cron
    dir=$(bundle_dir)
    cron=$(cat "${dir}cron.txt")
    assert_contains "$cron" "auto-recovery is DISABLED" \
        "support must be told the server will not restart itself, or they will wait for a recovery that never comes"
}

test_diagnose_captures_local_customizations() {
    harness_mock git 'case "$*" in
  *"status --porcelain"*) echo " M docker-compose.yml" ;;
  *"log -1"*) echo "9f9b148 pinned test revision" ;;
esac
exit 0'
    cat > "$SANDBOX_ROOT/docker-compose.override.yml" <<'EOT'
services:
  postgres:
    ports: ["127.0.0.1:5432:5432"]
EOT

    local output
    output=$(sandbox_run "diagnose")

    local dir cust
    dir=$(bundle_dir)
    assert_file_exists "${dir}customizations.txt" \
        "local customizations must be captured in the bundle"
    cust=$(cat "${dir}customizations.txt")
    assert_contains "$cust" "M docker-compose.yml" \
        "a dirty tree (blocks all updates) must be visible in the bundle"
    assert_contains "$cust" "docker-compose.override.yml" \
        "the override file's presence must be reported"
    assert_contains "$cust" "127.0.0.1:5432" \
        "the override file's contents must be captured"
    assert_contains "$output" "M docker-compose.yml" \
        "the paste report must surface local modifications"
}

test_diagnose_filters_job_and_postgres_errors() {
    sandbox_run "diagnose" >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_file_exists "${dir}job-errors.log" "job error view must be produced"
    assert_contains "$(cat "${dir}job-errors.log")" "SolidQueue::Job Exception" \
        "job exceptions must surface in the error view"
    assert_file_exists "${dir}postgres-errors.log" "postgres error view must be produced"
    assert_contains "$(cat "${dir}postgres-errors.log")" "FATAL" \
        "postgres FATAL lines must surface in the error view"
}

test_diagnose_checks_outbound_network() {
    sandbox_run "diagnose" >/dev/null

    local dir network
    dir=$(bundle_dir)
    assert_file_exists "${dir}network.txt" "outbound reachability must be recorded"
    network=$(cat "${dir}network.txt")
    assert_contains "$network" "sendbroadcast.net" "license server reachability must be checked"
    assert_contains "$network" "smtp egress port 25" "SMTP egress must be checked"
    assert_contains "$network" "open" "an open SMTP port should be reported open"
    harness_assert_called "https://sendbroadcast.net" \
        "the license server must actually be probed"
}

test_diagnose_reports_blocked_smtp_egress() {
    sandbox_run "diagnose" 'export TIMEOUT_MOCK_RC=1' >/dev/null

    local dir
    dir=$(bundle_dir)
    assert_contains "$(cat "${dir}network.txt")" "blocked" \
        "closed SMTP egress (common on cloud hosts) must be reported"
}

test_diagnose_report_includes_operational_sections() {
    local output
    output=$(sandbox_run "diagnose")

    assert_contains "$output" "Job queue" "the paste report must include queue health"
    assert_contains "$output" "Backups" "the paste report must include backup freshness"
    assert_contains "$output" "Outbound network" "the paste report must include network checks"
    assert_contains "$output" "Cron" "the paste report must include cron liveness"
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
    run_test "test_diagnose_captures_logs_from_journald_when_present" test_diagnose_captures_logs_from_journald_when_present
    run_test "test_diagnose_falls_back_to_docker_logs_without_journal_history" test_diagnose_falls_back_to_docker_logs_without_journal_history
    run_test "test_diagnose_filters_thruster_noise_from_app_log" test_diagnose_filters_thruster_noise_from_app_log
    run_test "test_diagnose_records_layered_probes" test_diagnose_records_layered_probes
    run_test "test_diagnose_flags_thruster_up_puma_down_fingerprint" test_diagnose_flags_thruster_up_puma_down_fingerprint
    run_test "test_diagnose_reports_healthy_when_all_probes_pass" test_diagnose_reports_healthy_when_all_probes_pass
    run_test "test_diagnose_treats_thruster_301_redirect_as_healthy" test_diagnose_treats_thruster_301_redirect_as_healthy
    run_test "test_diagnose_prints_copy_paste_report" test_diagnose_prints_copy_paste_report
    run_test "test_diagnose_includes_oom_check_and_system_state" test_diagnose_includes_oom_check_and_system_state
    run_test "test_diagnose_records_identity" test_diagnose_records_identity
    run_test "test_diagnose_doctor_flags_wrong_ownership" test_diagnose_doctor_flags_wrong_ownership
    run_test "test_diagnose_doctor_passes_on_a_correct_install" test_diagnose_doctor_passes_on_a_correct_install
    run_test "test_diagnose_records_system_specs_and_os" test_diagnose_records_system_specs_and_os
    run_test "test_diagnose_records_top_processes" test_diagnose_records_top_processes
    run_test "test_diagnose_announces_each_step_before_running_it" test_diagnose_announces_each_step_before_running_it
    run_test "test_diagnose_step_count_matches_the_declared_total" test_diagnose_step_count_matches_the_declared_total
    run_test "test_diagnose_progress_flags_the_slow_step" test_diagnose_progress_flags_the_slow_step
    run_test "test_diagnose_reports_elapsed_time_per_step_and_total" test_diagnose_reports_elapsed_time_per_step_and_total
    run_test "test_diagnose_report_includes_top_processes_by_cpu" test_diagnose_report_includes_top_processes_by_cpu
    run_test "test_diagnose_bounds_the_journal_capture_to_a_window" test_diagnose_bounds_the_journal_capture_to_a_window
    run_test "test_diagnose_still_never_tails_container_logs" test_diagnose_still_never_tails_container_logs
    run_test "test_diagnose_prunes_old_bundles" test_diagnose_prunes_old_bundles
    run_test "test_diagnose_warns_when_the_clock_is_not_synchronized" test_diagnose_warns_when_the_clock_is_not_synchronized
    run_test "test_diagnose_does_not_warn_when_the_clock_is_synchronized" test_diagnose_does_not_warn_when_the_clock_is_synchronized
    run_test "test_diagnose_counts_only_client_backends" test_diagnose_counts_only_client_backends
    run_test "test_diagnose_records_ports_without_warning_for_docker" test_diagnose_records_ports_without_warning_for_docker
    run_test "test_diagnose_warns_when_foreign_webserver_holds_ports" test_diagnose_warns_when_foreign_webserver_holds_ports
    run_test "test_diagnose_records_ssl_certificate_status" test_diagnose_records_ssl_certificate_status
    run_test "test_diagnose_records_versions_and_container_state" test_diagnose_records_versions_and_container_state
    run_test "test_diagnose_report_includes_new_sections" test_diagnose_report_includes_new_sections
    run_test "test_diagnose_records_queue_health_and_warns_on_failed_jobs" test_diagnose_records_queue_health_and_warns_on_failed_jobs
    run_test "test_diagnose_records_database_health" test_diagnose_records_database_health
    run_test "test_diagnose_records_database_connection_sources" test_diagnose_records_database_connection_sources
    run_test "test_diagnose_warns_on_external_database_client" test_diagnose_warns_on_external_database_client
    run_test "test_diagnose_warns_on_connections_through_published_port" test_diagnose_warns_on_connections_through_published_port
    run_test "test_diagnose_accepts_connections_from_broadcast_containers" test_diagnose_accepts_connections_from_broadcast_containers
    run_test "test_diagnose_does_not_cry_wolf_when_a_container_is_down" test_diagnose_does_not_cry_wolf_when_a_container_is_down
    run_test "test_diagnose_warns_when_connections_near_ceiling" test_diagnose_warns_when_connections_near_ceiling
    run_test "test_diagnose_warns_on_pending_migrations" test_diagnose_warns_on_pending_migrations
    run_test "test_diagnose_reports_fresh_backup_as_ok" test_diagnose_reports_fresh_backup_as_ok
    run_test "test_diagnose_warns_when_no_backups_exist" test_diagnose_warns_when_no_backups_exist
    run_test "test_diagnose_attributes_disk_usage" test_diagnose_attributes_disk_usage
    run_test "test_diagnose_records_timeline" test_diagnose_records_timeline
    run_test "test_diagnose_cron_liveness_keys_off_monitor_heartbeat" test_diagnose_cron_liveness_keys_off_monitor_heartbeat
    run_test "test_diagnose_cron_section_tails_update_and_trigger_logs" test_diagnose_cron_section_tails_update_and_trigger_logs
    run_test "test_diagnose_reports_auto_recovery_activity" test_diagnose_reports_auto_recovery_activity
    run_test "test_diagnose_notes_when_auto_recovery_is_disabled" test_diagnose_notes_when_auto_recovery_is_disabled
    run_test "test_diagnose_captures_local_customizations" test_diagnose_captures_local_customizations
    run_test "test_diagnose_filters_job_and_postgres_errors" test_diagnose_filters_job_and_postgres_errors
    run_test "test_diagnose_checks_outbound_network" test_diagnose_checks_outbound_network
    run_test "test_diagnose_reports_blocked_smtp_egress" test_diagnose_reports_blocked_smtp_egress
    run_test "test_diagnose_report_includes_operational_sections" test_diagnose_report_includes_operational_sections
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
