-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- Partition maintenance (§4.2)
-- =============================================================================

BEGIN;
SELECT plan(35);

-- ---------------------------------------------------------------------------
-- Functions + tables exist
-- ---------------------------------------------------------------------------
SELECT has_function('pgfr_record', '_current_major', 'Function pgfr_record._current_major should exist');
SELECT has_function('pgfr_record', '_short_name', 'Function pgfr_record._short_name should exist');
SELECT has_function('pgfr_record', '_partition_unit', 'Function pgfr_record._partition_unit should exist');
SELECT has_function('pgfr_record', '_partition_targets', 'Function pgfr_record._partition_targets should exist');
SELECT has_function('pgfr_record', '_partition_child_name', 'Function pgfr_record._partition_child_name should exist');
SELECT has_function('pgfr_record', '_partition_lower_bound', 'Function pgfr_record._partition_lower_bound should exist');
SELECT has_function('pgfr_record', 'maintain_partitions', 'Function pgfr_record.maintain_partitions should exist');
SELECT has_table('pgfr_record', 'ledger_runs', 'Table pgfr_record.ledger_runs should exist');
SELECT has_table('pgfr_record', 'ledger_captures', 'Table pgfr_record.ledger_captures should exist');

-- ---------------------------------------------------------------------------
-- _current_major
-- ---------------------------------------------------------------------------
SELECT is(
    pgfr_record._current_major(),
    (current_setting('server_version_num')::int / 10000),
    '_current_major() should match server_version_num'
);

-- ---------------------------------------------------------------------------
-- _short_name (§4.1)
-- ---------------------------------------------------------------------------
SELECT is(pgfr_record._short_name('pg_catalog.pg_stat_database'), 'pg_stat_database', '_short_name should strip the pg_catalog prefix');
SELECT is(pgfr_record._short_name('pgfr_record.src_catalog_identity'), 'src_catalog_identity', '_short_name should strip the pgfr_record prefix');

-- ---------------------------------------------------------------------------
-- _partition_unit boundaries (§4.2 width rule)
-- ---------------------------------------------------------------------------
SELECT is(pgfr_record._partition_unit(interval '2 hours'), 'hour', '2h retention should use hourly partitions');
SELECT is(pgfr_record._partition_unit(interval '6 hours'), 'hour', '6h retention (boundary) should use hourly partitions');
SELECT is(pgfr_record._partition_unit(interval '7 hours'), 'day', '7h retention should use daily partitions');
SELECT is(pgfr_record._partition_unit(interval '60 days'), 'day', '60d retention (boundary) should use daily partitions');
SELECT is(pgfr_record._partition_unit(interval '61 days'), 'month', '61d retention should use monthly partitions');
SELECT is(pgfr_record._partition_unit(interval '365 days'), 'month', '365d retention should use monthly partitions');

-- ---------------------------------------------------------------------------
-- Deterministic naming round-trips (maintain_partitions never parses
-- pg_class.relpartbound; it recovers bounds from the child's name).
-- ---------------------------------------------------------------------------
SELECT is(
    pgfr_record._partition_lower_bound(
        pgfr_record._partition_child_name('a_pg_stat_all_tables', '2026-08-28 00:00:00'::timestamptz, 'day'),
        'a_pg_stat_all_tables', 'day'
    ),
    '2026-08-28 00:00:00'::timestamptz,
    'day-unit child name should round-trip to its lower bound'
);
SELECT is(
    pgfr_record._partition_lower_bound(
        pgfr_record._partition_child_name('a_pg_stat_activity', '2026-08-28 14:00:00'::timestamptz, 'hour'),
        'a_pg_stat_activity', 'hour'
    ),
    '2026-08-28 14:00:00'::timestamptz,
    'hour-unit child name should round-trip to its lower bound'
);
SELECT is(
    pgfr_record._partition_lower_bound(
        pgfr_record._partition_child_name('a_pg_settings', '2026-08-01 00:00:00'::timestamptz, 'month'),
        'a_pg_settings', 'month'
    ),
    '2026-08-01 00:00:00'::timestamptz,
    'month-unit child name should round-trip to its lower bound'
);

-- ---------------------------------------------------------------------------
-- Create-ahead (step 1), on the ledger tables that already exist at
-- install time (archive tables do not exist yet -- generators land next).
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.maintain_partitions()$$, 'maintain_partitions() should execute without error');

SELECT ok(
    (SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
     WHERE p.relname = 'ledger_runs') >= 3,
    'ledger_runs should have at least 3 partitions after maintain_partitions() (current + 2 ahead)'
);
SELECT ok(
    (SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
     WHERE p.relname = 'ledger_captures') >= 3,
    'ledger_captures should have at least 3 partitions after maintain_partitions() (current + 2 ahead)'
);

SELECT lives_ok($$SELECT pgfr_record.maintain_partitions()$$, 'maintain_partitions() should be idempotent (re-run without error)');
SELECT is(
    (SELECT count(*)::int FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent WHERE p.relname = 'ledger_runs'),
    3,
    're-running maintain_partitions() should settle at exactly 3 ledger_runs partitions (current + 2 ahead), not duplicate them'
);

-- ---------------------------------------------------------------------------
-- Schedule detaches (step 2): manufacture an expired, still-attached
-- partition and verify a one-off pg_cron job is scheduled for it, with
-- the bare DETACH ... CONCURRENTLY statement as its command -- and that
-- nothing has actually been detached yet (only scheduled).
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$CREATE TABLE pgfr_record.ledger_runs_p20000101 PARTITION OF pgfr_record.ledger_runs
      FOR VALUES FROM ('2000-01-01') TO ('2000-01-02')$$,
    'creating a manufactured expired partition on ledger_runs should succeed'
);
SELECT lives_ok($$SELECT pgfr_record.maintain_partitions()$$, 'maintain_partitions() should execute without error over an expired partition');
SELECT is(
    (SELECT command FROM cron.job WHERE jobname = 'pgfr_detach_ledger_runs_p20000101'),
    'ALTER TABLE pgfr_record.ledger_runs DETACH PARTITION pgfr_record.ledger_runs_p20000101 CONCURRENTLY',
    'a one-off job should be scheduled with the bare DETACH ... CONCURRENTLY statement as its command'
);
SELECT ok(
    (SELECT relispartition FROM pg_class WHERE relname = 'ledger_runs_p20000101' AND relnamespace = 'pgfr_record'::regnamespace),
    'the expired partition should still be attached -- scheduling a detach must not detach it directly'
);

-- ---------------------------------------------------------------------------
-- Drop retired + reap (steps 3-4): manufacture a standalone leftover
-- table (as if a prior cycle's detach had already fired) plus its
-- matching stale cron.job row, and verify one maintain_partitions() pass
-- cleans up both.
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$CREATE TABLE pgfr_record.ledger_runs_p19990101 (LIKE pgfr_record.ledger_runs)$$,
    'creating a manufactured standalone leftover table should succeed'
);
SELECT lives_ok(
    $$SELECT cron.schedule('pgfr_detach_ledger_runs_p19990101', '0 0 1 1 *', 'SELECT 1')$$,
    'scheduling a manufactured stale one-off job should succeed'
);
SELECT lives_ok($$SELECT pgfr_record.maintain_partitions()$$, 'maintain_partitions() should execute without error over a retired standalone table');
SELECT is(
    to_regclass('pgfr_record.ledger_runs_p19990101'),
    NULL::regclass,
    'the standalone leftover table should be dropped'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_detach_ledger_runs_p19990101'),
    'the stale one-off job should be reaped once its target table is gone'
);

SELECT * FROM finish();
ROLLBACK;
