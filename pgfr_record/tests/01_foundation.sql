-- =============================================================================
-- pgfr_record pgTAP Tests - Foundation
-- =============================================================================
-- Tests: Installation verification, function existence, core functionality
-- Sections: 1, 2, 3
-- Test count: 50
-- =============================================================================

BEGIN;
SELECT plan(50);

-- =============================================================================
-- 1. INSTALLATION VERIFICATION (19 tests)
-- =============================================================================

-- Test schema exists
SELECT has_schema('pgfr_record', 'Schema pgfr_record should exist');

-- Test all 14 tables exist (snapshots + ring buffers + aggregates + config + collection_stats)
SELECT has_table('pgfr_record', 'snapshots', 'Table pgfr_record.snapshots should exist');
SELECT has_table('pgfr_record', 'replication_snapshots', 'Table pgfr_record.replication_snapshots should exist');
SELECT has_table('pgfr_record', 'statement_snapshots', 'Table pgfr_record.statement_snapshots should exist');
-- Ring buffers (UNLOGGED)
SELECT skip('Assertion retired with the legacy 120-slot ring');
SELECT skip('Assertion retired with the legacy 120-slot ring');
SELECT skip('Assertion retired with the legacy 120-slot ring');
SELECT skip('Assertion retired with the legacy 120-slot ring');
-- Aggregates (REGULAR/durable)
SELECT has_table('pgfr_record', 'wait_event_aggregates', 'Aggregates: Table pgfr_record.wait_event_aggregates should exist');
SELECT has_table('pgfr_record', 'lock_aggregates', 'Aggregates: Table pgfr_record.lock_aggregates should exist');
SELECT has_table('pgfr_record', 'activity_aggregates', 'Aggregates: Table pgfr_record.activity_aggregates should exist');
-- Raw archives (REGULAR/durable)
SELECT has_table('pgfr_record', 'activity_samples_archive', 'Raw archives: Table pgfr_record.activity_samples_archive should exist');
SELECT has_table('pgfr_record', 'lock_samples_archive', 'Raw archives: Table pgfr_record.lock_samples_archive should exist');
SELECT has_table('pgfr_record', 'wait_samples_archive', 'Raw archives: Table pgfr_record.wait_samples_archive should exist');
-- Config and monitoring
SELECT has_table('pgfr_record', 'config', 'Table pgfr_record.config should exist');
SELECT has_table('pgfr_record', 'collection_stats', 'P0 Safety: Table pgfr_record.collection_stats should exist');

-- Test Foreign Keys (Ring buffer child tables reference master samples_ring)
SELECT skip('Assertion retired with the legacy 120-slot ring');

SELECT skip('Assertion retired with the legacy 120-slot ring');

SELECT skip('Assertion retired with the legacy 120-slot ring');

-- Test all 6 views exist
SELECT has_view('pgfr_record', 'deltas', 'View pgfr_record.deltas should exist');
SELECT has_view('pgfr_record', 'recent_waits', 'View pgfr_record.recent_waits should exist');

-- =============================================================================
-- 2. FUNCTION EXISTENCE (25 tests)
-- =============================================================================

SELECT has_function('pgfr_record', '_pg_version', 'Function pgfr_record._pg_version should exist');
SELECT has_function('pgfr_record', '_get_config', 'Function pgfr_record._get_config should exist');
SELECT has_function('pgfr_record', '_has_pg_stat_statements', 'Function pgfr_record._has_pg_stat_statements should exist');
SELECT has_function('pgfr_record', '_pretty_bytes', 'Function pgfr_record._pretty_bytes should exist');
SELECT has_function('pgfr_record', '_check_circuit_breaker', 'P0 Safety: Function pgfr_record._check_circuit_breaker should exist');
SELECT has_function('pgfr_record', '_record_collection_start', 'P0 Safety: Function pgfr_record._record_collection_start should exist');
SELECT has_function('pgfr_record', '_record_collection_end', 'P0 Safety: Function pgfr_record._record_collection_end should exist');
SELECT has_function('pgfr_record', '_record_collection_skip', 'P0 Safety: Function pgfr_record._record_collection_skip should exist');
SELECT has_function('pgfr_record', '_check_schema_size', 'P1 Safety: Function pgfr_record._check_schema_size should exist');
SELECT has_function('pgfr_record', 'snapshot', 'Function pgfr_record.snapshot should exist');
SELECT has_function('pgfr_record', 'sample_ring', 'Function pgfr_record.sample_ring should exist');
SELECT has_function('pgfr_analyze', 'anomaly_report', 'Function pgfr_analyze.anomaly_report should exist');
SELECT has_function('pgfr_analyze', 'summary_report', 'Function pgfr_analyze.summary_report should exist');
SELECT has_function('pgfr_record', 'get_mode', 'Function pgfr_record.get_mode should exist');
SELECT has_function('pgfr_record', 'set_mode', 'Function pgfr_record.set_mode should exist');
SELECT has_function('pgfr_record', 'cleanup', 'Function pgfr_record.cleanup should exist');
-- Ring buffer functions
SELECT has_function('pgfr_record', 'flush_ring_to_aggregates', 'Aggregates: Function pgfr_record.flush_ring_to_aggregates should exist');
SELECT has_function('pgfr_record', 'archive_ring_samples', 'Raw archives: Function pgfr_record.archive_ring_samples should exist');
SELECT has_function('pgfr_record', 'cleanup_aggregates', 'Cleanup: Function pgfr_record.cleanup_aggregates should exist');

-- =============================================================================
-- 3. CORE FUNCTIONALITY (10 tests)
-- =============================================================================

-- Test snapshot() function works
SELECT lives_ok(
    $$SELECT pgfr_record.snapshot()$$,
    'snapshot() function should execute without error'
);

-- Verify snapshot was captured
SELECT ok(
    (SELECT count(*) FROM pgfr_record.snapshots) >= 1,
    'At least one snapshot should be captured'
);

-- Test sample() function works
SELECT lives_ok(
    $$SELECT pgfr_record.sample_ring()$$,
    'sample() function should execute without error'
);

-- Verify the v2 ring is queryable. We can't assert that sample_ring()
-- wrote rows because in a single-backend test container all other
-- backends are filtered out (sample_ring excludes pg_backend_pid()).
SELECT lives_ok(
    $$SELECT 1 FROM pgfr_record.wait_samples LIMIT 1$$,
    'v2 ring (wait_samples) should be queryable after sample_ring()'
);

-- Test wait_samples_ring captured
SELECT skip('Assertion retired with the legacy 120-slot ring');

-- Test activity_samples_ring captured
SELECT skip('Assertion retired with the legacy 120-slot ring');

-- Test version detection works
SELECT ok(
    pgfr_record._pg_version() >= 15,
    'PostgreSQL version should be 15 or higher'
);

-- Test pg_stat_statements detection
SELECT ok(
    pgfr_record._has_pg_stat_statements() IS NOT NULL,
    'pg_stat_statements detection should work'
);

-- Test pretty bytes formatting
SELECT is(
    pgfr_record._pretty_bytes(1024),
    '1.00 KB',
    'Pretty bytes should format correctly'
);

-- Test config retrieval
SELECT is(
    pgfr_record._get_config('mode', 'normal'),
    'normal',
    'Config retrieval should work with defaults'
);

SELECT * FROM finish();
ROLLBACK;
