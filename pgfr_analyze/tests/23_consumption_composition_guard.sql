-- =============================================================================
-- pgfr_analyze pgTAP Tests — Consumption Trend Composition Guard (Issue #83, phase 3/4)
-- =============================================================================
-- Tests _pct_shift_exceeds() in isolation, then the composition-drift guard
-- end to end: a detected movement (step) gets overridden to 'composition'
-- when the workload shape also moved; an unrelated shape shift does not
-- override an already-'stable' metric; and a step with no shape shift stays
-- 'step' (phase 2 behavior unaffected).
-- =============================================================================

BEGIN;
SELECT plan(15);

-- -----------------------------------------------------------------------------
-- 1. Schema (2 tests)
-- -----------------------------------------------------------------------------

SELECT has_column('pgfr_analyze', 'consumption_trends', 'composition_change',
    'consumption_trends: composition_change column exists');
SELECT has_function('pgfr_analyze', '_pct_shift_exceeds',
    '_pct_shift_exceeds() exists');

-- -----------------------------------------------------------------------------
-- 2. _pct_shift_exceeds() in isolation (5 tests)
-- -----------------------------------------------------------------------------

SELECT ok(
    pgfr_analyze._pct_shift_exceeds(100::numeric, 200::numeric, 25::numeric),
    'a 100% shift exceeds a 25% threshold'
);
SELECT ok(
    NOT pgfr_analyze._pct_shift_exceeds(100::numeric, 110::numeric, 25::numeric),
    'a 10% shift does not exceed a 25% threshold'
);
SELECT ok(
    pgfr_analyze._pct_shift_exceeds(0::numeric, 5::numeric, 25::numeric),
    'a 0-to-nonzero shift always exceeds (undefined percentage, but a real shift)'
);
SELECT ok(
    NOT pgfr_analyze._pct_shift_exceeds(0::numeric, 0::numeric, 25::numeric),
    'a 0-to-0 shift never exceeds'
);
SELECT ok(
    NOT pgfr_analyze._pct_shift_exceeds(NULL, 110::numeric, 25::numeric)
    AND NOT pgfr_analyze._pct_shift_exceeds(100::numeric, NULL, 25::numeric),
    'NULL on either side never exceeds (unknown, not a signal)'
);

-- -----------------------------------------------------------------------------
-- 3. Fixtures: three datnames, 28 days each
-- -----------------------------------------------------------------------------

-- Datname A: temp_bytes_per_xact steps AND read_write_tuple_ratio steps at the
-- same boundary -> the detected step should be overridden to 'composition'.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    temp_bytes_sum, xact_commit_sum, xact_rollback_sum,
    tup_returned_sum, tup_mutated_sum, db_size_bytes
)
SELECT
    current_date - i, '__pgfr_test_comp_a__', 3600, 1,
    CASE WHEN i >= 14 THEN 1000 ELSE 2000 END, 100, 0,
    CASE WHEN i >= 14 THEN 100  ELSE 300  END, 100, 5000000
FROM generate_series(0, 27) AS i;

-- Datname B: temp_bytes_per_xact steps the same way, but read_write_tuple_ratio
-- (and every other shape indicator) stays constant -> stays 'step' (phase 2
-- behavior unaffected by the guard's introduction).
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    temp_bytes_sum, xact_commit_sum, xact_rollback_sum,
    tup_returned_sum, tup_mutated_sum, db_size_bytes
)
SELECT
    current_date - i, '__pgfr_test_comp_b__', 3600, 1,
    CASE WHEN i >= 14 THEN 1000 ELSE 2000 END, 100, 0,
    100, 100, 5000000
FROM generate_series(0, 27) AS i;

-- Datname C: temp_bytes_per_xact is perfectly flat (nothing to misattribute),
-- but read_write_tuple_ratio steps -> classification stays 'stable', though
-- composition_change is still recorded true (the flag fired, it just had
-- nothing to override).
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    temp_bytes_sum, xact_commit_sum, xact_rollback_sum,
    tup_returned_sum, tup_mutated_sum, db_size_bytes
)
SELECT
    current_date - i, '__pgfr_test_comp_c__', 3600, 1,
    1000, 100, 0,
    CASE WHEN i >= 14 THEN 100 ELSE 300 END, 100, 5000000
FROM generate_series(0, 27) AS i;

SELECT lives_ok($$SELECT pgfr_analyze._refresh_consumption_trends()$$,
    '_refresh_consumption_trends() runs cleanly with the composition guard in place');

-- -----------------------------------------------------------------------------
-- 4. Datname A: step + shape shift -> composition overrides step (3 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_comp_a__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date),
    'composition',
    'a detected step is overridden to composition when the workload shape also shifted'
);
SELECT ok(
    (SELECT changepoint_date FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_comp_a__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date) IS NULL,
    'changepoint_date is NULL once composition overrides step -- no fitness inference'
);
SELECT is(
    (SELECT composition_change FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_comp_a__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date),
    true,
    'composition_change is recorded true'
);

-- -----------------------------------------------------------------------------
-- 5. Datname B: step, no shape shift -> stays step (phase 2 regression, 2 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_comp_b__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date),
    'step',
    'a step with no workload-shape shift stays step, unaffected by the guard'
);
SELECT is(
    (SELECT changepoint_date FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_comp_b__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date),
    (current_date - 14),
    'changepoint_date is still recorded correctly when composition does not fire'
);

-- -----------------------------------------------------------------------------
-- 6. Datname C: stable metric + shape shift -> stays stable, guard still fires (2 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_comp_c__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date),
    'stable',
    'a metric that never moved stays stable even when the workload shape shifted -- nothing to misattribute'
);
SELECT is(
    (SELECT composition_change FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_comp_c__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date),
    true,
    'composition_change is still recorded true even though it did not override a stable classification'
);

SELECT * FROM finish();
ROLLBACK;
