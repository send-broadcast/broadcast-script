# Smoke Test

End-to-end smoke test that installs Broadcast from scratch on disposable Ubuntu VMs (24.04 and 26.04 by default) using [Vagrant](https://www.vagrantup.com/) + QEMU. Catches issues that unit/integration tests can't: Docker image problems, systemd service failures, database initialization issues, package availability across Ubuntu releases, etc.

## Prerequisites

- [Vagrant](https://www.vagrantup.com/) (`brew install vagrant`)
- [QEMU](https://www.qemu.org/) (`brew install qemu`)
- [vagrant-qemu plugin](https://github.com/ppggff/vagrant-qemu): `vagrant plugin install vagrant-qemu`
- Valid Broadcast license key

QEMU on macOS uses Apple's Hypervisor framework (HVF) for near-native VM speed on both Apple Silicon and Intel Macs. The smoke test auto-detects host arch and picks the right QEMU machine flags.

The boxes are [`cloud-image/ubuntu-{24.04,26.04}`](https://portal.cloud.hashicorp.com/vagrant/discover/cloud-image), HashiCorp-built from the official Canonical cloud images.

## Setup

1. Copy the credential template:

```bash
cp tests/smoke/.smoke-test.env.sample tests/smoke/.smoke-test.env
```

2. Fill in your license key in `.smoke-test.env`. Registry credentials are fetched automatically from the license API.

Alternatively, export the variable in your shell:

```bash
export BROADCAST_LICENSE_KEY=your-license-key
```

## Usage

By default the VM clones `https://github.com/send-broadcast/broadcast-script.git` and installs that, matching what real end users do. Local uncommitted changes are **not** tested unless you pass `--local`.

```bash
# Basic smoke test (runs against Ubuntu 24.04 and 26.04 sequentially, clones the canonical remote)
./tests/smoke/test_multipass_smoke.sh

# Test only one Ubuntu version
./tests/smoke/test_multipass_smoke.sh --ubuntu 24.04
./tests/smoke/test_multipass_smoke.sh --ubuntu 26.04

# Test the local working tree instead of cloning the remote (uncommitted edits included)
./tests/smoke/test_multipass_smoke.sh --local

# Keep VM after test for debugging
./tests/smoke/test_multipass_smoke.sh --no-cleanup

# Also verify services survive a reboot
./tests/smoke/test_multipass_smoke.sh --test-reboot

# Show all command output
./tests/smoke/test_multipass_smoke.sh --verbose

# Combine flags
./tests/smoke/test_multipass_smoke.sh --ubuntu 26.04 --test-reboot --verbose --no-cleanup
```

## The Two Scripts

- `test_multipass_smoke.sh` installs from a clone with `broadcast.sh install` and runs the long list of checks below (install state, backup/restore, journald, reboot, upgrade hardening, domain change).
- `test_bootstrap_e2e.sh` tests the one-line installer (`curl ... | sudo bash`) as customers run it, in three scenarios: `noninteractive`, `interactive` (driven over a real TTY by `expect`), and `legacy-upgrade`.

Both get their VM plumbing from `lib/smoke_vm.sh`: the Vagrantfile, the QEMU flags, the ssh helpers and the redaction. Do not write a Vagrantfile in a script. The shared one carries a fix for Vagrant 2.4 on macOS 27, which otherwise reports every localhost port as in use ("The forwarded port to ... is already in use") and starts no VM. `tests/unit/test_smoke_harness.sh` (part of `tests/run_all_tests.sh`, no VM needed) fails when a smoke script stops using the helper or the fix goes missing.

### Secrets in the output

Everything the scripts print goes through `lib/redact.pl`. It masks the license key, the registry login and the secret values from the VM's env files, also when the key is echoed by the TTY, repeated in a prompt, wrapped over two lines, broken up by escape codes, or cut short. Saved files (the `expect` transcript, the install output) are masked in place. Values of `NAME=value` lines whose name says secret (`PASSWORD`, `SECRET`, `LICENSE`, `TOKEN`, `_KEY`, `_LOGIN`) are masked even when the harness does not know them. Check a saved log without printing the key:

```bash
grep -c -F -f <(sed -n 's/^BROADCAST_LICENSE_KEY=//p' tests/smoke/.smoke-test.env) your-run.log   # must print 0
```

### Upgrades from an older release

`legacy-upgrade` installs an older commit the way customers installed it then (`--from`, default `a1df6f0`, the last commit before the env-file changes), then upgrades it to `--ref`. It runs two paths on fresh VMs: `broadcast.sh upgrade`, and the nightly `update` cron command run twice. After each step it checks the stack, the owner and mode of `.env`, `app/.env` and `db/.env` (`broadcast:broadcast 600` once the new scripts ran), `broadcast.service`, and a restart.

```bash
./tests/smoke/test_bootstrap_e2e.sh --ubuntu 24.04 --scenario legacy-upgrade --ref main --from a1df6f0
./tests/smoke/test_bootstrap_e2e.sh --ubuntu 24.04 --scenario legacy-upgrade --ref main --path nightly
```

The scripts install what is on GitHub. To run a harness change before it is pushed, run the script from your checkout; `--ref` picks the code under test.

## What It Does

For each Ubuntu version selected:

1. **Setup VM** - Launches Ubuntu VM via Vagrant + QEMU (2 CPUs, 2G RAM); clones the canonical repo into `/opt/broadcast` (or copies the local working tree with `--local`)
2. **Prepare Installation** - Pre-creates config files to bypass interactive prompts
3. **Run Installer** - Executes `./broadcast.sh install`
4. **Health Checks** - Verifies containers, database, HTTP endpoints, systemd service, cron jobs
5. **Install State Checks** - Verifies the security/system half of `install.sh`: UFW rules (22/80/443) and enablement, fail2ban, swap file + fstab persistence, UTC timezone + chrony, unattended upgrades (no auto-reboot), broadcast user's docker group and sudoers entry, `/opt/broadcast` ownership, daily update cron, logrotate config, systemd unit installation/enablement, architecture-correct `.image`, and inotify-tools
6. **Backup/Restore Cycle** - Takes a real backup, restores it with `--yes`, and verifies data was genuinely replaced and the system recovers
7. **Reboot Recovery** (optional) - Restarts VM and re-runs health checks
8. **Domain Change** - Feeds `change_installation_domain`'s interactive prompts from a file: invalid domains are rejected, cancellation leaves state untouched, and a confirmed change updates `.domain`/`TLS_DOMAIN`/`.domain_history` with the system recovering afterwards (always runs last, since it renames the installation)
9. **Cleanup** - Destroys VM (unless `--no-cleanup`)

The summary at the end reports per-version pass/fail counts in addition to the overall total.

## Expected Runtime

~3-5 minutes per Ubuntu version (VM boot ~30s, installer ~2-3min, health checks ~30s). Running both 24.04 and 26.04 sequentially takes roughly twice that.

## Debugging

Each Ubuntu version uses its own working directory: `tests/smoke/.vagrant-smoke-24.04`, `tests/smoke/.vagrant-smoke-26.04`, etc.

Use `--no-cleanup` to keep the VM, then:

```bash
cd tests/smoke/.vagrant-smoke-26.04   # or -24.04
vagrant ssh
# You're now inside the VM
sudo su -
cd /opt/broadcast
docker ps
systemctl status broadcast.service
cat app/.env
```

To manually clean up:

```bash
cd tests/smoke/.vagrant-smoke-26.04 && vagrant destroy -f
```

## Architecture Notes

- On Apple Silicon, the test runs aarch64 VMs (HVF-accelerated), which validates the ARM Docker image path; on Intel hosts it runs x86_64 VMs
- Health checks use HTTP (port 80) since Thruster can't get real certs for `smoke-test.local`
- The default `/vagrant` synced folder is disabled; `--local` mode uses rsync to copy the working tree, which cloud-image boxes support out of the box
