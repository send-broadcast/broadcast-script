#!/bin/bash

# Unit tests for install() (scripts/install.sh) and the installer helpers in
# scripts/common.sh: idempotent cron entries, apt that never stops at a
# question, the registry password kept off the process list, .env parsing
# that survives spaces, the pinned fail2ban checksum, the scheduled or
# skipped reboot, and prompts that stop with a message at end of input.
#
# install() runs for real inside the harness sandbox. Every system command it
# reaches (useradd, ufw, apt-get, dpkg, systemctl, docker, crontab, shutdown,
# ...) is a recording mock; crontab keeps its table in a sandbox file, so a
# second install run sees what the first one wrote.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

REGISTRY_PASSWORD='s3cret pass=word'

setup_sandbox() {
    harness_make_sandbox

    echo "mail.example.com" > "$SANDBOX_ROOT/.domain"
    echo "KEY-1" > "$SANDBOX_ROOT/.license"
    printf 'BROADCAST_REGISTRY_URL=registry.example.com\nBROADCAST_REGISTRY_LOGIN=customer\nBROADCAST_REGISTRY_PASSWORD=%s\n' \
        "$REGISTRY_PASSWORD" > "$SANDBOX_ROOT/.env"
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast:latest" > "$SANDBOX_ROOT/.image"

    harness_mock id 'exit 0'
    harness_mock useradd
    harness_mock usermod
    harness_mock ufw
    harness_mock dpkg 'if [ "${1:-}" = "--print-architecture" ]; then echo amd64; fi'
    harness_mock timedatectl
    harness_mock fallocate
    harness_mock mkswap
    harness_mock swapon
    harness_mock free 'echo "Mem: 4000000000 0 0"'
    harness_mock install
    harness_mock chmod
    harness_mock tee 'cat > /dev/null'
    harness_mock shutdown
    harness_mock sha256sum "exit \${MOCK_SHA_RC:-0}"
    # apt-get records the environment that decides whether it may prompt
    harness_mock apt-get "echo \"apt-get-env DEBIAN_FRONTEND=\${DEBIAN_FRONTEND:-} NEEDRESTART_MODE=\${NEEDRESTART_MODE:-}\" >> \"$SANDBOX_CALLS\""
    # crontab keeps a real table in the sandbox. `crontab -` reads all of
    # stdin before replacing the table, as the real one does, so the
    # `(crontab -l; echo ...) | crontab -` pipeline does not race itself.
    harness_mock crontab "if [ \"\${1:-}\" = \"-l\" ]; then cat \"$SANDBOX_ROOT/crontab\" 2>/dev/null || exit 1; else cat > \"$SANDBOX_ROOT/crontab.new\" && mv \"$SANDBOX_ROOT/crontab.new\" \"$SANDBOX_ROOT/crontab\"; fi"
    # su records what it was given on stdin, separately from its arguments
    harness_mock su "cat > \"$SANDBOX_ROOT/su.stdin\""
    # sudo: drop -u <user> / -H, then run the command (mocks stay first on PATH)
    harness_mock sudo 'while [ $# -gt 0 ]; do case "$1" in -u) shift 2 ;; -H) shift ;; *) break ;; esac; done
exec "$@"'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

run_install() {
    sandbox_run "source \"$SANDBOX_ROOT/scripts/install.sh\"; install" "${1:-}"
}

test_running_install_twice_schedules_each_cron_job_once() {
    run_install >/dev/null
    run_install >/dev/null

    local name count
    for name in monitor trigger health recover update; do
        count=$(/usr/bin/grep -c "broadcast.sh $name " "$SANDBOX_ROOT/crontab")
        assert_equals "1" "$count" "the $name job must appear exactly once after two installs"
    done
}

test_cron_entries_keep_unrelated_jobs() {
    echo "15 3 * * * /usr/local/bin/customer-job" > "$SANDBOX_ROOT/crontab"

    run_install >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/crontab")" "customer-job" "an existing unrelated job must be kept"
}

test_every_apt_call_is_non_interactive() {
    run_install >/dev/null

    if /usr/bin/grep "^apt-get-env" "$SANDBOX_CALLS" | /usr/bin/grep -qv "DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a"; then
        echo "Assertion failed: an apt-get call could stop at a prompt:"
        /usr/bin/grep "^apt-get-env" "$SANDBOX_CALLS" | sed 's/^/  /'
        TEST_FAILED=true
        return 1
    fi
    harness_assert_called "apt-get -o DPkg::Lock::Timeout=600" "apt must wait for the first-boot apt lock"
    harness_assert_called "upgrade -y" "the system upgrade must still run"
}

test_registry_password_never_appears_in_a_command_line() {
    run_install >/dev/null

    harness_assert_called "su - broadcast -c docker login 'registry.example.com' -u 'customer' --password-stdin" \
        "the login must still run as the broadcast user"
    harness_assert_not_called "s3cret" "the password must not be in any command's arguments"
    assert_equals "$REGISTRY_PASSWORD" "$(cat "$SANDBOX_ROOT/su.stdin")" \
        "the full password, space and '=' included, must arrive on stdin"
}

test_load_registry_info_keeps_spaces_and_equals_signs() {
    local output
    output=$(sandbox_run 'load_registry_info; printf "[%s]" "$BROADCAST_REGISTRY_PASSWORD"')

    assert_equals "[$REGISTRY_PASSWORD]" "$output" "the value must be exported unchanged"
}

test_fail2ban_checksum_mismatch_stops_the_install() {
    local output rc=0
    output=$(run_install "export MOCK_SHA_RC=1") || rc=$?

    assert_equals "1" "$rc" "a package that fails its checksum must stop the install"
    assert_contains "$output" "checksum" "the reason must be shown"
    harness_assert_not_called "dpkg -i" "an unverified package must never be installed"
}

test_fail2ban_package_is_verified_before_install() {
    run_install >/dev/null

    harness_assert_call_order "sha256sum -c" "dpkg -i" "systemctl enable fail2ban"
}

test_install_schedules_the_reboot_instead_of_rebooting_now() {
    local output
    output=$(run_install)

    harness_assert_called "shutdown -r +1" "the reboot must be scheduled so the session ends cleanly"
    harness_assert_not_called "sudo reboot" "no immediate reboot"
    if /usr/bin/grep -q "^reboot" "$SANDBOX_CALLS"; then
        echo "Assertion failed: reboot was run directly"
        TEST_FAILED=true
    fi
    assert_contains "$output" "reboot in 1 minute" "the operator must be warned"
}

test_no_reboot_skips_the_reboot() {
    local output
    output=$(run_install "export BROADCAST_NO_REBOOT=1")

    harness_assert_not_called "shutdown" "--no-reboot must not schedule a reboot"
    assert_contains "$output" "Reboot skipped" "the operator must be told"
}

test_install_keeps_the_image_selected_before_it_ran() {
    # set_docker_image runs before install(); install must not rewrite it
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast-arm:latest" > "$SANDBOX_ROOT/.image"
    echo "TARGETARCH=arm64" >> "$SANDBOX_ROOT/.image"

    run_install >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/.image")" "broadcast-arm" "the arm64 image chosen before install must stand"
}

test_domain_prompt_stops_with_a_message_at_end_of_input() {
    rm -f "$SANDBOX_ROOT/.domain"

    local output rc=0
    output=$(sandbox_run "check_installation_domain < /dev/null") || rc=$?

    assert_equals "1" "$rc" "end of input must stop the prompt"
    assert_contains "$output" "No input available" "the reason must be shown, not a silent exit"
    assert_file_not_exists "$SANDBOX_ROOT/.domain" "nothing may be written"
}

test_domain_prompt_rejects_an_invalid_domain_then_accepts_a_valid_one() {
    rm -f "$SANDBOX_ROOT/.domain"

    local output
    output=$(sandbox_run "printf 'not a domain\nmail.example.org\n' | check_installation_domain")

    assert_contains "$output" "not a valid domain" "the invalid answer must be refused"
    assert_equals "mail.example.org" "$(cat "$SANDBOX_ROOT/.domain")" "the valid answer must be stored"
}

test_license_prompt_stops_with_a_message_at_end_of_input() {
    rm -f "$SANDBOX_ROOT/.license"

    local output rc=0
    output=$(sandbox_run "ask_license < /dev/null") || rc=$?

    assert_equals "1" "$rc" "end of input must stop the license prompt"
    assert_contains "$output" "No input available" "the reason must be shown"
}

run_install_tests() {
    init_test_framework
    setup_test_env
    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    run_test "test_running_install_twice_schedules_each_cron_job_once" test_running_install_twice_schedules_each_cron_job_once
    run_test "test_cron_entries_keep_unrelated_jobs" test_cron_entries_keep_unrelated_jobs
    run_test "test_every_apt_call_is_non_interactive" test_every_apt_call_is_non_interactive
    run_test "test_registry_password_never_appears_in_a_command_line" test_registry_password_never_appears_in_a_command_line
    run_test "test_load_registry_info_keeps_spaces_and_equals_signs" test_load_registry_info_keeps_spaces_and_equals_signs
    run_test "test_fail2ban_checksum_mismatch_stops_the_install" test_fail2ban_checksum_mismatch_stops_the_install
    run_test "test_fail2ban_package_is_verified_before_install" test_fail2ban_package_is_verified_before_install
    run_test "test_install_schedules_the_reboot_instead_of_rebooting_now" test_install_schedules_the_reboot_instead_of_rebooting_now
    run_test "test_no_reboot_skips_the_reboot" test_no_reboot_skips_the_reboot
    run_test "test_install_keeps_the_image_selected_before_it_ran" test_install_keeps_the_image_selected_before_it_ran
    run_test "test_domain_prompt_stops_with_a_message_at_end_of_input" test_domain_prompt_stops_with_a_message_at_end_of_input
    run_test "test_domain_prompt_rejects_an_invalid_domain_then_accepts_a_valid_one" test_domain_prompt_rejects_an_invalid_domain_then_accepts_a_valid_one
    run_test "test_license_prompt_stops_with_a_message_at_end_of_input" test_license_prompt_stops_with_a_message_at_end_of_input

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_install_tests
fi
