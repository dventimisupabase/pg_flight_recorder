-- =============================================================================
-- pgfr_analyze pgTAP Tests — Consumption Trend Report (Issue #83 phase 4/4,
-- Issue #92 phase D/4)
-- =============================================================================
-- Tests _sparkline() in isolation, then the full report renderer: section
-- headers using the issue's own vocabulary, explicit per-window baseline
-- declarations (28-day/daily and 84-day/weekly, Issue #92 phase D), factual
-- phrasing for every classification (insufficient_data, stable, composition,
-- step, drift) and for both grains' insufficient-data unit wording ("days" vs
-- "weeks"), and -- rendered across all of the above -- an absence of the
-- issue's banned vocabulary anywhere in the output.
-- =============================================================================

BEGIN;
SELECT plan(22);

-- -----------------------------------------------------------------------------
-- 1. Schema (3 tests)
-- -----------------------------------------------------------------------------

SELECT has_function('pgfr_analyze', '_sparkline',
    '_sparkline() exists');
SELECT has_function('pgfr_analyze', '_render_consumption_trend_window',
    '_render_consumption_trend_window() exists');
SELECT has_function('pgfr_analyze', 'consumption_trend_report',
    'consumption_trend_report() exists');

-- -----------------------------------------------------------------------------
-- 2. _sparkline() in isolation (4 tests)
-- -----------------------------------------------------------------------------

SELECT is(
    pgfr_analyze._sparkline(array[1,2,3,4,5,6,7,8]::numeric[]),
    '▁▂▃▄▅▆▇█',
    'a clean 1..8 sequence maps to all 8 levels in order'
);
SELECT is(
    pgfr_analyze._sparkline(array[1,NULL,8]::numeric[]),
    '▁·█',
    'a NULL entry renders as an explicit gap marker, not a skipped bar'
);
SELECT is(
    pgfr_analyze._sparkline(array[5,5,5]::numeric[]),
    '▄▄▄',
    'a constant series renders as a flat mid-level bar (no divide-by-zero)'
);
SELECT is(
    pgfr_analyze._sparkline(array[NULL,NULL]::numeric[]),
    '',
    'an all-NULL series renders as an empty string'
);

-- -----------------------------------------------------------------------------
-- 3. No-data report (1 test)
-- -----------------------------------------------------------------------------

SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_nodata__'),
    'No consumption trend data collected yet',
    'a datname with zero rollup data gets an explicit no-data report, not an empty or broken one'
);

-- -----------------------------------------------------------------------------
-- 4. Fixtures: three datnames covering composition/stable/insufficient_data,
--    step, and drift respectively. All three are exactly 28 days (4 complete
--    weekly buckets) -- enough for the daily window's 14-day minimum but
--    below the weekly window's 8-week minimum, so every metric's 84-day block
--    renders insufficient_data regardless of what its 28-day block shows.
--    That's deliberate: it's what exercises the weekly grain's "weeks"
--    wording and proves the two windows are judged independently.
-- -----------------------------------------------------------------------------

-- Datname A: temp_bytes_per_xact steps AND the read_write_tuple_ratio shape
-- indicator also steps (via tup_returned_sum) -> composition. rollback_fraction
-- stays flat (xact_rollback_sum=0 throughout, independent of tup_returned_sum)
-- -> stable despite the same window's composition_change firing. Every other
-- basket metric is left entirely unpopulated -> insufficient_data.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    temp_bytes_sum, xact_commit_sum, xact_rollback_sum,
    tup_returned_sum, tup_mutated_sum, db_size_bytes
)
SELECT
    current_date - i, '__pgfr_test_report_a__', 3600, 1,
    CASE WHEN i >= 14 THEN 1000 ELSE 2000 END, 100, 0,
    CASE WHEN i >= 14 THEN 100  ELSE 300  END, 100, 5000000
FROM generate_series(0, 27) AS i;

-- Datname B: temp_bytes_per_xact steps the same way, but tup_returned_sum
-- (and every shape indicator) stays constant -> step, no composition.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    temp_bytes_sum, xact_commit_sum, xact_rollback_sum,
    tup_returned_sum, tup_mutated_sum, db_size_bytes
)
SELECT
    current_date - i, '__pgfr_test_report_b__', 3600, 1,
    CASE WHEN i >= 14 THEN 1000 ELSE 2000 END, 100, 0,
    100, 100, 5000000
FROM generate_series(0, 27) AS i;

-- Datname C: wal_bytes_per_row_mutated ramps linearly -> drift.
INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    tup_mutated_sum, wal_bytes_sum, db_size_bytes
)
SELECT
    current_date - i, '__pgfr_test_report_c__', 3600, 1,
    100, 10000 + 100 * (27 - i), 5000000
FROM generate_series(0, 27) AS i;

-- -----------------------------------------------------------------------------
-- 5. Report structure and factual phrasing (13 tests)
-- -----------------------------------------------------------------------------

SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    '## Specific consumption',
    'report uses "Specific consumption" as a section header verbatim'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    '## Amplification factors',
    'report uses "Amplification factors" as a section header verbatim'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    '## Substrate',
    'report uses "Substrate" as a section header, never calling it consumption'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    E'\\*\\*28-day baseline:\\*\\* \\d{4}-\\d{2}-\\d{2} -> \\d{4}-\\d{2}-\\d{2}',
    'report declares its 28-day/daily baseline window explicitly'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    E'\\*\\*84-day baseline:\\*\\* \\d{4}-\\d{2}-\\d{2} -> \\d{4}-\\d{2}-\\d{2}',
    'report declares its 84-day/weekly baseline window explicitly, alongside the daily one'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    E'\\*\\*28-day window\\*\\*',
    'each metric shows an explicit 28-day window label'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    E'\\*\\*84-day window\\*\\*',
    'each metric shows an explicit 84-day window label, alongside the 28-day one'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    'Insufficient data: 14 days required, 0 collected',
    'an unpopulated metric states insufficient data explicitly at the daily grain, never silently omitted'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    'Insufficient data: 8 weeks required, 4 collected',
    'the same 28-day fixture reports insufficient data at the weekly grain too, in weeks rather than days'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    'A change was detected, but the workload mix also shifted',
    'a composition-flagged metric states the confound, makes no fitness inference'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__'),
    'No material change detected',
    'a metric that never moved states so plainly even though the window''s workload shape changed'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_b__'),
    ('Level shift detected on ' || (current_date - 14)::text),
    'a step (no composition) states the exact changepoint date at the daily grain'
);
SELECT matches(
    pgfr_analyze.consumption_trend_report('__pgfr_test_report_c__'),
    'Classification: drift',
    'a gradual ramp is reported as drift at the daily grain'
);

-- -----------------------------------------------------------------------------
-- 6. Vocabulary ban, across every classification rendered above (1 test)
-- -----------------------------------------------------------------------------

SELECT ok(
    (
        pgfr_analyze.consumption_trend_report('__pgfr_test_report_a__') ||
        pgfr_analyze.consumption_trend_report('__pgfr_test_report_b__') ||
        pgfr_analyze.consumption_trend_report('__pgfr_test_report_c__')
    ) !~* '(efficiency|waste|poor|unhealthy|\mbad\M)',
    'no banned vocabulary appears in reports covering insufficient_data, stable, composition, step, and drift'
);

SELECT * FROM finish();
ROLLBACK;
