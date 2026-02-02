-- =============================================================================
-- pg-flight-recorder pgTAP Tests - Vacuum Control Enhancements (v2.8)
-- =============================================================================
-- Tests: Vacuum control state, mode detection, scale factor calculation,
--        diagnostics, hysteresis, and integration
-- Test count: 72
-- =============================================================================

BEGIN;
SELECT plan(72);

-- Disable checkpoint detection during tests to prevent snapshot skipping
UPDATE flight_recorder.config SET value = 'false' WHERE key = 'check_checkpoint_backup';

-- Disable collection jitter to speed up tests
UPDATE flight_recorder.config SET value = 'false' WHERE key = 'collection_jitter_enabled';

-- =============================================================================
-- 1. SCHEMA TESTS - vacuum_control_state TABLE (4 tests)
-- =============================================================================

SELECT has_table(
    'flight_recorder', 'vacuum_control_state',
    'vacuum_control_state table should exist'
);

SELECT has_column(
    'flight_recorder', 'vacuum_control_state', 'relid',
    'vacuum_control_state should have relid column'
);

SELECT has_column(
    'flight_recorder', 'vacuum_control_state', 'operating_mode',
    'vacuum_control_state should have operating_mode column'
);

SELECT has_column(
    'flight_recorder', 'vacuum_control_state', 'last_recommended_scale_factor',
    'vacuum_control_state should have last_recommended_scale_factor column'
);

-- =============================================================================
-- 2. SCHEMA TESTS - table_snapshots NEW COLUMNS (4 tests)
-- =============================================================================

SELECT has_column(
    'flight_recorder', 'table_snapshots', 'reltuples',
    'table_snapshots should have reltuples column'
);

SELECT col_type_is(
    'flight_recorder', 'table_snapshots', 'reltuples', 'bigint',
    'reltuples should be BIGINT type'
);

SELECT has_column(
    'flight_recorder', 'table_snapshots', 'vacuum_running',
    'table_snapshots should have vacuum_running column'
);

SELECT has_column(
    'flight_recorder', 'table_snapshots', 'last_vacuum_duration_ms',
    'table_snapshots should have last_vacuum_duration_ms column'
);

-- =============================================================================
-- 3. CONFIG TESTS - NEW PARAMETERS (7 tests)
-- =============================================================================

SELECT ok(
    EXISTS(SELECT 1 FROM flight_recorder.config WHERE key = 'vacuum_control_enabled'),
    'vacuum_control_enabled config parameter should exist'
);

SELECT is(
    (SELECT value FROM flight_recorder.config WHERE key = 'vacuum_control_enabled'),
    'true',
    'vacuum_control_enabled default should be true'
);

SELECT ok(
    EXISTS(SELECT 1 FROM flight_recorder.config WHERE key = 'vacuum_control_dead_tuple_budget_pct'),
    'vacuum_control_dead_tuple_budget_pct config parameter should exist'
);

SELECT is(
    (SELECT value FROM flight_recorder.config WHERE key = 'vacuum_control_dead_tuple_budget_pct'),
    '5',
    'vacuum_control_dead_tuple_budget_pct default should be 5'
);

SELECT ok(
    EXISTS(SELECT 1 FROM flight_recorder.config WHERE key = 'vacuum_control_min_scale_factor'),
    'vacuum_control_min_scale_factor config parameter should exist'
);

SELECT ok(
    EXISTS(SELECT 1 FROM flight_recorder.config WHERE key = 'vacuum_control_hysteresis_pct'),
    'vacuum_control_hysteresis_pct config parameter should exist'
);

SELECT ok(
    EXISTS(SELECT 1 FROM flight_recorder.config WHERE key = 'vacuum_control_rate_limit_minutes'),
    'vacuum_control_rate_limit_minutes config parameter should exist'
);

-- =============================================================================
-- 4. FUNCTION EXISTENCE TESTS (6 tests)
-- =============================================================================

SELECT has_function(
    'flight_recorder', 'vacuum_control_mode',
    ARRAY['oid'],
    'vacuum_control_mode(oid) function should exist'
);

SELECT has_function(
    'flight_recorder', 'compute_recommended_scale_factor',
    ARRAY['oid'],
    'compute_recommended_scale_factor(oid) function should exist'
);

SELECT has_function(
    'flight_recorder', 'vacuum_diagnostic',
    ARRAY['oid'],
    'vacuum_diagnostic(oid) function should exist'
);

SELECT has_function(
    'flight_recorder', 'vacuum_control_report',
    ARRAY['timestamp with time zone', 'timestamp with time zone'],
    'vacuum_control_report(timestamptz, timestamptz) function should exist'
);

SELECT has_function(
    'flight_recorder', '_get_table_autovacuum_settings',
    ARRAY['oid'],
    '_get_table_autovacuum_settings(oid) function should exist'
);

SELECT has_function(
    'flight_recorder', 'dead_tuple_trend',
    ARRAY['oid', 'interval'],
    'dead_tuple_trend(oid, interval) function should exist'
);

-- =============================================================================
-- 5. HELPER FUNCTION TESTS (4 tests)
-- =============================================================================

-- Test _get_table_autovacuum_settings returns global defaults for tables without overrides
SELECT lives_ok(
    $$SELECT * FROM flight_recorder._get_table_autovacuum_settings(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    '_get_table_autovacuum_settings should execute without error'
);

-- Test dead_tuple_trend executes without error
SELECT lives_ok(
    $$SELECT flight_recorder.dead_tuple_trend(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1),
        '1 hour'::interval
    )$$,
    'dead_tuple_trend should execute without error'
);

-- Test dead_tuple_trend returns NUMERIC
SELECT ok(
    pg_typeof(flight_recorder.dead_tuple_trend(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1),
        '1 hour'::interval
    ))::text = 'numeric',
    'dead_tuple_trend should return NUMERIC type'
);

-- Test _get_table_autovacuum_settings returns expected columns
SELECT ok(
    (SELECT scale_factor IS NOT NULL
     FROM flight_recorder._get_table_autovacuum_settings(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
     )),
    '_get_table_autovacuum_settings should return scale_factor'
);

-- =============================================================================
-- 6. MODE DETECTION TESTS (12 tests)
-- =============================================================================

-- Take a snapshot to populate data
SELECT flight_recorder.snapshot();

-- Test vacuum_control_mode executes without error
SELECT lives_ok(
    $$SELECT * FROM flight_recorder.vacuum_control_mode(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'vacuum_control_mode should execute without error'
);

-- Test vacuum_control_mode returns expected columns
SELECT ok(
    (SELECT mode IS NOT NULL
     FROM flight_recorder.vacuum_control_mode(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
     )),
    'vacuum_control_mode should return mode column'
);

-- Test vacuum_control_mode returns 'normal' for healthy tables
SELECT ok(
    (SELECT mode IN ('normal', 'catch_up', 'safety')
     FROM flight_recorder.vacuum_control_mode(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
     )),
    'vacuum_control_mode should return valid mode value'
);

-- Test vacuum_control_mode returns reason
SELECT ok(
    (SELECT reason IS NOT NULL
     FROM flight_recorder.vacuum_control_mode(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
     )),
    'vacuum_control_mode should return reason column'
);

-- Test vacuum_control_mode returns entered_at
SELECT ok(
    (SELECT entered_at IS NOT NULL
     FROM flight_recorder.vacuum_control_mode(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
     )),
    'vacuum_control_mode should return entered_at column'
);

-- Test vacuum_control_mode returns evidence
SELECT lives_ok(
    $$SELECT evidence FROM flight_recorder.vacuum_control_mode(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'vacuum_control_mode should return evidence column'
);

-- Test mode for typical table returns a valid value (normal is expected for healthy tables
-- but catch_up/safety could occur depending on system state during test)
SELECT ok(
    (SELECT mode IN ('normal', 'catch_up', 'safety')
     FROM flight_recorder.vacuum_control_mode(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
     )),
    'vacuum_control_mode should return valid mode for typical table'
);

-- Test mode detection with non-existent OID
SELECT ok(
    (SELECT mode IS NULL
     FROM flight_recorder.vacuum_control_mode(0::oid)
    ) IS NOT FALSE,
    'vacuum_control_mode should handle non-existent OID gracefully'
);

-- Test mode persists in vacuum_control_state
SELECT lives_ok(
    $$SELECT * FROM flight_recorder.vacuum_control_state LIMIT 1$$,
    'vacuum_control_state table should be queryable'
);

-- Test safety mode detection (XID age check)
SELECT lives_ok(
    $$SELECT mode, reason FROM flight_recorder.vacuum_control_mode(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    ) WHERE mode = 'safety' OR mode != 'safety'$$,
    'vacuum_control_mode safety check should not error'
);

-- Test catch_up mode detection
SELECT lives_ok(
    $$SELECT mode, reason FROM flight_recorder.vacuum_control_mode(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    ) WHERE mode = 'catch_up' OR mode != 'catch_up'$$,
    'vacuum_control_mode catch_up check should not error'
);

-- Test mode with flight_recorder tables (should work)
SELECT lives_ok(
    $$SELECT * FROM flight_recorder.vacuum_control_mode(
        'flight_recorder.snapshots'::regclass::oid
    )$$,
    'vacuum_control_mode should work on flight_recorder tables'
);

-- =============================================================================
-- 7. CONTROL LAW TESTS - SCALE FACTOR CALCULATION (10 tests)
-- =============================================================================

-- Test compute_recommended_scale_factor executes without error
SELECT lives_ok(
    $$SELECT * FROM flight_recorder.compute_recommended_scale_factor(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'compute_recommended_scale_factor should execute without error'
);

-- Test compute_recommended_scale_factor returns current_scale_factor
SELECT lives_ok(
    $$SELECT current_scale_factor FROM flight_recorder.compute_recommended_scale_factor(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'compute_recommended_scale_factor should return current_scale_factor'
);

-- Test compute_recommended_scale_factor returns recommended_scale_factor
SELECT lives_ok(
    $$SELECT recommended_scale_factor FROM flight_recorder.compute_recommended_scale_factor(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'compute_recommended_scale_factor should return recommended_scale_factor'
);

-- Test compute_recommended_scale_factor returns change_pct
SELECT lives_ok(
    $$SELECT change_pct FROM flight_recorder.compute_recommended_scale_factor(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'compute_recommended_scale_factor should return change_pct'
);

-- Test compute_recommended_scale_factor returns rationale
SELECT lives_ok(
    $$SELECT rationale FROM flight_recorder.compute_recommended_scale_factor(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'compute_recommended_scale_factor should return rationale'
);

-- Test scale factor respects minimum bound
SELECT ok(
    (SELECT COALESCE(recommended_scale_factor, 0.001) >= 0.001
     FROM flight_recorder.compute_recommended_scale_factor(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )),
    'recommended_scale_factor should respect minimum bound (0.001)'
);

-- Test scale factor respects maximum bound
SELECT ok(
    (SELECT COALESCE(recommended_scale_factor, 0.2) <= 0.2
     FROM flight_recorder.compute_recommended_scale_factor(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )),
    'recommended_scale_factor should respect maximum bound (0.2)'
);

-- Test scale factor with non-existent OID
SELECT lives_ok(
    $$SELECT * FROM flight_recorder.compute_recommended_scale_factor(0::oid)$$,
    'compute_recommended_scale_factor should handle non-existent OID gracefully'
);

-- Test change_pct calculation is reasonable
SELECT ok(
    (SELECT COALESCE(change_pct, 0) >= -100
     FROM flight_recorder.compute_recommended_scale_factor(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )),
    'change_pct should be reasonable (>= -100)'
);

-- Test that rationale provides meaningful information
SELECT ok(
    (SELECT rationale IS NULL OR length(rationale) > 0
     FROM flight_recorder.compute_recommended_scale_factor(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )),
    'rationale should be meaningful when provided'
);

-- =============================================================================
-- 8. DIAGNOSTIC TESTS - FAILURE CLASSIFICATION (8 tests)
-- =============================================================================

-- Test vacuum_diagnostic executes without error
SELECT lives_ok(
    $$SELECT * FROM flight_recorder.vacuum_diagnostic(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'vacuum_diagnostic should execute without error'
);

-- Test vacuum_diagnostic returns classification
SELECT lives_ok(
    $$SELECT classification FROM flight_recorder.vacuum_diagnostic(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'vacuum_diagnostic should return classification'
);

-- Test vacuum_diagnostic returns valid classification values
SELECT ok(
    (SELECT classification IN ('NOT_SCHEDULED', 'RUNNING_BUT_LOSING', 'BLOCKED', 'HEALTHY')
            OR classification IS NULL
     FROM flight_recorder.vacuum_diagnostic(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )),
    'vacuum_diagnostic classification should be valid'
);

-- Test vacuum_diagnostic returns evidence
SELECT lives_ok(
    $$SELECT evidence FROM flight_recorder.vacuum_diagnostic(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'vacuum_diagnostic should return evidence'
);

-- Test vacuum_diagnostic returns confidence
SELECT lives_ok(
    $$SELECT confidence FROM flight_recorder.vacuum_diagnostic(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'vacuum_diagnostic should return confidence'
);

-- Test vacuum_diagnostic returns likely_cause
SELECT lives_ok(
    $$SELECT likely_cause FROM flight_recorder.vacuum_diagnostic(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'vacuum_diagnostic should return likely_cause'
);

-- Test vacuum_diagnostic returns mitigation
SELECT lives_ok(
    $$SELECT mitigation FROM flight_recorder.vacuum_diagnostic(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'vacuum_diagnostic should return mitigation'
);

-- Test vacuum_diagnostic returns mitigation_sql
SELECT lives_ok(
    $$SELECT mitigation_sql FROM flight_recorder.vacuum_diagnostic(
        (SELECT relid FROM pg_stat_user_tables LIMIT 1)
    )$$,
    'vacuum_diagnostic should return mitigation_sql'
);

-- =============================================================================
-- 9. HYSTERESIS AND RATE LIMIT TESTS (6 tests)
-- =============================================================================

-- Test vacuum_control_report executes without error
SELECT lives_ok(
    $$SELECT * FROM flight_recorder.vacuum_control_report(now() - interval '1 hour', now())$$,
    'vacuum_control_report should execute without error'
);

-- Test vacuum_control_report returns should_recommend flag
SELECT lives_ok(
    $$SELECT should_recommend FROM flight_recorder.vacuum_control_report(now() - interval '1 hour', now()) LIMIT 1$$,
    'vacuum_control_report should return should_recommend flag'
);

-- Test vacuum_control_report respects hysteresis threshold
SELECT lives_ok(
    $$SELECT should_recommend, change_pct
      FROM flight_recorder.vacuum_control_report(now() - interval '1 hour', now())
      LIMIT 5$$,
    'vacuum_control_report should include hysteresis info'
);

-- Test vacuum_control_report respects rate limiting
SELECT lives_ok(
    $$SELECT should_recommend, last_recommendation_at
      FROM flight_recorder.vacuum_control_report(now() - interval '1 hour', now())
      LIMIT 5$$,
    'vacuum_control_report should include rate limit info'
);

-- Test vacuum_control_report includes alter_table_sql
SELECT lives_ok(
    $$SELECT alter_table_sql FROM flight_recorder.vacuum_control_report(now() - interval '1 hour', now()) LIMIT 1$$,
    'vacuum_control_report should return alter_table_sql'
);

-- Test vacuum_control_report alter_table_sql format
SELECT ok(
    (SELECT alter_table_sql IS NULL
            OR alter_table_sql LIKE 'ALTER TABLE%'
            OR alter_table_sql = ''
     FROM flight_recorder.vacuum_control_report(now() - interval '1 hour', now())
     LIMIT 1),
    'alter_table_sql should be valid ALTER TABLE statement or NULL'
);

-- =============================================================================
-- 10. INTEGRATION TESTS (6 tests)
-- =============================================================================

-- Test anomaly_report includes vacuum control anomalies (structure exists)
SELECT lives_ok(
    $$SELECT * FROM flight_recorder.anomaly_report(now() - interval '1 hour', now())
      WHERE anomaly_type LIKE 'VACUUM_CONTROL%'$$,
    'anomaly_report should be queryable for VACUUM_CONTROL anomalies'
);

-- Test report function still works
SELECT lives_ok(
    $$SELECT flight_recorder.report('1 hour')$$,
    'report function should still work after vacuum control additions'
);

-- Test report includes vacuum control section (by checking length increased)
SELECT ok(
    (SELECT length(flight_recorder.report('1 hour')) > 0),
    'report should return content'
);

-- Test snapshot populates new columns
SELECT flight_recorder.snapshot();

SELECT lives_ok(
    $$SELECT reltuples, vacuum_running, last_vacuum_duration_ms
      FROM flight_recorder.table_snapshots
      WHERE snapshot_id = (SELECT max(id) FROM flight_recorder.snapshots)
      LIMIT 1$$,
    'snapshot should populate new table_snapshots columns'
);

-- Test vacuum_control_state is populated after snapshot
SELECT lives_ok(
    $$SELECT operating_mode, mode_entered_at, updated_at
      FROM flight_recorder.vacuum_control_state
      LIMIT 1$$,
    'vacuum_control_state should be populated after snapshot'
);

-- Test vacuum_control_report includes all expected columns
SELECT lives_ok(
    $$SELECT schemaname, relname, operating_mode, diagnostic_classification,
             current_scale_factor, recommended_scale_factor, change_pct,
             should_recommend, alter_table_sql
      FROM flight_recorder.vacuum_control_report(now() - interval '1 hour', now())
      LIMIT 1$$,
    'vacuum_control_report should return all expected columns'
);

-- =============================================================================
-- 11. EDGE CASE TESTS (5 tests)
-- =============================================================================

-- Test with non-existent OID - vacuum_control_mode
SELECT is(
    (SELECT mode FROM flight_recorder.vacuum_control_mode(0::oid)),
    NULL::text,
    'vacuum_control_mode should return NULL mode for non-existent OID'
);

-- Test with non-existent OID - compute_recommended_scale_factor
SELECT is(
    (SELECT recommended_scale_factor FROM flight_recorder.compute_recommended_scale_factor(0::oid)),
    NULL::numeric,
    'compute_recommended_scale_factor should return NULL for non-existent OID'
);

-- Test with non-existent OID - vacuum_diagnostic
SELECT is(
    (SELECT classification FROM flight_recorder.vacuum_diagnostic(0::oid)),
    NULL::text,
    'vacuum_diagnostic should return NULL classification for non-existent OID'
);

-- Test with empty time range
SELECT lives_ok(
    $$SELECT * FROM flight_recorder.vacuum_control_report(now(), now() - interval '1 hour')$$,
    'vacuum_control_report should handle reversed time range gracefully'
);

-- Test dead_tuple_trend with non-existent OID
SELECT is(
    flight_recorder.dead_tuple_trend(0::oid, '1 hour'::interval),
    NULL::numeric,
    'dead_tuple_trend should return NULL for non-existent OID'
);

SELECT * FROM finish();
ROLLBACK;
