-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- summary_report()
-- =============================================================================
-- summary_report() is a pure composition over already-tested functions
-- (coverage(), anomaly_report(), capacity_summary(), table_hotspots(),
-- unused_indexes(), long_running_transactions(), vacuum_progress(),
-- wal_archiver_status(), config_changes()); these tests check that every
-- expected section/metric row is present and shaped correctly, not that
-- the underlying detection logic is correct (that's each function's own
-- test file's job).

BEGIN;
SELECT plan(7);

SELECT has_function('pgfr_analyze', 'summary_report', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.summary_report should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture a real baseline');
SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should capture a real baseline');

SELECT clock_timestamp() AS t_ref \gset ref_

SELECT results_eq(
    $$SELECT DISTINCT section FROM pgfr_analyze.summary_report(clock_timestamp() - interval '1 hour', clock_timestamp()) ORDER BY section$$,
    $$VALUES ('ACTIVITY'), ('CAPACITY'), ('CONFIGURATION'), ('OVERVIEW'), ('TABLES & INDEXES') ORDER BY 1$$,
    'summary_report() should return exactly the five expected sections'
);
-- Not asserting a specific count: by the time this file runs in the full
-- suite, earlier files' own real activity (pgfr_record's acceptance suite,
-- other analyze tests exercising real captures) may have already tripped
-- a real anomaly in the live database. Only the row's own internal
-- consistency (value matches interpretation) is checked here.
SELECT ok(
    (SELECT (value::bigint = 0) = (interpretation = 'No issues detected')
     FROM pgfr_analyze.summary_report(:'ref_t_ref'::timestamptz - interval '1 hour', :'ref_t_ref'::timestamptz)
     WHERE metric = 'Anomalies Detected'),
    'summary_report() Anomalies Detected interpretation should match its own count'
);
SELECT ok(
    (SELECT value FROM pgfr_analyze.summary_report(:'ref_t_ref'::timestamptz - interval '1 hour', :'ref_t_ref'::timestamptz) WHERE metric = 'Time Window') LIKE '%to%',
    'summary_report() should format the Time Window metric as a from/to range'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.summary_report(:'ref_t_ref'::timestamptz - interval '1 hour', :'ref_t_ref'::timestamptz)) >= 0,
    'summary_report() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
