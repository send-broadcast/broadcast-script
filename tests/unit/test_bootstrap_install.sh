#!/bin/bash

# Unit tests for the one-line bootstrap installer (install.sh at the repo
# root), the target of `curl -fsSL https://sendbroadcast.net/install.sh |
# sudo bash`.
#
# The script is run the way customers run it: piped into bash on stdin. Its
# path constants are pointed at a scratch directory and PATH holds ONLY a
# mocks directory (real coreutils are linked in by name), so every external
# command the script reaches is either a recorded mock or deliberately real.
# `git clone` is mocked to create a checkout whose broadcast.sh records each
# call together with what it read from stdin — which is how the tests see
# whether the installer got the terminal, /dev/null, or (the bug this guards
# against) the rest of the piped script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"

BS=""        # scratch root
BS_CALLS=""  # calls.log

bs_mock() {
    local name="$1" body="${2:-exit 0}"
    cat > "$BS/bin/$name" <<MOCK
#!/bin/bash
echo "$name \$*" >> "$BS_CALLS"
$body
MOCK
    chmod +x "$BS/bin/$name"
}

setup_bootstrap() {
    BS=$(mktemp -d)
    BS_CALLS="$BS/calls.log"
    : > "$BS_CALLS"
    mkdir -p "$BS/bin" "$BS/opt" "$BS/etc"

    # Real tools the script legitimately uses, linked in by name. Anything
    # not listed here (git, apt-get, ss, ...) does not exist unless mocked.
    local tool path
    for tool in bash awk sed tee date ls cat cp dirname mkdir chmod touch rm head env sleep; do
        path=$(command -v "$tool") && ln -s "$path" "$BS/bin/$tool"
    done
    # Pin grep to the system binary (this machine shims grep to ugrep)
    ln -s /usr/bin/grep "$BS/bin/grep"

    cat > "$BS/os-release" <<'EOF'
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu
EOF
    echo "MemTotal:        4027244 kB" > "$BS/meminfo"
    echo "TTY-ANSWER" > "$BS/tty"

    bs_mock id 'if [ "${1:-}" = "-u" ]; then echo "${MOCK_UID:-0}"; fi'
    bs_mock uname 'echo "${MOCK_ARCH:-x86_64}"'
    bs_mock df 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "/dev/sda1 41000000 1000000 ${MOCK_DF_FREE_KB:-40000000} 3% /"'
    bs_mock ss 'printf "%s" "${MOCK_SS:-}"'
    bs_mock curl 'exit 0'
    bs_mock jq 'exit 0'
    bs_mock apt-get 'echo "apt-get-env DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}" >> "'"$BS_CALLS"'"
case " $* " in *" git"*) cp "'"$BS"'/git-mock" "'"$BS"'/bin/git" ;; esac
exit 0'

    # git: `clone` creates a checkout with a recording broadcast.sh
    cat > "$BS/git-mock" <<MOCK
#!/bin/bash
echo "git \$*" >> "$BS_CALLS"
args=" \$* "
case "\$args" in
  *" clone "*)
    dest="\${@: -1}"
    mkdir -p "\$dest/.git"
    cat > "\$dest/broadcast.sh" <<'STUB'
#!/bin/bash
if IFS= read -r line; then input="\$line"; else input="EOF"; fi
echo "broadcast.sh \$* stdin=\$input no_reboot=\${BROADCAST_NO_REBOOT:-unset}" >> "$BS_CALLS"
case "\$1" in
  validate_license) exit "\${MOCK_VALIDATE_RC:-0}" ;;
  install) exit "\${MOCK_INSTALL_RC:-0}" ;;
esac
STUB
    chmod +x "\$dest/broadcast.sh"
    ;;
  *" remote get-url "*) echo "\${MOCK_GIT_ORIGIN:-}" ;;
  *" status "*) printf "%s" "\${MOCK_GIT_DIRTY:-}" ;;
esac
exit 0
MOCK
    chmod +x "$BS/git-mock"
    cp "$BS/git-mock" "$BS/bin/git"

    # The script under test: install.sh minus its final call, then the
    # constants redirected into the scratch root, then the call itself.
    # Built as one file so it can be piped into bash like curl does.
    {
        sed '$d' "$PROJECT_ROOT/install.sh"
        cat <<EOF
BROADCAST_DIR="$BS/opt/broadcast"
INSTALL_LOG="$BS/install.log"
SYSTEMD_UNIT="$BS/etc/broadcast.service"
OS_RELEASE_FILE="$BS/os-release"
MEMINFO_FILE="$BS/meminfo"
TTY_DEVICE="\${MOCK_TTY:-$BS/no-tty}"
broadcast_bootstrap "\$@"
EOF
    } > "$BS/bootstrap.sh"
}

teardown_bootstrap() {
    [ -n "$BS" ] && [ -d "$BS" ] && rm -rf "$BS"
    BS=""
}

# bs_run [env assignments...] [-- script args...]
# Pipes the bootstrap into bash exactly like `curl ... | sudo bash -s -- args`.
bs_run() {
    local envs=() args=()
    while [ $# -gt 0 ]; do
        if [ "$1" = "--" ]; then shift; args=("$@"); break; fi
        envs+=("$1"); shift
    done
    cat "$BS/bootstrap.sh" | env -i HOME="$BS" PATH="$BS/bin" "${envs[@]}" "$BS/bin/bash" -s -- "${args[@]}" 2>&1
}

assert_called() {
    if ! /usr/bin/grep -qF -- "$1" "$BS_CALLS"; then
        echo -e "${RED}Assertion failed: no call matching '$1'${NC}"
        [ -n "${2:-}" ] && echo -e "${RED}Message: $2${NC}"
        sed 's/^/  /' "$BS_CALLS"
        TEST_FAILED=true
        return 1
    fi
}

assert_not_called() {
    if /usr/bin/grep -qF -- "$1" "$BS_CALLS"; then
        echo -e "${RED}Assertion failed: unexpected call matching '$1'${NC}"
        [ -n "${2:-}" ] && echo -e "${RED}Message: $2${NC}"
        sed 's/^/  /' "$BS_CALLS"
        TEST_FAILED=true
        return 1
    fi
}

# Every path and its size, so "nothing was changed" can be compared exactly.
snapshot() {
    (cd "$BS/opt" && find . -exec ls -ld {} + 2>/dev/null | awk '{print $1, $5, $NF}' | sort)
}

make_installation() {
    mkdir -p "$BS/opt/broadcast/app" "$BS/opt/broadcast/db/postgres-data" "$BS/opt/broadcast/.git"
    echo "SECRET_KEY_BASE=keep-me" > "$BS/opt/broadcast/app/.env"
    echo "PG_VERSION" > "$BS/opt/broadcast/db/postgres-data/PG_VERSION"
}

# --- Existing installations are never touched ------------------------------

test_refuses_an_existing_installation_and_changes_nothing() {
    make_installation
    local before after output rc=0
    before=$(snapshot)

    output=$(bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1) || rc=$?
    after=$(snapshot)

    assert_equals "3" "$rc" "an existing installation must exit 3"
    assert_contains "$output" "already installed" "the refusal must say why"
    assert_contains "$output" "broadcast.sh upgrade" "the refusal must point at upgrade"
    assert_contains "$output" "broadcast.sh update" "the refusal must point at update"
    assert_equals "$before" "$after" "not a single file may change"
    assert_equals "SECRET_KEY_BASE=keep-me" "$(cat "$BS/opt/broadcast/app/.env")" "the encryption keys must survive"
    assert_not_called "git" "no git operation on an existing install"
    assert_not_called "apt-get" "no package operation on an existing install"
    assert_file_not_exists "$BS/install.log" "a refusal writes nothing, not even the log"
}

test_refuses_when_only_the_database_remains() {
    mkdir -p "$BS/opt/broadcast/db/postgres-data"
    echo "x" > "$BS/opt/broadcast/db/postgres-data/PG_VERSION"

    local output rc=0
    output=$(bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1) || rc=$?

    assert_equals "3" "$rc" "a database directory alone marks an installation"
    assert_contains "$output" "postgres-data" "the marker found should be named"
}

test_refuses_when_the_service_unit_exists() {
    touch "$BS/etc/broadcast.service"

    local rc=0
    bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 >/dev/null || rc=$?

    assert_equals "3" "$rc" "an installed systemd unit marks an installation"
    assert_not_called "git" "nothing may be fetched"
}

test_refuses_a_directory_that_is_not_a_broadcast_checkout() {
    mkdir -p "$BS/opt/broadcast"
    echo "someone else's file" > "$BS/opt/broadcast/notes.txt"
    local before after output rc=0
    before=$(snapshot)

    output=$(bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1) || rc=$?
    after=$(snapshot)

    assert_equals "1" "$rc" "unknown content must be refused"
    assert_contains "$output" "not a Broadcast checkout" "the refusal must say why"
    assert_equals "$before" "$after" "unknown content must be left exactly as it was"
}

# --- No terminal and no answers: fail fast, change nothing -----------------

test_fails_fast_without_a_terminal_or_environment() {
    local output rc=0 start end
    start=$(date +%s)
    output=$(bs_run) || rc=$?
    end=$(date +%s)

    assert_equals "2" "$rc" "no terminal and no answers must exit 2"
    assert_contains "$output" "BROADCAST_DOMAIN=" "the message must show the non-interactive command"
    assert_not_called "git" "nothing may be fetched"
    assert_not_called "apt-get" "nothing may be installed"
    assert_file_not_exists "$BS/opt/broadcast" "nothing may be created"
    if [ $((end - start)) -gt 5 ]; then
        echo "Assertion failed: took $((end - start))s; must fail fast, not wait or loop"
        TEST_FAILED=true
    fi
}

test_fails_fast_when_only_the_domain_is_given() {
    local rc=0
    bs_run BROADCAST_DOMAIN=mail.example.com >/dev/null || rc=$?

    assert_equals "2" "$rc" "a missing license with no terminal must exit 2"
    assert_not_called "git" "nothing may be fetched"
}

test_rejects_an_invalid_domain_before_doing_anything() {
    local output rc=0
    output=$(bs_run "BROADCAST_DOMAIN=not a domain" BROADCAST_LICENSE=KEY-1) || rc=$?

    assert_equals "1" "$rc" "an invalid domain must be rejected"
    assert_contains "$output" "not a valid domain" "the message must say why"
    assert_not_called "git" "nothing may be fetched"
}

test_rejects_a_license_with_injection_characters() {
    local rc=0
    bs_run BROADCAST_DOMAIN=mail.example.com 'BROADCAST_LICENSE=KEY", "domain":"x' >/dev/null || rc=$?

    assert_equals "1" "$rc" "a key that could break the JSON body must be rejected"
    assert_not_called "git" "nothing may be fetched"
}

# --- Non-interactive install -----------------------------------------------

test_non_interactive_install_clones_main_and_validates_first() {
    local output rc=0
    output=$(bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=ABCDE-12345) || rc=$?

    assert_equals "0" "$rc" "a successful install exits 0"
    assert_called "git clone --quiet --branch main https://github.com/send-broadcast/broadcast-script.git $BS/opt/broadcast" \
        "the canonical repo must be cloned at main"
    assert_equals "mail.example.com" "$(cat "$BS/opt/broadcast/.domain")" ".domain must hold the given domain"
    assert_equals "ABCDE-12345" "$(cat "$BS/opt/broadcast/.license")" ".license must hold the given key"
    # validate_license must run BEFORE install, so a bad key fails in seconds
    local first second
    first=$(/usr/bin/grep -n "broadcast.sh validate_license" "$BS_CALLS" | cut -d: -f1)
    second=$(/usr/bin/grep -n "broadcast.sh install" "$BS_CALLS" | cut -d: -f1)
    if [ -z "$first" ] || [ -z "$second" ] || [ "$first" -ge "$second" ]; then
        echo "Assertion failed: validate_license must run before install"
        sed 's/^/  /' "$BS_CALLS"
        TEST_FAILED=true
    fi
}

test_installer_never_reads_the_piped_script_as_input() {
    # Under `curl | bash` the bootstrap's stdin IS the script. A child that
    # inherits it reads script text as the domain. With every answer given,
    # the installer must see an empty stdin (EOF), not script text.
    bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 >/dev/null

    assert_called "broadcast.sh install stdin=EOF" "the installer must get /dev/null when nothing needs asking"
    assert_called "broadcast.sh validate_license stdin=EOF" "validation must not read the pipe either"
}

test_license_rejection_stops_before_the_install_and_removes_the_key() {
    local output rc=0
    output=$(bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=BAD-KEY MOCK_VALIDATE_RC=1) || rc=$?

    assert_equals "1" "$rc" "a rejected key must fail the install"
    assert_contains "$output" "not accepted" "the message must say the key was rejected"
    assert_not_called "broadcast.sh install" "nothing heavy may run after a rejected key"
    assert_file_not_exists "$BS/opt/broadcast/.license" "the rejected key must be removed so a re-run starts clean"
}

test_installer_failure_reports_the_log() {
    local output rc=0
    output=$(bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 MOCK_INSTALL_RC=7) || rc=$?

    assert_equals "1" "$rc" "an installer failure must fail the bootstrap"
    assert_contains "$output" "exit 7" "the installer's exit code should be shown"
    assert_contains "$output" "install.log" "the log location must be given for support"
}

test_writes_a_private_install_log() {
    bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 >/dev/null

    assert_file_exists "$BS/install.log" "the install must be logged"
    assert_contains "$(cat "$BS/install.log")" "Running the Broadcast installer" "the log must hold the run's output"
    local mode
    mode=$(ls -l "$BS/install.log" | cut -c1-10)
    assert_equals "-rw-------" "$mode" "the log can contain the license key, so it must be root-only"
}

# --- Interactive install ---------------------------------------------------

test_interactive_install_hands_the_installer_the_terminal() {
    local rc=0
    bs_run MOCK_TTY="$BS/tty" >/dev/null || rc=$?

    assert_equals "0" "$rc" "an interactive install exits 0"
    assert_called "broadcast.sh install stdin=TTY-ANSWER" "the installer's prompts must read the terminal"
    assert_not_called "broadcast.sh validate_license" "with no key yet, the installer's own prompt validates it"
}

test_a_key_from_the_environment_is_validated_with_the_terminal_attached() {
    # Domain unknown: validate_license goes through broadcast.sh, which asks
    # for the domain first — on the terminal, not the pipe.
    bs_run MOCK_TTY="$BS/tty" BROADCAST_LICENSE=KEY-1 >/dev/null

    assert_called "broadcast.sh validate_license stdin=TTY-ANSWER" "the domain prompt must read the terminal"
}

# --- Options ---------------------------------------------------------------

test_reboots_by_default_and_no_reboot_is_passed_through() {
    bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 >/dev/null
    assert_called "broadcast.sh install stdin=EOF no_reboot=0" "the default keeps the reboot"

    : > "$BS_CALLS"; rm -rf "$BS/opt/broadcast"
    bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 -- --no-reboot >/dev/null
    assert_called "broadcast.sh install stdin=EOF no_reboot=1" "--no-reboot must reach the installer"

    : > "$BS_CALLS"; rm -rf "$BS/opt/broadcast"
    bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 BROADCAST_NO_REBOOT=1 >/dev/null
    assert_called "broadcast.sh install stdin=EOF no_reboot=1" "BROADCAST_NO_REBOOT=1 must reach the installer"
}

test_ref_override_selects_the_branch() {
    bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 BROADCAST_REF=curl-installer >/dev/null

    assert_called "git clone --quiet --branch curl-installer" "BROADCAST_REF must select the branch"
}

# --- Partial earlier attempt -----------------------------------------------

test_resumes_a_partial_checkout_without_deleting_it() {
    mkdir -p "$BS/opt/broadcast/.git"
    echo "old.example.com" > "$BS/opt/broadcast/.domain"
    # The checkout's broadcast.sh, as a clone would have left it
    bs_run_clone_stub

    local rc=0
    bs_run MOCK_GIT_ORIGIN=https://github.com/Furvur/broadcast-script.git \
        BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 >/dev/null || rc=$?

    assert_equals "0" "$rc" "a partial checkout must be resumed"
    assert_not_called "git clone" "an existing checkout must not be re-cloned"
    assert_called "remote set-url origin https://github.com/send-broadcast/broadcast-script.git" \
        "a legacy origin must be moved to the canonical repo"
    assert_called "checkout --quiet -B main origin/main" "the checkout must be brought to main"
    assert_equals "mail.example.com" "$(cat "$BS/opt/broadcast/.domain")" "the given domain replaces the old answer"
    assert_called "broadcast.sh install" "the install must continue"
}

test_resume_refuses_a_modified_checkout() {
    mkdir -p "$BS/opt/broadcast/.git"
    bs_run_clone_stub

    local output rc=0
    output=$(bs_run MOCK_GIT_ORIGIN=https://github.com/send-broadcast/broadcast-script.git \
        "MOCK_GIT_DIRTY= M docker-compose.yml" \
        BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1) || rc=$?

    assert_equals "1" "$rc" "local edits must stop the resume"
    assert_contains "$output" "docker-compose.yml" "the edited file must be named"
    assert_not_called "checkout --quiet -B" "edited files must not be overwritten"
}

# Puts a recording broadcast.sh into an existing checkout (as clone would).
bs_run_clone_stub() {
    local tmp="$BS/stubclone"
    "$BS/git-mock" clone x "$tmp" >/dev/null
    cp "$tmp/broadcast.sh" "$BS/opt/broadcast/broadcast.sh"
    rm -rf "$tmp"
    : > "$BS_CALLS"
}

# --- Host checks -----------------------------------------------------------

test_requires_root() {
    local output rc=0
    output=$(bs_run MOCK_UID=1000 BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1) || rc=$?

    assert_equals "1" "$rc" "a non-root run must fail"
    assert_contains "$output" "sudo bash" "the message must show how to run it"
    assert_not_called "git" "nothing may be fetched"
}

test_rejects_an_unsupported_ubuntu_release() {
    sed -i.bak 's/24.04/22.04/' "$BS/os-release"

    local output rc=0
    output=$(bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1) || rc=$?

    assert_equals "1" "$rc" "22.04 must be refused"
    assert_contains "$output" "24.04 or 26.04" "the message must name the supported releases"
    assert_not_called "git" "nothing may be fetched"
}

test_accepts_ubuntu_26_04_on_arm64() {
    sed -i.bak 's/24.04/26.04/' "$BS/os-release"

    local rc=0
    bs_run MOCK_ARCH=aarch64 BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 >/dev/null || rc=$?

    assert_equals "0" "$rc" "26.04 on arm64 is supported"
}

test_rejects_an_unsupported_architecture() {
    local rc=0
    bs_run MOCK_ARCH=riscv64 BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 >/dev/null || rc=$?

    assert_equals "1" "$rc" "riscv64 must be refused"
}

test_refuses_when_ports_80_or_443_are_taken() {
    local output rc=0
    output=$(bs_run 'MOCK_SS=LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1,fd=6))' \
        BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1) || rc=$?

    assert_equals "1" "$rc" "a busy port 80 must stop the install"
    assert_contains "$output" "nginx" "the listener must be shown"
    assert_not_called "git" "nothing may be fetched"
}

test_warns_on_low_memory_and_refuses_a_full_disk() {
    echo "MemTotal:        1013244 kB" > "$BS/meminfo"
    local output rc=0
    output=$(bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1) || rc=$?
    assert_equals "0" "$rc" "low memory is a warning, not a failure"
    assert_contains "$output" "2 GB" "the memory warning must state the requirement"

    : > "$BS_CALLS"; rm -rf "$BS/opt/broadcast"
    rc=0
    output=$(bs_run MOCK_DF_FREE_KB=2000000 BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1) || rc=$?
    assert_equals "1" "$rc" "under 5 GB free must stop the install"
    assert_not_called "git" "nothing may be fetched"
}

test_installs_git_when_it_is_missing() {
    rm -f "$BS/bin/git"

    local rc=0
    bs_run BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 >/dev/null || rc=$?

    assert_equals "0" "$rc" "a server without git must still install"
    assert_called "install -y -qq git" "git must be installed with apt"
    assert_called "apt-get-env DEBIAN_FRONTEND=noninteractive" "apt must not stop at a question"
}

# --- Truncated download ----------------------------------------------------

test_a_truncated_download_runs_nothing() {
    local size cut rc
    size=$(wc -c < "$BS/bootstrap.sh")
    # The last cut drops exactly the final `broadcast_bootstrap "$@"` line;
    # the one before it stops part-way through that line.
    for cut in $((size / 4)) $((size / 2)) $((size * 3 / 4)) $((size - 10)) $((size - 25)); do
        : > "$BS_CALLS"
        head -c "$cut" "$BS/bootstrap.sh" | env -i HOME="$BS" PATH="$BS/bin" \
            BROADCAST_DOMAIN=mail.example.com BROADCAST_LICENSE=KEY-1 "$BS/bin/bash" -s >/dev/null 2>&1 || true
        if [ -s "$BS_CALLS" ] || [ -e "$BS/opt/broadcast" ]; then
            echo "Assertion failed: a download cut at byte $cut of $size ran commands:"
            sed 's/^/  /' "$BS_CALLS"
            TEST_FAILED=true
            return 1
        fi
    done
}

test_bootstrap_passes_shellcheck() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "  (shellcheck not installed — skipped)"
        return 0
    fi
    local output
    if ! output=$(shellcheck "$PROJECT_ROOT/install.sh" 2>&1); then
        echo "$output"
        TEST_FAILED=true
        return 1
    fi
}

run_bootstrap_tests() {
    init_test_framework
    setup_test_env
    TEST_SETUP_FUNCTION="setup_bootstrap"
    TEST_TEARDOWN_FUNCTION="teardown_bootstrap"

    run_test "test_refuses_an_existing_installation_and_changes_nothing" test_refuses_an_existing_installation_and_changes_nothing
    run_test "test_refuses_when_only_the_database_remains" test_refuses_when_only_the_database_remains
    run_test "test_refuses_when_the_service_unit_exists" test_refuses_when_the_service_unit_exists
    run_test "test_refuses_a_directory_that_is_not_a_broadcast_checkout" test_refuses_a_directory_that_is_not_a_broadcast_checkout
    run_test "test_fails_fast_without_a_terminal_or_environment" test_fails_fast_without_a_terminal_or_environment
    run_test "test_fails_fast_when_only_the_domain_is_given" test_fails_fast_when_only_the_domain_is_given
    run_test "test_rejects_an_invalid_domain_before_doing_anything" test_rejects_an_invalid_domain_before_doing_anything
    run_test "test_rejects_a_license_with_injection_characters" test_rejects_a_license_with_injection_characters
    run_test "test_non_interactive_install_clones_main_and_validates_first" test_non_interactive_install_clones_main_and_validates_first
    run_test "test_installer_never_reads_the_piped_script_as_input" test_installer_never_reads_the_piped_script_as_input
    run_test "test_license_rejection_stops_before_the_install_and_removes_the_key" test_license_rejection_stops_before_the_install_and_removes_the_key
    run_test "test_installer_failure_reports_the_log" test_installer_failure_reports_the_log
    run_test "test_writes_a_private_install_log" test_writes_a_private_install_log
    run_test "test_interactive_install_hands_the_installer_the_terminal" test_interactive_install_hands_the_installer_the_terminal
    run_test "test_a_key_from_the_environment_is_validated_with_the_terminal_attached" test_a_key_from_the_environment_is_validated_with_the_terminal_attached
    run_test "test_reboots_by_default_and_no_reboot_is_passed_through" test_reboots_by_default_and_no_reboot_is_passed_through
    run_test "test_ref_override_selects_the_branch" test_ref_override_selects_the_branch
    run_test "test_resumes_a_partial_checkout_without_deleting_it" test_resumes_a_partial_checkout_without_deleting_it
    run_test "test_resume_refuses_a_modified_checkout" test_resume_refuses_a_modified_checkout
    run_test "test_requires_root" test_requires_root
    run_test "test_rejects_an_unsupported_ubuntu_release" test_rejects_an_unsupported_ubuntu_release
    run_test "test_accepts_ubuntu_26_04_on_arm64" test_accepts_ubuntu_26_04_on_arm64
    run_test "test_rejects_an_unsupported_architecture" test_rejects_an_unsupported_architecture
    run_test "test_refuses_when_ports_80_or_443_are_taken" test_refuses_when_ports_80_or_443_are_taken
    run_test "test_warns_on_low_memory_and_refuses_a_full_disk" test_warns_on_low_memory_and_refuses_a_full_disk
    run_test "test_installs_git_when_it_is_missing" test_installs_git_when_it_is_missing
    run_test "test_a_truncated_download_runs_nothing" test_a_truncated_download_runs_nothing
    run_test "test_bootstrap_passes_shellcheck" test_bootstrap_passes_shellcheck

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_bootstrap_tests
fi
