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
#   - Bound the journal capture by TIME, never by line count. Under the old
#     json-file driver a "full dump" was capped at 10m x 3 per container;
#     journald has no such cap, so the same code scanned multi-GB journals
#     (2m12s runs, 734MB of logs/, observed on a real server). A week-long
#     window keeps days-old crashes while staying finite. `docker logs` needs
#     no window: that path only exists for json-file installs, where compose
#     rotation already caps the size.
#   - Announce every step BEFORE running it. A customer mid-outage reading a
#     silent terminal assumes a hang and Ctrl-Cs, destroying the bundle.

# Progress feedback. Each collector names itself before it runs and reports
# its own elapsed seconds when it finishes, so whatever is taking the time
# identifies itself instead of hiding behind a blank terminal.
DIAGNOSE_STEP_TOTAL=20

function diagnose_step_done() {
  if [ -n "${DIAGNOSE_STEP_STARTED:-}" ]; then
    printf ' done (%ss)\n' "$(( $(date +%s) - DIAGNOSE_STEP_STARTED ))"
    DIAGNOSE_STEP_STARTED=""
  fi
  return 0
}

function diagnose_step() {
  diagnose_step_done
  DIAGNOSE_STEP_NO=$(( ${DIAGNOSE_STEP_NO:-0} + 1 ))
  printf '  [%2d/%d] %s ...' "$DIAGNOSE_STEP_NO" "$DIAGNOSE_STEP_TOTAL" "$1"
  DIAGNOSE_STEP_STARTED=$(date +%s)
  return 0
}

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

  DIAGNOSE_STEP_NO=0
  DIAGNOSE_STEP_STARTED=""
  local run_started
  run_started=$(date +%s)

  echo -e "\e[33mCollecting diagnostic bundle in $bundle ...\e[0m"

  # 1. Evidence first: container logs, before anything can wipe them.
  # Prefer the journal — with the journald logging driver it holds history
  # INCLUDING containers a restart already removed, evidence `docker logs`
  # can never see. Bounded by time (see header): unbounded scans of a
  # multi-GB journal are what made this step take minutes. Fall back to
  # `docker logs` on installs whose containers still run the old json-file
  # driver (empty journal), where compose rotation already caps the size.
  local container
  local log_window="${DIAGNOSE_LOG_WINDOW:-7 days ago}"
  echo "container logs captured with window: since $log_window" \
    > "$bundle/log-capture.txt"
  diagnose_step "container logs (slowest step on busy servers)"
  for container in app job postgres; do
    journalctl CONTAINER_NAME="$container" --since "$log_window" \
      --no-pager -o short-iso > "$bundle/$container.log" 2>/dev/null || true
    if ! grep -q . "$bundle/$container.log" 2>/dev/null; then
      docker logs "$container" > "$bundle/$container.log" 2>&1 \
        || echo "failed to capture $container logs" >> "$bundle/errors.txt"
    fi
  done

  # 2. Filtered app log: strip Thruster access/proxy noise so Puma output
  # (crashes, exceptions) surfaces near the top of a support read
  diagnose_step "filtered app and error logs"
  grep -viE '"msg":"Request"|Unable to proxy|TLS handshake' "$bundle/app.log" 2>/dev/null \
    | tail -200 > "$bundle/app-filtered.log" || true

  # Error-only views of the other containers: Solid Queue exceptions and
  # postgres FATAL/ERROR lines fail silently from the operator's view
  grep -iE "error|exception|fatal" "$bundle/job.log" 2>/dev/null \
    | tail -100 > "$bundle/job-errors.log" || true
  grep -iE "fatal|error|panic" "$bundle/postgres.log" 2>/dev/null \
    | tail -50 > "$bundle/postgres-errors.log" || true

  diagnose_step "container and system state"
  # 3. Container and system state
  docker ps > "$bundle/docker-ps.txt" 2>&1 || true
  docker stats --no-stream > "$bundle/docker-stats.txt" 2>&1 || true
  { df -h 2>&1 || true; echo; free -m 2>&1 || true; echo; uptime 2>&1 || true; } > "$bundle/system.txt"

  diagnose_step "kernel OOM check"
  # 4. Kernel OOM check: rules memory kills in or out immediately
  if ! journalctl -k --since "3 days ago" 2>/dev/null \
      | grep -iE "oom|out of memory" > "$bundle/oom.txt"; then
    echo "no kernel OOM events in the last 3 days" > "$bundle/oom.txt"
  fi

  local domain=""
  if [ -f /opt/broadcast/.domain ]; then
    domain=$(cat /opt/broadcast/.domain)
  fi

  diagnose_step "identity and permission doctor"
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

  diagnose_step "system specs and time sync"
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
    # Observed on a real server: NTP inactive, printed without comment. Skew
    # breaks provider request signatures, which surfaces as auth failures
    # nobody connects back to the clock.
    local timesync=""
    timesync=$(timedatectl 2>/dev/null | head -8) || true
    echo "$timesync"
    case "$timesync" in
      *"System clock synchronized: no"*)
        echo "WARN: system clock is NOT synchronized — skew breaks email provider request signatures (fix: timedatectl set-ntp true)" ;;
    esac
    case "$timesync" in
      *"NTP service: active"*) : ;;
      *"NTP service:"*)
        echo "WARN: NTP service is not active — the clock will drift unchecked (fix: timedatectl set-ntp true)" ;;
    esac
  } > "$bundle/system.txt"

  diagnose_step "top processes"
  # 7. What else is running on this host
  {
    echo "--- Top processes by memory ---"
    ps aux --sort=-%mem 2>/dev/null | head -16 || true
    echo
    echo "--- Top processes by CPU ---"
    ps aux --sort=-%cpu 2>/dev/null | head -16 || true
  } > "$bundle/processes.txt"

  diagnose_step "ports and firewall"
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

  diagnose_step "SSL certificate"
  # 9. Live SSL certificate (SNI required — see header note on --resolve)
  if [ -n "$domain" ]; then
    echo | openssl s_client -servername "$domain" -connect 127.0.0.1:443 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates > "$bundle/ssl.txt" 2>&1 \
      || echo "could not read the certificate for $domain (Thruster down, or no cert issued yet)" > "$bundle/ssl.txt"
  else
    echo "no .domain configured; certificate check skipped" > "$bundle/ssl.txt"
  fi

  diagnose_step "versions and container lifecycle"
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
    echo
    # Descriptor usage against its ceiling. The 2026-08-15 outage was exhaustion
    # inside the app process while every other signal read healthy, and this
    # bundle recorded nothing about it. A count climbing across successive
    # bundles is also the only way to tell a leak from a burst.
    echo "--- Open files (descriptor exhaustion took a customer down on 2026-08-15) ---"
    local fd_used fd_limit
    for c in app job; do
      fd_used=$(docker exec "$c" sh -c 'ls /proc/[0-9]*/fd 2>/dev/null | grep -c .' 2>/dev/null | tail -1)
      fd_limit=$(docker exec "$c" sh -c 'ulimit -n' 2>/dev/null | tail -1)
      echo "$c: open files ${fd_used:-unknown} of ${fd_limit:-unknown}"
      if [ -n "$fd_used" ] && [ -n "$fd_limit" ] && [ "$fd_limit" -gt 0 ] 2>/dev/null; then
        if [ "$((fd_used * 100 / fd_limit))" -ge 70 ]; then
          echo "WARN: $c is at $((fd_used * 100 / fd_limit))% of its descriptor limit — at the ceiling Puma stops accepting connections while the container still reports healthy"
        fi
      fi
    done
  } > "$bundle/versions.txt"

  diagnose_step "job queue health"
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

  diagnose_step "database health and connection sources"
  # 12. Database health: pool exhaustion mimics an app hang, and pending
  # migrations after an upgrade/restore cause confusing partial failures
  local psql_primary="docker exec postgres psql -U broadcast -d broadcast_primary_production -t -A -c"

  # Who is connected, not just how many. A remote client (psql, a BI tool, an
  # SSH tunnel) holding connections starves the app and presents exactly like
  # an app hang, and the bare active/max counts cannot tell the two apart.
  # Postgres is published on loopback only, so every legitimate session comes
  # from a sibling container; docker-proxy rewrites anything arriving through
  # the published 5432 port to the bridge gateway, and any other address is a
  # genuinely foreign client.
  local db_gateway="" db_container_ips="" active_conns="unknown" max_conns="unknown" conn_sources=""
  # docker inspect exits non-zero when ANY named container is missing but still
  # prints the ones it found, and the crash case (app container down) is
  # exactly when this runs. Keep the partial list: discarding it would flag
  # every surviving container's own sessions as an external client. The `tr`
  # pipe already masks the exit status (no `pipefail` here), so `|| true` only
  # documents the intent and keeps this correct if that ever changes.
  db_gateway=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' postgres 2>/dev/null | tr -d '[:space:]') || true
  db_container_ips=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' app job postgres 2>/dev/null | tr '\n' ' ') || true
  # `backend_type = 'client backend'` throughout: pg_stat_activity also lists
  # background workers (checkpointer, autovacuum, walwriter) which hold no
  # max_connections slot. Counting them overstates usage, skews the ceiling
  # warning, and adds meaningless null-database rows to the breakdown.
  local client_only="WHERE backend_type = 'client backend'"
  active_conns=$($psql_primary "SELECT COUNT(*) FROM pg_stat_activity $client_only" 2>/dev/null) || active_conns="unknown"
  max_conns=$($psql_primary "SHOW max_connections" 2>/dev/null) || max_conns="unknown"
  conn_sources=$($psql_primary "SELECT COALESCE(host(client_addr), 'local') || ' ' || COALESCE(datname, '-') || ' ' || COALESCE(state, '-') || ' ' || COUNT(*) FROM pg_stat_activity $client_only GROUP BY client_addr, datname, state ORDER BY COUNT(*) DESC" 2>/dev/null) || conn_sources=""

  {
    echo "active connections: $active_conns"
    echo "max_connections: $max_conns"
    if [ "$active_conns" -ge 0 ] 2>/dev/null && [ "$max_conns" -gt 0 ] 2>/dev/null; then
      if [ "$((active_conns * 100 / max_conns))" -ge 80 ]; then
        echo "WARN: $active_conns of $max_conns connections in use — at the ceiling Postgres refuses new sessions and every request fails"
      fi
    fi
    echo
    echo "--- Connections by source (address database state count) ---"
    if [ -n "$conn_sources" ]; then
      echo "$conn_sources"
      local conn_addr
      for conn_addr in $(echo "$conn_sources" | awk '{print $1}' | sort -u); do
        case "$conn_addr" in local|"") continue ;; esac
        if [ -n "$db_gateway" ] && [ "$conn_addr" = "$db_gateway" ]; then
          echo "WARN: sessions from $conn_addr (the docker bridge gateway) arrived through the published 5432 port rather than from the app or job containers"
        else
          case " $db_container_ips " in
            *" $conn_addr "*) : ;;
            *) echo "WARN: sessions from $conn_addr are not from a Broadcast container — an external client is consuming the connection ceiling" ;;
          esac
        fi
      done
    else
      echo "unknown"
    fi
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

  diagnose_step "backup freshness"
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

  diagnose_step "disk attribution"
  # 14. Disk attribution: "disk 92% full" means nothing until you know
  # whether postgres, uploads, logs, or dead Docker images grew
  {
    du -sh /opt/broadcast/db/postgres-data 2>/dev/null || true
    du -sh /opt/broadcast/app/storage 2>/dev/null || true
    du -sh /opt/broadcast/app/uploads 2>/dev/null || true
    du -sh /opt/broadcast/logs 2>/dev/null || true
    echo "(Docker image usage is in versions.txt)"
  } > "$bundle/storage.txt"

  diagnose_step "incident timeline"
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

  diagnose_step "cron liveness"
  # 16. Cron liveness: dead cron means no monitoring, no triggers, no
  # updates — and nothing complains until the dashboard goes stale.
  # Heartbeat is app/monitor/system.json (rewritten every minute by the
  # monitor cron). Log mtimes are NOT a liveness signal: successful cron
  # runs emit no stdout, so their logs sit 0-byte with stale mtimes forever
  # (false-positive WARN observed in a real customer bundle, 2026-08-04).
  # The update/trigger log tails ride along because a silently failing
  # nightly `git pull` was invisible in the bundle until it broke an
  # upgrade (same incident).
  {
    ls -l /opt/broadcast/logs/cron/ 2>/dev/null || echo "no cron log directory"
    if find /opt/broadcast/app/monitor/system.json -mmin -10 2>/dev/null | grep -q .; then
      echo "ok: monitor heartbeat (app/monitor/system.json) written within the last 10 minutes"
    else
      echo "WARN: no monitor heartbeat in the last 10 minutes — cron may be dead (app/monitor/system.json stale or missing)"
    fi
    echo
    echo "--- update.log tail (nightly script update) ---"
    tail -20 /opt/broadcast/logs/cron/update.log 2>/dev/null || echo "(no update.log)"
    echo
    echo "--- trigger.log tail (dashboard-triggered operations) ---"
    tail -20 /opt/broadcast/logs/cron/trigger.log 2>/dev/null || echo "(no trigger.log)"
    echo
    # A server that has been restarting itself is the first thing support needs
    # to know, and the operator will not mention it because it happened without
    # them. Written by recover.sh; see _recovery_notify_admin.
    echo "--- auto-recovery ---"
    if [ -f /opt/broadcast/.no_auto_recovery ]; then
      echo "WARN: auto-recovery is DISABLED (/opt/broadcast/.no_auto_recovery present) — this server will not restart itself when Puma stops answering"
    else
      echo "ok: auto-recovery is enabled"
    fi
    if [ -s /opt/broadcast/logs/recovery.log ]; then
      echo "recoveries recorded: $(grep -c 'RECOVERY' /opt/broadcast/logs/recovery.log 2>/dev/null || echo unknown)"
      tail -10 /opt/broadcast/logs/recovery.log 2>/dev/null || true
    else
      echo "no recoveries recorded"
    fi
    echo
    # A deferred upgrade is correct behaviour once, but a server that is busy
    # around the clock would stop upgrading and never say so.
    if [ -f /opt/broadcast/.upgrade_deferred ]; then
      echo "WARN: an upgrade has been deferred $(head -1 /opt/broadcast/.upgrade_deferred 2>/dev/null) time(s) because work was in flight — target: $(sed -n '2p' /opt/broadcast/.upgrade_deferred 2>/dev/null || echo latest)"
    else
      echo "ok: no upgrade is currently deferred"
    fi
  } > "$bundle/cron.txt"

  diagnose_step "local customizations"
  # 16b. Local customizations: a hand-edited tracked file blocks every git
  # pull — nightly updates fail silently and upgrades abort (2026-08-04
  # incident, invisible in the bundle until this collector). The override
  # file is the supported customization path, so its contents matter to
  # support.
  {
    echo "--- git status (tracked files; any entry here blocks script updates) ---"
    git -C /opt/broadcast status --porcelain --untracked-files=no 2>&1 || true
    echo
    echo "--- installed scripts revision ---"
    git -C /opt/broadcast log -1 --oneline 2>&1 || true
    echo
    if [ -f /opt/broadcast/docker-compose.override.yml ]; then
      echo "--- docker-compose.override.yml (customer customizations, applied on top of stock) ---"
      cat /opt/broadcast/docker-compose.override.yml
    else
      echo "no docker-compose.override.yml (stock compose configuration)"
    fi
  } > "$bundle/customizations.txt"

  diagnose_step "outbound network (SMTP probes can stall)"
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

  diagnose_step "health probes"
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
  # capture-before-restart discipline in the advice itself.
  # Close the probe step first: the tee below writes to stdout, and without
  # this it would land in the middle of the step's unterminated line.
  diagnose_step_done
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
  diagnose_step "bundle tarball"
  tar -czf "$logs_root/diagnose-$timestamp.tar.gz" -C "$logs_root" "diagnose-$timestamp" \
    || echo -e "\e[31mCould not create the bundle tarball; the directory remains at $bundle\e[0m"

  # Prune old bundles. Nothing ever removed them, and each one now carries a
  # week of journal, so logs/ grew unbounded (734MB observed on a real
  # server) — which then made the NEXT run slower. Sort by name, not mtime:
  # the timestamp is in the name and sorts chronologically, whereas mtimes
  # tie when several bundles are written in the same second.
  local keep=3 stale
  while IFS= read -r stale; do
    [ -n "$stale" ] && rm -rf "$stale"
  done < <(ls -d "$logs_root"/diagnose-*/ 2>/dev/null | sort -r | tail -n +$((keep + 1)))
  while IFS= read -r stale; do
    [ -n "$stale" ] && rm -f "$stale"
  done < <(ls "$logs_root"/diagnose-*.tar.gz 2>/dev/null | sort -r | tail -n +$((keep + 1)))

  diagnose_step_done
  echo -e "\e[32mBundle collected in $(( $(date +%s) - run_started ))s\e[0m"

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
  echo "--- Local customizations (dirty tree blocks updates; override file) ---"
  cat "$bundle/customizations.txt" 2>/dev/null || true
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
  # 40, not 20: processes.txt is the memory block (17 lines) then the CPU
  # block, so head -20 stopped one line into the CPU header and that section
  # printed empty in every real bundle.
  head -40 "$bundle/processes.txt" 2>/dev/null || true
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
