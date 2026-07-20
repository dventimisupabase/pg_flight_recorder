-- =============================================================================
-- pgfr_record pgTAP Tests — Consumption Daily Flows (Issue #83, phase 1)
-- =============================================================================
-- Tests consumption_daily_flows: the daily-grain ratio reconstruction from
-- consumption_daily_rollups' summed components. Fixture rows are inserted
-- directly into consumption_daily_rollups (bypassing the sampler/rollup
-- machinery entirely, already covered by 17_/19_) so this is a focused unit
-- test of the view's arithmetic: correct ratios from clean sums, and NULL
-- (never an error) when a sum is itself NULL or a denominator is zero.
-- =============================================================================

BEGIN;
SELECT plan(23);

-- -----------------------------------------------------------------------------
-- 1. Schema (4 tests)
-- -----------------------------------------------------------------------------

SELECT has_view('pgfr_record', 'consumption_daily_flows',
    'consumption_daily_flows view exists');
SELECT has_column('pgfr_record', 'consumption_daily_flows', 'blocks_per_row_returned',
    'consumption_daily_flows: blocks_per_row_returned column exists');
SELECT has_column('pgfr_record', 'consumption_daily_flows', 'read_write_tuple_ratio',
    'consumption_daily_flows: read_write_tuple_ratio column exists');
SELECT has_column('pgfr_record', 'consumption_daily_flows', 'db_size_bytes',
    'consumption_daily_flows: db_size_bytes column exists');

-- -----------------------------------------------------------------------------
-- 2. Fixture: one fully-populated day, clean round-number sums
-- -----------------------------------------------------------------------------

INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    blks_hit_sum, blks_read_sum,
    tup_returned_sum, tup_mutated_sum,
    xact_commit_sum, xact_rollback_sum,
    temp_bytes_sum,
    wal_bytes_sum, wal_fpi_sum, wal_bytes_advisory_sum,
    ckpt_num_timed_sum, ckpt_num_requested_sum,
    io_writes_autovacuum_sum, io_writes_total_sum,
    recorder_blks_hit_sum, recorder_blks_read_sum,
    db_size_bytes
) VALUES (
    '2026-03-01', '__pgfr_test_daily_flows__', 5000, 1,
    800, 200,
    100, 50,
    40, 10,
    2000,
    819200, 1, 32768,
    15, 5,
    30, 120,
    40, 10,
    5000000
);

SELECT is(
    (SELECT blocks_per_row_returned FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    10::numeric, 'blocks_per_row_returned = (800+200)/100'
);
SELECT is(
    (SELECT wal_bytes_per_row_mutated FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    16384::numeric, 'wal_bytes_per_row_mutated = 819200/50'
);
SELECT is(
    (SELECT temp_bytes_per_xact FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    50::numeric, 'temp_bytes_per_xact = 2000/40 (xact_commit only, not +rollback)'
);
SELECT is(
    (SELECT fpi_fraction FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    0.25::numeric, 'fpi_fraction = (1*8192)/32768'
);
SELECT is(
    (SELECT ckpt_requested_fraction FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    0.25::numeric, 'ckpt_requested_fraction = 5/(15+5)'
);
SELECT is(
    (SELECT rollback_fraction FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    0.2::numeric, 'rollback_fraction = 10/(40+10)'
);
SELECT is(
    (SELECT autovacuum_write_share FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    0.25::numeric, 'autovacuum_write_share = 30/120'
);
SELECT is(
    (SELECT cache_hit_fraction FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    0.8::numeric, 'cache_hit_fraction = 800/(800+200)'
);
SELECT is(
    (SELECT read_write_tuple_ratio FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    2::numeric, 'read_write_tuple_ratio = 100/50'
);
SELECT is(
    (SELECT xact_per_s FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    0.01::numeric, 'xact_per_s = (40+10)/5000'
);
SELECT is(
    (SELECT rows_returned_per_xact FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    2::numeric, 'rows_returned_per_xact = 100/50'
);
SELECT is(
    (SELECT rows_mutated_per_xact FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    1::numeric, 'rows_mutated_per_xact = 50/50'
);
SELECT is(
    (SELECT db_size_bytes FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    5000000::bigint, 'db_size_bytes passes through unchanged (gauge, not a ratio)'
);
SELECT is(
    (SELECT recorder_overhead_fraction FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-01' AND datname = '__pgfr_test_daily_flows__'),
    0.05::numeric, 'recorder_overhead_fraction = (40+10)/(800+200)'
);

-- -----------------------------------------------------------------------------
-- 3. Fixture: a day with a NULL sum (reset-excluded) and zero denominators
--    (5 tests) -- every ratio must be NULL, never a division error
-- -----------------------------------------------------------------------------

INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    blks_hit_sum, blks_read_sum,
    tup_returned_sum, tup_mutated_sum,
    xact_commit_sum, xact_rollback_sum,
    wal_bytes_sum,
    db_size_bytes
) VALUES (
    '2026-03-02', '__pgfr_test_daily_flows__', 3600, 1,
    NULL, NULL,
    50, 0,
    0, 0,
    1000,
    6000000
);

SELECT ok(
    (SELECT blocks_per_row_returned FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-02' AND datname = '__pgfr_test_daily_flows__') IS NULL,
    'blocks_per_row_returned is NULL when the underlying blks_hit/read sums are NULL'
);
SELECT ok(
    (SELECT wal_bytes_per_row_mutated FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-02' AND datname = '__pgfr_test_daily_flows__') IS NULL,
    'wal_bytes_per_row_mutated is NULL (not a division error) when tup_mutated_sum = 0'
);
SELECT ok(
    (SELECT rollback_fraction FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-02' AND datname = '__pgfr_test_daily_flows__') IS NULL,
    'rollback_fraction is NULL when both commit and rollback sums are 0'
);
SELECT ok(
    (SELECT read_write_tuple_ratio FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-02' AND datname = '__pgfr_test_daily_flows__') IS NULL,
    'read_write_tuple_ratio is NULL when tup_mutated_sum = 0'
);
SELECT is(
    (SELECT xact_per_s FROM pgfr_record.consumption_daily_flows
     WHERE rollup_date = '2026-03-02' AND datname = '__pgfr_test_daily_flows__'),
    0::numeric,
    'xact_per_s is a genuine 0 (not NULL) when total_seconds is nonzero but no xacts occurred'
);

SELECT * FROM finish();
ROLLBACK;
