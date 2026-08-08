# Upgrade preflight: refuse to stop the containers while work is running that
# a restart cannot resume.
#
# Reads Postgres directly rather than asking the app, for the same reason the
# queue and database collectors in diagnose do: a wedged or dead app container
# must not be able to block or skew the answer, and a wedged app is exactly
# when someone reaches for an upgrade. The app holds the authoritative copy of
# these rules in UpgradeSafety (app/services/upgrade_safety.rb) and refuses to
# write the trigger file for the same reasons — keep the two in step.
#
# Blocks on:
#   - claimed job executions: a worker is running the job right now, and
#     killing it can cut a send off partway through a batch of recipients
#   - broadcasts queueing or sending (status enum positions 2 and 3; the app's
#     enum is a positional array, so these are integers from SQL)
#
# Does NOT block on:
#   - queued-but-unclaimed work, which lives in the database and is picked up
#     again after the restart; blocking on it would stall upgrades on any busy
#     server for no safety gain
#   - an unreachable database, where no worker can be running a job either and
#     refusing would block the very restart that recovers the system

# Closes lingering client sessions so Postgres can shut down promptly.
#
# Postgres under SIGTERM does a SMART shutdown: it waits for existing clients
# to disconnect, indefinitely. The official image sets STOPSIGNAL SIGINT to get
# a fast shutdown instead, but compose still allows only its grace period
# before SIGKILL, and a shutdown checkpoint on a multi-GB database can exceed
# that on its own. A SIGKILLed Postgres does WAL crash recovery on the next
# boot, its healthcheck stays unhealthy, and `depends_on: service_healthy`
# leaves the app container waiting — which is exactly what "the upgrade hangs"
# looks like from the operator's chair.
#
# Everything here is best-effort and always returns 0: this runs on the
# shutdown path, and aborting an upgrade over a cleanup step would be worse
# than the problem it solves. The sessions are named before they are closed,
# because "we disconnected a remote client that was idle in transaction" is
# the single most useful line a support bundle can carry for this failure.
function disconnect_database_clients() {
  local psql="docker exec postgres psql -U broadcast -d broadcast_primary_production -t -A -c"
  local sessions="" terminated=""

  sessions=$($psql "SELECT COALESCE(host(client_addr), 'local') || ' ' || COALESCE(NULLIF(application_name, ''), '-') || ' ' || COALESCE(state, '-') FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()" 2>/dev/null) || sessions=""

  if [ -z "$(echo "$sessions" | tr -d '[:space:]')" ]; then
    return 0
  fi

  echo -e "\e[33mClosing database sessions before shutdown:\e[0m"
  echo "$sessions" | sed 's/^/  - /'

  terminated=$($psql "SELECT COUNT(*) FROM (SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()) t" 2>/dev/null) || terminated=""
  terminated=$(echo "$terminated" | tr -d '[:space:]')
  case "$terminated" in
    ''|*[!0-9]*) terminated=0 ;;
  esac
  echo "Closed $terminated database session(s)."

  return 0
}

# Records a deferred automated upgrade so a permanently busy server does not
# silently stop upgrading. Line 1 is the deferral count, line 2 the target
# version (blank for "latest") so the retry knows what was asked for.
function _preflight_deferral_file() {
  echo "${BROADCAST_ROOT:-/opt/broadcast}/.upgrade_deferred"
}

# Reads a single count from psql, treating anything non-numeric (unreachable
# database, permission error, empty result) as zero — see the header on why
# an unreadable database must not block.
function _preflight_count() {
  local database="$1" query="$2" value=""
  value=$(docker exec postgres psql -U broadcast -d "$database" -t -A -c "$query" 2>/dev/null) || value=""
  value=$(echo "$value" | tr -d '[:space:]')
  case "$value" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$value" ;;
  esac
}

# upgrade_preflight [--automated] [target_version]
# Exit 0 = safe to proceed. Exit 1 = work in flight.
function upgrade_preflight() {
  local automated="" target_version=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --automated) automated="yes" ;;
      *) target_version="$1" ;;
    esac
    shift
  done

  local deferral_file
  deferral_file=$(_preflight_deferral_file)

  local claimed sending reasons=""
  claimed=$(_preflight_count "broadcast_queue_production" \
    "SELECT COUNT(*) FROM solid_queue_claimed_executions")
  sending=$(_preflight_count "broadcast_primary_production" \
    "SELECT COUNT(*) FROM broadcasts WHERE status IN (2, 3)")

  if [ "$claimed" -gt 0 ]; then
    reasons="${reasons}  - ${claimed} job(s) mid-execution (a worker is running them right now)\n"
  fi
  if [ "$sending" -gt 0 ]; then
    reasons="${reasons}  - ${sending} broadcast(s) queueing or sending\n"
  fi

  if [ -z "$reasons" ]; then
    rm -f "$deferral_file"
    echo -e "\e[32mPreflight: no in-flight work — safe to upgrade.\e[0m"
    return 0
  fi

  echo -e "\e[33mPreflight: work is in flight and an upgrade would interrupt it:\e[0m"
  printf "%b" "$reasons"

  if [ -n "$automated" ]; then
    local count=1
    if [ -f "$deferral_file" ]; then
      count=$(( $(head -1 "$deferral_file" 2>/dev/null || echo 0) + 1 ))
    fi
    printf '%s\n%s\n' "$count" "$target_version" > "$deferral_file"
    echo "Deferring this automated upgrade (deferred ${count} time(s)); it will retry once the queue drains."
  else
    echo "Wait for the work to finish, or re-run with --force to upgrade anyway."
  fi

  return 1
}
