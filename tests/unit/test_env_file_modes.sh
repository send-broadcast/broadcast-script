#!/bin/bash

# The env files hold secrets: /opt/broadcast/.env the registry login, app/.env the database password
# and the Rails keys, db/.env the database password. broadcast.service runs `docker compose` as the
# broadcast user, and Compose reads all three, so their one correct state is broadcast:broadcast,
# mode 600. install, upgrade, the nightly update, restore and fix set it (secure_env_files); every
# script that rewrites a file replaces it in one step (env_file_begin / env_file_commit).
#
# The rule above all: the service must keep running, whatever state a server is in. When the
# broadcast user cannot read a file after the change, the previous owner and mode come back and
# the command still succeeds. Symlinks and servers without a broadcast user are left as they are.
#
# The harness fakes ownership (the tests run unprivileged): a file the scripts create belongs to
# root, as on a server, and `systemctl start|restart broadcast` fails when the broadcast user could
# not read an env file, as Compose does.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../test_framework.sh"
source "$SCRIPT_DIR/../script_harness.sh"

ENV_FILES=".env app/.env db/.env"
# update starts broadcast.sh again for the steps after its pull; in the sandbox they run inline
UPDATE_INLINE="export BROADCAST_UPDATE_REEXEC=1"
LICENSE_RESPONSE="export CURL_MOCK_HTTP_CODE=200
export CURL_MOCK_BODY='{\"registry_url\":\"r2.example\",\"registry_login\":\"l2\",\"registry_password\":\"pw2\"}'"

# own OWNER PATH: the file now has this owner, as after a real chown
own() {
    printf -- "-\t%s\t%s\t%s\n" "$1" "$2" "$(ls -id "$2" | awk '{ print $1 }')" >> "$SANDBOX_ROOT/.fake_owners"
}

setup_sandbox() {
    harness_make_sandbox
    harness_fake_ownership root:root
    harness_service_reads_env_files
    harness_stub_broadcast_sh
    echo "test.example.com" > "$SANDBOX_ROOT/.domain"
    echo "test-license" > "$SANDBOX_ROOT/.license"
    echo "2.0.0" > "$SANDBOX_ROOT/.current_version"
    echo "DOCKER_IMAGE=gitea.hostedapp.org/broadcast/broadcast:2.0.0" > "$SANDBOX_ROOT/.image"
    printf 'BROADCAST_REGISTRY_URL=r.example\nBROADCAST_REGISTRY_LOGIN=l\nBROADCAST_REGISTRY_PASSWORD=pw\n' > "$SANDBOX_ROOT/.env"
    printf 'SECRET_KEY_BASE=skb\nDATABASE_PASSWORD=dbpw\nTLS_DOMAIN=test.example.com\nACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=a\nACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=b\nACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=c\n' > "$SANDBOX_ROOT/app/.env"
    printf 'POSTGRES_PASSWORD=dbpw\n' > "$SANDBOX_ROOT/db/.env"
    local f
    for f in $ENV_FILES; do
        /bin/chmod 644 "$SANDBOX_ROOT/$f"
    done
    # As install leaves them: everything in /opt/broadcast belongs to the broadcast user
    while IFS= read -r f; do own broadcast:broadcast "$f"; done < <(find "$SANDBOX_ROOT" -print)
    harness_mock id 'exit 0'
    harness_mock crontab 'exit 0'
}

teardown_sandbox() {
    harness_destroy_sandbox
}

assert_env_files_are_private() {
    local why="$1" f
    for f in $ENV_FILES; do
        assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/$f")" "$why: $f"
    done
}

# What the VM proves for real: right after the command, the service comes up
assert_service_restarts() {
    local why="$1" rc=0 output
    output=$(sandbox_run "systemctl restart broadcast") || rc=$?
    assert_equals "0" "$rc" "$why: systemctl restart broadcast must work ($output)"
}

# A write into the file named by CAT_FAIL_INTO stops after 16 bytes and fails, like a full disk
mock_cat_that_fails_into_a_file() {
    cat > "$SANDBOX_ROOT/mocks/cat" <<'MOCK'
#!/bin/bash
exec 3>&1
if [ -n "${CAT_FAIL_INTO:-}" ] && [ -e "$CAT_FAIL_INTO" ]; then
  out=$(perl -e 'open(my $f, ">&=", 3) or exit 0; print ((stat($f))[1])')
  if [ "$out" = "$(ls -id "$CAT_FAIL_INTO" | awk '{ print $1 }')" ]; then
    /bin/cat "$@" | head -c 16
    exit 1
  fi
fi
exec /bin/cat "$@"
MOCK
    chmod +x "$SANDBOX_ROOT/mocks/cat"
}

# --- The paths that set the state ---------------------------------------------------------------

test_upgrade_makes_the_env_files_readable_by_their_owner_only() {
    local rc=0
    sandbox_run "_upgrade_continue 2.1.0" "umask 022" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the upgrade should succeed"
    assert_env_files_are_private "upgrade must set mode 600 and keep the owner"
    assert_file_not_exists "$SANDBOX_ROOT/.service_failed" "the upgrade's own start must work"
    assert_service_restarts "after upgrade"
}

test_nightly_update_makes_the_env_files_readable_by_their_owner_only() {
    local rc=0
    sandbox_run "update" "umask 022
$UPDATE_INLINE" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the update should succeed"
    assert_env_files_are_private "the nightly update must repair existing servers"
    assert_service_restarts "after the nightly update"
}

test_files_with_the_right_owner_keep_it() {
    sandbox_run "secure_env_files" "umask 022" >/dev/null

    if /usr/bin/grep -q "^chown" "$SANDBOX_CALLS"; then
        echo "Assertion failed: chown ran although the broadcast user owns the files"
        /usr/bin/grep "^chown" "$SANDBOX_CALLS"
        TEST_FAILED=true
        return 1
    fi
}

# Every night runs this: once the files are right, it changes nothing and checks nothing
test_a_second_run_changes_nothing() {
    sandbox_run "secure_env_files" >/dev/null
    : > "$SANDBOX_CALLS"
    sandbox_run "secure_env_files" >/dev/null

    harness_assert_not_called "chown" "the files are already right"
    harness_assert_not_called "chmod" "the files are already right"
    harness_assert_not_called "runuser" "nothing changed, so there is nothing to check"
}

test_a_file_that_root_replaced_goes_back_to_the_broadcast_user() {
    own root:root "$SANDBOX_ROOT/.env"
    sandbox_run "secure_env_files" "umask 022" >/dev/null

    assert_env_files_are_private "at mode 600 a root-owned .env would stop docker compose as the broadcast user"
}

test_secure_env_files_skips_missing_files() {
    rm -f "$SANDBOX_ROOT/db/.env"
    local rc=0
    sandbox_run "secure_env_files" "umask 022" >/dev/null || rc=$?

    assert_equals "0" "$rc" "a missing file is not an error"
    assert_file_not_exists "$SANDBOX_ROOT/db/.env" "a missing file must not be created"
}

# --- 1. Any other owner: the broadcast user could not read the file at mode 600 ----------------

test_a_file_an_admin_gave_to_another_user_goes_back_to_the_broadcast_user() {
    own ubuntu:ubuntu "$SANDBOX_ROOT/app/.env"
    sandbox_run "update" "$UPDATE_INLINE" >/dev/null

    assert_env_files_are_private "broadcast:broadcast is the one correct owner"
    assert_service_restarts "after an admin chowned app/.env to ubuntu"
}

test_a_file_owned_by_a_uid_with_no_name_goes_back_to_the_broadcast_user() {
    own 1234:1234 "$SANDBOX_ROOT/db/.env"
    sandbox_run "update" "$UPDATE_INLINE" >/dev/null

    assert_env_files_are_private "a uid with no name is not the broadcast user either"
    assert_service_restarts "after db/.env belonged to uid 1234"
}

# A server that an older script left with a root-owned file at mode 600 (Compose cannot read it)
test_an_unreadable_root_owned_file_is_repaired() {
    own root:root "$SANDBOX_ROOT/app/.env"
    /bin/chmod 600 "$SANDBOX_ROOT/app/.env"
    sandbox_run "update" "$UPDATE_INLINE" >/dev/null

    assert_env_files_are_private "the nightly update must repair a file the service cannot read"
    assert_service_restarts "after the repair"
}

# --- 2. Fail safe: the old owner and mode come back when the broadcast user cannot read --------

test_a_chown_that_fails_leaves_the_file_as_it_was() {
    own root:root "$SANDBOX_ROOT/app/.env"
    local rc=0 output
    output=$(sandbox_run "update" "export FAKE_CHOWN_FAILS='*/.env'
$UPDATE_INLINE") || rc=$?

    assert_equals "0" "$rc" "the update must not fail because of the env files"
    assert_equals "root:root 644" "$(harness_owner_and_mode "$SANDBOX_ROOT/app/.env")" "a file the broadcast user cannot own must stay readable"
    assert_contains "$output" "app/.env" "the warning must name the file"
    assert_service_restarts "after a chown that failed"
}

test_the_old_owner_and_mode_come_back_when_the_broadcast_user_cannot_read() {
    own root:root "$SANDBOX_ROOT/app/.env"
    local rc=0 output
    output=$(sandbox_run "update" "export FAKE_RUNUSER_DENY=1
$UPDATE_INLINE") || rc=$?

    assert_equals "0" "$rc" "the update must not fail because of the env files"
    assert_equals "root:root 644" "$(harness_owner_and_mode "$SANDBOX_ROOT/app/.env")" "the previous owner and mode must come back"
    assert_equals "broadcast:broadcast 644" "$(harness_owner_and_mode "$SANDBOX_ROOT/db/.env")" "db/.env must come back too"
    assert_contains "$output" "Warning" "the operator must be told"
    # The cause can be the file or a directory above it (a directory at mode 700), not the mode 600
    assert_contains "$output" "check the file and its directories" "the warning must point at the file and its directories"
    if [[ "$output" == *"at mode 600"* ]]; then
        echo "Assertion failed: the warning must not blame mode 600"
        TEST_FAILED=true
        return 1
    fi
}

test_upgrade_still_starts_when_the_env_files_cannot_be_changed() {
    own root:root "$SANDBOX_ROOT/app/.env"
    local rc=0
    sandbox_run "_upgrade_continue 2.1.0" "export FAKE_CHOWN_FAILS='*/.env'
export FAKE_RUNUSER_DENY=1" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the upgrade must not fail because of the env files"
    harness_assert_called "systemctl start broadcast" "the upgrade must start the service"
    assert_file_not_exists "$SANDBOX_ROOT/.service_failed" "the service must start"
}

# --- 3. Atomic: a rewrite never leaves an empty or partial file ---------------------------------

test_validate_license_replaces_env_in_one_step_at_mode_600() {
    local before after rc=0
    before=$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')
    sandbox_run "validate_license" "umask 022
$LICENSE_RESPONSE" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the license check should succeed"
    after=$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')
    assert_not_equals "$before" "$after" "validate_license must move a complete new file into place"
    assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/.env")" "the registry password must be private"
    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_PASSWORD=pw2" "the new login must be written"
    assert_equals "1" "$(/usr/bin/grep -c '^BROADCAST_REGISTRY_PASSWORD=' "$SANDBOX_ROOT/.env")" "the login must appear once"
    assert_equals "" "$(ls -A "$SANDBOX_ROOT" | /usr/bin/grep '^\.env\.' || true)" "no temporary file may stay behind"
    assert_service_restarts "after validate_license"
}

# The runtime profile setting runs every night; a rewrite with the same content changes nothing
test_a_rewrite_that_changes_nothing_leaves_env_alone() {
    printf 'BROADCAST_REGISTRY_URL=r2.example\nBROADCAST_REGISTRY_LOGIN=l2\nBROADCAST_REGISTRY_PASSWORD=pw2\n' > "$SANDBOX_ROOT/.env"
    own broadcast:broadcast "$SANDBOX_ROOT/.env"
    local before
    before=$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')
    sandbox_run "validate_license" "$LICENSE_RESPONSE" >/dev/null

    assert_equals "$before" "$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')" "the same content must not be written again"
    harness_assert_not_called "chown" "nothing changed"
    assert_equals "" "$(ls -A "$SANDBOX_ROOT" | /usr/bin/grep '^\.env\.' || true)" "no temporary file may stay behind"
}

# The same license again on a server where .env is root:root 644 (an older validate_license left
# it so): the content stays, but the owner and mode are still put right
test_validate_license_with_the_same_content_still_makes_env_private() {
    printf 'BROADCAST_REGISTRY_URL=r2.example\nBROADCAST_REGISTRY_LOGIN=l2\nBROADCAST_REGISTRY_PASSWORD=pw2\n' > "$SANDBOX_ROOT/.env"
    own root:root "$SANDBOX_ROOT/.env"
    /bin/chmod 644 "$SANDBOX_ROOT/.env"
    local before rc=0
    before=$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')
    sandbox_run "validate_license" "$LICENSE_RESPONSE" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the license check should succeed"
    assert_equals "$before" "$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')" "the same content must not be written again"
    assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/.env")" "the registry password must be private"
    assert_service_restarts "after validate_license"
}

test_validate_license_creates_a_new_env_at_mode_600() {
    rm -f "$SANDBOX_ROOT/.env"
    sandbox_run "validate_license" "umask 022
$LICENSE_RESPONSE" >/dev/null

    assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/.env")" "a new .env must never be readable by others"
}

test_a_failed_write_never_leaves_env_partial() {
    mock_cat_that_fails_into_a_file
    sandbox_run "validate_license" "export CAT_FAIL_INTO='$SANDBOX_ROOT/.env'
$LICENSE_RESPONSE" >/dev/null || true

    local content
    content=$(cat "$SANDBOX_ROOT/.env")
    assert_contains "$content" "BROADCAST_REGISTRY_URL=" "the registry URL must survive"
    assert_contains "$content" "BROADCAST_REGISTRY_LOGIN=" "the registry login must survive"
    assert_contains "$content" "BROADCAST_REGISTRY_PASSWORD=" "the registry password must survive"
}

test_encryption_keys_are_filled_in_one_step_at_mode_600() {
    printf 'SECRET_KEY_BASE=skb\nDATABASE_PASSWORD=dbpw\nACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=\nACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=b\nACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=c\n' > "$SANDBOX_ROOT/app/.env"
    local rc=0
    sandbox_run "generate_encryption_keys" >/dev/null || rc=$?

    assert_equals "0" "$rc" "filling the keys should succeed"
    assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/app/.env")" "app/.env must stay private"
    assert_equals "1" "$(/usr/bin/grep -c '^ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=.' "$SANDBOX_ROOT/app/.env")" "the empty key must get one value"
    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=b" "a key with a value must never change"
    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "DATABASE_PASSWORD=dbpw" "every other line must stay"
}

test_a_failed_write_never_leaves_app_env_partial() {
    printf 'SECRET_KEY_BASE=skb\nDATABASE_PASSWORD=dbpw\nACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=\nACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=b\nACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=c\n' > "$SANDBOX_ROOT/app/.env"
    mock_cat_that_fails_into_a_file
    sandbox_run "generate_encryption_keys" "export CAT_FAIL_INTO='$SANDBOX_ROOT/app/.env'" >/dev/null || true

    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "DATABASE_PASSWORD=dbpw" "the database password must survive"
    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=c" "the keys must survive"
}

# The safe-mode switch and the runtime profile setting rewrite .env (COMPOSE_PROFILES and the
# safe-mode flag); the runtime profile setting runs on every install, upgrade and nightly update
test_safe_mode_replaces_env_in_one_step_at_mode_600() {
    local value before
    for value in 1 0; do
        before=$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')
        sandbox_run "plugins_set_safe_mode $value" >/dev/null

        assert_not_equals "$before" "$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')" "safe-mode $value must move a complete new file into place"
        assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/.env")" "safe-mode $value must keep .env private"
        assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_PASSWORD=pw" "the registry login must stay"
        assert_equals "1" "$(/usr/bin/grep -c '^BROADCAST_PLUGINS_SAFE_MODE=' "$SANDBOX_ROOT/.env")" "the flag must appear once"
    done
    assert_service_restarts "after safe-mode"
}

test_a_failed_write_in_safe_mode_never_leaves_env_partial() {
    mock_cat_that_fails_into_a_file
    sandbox_run "plugins_set_safe_mode 1" "export CAT_FAIL_INTO='$SANDBOX_ROOT/.env'" >/dev/null || true

    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_PASSWORD=pw" "the registry login must survive"
}

test_the_runtime_profile_setting_replaces_env_in_one_step_at_mode_600() {
    local state before
    for state in on off; do
        before=$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')
        sandbox_run "set_plugin_runtime_profile $state" >/dev/null

        assert_not_equals "$before" "$(ls -id "$SANDBOX_ROOT/.env" | awk '{ print $1 }')" "the profile $state must move a complete new file into place"
        assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/.env")" "the profile $state must keep .env private"
        assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_PASSWORD=pw" "the registry login must stay"
    done
    assert_service_restarts "after the runtime profile setting"
}

test_a_failed_write_of_the_runtime_profile_never_leaves_env_partial() {
    mock_cat_that_fails_into_a_file
    sandbox_run "set_plugin_runtime_profile on" "export CAT_FAIL_INTO='$SANDBOX_ROOT/.env'" >/dev/null || true

    assert_contains "$(cat "$SANDBOX_ROOT/.env")" "BROADCAST_REGISTRY_PASSWORD=pw" "the registry login must survive"
}

# --- 4. Every other writer leaves the files broadcast:broadcast 600 -----------------------------

test_edge_enable_and_disable_keep_app_env_private() {
    sandbox_run "edge_enable --no-restart" >/dev/null
    assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/app/.env")" "edge-enable must keep app/.env private"
    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "BROADCAST_EDGE_ENABLED=1" "edge-enable must set the flag"
    assert_service_restarts "after edge-enable"

    sandbox_run "edge_disable --no-restart" >/dev/null
    assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/app/.env")" "edge-disable must keep app/.env private"
    assert_equals "0" "$(/usr/bin/grep -c '^BROADCAST_EDGE_ENABLED=' "$SANDBOX_ROOT/app/.env")" "edge-disable must remove the flag"
    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "DATABASE_PASSWORD=dbpw" "every other line must stay"
    assert_service_restarts "after edge-disable"
}

test_the_domains_trigger_keeps_app_env_private() {
    echo "extra.example.com" > "$SANDBOX_ROOT/app/triggers/domains.txt"
    sandbox_run "trigger" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "TLS_DOMAIN=test.example.com,extra.example.com" "the trigger must write the domains"
    assert_env_files_are_private "the domains trigger"
    assert_service_restarts "after the domains trigger"
}

test_a_domain_change_keeps_app_env_private() {
    # The servers have GNU sed; this stands in for its -i
    harness_mock sed 'if [ "${1:-}" = "-i" ]; then exec perl -i -pe "$2" "$3"; fi
exec /usr/bin/sed "$@"'
    sandbox_run "change_installation_domain <<< \$'new.example.com\ny'" >/dev/null

    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "TLS_DOMAIN=new.example.com" "the domain change must write TLS_DOMAIN"
    assert_env_files_are_private "the domain change"
    assert_file_not_exists "$SANDBOX_ROOT/.service_failed" "the domain change's own restart must work"
}

test_fix_leaves_the_env_files_private() {
    sed -i.bak '/^TLS_DOMAIN=/d' "$SANDBOX_ROOT/app/.env" && rm -f "$SANDBOX_ROOT/app/.env.bak"
    own broadcast:broadcast "$SANDBOX_ROOT/app/.env"
    harness_mock inotifywait 'exit 0'
    sandbox_run "fix" >/dev/null || true

    assert_contains "$(cat "$SANDBOX_ROOT/app/.env")" "TLS_DOMAIN=test.example.com" "fix must restore TLS_DOMAIN"
    assert_env_files_are_private "fix"
    assert_service_restarts "after fix"
}

# A restore that brings the env files back from an archive as root (tar keeps the archived owner
# and mode) and then starts the service at once
test_restore_starts_with_env_files_that_root_extracted() {
    local f
    for f in $ENV_FILES; do
        own root:root "$SANDBOX_ROOT/$f"
        /bin/chmod 600 "$SANDBOX_ROOT/$f"
    done
    echo "FAKE DUMP" > "$SANDBOX_ROOT/db/backups/restore.dump"
    local rc=0
    sandbox_run "RESTORE_DUMP_FILE='$SANDBOX_ROOT/db/backups/restore.dump' restore_apply" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the restore must succeed"
    assert_file_not_exists "$SANDBOX_ROOT/.service_failed" "the restore's own start must work"
    assert_env_files_are_private "restore"
    assert_service_restarts "after restore"
}

# upgrade and downgrade pull the images as the broadcast user before they start the service:
# the files must be right before the pull, or the pull fails and the old version comes back
test_upgrade_pulls_when_an_env_file_had_another_owner() {
    own ubuntu:ubuntu "$SANDBOX_ROOT/app/.env"
    /bin/chmod 600 "$SANDBOX_ROOT/app/.env"
    local rc=0
    sandbox_run "_upgrade_continue 2.1.0" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the upgrade must succeed"
    assert_file_not_exists "$SANDBOX_ROOT/.compose_failed" "the pull as the broadcast user must read the env files"
    assert_file_not_exists "$SANDBOX_ROOT/.service_failed" "the upgrade's start must work"
    assert_env_files_are_private "upgrade"
}

test_downgrade_pulls_when_an_env_file_had_another_owner() {
    own root:root "$SANDBOX_ROOT/db/.env"
    /bin/chmod 600 "$SANDBOX_ROOT/db/.env"
    local rc=0
    sandbox_run "_downgrade_continue 1.9.0" >/dev/null || rc=$?

    assert_equals "0" "$rc" "the downgrade must succeed"
    assert_file_not_exists "$SANDBOX_ROOT/.compose_failed" "the pull as the broadcast user must read the env files"
    assert_file_not_exists "$SANDBOX_ROOT/.service_failed" "the downgrade's start must work"
    assert_env_files_are_private "downgrade"
}

# A manual `./broadcast.sh restart` or `start` (edge-enable and the domains trigger restart too)
test_restart_and_start_repair_env_files_the_service_cannot_read() {
    own ubuntu:ubuntu "$SANDBOX_ROOT/app/.env"
    /bin/chmod 600 "$SANDBOX_ROOT/app/.env"
    local rc=0
    sandbox_run "restart" >/dev/null || rc=$?
    assert_equals "0" "$rc" "restart must bring the service up"
    assert_env_files_are_private "restart"

    own root:root "$SANDBOX_ROOT/db/.env"
    /bin/chmod 600 "$SANDBOX_ROOT/db/.env"
    rc=0
    sandbox_run "source \"\$BROADCAST_ROOT/scripts/start.sh\"; start" >/dev/null || rc=$?
    assert_equals "0" "$rc" "start must bring the service up"
    assert_env_files_are_private "start"
}

# --- 5. Symlinks: never chmod or chown through one ----------------------------------------------

test_a_symlinked_env_file_is_left_alone() {
    mkdir -p "$SANDBOX_ROOT/elsewhere"
    mv "$SANDBOX_ROOT/app/.env" "$SANDBOX_ROOT/elsewhere/app.env"
    ln -s "$SANDBOX_ROOT/elsewhere/app.env" "$SANDBOX_ROOT/app/.env"
    own ubuntu:ubuntu "$SANDBOX_ROOT/elsewhere/app.env"
    local output
    output=$(sandbox_run "update" "$UPDATE_INLINE")

    assert_equals "ubuntu:ubuntu 644" "$(harness_owner_and_mode "$SANDBOX_ROOT/elsewhere/app.env")" "the link target must not change"
    [ -L "$SANDBOX_ROOT/app/.env" ] || { echo "Assertion failed: app/.env must stay a symlink"; TEST_FAILED=true; }
    assert_equals "1" "$(echo "$output" | /usr/bin/grep -c 'symlink')" "the skip must be logged once"
    assert_equals "broadcast:broadcast 600" "$(harness_owner_and_mode "$SANDBOX_ROOT/db/.env")" "the other files must still be set"
}

test_validate_license_writes_through_a_symlinked_env_without_changing_it() {
    mkdir -p "$SANDBOX_ROOT/elsewhere"
    mv "$SANDBOX_ROOT/.env" "$SANDBOX_ROOT/elsewhere/registry.env"
    ln -s "$SANDBOX_ROOT/elsewhere/registry.env" "$SANDBOX_ROOT/.env"
    own ubuntu:ubuntu "$SANDBOX_ROOT/elsewhere/registry.env"
    sandbox_run "validate_license" "$LICENSE_RESPONSE" >/dev/null

    [ -L "$SANDBOX_ROOT/.env" ] || { echo "Assertion failed: .env must stay a symlink"; TEST_FAILED=true; }
    assert_contains "$(cat "$SANDBOX_ROOT/elsewhere/registry.env")" "BROADCAST_REGISTRY_PASSWORD=pw2" "the new login must reach the target"
    assert_equals "ubuntu:ubuntu 644" "$(harness_owner_and_mode "$SANDBOX_ROOT/elsewhere/registry.env")" "the link target's owner and mode must not change"
}

# --- 6. No broadcast user: change nothing --------------------------------------------------------

test_without_a_broadcast_user_nothing_changes() {
    harness_mock id 'exit 1'
    own root:root "$SANDBOX_ROOT/app/.env"
    sandbox_run "secure_env_files" >/dev/null

    assert_equals "root:root 644" "$(harness_owner_and_mode "$SANDBOX_ROOT/app/.env")" "app/.env must not change"
    assert_equals "broadcast:broadcast 644" "$(harness_owner_and_mode "$SANDBOX_ROOT/.env")" ".env must not change"
    harness_assert_not_called "chmod" "nothing may change"
}

# --- 8. The owner is the user the service runs as -----------------------------------------------

# Every broadcast.service unit since the first release has User=broadcast (upgrade rewrites older
# ones to the current template). If that ever changes, the owner of the env files must change too.
test_the_env_files_belong_to_the_user_the_service_runs_as() {
    local unit
    unit=$(sandbox_run "source \"\$BROADCAST_ROOT/scripts/init-services.sh\"; broadcast_service_unit")

    assert_contains "$unit" "User=broadcast" "secure_env_files gives the files to the broadcast user"
}

# --- 7. Other env files that an admin creates (compose override) are not touched ---------------

test_an_admin_env_file_is_not_touched() {
    echo "DATABASE_POOL=20" > "$SANDBOX_ROOT/app/database.env"
    /bin/chmod 644 "$SANDBOX_ROOT/app/database.env"
    own ubuntu:ubuntu "$SANDBOX_ROOT/app/database.env"
    sandbox_run "update" "$UPDATE_INLINE" >/dev/null
    sandbox_run "_upgrade_continue 2.1.0" >/dev/null

    assert_equals "ubuntu:ubuntu 644" "$(harness_owner_and_mode "$SANDBOX_ROOT/app/database.env")" "an admin's own env file must not change"
}

run_env_file_modes_tests() {
    init_test_framework
    setup_test_env
    TEST_SETUP_FUNCTION="setup_sandbox"
    TEST_TEARDOWN_FUNCTION="teardown_sandbox"

    local t
    for t in $(declare -F | awk '{ print $3 }' | /usr/bin/grep '^test_'); do
        run_test "$t" "$t"
    done

    local result
    print_test_summary
    result=$?

    cleanup_test_framework
    return $result
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_env_file_modes_tests
fi
