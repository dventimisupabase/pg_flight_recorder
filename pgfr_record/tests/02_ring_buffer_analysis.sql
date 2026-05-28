-- =============================================================================
-- pgfr_record pgTAP Tests - Ring Buffer & Analysis
-- =============================================================================
-- Tests: Ring buffer architecture, analysis functions, config, views
-- Sections: 3A, 4, 6, 7
-- Test count: 25
-- =============================================================================

BEGIN;
SELECT plan(16);

-- =============================================================================
-- 3A. RING BUFFER ARCHITECTURE (10 tests)
-- =============================================================================

-- Test ring buffer slot initialization (120 slots, 0-119)



-- Capture multiple samples; flush_ring_to_aggregates() / cleanup_aggregates() /
-- wait_event_aggregates retired (6 assertions dropped: 1 flush lives_ok at the
-- top of this section, plus 5 cleanup-with-old-data assertions below).
SELECT pgfr_record.sample_ring();
SELECT pgfr_record.sample_ring();
SELECT pgfr_record.sample_ring();

-- =============================================================================
-- 4. ANALYSIS FUNCTIONS (8 tests)
-- =============================================================================

-- Capture a second snapshot and sample for time-based queries
SELECT pg_sleep(0.1);
SELECT pgfr_record.snapshot();
SELECT pgfr_record.sample_ring();

-- Get time range for queries
DO $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
BEGIN
    -- Derive bounds from v2 wait_samples (sample_ts → captured_at).
    SELECT pgfr_record.epoch() + min(sample_ts) * interval '1 second' INTO v_start_time FROM pgfr_record.wait_samples;
    SELECT pgfr_record.epoch() + max(sample_ts) * interval '1 second' INTO v_end_time FROM pgfr_record.wait_samples;

    -- Store for later tests
    CREATE TEMP TABLE test_times (start_time TIMESTAMPTZ, end_time TIMESTAMPTZ);
    INSERT INTO test_times VALUES (v_start_time, v_end_time);
END;
$$;

-- Test _compare() function
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.compare(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'compare() should execute without error'
);

-- Test _wait_summary() function
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.wait_summary(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'wait_summary() should execute without error'
);

-- Test _activity_at() function
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.activity_at(now())$$,
    'activity_at() should execute without error'
);

-- Test anomaly_report() function
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'anomaly_report() should execute without error'
);

-- Test summary_report() function
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.summary_report(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'summary_report() should execute without error'
);

-- Test _statement_compare() function
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.statement_compare(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'statement_compare() should execute without error'
);

-- Test wait_summary executes without error (data optional in idle test DB)
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.wait_summary(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'wait_summary() should execute without error'
);

-- =============================================================================
-- 6. CONFIGURATION FUNCTIONS (5 tests)
-- =============================================================================

-- Test get_mode()
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.get_mode()$$,
    'get_mode() should execute without error'
);

-- Test default mode is normal
SELECT is(
    (SELECT mode FROM pgfr_record.get_mode()),
    'normal',
    'Default mode should be normal'
);

-- Test set_mode() to light
SELECT lives_ok(
    $$SELECT pgfr_record.set_mode('light')$$,
    'set_mode() should work'
);

-- Verify mode changed
SELECT is(
    (SELECT mode FROM pgfr_record.get_mode()),
    'light',
    'Mode should be changed to light'
);

-- Reset to normal
SELECT pgfr_record.set_mode('normal');

-- Test invalid mode throws error
SELECT throws_ok(
    $$SELECT pgfr_record.set_mode('invalid')$$,
    'Invalid mode: invalid. Must be normal, light, or emergency.',
    'set_mode() should reject invalid modes'
);

-- =============================================================================
-- 7. VIEWS FUNCTIONALITY (5 tests)
-- =============================================================================

-- Test deltas view
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.deltas LIMIT 1$$,
    'deltas view should be queryable'
);

-- Test recent_waits view
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.recent_waits LIMIT 1$$,
    'recent_waits view should be queryable'
);

-- Test recent_activity view
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.recent_activity LIMIT 1$$,
    'recent_activity view should be queryable'
);

-- Test recent_locks view
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.recent_locks LIMIT 1$$,
    'recent_locks view should be queryable'
);

-- NOTE: recent_progress view removed from ring buffer architecture
-- Progress tracking removed to minimize footprint
-- Use pg_stat_progress_* views directly for real-time progress

SELECT * FROM finish();
ROLLBACK;
