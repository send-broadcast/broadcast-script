# Compare two semantic versions. Returns:
#   0 if equal
#   1 if first > second
#   2 if first < second
function compare_versions() {
  if [ "$1" = "$2" ]; then
    return 0
  fi

  local IFS=.
  local i ver1=($1) ver2=($2)

  # Fill empty positions with zeros
  for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
    ver1[i]=0
  done
  for ((i=${#ver2[@]}; i<${#ver1[@]}; i++)); do
    ver2[i]=0
  done

  for ((i=0; i<${#ver1[@]}; i++)); do
    if ((10#${ver1[i]} > 10#${ver2[i]})); then
      return 1
    fi
    if ((10#${ver1[i]} < 10#${ver2[i]})); then
      return 2
    fi
  done
  return 0
}

# Root of the Broadcast installation. Overridable so the restore pipeline can
# be exercised against a scratch directory in tests.
BROADCAST_ROOT="${BROADCAST_ROOT:-/opt/broadcast}"

# Locate a backup file by name, checking the standard locations in order.
# Echoes the resolved path on success; error messages go to stderr.
function restore_find_backup_file() {
  local backup_file="$1"

  if [ -f "$BROADCAST_ROOT/$backup_file" ]; then
    echo "$BROADCAST_ROOT/$backup_file"
  elif [ -f "$BROADCAST_ROOT/db/backups/$backup_file" ]; then
    echo "$BROADCAST_ROOT/db/backups/$backup_file"
  elif [ -f "$backup_file" ]; then
    echo "$backup_file"
  else
    echo -e "\e[31mError: Backup file not found: $backup_file\e[0m" >&2
    echo -e "Searched locations:" >&2
    echo -e "  - $BROADCAST_ROOT/$backup_file" >&2
    echo -e "  - $BROADCAST_ROOT/db/backups/$backup_file" >&2
    echo -e "  - $backup_file" >&2
    return 1
  fi
}

# Portable sha256 (Linux sha256sum / macOS shasum)
function sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Verify the tarball against its .sha256 sidecar when one exists. A backup
# corrupted in transit (offsite download, copied between hosts) must be
# refused BEFORE services are stopped. No sidecar means no verification —
# older backups predate sidecars.
function restore_verify_checksum() {
  local backup_path="$1"
  local sidecar="${backup_path}.sha256"

  [ -f "$sidecar" ] || return 0

  echo -e "\e[34mVerifying backup integrity against $(basename "$sidecar")...\e[0m"
  local expected actual
  expected=$(awk '{print $1}' "$sidecar")
  actual=$(sha256_of "$backup_path")

  if [ "$expected" != "$actual" ]; then
    echo -e "\e[31mError: backup failed its checksum — the file is corrupted or incomplete.\e[0m"
    echo -e "\e[31m  expected: $expected\e[0m"
    echo -e "\e[31m  actual:   $actual\e[0m"
    return 1
  fi

  echo -e "\e[32mChecksum verified.\e[0m"
}

# Extract the archive, enforce the version gate, and locate the dump file.
# On success sets RESTORE_TEMP_DIR and RESTORE_DUMP_FILE; on failure cleans up
# the temp directory and returns 1.
function restore_prepare() {
  local backup_path="$1"

  restore_verify_checksum "$backup_path" || return 1

  RESTORE_TEMP_DIR="/tmp/broadcast-restore-$$"
  RESTORE_DUMP_FILE=""
  mkdir -p "$RESTORE_TEMP_DIR"
  local temp_dir="$RESTORE_TEMP_DIR"

  echo -e "\e[34mExtracting backup archive...\e[0m"
  tar -xzf "$backup_path" -C "$temp_dir"

  # Check version compatibility
  local backup_version="unknown"
  local installed_version="unknown"

  if [ -f "$temp_dir/VERSION" ]; then
    backup_version=$(cat "$temp_dir/VERSION")
  fi

  if [ -f "$BROADCAST_ROOT/.current_version" ]; then
    installed_version=$(cat "$BROADCAST_ROOT/.current_version")
  fi

  echo -e "\e[34mBackup version: $backup_version\e[0m"
  echo -e "\e[34mInstalled version: $installed_version\e[0m"

  # The gate can only reason about numeric versions. Installs pinned to a
  # rolling tag ("latest" on fresh installs, "edge"/"edge-<sha>" on dev
  # servers) record that tag in .current_version; feeding it to
  # compare_versions is a bash arithmetic error ("10#edge"), which under
  # `set -e` kills the restore outright. Treat non-numeric as unknown and
  # let the restore proceed with a warning instead.
  local numeric='^[0-9]+(\.[0-9]+)*$'
  if ! [[ "$backup_version" =~ $numeric ]]; then
    backup_version="unknown"
  fi
  if ! [[ "$installed_version" =~ $numeric ]]; then
    if [ "$installed_version" != "unknown" ]; then
      echo -e "\e[33mInstalled version '$installed_version' is not a release version (rolling tag); skipping the version compatibility check.\e[0m"
    fi
    installed_version="unknown"
  fi

  # Check for version incompatibility
  if [ "$backup_version" != "unknown" ] && [ "$installed_version" != "unknown" ]; then
    compare_versions "$backup_version" "$installed_version"
    local version_result=$?

    if [ $version_result -eq 1 ]; then
      # Backup is newer than installed version
      echo -e "\e[31m"
      echo "╔════════════════════════════════════════════════════════════════╗"
      echo "║                    VERSION MISMATCH                            ║"
      echo "║                                                                 ║"
      echo "║  The backup (v$backup_version) is from a NEWER version than    "
      echo "║  your installation (v$installed_version).                       "
      echo "║                                                                 ║"
      echo "║  Restoring a newer backup to an older installation is not      ║"
      echo "║  supported and may cause data loss or application errors.      ║"
      echo "║                                                                 ║"
      echo "║  Please upgrade your installation first:                       ║"
      echo "║    ./broadcast.sh upgrade $backup_version                       "
      echo "╚════════════════════════════════════════════════════════════════╝"
      echo -e "\e[0m"
      rm -rf "$temp_dir"
      return 1
    elif [ $version_result -eq 2 ]; then
      # Backup is older than installed version
      echo -e "\e[33m"
      echo "╔════════════════════════════════════════════════════════════════╗"
      echo "║                        NOTE                                    ║"
      echo "║                                                                 ║"
      echo "║  The backup (v$backup_version) is from an older version than   "
      echo "║  your installation (v$installed_version).                       "
      echo "║                                                                 ║"
      echo "║  Database migrations will run after restore to update the      ║"
      echo "║  schema to the current version.                                ║"
      echo "╚════════════════════════════════════════════════════════════════╝"
      echo -e "\e[0m"
    fi
  fi

  # Find the .dump file
  local dump_file=$(find "$temp_dir" -name "*.dump" -type f | head -1)

  if [ -z "$dump_file" ]; then
    echo -e "\e[31mError: No .dump file found in backup archive\e[0m"
    rm -rf "$temp_dir"
    return 1
  fi

  echo -e "\e[34mFound dump file: $(basename "$dump_file")\e[0m"
  RESTORE_DUMP_FILE="$dump_file"
}

# Stop services, restore RESTORE_DUMP_FILE into the database, migrate, and
# restart. Expects restore_prepare to have run.
function restore_apply() {
  local dump_file="$RESTORE_DUMP_FILE"

  # Stop the application to prevent writes during restore
  echo -e "\e[34mStopping Broadcast services...\e[0m"
  systemctl stop broadcast || true

  # Wait for connections to close
  sleep 3

  # Each step below fails the restore explicitly: this function runs in an ||
  # context from restore(), which suppresses set -e, so an unchecked failure
  # would fall through to the RESTORE COMPLETE banner with nothing restored.

  # Start just the database container
  echo -e "\e[34mStarting database container...\e[0m"
  cd "$BROADCAST_ROOT" || return 1
  set -a
  if ! . "$BROADCAST_ROOT/.image"; then
    set +a
    echo -e "\e[31mError: could not load $BROADCAST_ROOT/.image\e[0m"
    return 1
  fi
  set +a
  if ! docker compose up -d postgres; then
    echo -e "\e[31mError: failed to start the database container\e[0m"
    return 1
  fi

  # Wait for PostgreSQL to be ready
  echo -e "\e[34mWaiting for database to be ready...\e[0m"
  sleep 5

  # Copy dump file into container. Uses `docker compose cp` so the postgres
  # SERVICE is resolved through the compose file — a plain `docker cp` needs
  # the container_name, which has drifted from the script before and aborted
  # a restore midway with services stopped.
  if ! docker compose cp "$dump_file" postgres:/tmp/restore.dump; then
    echo -e "\e[31mError: failed to copy the dump into the database container\e[0m"
    return 1
  fi

  # Run pg_restore
  echo -e "\e[34mRestoring database (this may take a while)...\e[0m"

  if docker compose exec -T postgres pg_restore \
    -U broadcast \
    -d broadcast_primary_production \
    --clean \
    --if-exists \
    --no-owner \
    --no-privileges \
    /tmp/restore.dump; then
    echo -e "\e[32mDatabase restored successfully!\e[0m"
  else
    # pg_restore returns non-zero for warnings too, check if critical
    echo -e "\e[33mRestore completed with warnings (this is often normal)\e[0m"
  fi

  # Clean up dump file in container
  docker compose exec -T postgres rm -f /tmp/restore.dump

  # Run database migrations to handle schema differences between versions.
  # --pull never: the compose file sets pull_policy: always, but restore runs
  # as root, which has no registry login (only the broadcast user does) — and
  # the image is guaranteed local anyway, since the app was running before
  # this restore stopped it.
  echo -e "\e[34mRunning database migrations...\e[0m"
  if ! docker compose run --rm --pull never app bin/rails db:migrate; then
    echo -e "\e[31mError: post-restore database migrations failed\e[0m"
    return 1
  fi

  # Restart all services
  echo -e "\e[34mRestarting Broadcast services...\e[0m"
  systemctl start broadcast

  echo -e "\e[32m"
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║                    RESTORE COMPLETE                            ║"
  echo "║                                                                 ║"
  echo "║  Your database has been restored from the backup.              ║"
  echo "║  Please verify your data at your installation URL.             ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo -e "\e[0m"
}

function restore() {
  local backup_file="${1:-}"
  local confirm_flag="${2:-}"

  # Validate argument
  if [ -z "$backup_file" ]; then
    echo -e "\e[31mError: No backup file specified\e[0m"
    echo -e "Usage: ./broadcast.sh restore <backup-file.tar.gz> [--yes]"
    echo -e "Example: ./broadcast.sh restore broadcast-backup-v2.0.0-2026-01-28-14-30-00.tar.gz"
    return 1
  fi

  local backup_path
  backup_path=$(restore_find_backup_file "$backup_file") || return 1

  echo -e "\e[34mFound backup file: $backup_path\e[0m"

  # Confirm with user, unless running non-interactively (--yes flag or
  # BROADCAST_ASSUME_YES=1, e.g. from automation or tests)
  if [ "$confirm_flag" != "--yes" ] && [ "${BROADCAST_ASSUME_YES:-}" != "1" ]; then
    echo -e "\e[33m"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                         WARNING                                 ║"
    echo "║  This will REPLACE ALL DATA in your database.                  ║"
    echo "║  This action cannot be undone.                                 ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "\e[0m"
    read -p "Are you sure you want to restore from this backup? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
      echo -e "\e[33mRestore cancelled.\e[0m"
      return 0
    fi
  fi

  restore_prepare "$backup_path" || return 1

  local status=0
  restore_apply || status=$?

  # Clean up temp directory
  rm -rf "$RESTORE_TEMP_DIR"

  return $status
}
