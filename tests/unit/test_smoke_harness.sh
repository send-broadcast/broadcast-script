#!/bin/bash

# The VM smoke tests (tests/smoke) need a license key and real VMs, so CI never runs them. This
# checks, without a VM, the two parts of their harness that went wrong before:
#
#   * Vagrant 2.4 on macOS 27 reports every localhost port as in use, so "vagrant up" refuses to
#     start a VM unless the Vagrantfile carries the IsPortOpen patch. Every smoke script must get
#     its Vagrantfile from the shared helper (tests/smoke/lib/smoke_vm.sh), and that file must
#     carry the patch.
#   * The harness prints and saves VM output, including the TTY transcript of the interactive
#     install. The license key and the registry login must never reach that output, in whatever
#     form the terminal produced: echoed, inside a prompt, wrapped over two lines, broken up by
#     escape codes, cut short, or split over two writes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SMOKE_DIR="$PROJECT_ROOT/tests/smoke"
HELPER="$SMOKE_DIR/lib/smoke_vm.sh"

source "$SCRIPT_DIR/../test_framework.sh"

FAKE_KEY="FAKE-7Q2X-9KDM-4LPR-ZT"
FAKE_REGISTRY_LOGIN="fk-lgn-7731-qq"
FAKE_REGISTRY_PASSWORD="rEg1stryPa55w0rdXYZ"
ESC=$'\033'
CR=$'\r'

load_helper() {
    [ -f "$HELPER" ] || { echo "missing $HELPER"; return 1; }
    # shellcheck disable=SC1090
    source "$HELPER"
    smoke_redact_reset
    smoke_redact_add "$FAKE_KEY" "$FAKE_REGISTRY_LOGIN" "$FAKE_REGISTRY_PASSWORD"
}

# The output with line breaks, escape codes and backspaces taken out, so a secret the terminal
# split up is found again
flatten() {
    printf '%s' "$1" | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/[\r\n\x08]//g'
}

# Fails when any 6 consecutive characters of a secret remain in the output
assert_no_secret_left() {
    local output="$1" what="$2" flat secret i window leaked=""
    flat=$(flatten "$output")
    for secret in "$FAKE_KEY" "$FAKE_REGISTRY_LOGIN" "$FAKE_REGISTRY_PASSWORD"; do
        for ((i = 0; i + 6 <= ${#secret}; i++)); do
            window="${secret:i:6}"
            case "$flat" in
                *"$window"*) leaked="$leaked [$window]" ;;
            esac
        done
    done
    assert_equals "" "$leaked" "$what: secret characters left in the output"
}

redact_text() {
    printf '%s' "$1" | smoke_redact
}

test_every_smoke_script_uses_the_shared_helper() {
    local script found=0
    for script in "$SMOKE_DIR"/*.sh; do
        found=$((found + 1))
        if ! /usr/bin/grep -q 'source "$SCRIPT_DIR/lib/smoke_vm.sh"' "$script"; then
            assert_equals "sources lib/smoke_vm.sh" "does not" "$(basename "$script") must source the shared helper"
        fi
        if /usr/bin/grep -q 'Vagrant.configure' "$script"; then
            assert_equals "no Vagrantfile" "writes its own Vagrantfile" "$(basename "$script") must get its Vagrantfile from smoke_write_vagrantfile"
        fi
    done
    assert_not_equals "0" "$found" "smoke scripts found"
}

test_generated_vagrantfile_carries_the_port_patch() {
    load_helper || return 1
    local dir version extra patch_line configure_line
    for version in 24.04 26.04; do
        for extra in "" 'config.vm.provision "shell", inline: "true"'; do
            dir=$(mktemp -d)
            smoke_write_vagrantfile "$dir" "$version" 50999 broadcast-unit "$extra"
            assert_file_exists "$dir/Vagrantfile" "Vagrantfile written"
            assert_contains "$(cat "$dir/Vagrantfile")" "module IsPortOpen" "$version: IsPortOpen patch"
            assert_contains "$(cat "$dir/Vagrantfile")" "def is_port_open?(host, port)" "$version: is_port_open? override"
            assert_contains "$(cat "$dir/Vagrantfile")" 'config.vm.box = "cloud-image/ubuntu-'"$version"'"' "$version: box"
            assert_contains "$(cat "$dir/Vagrantfile")" 'qe.ssh_port = "50999"' "$version: ssh port"
            patch_line=$(/usr/bin/grep -n 'module IsPortOpen' "$dir/Vagrantfile" | cut -d: -f1)
            configure_line=$(/usr/bin/grep -n 'Vagrant.configure' "$dir/Vagrantfile" | cut -d: -f1)
            assert_equals "true" "$([ "${patch_line:-99}" -lt "${configure_line:-0}" ] && echo true || echo false)" "$version: patch comes before Vagrant.configure"
            if [ -n "$extra" ]; then
                assert_contains "$(cat "$dir/Vagrantfile")" "$extra" "$version: extra configuration kept"
            fi
            if command -v ruby >/dev/null 2>&1; then
                assert_equals "0" "$(ruby -c "$dir/Vagrantfile" >/dev/null 2>&1; echo $?)" "$version: Vagrantfile is valid Ruby"
            fi
            rm -rf "$dir"
        done
    done
}

test_redacts_the_key_in_plain_output() {
    load_helper || return 1
    local out
    out=$(redact_text "Validating license $FAKE_KEY for smoke-test.local"$'\n')
    assert_no_secret_left "$out" "plain line"
    assert_contains "$out" "smoke-test.local" "the rest of the line stays"
}

test_redacts_the_tty_echo_of_the_key() {
    load_helper || return 1
    local out
    out=$(redact_text "Please enter your license key: ${FAKE_KEY}${CR}"$'\n'"Checking...${CR}"$'\n')
    assert_no_secret_left "$out" "TTY echo"
    assert_contains "$out" "Please enter your license key:" "the prompt stays"
}

test_redacts_the_key_in_the_confirmation_prompt() {
    load_helper || return 1
    local out
    out=$(redact_text "Install Broadcast for [smoke-test.local] with license key [${FAKE_KEY}]? (y/n) ")
    assert_no_secret_left "$out" "confirmation prompt (no newline)"
    assert_contains "$out" "Install Broadcast for [smoke-test.local]" "the prompt stays"
}

test_redacts_a_key_wrapped_over_two_lines() {
    load_helper || return 1
    local out
    out=$(redact_text "with license key [${FAKE_KEY:0:9}${CR}"$'\n'"${FAKE_KEY:9}]? (y/n) ")
    assert_no_secret_left "$out" "key wrapped with CR LF"
    out=$(redact_text "license key ${FAKE_KEY:0:13} ${CR}${FAKE_KEY:13}"$'\n')
    assert_no_secret_left "$out" "key wrapped with a bare CR"
}

test_redacts_a_key_broken_up_by_escape_codes() {
    load_helper || return 1
    local out
    out=$(redact_text "${ESC}[1m${FAKE_KEY:0:5}${ESC}[K${FAKE_KEY:5:7}${ESC}[0m${FAKE_KEY:12}"$'\n')
    assert_no_secret_left "$out" "escape codes inside the key"
}

test_redacts_a_partial_echo() {
    load_helper || return 1
    local out
    out=$(redact_text "license key: ${FAKE_KEY:0:12}..."$'\n'"tail ${FAKE_KEY:10}"$'\n')
    assert_no_secret_left "$out" "start and end of the key on their own"
}

test_redacts_a_key_split_over_two_writes() {
    load_helper || return 1
    local out
    out=$( { printf 'license key [%s' "${FAKE_KEY:0:7}"; sleep 0.1; printf '%s]\n' "${FAKE_KEY:7}"; } | smoke_redact)
    assert_no_secret_left "$out" "key split over two writes"
    out=$( { printf 'license key [%s' "${FAKE_KEY:0:5}"; sleep 1; printf '%s]\n' "${FAKE_KEY:5}"; } | smoke_redact)
    assert_no_secret_left "$out" "key split over two writes a second apart"
}

test_masks_a_secret_registered_while_the_filter_runs() {
    load_helper || return 1
    local out late="LATE-SECRET-8841-QWZ"
    out=$( { printf 'started\n'; sleep 0.5; smoke_redact_add "$late"; printf 'registry password %s\n' "$late"; } | smoke_redact)
    case "$out" in
        *"${late:5:6}"*) assert_equals "masked" "visible" "a secret added after the filter started" ;;
    esac
    assert_contains "$out" "started" "earlier output stays"
}

test_redacts_registry_credentials() {
    load_helper || return 1
    local out
    out=$(redact_text "BROADCAST_REGISTRY_URL=gitea.example
BROADCAST_REGISTRY_LOGIN=$FAKE_REGISTRY_LOGIN
BROADCAST_REGISTRY_PASSWORD=$FAKE_REGISTRY_PASSWORD
{\"registry_url\":\"gitea.example\",\"registry_login\":\"$FAKE_REGISTRY_LOGIN\",\"registry_password\":\"$FAKE_REGISTRY_PASSWORD\"}
docker login gitea.example -u $FAKE_REGISTRY_LOGIN --password-stdin <<< $FAKE_REGISTRY_PASSWORD
")
    assert_no_secret_left "$out" "registry credentials"
    assert_contains "$out" "BROADCAST_REGISTRY_URL=gitea.example" "the registry URL is not a secret"
}

test_redacts_unregistered_secret_assignments() {
    load_helper || return 1
    local out
    out=$(redact_text "SECRET_KEY_BASE=abcdef0123456789
DATABASE_PASSWORD=unregistered-db-pw
POSTGRES_PASSWORD=unregistered-db-pw
LICENSE_KEY=OTHER-1111-2222-3333-44
TLS_DOMAIN=smoke-test.local
")
    case "$out" in
        *abcdef0123456789*|*unregistered-db-pw*|*OTHER-1111*) assert_equals "masked" "visible" "secret values in KEY=value lines" ;;
    esac
    assert_contains "$out" "TLS_DOMAIN=smoke-test.local" "non-secret assignments stay"
}

test_redacts_a_saved_file_in_place() {
    load_helper || return 1
    local file
    file=$(mktemp)
    printf 'spawn ssh ...\r\nPlease enter your license key: %s\r\nInstall Broadcast for [smoke-test.local] with license key [%s]? ' "$FAKE_KEY" "$FAKE_KEY" > "$file"
    smoke_redact_file "$file"
    assert_no_secret_left "$(cat "$file")" "saved transcript"
    assert_contains "$(cat "$file")" "Install Broadcast for [smoke-test.local]" "the transcript keeps its text"
    rm -f "$file"
}

run_smoke_harness_tests() {
    init_test_framework

    run_test "test_every_smoke_script_uses_the_shared_helper" test_every_smoke_script_uses_the_shared_helper
    run_test "test_generated_vagrantfile_carries_the_port_patch" test_generated_vagrantfile_carries_the_port_patch
    run_test "test_redacts_the_key_in_plain_output" test_redacts_the_key_in_plain_output
    run_test "test_redacts_the_tty_echo_of_the_key" test_redacts_the_tty_echo_of_the_key
    run_test "test_redacts_the_key_in_the_confirmation_prompt" test_redacts_the_key_in_the_confirmation_prompt
    run_test "test_redacts_a_key_wrapped_over_two_lines" test_redacts_a_key_wrapped_over_two_lines
    run_test "test_redacts_a_key_broken_up_by_escape_codes" test_redacts_a_key_broken_up_by_escape_codes
    run_test "test_redacts_a_partial_echo" test_redacts_a_partial_echo
    run_test "test_redacts_a_key_split_over_two_writes" test_redacts_a_key_split_over_two_writes
    run_test "test_masks_a_secret_registered_while_the_filter_runs" test_masks_a_secret_registered_while_the_filter_runs
    run_test "test_redacts_registry_credentials" test_redacts_registry_credentials
    run_test "test_redacts_unregistered_secret_assignments" test_redacts_unregistered_secret_assignments
    run_test "test_redacts_a_saved_file_in_place" test_redacts_a_saved_file_in_place

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    if type smoke_redact_cleanup >/dev/null 2>&1; then smoke_redact_cleanup; fi
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_smoke_harness_tests
fi
