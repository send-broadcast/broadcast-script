# Broadcast Script Test Suite

Comprehensive testing framework for the Broadcast email automation deployment scripts.

## Overview

This test suite provides thorough coverage for the bash scripts used to deploy and manage the Broadcast email automation system. It includes unit tests, integration tests, and mocked external dependency tests to ensure reliability and security.

## Test Structure

```
tests/
├── test_framework.sh              # Core testing framework with assertions and mocking
├── script_harness.sh              # Sandbox harness that loads the REAL scripts
├── run_all_tests.sh               # Main test runner
├── simple_test.sh                 # Basic framework functionality test
├── README.md                      # This documentation
├── unit/                          # Unit tests for individual functions
│   ├── test_version_functions.sh  # Real version/config helpers (common.sh, broadcast.sh)
│   ├── test_upgrade_downgrade.sh  # Real _upgrade_continue/_downgrade_continue flow
│   ├── test_restore_functions.sh  # Real restore() pipeline
│   ├── test_logs_streaming.sh     # Real log streaming/watcher reconcile
│   └── test_docker_references.sh  # Compose file consistency checks
├── integration/                   # Integration tests for complete workflows
│   ├── test_workflow_patterns.sh  # Real trigger/backup/upgrade-entry/update workflows
│   └── test_backup_restore.sh     # Full backup/restore against a Docker PostgreSQL
├── mocks/                         # Tests with mocked external dependencies
│   └── test_functional_patterns.sh # Real license validation with a mocked curl
├── smoke/                         # End-to-end tests in a Multipass VM
└── fixtures/                      # Test data and configuration files
```

## The Script Harness (`script_harness.sh`)

Most management scripts hardcode `/opt/broadcast` and `/etc/systemd/system`
and shell out to `systemctl`, `docker`, `su`, `curl`, etc. To test the real
code without root, Docker, or touching the implementation, the harness:

- Copies each script into a scratch sandbox, rewriting ONLY those two path
  constants to sandbox paths. All logic under test is the original code.
- Shims external commands via a `mocks/` directory placed first on `PATH`.
  Every shim logs its invocation to `calls.log`, so tests can assert on
  what ran and in what order (`harness_assert_called`,
  `harness_assert_call_order`). `sudo` re-execs its arguments so file
  operations stay real.
- Provides a stub `broadcast.sh` inside the sandbox that records dispatch
  calls made by scripts under test (e.g. `trigger` invoking
  `broadcast.sh upgrade 1.2.3`).

## Running Tests

### Run All Tests
```bash
./tests/run_all_tests.sh
```

### Run Specific Test Suite
```bash
# Unit tests only
./tests/run_all_tests.sh -s unit

# Integration tests only
./tests/run_all_tests.sh -s integration

# Mock tests only
./tests/run_all_tests.sh -s mocks
```

### Run Tests with Pattern Matching
```bash
# Run tests matching "backup"
./tests/run_all_tests.sh -p backup

# Run tests matching "upgrade" with verbose output
./tests/run_all_tests.sh -v -p upgrade
```

### Verbose Output
```bash
# Run all tests with detailed output
./tests/run_all_tests.sh -v
```

## Test Categories

### Unit Tests (`tests/unit/`)

Test the real functions from the management scripts in isolation.

**test_version_functions.sh** (real `common.sh`, `restore.sh`, `broadcast.sh`):
- `validate_semantic_version` accept/reject cases
- `compare_versions` return-code API (equal/greater/less, zero-fill, numeric)
- `get_current_version` file read and `unknown` fallback
- `log_version_change` history creation, format, and 102-line cap
- `set_docker_image` amd64/arm64 image selection and `.current_version` tracking
- `generate_encryption_keys` creation, idempotency, and missing-env failure

**test_upgrade_downgrade.sh** (real `upgrade.sh`, `downgrade.sh`):
- `downgrade` input validation (no services touched on rejection)
- stop → update → re-exec `_continue` sequencing for both directions
- `_upgrade_continue`: image pinning, pull-as-broadcast-user, service
  restart ordering, cleanup-service and logs-watcher installation branches,
  encryption-key backfill without clobbering existing keys, version history
- `_downgrade_continue`: prune → pull → start sequencing and history

**test_restore_functions.sh** (real `restore.sh`):
- Full restore() pipeline against a scratch root: file resolution,
  confirmation, checksum sidecar verification, version gate, cleanup

**test_diagnose.sh** (real `diagnose.sh`):
- Support-bundle collection: full container logs captured before any probe
  (never `--tail`), Thruster noise filtered while crash lines survive,
  layered probes (Puma direct / Thruster HTTP / HTTPS origin via
  `--resolve`), 301-redirect-is-healthy verdict, identity + permission
  doctor (WARN on ownership drift, clean on a correct install), system
  specs, top processes, port listeners with foreign-webserver warning,
  SSL certificate status, version/container lifecycle capture, job-queue
  health via psql (with failed-job warnings), database health and
  pending-migration detection, backup freshness warnings, disk
  attribution, incident timeline, cron liveness, job/postgres error
  views, outbound network and SMTP egress checks, the copy-paste report
  contents, OOM/system state capture, tarball output, and exit 0 even
  when every collector fails

### Integration Tests (`tests/integration/`)

Test complete workflows through the real scripts.

**test_workflow_patterns.sh** (real `trigger.sh`, `backup.sh`, `upgrade.sh`, `update.sh`):
- Upgrade entry: stop → script update → re-exec with version forwarding
- Trigger processing: versioned/fallback upgrades, domain updates (TLS_DOMAIN
  composition), backup, job restarts — including trigger-file consumption
  and the no-trigger no-op case
- `backup_database`: archive contents (dump + VERSION), checksum sidecar,
  staging to app/storage, retention pruning, orphan sidecar cleanup
- `update`: legacy Furvur→send-broadcast remote migration

**test_backup_restore.sh:** full backup/restore cycle against a disposable
Docker PostgreSQL container (skipped when Docker is unavailable).

### Mock Tests (`tests/mocks/`)

Test the real external-dependency code paths with the network mocked.

**test_functional_patterns.sh** (real `common.sh`):
- `validate_license` against a mocked sendbroadcast.net API: success writes
  registry credentials; 401/5xx/malformed-JSON/partial responses are refused
  without writing credentials; missing license file fails before any request
- `load_registry_info` credential export, comment handling, missing-file error

## Test Framework Features

### Assertions
- `assert_equals(expected, actual, message)`
- `assert_not_equals(not_expected, actual, message)`
- `assert_contains(haystack, needle, message)`
- `assert_file_exists(file_path, message)`
- `assert_file_not_exists(file_path, message)`
- `assert_exit_code(expected_code, command, message)`

### Mocking
- `mock_command(command, output, exit_code)` - Mock external commands
- `assert_command_called(command, count, message)` - Verify command calls

### Test Environment
- Isolated temporary directories for each test
- Clean environment setup and teardown
- Configurable mock paths and dependencies

## Functional Validation

The test suite validates proper functionality and best practices:

1. **Secure Authentication**: Tests demonstrate proper Docker login patterns
2. **Safe Configuration**: Tests validate atomic configuration file updates
3. **Input Validation**: Tests ensure semantic version checking works correctly
4. **Command Safety**: Tests validate proper command parameter handling

## CI/CD Integration

The test runner returns appropriate exit codes for CI/CD integration:
- `0`: All tests passed
- `1`: Some tests failed

Example GitHub Actions integration:
```yaml
- name: Run Broadcast Script Tests
  run: |
    cd broadcast-script
    ./tests/run_all_tests.sh
```

## Writing New Tests

### Adding Unit Tests
1. Create test file in `tests/unit/`
2. Source the test framework: `source "$SCRIPT_DIR/../test_framework.sh"`
3. Create setup/teardown functions
4. Write test functions with assertions
5. Add test runner function
6. Update `run_all_tests.sh` to include new tests

### Test Function Pattern
```bash
test_function_name() {
    setup_test_env
    
    # Test implementation
    local result=$(function_under_test "param")
    assert_equals "expected" "$result" "Test description"
    
    teardown_test_env
}
```

### Mocking External Commands
```bash
# Mock a command with specific output and exit code
mock_command "curl" '{"status":"success"}' 0

# Test the mocked command
local output=$(curl https://example.com)
assert_contains "$output" "success" "Should return success"
```

## Known Limitations

1. **Docker Testing**: Full Docker integration tests require Docker to be running
2. **Root Privileges**: Some tests simulate but cannot fully test root-required operations
3. **Network Dependencies**: External API tests use mocks rather than real network calls
4. **System Commands**: System-level commands are mocked for portability

## Troubleshooting

### Tests Fail to Run
- Ensure all test files are executable: `find tests/ -name "*.sh" -exec chmod +x {} \;`
- Check that test framework exists: `ls -la tests/test_framework.sh`

### Mock Commands Not Working
- Verify `$PATH` includes the mock directory
- Check mock scripts are executable in `$TEST_TMP_DIR/mocks/`

### Permission Errors
- Some tests may require write permissions to `/tmp/`
- Ensure the test user can create temporary directories

## Contributing

1. Add tests for any new functionality
2. Update existing tests when modifying script behavior
3. Ensure all tests pass before submitting changes
4. Add documentation for complex test scenarios

## Test Coverage

Covered by tests that execute the real scripts:
- ✅ Version management and validation (`common.sh`, `restore.sh`, `broadcast.sh`)
- ✅ Backup creation, retention, and checksum sidecars (`backup.sh`)
- ✅ Restore pipeline with version gate and integrity checks (`restore.sh`)
- ✅ Upgrade/downgrade continuation flow (`upgrade.sh`, `downgrade.sh`)
- ✅ Trigger system dispatch and file consumption (`trigger.sh`)
- ✅ Script updates and remote migration (`update.sh`)
- ✅ License validation and registry credential handling (`common.sh`)
- ✅ Log streaming and watcher reconciliation (`logs.sh`, watcher)

- ✅ Monitor metrics JSON output (`monitor.sh`)
- ✅ Command dispatch and argument forwarding (`broadcast.sh` main)
- ✅ Systemd unit generation and post-upgrade cleanup gate
  (`init-services.sh`, `post-upgrade-cleanup.sh`)
- ✅ Install end state via the VM smoke test (`tests/smoke/`)

Not yet covered:
- SSL certificate management
- `change_installation_domain` (interactive; needs a VM smoke phase)