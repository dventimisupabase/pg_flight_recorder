-- =============================================================================
-- pgfr_analyze pgTAP Tests - Query Storm Detection
-- =============================================================================
-- Tests: pgfr_analyze.detect_query_storms function and config settings
-- Test count: 10
-- =============================================================================

BEGIN;
SELECT plan(12);

-- =============================================================================
-- 1. CONFIG SETTINGS (6 tests)
-- =============================================================================

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_threshold_multiplier'),
    'storm_threshold_multiplier config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_lookback_interval'),
    'storm_lookback_interval config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_baseline_days'),
    'storm_baseline_days config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_severity_low_max'),
    'storm_severity_low_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_severity_medium_max'),
    'storm_severity_medium_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'storm_severity_high_max'),
    'storm_severity_high_max config setting should exist'
);

-- =============================================================================
-- 2. FUNCTION EXISTENCE (1 test)
-- =============================================================================

SELECT has_function(
    'pgfr_analyze', 'detect_query_storms', ARRAY['interval', 'numeric'],
    'pgfr_analyze.detect_query_storms(interval, numeric) function should exist'
);

-- =============================================================================
-- 3. FUNCTION EXECUTION (3 tests)
-- =============================================================================

-- Test detect_query_storms executes without error
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_query_storms()$$,
    'detect_query_storms() should execute without error'
);

-- Test detect_query_storms with explicit parameters
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_query_storms('2 hours'::interval, 5.0)$$,
    'detect_query_storms(interval, numeric) should execute without error'
);

-- Test detect_query_storms returns expected columns (including the #102
-- sample-count disclosures)
SELECT lives_ok(
    $$SELECT queryid, query_fingerprint, storm_type, severity, recent_count, baseline_count,
             multiplier, recent_samples, baseline_samples
      FROM pgfr_analyze.detect_query_storms()$$,
    'detect_query_storms() should return expected columns'
);

-- =============================================================================
-- 4. MULTIPLIER UNITS (Issue #102): a synthetic fixture with a known true
--    per-tick rate ratio must return exactly that multiplier. Before the
--    fix, the numerator was a whole-window SUM against a per-tick AVG
--    denominator, inflating the multiplier by the tick count of the window.
-- =============================================================================

DO $$
DECLARE
    v_snap_b1 INTEGER;
    v_snap_b2 INTEGER;
    v_snap_r1 INTEGER;
    v_snap_r2 INTEGER;
    v_dbid    OID := (SELECT oid FROM pg_database WHERE datname = current_database());
BEGIN
    -- Baseline: two snapshots on two distinct days, calls_delta = 10 per tick
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
    VALUES (now() - interval '3 days', 170000) RETURNING id INTO v_snap_b1;
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
    VALUES (now() - interval '2 days', 170000) RETURNING id INTO v_snap_b2;
    -- Recent: two snapshots inside the default 1-hour lookback, 40 per tick
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
    VALUES (now() - interval '10 minutes', 170000) RETURNING id INTO v_snap_r1;
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
    VALUES (now() - interval '5 minutes', 170000) RETURNING id INTO v_snap_r2;

    INSERT INTO pgfr_record.statement_snapshots (snapshot_id, queryid, dbid, query_preview, calls, calls_delta)
    VALUES (v_snap_b1, -777001, v_dbid, 'SELECT known_multiplier_fixture', 100, 10),
           (v_snap_b2, -777001, v_dbid, 'SELECT known_multiplier_fixture', 200, 10),
           (v_snap_r1, -777001, v_dbid, 'SELECT known_multiplier_fixture', 300, 40),
           (v_snap_r2, -777001, v_dbid, 'SELECT known_multiplier_fixture', 340, 40);
END $$;

SELECT is(
    (SELECT multiplier FROM pgfr_analyze.detect_query_storms()
     WHERE queryid = -777001),
    4.00,
    'a 40/tick recent rate over a 10/tick baseline returns multiplier 4.00 (like units both sides)'
);

SELECT is(
    (SELECT format('%s|%s', recent_samples, baseline_samples)
     FROM pgfr_analyze.detect_query_storms()
     WHERE queryid = -777001),
    '2|2',
    'the sample counts behind both sides of the ratio travel with it'
);

SELECT * FROM finish();
ROLLBACK;
