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

function diagnose() {
  local timestamp
  timestamp=$(date +%Y-%m-%d-%H-%M-%S)
  local logs_root="/opt/broadcast/logs"
  local bundle="$logs_root/diagnose-$timestamp"
  mkdir -p "$bundle"

  echo -e "\e[33mCollecting diagnostic bundle in $bundle ...\e[0m"

  # 1. Evidence first: full container logs, before anything can wipe them
  local container
  for container in app job postgres; do
    docker logs "$container" > "$bundle/$container.log" 2>&1 \
      || echo "failed to capture $container logs" >> "$bundle/errors.txt"
  done

  # 2. Filtered app log: strip Thruster access/proxy noise so Puma output
  # (crashes, exceptions) surfaces near the top of a support read
  grep -viE '"msg":"Request"|Unable to proxy|TLS handshake' "$bundle/app.log" 2>/dev/null \
    | tail -200 > "$bundle/app-filtered.log" || true

  # 3. Container and system state
  docker ps > "$bundle/docker-ps.txt" 2>&1 || true
  docker stats --no-stream > "$bundle/docker-stats.txt" 2>&1 || true
  { df -h 2>&1 || true; echo; free -m 2>&1 || true; echo; uptime 2>&1 || true; } > "$bundle/system.txt"

  # 4. Kernel OOM check: rules memory kills in or out immediately
  if ! journalctl -k --since "3 days ago" 2>/dev/null \
      | grep -iE "oom|out of memory" > "$bundle/oom.txt"; then
    echo "no kernel OOM events in the last 3 days" > "$bundle/oom.txt"
  fi

  # 5. Layered probes
  local puma_code thruster_code https_code="skipped" domain=""
  puma_code=$(docker exec app curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost:3000/up 2>/dev/null) || puma_code="000"
  thruster_code=$(curl -s -o /dev/null -w "%{http_code}" -m 10 http://localhost/up 2>/dev/null) || thruster_code="000"
  if [ -f /opt/broadcast/.domain ]; then
    domain=$(cat /opt/broadcast/.domain)
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
    if [ "$puma_code" = "200" ] && [ "$thruster_code" = "200" ]; then
      echo "All layers healthy: Puma answers directly and Thruster serves it."
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

  echo
  echo -e "\e[32mDiagnostic bundle ready:\e[0m"
  echo "  Directory: $bundle"
  echo "  Tarball:   $logs_root/diagnose-$timestamp.tar.gz (attach this to your support email)"

  return 0
}
