# MySQL scripts for Codex Cloud

These scripts install and operate a local MySQL server in the Ubuntu
environment provided by Codex Cloud. They provision the defaults used by this
repository's integration tests; they are not intended to be a general-purpose
production MySQL deployment.

## Setup

Run the idempotent setup script as root:

```bash
sudo scripts/setup-mysql.sh
```

It installs MySQL from Ubuntu's package repository, creates the test database
and account, applies the test server configuration, and verifies a TCP
connection. The defaults match CI and can be overridden before setup:

```bash
sudo env \
  MYSQL_TEST_USER=gotest \
  MYSQL_TEST_PASS=secret \
  MYSQL_TEST_ADDR=127.0.0.1:3306 \
  MYSQL_TEST_DBNAME=gotest \
  scripts/setup-mysql.sh
```

Export the same values when running the tests:

```bash
export MYSQL_TEST_USER=gotest MYSQL_TEST_PASS=secret
export MYSQL_TEST_ADDR=127.0.0.1:3306 MYSQL_TEST_DBNAME=gotest
go test ./...
```

## Maintenance

Use the maintenance script to manage the server in Codex Cloud:

```bash
sudo scripts/maintain-mysql.sh status
sudo scripts/maintain-mysql.sh health
sudo scripts/maintain-mysql.sh start
sudo scripts/maintain-mysql.sh stop
sudo scripts/maintain-mysql.sh restart
sudo scripts/maintain-mysql.sh upgrade
```

Run the script without a command to display its built-in usage summary.
