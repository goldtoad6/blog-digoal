#!/usr/bin/env bash
# run_repro.sh — execute a .sql repro file against the running instance,
# capture stdout, then dump the most recent ERROR/FATAL/PANIC/WARNING
# lines from the server log.
#
# Usage: ./run_repro.sh <file.sql> [label]
#
# Returns non-zero if psql returned non-zero OR if any ERROR/FATAL/PANIC
# appeared in the log during/after the run. This is intentional: a
# successful run means "no bug observed on this input".

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pg_env.sh
source "$HERE/pg_env.sh"

SQL="${1:?usage: run_repro.sh <file.sql> [label]}"
LABEL="${2:-$(basename "$SQL" .sql)}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$PGDATA/repro-${LABEL}-${STAMP}.log"

if [ ! -f "$SQL" ]; then
  echo "run_repro: $SQL not found" >&2
  exit 2
fi

# Mark the log so we know where this run starts.
LOG_MARK="REPRO_START_${LABEL}_${STAMP}"
echo "==> $LOG_MARK"
echo "$LOG_MARK" >> "$PG_LOG"

echo "==> psql $SQL  →  $OUT"
set +e
psql -h "$PG_SOCK_DIR" -p "$PG_PORT" -U "$PG_USER" -d postgres -X -e \
     -v ON_ERROR_STOP=0 -f "$SQL" 2>&1 | tee "$OUT"
PSQL_RC=$?
set -e

# Append mark so we can scope log capture
END_MARK="REPRO_END_${LABEL}_${STAMP}"
echo "$END_MARK" >> "$PG_LOG"

echo
echo "=== server log slice for this run ==="
awk -v start="$LOG_MARK" -v end="$END_MARK" \
  'index($0, start) {p=1; next} index($0, end) {p=0} p' \
  "$PG_LOG" 2>/dev/null | grep -E '^(ERROR|FATAL|PANIC|WARNING|STATEMENT|LOG:)' | tail -80 \
  || true

if [ "$PSQL_RC" -ne 0 ]; then
  echo
  echo "psql returned $PSQL_RC"
  exit "$PSQL_RC"
fi
