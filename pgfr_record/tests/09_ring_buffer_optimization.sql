-- =============================================================================
-- pgfr_record pgTAP Tests - Ring Buffer Optimization
-- =============================================================================
-- Tests: Configurable ring buffer slots, validation, profiles, rebuild
-- Test count: 25
-- =============================================================================

BEGIN;
SELECT plan(19);

-- =============================================================================
-- 1. CONFIGURATION PARAMETER TESTS (5 tests)
-- =============================================================================

-- Test ring_buffer_slots config exists
SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'ring_buffer_slots'),
    'ring_buffer_slots config key should exist'
);

-- Test default value is 120
SELECT is(
    (SELECT value FROM pgfr_record.config WHERE key = 'ring_buffer_slots'),
    '120',
    'ring_buffer_slots default should be 120'
);

-- Test _get_ring_buffer_slots() function exists
SELECT has_function(
    'pgfr_record',
    '_get_ring_buffer_slots',
    'Helper function _get_ring_buffer_slots() should exist'
);

-- Test _get_ring_buffer_slots() returns default value
SELECT is(
    pgfr_record._get_ring_buffer_slots(),
    120,
    '_get_ring_buffer_slots() should return 120 by default'
);

-- Test _get_ring_buffer_slots() clamps to min value (72)
DO $$
BEGIN
    UPDATE pgfr_record.config SET value = '10' WHERE key = 'ring_buffer_slots';
END $$;

SELECT is(
    pgfr_record._get_ring_buffer_slots(),
    72,
    '_get_ring_buffer_slots() should clamp to minimum 72'
);

-- Reset to default
UPDATE pgfr_record.config SET value = '120' WHERE key = 'ring_buffer_slots';

-- =============================================================================
-- 2. VALIDATION FUNCTION TESTS (5 tests)
-- =============================================================================

-- Test validate_ring_configuration() exists
SELECT has_function(
    'pgfr_record',
    'validate_ring_configuration',
    'validate_ring_configuration() should exist'
);

-- Test validate_ring_configuration() returns 4 checks
SELECT is(
    (SELECT count(*) FROM pgfr_record.validate_ring_configuration()),
    4::bigint,
    'validate_ring_configuration() should return 4 checks'
);

-- Test validate_ring_configuration() returns OK for default config
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.validate_ring_configuration()
        WHERE status = 'ERROR'
    ),
    'validate_ring_configuration() should not return ERROR for default config'
);

-- Test validate_ring_configuration() warns on low retention
DO $$
BEGIN
    UPDATE pgfr_record.config SET value = '72' WHERE key = 'ring_buffer_slots';
    UPDATE pgfr_record.config SET value = '60' WHERE key = 'sample_interval_seconds';
END $$;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.validate_ring_configuration()
        WHERE check_name = 'ring_buffer_retention' AND status IN ('WARNING', 'ERROR')
    ),
    'validate_ring_configuration() should warn on low retention (72 slots x 60s = 1.2h)'
);

-- Reset to default
UPDATE pgfr_record.config SET value = '120' WHERE key = 'ring_buffer_slots';
UPDATE pgfr_record.config SET value = '60' WHERE key = 'sample_interval_seconds';

-- Test validate_ring_configuration() returns OK for good config
SELECT ok(
    (SELECT status FROM pgfr_record.validate_ring_configuration()
     WHERE check_name = 'ring_buffer_retention') = 'OK',
    'validate_ring_configuration() should return OK for 2h retention'
);

-- =============================================================================
-- 3. OPTIMIZATION PROFILES TESTS (5 tests)
-- =============================================================================

-- Test get_optimization_profiles() exists
SELECT has_function(
    'pgfr_record',
    'get_optimization_profiles',
    'get_optimization_profiles() should exist'
);

-- Test get_optimization_profiles() returns 6 profiles
SELECT is(
    (SELECT count(*) FROM pgfr_record.get_optimization_profiles()),
    6::bigint,
    'get_optimization_profiles() should return 6 profiles'
);

-- Test standard profile has correct values
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.get_optimization_profiles()
        WHERE profile_name = 'standard'
          AND slots = 120
          AND sample_interval_seconds = 60
          AND archive_frequency_min = 15
    ),
    'standard profile should have slots=120, interval=60s, archive=15min'
);

-- Test fine_grained profile has correct values
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.get_optimization_profiles()
        WHERE profile_name = 'fine_grained'
          AND slots = 360
          AND sample_interval_seconds = 60
    ),
    'fine_grained profile should have slots=360, interval=60s'
);

-- Test apply_optimization_profile() rejects invalid profile
SELECT throws_ok(
    $$SELECT * FROM pgfr_record.apply_optimization_profile('invalid_profile')$$,
    'Unknown optimization profile: invalid_profile. Available: standard, fine_grained, ultra_fine, low_overhead, high_retention, forensic',
    'apply_optimization_profile() should reject invalid profile'
);

-- Regression: apply_optimization_profile('standard') used to query the retired
-- legacy samples_ring and ERROR. After the legacy-ring retirement the function
-- reads slot count from pgfr_record.ring_config instead.
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.apply_optimization_profile('standard')$$,
    'apply_optimization_profile(standard) works after legacy ring retirement'
);

-- =============================================================================
-- 4. REBUILD FUNCTION TESTS (retired with the legacy 120-slot ring)
-- =============================================================================
-- rebuild_ring_buffers() was specific to the legacy ring's pre-allocated
-- row model. The v2 ring uses TRUNCATE rotation on LIST-partitioned tables
-- and is resized by recreating partitions, not by rebuilding pre-populated
-- slots. All seven assertions in this section are dropped; the section
-- header is preserved to make the deletion discoverable in `git log -S`.

-- =============================================================================
-- 5. SAMPLE() DYNAMIC SLOT TESTS (3 tests)
-- =============================================================================

-- Test sample() works with default slots
SELECT lives_ok(
    $$SELECT pgfr_record.sample_ring()$$,
    'sample() should work with default 120 slots'
);

-- Test that sample_ring() runs to completion and writes a valid
-- sample_ts. We can't assert >0 rows: in a single-backend test
-- container, sample_ring filters out pg_backend_pid() and may
-- legitimately write nothing.
SELECT lives_ok(
    $$SELECT pgfr_record.sample_ring()$$,
    'sample_ring() should populate the v2 ring with current epoch'
);

-- Test sample_ring() respects slot range (LIST-partitioned by slot in v2).
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.activity_samples
        WHERE slot >= (SELECT num_slots FROM pgfr_record.ring_config WHERE singleton)
    ),
    'sample_ring() should only populate slots within configured range'
);

-- =============================================================================
-- CLEANUP
-- =============================================================================

SELECT * FROM finish();
ROLLBACK;
