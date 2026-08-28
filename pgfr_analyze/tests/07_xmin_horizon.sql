-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- xmin_horizon_history(), current_xmin_horizon_holder()
-- =============================================================================
-- pg_stat_activity always has at least one real candidate (this session's
-- own backend), so these use real captured activity rather than manufactured
-- rows. Window bounds use clock_timestamp(), not now(): now() freezes at
-- transaction start, which is before a capture made later in the same
-- transaction, and would silently exclude it from a BETWEEN window.

BEGIN;
SELECT plan(10);

SELECT has_function('pgfr_analyze', 'xmin_horizon_history', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.xmin_horizon_history should exist');
SELECT has_function('pgfr_analyze', 'current_xmin_horizon_holder', 'Function pgfr_analyze.current_xmin_horizon_holder should exist');

SELECT clock_timestamp() AS t0 \gset before_
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture pg_stat_activity');
SELECT clock_timestamp() AS t1 \gset after_

-- ---------------------------------------------------------------------------
-- current_xmin_horizon_holder(): this session's own backend is always a
-- valid candidate, and it's the only source with real data in a bare
-- container (no replication slots, no prepared transactions).
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.current_xmin_horizon_holder()),
    1,
    'current_xmin_horizon_holder() should return exactly one row'
);
SELECT is(
    (SELECT source FROM pgfr_analyze.current_xmin_horizon_holder()),
    'activity',
    'current_xmin_horizon_holder() should identify activity as the only real candidate source'
);
SELECT ok(
    (SELECT xmin_age FROM pgfr_analyze.current_xmin_horizon_holder()) >= 0,
    'current_xmin_horizon_holder() should report a non-negative xmin_age'
);
SELECT ok(
    (SELECT holder ? 'pid' FROM pgfr_analyze.current_xmin_horizon_holder()),
    'current_xmin_horizon_holder() should carry the full captured row as holder, keyed by column name'
);

-- ---------------------------------------------------------------------------
-- xmin_horizon_history(): the same real capture should show up as the
-- worst (only) activity observation within the bracketing window.
-- ---------------------------------------------------------------------------
SELECT ok(
    (SELECT count(*)::int FROM pgfr_analyze.xmin_horizon_history(:'before_t0'::timestamptz, :'after_t1'::timestamptz) WHERE source = 'activity') > 0,
    'xmin_horizon_history() should find an activity observation inside the bracketing window'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.xmin_horizon_history(:'before_t0'::timestamptz - interval '1 hour', :'before_t0'::timestamptz - interval '30 minutes')),
    0,
    'xmin_horizon_history() should find nothing in a window before any capture existed'
);

-- ---------------------------------------------------------------------------
-- Neither function should write anywhere.
-- ---------------------------------------------------------------------------
SAVEPOINT analyze_readonly;
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.current_xmin_horizon_holder()) >= 0,
    'current_xmin_horizon_holder() should execute successfully inside a hard READ ONLY transaction'
);
ROLLBACK TO SAVEPOINT analyze_readonly;

SELECT * FROM finish();
ROLLBACK;
