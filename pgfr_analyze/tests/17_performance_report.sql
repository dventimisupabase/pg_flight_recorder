-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- performance_report()
-- =============================================================================
-- The per-tier duration and trend metrics are computed from real
-- ledger_runs activity (this container's own run_tier() calls), not
-- synthesizable in isolation the way other tests mutate payloads --
-- inserting a synthetic 'fast'-tier row would mix with genuinely captured
-- 'fast' rows in the same window. Assertions check structural properties
-- (the metric appears, its assessment is one of the function's own valid
-- values) rather than an exact number.

BEGIN;
SELECT plan(8);

SELECT has_function('pgfr_analyze', 'performance_report', ARRAY['interval'], 'Function pgfr_analyze.performance_report should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture a real baseline for ledger_runs');
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 're-running run_tier(''fast'') should succeed');

SELECT ok(
    (SELECT assessment FROM pgfr_analyze.performance_report(interval '1 hour') WHERE metric = 'fast tier duration') IN ('Excellent', 'Good', 'Acceptable', 'Poor -- consider a lighter profile (pgfr_record.apply_profile())'),
    'performance_report() should report a fast tier duration with a valid assessment'
);
SELECT ok(
    (SELECT assessment FROM pgfr_analyze.performance_report(interval '1 hour') WHERE metric = 'Storage Size') IN ('Healthy', 'Good', 'Consider reviewing retention settings', 'Review retention settings soon'),
    'performance_report() should report a Storage Size with a valid assessment'
);
SELECT is(
    (SELECT assessment FROM pgfr_analyze.performance_report(interval '1 hour') WHERE metric = 'Collection Success Rate'),
    'Perfect',
    'performance_report() should report Perfect collection success rate when nothing has failed'
);
SELECT ok(
    (SELECT assessment FROM pgfr_analyze.performance_report(interval '1 hour') WHERE metric = 'Performance Trend (fast tier)') IN ('STABLE', 'IMPROVING', 'DEGRADING -- investigate system load', 'Need more data in this window'),
    'performance_report() should report a fast-tier trend with a valid assessment'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.performance_report(interval '1 hour')) >= 0,
    'performance_report() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
