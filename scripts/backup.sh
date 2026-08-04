function backup() {
  echo -e "\e[33mStarting backup...\e[0m"
  echo "Not yet implemented"
}

function backup_database() {
  create_database_backup_file

  sudo cp /opt/broadcast/db/backups/broadcast-backup-*.tar.gz /opt/broadcast/app/storage
  sudo chown -R broadcast:broadcast /opt/broadcast/app/storage/broadcast-backup-*.tar.gz
}

function create_database_backup_file() {
  echo -e "\e[33mStarting backup...\e[0m"

  timestamp=$(date +%Y-%m-%d-%H-%M-%S)
  
  # Get current version if available
  current_version="unknown"
  if [ -f "/opt/broadcast/.current_version" ]; then
    current_version=$(cat /opt/broadcast/.current_version)
  fi
  
  backup_file_name="broadcast-backup-v${current_version}-$timestamp"

  echo -e "\e[33mDumping the primary database. This can take several minutes on large databases;\e[0m"
  echo -e "\e[33mprogress can be watched from another terminal with: ls -lh /opt/broadcast/db/backups/temp-backup.dump\e[0m"

  # We only backup the primary database. The queue and cache databases are
  # ephemeral and considered unimportant for restoration. -T disables TTY
  # allocation: an interactive run otherwise pulls the binary dump through a
  # pty, corrupting it — and the checksum sidecar is computed after the
  # corruption, so restore's integrity check cannot catch it.
  cd /opt/broadcast
  sudo docker compose exec -T postgres pg_dump -U broadcast -Fc broadcast_primary_production > /opt/broadcast/db/backups/temp-backup.dump
  sudo mv /opt/broadcast/db/backups/temp-backup.dump /opt/broadcast/db/backups/$backup_file_name.dump

  # Create VERSION file with backup metadata
  echo "$current_version" > /opt/broadcast/db/backups/VERSION

  sudo tar -czvf /opt/broadcast/db/backups/$backup_file_name.tar.gz \
    -C /opt/broadcast/db/backups \
    $backup_file_name.dump \
    VERSION
  sudo rm /opt/broadcast/db/backups/$backup_file_name.dump /opt/broadcast/db/backups/VERSION

  # Checksum sidecar so restore (and offsite downloads) can verify integrity
  sudo sh -c "cd /opt/broadcast/db/backups && sha256sum $backup_file_name.tar.gz > $backup_file_name.tar.gz.sha256"
  sudo chown -R broadcast:broadcast /opt/broadcast/db/backups

  # Remove all but the most recent backup file, and any sidecar whose
  # tarball is gone
  cd /opt/broadcast/db/backups && ls -t broadcast-backup-*.tar.gz | tail -n +2 | xargs -r rm --
  for sidecar in broadcast-backup-*.tar.gz.sha256; do
    [ -e "$sidecar" ] || continue
    [ -f "${sidecar%.sha256}" ] || rm -f -- "$sidecar"
  done

  echo -e "\e[32mBackup successfully archived: v${current_version} with timestamp: $timestamp\e[0m"
}

function install_s3cmd() {
  echo -e "\e[33mInstalling s3cmd...\e[0m"
  echo "Not yet implemented"
  # sudo apt-get install s3cmd
}
