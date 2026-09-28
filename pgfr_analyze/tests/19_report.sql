-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- report(), report(interval)
-- =============================================================================
-- report() is a pure markdown rendering over already-tested functions;
-- these tests check that every expected section header appears (and the
-- deferred/descoped v1 sections do not), not that the underlying
-- detection logic is correct.

BEGIN;
SELECT plan(9);

SELECT has_function('pgfr_analyze', 'report', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.report(timestamptz, timestamptz) should exist');
SELECT has_function('pgfr_analyze', 'report', ARRAY['interval'], 'Function pgfr_analyze.report(interval) should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture a real baseline');
SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should capture a real baseline');

SELECT clock_timestamp() AS t_ref \gset ref_

SELECT ok(
    pgfr_analyze.report(:'ref_t_ref'::timestamptz - interval '1 hour', :'ref_t_ref'::timestamptz) ~ '# pg_flight_recorder Report',
    'report() should render the top-level header'
);
SELECT ok(
    (SELECT bool_and(pgfr_analyze.report(:'ref_t_ref'::timestamptz - interval '1 hour', :'ref_t_ref'::timestamptz) LIKE '%' || h || '%')
     FROM unnest(ARRAY[
        '## Anomalies', '## Capacity', '## Table Hotspots', '## Index Efficiency', '## Rarely-Used Indexes',
        '## Query Regressions', '## Query Storms', '## Long-Running Transactions', '## Vacuum Progress',
        '## WAL Archiver Status', '## Configuration Changes'
     ]) AS h),
    'report() should render every expected section header'
);
SELECT ok(
    NOT (pgfr_analyze.report(:'ref_t_ref'::timestamptz - interval '1 hour', :'ref_t_ref'::timestamptz) ~ '## (Wait Event Summary|Lock Contention|Role Configuration Changes)'),
    'report() should not render the deferred/descoped v1 sections (Wait Event Summary, Lock Contention, Role Configuration Changes)'
);
SELECT ok(
    pgfr_analyze.report(interval '1 hour') ~ '# pg_flight_recorder Report',
    'report(interval) should render the same top-level header as report(timestamptz, timestamptz)'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    length(pgfr_analyze.report(:'ref_t_ref'::timestamptz - interval '1 hour', :'ref_t_ref'::timestamptz)) > 0,
    'report() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
