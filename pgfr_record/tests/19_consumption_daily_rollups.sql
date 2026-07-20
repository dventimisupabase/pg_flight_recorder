-- =============================================================================
-- pgfr_record pgTAP Tests — Consumption Daily Rollups (Issue #83 prerequisite)
-- =============================================================================
-- Tests consumption_deltas (the split-out reset-guarded component view),
-- consumption_daily_rollups (the durable daily-grain table), and
-- _rollup_consumption_daily() (the idempotent, catch-up-capable populator
-- wired into the existing daily pgfr_cleanup cron job -- no new job).
--
-- Fixture data uses day-since-epoch offsets (100, 101) rather than real
-- calendar dates, and a private fake datname, so it can never collide with
-- real background sample_ring()/snapshot() activity running during the test
-- suite (same isolation technique as 17_consumption_sampler.sql and
-- 18_ring_rollups.sql).
-- =============================================================================

BEGIN;
SELECT plan(24);

-- -----------------------------------------------------------------------------
-- 1. Schema (7 tests)
-- -----------------------------------------------------------------------------

SELECT has_view('pgfr_record', 'consumption_deltas',
    'consumption_deltas view exists');
SELECT has_table('pgfr_record', 'consumption_daily_rollups',
    'consumption_daily_rollups table exists');
SELECT has_function('pgfr_record', '_rollup_consumption_daily',
    '_rollup_consumption_daily() exists');
SELECT has_column('pgfr_record', 'consumption_daily_rollups', 'total_seconds',
    'consumption_daily_rollups: total_seconds column exists');
SELECT has_column('pgfr_record', 'consumption_daily_rollups', 'valid_tick_count',
    'consumption_daily_rollups: valid_tick_count column exists');
SELECT has_column('pgfr_record', 'consumption_daily_rollups', 'db_size_bytes',
    'consumption_daily_rollups: db_size_bytes column exists');

-- Deliberately NOT partitioned: one row/day is tiny by construction, so the
-- bloat problem partition-drop retention exists to solve cannot occur here.
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_partitioned_table pt
        JOIN pg_catalog.pg_class c ON c.oid = pt.partrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record' AND c.relname = 'consumption_daily_rollups'
    ),
    'consumption_daily_rollups is a plain table, not partitioned'
);

-- -----------------------------------------------------------------------------
-- 2. Fixture: day 100 (3 ticks, no reset -> 2 valid intervals), a "today"
--    tick (must never roll up), and day 101 (2 ticks, mid-day db-scope reset)
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_day0_ts0 int4 := 100 * 86400;
    v_day1_ts0 int4 := 101 * 86400;
    v_today_ts int4 := extract(epoch from now() - pgfr_record.epoch())::int4;
    v_reset_a  timestamptz := '2026-01-01'::timestamptz;
    v_reset_b  timestamptz := '2026-01-02'::timestamptz;
BEGIN
    -- Day 100: three ticks, constant reset sentinels throughout.
    INSERT INTO pgfr_record.consumption_snapshots_v2 (
        snapshot_id, sample_ts, captured_at, pg_version, datname,
        wal_lsn, tup_returned, tup_inserted, tup_updated, tup_deleted,
        xact_commit, xact_rollback, blks_hit, blks_read, temp_bytes,
        wal_records, wal_fpi, wal_bytes, wal_stats_reset,
        io_writes_autovacuum, io_writes_total,
        ckpt_num_timed, ckpt_num_requested, ckpt_stats_reset,
        db_stats_reset, db_size_bytes,
        recorder_blks_hit, recorder_blks_read
    ) VALUES
        (810001, v_day0_ts0 + 0, now(), 17, '__pgfr_test_consumption__',
         '0/1000000'::pg_lsn, 1000, 200, 0, 0, 100, 5, 5000, 500, 0,
         1000, 10, 100000, v_reset_a, 50, 500, 5, 1, v_reset_a,
         v_reset_a, 1000000, 10, 1),
        (810002, v_day0_ts0 + 3600, now(), 17, '__pgfr_test_consumption__',
         '0/2000000'::pg_lsn, 1500, 250, 10, 0, 150, 6, 6000, 600, 1000,
         1100, 15, 110000, v_reset_a, 60, 600, 6, 2, v_reset_a,
         v_reset_a, 1100000, 15, 2),
        (810003, v_day0_ts0 + 7200, now(), 17, '__pgfr_test_consumption__',
         '0/3000000'::pg_lsn, 2200, 320, 15, 2, 220, 7, 7500, 650, 1500,
         1250, 20, 125000, v_reset_a, 75, 650, 8, 2, v_reset_a,
         v_reset_a, 1200000, 20, 3);

    -- "Today": one more tick under the same fake datname. Its delta (against
    -- day 100's last tick) attributes to the current day -- which must never
    -- be rolled up, since it isn't closed yet.
    INSERT INTO pgfr_record.consumption_snapshots_v2 (
        snapshot_id, sample_ts, captured_at, pg_version, datname,
        wal_lsn, tup_returned, xact_commit, blks_hit, blks_read,
        wal_records, wal_fpi, wal_bytes, wal_stats_reset,
        ckpt_num_timed, ckpt_num_requested, ckpt_stats_reset,
        db_stats_reset, db_size_bytes
    ) VALUES
        (810004, v_today_ts, now(), 17, '__pgfr_test_consumption__',
         '0/9000000'::pg_lsn, 9999, 999, 99000, 9900,
         9999, 99, 999000, v_reset_a, 99, 9, v_reset_a,
         v_reset_a, 9000000);

    -- Day 101: a single tick. Its "prev" is day 100's last tick (the only
    -- earlier row for this datname), so this is the day-boundary-crossing
    -- interval attributed to day 101. db_stats_reset changes relative to
    -- that prev (simulating a pg_stat_reset() sometime between the two
    -- ticks); wal/ckpt/io sentinels stay the same as day 100 (unaffected),
    -- so exactly one interval lands in day 101 and it's cleanly split: db-
    -- scoped sums NULL, wal/ckpt/io-scoped sums valid.
    INSERT INTO pgfr_record.consumption_snapshots_v2 (
        snapshot_id, sample_ts, captured_at, pg_version, datname,
        wal_lsn, tup_returned, tup_inserted, tup_updated, tup_deleted,
        xact_commit, xact_rollback, blks_hit, blks_read,
        wal_records, wal_fpi, wal_bytes, wal_stats_reset,
        io_writes_autovacuum, io_writes_total,
        ckpt_num_timed, ckpt_num_requested, ckpt_stats_reset,
        db_stats_reset, db_size_bytes,
        recorder_blks_hit, recorder_blks_read
    ) VALUES
        (810101, v_day1_ts0 + 0, now(), 17, '__pgfr_test_consumption__',
         '0/4000000'::pg_lsn, 5000, 500, 0, 0, 500, 10, 10000, 1000,
         2000, 30, 200000, v_reset_a, 100, 1000, 10, 3, v_reset_a,
         v_reset_b, 2000000, 30, 5);
END $$;

SELECT lives_ok($$SELECT pgfr_record._rollup_consumption_daily()$$,
    '_rollup_consumption_daily() runs cleanly');

-- -----------------------------------------------------------------------------
-- 3. Day 100 rollup correctness: 2 valid intervals, no reset (11 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT total_seconds FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    7200,
    'day 100: total_seconds sums the two 3600s intervals'
);
SELECT is(
    (SELECT valid_tick_count FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    2,
    'day 100: valid_tick_count counts the two intervals'
);
SELECT is(
    (SELECT blks_hit_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    2500::bigint,
    'day 100: blks_hit_sum = 1000 + 1500'
);
SELECT is(
    (SELECT tup_returned_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    1200::bigint,
    'day 100: tup_returned_sum = 500 + 700'
);
SELECT is(
    (SELECT tup_mutated_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    137::bigint,
    'day 100: tup_mutated_sum = 60 + 77 (ins+upd+del combined)'
);
SELECT is(
    (SELECT xact_commit_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    120::bigint,
    'day 100: xact_commit_sum = 50 + 70'
);
SELECT is(
    (SELECT xact_rollback_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    2::bigint,
    'day 100: xact_rollback_sum = 1 + 1'
);
SELECT is(
    (SELECT wal_bytes_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    33554432::numeric,
    'day 100: wal_bytes_sum (LSN ledger) = 0x1000000 + 0x1000000'
);
SELECT is(
    (SELECT ckpt_num_requested_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    1::bigint,
    'day 100: ckpt_num_requested_sum = 1 + 0'
);
SELECT is(
    (SELECT io_writes_autovacuum_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    25::bigint,
    'day 100: io_writes_autovacuum_sum = 10 + 15'
);
SELECT is(
    (SELECT db_size_bytes FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    1200000::bigint,
    'day 100: db_size_bytes is the day''s last observed value (gauge, not summed)'
);

-- -----------------------------------------------------------------------------
-- 4. Today never rolls up (1 test)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__'
       AND rollup_date >= current_date),
    0,
    'the current (unclosed) day never gets a rollup row'
);

-- -----------------------------------------------------------------------------
-- 5. Day 101: mid-day db-scope reset excludes db-scoped sums but leaves
--    wal/ckpt/io-scoped sums valid (2 tests) -- the per-source guard
--    behavior from consumption_deltas surviving into SUM()-based rollup.
-- -----------------------------------------------------------------------------

SELECT ok(
    (SELECT tup_returned_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 101 * 86400 * interval '1 second')::date) IS NULL
    AND (SELECT blks_hit_sum FROM pgfr_record.consumption_daily_rollups
         WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 101 * 86400 * interval '1 second')::date) IS NULL,
    'day 101: db-scoped sums are NULL for the interval spanning a db_stats_reset'
);
SELECT is(
    (SELECT wal_bytes_sum FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__' AND rollup_date = (pgfr_record.epoch() + 101 * 86400 * interval '1 second')::date),
    16777216::numeric,
    'day 101: wal_bytes_sum (LSN ledger, unaffected by a db-scope reset) still valid'
);

-- -----------------------------------------------------------------------------
-- 6. Idempotency: re-running does not duplicate or alter day 100's row (1 test)
-- -----------------------------------------------------------------------------

SELECT lives_ok($$SELECT pgfr_record._rollup_consumption_daily()$$,
    '_rollup_consumption_daily() re-run does not raise');

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.consumption_daily_rollups
     WHERE datname = '__pgfr_test_consumption__'
       AND rollup_date = (pgfr_record.epoch() + 100 * 86400 * interval '1 second')::date),
    1,
    'day 100 still has exactly one rollup row after a second run (no duplicate)'
);

SELECT * FROM finish();
ROLLBACK;
