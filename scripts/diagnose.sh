# One-shot support diagnostic bundle. Born from a 2-day customer outage
# (see broadcast repo TROUBLESHOOT.md, firstborngroup 520 case) where Puma
# died inside the app container while Thruster kept serving, `docker ps`
# showed "Up", and the restart that fixed it destroyed the evidence.
#
# Design rules, each one paid for in that incident:
#   - Capture FULL container logs FIRST: `broadcast.sh restart` runs
#     `docker compose down`, which removes containers and their logs.
#   - Never --tail: on a busy install a few thousand lines is only hours of
#     Thruster access noise; a days-old crash is long gone from any tail.
#   - Probe each layer separately so the failure names itself: Puma direct
#     (inside the container), Thruster over plain HTTP, HTTPS origin.
#   - HTTPS origin test uses --resolve, never a Host header: Host does not
#     set SNI, and autocert rejects SNI "localhost" in a way that
#     masquerades as a certificate failure.
#   - Every collector is fallible; none may abort the bundle. Exit 0 always.

# Ownership check for the permission doctor: install.sh chowns these paths
# to broadcast:broadcast, and drift breaks pulls/backups in confusing ways.
function diagnose_check_owner() {
  local path="$1" owner
  owner=$(stat -c %U "$path" 2>/dev/null) || { echo "WARN: cannot stat $path"; return 0; }
  if [ "$owner" = "broadcast" ]; then
    echo "ok: $path owned by broadcast"
  else
    echo "WARN: $path owned by $owner (expected broadcast; run: chown -R broadcast:broadcast /opt/broadcast)"
  fi
  return 0
}

function diagnose() {
  local timestamp
  timestamp=$(date +%Y-%m-%d-%H-%M-%S)
  local logs_root="/opt/broadcast/logs"
  local bundle="$logs_root/diagnose-$timestamp"
  mkdir -p "$bundle"

  echo -e "\e[33mCollecting diagnostic bundle in $bundle ...\e[0m"

  # 1. Evidence first: full container logs, before anything can wipe them.
  # Prefer the journal — with the journald logging driver it holds the full
  # history INCLUDING containers a restart already removed, evidence
  # `docker logs` can never see. Fall back to `docker logs` on installs
  # whose containers still run the old json-file driver (empty journal).
  local container
  for container in app job postgres; do
    journalctl CONTAINER_NAME="$container" --no-pager -o short-iso \
      > "$bundle/$container.log" 2>/dev/null || true
    if ! grep -q . "$bundle/$container.log" 2>/dev/null; then
      docker logs "$container" > "$bundle/$container.log" 2>&1 \
        || echo "failed to capture $container logs" >> "$bundle/errors.txt"
    fi
  done

  # 2. Filtered app log: strip Thruster access/proxy noise so Puma output
  # (crashes, exceptions) surfaces near the top of a support read
  grep -viE '"msg":"Request"|Unable to proxy|TLS handshake' "$bundle/app.log" 2>/dev/null \
    | tail -200 > "$bundle/app-filtered.log" || true

  # Error-only views of the other containers: Solid Queue exceptions and
  # postgres FATAL/ERROR lines fail silently from the operator's view
  grep -iE "error|exception|fatal" "$bundle/job.log" 2>/dev/null \
    | tail -100 > "$bundle/job-errors.log" || true
  grep -iE "fatal|error|panic" "$bundle/postgres.log" 2>/dev/null \
    | tail -50 > "$bundle/postgres-errors.log" || true

  # 3. Container and system state
  docker ps > "$bundle/docker-ps.txt" 2>&1 || true
  docker stats --no-stream > "$bundle/docker-stats.txt" 2>&1 || true
  { df -h 2>&1 || true; echo; free -m 2>&1 || true; echo; uptime 2>&1 || true; } > "$bundle/system.txt"

  # 4. Kernel OOM check: rules memory kills in or out immediately
  if ! journalctl -k --since "3 days ago" 2>/dev/null \
      | grep -iE "oom|out of memory" > "$bundle/oom.txt"; then
    echo "no kernel OOM events in the last 3 days" > "$bundle/oom.txt"
  fi

  local domain=""
  if [ -f /opt/broadcast/.domain ]; then
    domain=$(cat /opt/broadcast/.domain)
  fi

  # 5. Who ran this, and is the installation shaped the way install.sh
  # leaves it (brew-doctor style: ok/WARN per check)
  {
    echo "user: $(whoami 2>/dev/null || echo unknown)"
    id 2>/dev/null || true
  } > "$bundle/identity.txt"

  {
    diagnose_check_owner /opt/broadcast
    diagnose_check_owner /opt/broadcast/app
    [ -f /opt/broadcast/app/.env ] && diagnose_check_owner /opt/broadcast/app/.env
    diagnose_check_owner /opt/broadcast/db/backups
    if [ -x /opt/broadcast/broadcast.sh ]; then
      echo "ok: broadcast.sh is executable"
    else
      echo "WARN: broadcast.sh is not executable (chmod +x /opt/broadcast/broadcast.sh)"
    fi
    if id -nG broadcast 2>/dev/null | grep -qw docker; then
      echo "ok: broadcast user is in the docker group"
    else
      echo "WARN: broadcast user is not in the docker group"
    fi
    if [ -f /etc/sudoers.d/broadcast ]; then
      echo "ok: sudoers entry present"
    else
      echo "WARN: /etc/sudoers.d/broadcast missing"
    fi
  } > "$bundle/doctor.txt" 2>&1 || true

  # 6. System specs, OS, and time sync
  {
    echo "--- OS ---"
    cat /etc/os-release 2>/dev/null || true
    uname -a 2>/dev/null || true
    echo
    echo "--- CPU ---"
    echo "cores: $(nproc 2>/dev/null || echo unknown)"
    grep -m1 "model name" /proc/cpuinfo 2>/dev/null || true
    echo
    echo "--- Disk ---"
    df -h 2>&1 || true
    echo "--- Inodes (a full inode table breaks writes even with free space) ---"
    df -i / 2>&1 || true
    echo
    echo "--- Memory ---"
    free -m 2>&1 || true
    echo
    echo "--- Load ---"
    uptime 2>&1 || true
    echo
    echo "--- Time sync (clock skew breaks email provider signatures) ---"
    timedatectl 2>/dev/null | head -8 || true
  } > "$bundle/system.txt"

  # 7. What else is running on this host
  {
    echo "--- Top processes by memory ---"
    ps aux --sort=-%mem 2>/dev/null | head -16 || true
    echo
    echo "--- Top processes by CPU ---"
    ps aux --sort=-%cpu 2>/dev/null | head -16 || true
  } > "$bundle/processes.txt"

  # 8. Port listeners + firewall. A non-Docker process on 80/443 (customer
  # installed nginx/apache) silently steals traffic from Thruster.
  {
    ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo "no ss/netstat available"
    echo
    echo "--- Firewall ---"
    ufw status 2>/dev/null || true
  } > "$bundle/ports.txt"
  if grep -E "(:80|:443)[[:space:]]" "$bundle/ports.txt" 2>/dev/null \
      | grep -viE "docker|thruster" | grep -q .; then
    echo "WARN: a non-Docker process is listening on port 80/443 (see listeners above) — another web server may be stealing Broadcast's traffic" >> "$bundle/ports.txt"
  fi

  # 9. Live SSL certificate (SNI required — see header note on --resolve)
  if [ -n "$domain" ]; then
    echo | openssl s_client -servername "$domain" -connect 127.0.0.1:443 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates > "$bundle/ssl.txt" 2>&1 \
      || echo "could not read the certificate for $domain (Thruster down, or no cert issued yet)" > "$bundle/ssl.txt"
  else
    echo "no .domain configured; certificate check skipped" > "$bundle/ssl.txt"
  fi

  # 10. Versions and container lifecycle (restart counts and start times
  # date an incident: "recreated N days ago" was the timing clue in the
  # original outage)
  {
    echo "broadcast version: $(cat /opt/broadcast/.current_version 2>/dev/null || echo unknown)"
    cat /opt/broadcast/.image 2>/dev/null || true
    echo "scripts revision: $(git -C /opt/broadcast rev-parse --short HEAD 2>/dev/null || echo unknown)"
    docker --version 2>/dev/null || true
    echo
    echo "--- Docker disk usage ---"
    docker system df 2>&1 || true
    echo
    echo "--- Container lifecycle ---"
    local c
    for c in app job postgres; do
      docker inspect --format "{{.Name}}: restarts={{.RestartCount}} started={{.State.StartedAt}}" "$c" 2>/dev/null || true
    done
  } > "$bundle/versions.txt"

  # 11. Job queue health, read via psql against the postgres container so a
  # wedged or dead app container cannot block queue inspection. "My emails
  # aren't sending" is the most common support opener; a deep ready queue
  # with an old head, or piled-up failed jobs, answers it immediately.
  local psql_queue="docker exec postgres psql -U broadcast -d broadcast_queue_production -t -A -c"
  local failed_jobs
  failed_jobs=$($psql_queue "SELECT COUNT(*) FROM solid_queue_failed_executions" 2>/dev/null) || failed_jobs="unknown"
  {
    echo "ready jobs: $($psql_queue "SELECT COUNT(*) FROM solid_queue_ready_executions" 2>/dev/null || echo unknown)"
    echo "scheduled jobs: $($psql_queue "SELECT COUNT(*) FROM solid_queue_scheduled_executions" 2>/dev/null || echo unknown)"
    echo "failed jobs: $failed_jobs"
    echo "oldest ready job age (seconds): $($psql_queue "SELECT COALESCE(EXTRACT(EPOCH FROM (NOW() - MIN(created_at)))::int, 0) FROM solid_queue_ready_executions" 2>/dev/null || echo unknown)"
    case "$failed_jobs" in
      ""|0|unknown) : ;;
      *) echo "WARN: $failed_jobs failed jobs — inspect the job queue in the dashboard" ;;
    esac
  } > "$bundle/queue.txt"

  # 12. Database health: pool exhaustion mimics an app hang, and pending
  # migrations after an upgrade/restore cause confusing partial failures
  local psql_primary="docker exec postgres psql -U broadcast -d broadcast_primary_production -t -A -c"
  {
    echo "active connections: $($psql_primary "SELECT COUNT(*) FROM pg_stat_activity" 2>/dev/null || echo unknown)"
    echo "max_connections: $($psql_primary "SHOW max_connections" 2>/dev/null || echo unknown)"
    echo
    echo "--- Database sizes ---"
    $psql_primary "SELECT datname || ': ' || pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datname LIKE 'broadcast%'" 2>/dev/null || true
    echo
    echo "--- Queries running longer than 30s ---"
    $psql_primary "SELECT pid || ' ' || state || ' ' || (now() - query_start) || ' ' || LEFT(query, 80) FROM pg_stat_activity WHERE state <> 'idle' AND now() - query_start > interval '30 seconds'" 2>/dev/null || true
    echo
    if docker exec app bin/rails db:migrate:status 2>/dev/null | grep -q "^ *down"; then
      echo "WARN: pending database migrations — run the upgrade again or contact support"
    else
      echo "ok: no pending migrations detected"
    fi
  } > "$bundle/database.txt"

  # 13. Backup freshness: a customer who believes they have backups but
  # whose newest one is months old is a disaster in waiting
  {
    if ls /opt/broadcast/db/backups/broadcast-backup-*.tar.gz >/dev/null 2>&1; then
      ls -lt /opt/broadcast/db/backups/broadcast-backup-* 2>/dev/null | head -5
      if find /opt/broadcast/db/backups -name "broadcast-backup-*.tar.gz" -mtime -7 2>/dev/null | grep -q .; then
        echo "ok: newest backup is less than 7 days old"
      else
        echo "WARN: newest backup is more than 7 days old — trigger a fresh backup from the dashboard"
      fi
    else
      echo "WARN: no database backups found in db/backups — trigger one from the dashboard"
    fi
  } > "$bundle/backups.txt"

  # 14. Disk attribution: "disk 92% full" means nothing until you know
  # whether postgres, uploads, logs, or dead Docker images grew
  {
    du -sh /opt/broadcast/db/postgres-data 2>/dev/null || true
    du -sh /opt/broadcast/app/storage 2>/dev/null || true
    du -sh /opt/broadcast/app/uploads 2>/dev/null || true
    du -sh /opt/broadcast/logs 2>/dev/null || true
    echo "(Docker image usage is in versions.txt)"
  } > "$bundle/storage.txt"

  # 15. Incident timeline: upgrades, domain changes, reboots, failed
  # units, surprise unattended upgrades, and cgroup OOM kills (which the
  # kernel-journal check does not see)
  {
    echo "--- Version history ---"
    tail -10 /opt/broadcast/.version_history 2>/dev/null || echo "none"
    echo
    echo "--- Domain history ---"
    tail -5 /opt/broadcast/.domain_history 2>/dev/null || echo "none"
    echo
    echo "--- Reboots ---"
    last reboot 2>/dev/null | head -5 || true
    echo
    echo "--- Failed systemd units ---"
    systemctl --failed 2>/dev/null || true
    echo
    echo "--- Unattended upgrades (recent) ---"
    tail -20 /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null || echo "no log"
    echo
    echo "--- Container OOM flags ---"
    local tc
    for tc in app job postgres; do
      docker inspect --format "{{.Name}}: OOMKilled={{.State.OOMKilled}} exit={{.State.ExitCode}}" "$tc" 2>/dev/null || true
    done
  } > "$bundle/timeline.txt"

  # 16. Cron liveness: dead cron means no monitoring, no triggers, no
  # updates — and nothing complains until the dashboard goes stale
  {
    ls -l /opt/broadcast/logs/cron/ 2>/dev/null || echo "no cron log directory"
    if find /opt/broadcast/logs/cron -name "*.log" -mmin -10 2>/dev/null | grep -q .; then
      echo "ok: cron jobs wrote logs within the last 10 minutes"
    else
      echo "WARN: no cron log activity in the last 10 minutes — the monitor/trigger cron jobs may be dead"
    fi
  } > "$bundle/cron.txt"

  # 17. Outbound network: blocked egress fails silently, and cloud hosts
  # commonly block SMTP ports by default
  {
    echo "license server (sendbroadcast.net): $(curl -s -o /dev/null -w "%{http_code}" -m 10 https://sendbroadcast.net 2>/dev/null || echo unreachable)"
    echo "general internet (checkip.amazonaws.com): $(curl -s -o /dev/null -w "%{http_code}" -m 10 https://checkip.amazonaws.com 2>/dev/null || echo unreachable)"
    local port
    for port in 25 587; do
      if timeout 5 bash -c "</dev/tcp/aspmx.l.google.com/$port" 2>/dev/null; then
        echo "smtp egress port $port: open"
      else
        echo "smtp egress port $port: blocked or filtered"
      fi
    done
  } > "$bundle/network.txt"

  # 18. Layered probes
  local puma_code thruster_code https_code="skipped"
  puma_code=$(docker exec app curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost:3000/up 2>/dev/null) || puma_code="000"
  thruster_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost/up 2>/dev/null) || thruster_code="000"
  if [ -n "$domain" ]; then
    https_code=$(curl -sk --resolve "$domain:443:127.0.0.1" -o /dev/null -w "%{http_code}" -m 35 "https://$domain/up" 2>/dev/null) || https_code="000"
  fi

  {
    echo "Puma direct   (docker exec app curl localhost:3000/up): $puma_code"
    echo "Thruster HTTP (curl localhost/up): $thruster_code"
    echo "HTTPS origin  (curl --resolve ${domain:-<no .domain>}:443:127.0.0.1): $https_code"
  } > "$bundle/probes.txt"

  # 6. Interpretation: name the layer that failed, and preserve the
  # capture-before-restart discipline in the advice itself
  {
    # Thruster 301 on plain HTTP is its normal redirect to HTTPS — proof it
    # is alive, not a failure (confirmed against a healthy real install).
    if [ "$puma_code" = "200" ] && { [ "$thruster_code" = "200" ] || [ "$thruster_code" = "301" ]; }; then
      echo "All layers healthy: Puma answers directly and Thruster serves it."
      if [ "$thruster_code" = "301" ]; then
        echo "(Thruster answered plain HTTP with its normal 301 redirect to HTTPS.)"
      fi
    elif [ "$puma_code" != "200" ] && [ "$thruster_code" != "000" ]; then
      echo "WARNING: Thruster is up but the app process (Puma) is not responding."
      echo "This is the app-down fingerprint: docker ps shows the container Up,"
      echo "proxied requests fail slowly (~30s), and Cloudflare shows error 520."
      echo "Container logs are already captured in this bundle; it is now safe"
      echo "to recover with: ./broadcast.sh restart"
    elif [ "$puma_code" = "200" ]; then
      echo "The app process (Puma) is healthy but the Thruster HTTP probe failed."
      echo "Check host firewall/port bindings before touching the containers."
    else
      echo "Multiple layers failed to respond (Puma: $puma_code, Thruster: $thruster_code)."
      echo "Check docker-ps.txt and the container logs in this bundle."
    fi
  } | tee "$bundle/summary.txt"

  # 7. Single artifact for the support round-trip
  tar -czf "$logs_root/diagnose-$timestamp.tar.gz" -C "$logs_root" "diagnose-$timestamp" \
    || echo -e "\e[31mCould not create the bundle tarball; the directory remains at $bundle\e[0m"

  # 8. Copy-paste report: customers paste far more reliably than they
  # attach files, so the common case must travel in the terminal output
  # itself. The tarball stays as the escalation path (full logs are tens of
  # thousands of lines — they cannot ride in a paste).
  echo
  echo "=============== COPY FROM HERE FOR YOUR SUPPORT EMAIL ==============="
  echo "--- Versions ---"
  cat "$bundle/versions.txt" 2>/dev/null || true
  echo
  echo "--- Summary ---"
  cat "$bundle/summary.txt" 2>/dev/null || true
  echo
  echo "--- Health probes ---"
  cat "$bundle/probes.txt" 2>/dev/null || true
  echo
  echo "--- Job queue ---"
  cat "$bundle/queue.txt" 2>/dev/null || true
  echo
  echo "--- Database ---"
  cat "$bundle/database.txt" 2>/dev/null || true
  echo
  echo "--- Backups ---"
  cat "$bundle/backups.txt" 2>/dev/null || true
  echo
  echo "--- Permission doctor ---"
  cat "$bundle/doctor.txt" 2>/dev/null || true
  echo
  echo "--- SSL certificate ---"
  cat "$bundle/ssl.txt" 2>/dev/null || true
  echo
  echo "--- Ports and firewall ---"
  cat "$bundle/ports.txt" 2>/dev/null || true
  echo
  echo "--- Outbound network ---"
  cat "$bundle/network.txt" 2>/dev/null || true
  echo
  echo "--- Cron liveness ---"
  cat "$bundle/cron.txt" 2>/dev/null || true
  echo
  echo "--- Disk attribution ---"
  cat "$bundle/storage.txt" 2>/dev/null || true
  echo
  echo "--- Timeline (versions / reboots / OOM) ---"
  cat "$bundle/timeline.txt" 2>/dev/null || true
  echo
  echo "--- Containers ---"
  cat "$bundle/docker-ps.txt" 2>/dev/null || true
  echo
  echo "--- System (OS / CPU / disk / memory / load / time) ---"
  cat "$bundle/system.txt" 2>/dev/null || true
  echo
  echo "--- Top processes ---"
  head -20 "$bundle/processes.txt" 2>/dev/null || true
  echo
  echo "--- Kernel OOM check ---"
  head -20 "$bundle/oom.txt" 2>/dev/null || true
  echo
  echo "--- App log (last 40 lines, Thruster access noise filtered) ---"
  tail -40 "$bundle/app-filtered.log" 2>/dev/null || true
  echo "================ COPY TO HERE ================"

  echo
  echo -e "\e[32mDiagnostic bundle ready:\e[0m"
  echo "  Copy the report above into your support email."
  echo "  If support asks for full logs, attach: $logs_root/diagnose-$timestamp.tar.gz"

  return 0
}
