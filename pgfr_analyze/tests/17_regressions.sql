-- =============================================================================
-- pgfr_analyze pgTAP Tests - Performance Regression Detection
-- =============================================================================
-- Tests: pgfr_analyze.detect_regressions and pgfr_analyze._diagnose_regression_causes
-- Test count: 14
-- =============================================================================

BEGIN;
SELECT plan(14);

-- =============================================================================
-- 1. CONFIG SETTINGS (7 tests)
-- =============================================================================

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'regression_threshold_pct'),
    'regression_threshold_pct config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'regression_lookback_interval'),
    'regression_lookback_interval config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'regression_baseline_days'),
    'regression_baseline_days config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'regression_severity_low_max'),
    'regression_severity_low_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'regression_severity_medium_max'),
    'regression_severity_medium_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'regression_severity_high_max'),
    'regression_severity_high_max config setting should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'regression_detection_metric'),
    'regression_detection_metric config setting should exist'
);

-- =============================================================================
-- 2. FUNCTION EXISTENCE (2 tests)
-- =============================================================================

SELECT has_function(
    'pgfr_analyze', 'detect_regressions', ARRAY['interval', 'numeric'],
    'pgfr_analyze.detect_regressions(interval, numeric) function should exist'
);

SELECT has_function(
    'pgfr_analyze', '_diagnose_regression_causes', ARRAY['bigint'],
    'pgfr_analyze._diagnose_regression_causes(bigint) function should exist'
);

-- =============================================================================
-- 3. FUNCTION EXECUTION (5 tests)
-- =============================================================================

-- Test detect_regressions executes without error
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_regressions()$$,
    'detect_regressions() should execute without error'
);

-- Test detect_regressions with explicit parameters
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.detect_regressions('2 hours'::interval, 75.0)$$,
    'detect_regressions(interval, numeric) should execute without error'
);

-- Test _diagnose_regression_causes executes without error
SELECT lives_ok(
    $$SELECT pgfr_analyze._diagnose_regression_causes(12345)$$,
    '_diagnose_regression_causes() should execute without error'
);

-- Test detect_regressions returns expected columns
SELECT lives_ok(
    $$SELECT queryid, query_fingerprint, severity, baseline_avg_ms, current_avg_ms,
             change_pct, baseline_avg_buffers, current_avg_buffers, buffer_change_pct,
             detection_metric, probable_causes, z_score, baseline_samples, current_samples
      FROM pgfr_analyze.detect_regressions()$$,
    'detect_regressions() should return expected columns (including the #102 effect-size and sample-count disclosures)'
);

-- Test _diagnose_regression_causes returns text array
SELECT ok(
    pg_typeof(pgfr_analyze._diagnose_regression_causes(12345))::text = 'text[]',
    '_diagnose_regression_causes() should return text[]'
);

SELECT * FROM finish();
ROLLBACK;
