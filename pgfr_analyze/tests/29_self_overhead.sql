-- =============================================================================
-- pgfr_analyze pgTAP Tests: self_overhead() observer-effect budget (Issue #103)
-- =============================================================================
-- The recorder measures its own cost from its own tables. These tests assert
-- the function's shape, that every figure carries units and a reproducible
-- method, and that the always-computable figures actually compute.
-- =============================================================================

BEGIN;
SELECT plan(7);

SELECT has_function('pgfr_analyze', 'self_overhead', 'self_overhead() exists');

SELECT lives_ok(
    $$SELECT metric, value, units, method FROM pgfr_analyze.self_overhead()$$,
    'self_overhead() executes and returns the expected columns');

-- The four core figures are always present (pgss_time_share only when
-- pg_stat_statements is installed, so >= 4 rather than an exact count).
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.self_overhead()) >= 4,
    'at least the four core overhead figures are reported');

SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.self_overhead()
     WHERE metric IN ('snapshot_ms_per_tick', 'sample_ms_per_tick',
                      'recorder_block_share', 'storage_bytes')),
    4,
    'the four core metrics are all present by name');

-- Storage is measurable on any install: the recorder's own tables exist.
SELECT ok(
    (SELECT value > 0 FROM pgfr_analyze.self_overhead()
     WHERE metric = 'storage_bytes'),
    'storage_bytes reports a positive footprint');

SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.self_overhead()
     WHERE units IS NULL OR length(units) = 0),
    0,
    'every figure carries its units');

SELECT is(
    (SELECT count(*)::int FROM pgfr_analyze.self_overhead()
     WHERE method IS NULL OR length(method) < 20),
    0,
    'every figure carries a reproducible method statement');

SELECT * FROM finish();
ROLLBACK;
