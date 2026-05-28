-- =============================================================================
-- pgfr_record pgTAP Tests - Ring Buffer Optimization
-- =============================================================================
-- Tests: Configurable ring buffer slots, validation, profiles, rebuild
-- Test count: 25
-- =============================================================================

BEGIN;
SELECT plan(25);

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

-- =============================================================================
-- 4. REBUILD FUNCTION TESTS (7 tests)
-- =============================================================================

-- Test rebuild_ring_buffers() exists
SELECT has_function(
    'pgfr_record',
    'rebuild_ring_buffers',
    'rebuild_ring_buffers() should exist'
);

-- Test rebuild_ring_buffers() returns no-op message when already at target size
SELECT ok(
    pgfr_record.rebuild_ring_buffers() LIKE '%already sized%',
    'rebuild_ring_buffers() should return no-op message when already at 120 slots'
);

-- Test samples_ring has correct row count (120)
SELECT is(
    (SELECT count(*) FROM pgfr_record.samples_ring_legacy),
    120::bigint,
    'samples_ring should have 120 rows'
);

-- Test wait_samples_ring has correct row count (120 * 100)
SELECT is(
    (SELECT count(*) FROM pgfr_record.wait_samples_ring_legacy),
    12000::bigint,
    'wait_samples_ring should have 12000 rows (120 slots x 100 rows)'
);

-- Test rebuild_ring_buffers() can resize to 72 slots
SELECT ok(
    pgfr_record.rebuild_ring_buffers(72) LIKE '%rebuilt%',
    'rebuild_ring_buffers(72) should succeed'
);

-- Verify resize worked
SELECT is(
    (SELECT count(*) FROM pgfr_record.samples_ring_legacy),
    72::bigint,
    'samples_ring should have 72 rows after rebuild'
);

-- Restore to default
SELECT pgfr_record.rebuild_ring_buffers(120);

-- Test rebuild_ring_buffers() rejects invalid slot count
SELECT throws_ok(
    $$SELECT pgfr_record.rebuild_ring_buffers(50)$$,
    'Ring buffer slots must be between 72 and 2880. Got: 50',
    'rebuild_ring_buffers() should reject slot count below 72'
);

-- =============================================================================
-- 5. SAMPLE() DYNAMIC SLOT TESTS (3 tests)
-- =============================================================================

-- Test sample() works with default slots
SELECT lives_ok(
    $$SELECT pgfr_record.sample_ring()$$,
    'sample() should work with default 120 slots'
);

-- Test that sample() populates ring buffer
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.samples_ring_legacy
        WHERE epoch_seconds > 0
    ),
    'sample() should populate ring buffer with current epoch'
);

-- Test sample() respects slot range
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.samples_ring_legacy
        WHERE slot_id >= pgfr_record._get_ring_buffer_slots()
          AND epoch_seconds > 0
    ),
    'sample() should only populate slots within configured range'
);

-- =============================================================================
-- CLEANUP
-- =============================================================================

SELECT * FROM finish();
ROLLBACK;
