#!/usr/bin/env bash
# pg_instance.sh {init|start|stop|status|psql|pglog|tail} [args...]
# 用法:
#   pg_instance.sh init <pg_install>   # 第一次
#   pg_instance.sh start
#   pg_instance.sh stop
#   pg_instance.sh status
#   pg_instance.sh psql "SELECT 1;"
#   pg_instance.sh tail 200
#
# 环境变量(可覆盖):
#   PG_INSTALL  PG 安装目录 (默认探测)
#   PG_DATA     数据目录    (默认 /tmp/pgbug_data)
#   PG_PORT     端口        (默认 55432)
#   PG_USER     用户        (默认 当前用户)
set -euo pipefail

PG_INSTALL="${PG_INSTALL:-}"
PG_DATA="${PG_DATA:-/tmp/pgbug_data}"
PG_PORT="${PG_PORT:-55432}"
PG_USER="${PG_USER:-$(id -un)}"
PG_LOG_DIR="$PG_DATA/pg_log"

# 自动探测 PG_INSTALL
detect_install() {
    if [ -n "$PG_INSTALL" ] && [ -x "$PG_INSTALL/bin/pg_ctl" ]; then return; fi
    for d in /usr/local/pgsql /opt/postgresql/* $(git -C . rev-parse --show-toplevel 2>/dev/null || true); do
        if [ -x "$d/bin/pg_ctl" ]; then PG_INSTALL="$d"; return; fi
    done
}

cmd="${1:-help}"; shift || true

case "$cmd" in
    init)
        detect_install
        [ -x "$PG_INSTALL/bin/initdb" ] || { echo "initdb not found, set PG_INSTALL"; exit 1; }
        rm -rf "$PG_DATA"
        "$PG_INSTALL/bin/initdb" -D "$PG_DATA" -U "$PG_USER" --encoding=UTF8 --locale=C
        cat >> "$PG_DATA/postgresql.conf" <<EOF
port = ${PG_PORT}
listen_addresses = '127.0.0.1'
unix_socket_directories = '${PG_DATA}'
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_min_messages = warning
log_error_verbosity = verbose
log_line_prefix = '%m [%p] %q%u@%d/%a from %h '
log_statement = 'mod'
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
client_min_messages = notice
shared_preload_libraries = 'auto_explain'
auto_explain.log_min_duration = 0
auto_explain.log_analyze = on
EOF
        echo "initialized at $PG_DATA, port $PG_PORT, install $PG_INSTALL"
        ;;
    start)
        detect_install
        [ -d "$PG_DATA" ] || { echo "no data dir, run init first"; exit 1; }
        "$PG_INSTALL/bin/pg_ctl" -D "$PG_DATA" -l "$PG_DATA/server.log" -w start
        "$PG_INSTALL/bin/pg_isready" -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER"
        ;;
    stop)
        detect_install
        "$PG_INSTALL/bin/pg_ctl" -D "$PG_DATA" -m fast stop || true
        ;;
    status)
        detect_install
        "$PG_INSTALL/bin/pg_ctl" -D "$PG_DATA" status
        echo "--- latest log ---"
        ls -t "$PG_LOG_DIR"/postgresql-*.log 2>/dev/null | head -1 | xargs -I {} tail -50 {}
        ;;
    psql)
        detect_install
        PSQL="$PG_INSTALL/bin/psql"
        exec "$PSQL" -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -X "$@"
        ;;
    pglog)
        ls -lt "$PG_LOG_DIR"/postgresql-*.log 2>/dev/null | head -20
        ;;
    tail)
        N="${1:-200}"
        ls -t "$PG_LOG_DIR"/postgresql-*.log 2>/dev/null | head -1 | xargs -I {} tail -n "$N" {}
        ;;
    help|*)
        sed -n '2,12p' "$0"
        ;;
esac
