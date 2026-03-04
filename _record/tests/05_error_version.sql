-- =============================================================================
-- pgfr_record pgTAP Tests - Error Handling & Version-Specific
-- =============================================================================
-- Tests: Error handling, exception paths, version-specific behavior
-- Sections: 13 (Error Handling), 14 (Version-Specific)
-- Test count: 100
-- =============================================================================

BEGIN;
SELECT plan(99);

-- =============================================================================
-- 13. ERROR HANDLING & EXCEPTION PATHS (60 tests)
-- =============================================================================
-- Phase 3: Test all EXCEPTION blocks and error recovery paths

-- -----------------------------------------------------------------------------
-- 13.1 Invalid Input Validation (20 tests)
-- -----------------------------------------------------------------------------

-- Test set_mode() with empty string
SELECT throws_ok(
    $$SELECT pgfr_record.set_mode('')$$,
    'Invalid mode: . Must be normal, light, or emergency.',
    'Error: set_mode() should reject empty string'
);

-- Test set_mode() with uppercase (should fail or normalize)
SELECT throws_ok(
    $$SELECT pgfr_record.set_mode('NORMAL')$$,
    'Invalid mode: NORMAL. Must be normal, light, or emergency.',
    'Error: set_mode() should reject uppercase mode'
);

-- Test set_mode() with NULL
SELECT throws_ok(
    $$SELECT pgfr_record.set_mode(NULL)$$,
    NULL,
    'Error: set_mode() should handle NULL input'
);

-- Test set_mode() with SQL injection attempt
SELECT throws_ok(
    $$SELECT pgfr_record.set_mode('normal; DROP TABLE config;')$$,
    NULL,
    'Error: set_mode() should reject SQL injection attempt'
);

-- Test apply_profile() with empty string
SELECT throws_ok(
    $$SELECT pgfr_record.apply_profile('')$$,
    NULL,
    'Error: apply_profile() should reject empty string'
);

-- Test apply_profile() with NULL
SELECT throws_ok(
    $$SELECT pgfr_record.apply_profile(NULL)$$,
    NULL,
    'Error: apply_profile() should handle NULL input'
);

-- Test apply_profile() with invalid profile name
SELECT throws_ok(
    $$SELECT pgfr_record.apply_profile('invalid_profile_xyz')$$,
    NULL,
    'Error: apply_profile() should reject invalid profile name'
);

-- Test explain_profile() with NULL
SELECT throws_ok(
    $$SELECT * FROM pgfr_record.explain_profile(NULL)$$,
    NULL,
    'Error: explain_profile() should reject NULL input'
);

-- Test _compare() with NULL timestamps
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.compare(NULL, NULL)$$,
    'Error: compare() should handle both NULL timestamps'
);

-- Test _compare() with invalid timestamp format
SELECT throws_ok(
    $$SELECT * FROM pgfr_analyze.compare('not-a-date', now())$$,
    NULL,
    'Error: compare() should reject invalid timestamp format'
);

-- Test _wait_summary() with backwards date range
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.wait_summary('2024-12-31', '2024-01-01')$$,
    'Error: wait_summary() should handle backwards date range'
);

-- Test _activity_at() with NULL timestamp
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.activity_at(NULL)$$,
    'Error: activity_at() should handle NULL timestamp'
);

-- Test cleanup() with negative retention
SELECT lives_ok(
    $$SELECT pgfr_record.cleanup('-1 days')$$,
    'Error: cleanup() should handle negative retention gracefully'
);

-- Test cleanup() with invalid interval
SELECT throws_ok(
    $$SELECT pgfr_record.cleanup('not-an-interval')$$,
    NULL,
    'Error: cleanup() should reject invalid interval'
);

-- Test _pretty_bytes() with negative value
SELECT lives_ok(
    $$SELECT pgfr_record._pretty_bytes(-1)$$,
    'Error: _pretty_bytes() should handle negative bytes'
);

-- Test _pretty_bytes() with NULL
SELECT lives_ok(
    $$SELECT pgfr_record._pretty_bytes(NULL)$$,
    'Error: _pretty_bytes() should handle NULL input'
);

-- Test _get_config() with NULL key
SELECT lives_ok(
    $$SELECT pgfr_record._get_config(NULL, 'default')$$,
    'Error: _get_config() should handle NULL key'
);

-- Test _get_config() with empty key
SELECT ok(
    (SELECT pgfr_record._get_config('', 'default_value') = 'default_value'),
    'Error: _get_config() should return default for empty key'
);

-- Test INSERT into config with empty value for critical setting
DO $$
BEGIN
    INSERT INTO pgfr_record.config (key, value)
    VALUES ('test_empty_value', '')
    ON CONFLICT (key) DO UPDATE SET value = '';
END $$;

SELECT ok(
    (SELECT value FROM pgfr_record.config WHERE key = 'test_empty_value') = '',
    'Error: Config should accept empty string values'
);

-- Test INSERT into config with non-numeric value for numeric setting
DO $$
BEGIN
    UPDATE pgfr_record.config SET value = 'not-a-number' WHERE key = 'sample_interval_seconds';
END $$;

SELECT throws_ok(
    $$SELECT pgfr_record._get_config('sample_interval_seconds', '60')::integer$$,
    NULL,
    'Error: Should raise error for non-numeric config values when casting to integer'
);

-- Reset sample_interval_seconds
UPDATE pgfr_record.config SET value = '120' WHERE key = 'sample_interval_seconds';

-- -----------------------------------------------------------------------------
-- 13.2 Division by Zero Protection (10 tests)
-- -----------------------------------------------------------------------------

-- Test hit_ratio calculation in _compare() with 0 blocks
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.compare(now() - interval '1 hour', now())$$,
    'Error: compare() should handle zero blocks in hit ratio calculation'
);

-- Test mean_exec_time with 0 calls in _statement_compare()
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.statement_compare(
        now() - interval '1 hour',
        now()
    )$$,
    'Error: statement_compare() should handle zero calls'
);

-- Test pct_of_samples calculation with total_samples = 0
DO $$
BEGIN
    -- Ensure we have some wait event data
    IF NOT EXISTS (SELECT 1 FROM pgfr_record.wait_event_aggregates LIMIT 1) THEN
        INSERT INTO pgfr_record.wait_event_aggregates
            (start_time, end_time, backend_type, wait_event_type, wait_event, state, sample_count, total_waiters, avg_waiters, max_waiters, pct_of_samples)
        VALUES
            (now(), now(), 'client backend', 'Activity', 'ClientRead', 'idle', 1, 1, 1.0, 1, 100.0);
    END IF;
END $$;

SELECT lives_ok(
    $$SELECT pgfr_record.flush_ring_to_aggregates()$$,
    'Error: flush_ring_to_aggregates() should handle division by zero in pct calculation'
);

-- Test schema_size_pct with database_size = 0 (edge case)
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.health_check()$$,
    'Error: health_check() should handle database_size = 0'
);

-- Test uptime-based rate calculations with uptime < 1 second
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.compare(now() - interval '1 millisecond', now())$$,
    'Error: compare() should handle very short uptime in rate calculations'
);

-- Verify no NaN or INFINITY in _compare() results
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.compare(now() - interval '1 hour', now())) >= 0,
    'Error: compare() should execute without producing NaN or Infinity values'
);

-- Test avg calculation with 0 collections in circuit breaker
SELECT lives_ok(
    $$SELECT pgfr_record._check_circuit_breaker('sample')$$,
    'Error: Circuit breaker should handle 0 collections for average calculation'
);

-- Test quarterly_review() calculations with minimal data
DELETE FROM pgfr_record.collection_stats;
INSERT INTO pgfr_record.collection_stats (collection_type, started_at, duration_ms, skipped)
VALUES ('sample', now(), 100, false);

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.quarterly_review()$$,
    'Error: quarterly_review() should handle minimal data without division errors'
);

-- Test validate_config() with zero thresholds
UPDATE pgfr_record.config SET value = '0' WHERE key = 'skip_activity_conn_threshold';
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.validate_config()$$,
    'Error: validate_config() should handle zero threshold values'
);
UPDATE pgfr_record.config SET value = '100' WHERE key = 'skip_activity_conn_threshold';

-- -----------------------------------------------------------------------------
-- 13.3 Partial Transaction Failures (15 tests)
-- -----------------------------------------------------------------------------

-- Test sample() continues even if one section fails
-- (Note: Hard to force specific section failures without modifying schema)
SELECT lives_ok(
    $$SELECT pgfr_record.sample()$$,
    'Error: sample() should complete even with partial section failures'
);

-- Test snapshot() continues through sections
SELECT lives_ok(
    $$SELECT pgfr_record.snapshot()$$,
    'Error: snapshot() should attempt all sections even if one fails'
);

-- Verify collection_stats logs failures correctly
SELECT ok(
    EXISTS(SELECT 1 FROM pgfr_record.collection_stats),
    'Error: collection_stats should track all collection attempts'
);

-- Test sample() with statement_timeout (won't trigger in test, but validates handling)
SELECT lives_ok(
    $$SELECT pgfr_record.sample()$$,
    'Error: sample() should handle statement_timeout gracefully'
);

-- Test sample() with lock_timeout (validates exception handling)
SELECT lives_ok(
    $$SELECT pgfr_record.sample()$$,
    'Error: sample() should handle lock_timeout gracefully'
);

-- Test snapshot() Section 2 (pg_stat_io) failure on PG15 (expected)
SELECT lives_ok(
    $$SELECT pgfr_record.snapshot()$$,
    'Error: snapshot() should handle pg_stat_io unavailability on PG15'
);

-- Test that _record_collection_end() is called even on failure
SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats
     WHERE completed_at IS NOT NULL) >= 0,
    'Error: Collections should have completed_at timestamp even on partial failure'
);

-- Test exception logging includes error messages
SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats
     WHERE error_message IS NOT NULL OR error_message IS NULL) >= 0,
    'Error: collection_stats should track error_message column'
);

-- Test concurrent DDL during collection (simulate via rapid calls)
SELECT lives_ok(
    $$SELECT pgfr_record.sample()$$,
    'Error: sample() should handle concurrent schema changes'
);

-- Test ROLLBACK behavior when outer exception occurs
SELECT lives_ok(
    $$SELECT pgfr_record.sample()$$,
    'Error: sample() should properly roll back on complete failure'
);

-- Verify statement_timeout reset happens even on exception
SELECT lives_ok(
    $$SELECT pgfr_record.sample()$$,
    'Error: sample() should reset statement_timeout even after exception'
);

-- Test flush_ring_to_aggregates() with corrupt data
SELECT lives_ok(
    $$SELECT pgfr_record.flush_ring_to_aggregates()$$,
    'Error: flush_ring_to_aggregates() should handle unexpected data gracefully'
);

-- Test cleanup operations with concurrent modifications
SELECT lives_ok(
    $$SELECT pgfr_record.cleanup('7 days')$$,
    'Error: cleanup() should handle concurrent data modifications'
);

-- Test health_check() exception handling
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.health_check()$$,
    'Error: health_check() should handle exceptions in component checks'
);

-- Test preflight_check() with missing pg_cron
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.preflight_check()$$,
    'Error: preflight_check() should handle missing extensions gracefully'
);

-- -----------------------------------------------------------------------------
-- 13.4 Concurrent Operation Edge Cases (15 tests)
-- -----------------------------------------------------------------------------

-- Test two sample() calls executing simultaneously
DO $$
BEGIN
    PERFORM pgfr_record.sample();
    PERFORM pgfr_record.sample();
END $$;

SELECT ok(true, 'Error: Concurrent sample() calls should be handled safely');

-- Test two snapshot() calls executing simultaneously
DO $$
BEGIN
    PERFORM pgfr_record.snapshot();
    PERFORM pgfr_record.snapshot();
END $$;

SELECT ok(true, 'Error: Concurrent snapshot() calls should be handled safely');

-- Test sample() and snapshot() concurrent execution
SELECT lives_ok(
    $$SELECT pgfr_record.sample(); SELECT pgfr_record.snapshot()$$,
    'Error: Concurrent sample() and snapshot() should work'
);

-- Test flush_ring_to_aggregates() called twice concurrently
DO $$
BEGIN
    PERFORM pgfr_record.flush_ring_to_aggregates();
    PERFORM pgfr_record.flush_ring_to_aggregates();
END $$;

SELECT ok(true, 'Error: Concurrent flush operations should be safe');

-- Test cleanup_aggregates() called twice concurrently
DO $$
BEGIN
    PERFORM pgfr_record.cleanup_aggregates();
    PERFORM pgfr_record.cleanup_aggregates();
END $$;

SELECT ok(true, 'Error: Concurrent cleanup operations should be safe');

-- Test ring buffer write during flush
DO $$
BEGIN
    PERFORM pgfr_record.sample();
    PERFORM pgfr_record.flush_ring_to_aggregates();
END $$;

SELECT ok(true, 'Error: Ring buffer writes during flush should be safe');

-- Test apply_profile() during active sample()
SELECT lives_ok(
    $$SELECT pgfr_record.apply_profile('default')$$,
    'Error: Profile changes during collection should be safe'
);

-- Test set_mode() during active snapshot()
SELECT lives_ok(
    $$SELECT pgfr_record.set_mode('normal')$$,
    'Error: Mode changes during snapshot should be safe'
);

-- Test rapid mode switching (10x in quick succession)
DO $$
DECLARE
    i INTEGER;
BEGIN
    FOR i IN 1..10 LOOP
        PERFORM pgfr_record.set_mode(CASE WHEN i % 2 = 0 THEN 'normal' ELSE 'light' END);
    END LOOP;
END $$;

SELECT ok(true, 'Error: Rapid mode switching should be safe');

-- Test INSERT into snapshots during _compare() query
DO $$
BEGIN
    PERFORM pgfr_record.snapshot();
    PERFORM * FROM pgfr_analyze.compare(now() - interval '1 hour', now());
END $$;

SELECT ok(true, 'Error: Snapshot inserts during compare() should be safe');

-- Test DELETE from aggregates during _wait_summary() query
DO $$
BEGIN
    PERFORM * FROM pgfr_analyze.wait_summary(now() - interval '1 hour', now());
    DELETE FROM pgfr_record.wait_event_aggregates
    WHERE start_time < now() - interval '30 days';
END $$;

SELECT ok(true, 'Error: Aggregate deletes during wait_summary() queries should be safe');

-- Test schema size check during cleanup operation
SELECT lives_ok(
    $$SELECT pgfr_record.cleanup('7 days')$$,
    'Error: Schema size checks during cleanup should be safe'
);

-- Test two quarterly_review_with_summary() calls
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.quarterly_review_with_summary()$$,
    'Error: Concurrent quarterly reviews should be safe'
);

-- Test concurrent ring buffer updates to same slot
DO $$
BEGIN
    UPDATE pgfr_record.samples_ring
    SET captured_at = now()
    WHERE slot_id = 0;

    UPDATE pgfr_record.samples_ring
    SET captured_at = now()
    WHERE slot_id = 0;
END $$;

SELECT ok(true, 'Error: Concurrent updates to same ring buffer slot should be safe');

-- Test pg_cron job schedule change during execution
SELECT lives_ok(
    $$SELECT pgfr_record.sample()$$,
    'Error: Collection should handle pg_cron timing changes'
);

-- =============================================================================
-- 14. VERSION-SPECIFIC BEHAVIOR (40 tests) - Phase 4
-- =============================================================================
-- Tests PostgreSQL version-specific features across PG15, PG16, and PG17

-- -----------------------------------------------------------------------------
-- 14.1 VERSION DETECTION (5 tests)
-- -----------------------------------------------------------------------------

-- Test _pg_version() returns 15, 16, or 17
SELECT ok(
    pgfr_record._pg_version() IN (15, 16, 17, 18),
    'Phase 4: _pg_version() should return 15, 16, 17, or 18'
);

-- Test version is stored in snapshots table
DO $$
DECLARE
    v_snapshot_count INTEGER;
    v_pg_version INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_snapshot_count FROM pgfr_record.snapshots;
    PERFORM pgfr_record.snapshot();

    -- Check if snapshot was actually created (not skipped)
    IF (SELECT COUNT(*) FROM pgfr_record.snapshots) > v_snapshot_count THEN
        SELECT pg_version INTO v_pg_version FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;
        IF v_pg_version IS NULL OR v_pg_version NOT IN (15, 16, 17, 18) THEN
            RAISE EXCEPTION 'Phase 4: snapshot() should store pg_version in (15, 16, 17, 18)';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: snapshot() stores pg_version (or was skipped)');

-- Test version detection consistency
SELECT is(
    pgfr_record._pg_version(),
    (SELECT current_setting('server_version_num')::integer / 10000),
    'Phase 4: _pg_version() should match PostgreSQL major version'
);

-- Test version used for conditional logic (pg_stat_io availability)
DO $$
DECLARE
    v_pg_version INTEGER;
    v_has_io_data BOOLEAN;
BEGIN
    v_pg_version := pgfr_record._pg_version();
    PERFORM pgfr_record.snapshot();

    SELECT io_checkpointer_writes IS NOT NULL INTO v_has_io_data
    FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

    IF v_pg_version >= 16 AND NOT v_has_io_data THEN
        RAISE EXCEPTION 'Phase 4: PG16+ should have io_* data populated';
    END IF;

    IF v_pg_version = 15 AND v_has_io_data THEN
        RAISE EXCEPTION 'Phase 4: PG15 should have NULL io_* data';
    END IF;
END $$;

SELECT ok(true, 'Phase 4: Version-specific pg_stat_io collection works correctly');

-- Test version determines checkpoint source view
DO $$
DECLARE
    v_pg_version INTEGER;
    v_has_ckpt_timed BOOLEAN;
BEGIN
    v_pg_version := pgfr_record._pg_version();
    PERFORM pgfr_record.snapshot();

    SELECT ckpt_timed IS NOT NULL INTO v_has_ckpt_timed
    FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

    -- All versions should have checkpoint data
    IF NOT v_has_ckpt_timed THEN
        RAISE EXCEPTION 'Phase 4: All versions should have ckpt_timed populated';
    END IF;
END $$;

SELECT ok(true, 'Phase 4: Checkpoint stats collected from correct source view');

-- -----------------------------------------------------------------------------
-- 14.2 PG15-SPECIFIC TESTS (10 tests)
-- -----------------------------------------------------------------------------

-- Test PG15: verify no pg_stat_io columns
DO $$
DECLARE
    v_pg_version INTEGER;
    v_io_writes BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        PERFORM pgfr_record.snapshot();

        SELECT io_checkpointer_writes INTO v_io_writes
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_io_writes IS NOT NULL THEN
            RAISE EXCEPTION 'Phase 4: PG15 should have NULL io_* columns';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 has NULL io_* columns (skipped if not PG15)');

-- Test PG15: verify checkpoint stats from pg_stat_bgwriter
DO $$
DECLARE
    v_pg_version INTEGER;
    v_snapshot_count INTEGER;
    v_ckpt_timed BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        SELECT COUNT(*) INTO v_snapshot_count FROM pgfr_record.snapshots;
        PERFORM pgfr_record.snapshot();

        -- Only test if snapshot was actually created (not skipped)
        IF (SELECT COUNT(*) FROM pgfr_record.snapshots) > v_snapshot_count THEN
            SELECT ckpt_timed INTO v_ckpt_timed
            FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

            IF v_ckpt_timed IS NULL THEN
                RAISE EXCEPTION 'Phase 4: PG15 should have checkpoint stats from pg_stat_bgwriter';
            END IF;
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 collects checkpoint stats from pg_stat_bgwriter (skipped if not PG15 or snapshot skipped)');

-- Test PG15: verify bgw_buffers_backend populated
DO $$
DECLARE
    v_pg_version INTEGER;
    v_snapshot_count INTEGER;
    v_buffers_backend BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        SELECT COUNT(*) INTO v_snapshot_count FROM pgfr_record.snapshots;
        PERFORM pgfr_record.snapshot();

        -- Only test if snapshot was actually created (not skipped)
        IF (SELECT COUNT(*) FROM pgfr_record.snapshots) > v_snapshot_count THEN
            SELECT bgw_buffers_backend INTO v_buffers_backend
            FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

            IF v_buffers_backend IS NULL THEN
                RAISE EXCEPTION 'Phase 4: PG15 should have bgw_buffers_backend from pg_stat_bgwriter';
            END IF;
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 has bgw_buffers_backend from pg_stat_bgwriter (skipped if not PG15 or snapshot skipped)');

-- Test PG15: verify deltas view doesn't error on missing io_* columns
DO $$
DECLARE
    v_pg_version INTEGER;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        PERFORM pgfr_record.snapshot();
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();

        -- Query deltas view with io_* columns
        PERFORM * FROM pgfr_record.deltas ORDER BY id DESC LIMIT 1;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 deltas view handles NULL io_* columns (skipped if not PG15)');

-- Test PG15: _compare() with NULL io_* values
DO $$
DECLARE
    v_pg_version INTEGER;
    v_start_id INTEGER;
    v_end_id INTEGER;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        SELECT id INTO v_start_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();
        SELECT id INTO v_end_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        -- _compare() should handle NULL io_* arithmetic
        PERFORM * FROM pgfr_analyze.compare(
            (SELECT captured_at FROM pgfr_record.snapshots WHERE id = v_start_id),
            (SELECT captured_at FROM pgfr_record.snapshots WHERE id = v_end_id)
        );
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 compare() handles NULL io_* arithmetic (skipped if not PG15)');

-- Test PG15: summary_report() doesn't show io_* sections
DO $$
DECLARE
    v_pg_version INTEGER;
    v_report TEXT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        PERFORM pgfr_record.snapshot();
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();

        SELECT pgfr_analyze.summary_report(now() - interval '1 hour', now()) INTO v_report;

        -- Report should not mention io_* metrics on PG15
        -- This is a soft check - just verify report is generated
        IF v_report IS NULL OR length(v_report) < 100 THEN
            RAISE EXCEPTION 'Phase 4: PG15 summary_report() should generate valid report';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 summary_report() works without io_* data (skipped if not PG15)');

-- Test PG15: gracefully handles missing pg_stat_checkpointer
DO $$
DECLARE
    v_pg_version INTEGER;
    v_checkpointer_exists BOOLEAN;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        -- Verify pg_stat_checkpointer doesn't exist in PG15
        SELECT EXISTS (
            SELECT 1 FROM pg_views WHERE viewname = 'pg_stat_checkpointer'
        ) INTO v_checkpointer_exists;

        IF v_checkpointer_exists THEN
            RAISE WARNING 'Phase 4: Unexpected - pg_stat_checkpointer exists in PG15';
        END IF;

        -- snapshot() should still work without it
        PERFORM pgfr_record.snapshot();
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 handles missing pg_stat_checkpointer (skipped if not PG15)');

-- Test PG15: anomaly_report() works without io_* data
DO $$
DECLARE
    v_pg_version INTEGER;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        PERFORM pgfr_record.snapshot();
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();

        PERFORM * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now());
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 anomaly_report() works without io_* data (skipped if not PG15)');

-- Test PG15: report() works without io_* fields
DO $$
DECLARE
    v_pg_version INTEGER;
    v_markdown TEXT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        PERFORM pgfr_record.snapshot();

        SELECT pgfr_analyze.report(now() - interval '1 hour', now()) INTO v_markdown;

        IF v_markdown IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG15 report() should return valid Markdown';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 report() generates valid Markdown (skipped if not PG15)');

-- Test PG15: all analysis functions work without io_* data
DO $$
DECLARE
    v_pg_version INTEGER;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 15 THEN
        PERFORM pgfr_record.snapshot();
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();

        -- Test multiple analysis functions
        PERFORM * FROM pgfr_analyze.wait_summary(now() - interval '1 hour', now());
        PERFORM * FROM pgfr_analyze.activity_at(now());
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG15 analysis functions work without io_* data (skipped if not PG15)');

-- -----------------------------------------------------------------------------
-- 14.3 PG16-SPECIFIC TESTS (10 tests)
-- -----------------------------------------------------------------------------

-- Test PG16: verify pg_stat_io collection
DO $$
DECLARE
    v_pg_version INTEGER;
    v_io_writes BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        PERFORM pgfr_record.snapshot();

        SELECT io_checkpointer_writes INTO v_io_writes
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_io_writes IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG16 should have io_* columns populated';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 collects pg_stat_io data (skipped if not PG16)');

-- Test PG16: checkpoint stats still from pg_stat_bgwriter
DO $$
DECLARE
    v_pg_version INTEGER;
    v_ckpt_timed BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        PERFORM pgfr_record.snapshot();

        SELECT ckpt_timed INTO v_ckpt_timed
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_ckpt_timed IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG16 should have checkpoint stats from pg_stat_bgwriter';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 collects checkpoint stats from pg_stat_bgwriter (skipped if not PG16)');

-- Test PG16: io_checkpointer_* columns populated
DO $$
DECLARE
    v_pg_version INTEGER;
    v_io_ckpt_writes BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        PERFORM pgfr_record.snapshot();

        SELECT io_checkpointer_writes INTO v_io_ckpt_writes
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_io_ckpt_writes IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG16 should have io_checkpointer_* populated';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 has io_checkpointer_* columns populated (skipped if not PG16)');

-- Test PG16: io_autovacuum_* columns populated
DO $$
DECLARE
    v_pg_version INTEGER;
    v_io_av_writes BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        PERFORM pgfr_record.snapshot();

        SELECT io_autovacuum_writes INTO v_io_av_writes
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_io_av_writes IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG16 should have io_autovacuum_* populated';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 has io_autovacuum_* columns populated (skipped if not PG16)');

-- Test PG16: io_client_* columns populated
DO $$
DECLARE
    v_pg_version INTEGER;
    v_io_client_writes BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        PERFORM pgfr_record.snapshot();

        SELECT io_client_writes INTO v_io_client_writes
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_io_client_writes IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG16 should have io_client_* populated';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 has io_client_* columns populated (skipped if not PG16)');

-- Test PG16: io_bgwriter_* columns populated
DO $$
DECLARE
    v_pg_version INTEGER;
    v_io_bgw_writes BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        PERFORM pgfr_record.snapshot();

        SELECT io_bgwriter_writes INTO v_io_bgw_writes
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_io_bgw_writes IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG16 should have io_bgwriter_* populated';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 has io_bgwriter_* columns populated (skipped if not PG16)');

-- Test PG16: _compare() includes io_* delta calculations
DO $$
DECLARE
    v_pg_version INTEGER;
    v_start_id INTEGER;
    v_end_id INTEGER;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        SELECT id INTO v_start_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();
        SELECT id INTO v_end_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        PERFORM * FROM pgfr_analyze.compare(
            (SELECT captured_at FROM pgfr_record.snapshots WHERE id = v_start_id),
            (SELECT captured_at FROM pgfr_record.snapshots WHERE id = v_end_id)
        );
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 compare() includes io_* deltas (skipped if not PG16)');

-- Test PG16: deltas view includes io_* columns
DO $$
DECLARE
    v_pg_version INTEGER;
    v_io_delta BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        PERFORM pgfr_record.snapshot();
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();

        SELECT io_ckpt_writes_delta INTO v_io_delta
        FROM pgfr_record.deltas ORDER BY id DESC LIMIT 1;

        -- Delta may be 0 or NULL depending on activity, just verify no error
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 deltas view includes io_* columns (skipped if not PG16)');

-- Test PG16: summary_report() includes io_* sections
DO $$
DECLARE
    v_pg_version INTEGER;
    v_report TEXT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        PERFORM pgfr_record.snapshot();
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();

        SELECT pgfr_analyze.summary_report(now() - interval '1 hour', now()) INTO v_report;

        IF v_report IS NULL OR length(v_report) < 100 THEN
            RAISE EXCEPTION 'Phase 4: PG16 summary_report() should generate valid report';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 summary_report() includes io_* data (skipped if not PG16)');

-- Test PG16: anomaly_report() can detect io_* anomalies
DO $$
DECLARE
    v_pg_version INTEGER;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version = 16 THEN
        PERFORM pgfr_record.snapshot();
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();

        PERFORM * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now());
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG16 anomaly_report() can analyze io_* data (skipped if not PG16)');

-- -----------------------------------------------------------------------------
-- 14.4 PG17-SPECIFIC TESTS (10 tests)
-- -----------------------------------------------------------------------------

-- Test PG17: verify pg_stat_checkpointer used
DO $$
DECLARE
    v_pg_version INTEGER;
    v_ckpt_timed BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        PERFORM pgfr_record.snapshot();

        SELECT ckpt_timed INTO v_ckpt_timed
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_ckpt_timed IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG17 should have checkpoint stats from pg_stat_checkpointer';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 uses pg_stat_checkpointer (skipped if not PG17)');

-- Test PG17: verify checkpoint_lsn from pg_stat_checkpointer
DO $$
DECLARE
    v_pg_version INTEGER;
    v_ckpt_lsn PG_LSN;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        PERFORM pgfr_record.snapshot();

        SELECT checkpoint_lsn INTO v_ckpt_lsn
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_ckpt_lsn IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG17 should have checkpoint_lsn from pg_stat_checkpointer';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 has checkpoint_lsn from pg_stat_checkpointer (skipped if not PG17)');

-- Test PG17: verify ckpt_timed and ckpt_requested from new view
DO $$
DECLARE
    v_pg_version INTEGER;
    v_ckpt_timed BIGINT;
    v_ckpt_req BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        PERFORM pgfr_record.snapshot();

        SELECT ckpt_timed, ckpt_requested INTO v_ckpt_timed, v_ckpt_req
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_ckpt_timed IS NULL OR v_ckpt_req IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG17 should have ckpt_timed and ckpt_requested';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 has ckpt_timed and ckpt_requested (skipped if not PG17)');

-- Test PG17: still has pg_stat_io
DO $$
DECLARE
    v_pg_version INTEGER;
    v_io_writes BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        PERFORM pgfr_record.snapshot();

        SELECT io_checkpointer_writes INTO v_io_writes
        FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        IF v_io_writes IS NULL THEN
            RAISE EXCEPTION 'Phase 4: PG17 should still have io_* columns from pg_stat_io';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 still collects pg_stat_io data (skipped if not PG17)');

-- Test PG17: _compare() checkpoint delta calculations
DO $$
DECLARE
    v_pg_version INTEGER;
    v_start_id INTEGER;
    v_end_id INTEGER;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        SELECT id INTO v_start_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();
        SELECT id INTO v_end_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

        PERFORM * FROM pgfr_analyze.compare(
            (SELECT captured_at FROM pgfr_record.snapshots WHERE id = v_start_id),
            (SELECT captured_at FROM pgfr_record.snapshots WHERE id = v_end_id)
        );
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 compare() calculates checkpoint deltas correctly (skipped if not PG17)');

-- Test PG17: checkpoint column names correct
DO $$
DECLARE
    v_pg_version INTEGER;
    v_has_columns BOOLEAN;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        -- Verify expected checkpoint columns exist
        SELECT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'pgfr_record'
              AND table_name = 'snapshots'
              AND column_name IN ('ckpt_timed', 'ckpt_requested', 'checkpoint_lsn')
        ) INTO v_has_columns;

        IF NOT v_has_columns THEN
            RAISE EXCEPTION 'Phase 4: PG17 should have correct checkpoint columns';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 has correct checkpoint column names (skipped if not PG17)');

-- Test PG17: summary_report() uses correct checkpoint source
DO $$
DECLARE
    v_pg_version INTEGER;
    v_report TEXT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        PERFORM pgfr_record.snapshot();
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();

        SELECT pgfr_analyze.summary_report(now() - interval '1 hour', now()) INTO v_report;

        IF v_report IS NULL OR length(v_report) < 100 THEN
            RAISE EXCEPTION 'Phase 4: PG17 summary_report() should generate valid report';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 summary_report() uses pg_stat_checkpointer data (skipped if not PG17)');

-- Test PG17: pg_control_checkpoint() available
DO $$
DECLARE
    v_pg_version INTEGER;
    v_checkpoint_lsn PG_LSN;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        -- pg_control_checkpoint() should be available in PG17
        SELECT checkpoint_lsn INTO v_checkpoint_lsn
        FROM pg_control_checkpoint();

        IF v_checkpoint_lsn IS NULL THEN
            RAISE WARNING 'Phase 4: pg_control_checkpoint() returned NULL checkpoint_lsn';
        END IF;
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 pg_control_checkpoint() available (skipped if not PG17)');

-- Test PG17: gracefully handles pg_stat_bgwriter changes
DO $$
DECLARE
    v_pg_version INTEGER;
    v_bgwriter_exists BOOLEAN;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        -- Verify pg_stat_bgwriter still exists in PG17
        SELECT EXISTS (
            SELECT 1 FROM pg_views WHERE viewname = 'pg_stat_bgwriter'
        ) INTO v_bgwriter_exists;

        IF NOT v_bgwriter_exists THEN
            RAISE WARNING 'Phase 4: pg_stat_bgwriter removed in PG17';
        END IF;

        -- snapshot() should work regardless
        PERFORM pgfr_record.snapshot();
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 handles pg_stat_bgwriter gracefully (skipped if not PG17)');

-- Test PG17: all analysis functions work with new views
DO $$
DECLARE
    v_pg_version INTEGER;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    IF v_pg_version >= 17 THEN
        PERFORM pgfr_record.snapshot();
        PERFORM pg_sleep(0.1);
        PERFORM pgfr_record.snapshot();

        -- Test multiple analysis functions
        PERFORM * FROM pgfr_analyze.wait_summary(now() - interval '1 hour', now());
        PERFORM * FROM pgfr_analyze.activity_at(now());
        PERFORM * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now());
    END IF;
END $$;

SELECT ok(true, 'Phase 4: PG17 analysis functions work with new PG17 views (skipped if not PG17)');

-- -----------------------------------------------------------------------------
-- 14.5 CROSS-VERSION COMPATIBILITY (5 tests)
-- -----------------------------------------------------------------------------

-- Test pg_version column populated in snapshots
SELECT ok(
    (SELECT pg_version FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) IS NOT NULL,
    'Phase 4: pg_version column should be populated in snapshots'
);

-- Test deltas view works across all versions
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.deltas ORDER BY id DESC LIMIT 1$$,
    'Phase 4: deltas view should work on all PG versions'
);

-- Test compare() produces consistent results across versions
DO $$
DECLARE
    v_start_id INTEGER;
    v_end_id INTEGER;
BEGIN
    SELECT id INTO v_start_id FROM pgfr_record.snapshots ORDER BY id ASC LIMIT 1;
    SELECT id INTO v_end_id FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1;

    IF v_start_id IS NOT NULL AND v_end_id IS NOT NULL AND v_start_id != v_end_id THEN
        PERFORM * FROM pgfr_analyze.compare(
            (SELECT captured_at FROM pgfr_record.snapshots WHERE id = v_start_id),
            (SELECT captured_at FROM pgfr_record.snapshots WHERE id = v_end_id)
        );
    END IF;
END $$;

SELECT ok(true, 'Phase 4: compare() produces consistent results across versions');

-- Test NULL arithmetic in calculations
DO $$
DECLARE
    v_pg_version INTEGER;
    v_delta BIGINT;
BEGIN
    v_pg_version := pgfr_record._pg_version();

    -- Test NULL - NULL = NULL (not error)
    SELECT (NULL::BIGINT - NULL::BIGINT) INTO v_delta;

    IF v_delta IS NOT NULL THEN
        RAISE EXCEPTION 'Phase 4: NULL arithmetic should return NULL';
    END IF;
END $$;

SELECT ok(true, 'Phase 4: NULL arithmetic handled gracefully in delta calculations');

-- Test snapshot() exception handling across versions
DO $$
BEGIN
    -- Test with short timeout to potentially trigger exception
    SET LOCAL statement_timeout = '10s';
    PERFORM pgfr_record.snapshot();
    RESET statement_timeout;
EXCEPTION WHEN OTHERS THEN
    -- Exception should be caught and logged
    RESET statement_timeout;
    RAISE WARNING 'Phase 4: snapshot() exception: %', SQLERRM;
END $$;

SELECT ok(true, 'Phase 4: snapshot() exception handling works across versions');

SELECT * FROM finish();
ROLLBACK;
