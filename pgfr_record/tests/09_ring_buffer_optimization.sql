-- =============================================================================
-- pgfr_record pgTAP Tests - Ring Configuration (Issue #106 retirement)
-- =============================================================================
-- This file used to test the legacy ring's optimization-profile subsystem
-- (ring_buffer_slots, sample_interval_seconds, archive_sample_frequency_minutes,
-- get/apply_optimization_profile, _get_ring_buffer_slots). Issue #106 retired
-- all of it: every knob belonged to the retired 120-slot ring and controlled
-- nothing in the v2 path, while presenting itself as live. These tests now
-- assert the retirement (nothing resurrects the dead keys or functions) and
-- exercise the rewritten validate_ring_configuration(), which reads the live
-- v2 state instead of fabricating figures from dead config.
-- =============================================================================

BEGIN;
SELECT plan(14);

-- -----------------------------------------------------------------------------
-- 1. The retired config keys are gone and stay gone
-- -----------------------------------------------------------------------------

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'sample_interval_seconds'),
    'sample_interval_seconds key is not seeded (retired; cadence is a fixed design constant)'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'ring_buffer_slots'),
    'ring_buffer_slots key is not seeded (retired with the legacy ring)'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'archive_sample_frequency_minutes'),
    'archive_sample_frequency_minutes key is not seeded (retired with the legacy archiver)'
);

-- Upgraded installs: migrate_config_keys() deletes leftovers.
INSERT INTO pgfr_record.config (key, value) VALUES ('sample_interval_seconds', '300');
SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.migrate_config_keys()
            WHERE old_key = 'sample_interval_seconds'
              AND action LIKE 'deleted (retired%'),
    'migrate_config_keys() reports the retired key deletion'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'sample_interval_seconds'),
    'migrate_config_keys() removes a leftover sample_interval_seconds row'
);

-- -----------------------------------------------------------------------------
-- 2. The retired functions are gone
-- -----------------------------------------------------------------------------

SELECT hasnt_function('pgfr_record', 'get_optimization_profiles',
    'get_optimization_profiles() is retired');
SELECT hasnt_function('pgfr_record', 'apply_optimization_profile', ARRAY['text'],
    'apply_optimization_profile() is retired');
SELECT hasnt_function('pgfr_record', '_get_ring_buffer_slots',
    '_get_ring_buffer_slots() is retired');
SELECT hasnt_function('pgfr_record', '_get_ring_retention_interval',
    '_get_ring_retention_interval() is retired');

-- -----------------------------------------------------------------------------
-- 3. validate_ring_configuration() reads the live v2 state
-- -----------------------------------------------------------------------------

SELECT has_function('pgfr_record', 'validate_ring_configuration',
    'validate_ring_configuration() exists');

SELECT is(
    (SELECT array_agg(check_name ORDER BY check_name)
     FROM pgfr_record.validate_ring_configuration()),
    ARRAY['ring_buffer_retention', 'ring_rotation', 'ring_storage', 'sampler_cost'],
    'the four checks cover retention, rotation health, measured cost, and measured storage'
);

-- Default install: 3 slots x 2 hour rotation = 6 hour nominal window -> OK.
SELECT is(
    (SELECT status FROM pgfr_record.validate_ring_configuration()
     WHERE check_name = 'ring_buffer_retention'),
    'OK',
    'default ring configuration (3 slots x 2h) validates OK'
);

SELECT ok(
    (SELECT message LIKE '%nominal window%'
     FROM pgfr_record.validate_ring_configuration()
     WHERE check_name = 'ring_buffer_retention'),
    'retention message states the window comes from ring_config, with the on-hand range'
);

SELECT ok(
    (SELECT message LIKE '%measured%'
     FROM pgfr_record.validate_ring_configuration()
     WHERE check_name = 'ring_storage'),
    'storage figure is measured from the ring tables, not estimated from dead config'
);

SELECT * FROM finish();
ROLLBACK;
