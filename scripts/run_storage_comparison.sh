#!/usr/bin/env bash
# run_storage_comparison.sh — Old ring (UPDATE) vs New ring v2 (INSERT+TRUNCATE)
#
# Runs 3 scenarios side by side:
#   A) Old ring, baseline (no long tx)
#   B) Old ring with long-running tx pinning the xmin horizon
#   C) New ring v2, same tick count (shows zero dead tuples, instant reclaim)
#
# Usage:
#   bash scripts/run_storage_comparison.sh [CONTAINER] [DB]
#
# Example:
#   bash scripts/run_storage_comparison.sh pgfr_record_test-17 pgfr_bench

set -euo pipefail

CONTAINER="${1:-pgfr_record_test-17}"
DB="${2:-pgfr_bench}"
PSQL="docker exec -i ${CONTAINER} psql -U postgres -d ${DB}"
TICKS=10000

echo "=== pg_flight_recorder: Storage Comparison ==="
echo "Container : ${CONTAINER}"
echo "Database  : ${DB}"
echo "Ticks     : ${TICKS}"
echo ""

# ── Teardown any prior run ─────────────────────────────────────────────────

$PSQL <<'SQL' 2>/dev/null || true
drop schema if exists pgfr_bloat_demo cascade;
SQL

# ── Setup old ring schema ──────────────────────────────────────────────────

echo "--- Creating old ring schema (pre-populated)..."
$PSQL <<SQL
create schema pgfr_bloat_demo;

-- Old ring: fixed 120 slots × 100 rows (UPDATE-based)
create unlogged table pgfr_bloat_demo.samples_ring (
    slot_id      integer primary key check (slot_id >= 0 and slot_id < 120),
    captured_at  timestamptz not null default now(),
    epoch_secs   bigint not null default 0
) with (fillfactor = 70);

create unlogged table pgfr_bloat_demo.wait_samples_ring (
    slot_id          integer references pgfr_bloat_demo.samples_ring(slot_id) on delete cascade,
    row_num          integer not null check (row_num >= 0 and row_num < 1000),
    wait_event_type  text,
    wait_event       text,
    state            text,
    count            integer,
    primary key (slot_id, row_num)
) with (fillfactor = 90);

-- Pre-populate: 120 × 100 = 12,000 rows
insert into pgfr_bloat_demo.samples_ring (slot_id, captured_at, epoch_secs)
select g, now(), 0 from generate_series(0, 119) as g;

insert into pgfr_bloat_demo.wait_samples_ring (slot_id, row_num)
select s, r
from generate_series(0, 119) as s
cross join generate_series(0, 999) as r;

create extension if not exists pgstattuple;

-- New ring v2: 3-slot INSERT+TRUNCATE
create schema pgfr_demo_v2;

create unlogged table pgfr_demo_v2.wait_samples_0 (
    captured_at   timestamptz not null default now(),
    db_name       text,
    wait_event    text,
    state         text,
    count         integer
);
create unlogged table pgfr_demo_v2.wait_samples_1 (like pgfr_demo_v2.wait_samples_0);
create unlogged table pgfr_demo_v2.wait_samples_2 (like pgfr_demo_v2.wait_samples_0);

-- Slot pointer
create table pgfr_demo_v2.ring_state (
    current_slot integer not null default 0
);
insert into pgfr_demo_v2.ring_state values (0);
SQL

echo "Done."
echo ""

# ── Helper: size snapshot ──────────────────────────────────────────────────

show_old_sizes() {
    local label="$1"
    echo "--- Sizes: ${label}"
    $PSQL <<'SQL'
select
    relname,
    n_live_tup                                              as live,
    n_dead_tup                                              as dead,
    round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) as dead_pct,
    pg_size_pretty(pg_relation_size(relid))                 as heap
from pg_stat_user_tables
where schemaname = 'pgfr_bloat_demo'
order by relname;
SQL
    echo ""
}

show_v2_sizes() {
    local label="$1"
    echo "--- Sizes (v2): ${label}"
    $PSQL <<'SQL'
select
    relname,
    n_live_tup                                              as live,
    n_dead_tup                                              as dead,
    pg_size_pretty(pg_relation_size(relid))                 as heap
from pg_stat_user_tables
where schemaname = 'pgfr_demo_v2'
order by relname;
SQL
    echo ""
}

# ── Scenario A: Old ring, no long tx ──────────────────────────────────────

echo "=== Scenario A: Old ring, ${TICKS} ticks, no long tx ==="
$PSQL <<SQL
do \$\$
declare v_slot int; v_tick int;
begin
    for v_tick in 1..${TICKS} loop
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
            where slot_id = v_slot and row_num < 1000;
    end loop;
end;
\$\$;
vacuum analyze pgfr_bloat_demo.wait_samples_ring;
SQL
show_old_sizes "after ${TICKS} ticks + VACUUM (no long tx)"

echo "pgstattuple (old, scenario A):"
$PSQL -c "
select dead_tuple_count,
       pg_size_pretty(dead_tuple_len::bigint) as dead_size,
       round(dead_tuple_percent::numeric, 1)  as dead_pct,
       pg_size_pretty(free_space::bigint)     as free_space
from pgstattuple('pgfr_bloat_demo.wait_samples_ring');" 2>/dev/null || echo "(pgstattuple unavailable)"
echo ""

# ── Reset for Scenario B ───────────────────────────────────────────────────

echo "--- Resetting old ring tables for Scenario B..."
$PSQL <<'SQL'
truncate pgfr_bloat_demo.wait_samples_ring;
truncate pgfr_bloat_demo.samples_ring cascade;
insert into pgfr_bloat_demo.samples_ring (slot_id, captured_at, epoch_secs)
select g, now(), 0 from generate_series(0, 119) as g;
insert into pgfr_bloat_demo.wait_samples_ring (slot_id, row_num)
select s, r
from generate_series(0, 119) as s
cross join generate_series(0, 999) as r;
-- ensure stats are fresh
vacuum analyze pgfr_bloat_demo.wait_samples_ring;
SQL

# ── Scenario B: Old ring with long-running tx ─────────────────────────────

echo ""
echo "=== Scenario B: Old ring, ${TICKS} ticks, long tx pins horizon ==="

# Open background long tx
docker exec -d "${CONTAINER}" bash -c "
    psql -U postgres -d ${DB} -c \"begin; select pg_sleep(400);\" >/dev/null 2>&1
" || true
sleep 2

echo "Horizon-pinning transactions visible:"
$PSQL -c "
select pid,
       backend_xmin,
       round(extract(epoch from (now() - xact_start))::numeric, 1) as age_s,
       left(query, 40) as query
from pg_stat_activity
where backend_xmin is not null
  and pid <> pg_backend_pid()
order by xact_start nulls last
limit 5;" 2>/dev/null || echo "(none visible)"
echo ""

$PSQL <<SQL
do \$\$
declare v_slot int; v_tick int;
begin
    for v_tick in 1..${TICKS} loop
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
            where slot_id = v_slot and row_num < 1000;
    end loop;
end;
\$\$;
vacuum pgfr_bloat_demo.wait_samples_ring;
SQL

show_old_sizes "after ${TICKS} ticks + VACUUM (long tx ACTIVE)"

echo "pgstattuple (old, scenario B — long tx):"
$PSQL -c "
select dead_tuple_count,
       pg_size_pretty(dead_tuple_len::bigint) as dead_size,
       round(dead_tuple_percent::numeric, 1)  as dead_pct,
       pg_size_pretty(free_space::bigint)     as free_space
from pgstattuple('pgfr_bloat_demo.wait_samples_ring');" 2>/dev/null || echo "(pgstattuple unavailable)"
echo ""

# Kill the long tx
$PSQL -c "
select pg_terminate_backend(pid)
from pg_stat_activity
where backend_xmin is not null
  and query like '%pg_sleep%'
  and pid <> pg_backend_pid();" 2>/dev/null || true

# ── Scenario C: New ring v2 ────────────────────────────────────────────────

echo ""
echo "=== Scenario C: New ring v2 (INSERT+TRUNCATE), ${TICKS} ticks ==="
echo "--- Also with long-running tx open (shows it makes no difference)"

# Open another long tx to prove v2 is immune
docker exec -d "${CONTAINER}" bash -c "
    psql -U postgres -d ${DB} -c \"begin; select pg_sleep(400);\" >/dev/null 2>&1
" || true
sleep 2

echo "Horizon-pinning tx:"
$PSQL -c "
select pid, backend_xmin,
       round(extract(epoch from (now() - xact_start))::numeric, 1) as age_s
from pg_stat_activity
where backend_xmin is not null and pid <> pg_backend_pid()
limit 3;" 2>/dev/null || echo "(none)"
echo ""

$PSQL <<ENDSQL
do \$\$
declare
    v_slot     int;
    v_tick     int;
    v_cur      int;
    v_truncate text;
begin
    for v_tick in 1..${TICKS} loop
        select current_slot into v_cur from pgfr_demo_v2.ring_state;

        v_slot := v_cur % 3;

        -- INSERT into current slot (sparse -- only actual data)
        execute format(
            'insert into pgfr_demo_v2.wait_samples_%s
                (captured_at, db_name, wait_event, state, count)
             select now(), current_database(),
                    (array[''Lock'',''LWLock'',''IO'',''Client''])[1 + (n %% 4)],
                    ''active'',
                    1 + (random() * 10)::int
             from generate_series(1, 800 + (random()*400)::int) as n',
            v_slot
        );

        -- Every 60 ticks: rotate -- truncate oldest slot
        if v_tick % 60 = 0 then
            v_truncate := format('pgfr_demo_v2.wait_samples_%s', (v_slot + 1) % 3);
            execute 'truncate ' || v_truncate;
            update pgfr_demo_v2.ring_state set current_slot = v_cur + 1;
            raise notice 'tick % -- rotated. Truncated %', v_tick, v_truncate;
        end if;
    end loop;
end;
\$\$;
ENDSQL

show_v2_sizes "after ${TICKS} ticks with long tx ACTIVE"

echo "pgstattuple (v2, scenario C — long tx open):"
$PSQL -c "
select dead_tuple_count,
       pg_size_pretty(dead_tuple_len::bigint) as dead_size,
       round(dead_tuple_percent::numeric, 1)  as dead_pct
from pgstattuple('pgfr_demo_v2.wait_samples_0');" 2>/dev/null || echo "(pgstattuple unavailable)"
echo ""

# Kill the long tx
$PSQL -c "
select pg_terminate_backend(pid)
from pg_stat_activity
where backend_xmin is not null and query like '%pg_sleep%' and pid <> pg_backend_pid();" 2>/dev/null || true

# ── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "=== Summary ==="
echo ""
echo "Old ring (after ${TICKS} ticks):"
$PSQL -c "
select relname,
       n_live_tup as live, n_dead_tup as dead,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) as dead_pct,
       pg_size_pretty(pg_relation_size(relid)) as heap
from pg_stat_user_tables where schemaname = 'pgfr_bloat_demo' order by relname;"
echo ""
echo "New ring v2 (after ${TICKS} ticks, includes rotations):"
$PSQL -c "
select relname,
       n_live_tup as live, n_dead_tup as dead,
       pg_size_pretty(pg_relation_size(relid)) as heap
from pg_stat_user_tables where schemaname = 'pgfr_demo_v2' order by relname;"

echo ""
echo "Key points:"
echo "  - Old ring: dead tuples proportional to UPDATE rate, VACUUM required"
echo "  - Old ring + long tx: VACUUM runs but cannot reclaim — bloat accumulates indefinitely"
echo "  - New ring v2: TRUNCATE bypasses MVCC entirely — long tx has zero effect on ring tables"
echo ""

# ── Cleanup ────────────────────────────────────────────────────────────────
$PSQL -c "drop schema pgfr_bloat_demo cascade; drop schema pgfr_demo_v2 cascade;" 2>/dev/null || true
echo "Cleanup done."
