function monitor() {
    # Get CPU information
    cpu_cores=$(nproc)
    cpu_load=$(uptime | awk -F'average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')

    # Get memory information
    mem_total=$(free -b | awk '/Mem:/ {print $2}')
    mem_used=$(free -b | awk '/Mem:/ {print $3}')
    mem_free_percent=$(echo "scale=2; ($mem_total - $mem_used) / $mem_total * 100" | bc)

    # Get disk information
    disk_total=$(df -B1 / | awk 'NR==2 {print $2}')
    disk_used=$(df -B1 / | awk 'NR==2 {print $3}')
    disk_free_percent=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
    disk_free_percent=$(echo "100 - $disk_free_percent" | bc)

    # File descriptors held by the app container, and its ceiling.
    #
    # The 2026-08-15 outage was fd exhaustion inside the app process while every
    # other signal read healthy, and nothing on the box was counting -- so we
    # could not distinguish a burst that exhausted a low limit from a slow leak
    # that had been climbing for days. Cheap to collect (two docker execs a
    # minute) and it answers that question retroactively for every install.
    #
    # Counted across all processes in the container, not just PID 1: Thruster is
    # PID 1 and Puma is its child, and it was Puma's table that filled.
    app_open_files=$(docker exec app sh -c 'ls /proc/[0-9]*/fd 2>/dev/null | grep -c .' 2>/dev/null | tail -1)
    [ -z "$app_open_files" ] && app_open_files=0
    app_open_files_limit=$(docker exec app sh -c 'ulimit -n' 2>/dev/null | tail -1)
    [ -z "$app_open_files_limit" ] && app_open_files_limit=0

    # Get current version
    current_version="unknown"
    if [ -f "/opt/broadcast/.current_version" ]; then
        current_version=$(cat /opt/broadcast/.current_version)
    fi

    # Create JSON output
    json_output=$(cat <<EOF
{
    "cpu_cores": $cpu_cores,
    "cpu_load": $cpu_load,
    "memory_used": $mem_used,
    "memory_total": $mem_total,
    "memory_free_percent": $mem_free_percent,
    "disk_space_total": $disk_total,
    "disk_space_used": $disk_used,
    "disk_space_free_percent": $disk_free_percent,
    "app_open_files": $app_open_files,
    "app_open_files_limit": $app_open_files_limit,
    "current_version": "$current_version"
}
EOF
)

    # Write JSON to file as broadcast user
    su - broadcast -c "echo '$json_output' > /opt/broadcast/app/monitor/system.json"

    # Cron runs stay silent (their stdout is a log file appended every
    # minute); a person at a terminal gets confirmation of what was written.
    if monitor_output_is_terminal; then
        echo "Wrote host metrics to /opt/broadcast/app/monitor/system.json:"
        echo "$json_output"
    fi
}

# Seam for tests; true when a person is watching (stdout is a terminal)
monitor_output_is_terminal() {
    [ -t 1 ]
}
