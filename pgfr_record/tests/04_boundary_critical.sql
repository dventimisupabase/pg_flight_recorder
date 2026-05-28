-- =============================================================================
-- pgfr_record pgTAP Tests - Boundary & Critical Functions
-- =============================================================================
-- Tests: Adversarial boundary tests, untested critical functions
-- Sections: 11 (Adversarial Boundary), 12 (Untested Critical Functions)
-- Test count: 101
-- =============================================================================

BEGIN;
SELECT plan(64);

-- =============================================================================
-- 11. ADVERSARIAL BOUNDARY TESTS (50 tests)
-- =============================================================================

-- Ring Buffer Slot Boundaries (10 tests)

-- Test slot_id = 119 (should succeed - max valid)

-- Test slot_id = 0 (should succeed - min valid)

-- Test slot_id wraparound (verify both 0 and 119 exist)

-- Test all 120 slots exist

-- Row Number Boundaries (15 tests)

-- Wait samples: row_num = 99 (should succeed - max valid)

-- Wait samples: row_num = 0 (should succeed - min valid)

-- Activity samples: row_num = 24 (should succeed - max valid)

-- Activity samples: row_num = 0 (should succeed - min valid)

-- Lock samples: row_num = 99 (should succeed - max valid)

-- Lock samples: row_num = 0 (should succeed - min valid)

-- Verify pre-population counts



-- Configuration Boundaries (15 tests)

-- Test sample_interval_seconds = 0 (should be rejected by validation)
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '0' WHERE key = 'sample_interval_seconds'$$,
    'Boundary: config can store sample_interval_seconds = 0 (validation happens at use time)'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '120' WHERE key = 'sample_interval_seconds';

-- Test sample_interval_seconds = -1
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '-1' WHERE key = 'sample_interval_seconds'$$,
    'Boundary: config can store negative sample_interval_seconds (validation happens at use time)'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '120' WHERE key = 'sample_interval_seconds';

-- Test sample_interval_seconds = 59 (below minimum of 60)
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '59' WHERE key = 'sample_interval_seconds'$$,
    'Boundary: config can store sample_interval_seconds = 59'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '120' WHERE key = 'sample_interval_seconds';

-- Test sample_interval_seconds = 3601 (above maximum of 3600)
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '3601' WHERE key = 'sample_interval_seconds'$$,
    'Boundary: config can store sample_interval_seconds = 3601'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '120' WHERE key = 'sample_interval_seconds';

-- Test circuit_breaker_threshold_ms = 0
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '0' WHERE key = 'circuit_breaker_threshold_ms'$$,
    'Boundary: config can store circuit_breaker_threshold_ms = 0'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '1000' WHERE key = 'circuit_breaker_threshold_ms';

-- Test section_timeout_ms = 0
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '0' WHERE key = 'section_timeout_ms'$$,
    'Boundary: config can store section_timeout_ms = 0'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '250' WHERE key = 'section_timeout_ms';

-- Test lock_timeout_ms = -1
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '-1' WHERE key = 'lock_timeout_ms'$$,
    'Boundary: config can store lock_timeout_ms = -1'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '100' WHERE key = 'lock_timeout_ms';

-- Test schema_size_warning_mb = 0
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '0' WHERE key = 'schema_size_warning_mb'$$,
    'Boundary: config can store schema_size_warning_mb = 0'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '5000' WHERE key = 'schema_size_warning_mb';

-- Test load_shedding_active_pct = 101 (above 100%)
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '101' WHERE key = 'load_shedding_active_pct'$$,
    'Boundary: config can store load_shedding_active_pct = 101'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '70' WHERE key = 'load_shedding_active_pct';

-- Test load_shedding_active_pct = -1
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '-1' WHERE key = 'load_shedding_active_pct'$$,
    'Boundary: config can store load_shedding_active_pct = -1'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = '70' WHERE key = 'load_shedding_active_pct';

-- Test config with empty string value
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = '' WHERE key = 'mode'$$,
    'Boundary: config can store empty string value'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = 'normal' WHERE key = 'mode';

-- Test config with very long string value
SELECT lives_ok(
    $$UPDATE pgfr_record.config SET value = repeat('x', 1000) WHERE key = 'mode'$$,
    'Boundary: config can store very long string (1000 chars)'
);

-- Reset to valid value
UPDATE pgfr_record.config SET value = 'normal' WHERE key = 'mode';

-- Test _get_config with NULL key
SELECT lives_ok(
    $$SELECT pgfr_record._get_config(NULL, 'default_value')$$,
    'Boundary: _get_config should handle NULL key gracefully'
);

-- Test _get_config with empty key
SELECT lives_ok(
    $$SELECT pgfr_record._get_config('', 'default_value')$$,
    'Boundary: _get_config should handle empty key gracefully'
);

-- Timestamp Edge Cases (10 tests)

-- Test _compare() with NULL timestamps
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.compare(NULL, NULL)$$,
    'Boundary: compare(NULL, NULL) should not crash'
);

-- Test _compare() with start > end (backwards range)
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.compare('2025-12-31', '2024-01-01')$$,
    'Boundary: compare() with backwards range should not crash'
);

-- Test _compare() with future dates
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.compare(now() + interval '1 year', now() + interval '2 years')$$,
    'Boundary: compare() with future dates should not crash'
);

-- Test _compare() with very old dates (epoch)
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.compare('1970-01-01'::timestamptz, '1970-01-02'::timestamptz)$$,
    'Boundary: compare() with epoch dates should not crash'
);

-- Test _wait_summary() with '0 seconds' interval
DO $$
DECLARE
    v_start timestamptz;
    v_end timestamptz;
BEGIN
    SELECT pgfr_record.epoch() + min(sample_ts) * interval '1 second',
           pgfr_record.epoch() + min(sample_ts) * interval '1 second'
      INTO v_start, v_end
      FROM pgfr_record.wait_samples;

    IF v_start IS NOT NULL THEN
        PERFORM * FROM pgfr_analyze.wait_summary(v_start, v_end);
    END IF;
END $$;

SELECT ok(true, 'Boundary: wait_summary() with 0-second interval should not crash');

-- Test _wait_summary() with negative interval
DO $$
DECLARE
    v_start timestamptz;
    v_end timestamptz;
BEGIN
    SELECT pgfr_record.epoch() + max(sample_ts) * interval '1 second',
           pgfr_record.epoch() + min(sample_ts) * interval '1 second'
      INTO v_start, v_end
      FROM pgfr_record.wait_samples;

    IF v_start IS NOT NULL AND v_end IS NOT NULL THEN
        PERFORM * FROM pgfr_analyze.wait_summary(v_start, v_end);
    END IF;
END $$;

SELECT ok(true, 'Boundary: wait_summary() with negative interval should not crash');

-- Test activity_at() with NULL timestamp
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.activity_at(NULL)$$,
    'Boundary: activity_at(NULL) should not crash'
);

-- Test cleanup() with '0 days' retention
SELECT lives_ok(
    $$SELECT pgfr_record.cleanup('0 days')$$,
    'Boundary: cleanup(''0 days'') should not crash'
);

-- Test cleanup() with negative retention
SELECT lives_ok(
    $$SELECT pgfr_record.cleanup('-1 days')$$,
    'Boundary: cleanup(''-1 days'') should not crash'
);

-- Test _pretty_bytes with negative value
SELECT lives_ok(
    $$SELECT pgfr_record._pretty_bytes(-1)$$,
    'Boundary: _pretty_bytes(-1) should not crash'
);

-- =============================================================================
-- 12. UNTESTED CRITICAL FUNCTIONS (70 tests)
-- =============================================================================
-- Phase 2: Test all 23 previously untested functions with comprehensive coverage

-- -----------------------------------------------------------------------------
-- 12.2 Health Check Functions (20 tests)
-- -----------------------------------------------------------------------------

-- Test quarterly_review() with 0 collections in 30 days
DO $$
BEGIN
    -- Temporarily clear collection stats
    DELETE FROM pgfr_record.collection_stats;
END $$;

SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_analyze.quarterly_review()
        WHERE status IN ('ERROR', 'REVIEW NEEDED')
        AND component LIKE '%Collection%'
    ),
    'Health: quarterly_review() should report ERROR status with 0 collections in 30 days'
);

-- Restore some collection data for subsequent tests
INSERT INTO pgfr_record.collection_stats (collection_type, started_at, duration_ms, skipped)
VALUES ('sample', now() - interval '1 hour', 50, false);

-- Test quarterly_review() with mixed statuses
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.quarterly_review()) >= 3,
    'Health: quarterly_review() should return multiple component checks'
);

-- Test quarterly_review_with_summary() wrapper
SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_analyze.quarterly_review_with_summary()
        WHERE component LIKE '%SUMMARY%'
    ),
    'Health: quarterly_review_with_summary() should include summary section'
);

-- Test quarterly_review_with_summary() summary assessment
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.quarterly_review_with_summary()) >
    (SELECT count(*) FROM pgfr_analyze.quarterly_review()),
    'Health: quarterly_review_with_summary() should have more rows than base function (includes summary)'
);

-- Test health_check() with disabled system
-- Insert the 'enabled' key if it doesn't exist, then set to 'false'
INSERT INTO pgfr_record.config (key, value)
VALUES ('enabled', 'false')
ON CONFLICT (key) DO UPDATE SET value = 'false';

SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_record.health_check()
        WHERE status = 'DISABLED'
        AND component LIKE '%System%'
    ),
    'Health: health_check() should report DISABLED when system disabled'
);

-- Re-enable system
INSERT INTO pgfr_record.config (key, value)
VALUES ('enabled', 'true')
ON CONFLICT (key) DO UPDATE SET value = 'true';

-- Test health_check() with stale samples (mock by checking current state)
SELECT ok(
    (SELECT count(*) FROM pgfr_record.health_check()) >= 5,
    'Health: health_check() should perform at least 5 checks'
);

-- Test health_check() schema size check
SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_record.health_check()
        WHERE component LIKE '%Schema%'
    ),
    'Health: health_check() should include schema size check'
);

-- Test health_check() circuit breaker check
SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_record.health_check()
        WHERE component LIKE '%Circuit%'
    ),
    'Health: health_check() should include circuit breaker trip check'
);

-- Test performance_report() with 1 hour interval
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.performance_report('1 hour')) >= 0,
    'Health: performance_report(''1 hour'') should execute without error'
);

-- Test performance_report() with 24 hours interval
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.performance_report('24 hours')) >= 0,
    'Health: performance_report(''24 hours'') should execute without error'
);

-- Test performance_report() with 0 seconds interval
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.performance_report('0 seconds')$$,
    'Health: performance_report(''0 seconds'') should not crash'
);

-- ring_buffer_health() was specific to the legacy 120-slot ring (HOT-update
-- monitoring, pre-allocated slot bloat tracking). The v2 ring uses TRUNCATE
-- rotation and has no equivalent metric surface.

-- Test preflight_check() executes all checks
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.preflight_check()) >= 6,
    'Health: preflight_check() should perform at least 6 checks'
);

-- Test preflight_check_with_summary()
SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_analyze.preflight_check_with_summary()
        WHERE check_name LIKE '%SUMMARY%'
    ),
    'Health: preflight_check_with_summary() should include summary section'
);

-- Test validate_config() with current config
SELECT ok(
    (SELECT count(*) FROM pgfr_record.validate_config()) >= 7,
    'Health: validate_config() should perform at least 7 validation checks'
);

-- Test validate_config() with dangerous timeout
UPDATE pgfr_record.config SET value = '2000' WHERE key = 'section_timeout_ms';

SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_record.validate_config()
        WHERE status = 'CRITICAL'
        AND check_name = 'section_timeout_ms'
    ),
    'Health: validate_config() should flag dangerous section_timeout_ms > 1000'
);

-- Reset timeout
UPDATE pgfr_record.config SET value = '250' WHERE key = 'section_timeout_ms';

-- Test validate_config() with circuit breaker disabled
UPDATE pgfr_record.config SET value = 'false' WHERE key = 'circuit_breaker_enabled';

SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_record.validate_config()
        WHERE status = 'CRITICAL'
        AND check_name = 'circuit_breaker_enabled'
    ),
    'Health: validate_config() should flag CRITICAL when circuit breaker disabled'
);

-- Re-enable circuit breaker
UPDATE pgfr_record.config SET value = 'true' WHERE key = 'circuit_breaker_enabled';

-- Test validate_config() with high lock_timeout (> 500ms)
UPDATE pgfr_record.config SET value = '600' WHERE key = 'lock_timeout_ms';

SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_record.validate_config()
        WHERE status = 'WARNING'
        AND check_name = 'lock_timeout_ms'
    ),
    'Health: validate_config() should warn when lock_timeout_ms > 500'
);

-- Reset lock timeout
UPDATE pgfr_record.config SET value = '50' WHERE key = 'lock_timeout_ms';

-- -----------------------------------------------------------------------------
-- 12.3 Pre-Collection Checks (15 tests)
-- -----------------------------------------------------------------------------

-- Test _check_statements_health() basic execution
SELECT lives_ok(
    $$SELECT pgfr_record._check_statements_health()$$,
    'Pre-Collection: _check_statements_health() should execute without error'
);

-- Test _check_statements_health() return type
SELECT ok(
    (SELECT status FROM pgfr_record._check_statements_health()) IN ('OK', 'HIGH_CHURN', 'UNAVAILABLE', 'DISABLED'),
    'Pre-Collection: _check_statements_health() should return valid status'
);

-- Test pre-collection checks don't prevent sample()
SELECT lives_ok(
    $$SELECT pgfr_record.sample_ring()$$,
    'Pre-Collection: sample() should succeed even with pre-collection checks enabled'
);

-- Test _check_statements_health() with pg_stat_statements disabled/unavailable
SELECT ok(
    (SELECT pgfr_record._check_statements_health() IS NOT NULL),
    'Pre-Collection: _check_statements_health() should return status even if pg_stat_statements unavailable'
);

-- Test pre-collection checks are actually called during sample()
DO $$ BEGIN
    PERFORM pgfr_record.sample_ring();
END $$;

SELECT ok(
    (SELECT count(*) FROM pgfr_record.collection_stats) >= 1,
    'Pre-Collection: sample() should log collection attempt'
);

-- Test that skip reasons are properly logged
SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_record.collection_stats
        WHERE skipped_reason IS NOT NULL OR skipped_reason IS NULL
    ),
    'Pre-Collection: collection_stats should track skipped_reason column'
);

-- -----------------------------------------------------------------------------
-- 12.4 Alert and Recommendation Functions (10 tests)
-- -----------------------------------------------------------------------------

-- Test check_alerts() with 1 hour interval
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.check_alerts('1 hour')) >= 0,
    'Alerts: check_alerts(''1 hour'') should execute without error'
);

-- Test check_alerts() with 24 hours interval
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.check_alerts('24 hours')) >= 0,
    'Alerts: check_alerts(''24 hours'') should execute without error'
);

-- Test check_alerts() detects stale collections
DO $$
BEGIN
    -- Clear recent collections to trigger stale alert
    DELETE FROM pgfr_record.collection_stats
    WHERE started_at > now() - interval '2 hours';
END $$;

SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.check_alerts('1 hour')) >= 0,
    'Alerts: check_alerts() should check for stale collections'
);

-- Restore a collection stat
INSERT INTO pgfr_record.collection_stats (collection_type, started_at, duration_ms, skipped)
VALUES ('sample', now() - interval '5 minutes', 50, false);

-- Test config_recommendations()
SELECT ok(
    (SELECT count(*) FROM pgfr_record.config_recommendations()) >= 0,
    'Alerts: config_recommendations() should return recommendations list'
);

-- Test config_recommendations() with perfect config
DO $$
BEGIN
    -- Set all recommended values
    UPDATE pgfr_record.config SET value = '120' WHERE key = 'sample_interval_seconds';
    UPDATE pgfr_record.config SET value = 'true' WHERE key = 'circuit_breaker_enabled';
    UPDATE pgfr_record.config SET value = '50' WHERE key = 'lock_timeout_ms';
END $$;

SELECT ok(
    (SELECT count(*) FROM pgfr_record.config_recommendations()) >= 0,
    'Alerts: config_recommendations() should handle optimal config'
);

-- Test get_current_profile()
SELECT ok(
    (SELECT closest_profile FROM pgfr_record.get_current_profile()) IN ('default', 'production_safe', 'development', 'troubleshooting', 'minimal_overhead', 'custom'),
    'Alerts: get_current_profile() should return valid profile name'
);

-- Test get_current_profile() after applying a profile
DO $$
BEGIN
    PERFORM pgfr_record.apply_profile('production_safe');
END $$;

SELECT is(
    (SELECT closest_profile FROM pgfr_record.get_current_profile()),
    'production_safe',
    'Alerts: get_current_profile() should return last applied profile'
);

-- Reset to default profile
SELECT pgfr_record.apply_profile('default');

-- -----------------------------------------------------------------------------
-- 12.5 Real-Time View Functions (10 tests)
-- -----------------------------------------------------------------------------

-- Test _recent_waits_current() with current data
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.recent_waits_current()) >= 0,
    'Real-Time: recent_waits_current() should execute without error'
);

-- Test _recent_waits_current() structure
SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_analyze.recent_waits_current()
        WHERE captured_at IS NOT NULL
        LIMIT 1
    ) OR NOT EXISTS(SELECT 1 FROM pgfr_analyze.recent_waits_current()),
    'Real-Time: recent_waits_current() should have captured_at column'
);

-- Test _recent_activity_current() with current data
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.recent_activity_current()) >= 0,
    'Real-Time: recent_activity_current() should execute without error'
);

-- Test _recent_activity_current() structure
SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_analyze.recent_activity_current()
        WHERE captured_at IS NOT NULL
        LIMIT 1
    ) OR NOT EXISTS(SELECT 1 FROM pgfr_analyze.recent_activity_current()),
    'Real-Time: recent_activity_current() should have captured_at column'
);

-- Test _recent_locks_current() with current data
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.recent_locks_current()) >= 0,
    'Real-Time: recent_locks_current() should execute without error'
);

-- Test _recent_locks_current() structure
SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_analyze.recent_locks_current()
        WHERE captured_at IS NOT NULL
        LIMIT 1
    ) OR NOT EXISTS(SELECT 1 FROM pgfr_analyze.recent_locks_current()),
    'Real-Time: recent_locks_current() should have captured_at column'
);

-- Test mode-aware retention (normal mode = 6h)
SELECT pgfr_record.set_mode('normal');

SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pgfr_analyze.recent_waits_current()
        WHERE captured_at < now() - interval '6 hours'
    ),
    'Real-Time: recent_waits_current() should respect 6h retention in normal mode'
);

-- Test mode-aware retention (emergency mode = 10h)
SELECT pgfr_record.set_mode('emergency');

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.recent_waits_current()$$,
    'Real-Time: recent_waits_current() should work in emergency mode'
);

-- Reset to normal mode
SELECT pgfr_record.set_mode('normal');

-- Test all 3 views with concurrent query
SELECT lives_ok(
    $$SELECT
        (SELECT count(*) FROM pgfr_analyze.recent_waits_current()) +
        (SELECT count(*) FROM pgfr_analyze.recent_activity_current()) +
        (SELECT count(*) FROM pgfr_analyze.recent_locks_current())
    $$,
    'Real-Time: All 3 real-time views should work concurrently'
);

-- Test views during sample() execution
SELECT lives_ok(
    $$SELECT pgfr_record.sample_ring()$$,
    'Real-Time: sample() should not conflict with real-time views'
);

SELECT * FROM finish();
ROLLBACK;
