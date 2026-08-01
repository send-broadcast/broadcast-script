#!/bin/bash

# Sandbox harness for testing the REAL management scripts without modifying
# them and without touching /opt/broadcast or the host system.
#
# How it works:
#   - The scripts hardcode /opt/broadcast and /etc/systemd/system. At load
#     time we copy each script into a scratch sandbox, rewriting ONLY those
#     two path constants to point inside the sandbox. All logic, ordering,
#     quoting and error handling under test is the unmodified original code.
#   - External commands (systemctl, docker, su, curl, git, ...) are shimmed
#     via a mocks/ directory placed first on PATH. Every shim appends its
#     invocation to calls.log so tests can assert on what ran and in what
#     order. `sudo` re-execs its arguments so file operations stay real.
#   - broadcast.sh is loaded with its trailing `main "$@"` call disabled so
#     its functions (set_docker_image, ...) can be tested; a separate stub
#     broadcast.sh records dispatch calls made BY scripts under test.
#
# Usage from a test file:
#   source tests/script_harness.sh
#   harness_make_sandbox            # fresh sandbox, default mocks
#   sandbox_run 'trigger'           # source real scripts, run snippet
#   harness_assert_called "systemctl stop broadcast" "..."
#   harness_destroy_sandbox

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_PROJECT_ROOT="$(cd "$HARNESS_DIR/.." && pwd)"

SANDBOX_ROOT=""
SANDBOX_CALLS=""

# Scripts loaded into every sandbox, in source order (common first; restore
# defines compare_versions used by others).
HARNESS_SCRIPTS="common.sh restore.sh backup.sh update.sh upgrade.sh downgrade.sh trigger.sh monitor.sh diagnose.sh init-services.sh"

harness_make_sandbox() {
    SANDBOX_ROOT=$(mktemp -d)
    SANDBOX_CALLS="$SANDBOX_ROOT/calls.log"
    : > "$SANDBOX_CALLS"

    mkdir -p "$SANDBOX_ROOT/scripts" "$SANDBOX_ROOT/mocks" \
        "$SANDBOX_ROOT/app/triggers" "$SANDBOX_ROOT/app/storage" \
        "$SANDBOX_ROOT/app/monitor" "$SANDBOX_ROOT/app/uploads" \
        "$SANDBOX_ROOT/db/backups" "$SANDBOX_ROOT/ssl" \
        "$SANDBOX_ROOT/etc/systemd/system"

    # Rewrite ONLY the hardcoded path constants; everything else is the
    # original script text.
    local s
    for s in $HARNESS_SCRIPTS install.sh logs.sh start.sh stop.sh restart.sh; do
        sed -e "s|/opt/broadcast|$SANDBOX_ROOT|g" \
            -e "s|/etc/systemd/system|$SANDBOX_ROOT/etc/systemd/system|g" \
            "$HARNESS_PROJECT_ROOT/scripts/$s" > "$SANDBOX_ROOT/scripts/$s"
    done

    # Support files referenced by upgrade (cp'd service units, chmod targets)
    cp "$HARNESS_PROJECT_ROOT/scripts/"*.service "$SANDBOX_ROOT/scripts/" 2>/dev/null || true
    cp "$HARNESS_PROJECT_ROOT/scripts/post-upgrade-cleanup.sh" \
       "$HARNESS_PROJECT_ROOT/scripts/logs-trigger-watcher.sh" \
       "$SANDBOX_ROOT/scripts/" 2>/dev/null || true

    # broadcast.sh functions (set_docker_image, display_help, ...) with the
    # final `main "$@"` invocation disabled so sourcing has no side effects.
    sed -e "s|/opt/broadcast|$SANDBOX_ROOT|g" \
        -e 's|^main "\$@"|: # main disabled by test harness|' \
        "$HARNESS_PROJECT_ROOT/broadcast.sh" > "$SANDBOX_ROOT/broadcast_functions.sh"

    harness_install_default_mocks
}

harness_destroy_sandbox() {
    if [ -n "$SANDBOX_ROOT" ] && [ -d "$SANDBOX_ROOT" ]; then
        rm -rf "$SANDBOX_ROOT"
    fi
    SANDBOX_ROOT=""
    SANDBOX_CALLS=""
}

# harness_mock <command> [body]
# Creates a PATH shim that logs "<command> <args>" to calls.log, then runs
# the given body (default: exit 0). The body sees the original "$@".
harness_mock() {
    local name="$1"
    local body="${2:-exit 0}"

    cat > "$SANDBOX_ROOT/mocks/$name" <<MOCK
#!/bin/bash
echo "$name \$*" >> "$SANDBOX_CALLS"
$body
MOCK
    chmod +x "$SANDBOX_ROOT/mocks/$name"
}

harness_install_default_mocks() {
    harness_mock systemctl 'if [ "${1:-}" = "is-enabled" ]; then exit "${SYSTEMCTL_IS_ENABLED_RC:-0}"; fi
exit 0'
    harness_mock docker 'case "$*" in
  *pg_dump*) printf "FAKE PG DUMP PAYLOAD\n" ;;
esac
exit 0'
    harness_mock su 'exit 0'
    harness_mock chown 'exit 0'
    harness_mock apt-get 'exit 0'
    harness_mock sleep 'exit 0'
    # sudo re-execs its arguments: file operations (cp, tar, rm) stay real,
    # while commands we shim (docker, chown) still resolve to their mocks
    # because the mocks dir stays first on PATH.
    harness_mock sudo 'exec "$@"'
    # Deterministic architecture for set_docker_image regardless of the
    # machine running the tests. Override with harness_mock_uname_arm64.
    harness_mock uname 'echo "x86_64"'
    # git: configurable remote URL for update() tests
    harness_mock git 'if [ "${1:-}" = "remote" ] && [ "${2:-}" = "get-url" ]; then echo "${GIT_MOCK_REMOTE_URL:-}"; fi
exit 0'
    # curl: emulates `curl -s -w "%{http_code}" -o <file> ...` used by
    # validate_license. Body and status come from CURL_MOCK_* variables.
    harness_mock curl 'out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
if [ -n "$out" ]; then printf "%s" "${CURL_MOCK_BODY:-}" > "$out"; fi
printf "%s" "${CURL_MOCK_HTTP_CODE:-200}"
exit 0'

    # Pin grep to the system binary: this development machine shims grep to
    # ugrep, whose behavior differs. The real servers run GNU grep; the
    # system grep is the closest faithful stand-in. Not logged (too noisy).
    cat > "$SANDBOX_ROOT/mocks/grep" <<'MOCK'
#!/bin/bash
exec /usr/bin/grep "$@"
MOCK
    chmod +x "$SANDBOX_ROOT/mocks/grep"
}

harness_mock_uname_arm64() {
    harness_mock uname 'echo "arm64"'
}

# Stub broadcast.sh inside the sandbox. Scripts under test invoke
# /opt/broadcast/broadcast.sh (rewritten to the sandbox path) for dispatch;
# the stub records the call instead of re-entering the real entry point.
harness_stub_broadcast_sh() {
    cat > "$SANDBOX_ROOT/broadcast.sh" <<STUB
#!/bin/bash
echo "broadcast.sh \$*" >> "$SANDBOX_CALLS"
exit 0
STUB
    chmod +x "$SANDBOX_ROOT/broadcast.sh"
}

# sandbox_run '<shell snippet>' [extra environment lines]
# Runs the snippet in a fresh bash with the real (path-rewritten) scripts
# sourced and the mocks first on PATH. Returns the snippet's exit code;
# combined stdout+stderr goes to stdout.
sandbox_run() {
    local snippet="$1"
    local env_setup="${2:-}"

    cat > "$SANDBOX_ROOT/run.sh" <<RUN
set -e
set -u
export PATH="$SANDBOX_ROOT/mocks:\$PATH"
export BROADCAST_ROOT="$SANDBOX_ROOT"
$env_setup
source "$SANDBOX_ROOT/broadcast_functions.sh"
for s in $HARNESS_SCRIPTS; do
    source "$SANDBOX_ROOT/scripts/\$s"
done
$snippet
RUN
    bash "$SANDBOX_ROOT/run.sh" 2>&1
}

# --- Assertions over calls.log -------------------------------------------

harness_assert_called() {
    local pattern="$1"
    local message="${2:-}"

    if ! /usr/bin/grep -qF -- "$pattern" "$SANDBOX_CALLS"; then
        echo -e "${RED}Assertion failed: no call matching '$pattern' was recorded${NC}"
        [ -n "$message" ] && echo -e "${RED}Message: $message${NC}"
        echo "Recorded calls:"
        sed 's/^/  /' "$SANDBOX_CALLS"
        TEST_FAILED=true
        return 1
    fi
    return 0
}

harness_assert_not_called() {
    local pattern="$1"
    local message="${2:-}"

    if /usr/bin/grep -qF -- "$pattern" "$SANDBOX_CALLS"; then
        echo -e "${RED}Assertion failed: unexpected call matching '$pattern' was recorded${NC}"
        [ -n "$message" ] && echo -e "${RED}Message: $message${NC}"
        TEST_FAILED=true
        return 1
    fi
    return 0
}

# harness_assert_call_order <pattern1> <pattern2> [...]
# Asserts each pattern appears in calls.log strictly after the previous one.
harness_assert_call_order() {
    local pos=0 pattern found
    for pattern in "$@"; do
        found=$(awk -v p="$pattern" -v start="$pos" \
            'NR > start && index($0, p) { print NR; exit }' "$SANDBOX_CALLS")
        if [ -z "$found" ]; then
            echo -e "${RED}Assertion failed: call '$pattern' not found after line $pos${NC}"
            echo "Recorded calls:"
            sed 's/^/  /' "$SANDBOX_CALLS"
            TEST_FAILED=true
            return 1
        fi
        pos=$found
    done
    return 0
}
