#!/usr/bin/env bash
set -euo pipefail

# Install and provision the local MySQL instance used by this driver's tests.
# Override these values in the environment before running the script if needed.
MYSQL_TEST_USER="${MYSQL_TEST_USER:-gotest}"
MYSQL_TEST_PASS="${MYSQL_TEST_PASS:-secret}"
MYSQL_TEST_DBNAME="${MYSQL_TEST_DBNAME:-gotest}"
MYSQL_TEST_ADDR="${MYSQL_TEST_ADDR:-127.0.0.1:3306}"

if (( EUID != 0 )); then
  echo "Run this script as root (for example, with sudo)." >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify this operating system; Ubuntu is required." >&2
  exit 1
fi
# This file is supplied by the detected OS.
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != ubuntu ]]; then
  echo "Unsupported operating system: ${PRETTY_NAME:-unknown}. Ubuntu is required." >&2
  exit 1
fi

for value_name in MYSQL_TEST_USER MYSQL_TEST_DBNAME; do
  value="${!value_name}"
  if [[ ! "$value" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "$value_name must contain only letters, numbers, and underscores." >&2
    exit 1
  fi
done

echo "Installing MySQL from the Ubuntu package repository..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
if ! apt-get install -y mysql-server mysql-client; then
  # In minimal containers PID 1 may not reap mysqld's short-lived daemonize
  # process. Ubuntu's postinst then mistakes that zombie for a live server and
  # times out. Retry configuration with a zombie-aware process check.
  postinst=/var/lib/dpkg/info/mysql-server-8.0.postinst
  if [[ ! -f "$postinst" ]] || ! ps -C mysqld -o stat= | awk '$1 ~ /^Z/ { found=1 } END { exit !found }'; then
    echo "MySQL package installation failed for an unexpected reason." >&2
    exit 1
  fi
  postinst_backup="$(mktemp)"
  cp "$postinst" "$postinst_backup"
  trap 'cp "$postinst_backup" "$postinst"; rm -f "$postinst_backup"' EXIT
  # The dollar signs below belong to the package script, not this script.
  # shellcheck disable=SC2016
  sed -i 's/if ! $(ps $server_pid >\/dev\/null 2>\&1); then/if ! ps -p "$server_pid" -o stat= 2>\/dev\/null | grep -qv "^[[:space:]]*Z"; then/' "$postinst"
  dpkg --configure --pending
  cp "$postinst_backup" "$postinst"
  rm -f "$postinst_backup"
  trap - EXIT
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/maintain-mysql.sh" start

# Pass SQL on stdin rather than in mysql's arguments, where it would be visible
# in the process list. Escape characters significant in a single-quoted value.
escaped_password=${MYSQL_TEST_PASS//\\/\\\\}
escaped_password=${escaped_password//\'/\'\'}

mysql --user=root <<SQL
CREATE DATABASE IF NOT EXISTS \`${MYSQL_TEST_DBNAME}\`;
CREATE USER IF NOT EXISTS '${MYSQL_TEST_USER}'@'localhost' IDENTIFIED BY '${escaped_password}';
ALTER USER '${MYSQL_TEST_USER}'@'localhost' IDENTIFIED BY '${escaped_password}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_TEST_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

cat > /etc/mysql/mysql.conf.d/go-mysql-driver.cnf <<'CNF'
[mysqld]
local_infile=1
max_allowed_packet=48M
max_connections=50
performance_schema=ON
CNF

"$SCRIPT_DIR/maintain-mysql.sh" restart

export MYSQL_PWD="$MYSQL_TEST_PASS"
mysql --protocol=TCP --host="${MYSQL_TEST_ADDR%:*}" --port="${MYSQL_TEST_ADDR##*:}" \
  --user="$MYSQL_TEST_USER" --database="$MYSQL_TEST_DBNAME" \
  --execute='SELECT VERSION() AS mysql_version, CURRENT_USER() AS authenticated_as;'
unset MYSQL_PWD

cat <<EOF

MySQL is ready. Use these variables to run the integration tests:
  export MYSQL_TEST_USER='$MYSQL_TEST_USER'
  export MYSQL_TEST_PASS='<the password supplied to setup-mysql.sh>'
  export MYSQL_TEST_ADDR='$MYSQL_TEST_ADDR'
  export MYSQL_TEST_DBNAME='$MYSQL_TEST_DBNAME'
EOF
