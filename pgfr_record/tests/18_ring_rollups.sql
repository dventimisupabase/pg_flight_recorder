-- =============================================================================
-- pgfr_record pgTAP Tests — Ring Rollups ("get back our aggregates")
-- =============================================================================
-- Tests the durable wait/lock/activity rollup tables and the collector that
-- feeds them (_flush_ring_slot_to_rollups()), plus the end-to-end wiring into
-- rotate_ring() -- no separate cron job, no persisted flush watermark.
--
-- rotate_ring()'s cron job keeps sampling in the background for the whole
-- test run, so a slot can hold a mix of real and synthetic rows by the time
-- we read it back. Wait/lock assertions use a fake wait_event_type/wait_event
-- pair and an out-of-range locked_relation_oid that real sampling could never
-- produce, so exact-equality assertions stay valid regardless of real
-- background activity in the same slot. Activity assertions can't get that
-- same isolation (backend_type/state are a small, realistic vocabulary), so
-- they use >= lower-bound checks instead of exact equality.
-- =============================================================================

BEGIN;
SELECT plan(21);

-- -----------------------------------------------------------------------------
-- 1. Schema (9 tests)
-- -----------------------------------------------------------------------------

SELECT has_table('pgfr_record', 'wait_event_rollups_archive_v2',
    'wait_event_rollups_archive_v2 table exists');
SELECT has_table('pgfr_record', 'lock_rollups_archive_v2',
    'lock_rollups_archive_v2 table exists');
SELECT has_table('pgfr_record', 'activity_rollups_archive_v2',
    'activity_rollups_archive_v2 table exists');

SELECT is(
    (SELECT count(*)::int FROM pg_catalog.pg_partitioned_table pt
     JOIN pg_catalog.pg_class c ON c.oid = pt.partrelid
     JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgfr_record'
       AND c.relname IN ('wait_event_rollups_archive_v2', 'lock_rollups_archive_v2',
                          'activity_rollups_archive_v2')
       AND pt.partstrat = 'r'),
    3,
    'all three rollup tables are RANGE-partitioned'
);

-- Naming: all three end in _archive_v2, which is what buys them
-- retention_archive_days-tier retention from _partition_inventory() with no
-- new shared infrastructure (see 11_ring_rollups.sql header comment).
SELECT ok(
    'wait_event_rollups_archive_v2' LIKE '%_archive_v2'
    AND 'lock_rollups_archive_v2' LIKE '%_archive_v2'
    AND 'activity_rollups_archive_v2' LIKE '%_archive_v2',
    'rollup table names match the _archive_v2 pattern _partition_inventory() uses for the archive tier'
);

SELECT has_column('pgfr_record', 'wait_event_rollups_archive_v2', 'pct_of_samples',
    'wait_event_rollups_archive_v2: pct_of_samples column exists');
SELECT has_column('pgfr_record', 'lock_rollups_archive_v2', 'locked_relation_oid',
    'lock_rollups_archive_v2: locked_relation_oid column exists');
SELECT has_column('pgfr_record', 'activity_rollups_archive_v2', 'duration_bucket',
    'activity_rollups_archive_v2: duration_bucket column exists');

SELECT has_function('pgfr_record', '_flush_ring_slot_to_rollups',
    '_flush_ring_slot_to_rollups(smallint) exists');

-- -----------------------------------------------------------------------------
-- 2. Empty slot is a no-op (2 tests). Slot 99 is never a real, populated ring
--    slot (num_slots is single-digit in practice), so it cleanly exercises the
--    "nothing to roll up" branch.
-- -----------------------------------------------------------------------------

SELECT lives_ok($$SELECT pgfr_record._flush_ring_slot_to_rollups(99::smallint)$$,
    '_flush_ring_slot_to_rollups() on an empty slot does not raise');

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.wait_event_rollups_archive_v2
     WHERE wait_event_type = '__pgfr_test_empty__'),
    0,
    '_flush_ring_slot_to_rollups() on an empty slot inserts nothing'
);

-- -----------------------------------------------------------------------------
-- 3. Standalone rollup correctness on slot 0, using synthetic ring data
--    (7 tests): wait aggregation across ticks, lock duration aggregation,
--    and activity duration-bucket assignment.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_wait_id smallint;
    v_lock_type_id smallint;
    v_captured_at timestamptz;
BEGIN
    v_wait_id := pgfr_record._register_wait('active', '__pgfr_test__', '__wait_a__');
    SELECT id INTO v_lock_type_id FROM pgfr_record.lock_type_map WHERE lock_type = 'relation';

    -- wait_samples: same (fake) wait event across two ticks -> one grouped
    -- rollup row, isolated from any real background sampling by construction.
    INSERT INTO pgfr_record.wait_samples_0 (sample_ts, datid, active_count, data, slot)
    VALUES
        (500000, 0, 3, ARRAY[-v_wait_id, 3, 0], 0),
        (500060, 0, 5, ARRAY[-v_wait_id, 5, 0], 0);

    -- lock_samples: real lock_type, but an out-of-range relation oid that
    -- real lock contention in a test container could never target.
    INSERT INTO pgfr_record.lock_samples_0
        (sample_ts, blocked_pid, blocking_pid, lock_type, locked_relation_oid, blocked_duration_s, slot)
    VALUES
        (500000, 101, 102, v_lock_type_id, 999999999, 5, 0),
        (500060, 103, 102, v_lock_type_id, 999999999, 15, 0);

    -- activity_samples: three sessions, three different running durations at
    -- sample time -> three distinct duration_bucket rows. backend_type/state
    -- are real values (no fake-vocabulary escape hatch here), so assertions
    -- below use >= lower bounds rather than exact equality.
    v_captured_at := pgfr_record.epoch() + 500000 * interval '1 second';
    INSERT INTO pgfr_record.activity_samples_0
        (sample_ts, pid, backend_type, state, query_start, slot)
    VALUES
        (500000, 201, 'client backend', 'active', v_captured_at - interval '0.5 seconds', 0),
        (500000, 202, 'client backend', 'active', v_captured_at - interval '5 seconds', 0),
        (500000, 203, 'client backend', 'active', v_captured_at - interval '30 seconds', 0);

    PERFORM pgfr_record._flush_ring_slot_to_rollups(0::smallint);
END $$;

SELECT is(
    (SELECT sample_count FROM pgfr_record.wait_event_rollups_archive_v2
     WHERE wait_event_type = '__pgfr_test__' AND wait_event = '__wait_a__'),
    2,
    'wait rollup: sample_count counts distinct ticks in the slot'
);
SELECT is(
    (SELECT total_waiters FROM pgfr_record.wait_event_rollups_archive_v2
     WHERE wait_event_type = '__pgfr_test__' AND wait_event = '__wait_a__'),
    8::bigint,
    'wait rollup: total_waiters sums across ticks (3 + 5)'
);
SELECT is(
    (SELECT max_waiters FROM pgfr_record.wait_event_rollups_archive_v2
     WHERE wait_event_type = '__pgfr_test__' AND wait_event = '__wait_a__'),
    5,
    'wait rollup: max_waiters is the peak across ticks'
);

SELECT is(
    (SELECT occurrence_count FROM pgfr_record.lock_rollups_archive_v2
     WHERE locked_relation_oid = 999999999::oid),
    2,
    'lock rollup: occurrence_count counts rows grouped by (lock_type, relation)'
);
SELECT is(
    (SELECT max_duration FROM pgfr_record.lock_rollups_archive_v2
     WHERE locked_relation_oid = 999999999::oid),
    interval '15 seconds',
    'lock rollup: max_duration is the peak blocked_duration_s'
);

SELECT ok(
    (SELECT occurrence_count FROM pgfr_record.activity_rollups_archive_v2
     WHERE backend_type = 'client backend' AND state = 'active'
       AND duration_bucket = '<1s') >= 1,
    'activity rollup: a 0.5s-running session buckets as <1s'
);
SELECT ok(
    (SELECT occurrence_count FROM pgfr_record.activity_rollups_archive_v2
     WHERE backend_type = 'client backend' AND state = 'active'
       AND duration_bucket = '1s-10s') >= 1,
    'activity rollup: a 5s-running session buckets as 1s-10s'
);

-- Clean up slot 0's synthetic ring data so it doesn't leak into the
-- integration test below, which may target any slot including 0.
DELETE FROM pgfr_record.wait_samples_0 WHERE sample_ts IN (500000, 500060);
DELETE FROM pgfr_record.lock_samples_0 WHERE sample_ts IN (500000, 500060);
DELETE FROM pgfr_record.activity_samples_0 WHERE sample_ts = 500000;

-- -----------------------------------------------------------------------------
-- 4. End-to-end: rotate_ring() rolls up the slot it's about to truncate, with
--    no separate cron job (3 tests). Mirrors the canary-row technique already
--    used by test_ring_rotation_activity.sql to identify the next
--    truncate-target slot deterministically. Uses another fake wait event so
--    the assertion is immune to real background sampling in the same slot.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_current smallint;
    v_num_slots smallint;
    v_truncate_slot smallint;
    v_wait_id smallint;
BEGIN
    SELECT current_slot, num_slots INTO v_current, v_num_slots
    FROM pgfr_record.ring_config WHERE singleton;

    v_truncate_slot := (v_current + 2) % v_num_slots;
    v_wait_id := pgfr_record._register_wait('active', '__pgfr_test__', '__rotate_canary__');

    EXECUTE format(
        'INSERT INTO pgfr_record.wait_samples_%s (sample_ts, datid, active_count, data, slot) '
        'VALUES (600000, 0, 1, ARRAY[%s, 1, 0], %s)',
        v_truncate_slot, -v_wait_id, v_truncate_slot
    );

    UPDATE pgfr_record.ring_config SET rotated_at = now() - interval '3 hours' WHERE singleton;
    PERFORM set_config('test.truncate_slot', v_truncate_slot::text, false);
END $$;

SELECT matches(
    pgfr_record.rotate_ring(),
    '^rotated',
    'rotate_ring() actually rotated (not skipped)'
);

SELECT is(
    (SELECT sample_count FROM pgfr_record.wait_event_rollups_archive_v2
     WHERE wait_event_type = '__pgfr_test__' AND wait_event = '__rotate_canary__'),
    1,
    'rotate_ring() rolled up the truncated slot before truncating it (no separate cron job)'
);

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.wait_samples
     WHERE slot = current_setting('test.truncate_slot')::smallint
       AND sample_ts = 600000),
    0,
    'the truncated slot no longer holds the canary row after rotation'
);

SELECT * FROM finish();
ROLLBACK;
