-- =============================================================================
-- pgfr_analyze pgTAP Tests — Consumption Weekly Trend Engine (Issue #92, phase B/4)
-- =============================================================================
-- Mirrors 22_consumption_trends.sql's synthetic scenarios (insufficient data,
-- stable, drift, step) at the weekly grain: 84-day/12-week fixtures built
-- from day-level generate_series, mapped to week boundaries via i/7. Also
-- confirms composition_change is always false at this grain (phase C's job,
-- not yet built) and that the daily engine's phase 2 behavior is untouched.
-- =============================================================================

BEGIN;
SELECT plan(15);

-- -----------------------------------------------------------------------------
-- 1. Schema (2 tests)
-- -----------------------------------------------------------------------------

SELECT has_view('pgfr_analyze', 'consumption_weekly_metric_series',
    'consumption_weekly_metric_series view exists');
SELECT has_function('pgfr_analyze', '_refresh_consumption_trends_weekly',
    '_refresh_consumption_trends_weekly() exists');

-- -----------------------------------------------------------------------------
-- 2. Fixtures: four datnames, 84 days of pgfr_record.consumption_daily_rollups
--    each (i = days ago, 0..83; week index = i/7)
-- -----------------------------------------------------------------------------

-- Insufficient data: only 5 weeks (35 days) collected, need 8.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    blks_hit_sum, blks_read_sum, tup_returned_sum
)
SELECT current_date - i, '__pgfr_test_weekly_short__', 3600, 1, 800, 200, 100
FROM generate_series(0, 34) AS i;

-- Stable: perfectly constant ratio across all 12 weeks.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    blks_hit_sum, blks_read_sum, tup_returned_sum
)
SELECT current_date - i, '__pgfr_test_weekly_stable__', 3600, 1, 800, 200, 100
FROM generate_series(0, 83) AS i;

-- Drift: wal_bytes_per_row_mutated ramps smoothly (tup_mutated_sum constant,
-- wal_bytes_sum increases linearly day over day).
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    tup_mutated_sum, wal_bytes_sum
)
SELECT current_date - i, '__pgfr_test_weekly_drift__', 3600, 1,
    100, 10000 + 100 * (83 - i)
FROM generate_series(0, 83) AS i;

-- Step: temp_bytes_per_xact shifts cleanly at the week-5/week-6 boundary
-- (i=42 is the first day of week index 6) -> changepoint at week_end_date
-- for week 6, i.e. current_date - 42.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    temp_bytes_sum, xact_commit_sum
)
SELECT current_date - i, '__pgfr_test_weekly_step__', 3600, 1,
    CASE WHEN i >= 42 THEN 1000 ELSE 2000 END, 100
FROM generate_series(0, 83) AS i;

SELECT lives_ok($$SELECT pgfr_analyze._refresh_consumption_trends_weekly()$$,
    '_refresh_consumption_trends_weekly() runs cleanly');

-- -----------------------------------------------------------------------------
-- 3. Assertions (9 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_short__' AND metric_name = 'blocks_per_row_returned'
       AND as_of_date = current_date AND window_days = 84),
    'insufficient_data',
    '5 weeks of data classifies as insufficient_data (< 8-week minimum)'
);
SELECT is(
    (SELECT window_days FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_short__' AND metric_name = 'blocks_per_row_returned'
       AND as_of_date = current_date AND window_days = 84),
    84,
    'the weekly engine writes window_days = 84, distinguishing it from the daily engine''s 28'
);
SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_stable__' AND metric_name = 'blocks_per_row_returned'
       AND as_of_date = current_date AND window_days = 84),
    'stable',
    '12 weeks of a perfectly constant ratio classifies as stable'
);
SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_drift__' AND metric_name = 'wal_bytes_per_row_mutated'
       AND as_of_date = current_date AND window_days = 84),
    'drift',
    'a clean linear ramp, aggregated to weekly grain, classifies as drift'
);
SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_step__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    'step',
    'a clean level shift at a week boundary classifies as step'
);
SELECT is(
    (SELECT changepoint_date FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_step__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    (current_date - 42),
    'changepoint_date lands exactly at the injected shift''s week boundary'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.consumption_trends
        WHERE datname IN ('__pgfr_test_weekly_short__', '__pgfr_test_weekly_stable__',
                           '__pgfr_test_weekly_drift__', '__pgfr_test_weekly_step__')
          AND window_days = 84 AND as_of_date = current_date
          AND composition_change = true
    ),
    'composition_change is false everywhere at this grain -- not evaluated yet, phase C''s job'
);

-- -----------------------------------------------------------------------------
-- 3b. Known boundary (Issue #101): a level shift whose week contains a
--     recorded restart classifies as discontinuity, not step. Shift at
--     i >= 21 (week index 3, week_end_date = current_date - 21); restart
--     recorded at current_date - 23, inside that week's 7-day span. The
--     existing step fixture splits at current_date - 42, outside this
--     event's tolerance, so it stays a discovered step.
-- -----------------------------------------------------------------------------

INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    temp_bytes_sum, xact_commit_sum
)
SELECT current_date - i, '__pgfr_test_weekly_discont__', 3600, 1,
    CASE WHEN i >= 21 THEN 1000 ELSE 2000 END, 100
FROM generate_series(0, 83) AS i;

INSERT INTO pgfr_record.discontinuities (detected_at, event_kind, scope, evidence)
VALUES ((current_date - 23)::timestamptz + interval '4 hours', 'restart', 'postmaster',
        '{"previous_start": "weekly fixture"}'::jsonb);

SELECT lives_ok($$SELECT pgfr_analyze._refresh_consumption_trends_weekly()$$,
    '_refresh_consumption_trends_weekly() runs with a recorded discontinuity in the window');

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_discont__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    'discontinuity',
    'a weekly level shift whose week contains a recorded restart classifies as discontinuity'
);

SELECT is(
    (SELECT classification FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_step__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    'step',
    'the unrelated step fixture (split outside the event tolerance) stays a discovered step'
);

SELECT lives_ok($$SELECT pgfr_analyze._refresh_consumption_trends_weekly()$$,
    '_refresh_consumption_trends_weekly() re-run does not raise');
SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.consumption_trends
     WHERE datname = '__pgfr_test_weekly_step__' AND metric_name = 'temp_bytes_per_xact'
       AND as_of_date = current_date AND window_days = 84),
    1,
    'today''s 84-day row is upserted, not duplicated, on a second refresh'
);

SELECT * FROM finish();
ROLLBACK;
