#!/usr/bin/env bash
# agent_test.sh — the agent test (pgfr-v2-context-pack.md §1 invariant 2,
# §10.1 acceptance criterion 11)
#
# Operationalizes the record/analyze boundary: an AI agent with a pg_dump
# of pgfr_record alone, restored into an empty database on a DIFFERENT
# PostgreSQL major, using only psql, should be able to make progress on
# troubleshooting -- with presentation views regenerated OFFLINE from
# payload_schemas (no live source views on that major required), and
# using no pgfr_analyze object.
#
# Procedure:
#   1. Install pgfr_record on the source major; generate a little real
#      activity (a table with rows, a few tier captures, one deliberately
#      broken capture so the ledger has a non-ok row to find).
#   2. pg_dump --schema=pgfr_record --no-owner --no-privileges from the
#      source.
#   3. Restore into a fresh database on the target major (a different
#      major from the source -- older-to-newer is pg_dump/restore's
#      well-supported direction).
#   4. Drop every v_<short_name> presentation view on the target (leaving
#      the structural src_catalog_identity projection view alone -- it is
#      not something generate_presentation_views() is responsible for;
#      it is restored like any other object in the dump) and call
#      generate_presentation_views() to rebuild them from payload_schemas
#      alone.
#   5. Answer a fixed troubleshooting question set via plain psql: which
#      relation grew, what a backend was doing at a single captured_at
#      (the single-stamp join), when the recorder was blind (the
#      ledger), and what relation a captured OID resolves to.
#
# Usage: scripts/agent_test.sh [SOURCE_MAJOR] [TARGET_MAJOR]
#   Defaults: SOURCE_MAJOR=15 TARGET_MAJOR=17

set -euo pipefail

SOURCE_MAJOR="${1:-15}"
TARGET_MAJOR="${2:-17}"
RESTORE_DB="agent_restore"
COMPOSE_FILES="-f docker-compose.yml -f pgfr_record/docker-compose.yml -f pgfr_analyze/docker-compose.yml"

if command -v docker-compose &> /dev/null; then
    DC="docker-compose $COMPOSE_FILES"
else
    DC="docker compose $COMPOSE_FILES"
fi

SRC_SVC="postgres${SOURCE_MAJOR}"
TGT_SVC="postgres${TARGET_MAJOR}"
DUMP_FILE="$(mktemp -t agent_test_dump.XXXXXX.sql)"
trap 'rm -f "$DUMP_FILE"; $DC --profile "pg${SOURCE_MAJOR}" --profile "pg${TARGET_MAJOR}" down -v > /dev/null 2>&1 || true' EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log "Starting source (PG${SOURCE_MAJOR}) and target (PG${TARGET_MAJOR})..."
$DC --profile "pg${SOURCE_MAJOR}" --profile "pg${TARGET_MAJOR}" up -d "$SRC_SVC" "$TGT_SVC" > /dev/null
until $DC exec -T "$SRC_SVC" pg_isready -U postgres > /dev/null 2>&1 && \
      $DC exec -T "$TGT_SVC" pg_isready -U postgres > /dev/null 2>&1; do
    sleep 1
done

log "Installing pgfr_record on the source..."
$DC exec -T "$SRC_SVC" psql -U postgres -d postgres -c \
    "CREATE EXTENSION IF NOT EXISTS pg_cron; CREATE EXTENSION IF NOT EXISTS pg_stat_statements; CREATE EXTENSION IF NOT EXISTS pgtap;" \
    > /dev/null
$DC exec -T "$SRC_SVC" psql -U postgres -d postgres --single-transaction -f /pgfr_record/install.sql > /dev/null

log "Generating real activity: a table, several tier captures, one deliberately broken capture..."
$DC exec -T "$SRC_SVC" psql -U postgres -d postgres -c \
    "CREATE TABLE agent_test_target (id int); INSERT INTO agent_test_target SELECT generate_series(1,100);" > /dev/null
$DC exec -T "$SRC_SVC" psql -U postgres -d postgres -c "SELECT pgfr_record.run_tier('medium');" > /dev/null
$DC exec -T "$SRC_SVC" psql -U postgres -d postgres -c "SELECT pgfr_record.run_tier('on_change');" > /dev/null
$DC exec -T "$SRC_SVC" psql -U postgres -d postgres -c "SELECT pgfr_record.run_tier('fast');" > /dev/null
$DC exec -T "$SRC_SVC" psql -U postgres -d postgres -c \
    "UPDATE pgfr_record.capture_plan SET capture_select_sql = 'SELECT NULL::jsonb AS key, NULL::bigint AS key_hash, 1::bigint AS row_hash, jsonb_build_array(bogus_col) AS payload FROM pg_catalog.pg_stat_wal_receiver' WHERE source_view = 'pg_catalog.pg_stat_wal_receiver';" \
    > /dev/null
$DC exec -T "$SRC_SVC" psql -U postgres -d postgres -c "SELECT pgfr_record.run_tier('fast');" > /dev/null

TARGET_OID="$($DC exec -T "$SRC_SVC" psql -U postgres -d postgres -tAc "SELECT 'agent_test_target'::regclass::oid;")"
log "agent_test_target oid = $TARGET_OID"

log "Dumping pgfr_record schema from the source..."
$DC exec -T "$SRC_SVC" pg_dump -U postgres -d postgres --schema=pgfr_record --no-owner --no-privileges -Fp > "$DUMP_FILE"

log "Restoring into a fresh database on the target..."
$DC exec -T "$TGT_SVC" psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS $RESTORE_DB;" > /dev/null
$DC exec -T "$TGT_SVC" psql -U postgres -d postgres -c "CREATE DATABASE $RESTORE_DB;" > /dev/null
RESTORE_LOG="$(mktemp -t agent_test_restore.XXXXXX.log)"
$DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" < "$DUMP_FILE" > "$RESTORE_LOG" 2>&1
if grep -qi "error" "$RESTORE_LOG"; then
    echo "FAIL: restore produced errors:" >&2
    cat "$RESTORE_LOG" >&2
    exit 1
fi
rm -f "$RESTORE_LOG"
log "Restore clean, zero errors."

log "Dropping all v_<short_name> presentation views on the target, regenerating offline..."
$DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" -v ON_ERROR_STOP=1 -c "
DO \$\$
DECLARE v_v text;
BEGIN
    FOR v_v IN SELECT viewname FROM pg_views WHERE schemaname = 'pgfr_record' AND viewname LIKE 'v\_%' ESCAPE '\' LOOP
        EXECUTE format('DROP VIEW pgfr_record.%I', v_v);
    END LOOP;
END \$\$;
" > /dev/null
$DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" -v ON_ERROR_STOP=1 -c "SELECT pgfr_record.generate_presentation_views();" > /dev/null

VIEW_COUNT="$($DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" -tAc "SELECT count(*) FROM pg_views WHERE schemaname='pgfr_record' AND viewname LIKE 'v\_%' ESCAPE '\';")"
PROJECTION_SURVIVED="$($DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" -tAc "SELECT to_regclass('pgfr_record.src_catalog_identity') IS NOT NULL;")"
log "Regenerated $VIEW_COUNT presentation views offline; structural projection view survived: $PROJECTION_SURVIVED"
if [ "$PROJECTION_SURVIVED" != "t" ]; then
    echo "FAIL: pgfr_record.src_catalog_identity did not survive the restore" >&2
    exit 1
fi

log "Answering the fixed troubleshooting question set via plain psql, no pgfr_analyze object..."

ANALYZE_EXISTS="$($DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" -tAc "SELECT count(*) FROM pg_namespace WHERE nspname = 'pgfr_analyze';")"
if [ "$ANALYZE_EXISTS" != "0" ]; then
    echo "FAIL: pgfr_analyze schema exists in the restore (only pgfr_record was dumped)" >&2
    exit 1
fi

Q1="$($DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" -tAc "SELECT n_tup_ins FROM pgfr_record.v_pg_stat_all_tables WHERE relname = 'agent_test_target';")"
log "Q1 (which relation grew): agent_test_target n_tup_ins = $Q1"
[ "$Q1" = "100" ] || { echo "FAIL: expected n_tup_ins = 100, got $Q1" >&2; exit 1; }

Q2="$($DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" -tAc "SELECT count(*) FROM pgfr_record.v_pg_locks l JOIN pgfr_record.v_pg_stat_activity a ON a.captured_at = l.captured_at AND a.pid = l.pid;")"
log "Q2 (single-stamp lock/activity join): $Q2 joined rows"
[ "$Q2" -gt 0 ] || { echo "FAIL: expected the single-stamp pg_locks/pg_stat_activity join to return rows" >&2; exit 1; }

Q3="$($DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" -tAc "SELECT count(*) FROM pgfr_record.ledger_captures WHERE source_view = 'pg_catalog.pg_stat_wal_receiver' AND outcome = 'error';")"
log "Q3 (when was the recorder blind): $Q3 matching ledger error row(s)"
[ "$Q3" = "1" ] || { echo "FAIL: expected exactly 1 ledger error row for the deliberately broken capture, got $Q3" >&2; exit 1; }

Q4="$($DC exec -T "$TGT_SVC" psql -U postgres -d "$RESTORE_DB" -tAc "SELECT relname FROM pgfr_record.resolve_relation($TARGET_OID);")"
log "Q4 (resolve_relation($TARGET_OID)): $Q4"
[ "$Q4" = "agent_test_target" ] || { echo "FAIL: expected resolve_relation to identify agent_test_target, got '$Q4'" >&2; exit 1; }

log "PASS: the agent test succeeded end to end (source PG${SOURCE_MAJOR} -> target PG${TARGET_MAJOR})."
