#!/bin/bash

# two_factor: recovery for two-factor authentication lock-outs.
#
# The dashboard handles the normal cases (a user resets their own factors
# from Profile; a user-management admin resets anyone's from Users). This
# command is for what the dashboard cannot fix: the only administrator has
# lost their authenticator and every recovery code, or enforcement was
# switched on before anyone who could switch it off had enrolled.
#
# Each subcommand runs the matching two_factor:* rake task inside the app
# container, so the app's own code does the work and prints the outcome.

two_factor_usage() {
  echo "Usage: $0 two_factor <subcommand>"
  echo
  echo "Subcommands:"
  echo "  reset <email>          Clear two-factor for one user so they can sign in"
  echo "                         with their password alone and enrol again"
  echo "  disable_enforcement    Stop requiring two-factor for all users"
  echo "                         (Application > Security); enrolled users keep theirs"
  echo "  status                 Show enforcement and which users have it enabled"
}

two_factor() {
  local subcommand="${1:-}"

  case "$subcommand" in
    reset)
      local email="${2:-}"
      if [ -z "$email" ]; then
        echo -e "\e[31mError: an email address is required.\e[0m"
        echo "Usage: $0 two_factor reset <email>"
        return 1
      fi
      # The email is passed to a rake task argument inside the container. Keep
      # it to characters an address can contain so nothing else rides along.
      if ! [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo -e "\e[31mError: '$email' does not look like an email address.\e[0m"
        return 1
      fi
      two_factor_run_task "two_factor:reset[$email]"
      ;;
    disable_enforcement)
      two_factor_run_task "two_factor:disable_enforcement"
      ;;
    status)
      two_factor_run_task "two_factor:status"
      ;;
    *)
      [ -n "$subcommand" ] && echo -e "\e[31mError: unknown subcommand '$subcommand'.\e[0m"
      two_factor_usage
      return 1
      ;;
  esac
}

# Runs one rake task in the running app container and passes its exit
# status back, so a failure inside the app (unknown email, app not running)
# fails this command too.
two_factor_run_task() {
  local task="$1"

  if ! docker exec app bin/rails "$task"; then
    echo -e "\e[31mThe command failed inside the app container. Is Broadcast running? (./broadcast.sh start)\e[0m"
    return 1
  fi
}
