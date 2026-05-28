-- =============================================================================
-- pgfr_record pgTAP Tests - Blast Radius Analysis
-- =============================================================================
-- Tests: blast_radius, blast_radius_report
-- Test count: 45
-- =============================================================================

BEGIN;
SELECT plan(45);

-- =============================================================================
-- 1. FUNCTION EXISTENCE (2 tests)
-- =============================================================================

SELECT has_function(
    'pgfr_analyze', 'blast_radius',
    ARRAY['timestamptz', 'timestamptz'],
    'blast_radius function should exist'
);

SELECT has_function(
    'pgfr_analyze', 'blast_radius_report',
    ARRAY['timestamptz', 'timestamptz'],
    'blast_radius_report function should exist'
);

-- =============================================================================
-- 2. BLAST_RADIUS RETURN TYPE TESTS (22 tests)
-- =============================================================================

-- Test time window columns
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT incident_start FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return incident_start column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT incident_end FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return incident_end column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT duration_seconds FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return duration_seconds column'
);

-- Test lock impact columns
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT blocked_sessions_total FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return blocked_sessions_total column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT blocked_sessions_max_concurrent FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return blocked_sessions_max_concurrent column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT max_block_duration FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return max_block_duration column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT avg_block_duration FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return avg_block_duration column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT lock_types FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return lock_types column'
);

-- Test query degradation columns
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT degraded_queries_count FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return degraded_queries_count column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT degraded_queries FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return degraded_queries column'
);

-- Test connection impact columns
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT connections_before FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return connections_before column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT connections_during_avg FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return connections_during_avg column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT connections_during_max FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return connections_during_max column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT connection_increase_pct FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return connection_increase_pct column'
);

-- Test application impact column
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT affected_applications FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return affected_applications column'
);

-- Test wait event column
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT top_wait_events FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return top_wait_events column'
);

-- Test throughput columns
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT tps_before FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return tps_before column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT tps_during FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return tps_during column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT tps_change_pct FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return tps_change_pct column'
);

-- Test summary columns
SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT severity FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return severity column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT impact_summary FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return impact_summary column'
);

SELECT ok(
    (SELECT COUNT(*) FROM (
        SELECT recommendations FROM pgfr_analyze.blast_radius(
            now() - interval '1 hour', now()
        )
    ) sub) >= 0,
    'blast_radius should return recommendations column'
);

-- =============================================================================
-- 3. BLAST_RADIUS BEHAVIOR TESTS (12 tests)
-- =============================================================================

-- Ensure we have some data
SELECT pgfr_record.snapshot();
SELECT pgfr_record.sample_ring();

-- Test that incident_start matches input
SELECT is(
    (SELECT incident_start FROM pgfr_analyze.blast_radius(
        '2024-01-01 10:00:00'::timestamptz,
        '2024-01-01 11:00:00'::timestamptz
    )),
    '2024-01-01 10:00:00'::timestamptz,
    'blast_radius should return the requested start time in incident_start'
);

-- Test that incident_end matches input
SELECT is(
    (SELECT incident_end FROM pgfr_analyze.blast_radius(
        '2024-01-01 10:00:00'::timestamptz,
        '2024-01-01 11:00:00'::timestamptz
    )),
    '2024-01-01 11:00:00'::timestamptz,
    'blast_radius should return the requested end time in incident_end'
);

-- Test duration calculation (1 hour = 3600 seconds)
SELECT is(
    (SELECT duration_seconds FROM pgfr_analyze.blast_radius(
        '2024-01-01 10:00:00'::timestamptz,
        '2024-01-01 11:00:00'::timestamptz
    )),
    3600::numeric,
    'blast_radius should calculate duration_seconds correctly'
);

-- Test severity is valid value
SELECT ok(
    (SELECT severity FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )) IN ('low', 'medium', 'high', 'critical'),
    'blast_radius severity should be low, medium, high, or critical'
);

-- Test lock_types is valid JSONB array
SELECT ok(
    (SELECT jsonb_typeof(lock_types) FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )) = 'array',
    'blast_radius lock_types should be a JSONB array'
);

-- Test degraded_queries is valid JSONB array
SELECT ok(
    (SELECT jsonb_typeof(degraded_queries) FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )) = 'array',
    'blast_radius degraded_queries should be a JSONB array'
);

-- Test affected_applications is valid JSONB array
SELECT ok(
    (SELECT jsonb_typeof(affected_applications) FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )) = 'array',
    'blast_radius affected_applications should be a JSONB array'
);

-- Test top_wait_events is valid JSONB array
SELECT ok(
    (SELECT jsonb_typeof(top_wait_events) FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )) = 'array',
    'blast_radius top_wait_events should be a JSONB array'
);

-- Test impact_summary is an array
SELECT ok(
    (SELECT impact_summary IS NOT NULL FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )),
    'blast_radius impact_summary should not be NULL'
);

-- Test recommendations is an array
SELECT ok(
    (SELECT recommendations IS NOT NULL FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )),
    'blast_radius recommendations should not be NULL'
);

-- Test blocked_sessions_total is non-negative
SELECT ok(
    (SELECT blocked_sessions_total >= 0 FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )),
    'blast_radius blocked_sessions_total should be non-negative'
);

-- Test degraded_queries_count is non-negative
SELECT ok(
    (SELECT degraded_queries_count >= 0 FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )),
    'blast_radius degraded_queries_count should be non-negative'
);

-- =============================================================================
-- 4. SEVERITY CLASSIFICATION TESTS (5 tests)
-- =============================================================================

-- Test that severity is low when no issues (using a time range with no data)
SELECT ok(
    (SELECT severity FROM pgfr_analyze.blast_radius(
        '1990-01-01 00:00:00'::timestamptz,
        '1990-01-01 01:00:00'::timestamptz
    )) = 'low',
    'blast_radius should return low severity when no issues detected'
);

-- Test that impact_summary contains at least one entry
SELECT ok(
    (SELECT array_length(impact_summary, 1) >= 1 FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )),
    'blast_radius impact_summary should contain at least one entry'
);

-- Test that recommendations contains at least one entry
SELECT ok(
    (SELECT array_length(recommendations, 1) >= 1 FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )),
    'blast_radius recommendations should contain at least one entry'
);

-- Test that connection metrics are reasonable
SELECT ok(
    (SELECT connections_during_avg >= 0 FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )),
    'blast_radius connections_during_avg should be non-negative'
);

-- Test that TPS metrics handle no data gracefully
SELECT ok(
    (SELECT tps_before IS NOT NULL FROM pgfr_analyze.blast_radius(
        now() - interval '1 hour', now()
    )),
    'blast_radius tps_before should not be NULL (may be 0)'
);

-- =============================================================================
-- 5. BLAST_RADIUS_REPORT TESTS (4 tests)
-- =============================================================================

-- Test that report returns TEXT
SELECT ok(
    (SELECT pg_typeof(pgfr_analyze.blast_radius_report(
        now() - interval '1 hour', now()
    ))::text = 'text'),
    'blast_radius_report should return TEXT type'
);

-- Test that report contains header
SELECT ok(
    (SELECT pgfr_analyze.blast_radius_report(
        now() - interval '1 hour', now()
    ) LIKE '%BLAST RADIUS ANALYSIS REPORT%'),
    'blast_radius_report should contain report header'
);

-- Test that report contains severity indicator
SELECT ok(
    (SELECT pgfr_analyze.blast_radius_report(
        now() - interval '1 hour', now()
    ) LIKE '%Severity:%'),
    'blast_radius_report should contain severity indicator'
);

-- Test that report contains recommendations section
SELECT ok(
    (SELECT pgfr_analyze.blast_radius_report(
        now() - interval '1 hour', now()
    ) LIKE '%RECOMMENDATIONS%'),
    'blast_radius_report should contain recommendations section'
);

-- =============================================================================
-- CLEANUP
-- =============================================================================

SELECT * FROM finish();
ROLLBACK;
