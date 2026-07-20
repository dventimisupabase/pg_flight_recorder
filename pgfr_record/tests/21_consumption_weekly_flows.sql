-- =============================================================================
-- pgfr_record pgTAP Tests — Consumption Weekly Flows (Issue #92, phase A/4)
-- =============================================================================
-- Tests consumption_weekly_flows: rolling 7-day bucket boundaries, the
-- Σnum/Σden reconstruction (a week's ratio must be volume-weighted across its
-- days, never a naive average of daily ratios), last-observed-value
-- semantics for the db_size_bytes gauge, and zero-denominator safety.
-- =============================================================================

BEGIN;
SELECT plan(10);

-- -----------------------------------------------------------------------------
-- 1. Schema (4 tests)
-- -----------------------------------------------------------------------------

SELECT has_view('pgfr_record', 'consumption_weekly_flows',
    'consumption_weekly_flows view exists');
SELECT has_column('pgfr_record', 'consumption_weekly_flows', 'week_end_date',
    'consumption_weekly_flows: week_end_date column exists');
SELECT has_column('pgfr_record', 'consumption_weekly_flows', 'week_index',
    'consumption_weekly_flows: week_index column exists');
SELECT has_column('pgfr_record', 'consumption_weekly_flows', 'blocks_per_row_returned',
    'consumption_weekly_flows: blocks_per_row_returned column exists');

-- -----------------------------------------------------------------------------
-- 2. Fixture: two complete rolling weeks (14 days). Week 0 (today back to 6
--    days ago) has one high-traffic day and six low-traffic days, so a
--    correct Σnum/Σden reconstruction must be volume-weighted rather than a
--    naive average of daily ratios: naive average of (10, 1,1,1,1,1,1)/7 ≈
--    2.29 or day-count-blind; correct is Σblks_hit/Σtup_returned = 6.4. Week 1
--    (7-13 days ago) is uniform, for a clean bucket-boundary check. The most
--    recent day (i=0) also carries a distinctive db_size_bytes to verify
--    last-observed-value (not summed) semantics.
-- -----------------------------------------------------------------------------

INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    blks_hit_sum, blks_read_sum, tup_returned_sum, db_size_bytes
)
SELECT
    current_date - i, '__pgfr_test_weekly_flows__', 3600, 1,
    CASE
        WHEN i = 0 THEN 9000   -- high-traffic day, week 0
        WHEN i <= 6 THEN 100   -- low-traffic days, week 0
        ELSE 200               -- uniform, week 1
    END,
    0,
    CASE
        WHEN i = 0 THEN 900
        WHEN i <= 6 THEN 100
        ELSE 10
    END,
    CASE WHEN i = 0 THEN 9000000 ELSE 1000000 END
FROM generate_series(0, 13) AS i;

SELECT is(
    (SELECT blocks_per_row_returned FROM pgfr_record.consumption_weekly_flows
     WHERE datname = '__pgfr_test_weekly_flows__' AND week_index = 0),
    6.4::numeric,
    'week 0''s ratio is volume-weighted (Σ9600/Σ1500=6.4), not a naive average of daily ratios (would be ≈2.29)'
);
SELECT is(
    (SELECT week_end_date FROM pgfr_record.consumption_weekly_flows
     WHERE datname = '__pgfr_test_weekly_flows__' AND week_index = 0),
    current_date,
    'week 0''s end date is today'
);
SELECT is(
    (SELECT blocks_per_row_returned FROM pgfr_record.consumption_weekly_flows
     WHERE datname = '__pgfr_test_weekly_flows__' AND week_index = 1),
    20::numeric,
    'week 1 (7-13 days ago) is a distinct, correctly-bucketed value: Σ1400/Σ70=20'
);
SELECT is(
    (SELECT week_end_date FROM pgfr_record.consumption_weekly_flows
     WHERE datname = '__pgfr_test_weekly_flows__' AND week_index = 1),
    (current_date - 7),
    'week 1''s end date is exactly 7 days before week 0''s'
);
SELECT is(
    (SELECT db_size_bytes FROM pgfr_record.consumption_weekly_flows
     WHERE datname = '__pgfr_test_weekly_flows__' AND week_index = 0),
    9000000::bigint,
    'db_size_bytes is the week''s last observed value (today''s), not a sum or average'
);

-- -----------------------------------------------------------------------------
-- 3. Zero-denominator safety (1 test)
-- -----------------------------------------------------------------------------

INSERT INTO pgfr_record.consumption_daily_rollups (
    rollup_date, datname, total_seconds, valid_tick_count,
    blks_hit_sum, blks_read_sum, tup_returned_sum
)
SELECT current_date - i, '__pgfr_test_weekly_flows_zero__', 3600, 1, 100, 0, 0
FROM generate_series(0, 6) AS i;

SELECT ok(
    (SELECT blocks_per_row_returned FROM pgfr_record.consumption_weekly_flows
     WHERE datname = '__pgfr_test_weekly_flows_zero__' AND week_index = 0) IS NULL,
    'a week with a zero denominator yields NULL, never a division error'
);

SELECT * FROM finish();
ROLLBACK;
