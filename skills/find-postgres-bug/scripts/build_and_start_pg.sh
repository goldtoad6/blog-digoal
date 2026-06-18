#!/usr/bin/env bash
# build_and_start_pg.sh — build PostgreSQL from source and start a local
# instance. Idempotent. The instance is INTENTIONALLY left running when
# this script exits; use stop_pg.sh to tear it down.
#
# Steps (skipped if already done):
#   1. ./configure (debug + cassert + debug-symbols)
#   2. make -j
#   3. make install (into $PG_PREFIX)
#   4. initdb (if $PGDATA/PG_VERSION missing)
#   5. configure listen + port + log
#   6. pg_ctl start
#
# Override defaults by exporting them before calling this script, e.g.:
#   PG_SRC_DIR=/path/to/pg PG_PORT=55432 ./build_and_start_pg.sh

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pg_env.sh
source "$HERE/pg_env.sh"

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "==> Source:   $PG_SRC_DIR"
echo "==> Prefix:   $PG_PREFIX"
echo "==> Data:     $PGDATA"
echo "==> Port:     $PG_PORT"
echo "==> User:     $PG_USER"
echo "==> Configure: $PG_CONFIGURE_OPTS"

cd "$PG_SRC_DIR"

# 1. configure (only if Makefile.global missing)
if [ ! -f "$PG_SRC_DIR/src/Makefile.global" ]; then
  echo "==> ./configure ..."
  # shellcheck disable=SC2086
  ./configure $PG_CONFIGURE_OPTS
fi

# 2. build
echo "==> make -j$JOBS"
make -j"$JOBS" -s

# 3. install
echo "==> make install"
make install -s

# 4. initdb (only if not already initialised)
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "==> initdb"
  mkdir -p "$PGDATA"
  initdb -D "$PGDATA" -U "$PG_USER" --auth=trust --no-locale --encoding=UTF8
fi

# 5. write minimal postgresql.conf overrides (idempotent — uses include_if_exists)
cat > "$PG_PREFIX/data.conf" <<EOF
# managed by find-postgres-bug
port = $PG_PORT
unix_socket_directories = '$PG_SOCK_DIR'
listen_addresses = '127.0.0.1'
shared_preload_libraries = ''
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'server.log'
log_min_messages = debug1
log_min_error_statement = debug1
log_statement = 'all'
log_line_prefix = '%m [%p] %q%u@%d from %h '
include_if_exists = '$PG_PREFIX/data.conf'
EOF
# Make sure postgresql.conf ends with our include
if ! grep -q "include_if_exists = '$PG_PREFIX/data.conf'" "$PG_CONF" 2>/dev/null; then
  echo "" >> "$PG_CONF"
  echo "include_if_exists = '$PG_PREFIX/data.conf'" >> "$PG_CONF"
fi

# 6. start (idempotent — skip if already running)
if pg_ctl -D "$PGDATA" status >/dev/null 2>&1; then
  echo "==> PG already running (pid: $(pg_ctl -D "$PGDATA" status | awk '/PID/ {print $NF}'))"
else
  echo "==> pg_ctl start"
  pg_ctl -D "$PGDATA" -l "$PG_LOG" -o "-p $PG_PORT -k $PG_SOCK_DIR" start
  # wait for readiness
  for i in $(seq 1 30); do
    if pg_isready -h /tmp -p "$PG_PORT" -q; then break; fi
    sleep 0.5
  done
fi

echo
echo "==> PG UP on port $PG_PORT  (log: $PG_LOG)"
echo "    Connect:  psql -h /tmp -p $PG_PORT -U $PG_USER -d postgres"
echo "    Stop:     $HERE/stop_pg.sh"
