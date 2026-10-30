function display_logs() {
  if [ $# -eq 2 ] && [ "$1" = "logs" ]; then
    case "$2" in
      app)
        docker logs --follow app
        ;;
      job)
        docker logs --follow job
        ;;
      db)
        docker logs --follow postgres
        ;;
      plugins|egress)
        docker logs --follow "$2"
        ;;
      *)
        echo "Please specify a valid log type: app, job, db, plugins or egress"
        exit 1
        ;;
    esac
  else
    echo "Usage: $0 logs <app|job|db|plugins|egress>"
    exit 1
  fi
}

# === On-Demand Log Streaming (for web UI) ===
LOGS_TRIGGER="/opt/broadcast/app/triggers/logs-stream.txt"
LOGS_OUTPUT="/opt/broadcast/logs/application.log"
LOGS_PID_FILE="/opt/broadcast/logs/.streaming.pid"
# The viewer reads only the newest lines (a 200-line backlog, then it follows),
# so application.log needs no long history. Past LOGS_MAX_BYTES it is emptied.
LOGS_MAX_BYTES=$((50 * 1024 * 1024))

is_streaming_active() {
  if [ -f "$LOGS_PID_FILE" ]; then
    local pid=$(cat "$LOGS_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      # Process exists - verify it's still our streaming process
      if ps -p "$pid" -o args= 2>/dev/null | grep -q "docker logs"; then
        return 0
      fi
    fi
    # Stale PID file - clean up
    rm -f "$LOGS_PID_FILE"
  fi
  return 1
}

start_log_streaming() {
  # Idempotent: never spawn a second streamer on top of a live one. This makes
  # it safe for the inotify handler, the periodic reconciler, and startup to all
  # funnel through here.
  if is_streaming_active; then
    echo "[$(date)] Log streaming already active, skipping start"
    return 0
  fi

  echo "[$(date)] Starting log streaming..."
  mkdir -p "$(dirname "$LOGS_OUTPUT")"

  # Genuine fresh start: discard any stale output left behind by a streamer that
  # died (e.g. when the containers were last recreated during an upgrade).
  : > "$LOGS_OUTPUT"

  # `docker logs -f` is bound to a *container instance* and exits the moment the
  # container is recreated (upgrade/restart). Supervise each follow in a loop so
  # streaming re-attaches to the new container instead of silently dying. The
  # first attach includes recent backlog; reattaches pull only the gap (--since)
  # to avoid re-dumping the same 100 lines. setsid puts the whole tree in a new
  # session/process group so stop_log_streaming can kill it cleanly.
  #
  # Daemon fd hygiene matters here: the watcher calls this from inside a
  # flock-guarded reconcile that holds the lock on fd 9. Without `9>&-` the
  # long-lived streamer would inherit that descriptor and pin the lock for its
  # entire lifetime, so every later reconcile (stop on trigger removal, periodic
  # self-heal) would block on flock and silently skip. `</dev/null` likewise
  # drops the inotify pipe inherited on stdin. Keep both.
  setsid bash -c '
    stream_container() {
      local name="$1" label="$2"
      docker logs -f --tail=100 --timestamps "$name" 2>&1 | sed "s/^/[$label] /"
      while true; do
        sleep 1
        docker logs -f --since 5s --timestamps "$name" 2>&1 | sed "s/^/[$label] /"
      done
    }
    stream_container app web &
    stream_container job job &
    wait
  ' </dev/null >> "$LOGS_OUTPUT" 2>&1 9>&- &

  local pid=$!
  echo "$pid" > "$LOGS_PID_FILE"
  echo "[$(date)] Log streaming started (PID: $pid)"
}

stop_log_streaming() {
  if [ -f "$LOGS_PID_FILE" ]; then
    local pid=$(cat "$LOGS_PID_FILE" 2>/dev/null)
    echo "[$(date)] Stopping log streaming (PID: $pid)..."

    if [ -n "$pid" ]; then
      # Kill the entire process group so every descendant dies (the supervisor
      # loops, the `docker logs` follows, and the `sed` filters). setsid put the
      # streamer in its own group; resolve the real PGID from the stored pid
      # rather than assuming it equals the pid (setsid may have forked).
      local pgid
      pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
      if [ -n "$pgid" ]; then
        kill -TERM "-$pgid" 2>/dev/null
        sleep 1
        kill -KILL "-$pgid" 2>/dev/null
      fi

      # Fallbacks in case the group is already gone but children linger.
      pkill -KILL -P "$pid" 2>/dev/null
      kill -KILL "$pid" 2>/dev/null
    fi

    rm -f "$LOGS_PID_FILE"
    rm -f "$LOGS_OUTPUT"
    echo "[$(date)] Log streaming stopped"
  fi
}

cap_log_output() {
  # A browser tab closed without Stop leaves the streamer on, and nothing else
  # limits this file (the logrotate pattern does not match it).
  #
  # This runs as root, and the logs folder is writable by the broadcast user, so
  # never write through a symlink planted at this path.
  [ -f "$LOGS_OUTPUT" ] && [ ! -L "$LOGS_OUTPUT" ] || return 0

  local size
  size=$(wc -c < "$LOGS_OUTPUT" | tr -d ' ')
  [ "$size" -gt "$LOGS_MAX_BYTES" ] || return 0

  # Truncate in place: the streamer holds the file open in append mode, so a
  # new file (mv) would leave it writing to a deleted inode that still uses the
  # disk. The streamer writes new lines again within seconds, and the viewer
  # reads from the start when the file is shorter than its position.
  : > "$LOGS_OUTPUT"
  echo "[$(date)] Emptied application.log at $size bytes"
}

check_log_streaming_trigger() {
  # Safety check: only run if volume mount exists (container was recreated with new compose)
  if ! docker exec app test -d /rails/logs 2>/dev/null; then
    # Volume not mounted yet - clean up any stale trigger
    if [ -f "$LOGS_TRIGGER" ]; then
      rm -f "$LOGS_TRIGGER"
      echo "[$(date)] Removed stale logs-stream.txt trigger (volume not mounted)"
    fi
    return
  fi

  if [ -f "$LOGS_TRIGGER" ]; then
    if ! is_streaming_active; then
      start_log_streaming
    fi
    cap_log_output
  else
    if is_streaming_active; then
      stop_log_streaming
    elif [ -e "$LOGS_OUTPUT" ] || [ -L "$LOGS_OUTPUT" ]; then
      # Left behind by a streamer that died with the trigger gone; nothing else
      # removes it. upgrade restarts this watcher, so existing installs get the
      # space back on the first reconcile.
      rm -f "$LOGS_OUTPUT"
      echo "[$(date)] Removed a stale application.log"
    fi
  fi
}
