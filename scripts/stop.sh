function stop() {
  echo -e "\e[33mStopping Broadcast service...\e[0m"
  disconnect_database_clients
  systemctl stop broadcast
  echo -e "\e[32mBroadcast service stopped successfully!\e[0m"
}
