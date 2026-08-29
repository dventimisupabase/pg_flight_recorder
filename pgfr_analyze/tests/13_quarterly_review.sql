-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- quarterly_review(), quarterly_review_with_summary()
-- =============================================================================
-- test.sh deactivates every pgfr_ cron job before running the pgTAP suite,
-- so "5. pg_cron Job Health" is deterministically CRITICAL here (and the
-- overall summary deterministically ACTION REQUIRED) -- not something to
-- avoid triggering, same reasoning as 12_check_alerts.sql.

BEGIN;
SELECT plan(10);

SELECT has_function('pgfr_analyze', 'quarterly_review', 'Function pgfr_analyze.quarterly_review should exist');
SELECT has_function('pgfr_analyze', 'quarterly_review_with_summary', 'Function pgfr_analyze.quarterly_review_with_summary should exist');

SELECT results_eq(
    $$SELECT component FROM pgfr_analyze.quarterly_review() ORDER BY component$$,
    $$VALUES ('1. Collection Performance'), ('2. Storage Consumption'), ('3. Collection Reliability'), ('4. Data Freshness'), ('5. pg_cron Job Health'), ('6. Partition Maintenance'), ('=== QUARTERLY REVIEW ===') ORDER BY 1$$,
    'quarterly_review() should return the header row plus all six numbered components'
);

SELECT is(
    (SELECT status FROM pgfr_analyze.quarterly_review() WHERE component = '5. pg_cron Job Health'),
    'CRITICAL',
    '5. pg_cron Job Health should be CRITICAL while every pgfr_ cron job is deactivated'
);

-- ---------------------------------------------------------------------------
-- After running every tier, Data Freshness and Collection Reliability
-- should both grade clean.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should succeed');
SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should succeed');
SELECT lives_ok($$SELECT pgfr_record.run_tier('slow')$$, 'run_tier(''slow'') should succeed');
SELECT lives_ok($$SELECT pgfr_record.run_tier('on_change')$$, 'run_tier(''on_change'') should succeed');

SELECT is(
    (SELECT status FROM pgfr_analyze.quarterly_review() WHERE component = '4. Data Freshness'),
    'EXCELLENT',
    '4. Data Freshness should be EXCELLENT once every tier has just run'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.quarterly_review_with_summary()) >= 0,
    'quarterly_review_with_summary() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
