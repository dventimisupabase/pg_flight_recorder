-- =============================================================================
-- pgfr_analyze pgTAP Tests — Consumption Trend Engine (Issue #83, phase 2/4)
-- =============================================================================
-- Tests consumption_metric_series, consumption_trends, and
-- _refresh_consumption_trends(): the Theil-Sen slope and the R2-based
-- step/drift/stable classification, on synthetic 28-day fixtures inserted
-- directly into pgfr_record.consumption_daily_rollups under private fake
-- datnames (isolated from real background sampling, same technique as the
-- pgfr_record consumption test files).
-- =============================================================================

BEGIN;
SELECT plan(21);

-- -----------------------------------------------------------------------------
-- 1. Schema (6 tests)
-- -----------------------------------------------------------------------------

SELECT has_view('pgfr_analyze', 'consumption_metric_series',
    'consumption_metric_series view exists');
SELECT has_table('pgfr_analyze', 'consumption_trends',
    'consumption_trends table exists');
SELECT has_function('pgfr_analyze', '_refresh_consumption_trends',
    '_refresh_consumption_trends() exists');
SELECT has_column('pgfr_analyze', 'consumption_trends', 'classification',
    'consumption_trends: classification column exists');
SELECT has_column('pgfr_analyze', 'consumption_trends', 'changepoint_date',
    'consumption_trends: changepoint_date column exists');
SELECT has_column('pgfr_analyze', 'consumption_trends', 'slope_pct_per_30d',
    'consumption_trends: slope_pct_per_30d column exists');

-- -----------------------------------------------------------------------------
-- 2. Table constraints (2 tests)
-- -----------------------------------------------------------------------------

SELECT throws_ok(
    $$INSERT INTO pgfr_analyze.consumption_trends
      (as_of_date, datname, metric_name, window_days, basket_version,
       sample_count, baseline_start, baseline_end, classification)
      VALUES (current_date, '__pgfr_test_ck__', 'x', 28, 1, 0, current_date, current_date, 'bogus')$$,
    'new row for relation "consumption_trends" violates check constraint "consumption_trends_classification_check"',
    'classification rejects a value outside the enum'
);
SELECT throws_ok(
    $$INSERT INTO pgfr_analyze.consumption_trends
      (as_of_date, datname, metric_name, window_days, basket_version,
       sample_count, baseline_start, baseline_end, classification, changepoint_date)
      VALUES (current_date, '__pgfr_test_ck__', 'x', 28, 1, 28, current_date - 27, current_date, 'drift', current_date - 10)$$,
    'new row for relation "consumption_trends" violates check constraint "consumption_trends_check"',
    'changepoint_date set on a non-step classification is rejected'
);

-- -----------------------------------------------------------------------------
-- 3. Fixtures
-- -----------------------------------------------------------------------------

-- Scenario A: 5 days only (< the 14-day minimum) -> insufficient_data.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    blks_hit_sum, blks_read_sum, tup_returned_sum
)
SELECT current_date - i, '__pgfr_test_trends_short__', 3600, 1, 800, 200, 100
FROM generate_series(0, 4) AS i;

-- Scenario B: 28 days, perfectly constant -> stable (both R2s undefined:
-- zero total variance; the classifier's coalesce-to-0 fallback lands on stable).
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    blks_hit_sum, blks_read_sum, tup_returned_sum
)
SELECT current_date - i, '__pgfr_test_trends_stable__', 3600, 1, 800, 200, 100
FROM generate_series(0, 27) AS i;

-- Scenario C: 28 days, one datname, three independent metrics from the same
-- rows -- a clean linear ramp (wal_bytes_per_row_mutated), a clean level
-- shift at current_date-14 (temp_bytes_per_xact), and a metric left entirely
-- NULL (autovacuum_write_share -- io_writes_*_sum columns simply omitted,
-- as they would be on PG15) to confirm one metric's NULLs can't affect
-- another metric's classification for the same datname.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    tup_mutated_sum, wal_bytes_sum, temp_bytes_sum, xact_commit_sum
)
SELECT
    current_date - i, '__pgfr_test_trends_shape__', 3600, 1,
    100,
    10000 + 100 * (27 - i),
    CASE WHEN i >= 14 THEN 1000 ELSE 2000 END,
    100
FROM generate_series(0, 27) AS i;

SELECT lives_ok($$SELECT pgfr_analyze._refresh_consumption_trends()$$,
    '_refresh_consumption_trends() runs cleanly');

-- -----------------------------------------------------------------------------
-- 4. Scenario A: insufficient data (4 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_short__' AND metric_name = 'blocks_per_row_returned'
       AND as_of_date = current_date),
    'insufficient_data',
    '5 days of data classifies as insufficient_data (< 14-day minimum)'
);
SELECT is(
    (SELECT sample_count FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_short__' AND metric_name = 'blocks_per_row_returned'
       AND as_of_date = current_date),
    5,
    'sample_count reflects the 5 days actually present'
);
SELECT ok(
    (SELECT slope_pct_per_30d FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_short__' AND metric_name = 'blocks_per_row_returned'
       AND as_of_date = current_date) IS NULL,
    'slope_pct_per_30d is NULL when insufficient_data'
);
SELECT ok(
    (SELECT changepoint_date FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_short__' AND metric_name = 'blocks_per_row_returned'
       AND as_of_date = current_date) IS NULL,
    'changepoint_date is NULL when insufficient_data'
);

-- -----------------------------------------------------------------------------
-- 5. Scenario B: stable (1 test)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_stable__' AND metric_name = 'blocks_per_row_returned'
       AND as_of_date = current_date),
    'stable',
    '28 days of a perfectly constant ratio classifies as stable'
);

-- -----------------------------------------------------------------------------
-- 6. Scenario C: ramp -> drift, level shift -> step, NULL metric doesn't
--    poison its sibling metrics (5 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_shape__' AND metric_name = 'wal_bytes_per_row_mutated'
       AND as_of_date = current_date),
    'drift',
    'a clean linear ramp classifies as drift, not step'
);
SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_shape__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date),
    'step',
    'a clean level shift classifies as step, not drift'
);
SELECT is(
    (SELECT changepoint_date FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_shape__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date),
    (current_date - 14),
    'changepoint_date lands exactly at the injected shift date'
);
SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_shape__' AND metric_name = 'autovacuum_write_share'
       AND as_of_date = current_date),
    'insufficient_data',
    'a metric NULL for the whole window (autovacuum_write_share, as on PG15) gets its own explicit insufficient_data row'
);
SELECT is(
    (SELECT sample_count FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_shape__' AND metric_name = 'autovacuum_write_share'
       AND as_of_date = current_date),
    0,
    'the NULL metric does not poison its sibling metrics: 0 samples recorded, not silently omitted'
);

-- -----------------------------------------------------------------------------
-- 7. Idempotency: re-running does not duplicate today's row (1 test)
-- -----------------------------------------------------------------------------

SELECT lives_ok($$SELECT pgfr_analyze._refresh_consumption_trends()$$,
    '_refresh_consumption_trends() re-run does not raise');

SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_trends_shape__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date),
    1,
    'today''s row is upserted, not duplicated, on a second refresh'
);

SELECT * FROM finish();
ROLLBACK;
