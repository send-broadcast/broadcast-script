function start() {
  echo -e "\e[33mStarting Broadcast service...\e[0m"
  # The service reads the env files as the broadcast user (see common.sh)
  secure_env_files
  systemctl start broadcast
  echo -e "\e[32mBroadcast service started successfully!\e[0m"
}
