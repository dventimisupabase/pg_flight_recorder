#!/usr/bin/env bash
# run_bloat_demo.sh — Automated old-schema UPDATE bloat demo
#
# Creates the old ring tables, runs UPDATE churn in three phases:
#   Phase 0: baseline (no long tx, vacuum free)
#   Phase 1: 200 ticks with a long-running tx pinning the xmin horizon
#   Phase 2: kill the blocker, run VACUUM, show recovery
#
# Usage:
#   bash scripts/run_bloat_demo.sh [DOCKER_CONTAINER] [DB]
#
# Examples:
#   bash scripts/run_bloat_demo.sh pgfr_record_test-17 pgfr_bench
#   bash scripts/run_bloat_demo.sh                          # uses defaults

set -euo pipefail

CONTAINER="${1:-pgfr_record_test-17}"
DB="${2:-pgfr_bench}"
PSQL="docker exec -i ${CONTAINER} psql -U postgres -d ${DB}"

echo "=== pg_flight_recorder: Old-schema UPDATE bloat demo ==="
echo "Container : ${CONTAINER}"
echo "Database  : ${DB}"
echo ""

# ── Setup ────────────────────────────────────────────────────────────────────

echo "--- Setting up schema and tables..."
$PSQL <<'SQL'
drop schema if exists pgfr_bloat_demo cascade;
create schema pgfr_bloat_demo;

create unlogged table pgfr_bloat_demo.samples_ring (
    slot_id      integer primary key check (slot_id >= 0 and slot_id < 120),
    captured_at  timestamptz not null default now(),
    epoch_secs   bigint not null default 0
) with (fillfactor = 70);

create unlogged table pgfr_bloat_demo.wait_samples_ring (
    slot_id          integer references pgfr_bloat_demo.samples_ring(slot_id) on delete cascade,
    row_num          integer not null check (row_num >= 0 and row_num < 100),
    wait_event_type  text,
    wait_event       text,
    state            text,
    count            integer,
    primary key (slot_id, row_num)
) with (fillfactor = 90);

-- Pre-populate: 120 slots × 100 rows = 12,000 rows
insert into pgfr_bloat_demo.samples_ring (slot_id, captured_at, epoch_secs)
select g, now(), 0 from generate_series(0, 119) as g;

insert into pgfr_bloat_demo.wait_samples_ring (slot_id, row_num)
select s, r
from generate_series(0, 119) as s
cross join generate_series(0, 99) as r;

-- Also create pgstattuple extension if available (best-effort)
create extension if not exists pgstattuple;
SQL

echo ""

# ── Phase 0: baseline without long tx ────────────────────────────────────────

echo "--- Phase 0: 60 ticks, vacuum free (no long tx)"
$PSQL <<'SQL'
do $$
declare v_slot int; v_tick int;
begin
    for v_tick in 1..60 loop
        v_slot := v_tick % 120;
        update pgfr_bloat_demo.samples_ring
            set captured_at = now(), epoch_secs = extract(epoch from now())
            where slot_id = v_slot;
        update pgfr_bloat_demo.wait_samples_ring
            set wait_event_type = null, wait_event = null, state = null, count = null
            where slot_id = v_slot;
        update pgfr_bloat_demo.wait_samples_ring
            set wait_event_type = (array['Lock','LWLock','IO','Client'])[1 + (row_num % 4)],
                wait_event = 'Event' || row_num::text,
                state = 'active',
                count = 1 + (random() * 10)::int
            where slot_id = v_slot and row_num < 20;
    end loop;
end;
$$;
vacuum analyze pgfr_bloat_demo.wait_samples_ring;
SQL

echo "Phase 0 sizes (after 60 ticks + VACUUM):"
$PSQL -c "
select relname,
       n_live_tup as live,
       n_dead_tup as dead,
       pg_size_pretty(pg_relation_size(relid)) as heap
from pg_stat_user_tables
where schemaname = 'pgfr_bloat_demo'
order by pg_total_relation_size(relid) desc;"

echo ""

# ── Phase 1: open long-running tx in background, then run churn ──────────────

echo "--- Phase 1: Opening long-running tx in background (horizon pinned)..."

# Start background psql that opens a transaction and sleeps indefinitely
docker exec -d "${CONTAINER}" bash -c "
    psql -U postgres -d ${DB} -c \"
        begin;
        select 'long tx open', pg_backend_pid(), txid_current();
        select pg_sleep(300);
    \" 2>/dev/null
" &
BLOCKER_BGPID=$!

# Give it a moment to open the tx
sleep 2

# Confirm the long tx is visible
echo "Long-running transactions visible:"
$PSQL -c "
select pid,
       backend_xmin,
       round(extract(epoch from (now() - xact_start))::numeric, 1) as age_s,
       left(query, 50) as query
from pg_stat_activity
where backend_xmin is not null
  and query not like '%pg_stat_activity%'
order by xact_start nulls last
limit 5;"

echo ""
echo "--- Running 200 UPDATE ticks (autovacuum cannot reclaim dead tuples)..."

$PSQL <<'SQL'
do $$
declare v_slot int; v_tick int;
begin
    for v_tick in 1..200 loop
        v_slot := v_tick % 120;
        update pgfr_bloat_demo.samples_ring
            set captured_at = now(), epoch_secs = extract(epoch from now())
            where slot_id = v_slot;
        update pgfr_bloat_demo.wait_samples_ring
            set wait_event_type = null, wait_event = null, state = null, count = null
            where slot_id = v_slot;
        update pgfr_bloat_demo.wait_samples_ring
            set wait_event_type = (array['Lock','LWLock','IO','Client'])[1 + (row_num % 4)],
                wait_event = 'Event' || row_num::text,
                state = 'active',
                count = 1 + (random() * 10)::int
            where slot_id = v_slot and row_num < 20;
    end loop;
end;
$$;
-- VACUUM will run but cannot reclaim (horizon pinned)
vacuum pgfr_bloat_demo.wait_samples_ring;
SQL

echo ""
echo "Phase 1 sizes (200 ticks + VACUUM, long tx STILL OPEN):"
$PSQL -c "
select relname,
       n_live_tup as live,
       n_dead_tup as dead,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) as dead_pct,
       pg_size_pretty(pg_relation_size(relid)) as heap,
       case when n_live_tup > 0
            then pg_relation_size(relid) / n_live_tup
       end as bytes_per_live_row
from pg_stat_user_tables
where schemaname = 'pgfr_bloat_demo'
order by pg_total_relation_size(relid) desc;"

echo ""

# pgstattuple for physical bloat estimate
echo "pgstattuple physical bloat estimate:"
$PSQL -c "
select dead_tuple_count,
       dead_tuple_len,
       pg_size_pretty(dead_tuple_len::bigint) as dead_tuple_size,
       round(dead_tuple_percent::numeric, 1) as dead_pct,
       pg_size_pretty(free_space::bigint) as free_space
from pgstattuple('pgfr_bloat_demo.wait_samples_ring');" 2>/dev/null \
|| echo "(pgstattuple not available — install with CREATE EXTENSION pgstattuple)"

echo ""

# ── Phase 2: kill the long tx, vacuum, show recovery ─────────────────────────

echo "--- Phase 2: Terminating long-running tx (releasing horizon)..."

$PSQL -c "
select pg_terminate_backend(pid)
from pg_stat_activity
where backend_xmin is not null
  and query like '%pg_sleep%'
  and pid <> pg_backend_pid();" 2>/dev/null || true

kill "${BLOCKER_BGPID}" 2>/dev/null || true
sleep 1

echo "Running VACUUM after horizon released..."
$PSQL -c "vacuum pgfr_bloat_demo.wait_samples_ring;"

echo ""
echo "Phase 2 sizes (after horizon released + VACUUM):"
$PSQL -c "
select relname,
       n_live_tup as live,
       n_dead_tup as dead,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) as dead_pct,
       pg_size_pretty(pg_relation_size(relid)) as heap,
       case when n_live_tup > 0
            then pg_relation_size(relid) / n_live_tup
       end as bytes_per_live_row
from pg_stat_user_tables
where schemaname = 'pgfr_bloat_demo'
order by pg_total_relation_size(relid) desc;"

echo ""
echo "=== Summary ==="
echo "The old UPDATE pattern accumulates dead tuples proportional to tick rate."
echo "A single long-running transaction (reporting query, idle-in-transaction"
echo "session, logical replication slot) pins the xmin horizon and prevents VACUUM"
echo "from reclaiming them — indefinitely."
echo ""
echo "The v2 INSERT+TRUNCATE pattern has zero dead tuples: TRUNCATE drops the"
echo "entire partition page-by-page, bypassing MVCC dead tuple accumulation."
echo ""
