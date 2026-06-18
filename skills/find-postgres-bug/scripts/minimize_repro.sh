#!/usr/bin/env bash
# minimize_repro.sh <input.sql> <pg_install> [data_dir]
# 把一个能复现 bug 的大脚本逐步缩到最小
# 用法:
#   1. 准备 reproduce.sh 调用 pg_instance.sh psql -f <file>
#   2. ./minimize_repro.sh big.sql
#   3. delta/delta-debug 风格的逐步删除
set -euo pipefail
SRC="${1:?usage: $0 <sql> [pg_install]}"
INSTALL="${2:-${PG_INSTALL:-}}"
DATA="${3:-${PG_DATA:-/tmp/pgbug_data}}"
PSQL="$INSTALL/bin/psql"

# split SQL on `;` boundaries
awk 'BEGIN{n=0} {print > sprintf("/tmp/repro_%04d.sql", n); if($0 ~ /;$/) n++}' "$SRC"

echo "split into $(ls /tmp/repro_*.sql | wc -l) chunks"
echo "请手动验证每个 chunk 单独跑是否能触发 bug"
echo "推荐流程:"
echo "  1. for i in \$(ls /tmp/repro_*.sql); do"
echo "       $PSQL -h 127.0.0.1 -p ${PG_PORT:-55432} -U \$USER -X -f \$i 2>&1 | tee -a /tmp/run.log"
echo "       grep -E 'PANIC|FATAL|ERROR' /tmp/run.log && break"
echo "     done"
echo "  2. 找到能触发的最小 chunk 序列"
echo "  3. 把这些 chunk 合并到 minimun_repro.sql 即为最小复现"
