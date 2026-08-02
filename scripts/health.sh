# Health reporter: the install-side half of the opt-in server monitoring
# feature. Runs from cron every minute, probes the local stack, and reports
# to sendbroadcast.net so the dashboard can show health and alert the owner
# (the down system is an email platform — it cannot email about itself).
#
# Fleet-safety rules, each deliberate:
#   - Hysteresis: 3 consecutive failed probes before declaring unhealthy,
#     so a deploy blip or restart never pages anyone.
#   - Transitions send immediately; steady state sends only a heartbeat
#     every heartbeat_interval seconds — and the server steers that
#     interval via its response, so fleet cadence is tunable server-side.
#   - Jitter: heartbeats sleep a per-domain splay so the fleet's crons
#     (which all fire at second :00) do not arrive as one spike.
#   - Backoff: failed sends drop the report (lossy by design — a queued
#     backlog would spike the server on recovery) and back off
#     exponentially. Transitions bypass backoff; they are rare.
#   - A "monitoring disabled" response silences everything for an hour —
#     opt-out is respected with at most one probe-shaped request per hour.
#   - Payload is status codes and basic system facts only; the server
#     additionally enforces this whitelist on its side.

HEALTH_REPORT_URL_DEFAULT="https://sendbroadcast.net/health/report"
HEALTH_FAILURE_THRESHOLD=3
HEALTH_DISABLED_RECHECK_SECONDS=3600
HEALTH_BACKOFF_CAP_SECONDS=3600

function health() {
  local state_file="/opt/broadcast/.health_state"
  local url="${BROADCAST_HEALTH_URL:-$HEALTH_REPORT_URL_DEFAULT}"
  local now
  now=$(date +%s)

  local domain="" key=""
  [ -f /opt/broadcast/.domain ] && domain=$(cat /opt/broadcast/.domain)
  [ -f /opt/broadcast/.license ] && key=$(cat /opt/broadcast/.license)
  if [ -z "$domain" ] || [ -z "$key" ]; then
    echo "[$(date)] health: missing .domain or .license; skipping"
    return 0
  fi

  # --- Load persisted state (our own root-owned key=value file) ----------
  local last_status="" consecutive_failures=0 last_heartbeat=0
  local heartbeat_interval=300 disabled_until=0 backoff_until=0 send_failures=0
  if [ -f "$state_file" ]; then
    # shellcheck disable=SC1090
    source "$state_file" || true
  fi

  # --- Probe each layer ---------------------------------------------------
  local puma thruster https
  puma=$(docker exec app curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost:3000/up 2>/dev/null) || puma="000"
  thruster=$(curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost/up 2>/dev/null) || thruster="000"
  https=$(curl -sk --resolve "$domain:443:127.0.0.1" -o /dev/null -w "%{http_code}" -m 20 "https://$domain/up" 2>/dev/null) || https="000"

  # --- Verdict with hysteresis -------------------------------------------
  local current=""
  if [ "$puma" = "200" ]; then
    consecutive_failures=0
    current="healthy"
  else
    consecutive_failures=$((consecutive_failures + 1))
    if [ "$consecutive_failures" -ge "$HEALTH_FAILURE_THRESHOLD" ]; then
      current="unhealthy"
    elif [ -n "$last_status" ]; then
      current="$last_status"   # not enough evidence to change the verdict
    fi                          # else: no verdict yet on a brand-new install
  fi

  # --- Decide whether to send --------------------------------------------
  local transition=false send=false
  if [ -n "$current" ] && [ -n "$last_status" ] && [ "$current" != "$last_status" ]; then
    transition=true
  fi

  if [ -n "$current" ]; then
    if [ "$transition" = true ]; then
      send=true
    elif [ $((now - last_heartbeat)) -ge "$heartbeat_interval" ]; then
      send=true
    fi
  fi

  # Opt-out silence and failure backoff (transitions bypass backoff only)
  if [ "$now" -lt "$disabled_until" ]; then
    send=false
  elif [ "$now" -lt "$backoff_until" ] && [ "$transition" != true ]; then
    send=false
  fi

  # --- Send ---------------------------------------------------------------
  if [ "$send" = true ]; then
    if [ "$transition" != true ]; then
      # Per-domain splay so the fleet's synchronized crons spread out
      local splay
      splay=$(( $(printf %s "$domain" | cksum | cut -d' ' -f1) % 30 ))
      sleep "$splay"
    fi

    local reboot_required="false"
    [ -f /var/run/reboot-required ] && reboot_required="true"
    local disk_used mem_used load_avg cores version os_name
    disk_used=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%') || disk_used=""
    mem_used=$(free 2>/dev/null | awk '/Mem:/ {printf "%d", $3/$2*100}') || mem_used=""
    load_avg=$(uptime 2>/dev/null | awk -F'average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ') || load_avg=""
    cores=$(nproc 2>/dev/null) || cores=""
    version=$(cat /opt/broadcast/.current_version 2>/dev/null) || version="unknown"
    os_name=$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2) || os_name=""

    local response="" send_rc=0
    response=$(curl -s -m 15 -X POST \
      --data-urlencode "key=$key" \
      --data-urlencode "domain=$domain" \
      --data-urlencode "status=$current" \
      --data-urlencode "probes[puma]=$puma" \
      --data-urlencode "probes[thruster]=$thruster" \
      --data-urlencode "probes[https]=$https" \
      --data-urlencode "system[reboot_required]=$reboot_required" \
      --data-urlencode "system[disk_used_percent]=$disk_used" \
      --data-urlencode "system[memory_used_percent]=$mem_used" \
      --data-urlencode "system[load]=$load_avg" \
      --data-urlencode "system[cores]=$cores" \
      --data-urlencode "system[version]=$version" \
      --data-urlencode "system[os]=$os_name" \
      "$url" 2>/dev/null) || send_rc=$?

    if [ "$send_rc" -eq 0 ] && echo "$response" | grep -q '"monitoring"'; then
      send_failures=0
      backoff_until=0
      last_heartbeat=$now
      last_status="$current"
      if echo "$response" | grep -q '"monitoring":"disabled"'; then
        disabled_until=$((now + HEALTH_DISABLED_RECHECK_SECONDS))
        echo "[$(date)] health: monitoring is disabled for this server; next check-in in an hour"
      else
        disabled_until=0
        local server_interval
        server_interval=$(echo "$response" | grep -o '"heartbeat_interval":[0-9]*' | grep -o '[0-9]*$') || server_interval=""
        [ -n "$server_interval" ] && heartbeat_interval="$server_interval"
        echo "[$(date)] health: reported $current (puma=$puma thruster=$thruster https=$https)"
      fi
    else
      # Lossy drop + exponential backoff; last_status is left unchanged so
      # an unsent transition is retried after the backoff window
      send_failures=$((send_failures + 1))
      local backoff=$(( 60 * (2 ** (send_failures - 1)) ))
      [ "$backoff" -gt "$HEALTH_BACKOFF_CAP_SECONDS" ] && backoff=$HEALTH_BACKOFF_CAP_SECONDS
      backoff_until=$((now + backoff))
      echo "[$(date)] health: report failed (attempt $send_failures); backing off ${backoff}s"
    fi
  fi

  # --- Persist state atomically ------------------------------------------
  cat > "$state_file.tmp" <<STATE
last_status=$last_status
consecutive_failures=$consecutive_failures
last_heartbeat=$last_heartbeat
heartbeat_interval=$heartbeat_interval
disabled_until=$disabled_until
backoff_until=$backoff_until
send_failures=$send_failures
STATE
  mv "$state_file.tmp" "$state_file"

  return 0
}
