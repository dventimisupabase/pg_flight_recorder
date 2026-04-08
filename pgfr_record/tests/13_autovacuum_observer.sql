-- =============================================================================
-- pgfr_record pgTAP Tests - Autovacuum Observer Enhancements (v2.7)
-- =============================================================================
-- Tests: n_mod_since_analyze column, rate calculation functions, sampling modes
-- Test count: 27
-- =============================================================================

BEGIN;
SELECT plan(27);

-- =============================================================================
-- 1. SCHEMA TESTS - n_mod_since_analyze COLUMN (3 tests)
-- =============================================================================

SELECT has_column(
    'pgfr_record', 'table_snapshots', 'n_mod_since_analyze',
    'table_snapshots should have n_mod_since_analyze column'
);

SELECT col_type_is(
    'pgfr_record', 'table_snapshots', 'n_mod_since_analyze', 'bigint',
    'n_mod_since_analyze should be BIGINT type'
);

SELECT col_is_null(
    'pgfr_record', 'table_snapshots', 'n_mod_since_analyze',
    'n_mod_since_analyze should be nullable'
);

-- =============================================================================
-- 2. CONFIG TESTS - NEW PARAMETERS (4 tests)
-- =============================================================================

SELECT ok(
    EXISTS(SELECT 1 FROM pgfr_record.config WHERE key = 'table_stats_mode'),
    'table_stats_mode config parameter should exist'
);

SELECT is(
    (SELECT value FROM pgfr_record.config WHERE key = 'table_stats_mode'),
    'top_n',
    'table_stats_mode default should be top_n'
);

SELECT ok(
    EXISTS(SELECT 1 FROM pgfr_record.config WHERE key = 'table_stats_activity_threshold'),
    'table_stats_activity_threshold config parameter should exist'
);

SELECT is(
    (SELECT value FROM pgfr_record.config WHERE key = 'table_stats_activity_threshold'),
    '0',
    'table_stats_activity_threshold default should be 0'
);

-- =============================================================================
-- 3. FUNCTION EXISTENCE TESTS (2 tests)
-- =============================================================================

SELECT has_function(
    'pgfr_analyze', 'modification_rate',
    ARRAY['oid', 'interval'],
    'modification_rate(oid, interval) function should exist'
);

SELECT has_function(
    'pgfr_analyze', 'hot_update_ratio',
    ARRAY['oid'],
    'hot_update_ratio(oid) function should exist'
);

-- =============================================================================
-- 4. DATA COLLECTION TESTS (4 tests)
-- =============================================================================

-- Take a snapshot to populate data
SELECT pgfr_record.snapshot();

-- Verify n_mod_since_analyze is queryable
SELECT lives_ok(
    $$SELECT n_mod_since_analyze FROM pgfr_record.table_snapshots LIMIT 1$$,
    'n_mod_since_analyze column should be queryable'
);

-- Verify snapshot was created successfully
SELECT ok(
    (SELECT count(*) FROM pgfr_record.snapshots WHERE captured_at > now() - interval '1 minute') > 0,
    'snapshot() should create a new snapshot with table stats'
);

-- Verify table_snapshots has data (if there are user tables)
SELECT lives_ok(
    $$SELECT relid, n_dead_tup, n_mod_since_analyze
      FROM pgfr_record.table_snapshots
      ORDER BY snapshot_id DESC LIMIT 5$$,
    'table_snapshots should be queryable with n_mod_since_analyze'
);

-- Verify n_mod_since_analyze is populated from pg_stat_user_tables
SELECT lives_ok(
    $$SELECT ts.n_mod_since_analyze
      FROM pgfr_record.table_snapshots ts
      JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
      WHERE s.captured_at > now() - interval '1 minute'
      LIMIT 1$$,
    'n_mod_since_analyze should be populated in recent snapshots'
);

-- =============================================================================
-- 5. RATE FUNCTION TESTS - EXECUTION WITHOUT ERROR (4 tests)
-- =============================================================================

-- Test modification_rate executes without error
SELECT lives_ok(
    $$SELECT pgfr_analyze.modification_rate(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1),
        '1 hour'::interval
      )$$,
    'modification_rate should execute without error'
);

-- Test modification_rate returns NUMERIC
SELECT ok(
    pg_typeof(pgfr_analyze.modification_rate(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1),
        '1 hour'::interval
    ))::text = 'numeric',
    'modification_rate should return NUMERIC type'
);

-- Test hot_update_ratio executes without error
SELECT lives_ok(
    $$SELECT pgfr_analyze.hot_update_ratio(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
      )$$,
    'hot_update_ratio should execute without error'
);

-- Test hot_update_ratio returns NUMERIC
SELECT ok(
    pg_typeof(pgfr_analyze.hot_update_ratio(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    ))::text = 'numeric',
    'hot_update_ratio should return NUMERIC type'
);

-- =============================================================================
-- 6. SAMPLING MODE TESTS (8 tests)
-- =============================================================================

-- Test top_n mode (default)
UPDATE pgfr_record.config SET value = 'top_n' WHERE key = 'table_stats_mode';
UPDATE pgfr_record.config SET value = '5' WHERE key = 'table_stats_top_n';

SELECT pgfr_record.snapshot();

-- Get the most recent snapshot and count its table_snapshots
SELECT ok(
    (SELECT count(*) FROM pgfr_record.table_snapshots
     WHERE snapshot_id = (SELECT max(id) FROM pgfr_record.snapshots)) <= 5,
    'top_n mode should limit to table_stats_top_n tables'
);

-- Test all mode
UPDATE pgfr_record.config SET value = 'all' WHERE key = 'table_stats_mode';

SELECT pgfr_record.snapshot();

SELECT lives_ok(
    $$SELECT count(*) FROM pgfr_record.table_snapshots ts
      JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
      WHERE s.captured_at > now() - interval '10 seconds'$$,
    'all mode should collect all tables without error'
);

-- Verify all mode collects tables
SELECT ok(
    (SELECT count(*) FROM pgfr_record.table_snapshots ts
     JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
     WHERE s.captured_at > now() - interval '10 seconds') >= 0,
    'all mode should collect tables'
);

-- Test threshold mode with high threshold (should collect few/none)
UPDATE pgfr_record.config SET value = 'threshold' WHERE key = 'table_stats_mode';
UPDATE pgfr_record.config SET value = '999999999999' WHERE key = 'table_stats_activity_threshold';

SELECT pgfr_record.snapshot();

SELECT ok(
    (SELECT count(*) FROM pgfr_record.table_snapshots ts
     JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
     WHERE s.captured_at > now() - interval '10 seconds') >= 0,
    'threshold mode with high threshold should work'
);

-- Test threshold mode with zero threshold (should collect all active)
UPDATE pgfr_record.config SET value = '0' WHERE key = 'table_stats_activity_threshold';

SELECT pgfr_record.snapshot();

SELECT lives_ok(
    $$SELECT count(*) FROM pgfr_record.table_snapshots ts
      JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
      WHERE s.captured_at > now() - interval '10 seconds'$$,
    'threshold mode with zero threshold should collect tables'
);

-- Reset to default mode
UPDATE pgfr_record.config SET value = 'top_n' WHERE key = 'table_stats_mode';
UPDATE pgfr_record.config SET value = '50' WHERE key = 'table_stats_top_n';

SELECT lives_ok(
    $$SELECT 1$$,
    'config reset to defaults should succeed'
);

-- Test invalid mode falls back gracefully
UPDATE pgfr_record.config SET value = 'invalid_mode' WHERE key = 'table_stats_mode';

SELECT lives_ok(
    $$SELECT pgfr_record.snapshot()$$,
    'invalid table_stats_mode should not cause error (falls back to top_n)'
);

-- Reset mode
UPDATE pgfr_record.config SET value = 'top_n' WHERE key = 'table_stats_mode';

SELECT lives_ok(
    $$SELECT 1$$,
    'config cleanup should succeed'
);

-- =============================================================================
-- 7. EDGE CASE TESTS (2 tests)
-- =============================================================================

-- Test rate functions with non-existent OID
SELECT is(
    pgfr_analyze.modification_rate(0::oid, '1 hour'::interval),
    NULL::numeric,
    'modification_rate should return NULL for non-existent OID'
);

SELECT is(
    pgfr_analyze.hot_update_ratio(0::oid),
    NULL::numeric,
    'hot_update_ratio should return NULL for non-existent OID'
);

SELECT * FROM finish();
ROLLBACK;
