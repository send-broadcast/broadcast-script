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
HARNESS_SCRIPTS="common.sh preflight.sh restore.sh backup.sh update.sh upgrade.sh downgrade.sh trigger.sh monitor.sh diagnose.sh fix.sh health.sh recover.sh init-services.sh restart.sh two_factor.sh"

harness_make_sandbox() {
    SANDBOX_ROOT=$(mktemp -d)
    SANDBOX_CALLS="$SANDBOX_ROOT/calls.log"
    : > "$SANDBOX_CALLS"

    mkdir -p "$SANDBOX_ROOT/scripts" "$SANDBOX_ROOT/mocks" \
        "$SANDBOX_ROOT/app/triggers" "$SANDBOX_ROOT/app/storage" \
        "$SANDBOX_ROOT/app/monitor" "$SANDBOX_ROOT/app/uploads" \
        "$SANDBOX_ROOT/db/backups" "$SANDBOX_ROOT/db/init-scripts" \
        "$SANDBOX_ROOT/logs/cron" "$SANDBOX_ROOT/ssl" \
        "$SANDBOX_ROOT/etc/systemd/system" "$SANDBOX_ROOT/etc/sudoers.d" \
        "$SANDBOX_ROOT/etc/logrotate.d" "$SANDBOX_ROOT/home/broadcast" \
        "$SANDBOX_ROOT/var/run"

    # Rewrite ONLY the hardcoded path constants; everything else is the
    # original script text.
    local s
    for s in $HARNESS_SCRIPTS install.sh logs.sh start.sh stop.sh restart.sh; do
        sed -e "s|/opt/broadcast|$SANDBOX_ROOT|g" \
            -e "s|/etc/systemd/system|$SANDBOX_ROOT/etc/systemd/system|g" \
            -e "s|/etc/sudoers.d|$SANDBOX_ROOT/etc/sudoers.d|g" \
            -e "s|/etc/logrotate.d|$SANDBOX_ROOT/etc/logrotate.d|g" \
            -e "s|/home/broadcast|$SANDBOX_ROOT/home/broadcast|g" \
            -e "s|/var/run|$SANDBOX_ROOT/var/run|g" \
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
# No unit is in the failed state unless a test says so
if [ "${1:-}" = "is-failed" ]; then exit "${SYSTEMCTL_IS_FAILED_RC:-1}"; fi
exit 0'
    harness_mock docker 'case "$*" in
  *pg_dump*) printf "FAKE PG DUMP PAYLOAD\n" ;;
esac
exit 0'
    harness_mock su 'exit 0'
    # runuser: the broadcast user can read every file (harness_fake_ownership models it)
    harness_mock runuser 'exit 0'
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

# harness_fake_ownership [default owner]
# The sandbox runs unprivileged, so a real chown to uid 1000 or to the broadcast user fails. This
# replaces chown with a recorder and stat with a reader of those records, so a test can assert who
# owns a file after a sequence of chowns:
#   chown [-R] OWNER PATH...   records OWNER for the file (by inode, so it moves with an mv); with
#                              -R for everything below PATH too. A path that matches the glob in
#                              FAKE_CHOWN_FAILS fails like a chown on an immutable file.
#   stat -c FORMAT PATH        %U %u = the user, %G %g = the group of the last record for the file
#                              (the default owner when there is none: a file that the scripts
#                              create runs as root on a server); %a = the real mode; %i = the inode
#   chmod                      real, but only for paths inside the sandbox
#   runuser -u USER -- test -r PATH
#                              answers from the recorded owner and the real mode, as the kernel
#                              would (root reads all); FAKE_RUNUSER_DENY=1 makes every check fail
# A test may also append "R<TAB>OWNER<TAB>PATH" to .fake_owners: it covers PATH and everything
# below it, also files created later.
harness_fake_ownership() {
    : > "$SANDBOX_ROOT/.fake_owners"
    echo "${1:-dev:dev}" > "$SANDBOX_ROOT/.fake_default_owner"
    harness_mock chown 'recursive=-
args=()
for a in "$@"; do
  case "$a" in
    -R) recursive=R ;;
    -*) ;;
    *) args+=("$a") ;;
  esac
done
for p in "${args[@]:1}"; do
  if [ -n "${FAKE_CHOWN_FAILS:-}" ]; then
    case "$p" in
      $FAKE_CHOWN_FAILS) echo "chown: changing ownership of $p: Operation not permitted" >&2; exit 1 ;;
    esac
  fi
  if [ ! -e "$p" ]; then
    printf -- "-\t%s\t%s\t\n" "${args[0]}" "$p" >> "$BROADCAST_ROOT/.fake_owners"
    continue
  fi
  if [ "$recursive" = R ]; then
    find "$p" -print
  else
    printf "%s\n" "$p"
  fi | while IFS= read -r f; do
    printf -- "-\t%s\t%s\t%s\n" "${args[0]}" "$f" "$(ls -id "$f" | awk "{ print \$1 }")" >> "$BROADCAST_ROOT/.fake_owners"
  done
done
exit 0'
    harness_mock stat 'fmt="" path=""
while [ $# -gt 0 ]; do
  case "$1" in
    -c) fmt="$2"; shift 2 ;;
    *) path="$1"; shift ;;
  esac
done
[ -e "$path" ] || { echo "stat: cannot stat $path" >&2; exit 1; }
inode=$(ls -id "$path" | awk "{ print \$1 }")
owner=$(awk -F "\t" -v p="$path" -v i="$inode" "(\$4 != \"\" && \$4 == i) || (\$4 == \"\" && ((\$3 == p) || (\$1 == \"R\" && index(p, \$3 \"/\") == 1))) { o = \$2 } END { print o }" "$BROADCAST_ROOT/.fake_owners")
[ -n "$owner" ] || owner=$(cat "$BROADCAST_ROOT/.fake_default_owner" 2>/dev/null || echo dev:dev)
user="${owner%%:*}"
group="${owner#*:}"
mode=$(/usr/bin/stat -c %a "$path" 2>/dev/null || /usr/bin/stat -f %Lp "$path")
out="$fmt"
out="${out//%U/$user}"; out="${out//%u/$user}"
out="${out//%G/$group}"; out="${out//%g/$group}"
out="${out//%a/$mode}"; out="${out//%i/$inode}"
echo "$out"'
    harness_mock chmod 'last=""
for a in "$@"; do last="$a"; done
case "$last" in
  "$BROADCAST_ROOT"/*) exec /bin/chmod "$@" ;;
esac
exit 0'
    # Not on the calls log: the permission check that runuser and the service mock share
    cat > "$SANDBOX_ROOT/mocks/.fake_can_read" <<'CHECK'
#!/bin/bash
# .fake_can_read USER PATH: 0 when USER could open PATH for reading (owner, then group, then other)
user="$1" path="$2"
[ -e "$path" ] || exit 1
[ "$user" = root ] && exit 0
read -r og mode <<< "$("$(dirname "$0")/stat" -c "%U:%G %a" "$path")"
mode=$(printf "%03d" "$mode")
u="${og%%:*}" g="${og#*:}"
if [ "$u" = "$user" ]; then bits=${mode: -3:1}
elif [ "$g" = "$user" ]; then bits=${mode: -2:1}
else bits=${mode: -1}
fi
(( bits & 4 ))
CHECK
    chmod +x "$SANDBOX_ROOT/mocks/.fake_can_read"
    harness_mock runuser 'user=""
while [ $# -gt 0 ]; do
  case "$1" in
    -u) user="$2"; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
[ -z "${FAKE_RUNUSER_DENY:-}" ] || exit 1
if [ "${1:-}" = test ] && [ "${2:-}" = -r ]; then
  exec "$(dirname "$0")/.fake_can_read" "$user" "$3"
fi
exec "$@"'
}

# harness_owner_and_mode <path>: "<user>:<group> <mode>" as the fake ownership records it
harness_owner_and_mode() {
    BROADCAST_ROOT="$SANDBOX_ROOT" "$SANDBOX_ROOT/mocks/stat" -c "%u:%g %a" "$1"
}

# harness_service_reads_env_files
# broadcast.service runs `docker compose` as the broadcast user, and Compose reads .env, app/.env
# and db/.env. With this, `systemctl start|restart broadcast` fails, like Compose with "permission
# denied", when the broadcast user cannot read one of them (needs harness_fake_ownership). So does
# `su - broadcast -c '... docker compose ...'` (the upgrade's pull); it records .compose_failed.
# The unit's state is in .service_state (default active; a test may write activating, failed or
# inactive): a start or restart that works makes it active, one that fails leaves it as it was,
# stop makes it inactive, reset-failed turns failed into inactive, and is-active / is-failed
# answer from it.
harness_service_reads_env_files() {
    harness_mock su 'case "$*" in
  *"docker compose"*)
    for f in "$BROADCAST_ROOT/.env" "$BROADCAST_ROOT/app/.env" "$BROADCAST_ROOT/db/.env"; do
      [ -e "$f" ] || continue
      if ! "$BROADCAST_ROOT/mocks/.fake_can_read" broadcast "$f"; then
        echo "docker compose: open $f: permission denied" >&2
        echo "$f" >> "$BROADCAST_ROOT/.compose_failed"
        exit 1
      fi
    done
    ;;
esac
exit 0'
    harness_mock systemctl 'state_file="$BROADCAST_ROOT/.service_state"
state=$(cat "$state_file" 2>/dev/null || echo active)
unit=""
for a in "$@"; do
  case "$a" in
    broadcast|broadcast.service) unit=broadcast ;;
  esac
done
case "${1:-}" in
  is-enabled) exit "${SYSTEMCTL_IS_ENABLED_RC:-0}" ;;
  is-active)
    [ "$unit" = broadcast ] || exit 0
    case " $* " in *" --quiet "*) ;; *) echo "$state" ;; esac
    [ "$state" = active ]
    exit
    ;;
  is-failed)
    [ "$unit" = broadcast ] || exit 1
    case " $* " in *" --quiet "*) ;; *) echo "$state" ;; esac
    [ "$state" = failed ]
    exit
    ;;
  reset-failed)
    if [ "$unit" = broadcast ] && [ "$state" = failed ]; then echo inactive > "$state_file"; fi
    ;;
  stop)
    [ "$unit" = broadcast ] && echo inactive > "$state_file"
    ;;
  start|restart)
    if [ "$unit" = broadcast ]; then
        for f in "$BROADCAST_ROOT/.env" "$BROADCAST_ROOT/app/.env" "$BROADCAST_ROOT/db/.env"; do
          [ -e "$f" ] || continue
          if ! "$BROADCAST_ROOT/mocks/.fake_can_read" broadcast "$f"; then
            echo "broadcast.service: open $f: permission denied" >&2
            echo "$f" >> "$BROADCAST_ROOT/.service_failed"
            exit 1
          fi
        done
        echo active > "$state_file"
    fi
    ;;
esac
exit 0'
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
