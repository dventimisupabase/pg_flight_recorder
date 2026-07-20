-- =============================================================================
-- pgfr_analyze pgTAP Tests — Consumption Weekly Composition Guard (Issue #92, phase C/4)
-- =============================================================================
-- Mirrors 23_consumption_composition_guard.sql at the weekly/84-day grain: a
-- detected step overridden to composition when the workload shape also
-- shifted across the window's two halves, a step with no shape shift staying
-- step (phase B regression check), and a stable metric staying stable even
-- though the same window's shape shifted.
-- =============================================================================

BEGIN;
SELECT plan(9);

-- -----------------------------------------------------------------------------
-- Fixtures: two datnames, 84 days each. Both split cleanly at i=42 -- the
-- exact midpoint of the 84-day window, matching where the composition
-- guard's own fixed-halves split falls (v_as_of_date - v_window_days/2).
-- -----------------------------------------------------------------------------

-- Datname A: temp_bytes_per_xact steps AND read_write_tuple_ratio (via
-- tup_returned_sum) steps at the same boundary -> composition overrides the
-- detected step. rollback_fraction stays flat (xact_rollback_sum=0
-- throughout, independent of tup_returned_sum) -> stays stable despite the
-- same window's composition_change firing.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    temp_bytes_sum, xact_commit_sum, xact_rollback_sum,
    tup_returned_sum, tup_mutated_sum, db_size_bytes
)
SELECT
    current_date - i, '__pgfr_test_weekly_comp_a__', 3600, 1,
    CASE WHEN i >= 42 THEN 1000 ELSE 2000 END, 100, 0,
    CASE WHEN i >= 42 THEN 100  ELSE 300  END, 100, 5000000
FROM generate_series(0, 83) AS i;

-- Datname B: temp_bytes_per_xact steps the same way, but tup_returned_sum
-- (and every shape indicator) stays constant -> step, no composition.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    temp_bytes_sum, xact_commit_sum, xact_rollback_sum,
    tup_returned_sum, tup_mutated_sum, db_size_bytes
)
SELECT
    current_date - i, '__pgfr_test_weekly_comp_b__', 3600, 1,
    CASE WHEN i >= 42 THEN 1000 ELSE 2000 END, 100, 0,
    100, 100, 5000000
FROM generate_series(0, 83) AS i;

SELECT lives_ok($$SELECT pgfr_analyze._refresh_consumption_trends_weekly()$$,
    '_refresh_consumption_trends_weekly() runs cleanly with the composition guard in place');

-- -----------------------------------------------------------------------------
-- Datname A: step + shape shift -> composition overrides step (5 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_comp_a__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    'composition',
    'a detected step at weekly grain is overridden to composition when the workload shape also shifted'
);
SELECT ok(
    (SELECT changepoint_date FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_comp_a__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84) IS NULL,
    'changepoint_date is NULL once composition overrides step at weekly grain too'
);
SELECT is(
    (SELECT composition_change FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_comp_a__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    true,
    'composition_change is recorded true'
);
SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_comp_a__' AND metric_name = 'rollback_fraction'
       AND as_of_date = current_date AND window_days = 84),
    'stable',
    'a metric that never moved stays stable even when the same window''s workload shape shifted'
);
SELECT is(
    (SELECT composition_change FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_comp_a__' AND metric_name = 'rollback_fraction'
       AND as_of_date = current_date AND window_days = 84),
    true,
    'composition_change is still recorded true even though it did not override a stable classification'
);

-- -----------------------------------------------------------------------------
-- Datname B: step, no shape shift -> stays step (phase B regression, 3 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_comp_b__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    'step',
    'a step with no workload-shape shift stays step at weekly grain, unaffected by the guard'
);
SELECT is(
    (SELECT changepoint_date FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_comp_b__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    (current_date - 42),
    'changepoint_date is still recorded correctly when composition does not fire'
);
SELECT is(
    (SELECT composition_change FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_comp_b__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    false,
    'composition_change is false when the workload shape did not shift'
);

SELECT * FROM finish();
ROLLBACK;
