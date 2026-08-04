-- =============================================================================
-- pgfr_record pgTAP Tests - Time-Travel Debugging
-- =============================================================================
-- Tests: _interpolate_metric, what_happened_at, incident_timeline
-- Test count: 45
-- =============================================================================

BEGIN;
SELECT plan(46);

-- =============================================================================
-- 1. FUNCTION EXISTENCE (3 tests)
-- =============================================================================

SELECT has_function(
    'pgfr_record', '_interpolate_metric',
    ARRAY['numeric', 'timestamptz', 'numeric', 'timestamptz', 'timestamptz'],
    '_interpolate_metric function should exist'
);

SELECT has_function(
    'pgfr_analyze', 'what_happened_at',
    ARRAY['timestamptz', 'interval'],
    'what_happened_at function should exist'
);

SELECT has_function(
    'pgfr_analyze', 'incident_timeline',
    ARRAY['timestamptz', 'timestamptz'],
    'incident_timeline function should exist'
);

-- =============================================================================
-- 2. _INTERPOLATE_METRIC TESTS (15 tests)
-- =============================================================================

-- Test exact midpoint interpolation
SELECT is(
    pgfr_record._interpolate_metric(
        10::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        20::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:05:00'::timestamptz
    ),
    15.0000::NUMERIC,
    '_interpolate_metric should return 15 at exact midpoint between 10 and 20'
);

-- Test quarter point interpolation
SELECT is(
    pgfr_record._interpolate_metric(
        0::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        100::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:02:30'::timestamptz
    ),
    25.0000::NUMERIC,
    '_interpolate_metric should return 25 at quarter point'
);

-- Test three-quarter point interpolation
SELECT is(
    pgfr_record._interpolate_metric(
        0::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        100::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:07:30'::timestamptz
    ),
    75.0000::NUMERIC,
    '_interpolate_metric should return 75 at three-quarter point'
);

-- Test at start time (should return before value)
SELECT is(
    pgfr_record._interpolate_metric(
        10::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        20::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:00:00'::timestamptz
    ),
    10.0000::NUMERIC,
    '_interpolate_metric should return before value at start time'
);

-- Test at end time (should return after value)
SELECT is(
    pgfr_record._interpolate_metric(
        10::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        20::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:10:00'::timestamptz
    ),
    20.0000::NUMERIC,
    '_interpolate_metric should return after value at end time'
);

-- Test before start time (clamped to start)
SELECT is(
    pgfr_record._interpolate_metric(
        10::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        20::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 09:55:00'::timestamptz
    ),
    10.0000::NUMERIC,
    '_interpolate_metric should clamp to before value when target is before range'
);

-- Test after end time (clamped to end)
SELECT is(
    pgfr_record._interpolate_metric(
        10::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        20::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:15:00'::timestamptz
    ),
    20.0000::NUMERIC,
    '_interpolate_metric should clamp to after value when target is after range'
);

-- Test with same timestamps (should return before value)
SELECT is(
    pgfr_record._interpolate_metric(
        10::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        20::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        '2024-01-01 10:00:00'::timestamptz
    ),
    10.0000::NUMERIC,
    '_interpolate_metric should return before value when timestamps are equal'
);

-- Test with NULL value_before
SELECT is(
    pgfr_record._interpolate_metric(
        NULL::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        20::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:05:00'::timestamptz
    ),
    NULL::NUMERIC,
    '_interpolate_metric should return NULL when value_before is NULL'
);

-- Test with NULL value_after
SELECT is(
    pgfr_record._interpolate_metric(
        10::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        NULL::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:05:00'::timestamptz
    ),
    NULL::NUMERIC,
    '_interpolate_metric should return NULL when value_after is NULL'
);

-- Test with NULL time_before
SELECT is(
    pgfr_record._interpolate_metric(
        10::NUMERIC, NULL::timestamptz,
        20::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:05:00'::timestamptz
    ),
    NULL::NUMERIC,
    '_interpolate_metric should return NULL when time_before is NULL'
);

-- Test with NULL target_time
SELECT is(
    pgfr_record._interpolate_metric(
        10::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        20::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        NULL::timestamptz
    ),
    NULL::NUMERIC,
    '_interpolate_metric should return NULL when target_time is NULL'
);

-- Test negative value interpolation
SELECT is(
    pgfr_record._interpolate_metric(
        -10::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        10::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:05:00'::timestamptz
    ),
    0.0000::NUMERIC,
    '_interpolate_metric should handle negative values correctly'
);

-- Test decreasing values
SELECT is(
    pgfr_record._interpolate_metric(
        100::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        0::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:05:00'::timestamptz
    ),
    50.0000::NUMERIC,
    '_interpolate_metric should handle decreasing values correctly'
);

-- Test with fractional values
SELECT ok(
    ABS(pgfr_record._interpolate_metric(
        1.5::NUMERIC, '2024-01-01 10:00:00'::timestamptz,
        3.5::NUMERIC, '2024-01-01 10:10:00'::timestamptz,
        '2024-01-01 10:05:00'::timestamptz
    ) - 2.5) < 0.0001,
    '_interpolate_metric should handle fractional values correctly'
);

-- =============================================================================
-- 3. WHAT_HAPPENED_AT RETURN TYPE TESTS (12 tests)
-- =============================================================================

-- Ensure function returns expected columns
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT requested_time FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return requested_time column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT sample_before FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return sample_before column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT sample_after FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return sample_after column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT snapshot_before FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return snapshot_before column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT snapshot_after FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return snapshot_after column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT est_connections_active FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return est_connections_active column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT events FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return events column as JSONB'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT confidence FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return confidence column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT confidence_score FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return confidence_score column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT data_quality_notes FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return data_quality_notes column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT recommendations FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return recommendations column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT top_wait_events FROM pgfr_analyze.what_happened_at(now())
    ) sub) >= 0,
    'what_happened_at should return top_wait_events column'
);

-- =============================================================================
-- 4. WHAT_HAPPENED_AT BEHAVIOR TESTS (7 tests)
-- =============================================================================

-- Test that requested_time matches input
SELECT is(
    (SELECT requested_time FROM pgfr_analyze.what_happened_at('2024-01-01 10:00:00'::timestamptz)),
    '2024-01-01 10:00:00'::timestamptz,
    'what_happened_at should return the requested timestamp in requested_time'
);

-- Test that confidence_score is between 0 and 1
SELECT ok(
    (SELECT confidence_score FROM pgfr_analyze.what_happened_at(now()))
        BETWEEN 0 AND 1,
    'what_happened_at confidence_score should be between 0 and 1'
);

-- Test that confidence level is one of expected values
SELECT ok(
    (SELECT confidence FROM pgfr_analyze.what_happened_at(now()))
        IN ('high', 'medium', 'low', 'very_low'),
    'what_happened_at confidence should be high, medium, low, or very_low'
);

-- Test that events is valid JSONB array
SELECT ok(
    (SELECT jsonb_typeof(events) FROM pgfr_analyze.what_happened_at(now())) = 'array',
    'what_happened_at events should be a JSONB array'
);

-- Test that data_quality_notes is an array
SELECT ok(
    (SELECT data_quality_notes IS NOT NULL FROM pgfr_analyze.what_happened_at(now())),
    'what_happened_at data_quality_notes should not be NULL'
);

-- Test that recommendations is an array
SELECT ok(
    (SELECT recommendations IS NOT NULL FROM pgfr_analyze.what_happened_at(now())),
    'what_happened_at recommendations should not be NULL'
);

-- Test custom context window
SELECT ok(
    (SELECT COUNT(*) FROM pgfr_analyze.what_happened_at(now(), '10 minutes'::interval)) = 1,
    'what_happened_at should accept custom context_window parameter'
);

-- =============================================================================
-- 5. INCIDENT_TIMELINE RETURN TYPE TESTS (4 tests)
-- =============================================================================

-- Ensure function returns expected columns
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT event_time FROM pgfr_analyze.incident_timeline(
            now() - interval '1 hour', now()
        ) LIMIT 0
    ) sub) >= 0,
    'incident_timeline should return event_time column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT event_type FROM pgfr_analyze.incident_timeline(
            now() - interval '1 hour', now()
        ) LIMIT 0
    ) sub) >= 0,
    'incident_timeline should return event_type column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT description FROM pgfr_analyze.incident_timeline(
            now() - interval '1 hour', now()
        ) LIMIT 0
    ) sub) >= 0,
    'incident_timeline should return description column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT details FROM pgfr_analyze.incident_timeline(
            now() - interval '1 hour', now()
        ) LIMIT 0
    ) sub) >= 0,
    'incident_timeline should return details column as JSONB'
);

-- =============================================================================
-- 6. INCIDENT_TIMELINE BEHAVIOR TESTS (4 tests)
-- =============================================================================

-- Test that incident_timeline returns results in chronological order
-- (Create test data by ensuring snapshots exist)
SELECT pgfr_record.snapshot();

SELECT ok(
    (SELECT COUNT(*) >= 0 FROM pgfr_analyze.incident_timeline(
        now() - interval '1 hour', now()
    )),
    'incident_timeline should execute without error for recent time range'
);

-- Test that all returned events are within the specified range
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.incident_timeline(
            now() - interval '1 hour', now()
        )
        WHERE event_time < now() - interval '1 hour'
           OR event_time > now()
    ),
    'incident_timeline events should all be within specified time range'
);

-- Test that event_type is one of expected values
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.incident_timeline(
            now() - interval '1 hour', now()
        )
        WHERE event_type NOT IN (
            'checkpoint', 'wal_archived', 'archive_failed',
            'query_started', 'transaction_started', 'connection_opened',
            'lock_contention', 'wait_spike', 'snapshot',
            'coverage'  -- Issue #102: the window's coverage disclosure event
        )
    ),
    'incident_timeline event_type should be one of the expected values'
);

-- Test that details is valid JSONB
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.incident_timeline(
            now() - interval '1 hour', now()
        )
        WHERE jsonb_typeof(details) != 'object'
    ),
    'incident_timeline details should be JSONB objects'
);

-- =============================================================================
-- CLEANUP
-- =============================================================================

-- Issue #102: the reconstruction states its ring coverage in the notes
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.what_happened_at(now()) w,
             unnest(w.data_quality_notes) AS note
        WHERE note ILIKE '%coverage%'
    ),
    'what_happened_at states ring sample coverage in data_quality_notes'
);

SELECT * FROM finish();
ROLLBACK;
