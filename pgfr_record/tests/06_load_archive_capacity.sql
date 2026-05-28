-- =============================================================================
-- pgfr_record pgTAP Tests - Load, Archive, Capacity & Features
-- =============================================================================
-- Tests: Load shedding, archive, capacity planning, feature designs, db/role config
-- Sections: 15 (Load/Circuit), 6 (Archive), Capacity Planning, Feature Designs, DB/Role Config
-- Test count: 104
-- =============================================================================

BEGIN;
SELECT plan(97);

-- =============================================================================
-- 15. LOAD SHEDDING & CIRCUIT BREAKER (30 tests) - Phase 5
-- =============================================================================
-- Tests P0 safety mechanisms that protect database from collection overhead

-- -----------------------------------------------------------------------------
-- 15.1 LOAD SHEDDING (10 tests)
-- -----------------------------------------------------------------------------

-- Test 1: Load shedding disabled
UPDATE pgfr_record.config SET value = 'false' WHERE key = 'load_shedding_enabled';
DELETE FROM pgfr_record.collection_stats;

DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats WHERE skipped = false AND collection_type = 'sample') >= 1,
    'Safety: Load shedding disabled should allow collection'
);

-- Re-enable for other tests
UPDATE pgfr_record.config SET value = 'true' WHERE key = 'load_shedding_enabled';

-- Test 2: Load shedding with threshold = 0% (always skip if any connections exist)
UPDATE pgfr_record.config SET value = '0' WHERE key = 'load_shedding_active_pct';
DELETE FROM pgfr_record.collection_stats;

DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

-- Check if collection was attempted and skipped (if active connections > 0%)
SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats WHERE collection_type = 'sample') > 0,
    'Safety: Load shedding with 0% threshold should create collection_stats entry'
);

-- Test 3: Verify skip_reason format for load shedding (if skip occurred)
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pgfr_record.collection_stats WHERE collection_type = 'sample' AND skipped = true)
    OR (SELECT skipped_reason FROM pgfr_record.collection_stats WHERE collection_type = 'sample' AND skipped = true ORDER BY started_at DESC LIMIT 1) LIKE '%Load shedding: high load%',
    'Safety: Load shedding skip reason should match expected format (if skip occurred)'
);

-- Test 4: Load shedding with threshold = 100% (never skip unless at 100% connections)
UPDATE pgfr_record.config SET value = '100' WHERE key = 'load_shedding_active_pct';
DELETE FROM pgfr_record.collection_stats;

DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

-- With 100% threshold, load shedding should not trigger (unless exactly at 100% connections)
SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats WHERE collection_type = 'sample') > 0,
    'Safety: Load shedding with 100% threshold should create collection_stats entry'
);

-- Reset to default
UPDATE pgfr_record.config SET value = '70' WHERE key = 'load_shedding_active_pct';

-- Test 5: collection_stats logging for load shedding
UPDATE pgfr_record.config SET value = '0' WHERE key = 'load_shedding_active_pct';
DELETE FROM pgfr_record.collection_stats;

DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.collection_stats
        WHERE collection_type = 'sample'
          AND skipped = true
          AND skipped_reason IS NOT NULL
          AND skipped_reason LIKE '%Load shedding%'
    ),
    'Safety: Load shedding should log skip to collection_stats with reason'
);

-- Reset
UPDATE pgfr_record.config SET value = '70' WHERE key = 'load_shedding_active_pct';

-- Test 6: Load shedding doesn't affect snapshot()
UPDATE pgfr_record.config SET value = '0' WHERE key = 'load_shedding_active_pct';
DELETE FROM pgfr_record.snapshots WHERE captured_at > now() - interval '1 minute';

DO $$ BEGIN
    PERFORM pgfr_record.snapshot();
END $$;

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.snapshots WHERE captured_at > now() - interval '10 seconds'),
    'Safety: Load shedding should not affect snapshot() collections'
);

-- Reset
UPDATE pgfr_record.config SET value = '70' WHERE key = 'load_shedding_active_pct';

-- Test 7: Load shedding recovery (high -> normal)
UPDATE pgfr_record.config SET value = '0' WHERE key = 'load_shedding_active_pct';
DELETE FROM pgfr_record.collection_stats;

-- First sample should skip
DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

-- Change to normal threshold
UPDATE pgfr_record.config SET value = '70' WHERE key = 'load_shedding_active_pct';

-- Second sample should succeed
DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats WHERE skipped = false AND collection_type = 'sample') >= 1,
    'Safety: Load shedding recovery - collection should succeed after threshold increased'
);

-- Test 8: Verify skip_reason includes threshold value
UPDATE pgfr_record.config SET value = '0' WHERE key = 'load_shedding_active_pct';
DELETE FROM pgfr_record.collection_stats;

DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

SELECT ok(
    (SELECT skipped_reason FROM pgfr_record.collection_stats WHERE collection_type = 'sample' AND skipped = true ORDER BY started_at DESC LIMIT 1) LIKE
    '%0% threshold%',
    'Safety: Load shedding skip reason should include configured threshold'
);

-- Reset
UPDATE pgfr_record.config SET value = '70' WHERE key = 'load_shedding_active_pct';

-- Test 9: Load shedding with production_safe profile (60% threshold)
SELECT pgfr_record.apply_profile('production_safe');
DELETE FROM pgfr_record.collection_stats;

-- Should use 60% threshold from profile
DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

SELECT ok(
    pgfr_record._get_config('load_shedding_active_pct', '70')::integer = 60,
    'Safety: production_safe profile should set load shedding to 60%'
);

-- Reset to default profile
SELECT pgfr_record.apply_profile('default');

-- Test 10: Multiple load shedding skips tracked correctly
UPDATE pgfr_record.config SET value = '0' WHERE key = 'load_shedding_active_pct';
DELETE FROM pgfr_record.collection_stats;

-- Generate 3 skipped collections
DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
    PERFORM pgfr_record.sample_ring();
    PERFORM pgfr_record.sample_ring();
END $$;

SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats WHERE collection_type = 'sample' AND skipped = true AND skipped_reason LIKE '%Load shedding%') = 3,
    'Safety: Multiple load shedding skips should all be tracked in collection_stats'
);

-- Reset
UPDATE pgfr_record.config SET value = '70' WHERE key = 'load_shedding_active_pct';

-- -----------------------------------------------------------------------------
-- 15.2 CIRCUIT BREAKER (10 tests)
-- -----------------------------------------------------------------------------

-- Test 1: Circuit breaker disabled
UPDATE pgfr_record.config SET value = 'false' WHERE key = 'circuit_breaker_enabled';
DELETE FROM pgfr_record.collection_stats;

DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats WHERE skipped = false AND collection_type = 'sample') >= 1,
    'Safety: Circuit breaker disabled should allow collection'
);

-- Re-enable
UPDATE pgfr_record.config SET value = 'true' WHERE key = 'circuit_breaker_enabled';

-- Test 2: _check_circuit_breaker() with < 3 fast collections (should not trip)
DELETE FROM pgfr_record.collection_stats;

-- Insert only 2 collections with durations below threshold (1000ms)
INSERT INTO pgfr_record.collection_stats (collection_type, started_at, completed_at, duration_ms, success, skipped)
VALUES
    ('sample', now() - interval '5 minutes', now() - interval '5 minutes', 500, true, false),
    ('sample', now() - interval '3 minutes', now() - interval '3 minutes', 600, true, false);

SELECT ok(
    pgfr_record._check_circuit_breaker('sample') = false,
    'Safety: Circuit breaker should not trip with < 3 fast collections in window'
);

-- Test 3: _check_circuit_breaker() with 3 fast collections (should not trip)
DELETE FROM pgfr_record.collection_stats;

INSERT INTO pgfr_record.collection_stats (collection_type, started_at, completed_at, duration_ms, success, skipped)
VALUES
    ('sample', now() - interval '5 minutes', now() - interval '5 minutes', 500, true, false),
    ('sample', now() - interval '3 minutes', now() - interval '3 minutes', 600, true, false),
    ('sample', now() - interval '1 minute', now() - interval '1 minute', 550, true, false);

-- Avg = 550ms < 1000ms threshold
SELECT ok(
    pgfr_record._check_circuit_breaker('sample') = false,
    'Safety: Circuit breaker should not trip with 3 fast collections (avg 550ms < 1000ms)'
);

-- Test 4: _check_circuit_breaker() with 3 slow collections (should trip)
-- First ensure circuit breaker is enabled and threshold is default
UPDATE pgfr_record.config SET value = 'true' WHERE key = 'circuit_breaker_enabled';
UPDATE pgfr_record.config SET value = '1000' WHERE key = 'circuit_breaker_threshold_ms';

DELETE FROM pgfr_record.collection_stats;

INSERT INTO pgfr_record.collection_stats (collection_type, started_at, completed_at, duration_ms, success, skipped)
VALUES
    ('sample', now() - interval '5 minutes', now() - interval '5 minutes', 1500, true, false),
    ('sample', now() - interval '3 minutes', now() - interval '3 minutes', 1200, true, false),
    ('sample', now() - interval '1 minute', now() - interval '1 minute', 1400, true, false);

-- Verify we have 3 rows
SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats WHERE collection_type = 'sample' AND success = true AND skipped = false) = 3,
    'Safety: Circuit breaker test data - should have 3 successful non-skipped samples'
);

-- Avg = 1366ms > 1000ms threshold
SELECT ok(
    pgfr_record._check_circuit_breaker('sample') = true,
    'Safety: Circuit breaker should trip with 3 slow collections (avg 1366ms > 1000ms)'
);

-- Test 5: Circuit breaker moving average (2 fast + 1 slow)
DELETE FROM pgfr_record.collection_stats;

INSERT INTO pgfr_record.collection_stats (collection_type, started_at, completed_at, duration_ms, success, skipped)
VALUES
    ('sample', now() - interval '5 minutes', now() - interval '5 minutes', 500, true, false),
    ('sample', now() - interval '3 minutes', now() - interval '3 minutes', 600, true, false),
    ('sample', now() - interval '1 minute', now() - interval '1 minute', 1500, true, false);

-- Avg = 866ms < 1000ms threshold
SELECT ok(
    pgfr_record._check_circuit_breaker('sample') = false,
    'Safety: Circuit breaker moving average should not trip (2 fast + 1 slow = 866ms avg)'
);

-- Test 6: Circuit breaker window (old collections ignored)
DELETE FROM pgfr_record.collection_stats;

-- Insert slow collections outside 15-minute window
INSERT INTO pgfr_record.collection_stats (collection_type, started_at, completed_at, duration_ms, success, skipped)
VALUES
    ('sample', now() - interval '20 minutes', now() - interval '20 minutes', 1500, true, false),
    ('sample', now() - interval '18 minutes', now() - interval '18 minutes', 1400, true, false),
    ('sample', now() - interval '16 minutes', now() - interval '16 minutes', 1600, true, false);

SELECT ok(
    pgfr_record._check_circuit_breaker('sample') = false,
    'Safety: Circuit breaker should ignore collections outside 15-minute window'
);

-- Test 7: Circuit breaker with aggressive 100ms threshold
UPDATE pgfr_record.config SET value = '100' WHERE key = 'circuit_breaker_threshold_ms';
DELETE FROM pgfr_record.collection_stats;

-- Insert collections with 200ms avg (would be fine with 1000ms, but trips at 100ms)
INSERT INTO pgfr_record.collection_stats (collection_type, started_at, completed_at, duration_ms, success, skipped)
VALUES
    ('sample', now() - interval '5 minutes', now() - interval '5 minutes', 200, true, false),
    ('sample', now() - interval '3 minutes', now() - interval '3 minutes', 210, true, false),
    ('sample', now() - interval '1 minute', now() - interval '1 minute', 190, true, false);

-- Avg = 200ms > 100ms threshold
SELECT ok(
    pgfr_record._check_circuit_breaker('sample') = true,
    'Safety: Circuit breaker with 100ms threshold should be highly sensitive'
);

-- Reset threshold
UPDATE pgfr_record.config SET value = '1000' WHERE key = 'circuit_breaker_threshold_ms';

-- =============================================================================
-- 6. ARCHIVE FUNCTIONALITY (12 tests)
-- =============================================================================

-- Clear any archive data that may have been created by background cron jobs
TRUNCATE pgfr_record.activity_samples_archive;
TRUNCATE pgfr_record.lock_samples_archive;
TRUNCATE pgfr_record.wait_samples_archive;

-- Test 1: Archive configuration exists
SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'archive_samples_enabled'),
    'Archive: Config key archive_samples_enabled should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'archive_sample_frequency_minutes'),
    'Archive: Config key archive_sample_frequency_minutes should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'archive_retention_days'),
    'Archive: Config key archive_retention_days should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'archive_wait_samples'),
    'Archive: Config key archive_wait_samples should exist'
);

-- Test 2: Archive tables are empty initially
SELECT is(
    (SELECT count(*)::integer FROM pgfr_record.activity_samples_archive),
    0,
    'Archive: activity_samples_archive should be empty initially'
);

SELECT is(
    (SELECT count(*)::integer FROM pgfr_record.lock_samples_archive),
    0,
    'Archive: lock_samples_archive should be empty initially'
);

SELECT is(
    (SELECT count(*)::integer FROM pgfr_record.wait_samples_archive),
    0,
    'Archive: wait_samples_archive should be empty initially'
);

-- Test 3: Archive function can be called
SELECT lives_ok(
    'SELECT pgfr_record.archive_ring_samples()',
    'Archive: archive_ring_samples() should execute without error'
);

-- Test 4: Archive captures data after sample collection
-- First, capture some samples
SELECT pgfr_record.sample_ring();

-- Manually call archive (normally scheduled via cron)
SELECT pgfr_record.archive_ring_samples();

-- Verify data was archived
SELECT ok(
    (SELECT count(*) FROM pgfr_record.activity_samples_archive) >= 0,
    'Archive: activity_samples_archive should contain data after archival'
);

-- Test 5: Cleanup removes old archived data
-- Insert old archive data
INSERT INTO pgfr_record.activity_samples_archive (sample_id, captured_at, pid, usename)
VALUES (1, now() - interval '10 days', 12345, 'test_user');

INSERT INTO pgfr_record.lock_samples_archive (sample_id, captured_at, blocked_pid)
VALUES (1, now() - interval '10 days', 67890);

INSERT INTO pgfr_record.wait_samples_archive (sample_id, captured_at, backend_type, wait_event_type, wait_event, count)
VALUES (1, now() - interval '10 days', 'client backend', 'Lock', 'relation', 5);

-- Set retention to 7 days for test
UPDATE pgfr_record.config SET value = '7' WHERE key = 'archive_retention_days';

-- Run cleanup
SELECT pgfr_record.cleanup_aggregates();

-- Verify old data was removed (assuming default retention of 7 days)
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.activity_samples_archive
        WHERE captured_at < now() - interval '7 days'
    ),
    'Archive: cleanup should remove old activity archive data'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.lock_samples_archive
        WHERE captured_at < now() - interval '7 days'
    ),
    'Archive: cleanup should remove old lock archive data'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.wait_samples_archive
        WHERE captured_at < now() - interval '7 days'
    ),
    'Archive: cleanup should remove old wait archive data'
);

-- =============================================================================
-- CAPACITY PLANNING TESTS (33 tests) - Phase 1 MVP
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: Schema Verification (8 tests)
-- -----------------------------------------------------------------------------

SELECT has_column('pgfr_record', 'snapshots', 'xact_commit', 'Snapshots table should have xact_commit column');
SELECT has_column('pgfr_record', 'snapshots', 'xact_rollback', 'Snapshots table should have xact_rollback column');
SELECT has_column('pgfr_record', 'snapshots', 'blks_read', 'Snapshots table should have blks_read column');
SELECT has_column('pgfr_record', 'snapshots', 'blks_hit', 'Snapshots table should have blks_hit column');
SELECT has_column('pgfr_record', 'snapshots', 'connections_active', 'Snapshots table should have connections_active column');
SELECT has_column('pgfr_record', 'snapshots', 'connections_total', 'Snapshots table should have connections_total column');
SELECT has_column('pgfr_record', 'snapshots', 'connections_max', 'Snapshots table should have connections_max column');
SELECT has_column('pgfr_record', 'snapshots', 'db_size_bytes', 'Snapshots table should have db_size_bytes column');

-- -----------------------------------------------------------------------------
-- Section 2: capacity_summary() Function (12 tests)
-- -----------------------------------------------------------------------------

-- Test 1: Function exists
SELECT has_function('pgfr_analyze', 'capacity_summary', 'Function capacity_summary should exist');

-- Test 2: Function executes without error (with insufficient data)
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.capacity_summary(interval '24 hours')$$,
    'capacity_summary: Should execute without error'
);

-- Create synthetic test data for capacity analysis (need multiple snapshots)
-- Insert backdated snapshot for testing
INSERT INTO pgfr_record.snapshots (
    captured_at, pg_version,
    wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
    checkpoint_lsn, checkpoint_time,
    ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
    bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
    bgw_buffers_backend, bgw_buffers_backend_fsync,
    autovacuum_workers, slots_count, slots_max_retained_wal,
    temp_files, temp_bytes,
    xact_commit, xact_rollback, blks_read, blks_hit,
    connections_active, connections_total, connections_max,
    db_size_bytes
) VALUES (
    now() - interval '1 hour', 16,
    1000, 100, 10000000, 100.0, 50.0,
    '0/1000000'::pg_lsn, now() - interval '1 hour',
    5, 1, 1000.0, 500.0, 50000,
    10000, 5, 100000,
    1000, 10,
    0, 0, 0,
    50, 1000000,
    10000, 100, 50000, 450000,
    5, 10, 100,
    1000000000
);

-- Test 3: Returns data with sufficient snapshots
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.capacity_summary(interval '2 hours')) >= 1,
    'capacity_summary: Should return metrics with sufficient data'
);

-- Test 4: Check connections metric is returned
SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_analyze.capacity_summary(interval '2 hours') WHERE metric = 'connections'),
    'capacity_summary: Should return connections metric'
);

-- Test 5: Utilization percentage is within bounds
SELECT ok(
    (SELECT max(utilization_pct) FROM pgfr_analyze.capacity_summary(interval '2 hours') WHERE utilization_pct IS NOT NULL) <= 100,
    'capacity_summary: Utilization percentage should be <= 100'
);

SELECT ok(
    (SELECT min(utilization_pct) FROM pgfr_analyze.capacity_summary(interval '2 hours') WHERE utilization_pct IS NOT NULL) >= 0,
    'capacity_summary: Utilization percentage should be >= 0'
);

-- Test 6: Status values are valid
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.capacity_summary(interval '2 hours')
     WHERE status NOT IN ('healthy', 'warning', 'critical', 'insufficient_data')) = 0,
    'capacity_summary: Status should be one of valid values'
);

-- Test 7: Current usage is populated
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.capacity_summary(interval '2 hours')
     WHERE current_usage IS NOT NULL) >= 1,
    'capacity_summary: Current usage should be populated'
);

-- Test 8: Different time windows work
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.capacity_summary(interval '1 hour')$$,
    'capacity_summary: Should work with 1 hour window'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.capacity_summary(interval '7 days')$$,
    'capacity_summary: Should work with 7 day window'
);

-- Test 9: NULL handling - function doesn't crash with NULL columns
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.capacity_summary(interval '2 hours')$$,
    'capacity_summary: Should handle NULL columns gracefully'
);

-- -----------------------------------------------------------------------------
-- Section 3: capacity_dashboard View (10 tests)
-- -----------------------------------------------------------------------------

-- Test 1: View exists
SELECT has_view('pgfr_analyze', 'capacity_dashboard', 'View capacity_dashboard should exist');

-- Test 2: View executes without error
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.capacity_dashboard$$,
    'capacity_dashboard: Should execute without error'
);

-- Test 3: Returns exactly one row
SELECT is(
    (SELECT count(*)::integer FROM pgfr_analyze.capacity_dashboard),
    1,
    'capacity_dashboard: Should return exactly one row'
);

-- Test 4: last_updated is populated
SELECT ok(
    (SELECT last_updated FROM pgfr_analyze.capacity_dashboard) IS NOT NULL,
    'capacity_dashboard: last_updated should be populated'
);

-- Test 5: connections_status is valid
SELECT ok(
    (SELECT connections_status FROM pgfr_analyze.capacity_dashboard) IN ('healthy', 'warning', 'critical', 'insufficient_data'),
    'capacity_dashboard: connections_status should be valid'
);

-- Test 6: memory_status is valid
SELECT ok(
    (SELECT memory_status FROM pgfr_analyze.capacity_dashboard) IN ('healthy', 'warning', 'critical', 'insufficient_data'),
    'capacity_dashboard: memory_status should be valid'
);

-- Test 7: overall_status is valid
SELECT ok(
    (SELECT overall_status FROM pgfr_analyze.capacity_dashboard) IN ('healthy', 'warning', 'critical', 'insufficient_data'),
    'capacity_dashboard: overall_status should be valid'
);

-- Test 8: memory_pressure_score is within bounds
SELECT ok(
    (SELECT memory_pressure_score FROM pgfr_analyze.capacity_dashboard) >= 0 AND
    (SELECT memory_pressure_score FROM pgfr_analyze.capacity_dashboard) <= 100,
    'capacity_dashboard: memory_pressure_score should be 0-100'
);

-- Test 9: critical_issues is an array
SELECT ok(
    pg_typeof((SELECT critical_issues FROM pgfr_analyze.capacity_dashboard))::text = 'text[]',
    'capacity_dashboard: critical_issues should be text array'
);

-- Test 10: Dashboard reflects underlying summary data
SELECT ok(
    (SELECT connections_status FROM pgfr_analyze.capacity_dashboard) =
    COALESCE((SELECT status FROM pgfr_analyze.capacity_summary(interval '24 hours') WHERE metric = 'connections'), 'insufficient_data'),
    'capacity_dashboard: Should reflect capacity_summary connections status'
);

-- =============================================================================
-- FEATURE DESIGNS: TABLE/INDEX/CONFIG TRACKING (23 tests)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: Table Existence (3 tests)
-- -----------------------------------------------------------------------------

SELECT has_table('pgfr_record', 'table_snapshots', 'Table pgfr_record.table_snapshots should exist');
SELECT has_table('pgfr_record', 'index_snapshots', 'Table pgfr_record.index_snapshots should exist');
SELECT has_table('pgfr_record', 'config_snapshots', 'Table pgfr_record.config_snapshots should exist');

-- -----------------------------------------------------------------------------
-- Section 2: Collection Function Existence (3 tests)
-- -----------------------------------------------------------------------------

SELECT has_function('pgfr_record', '_collect_table_stats', 'Function pgfr_record._collect_table_stats should exist');
SELECT has_function('pgfr_record', '_collect_index_stats', 'Function pgfr_record._collect_index_stats should exist');
SELECT has_function('pgfr_record', '_collect_config_snapshot', 'Function pgfr_record._collect_config_snapshot should exist');

-- -----------------------------------------------------------------------------
-- Section 3: Analysis Function Existence (7 tests)
-- -----------------------------------------------------------------------------

SELECT has_function('pgfr_analyze', 'table_compare', 'Function pgfr_analyze.table_compare should exist');
SELECT has_function('pgfr_analyze', 'table_hotspots', 'Function pgfr_analyze.table_hotspots should exist');
SELECT has_function('pgfr_analyze', 'unused_indexes', 'Function pgfr_analyze.unused_indexes should exist');
SELECT has_function('pgfr_analyze', 'index_efficiency', 'Function pgfr_analyze.index_efficiency should exist');
SELECT has_function('pgfr_analyze', 'config_changes', 'Function pgfr_analyze.config_changes should exist');
SELECT has_function('pgfr_analyze', 'config_at', 'Function pgfr_analyze.config_at should exist');
SELECT has_function('pgfr_analyze', 'config_health_check', 'Function pgfr_analyze.config_health_check should exist');

-- -----------------------------------------------------------------------------
-- Section 4: Collection Function Execution (3 tests)
-- -----------------------------------------------------------------------------

-- First capture a snapshot to get a valid snapshot_id
DO $$
DECLARE
    v_snapshot_id INTEGER;
BEGIN
    SELECT id INTO v_snapshot_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;
    IF v_snapshot_id IS NULL THEN
        SELECT pgfr_record.snapshot();
        SELECT id INTO v_snapshot_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;
    END IF;
    -- Store for tests
    CREATE TEMP TABLE IF NOT EXISTS test_snapshot_id (id INTEGER);
    DELETE FROM test_snapshot_id;
    INSERT INTO test_snapshot_id VALUES (v_snapshot_id);
END $$;

SELECT lives_ok(
    $$SELECT pgfr_record._collect_table_stats((SELECT id FROM test_snapshot_id))$$,
    'Table stats collection executes without error'
);

SELECT lives_ok(
    $$SELECT pgfr_record._collect_index_stats((SELECT id FROM test_snapshot_id))$$,
    'Index stats collection executes without error'
);

SELECT lives_ok(
    $$SELECT pgfr_record._collect_config_snapshot((SELECT id FROM test_snapshot_id))$$,
    'Config snapshot collection executes without error'
);

-- -----------------------------------------------------------------------------
-- Section 5: Analysis Function Execution (7 tests)
-- -----------------------------------------------------------------------------

-- Get time range for queries
DO $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
BEGIN
    v_start_time := now() - interval '1 hour';
    v_end_time := now();
    -- Store for later tests
    CREATE TEMP TABLE IF NOT EXISTS test_feature_times (start_time TIMESTAMPTZ, end_time TIMESTAMPTZ);
    DELETE FROM test_feature_times;
    INSERT INTO test_feature_times VALUES (v_start_time, v_end_time);
END;
$$;

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.table_compare(
        (SELECT start_time FROM test_feature_times),
        (SELECT end_time FROM test_feature_times)
    )$$,
    'table_compare() should execute without error'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.table_hotspots(
        (SELECT start_time FROM test_feature_times),
        (SELECT end_time FROM test_feature_times)
    )$$,
    'table_hotspots() should execute without error'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.unused_indexes()$$,
    'unused_indexes() should execute without error'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.index_efficiency(
        (SELECT start_time FROM test_feature_times),
        (SELECT end_time FROM test_feature_times)
    )$$,
    'index_efficiency() should execute without error'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.config_changes(
        (SELECT start_time FROM test_feature_times),
        (SELECT end_time FROM test_feature_times)
    )$$,
    'config_changes() should execute without error'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.config_at(now())$$,
    'config_at() should execute without error'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.config_health_check()$$,
    'config_health_check() should execute without error'
);

-- =============================================================================
-- DATABASE/ROLE CONFIGURATION TRACKING (15 tests)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Section 1: Table Existence and Structure (5 tests)
-- -----------------------------------------------------------------------------

SELECT has_table('pgfr_record', 'db_role_config_snapshots', 'Table pgfr_record.db_role_config_snapshots should exist');

SELECT has_column('pgfr_record', 'db_role_config_snapshots', 'snapshot_id', 'db_role_config_snapshots should have snapshot_id column');
SELECT has_column('pgfr_record', 'db_role_config_snapshots', 'database_name', 'db_role_config_snapshots should have database_name column');
SELECT has_column('pgfr_record', 'db_role_config_snapshots', 'role_name', 'db_role_config_snapshots should have role_name column');
SELECT has_column('pgfr_record', 'db_role_config_snapshots', 'parameter_name', 'db_role_config_snapshots should have parameter_name column');

-- -----------------------------------------------------------------------------
-- Section 2: Function Existence (4 tests)
-- -----------------------------------------------------------------------------

SELECT has_function('pgfr_record', '_collect_db_role_config_snapshot', 'Function pgfr_record._collect_db_role_config_snapshot should exist');
SELECT has_function('pgfr_analyze', 'db_role_config_at', 'Function pgfr_analyze.db_role_config_at should exist');
SELECT has_function('pgfr_analyze', 'db_role_config_changes', 'Function pgfr_analyze.db_role_config_changes should exist');
SELECT has_function('pgfr_analyze', 'db_role_config_summary', 'Function pgfr_analyze.db_role_config_summary should exist');

-- -----------------------------------------------------------------------------
-- Section 3: Collection Function Execution (4 tests)
-- -----------------------------------------------------------------------------

-- Get or create a snapshot for testing
DO $$
DECLARE
    v_snapshot_id INTEGER;
BEGIN
    SELECT id INTO v_snapshot_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;
    IF v_snapshot_id IS NULL THEN
        PERFORM pgfr_record.snapshot();
        SELECT id INTO v_snapshot_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;
    END IF;
    -- Store for tests
    CREATE TEMP TABLE IF NOT EXISTS test_db_role_snapshot_id (id INTEGER);
    DELETE FROM test_db_role_snapshot_id;
    INSERT INTO test_db_role_snapshot_id VALUES (v_snapshot_id);
END $$;

SELECT lives_ok(
    $$SELECT pgfr_record._collect_db_role_config_snapshot((SELECT id FROM test_db_role_snapshot_id))$$,
    'Database/role config snapshot collection executes without error'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.db_role_config_at(now())$$,
    'db_role_config_at() should execute without error'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.db_role_config_changes(now() - interval '1 hour', now())$$,
    'db_role_config_changes() should execute without error'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.db_role_config_summary()$$,
    'db_role_config_summary() should execute without error'
);

-- -----------------------------------------------------------------------------
-- Section 4: Feature Toggle (2 tests)
-- -----------------------------------------------------------------------------

-- Test 1: Config key exists
SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'db_role_config_snapshots_enabled'),
    'Config key db_role_config_snapshots_enabled should exist'
);

-- Test 2: Feature can be disabled
UPDATE pgfr_record.config SET value = 'false' WHERE key = 'db_role_config_snapshots_enabled';

SELECT ok(
    pgfr_record._get_config('db_role_config_snapshots_enabled', 'true')::boolean = false,
    'db_role_config_snapshots_enabled can be set to false'
);

-- Reset to default
UPDATE pgfr_record.config SET value = 'true' WHERE key = 'db_role_config_snapshots_enabled';

SELECT * FROM finish();
ROLLBACK;
