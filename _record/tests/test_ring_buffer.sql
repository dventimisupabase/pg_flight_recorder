-- pgTAP tests for ring buffer v2 (N-partition TRUNCATE rotation)
-- Run after install.sql with pg_tap installed.
-- Usage:
--   PGPASSWORD=postgres psql -h localhost -p 5416 -U postgres -d postgres \
--       -f _record/tests/test_ring_buffer.sql

\set ON_ERROR_STOP 1
set client_min_messages to warning;

-- pgTAP setup
select plan(26);

-- -------------------------------------------------------------------------
-- 1. ring_config exists and has exactly 1 row
-- -------------------------------------------------------------------------
select has_table('pgfr_record', 'ring_config',
    'ring_config table exists');

select is(
    (select count(*)::int from pgfr_record.ring_config),
    1,
    'ring_config has exactly 1 row (singleton)'
);

-- -------------------------------------------------------------------------
-- 2. wait_samples exists and is partitioned by LIST
-- -------------------------------------------------------------------------
select has_table('pgfr_record', 'wait_samples',
    'wait_samples table exists');

select is(
    (select partstrat::text
     from pg_partitioned_table pt
     join pg_class c on c.oid = pt.partrelid
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'pgfr_record' and c.relname = 'wait_samples'),
    'l',
    'wait_samples is partitioned by LIST'
);

-- -------------------------------------------------------------------------
-- 3. wait_samples_0 exists as a partition
-- -------------------------------------------------------------------------
select has_table('pgfr_record', 'wait_samples_0',
    'wait_samples_0 partition exists');

select is(
    (select count(*)::int
     from pg_inherits i
     join pg_class parent on parent.oid = i.inhparent
     join pg_class child  on child.oid  = i.inhrelid
     join pg_namespace n  on n.oid = parent.relnamespace
     where n.nspname = 'pgfr_record'
       and parent.relname = 'wait_samples'
       and child.relname  = 'wait_samples_0'),
    1,
    'wait_samples_0 is a partition of wait_samples'
);

-- -------------------------------------------------------------------------
-- 4. lock_samples exists and is partitioned
-- -------------------------------------------------------------------------
select has_table('pgfr_record', 'lock_samples',
    'lock_samples table exists');

select is(
    (select partstrat::text
     from pg_partitioned_table pt
     join pg_class c on c.oid = pt.partrelid
     join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'pgfr_record' and c.relname = 'lock_samples'),
    'l',
    'lock_samples is partitioned by LIST'
);

-- -------------------------------------------------------------------------
-- 5. query_map_0 exists
-- -------------------------------------------------------------------------
select has_table('pgfr_record', 'query_map_0',
    'query_map_0 table exists');

-- -------------------------------------------------------------------------
-- 6. query_map_all view exists
-- -------------------------------------------------------------------------
select has_view('pgfr_record', 'query_map_all',
    'query_map_all view exists');

select is(
    (select count(*)::int from pgfr_record.query_map_all),
    0,
    'query_map_all is queryable and empty initially'
);

-- -------------------------------------------------------------------------
-- 7. wait_event_map exists and is empty initially
-- -------------------------------------------------------------------------
select has_table('pgfr_record', 'wait_event_map',
    'wait_event_map table exists');

-- (may already have entries if sample_ring() ran; just verify queryable)
select ok(
    (select count(*) from pgfr_record.wait_event_map) >= 0,
    'wait_event_map is queryable'
);

-- -------------------------------------------------------------------------
-- 8. _register_wait() returns a smallint id and is idempotent
-- -------------------------------------------------------------------------
select isnt(
    pgfr_record._register_wait('active', 'Lock', 'relation'),
    null,
    '_register_wait returns non-null id'
);

select is(
    pgfr_record._register_wait('active', 'Lock', 'relation'),
    pgfr_record._register_wait('active', 'Lock', 'relation'),
    '_register_wait is idempotent (same input → same id)'
);

select is(
    pg_typeof(pgfr_record._register_wait('active', 'CPU*', 'CPU*')),
    'smallint'::regtype,
    '_register_wait returns smallint'
);

-- -------------------------------------------------------------------------
-- 9. ring_current_slot() returns a valid slot number
-- -------------------------------------------------------------------------
select ok(
    pgfr_record.ring_current_slot() between 0 and 32767,
    'ring_current_slot() returns a non-negative smallint'
);

select ok(
    pgfr_record.ring_current_slot() < (select num_slots from pgfr_record.ring_config where singleton),
    'ring_current_slot() < num_slots'
);

-- -------------------------------------------------------------------------
-- 10. rotate_ring() returns text starting with 'skipped' or 'rotated'
-- -------------------------------------------------------------------------
select matches(
    pgfr_record.rotate_ring(),
    '^(skipped|rotated)',
    'rotate_ring() returns text starting with skipped or rotated'
);

-- -------------------------------------------------------------------------
-- 11. rotate_ring() is idempotent (second call within period = 'skipped')
-- -------------------------------------------------------------------------
do $$
declare
    v_result text;
begin
    -- force a fresh rotation by backdating rotated_at
    update pgfr_record.ring_config
    set rotated_at = now() - interval '3 hours'
    where singleton;

    -- first call should rotate
    perform pgfr_record.rotate_ring();

    -- second call immediately after should be skipped
    v_result := pgfr_record.rotate_ring();
    if v_result not like 'skipped%' then
        raise exception 'Expected skipped but got: %', v_result;
    end if;

    -- restore rotated_at to something reasonable
    update pgfr_record.ring_config
    set rotated_at = now()
    where singleton;
end $$;

select ok(true, 'rotate_ring() second call within period returns skipped (verified in DO block)');

-- -------------------------------------------------------------------------
-- 12. After INSERT into wait_samples, the inserted slot is a valid ring slot
-- -------------------------------------------------------------------------
do $$
declare
    v_slot smallint;
    v_wid  smallint;
    v_num  smallint;
begin
    v_slot := pgfr_record.ring_current_slot();
    v_num  := (select num_slots from pgfr_record.ring_config where singleton);
    v_wid  := pgfr_record._register_wait('active', 'IPC', 'BgWorkerShutdown');

    -- insert a minimal valid row (data[1] < 0, length >= 3) at captured slot
    insert into pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
    values (1, 0::oid, 1, array[-v_wid::integer, 1, 0], v_slot);

    -- verify inline: slot must be in valid range
    if v_slot < 0 or v_slot >= v_num then
        raise exception 'inserted slot % out of range [0, %)', v_slot, v_num;
    end if;
    -- verify the row exists
    if not exists (
        select from pgfr_record.wait_samples
        where slot = v_slot and sample_ts = 1 and active_count = 1
    ) then
        raise exception 'inserted row not found in wait_samples (slot=%, sample_ts=1)', v_slot;
    end if;
end $$;

select ok(
    exists(select from pgfr_record.wait_samples where sample_ts = 1),
    'wait_samples contains the test-inserted row with sample_ts=1'
);

-- -------------------------------------------------------------------------
-- 13. recent_waits_v2 view exists and is queryable
-- -------------------------------------------------------------------------
select has_view('pgfr_record', 'recent_waits_v2',
    'recent_waits_v2 view exists');

select ok(
    (select count(*) from pgfr_record.recent_waits_v2) >= 0,
    'recent_waits_v2 is queryable'
);

-- -------------------------------------------------------------------------
-- 14. recent_waits_v2 decodes the test row correctly
-- -------------------------------------------------------------------------
select ok(
    exists(
        select 1 from pgfr_record.recent_waits_v2
        where wait_event_type = 'IPC'
          and wait_event = 'BgWorkerShutdown'
    ),
    'recent_waits_v2 decodes IPC:BgWorkerShutdown from the test row'
);

-- -------------------------------------------------------------------------
-- 15. ring_config has sane defaults
-- -------------------------------------------------------------------------
select ok(
    (select num_slots from pgfr_record.ring_config where singleton) >= 3,
    'ring_config.num_slots >= 3 (minimum)'
);

select ok(
    (select rotation_period from pgfr_record.ring_config where singleton) >= interval '1 minute',
    'ring_config.rotation_period is at least 1 minute'
);

-- -------------------------------------------------------------------------
-- Finish
-- -------------------------------------------------------------------------
select * from finish();
