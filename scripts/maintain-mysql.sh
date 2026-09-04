#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo scripts/maintain-mysql.sh COMMAND

Commands:
  start     Start MySQL and wait until it accepts connections
  stop      Stop MySQL
  restart   Restart MySQL and wait until it accepts connections
  status    Show service status and server version
  health    Verify that MySQL accepts a local administrative connection
  upgrade   Install Ubuntu's available MySQL updates, then restart
EOF
}

if (( EUID != 0 )); then
  echo "Run this script as root (for example, with sudo)." >&2
  exit 1
fi

command="${1:-}"
case "$command" in
  start|stop|restart|status|health|upgrade) ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "$command" != upgrade ]] && ! command -v mysqladmin >/dev/null; then
  echo "MySQL is not installed; run scripts/setup-mysql.sh first." >&2
  exit 1
fi

service_action() {
  local action=$1
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl "$action" mysql
  else
    case "$action" in
      start)
        if mysqladmin --user=root --silent ping >/dev/null 2>&1; then
          return
        fi
        install -o mysql -g mysql -m 0755 -d /var/run/mysqld
        mysqld --user=mysql --daemonize --pid-file=/var/run/mysqld/mysqld.pid
        ;;
      stop)
        mysqladmin --user=root shutdown
        ;;
      restart)
        if mysqladmin --user=root --silent ping >/dev/null 2>&1; then
          mysqladmin --user=root shutdown
        fi
        install -o mysql -g mysql -m 0755 -d /var/run/mysqld
        mysqld --user=mysql --daemonize --pid-file=/var/run/mysqld/mysqld.pid
        ;;
      status)
        mysqladmin --user=root status
        ;;
    esac
  fi
}

wait_until_ready() {
  local _
  for _ in {1..30}; do
    if mysqladmin --user=root --silent ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "MySQL did not become ready within 30 seconds." >&2
  return 1
}

case "$command" in
  start)
    service_action start
    wait_until_ready
    ;;
  stop)
    service_action stop
    ;;
  restart)
    service_action restart
    wait_until_ready
    ;;
  status)
    service_action status
    mysql --user=root --batch --execute='SELECT VERSION() AS mysql_version, NOW() AS server_time;'
    ;;
  health)
    mysqladmin --user=root ping
    mysql --user=root --batch --execute='SELECT 1 AS healthy;'
    ;;
  upgrade)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --only-upgrade mysql-server mysql-client
    service_action restart
    wait_until_ready
    mysql --version
    ;;
esac
