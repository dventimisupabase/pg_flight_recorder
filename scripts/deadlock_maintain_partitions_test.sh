#!/usr/bin/env bash
# deadlock_maintain_partitions_test.sh — regression test for the lock-order
# inversion between maintain_partitions()'s create-ahead step and
# run_tier()'s ledger writes.
#
# maintain_partitions() (pgfr_record/sql/05_partition_infra.sql) creates
# partitions for every row of _partition_targets(), in that query's row
# order, issuing CREATE TABLE ... PARTITION OF (ACCESS EXCLUSIVE) for
# whichever targets need one this cycle. run_tier() (sql/08_collector.sql)
# writes the two ledger tables in the opposite order within one transaction:
# INSERT into ledger_captures across its whole loop (held from the first
# target), and only appends the single ledger_runs row at the very end.
#
# _partition_targets() lists ledger_runs before ledger_captures. If
# maintain_partitions() ever needs to CREATE TABLE PARTITION OF on BOTH
# ledger tables in the same cycle (true once per partition-width rollover —
# daily, since both carry a fixed 30-day retention) while a run_tier()
# transaction is concurrently open, the two lock orders form a cycle:
# maintain_partitions() holds ledger_runs and wants ledger_captures;
# run_tier() holds ledger_captures and wants ledger_runs. PostgreSQL's
# deadlock detector kills one of them with "deadlock detected".
#
# This cannot be exercised from a pgTAP file — one transaction per file, the
# same reason tests/13_acceptance.sql documents criterion 4 (induced
# lock_timeout from a second concurrent session) as a gap rather than
# silently skipping it. This is a genuine two-session shell harness, in the
# same spirit as scripts/agent_test.sh.
#
# Usage: scripts/deadlock_maintain_partitions_test.sh [PG_MAJOR]
#   Default: PG_MAJOR=17
#
# Exit 0: no deadlock (session B blocked behind session A and then
#         proceeded once A committed — correct behavior).
# Exit 1: a deadlock was observed — the bug reproduced.
# Exit 2: the harness itself could not reach the interleaving it needs.

set -uo pipefail

PG_MAJOR="${1:-17}"
SVC="postgres${PG_MAJOR}"
COMPOSE_FILES="-f docker-compose.yml -f pgfr_record/docker-compose.yml -f pgfr_analyze/docker-compose.yml"

if command -v docker-compose &> /dev/null; then
    DC="docker-compose $COMPOSE_FILES"
else
    DC="docker compose $COMPOSE_FILES"
fi

WORKDIR="$(mktemp -d -t pgfr_deadlock_test.XXXXXX)"
cleanup() {
    exec 3>&- 2>/dev/null || true
    exec 4>&- 2>/dev/null || true
    kill "${PID_A_WRAPPER:-}" "${PID_B_WRAPPER:-}" 2>/dev/null || true
    rm -rf "$WORKDIR"
    $DC --profile "pg${PG_MAJOR}" down -v > /dev/null 2>&1 || true
}
trap cleanup EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
psql_admin() { $DC exec -T "$SVC" psql -U postgres -d postgres -tAc "$1"; }

log "Starting PG${PG_MAJOR}..."
$DC --profile "pg${PG_MAJOR}" up -d "$SVC" > /dev/null
until $DC exec -T "$SVC" pg_isready -U postgres > /dev/null 2>&1; do sleep 1; done

log "Installing pgfr_record..."
$DC exec -T "$SVC" psql -U postgres -d postgres -c \
    "CREATE EXTENSION IF NOT EXISTS pg_cron; CREATE EXTENSION IF NOT EXISTS pg_stat_statements; CREATE EXTENSION IF NOT EXISTS pgtap;" \
    > /dev/null
$DC exec -T "$SVC" psql -U postgres -d postgres --single-transaction -f /pgfr_record/install.sql > /dev/null

log "Baseline maintain_partitions() run, to create today/tomorrow/+2d partitions cleanly..."
psql_admin "SELECT pgfr_record.maintain_partitions();" > /dev/null

log "Dropping the +2d partition of both ledger tables, so this cycle needs to recreate it (the real once-a-day rollover condition)..."
for TBL in ledger_runs ledger_captures; do
    CHILD="$(psql_admin "
        SELECT c.relname FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_class p ON p.oid = i.inhparent
        JOIN pg_namespace n ON n.oid = p.relnamespace
        WHERE n.nspname = 'pgfr_record' AND p.relname = '$TBL'
        ORDER BY c.relname DESC LIMIT 1;
    ")"
    log "  dropping pgfr_record.$CHILD"
    psql_admin "DROP TABLE pgfr_record.$CHILD;" > /dev/null
done

FIFO_A="$WORKDIR/fifo_a"; FIFO_B="$WORKDIR/fifo_b"
OUT_A="$WORKDIR/out_a.log"; OUT_B="$WORKDIR/out_b.log"
mkfifo "$FIFO_A" "$FIFO_B"

$DC exec -T "$SVC" psql -U postgres -d postgres < "$FIFO_A" > "$OUT_A" 2>&1 &
PID_A_WRAPPER=$!
$DC exec -T "$SVC" psql -U postgres -d postgres < "$FIFO_B" > "$OUT_B" 2>&1 &
PID_B_WRAPPER=$!

exec 3>"$FIFO_A"
exec 4>"$FIFO_B"

log "Session A: BEGIN + INSERT INTO ledger_captures (mirrors run_tier()'s per-target insert, held open)..."
echo "BEGIN;" >&3
echo "INSERT INTO pgfr_record.ledger_captures (run_id, source_view, outcome, captured_at) VALUES (999001, 'deadlock_test_probe', 'ok', now());" >&3

sleep 1
BACKEND_A="$(psql_admin "SELECT pid FROM pg_stat_activity WHERE query LIKE '%deadlock_test_probe%' AND state = 'idle in transaction';")"
if [ -z "$BACKEND_A" ]; then
    echo "FAIL: session A never reached idle-in-transaction holding the ledger_captures insert -- harness precondition not met." >&2
    exit 2
fi
log "Session A (pid=$BACKEND_A) holds its ledger_captures lock."

log "Session B: BEGIN + maintain_partitions() (needs both ledger tables' missing +2d partition this cycle)..."
echo "BEGIN;" >&4
echo "SELECT pgfr_record.maintain_partitions();" >&4

log "Waiting for session B to block on a lock..."
WAITING=""
for _ in $(seq 1 20); do
    WAITING="$(psql_admin "SELECT wait_event_type FROM pg_stat_activity WHERE query LIKE '%maintain_partitions%' AND state = 'active';")"
    [ "$WAITING" = "Lock" ] && break
    sleep 0.5
done
if [ "$WAITING" != "Lock" ]; then
    echo "FAIL: session B never blocked on a lock -- harness precondition not met (are both ledger tables' +2d partitions actually missing?)." >&2
    exit 2
fi
log "Session B is blocked waiting on a lock, as expected."

log "Session A: completing its transaction the way run_tier() does -- appending the final ledger_runs row, then COMMIT..."
echo "INSERT INTO pgfr_record.ledger_runs (run_id, tier, captured_at, finished_at) OVERRIDING SYSTEM VALUE VALUES (999001, 'deadlock_test_probe', now(), now());" >&3
echo "COMMIT;" >&3
echo "COMMIT;" >&4

sleep 3
exec 3>&-
exec 4>&-
wait "$PID_A_WRAPPER" 2>/dev/null
wait "$PID_B_WRAPPER" 2>/dev/null

if grep -qi "deadlock detected" "$OUT_A" "$OUT_B"; then
    echo "FAIL: deadlock detected -- maintain_partitions() and run_tier()-style ledger writes still take ledger_runs/ledger_captures in opposite orders." >&2
    echo "--- session A output ---" >&2; cat "$OUT_A" >&2
    echo "--- session B output ---" >&2; cat "$OUT_B" >&2
    exit 1
fi

log "PASS: no deadlock. Session B blocked behind session A and proceeded once A committed."
