-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- schema bootstrap, config, _get_config()
-- =============================================================================

BEGIN;
SELECT plan(8);

SELECT has_schema('pgfr_analyze', 'Schema pgfr_analyze should exist');
SELECT has_table('pgfr_analyze', 'config', 'Table pgfr_analyze.config should exist');
SELECT has_function('pgfr_analyze', '_get_config', 'Function pgfr_analyze._get_config should exist');

SELECT is(
    pgfr_analyze._get_config('does_not_exist', 'fallback'),
    'fallback',
    '_get_config should return the default when the key is unset'
);

SELECT lives_ok(
    $$INSERT INTO pgfr_analyze.config (key, value) VALUES ('a_test_key', 'a_test_value')$$,
    'inserting a config row should succeed'
);
SELECT is(
    pgfr_analyze._get_config('a_test_key', 'fallback'),
    'a_test_value',
    '_get_config should return the stored value when the key is set'
);

-- pgfr_analyze must never write to pgfr_record's schema. Spot-check inside
-- a hard READ ONLY transaction: _get_config() reads only pgfr_analyze.config,
-- so it must succeed even when writes are disallowed entirely.
SAVEPOINT analyze_readonly;
SET TRANSACTION READ ONLY;
SELECT is(
    pgfr_analyze._get_config('a_test_key', 'fallback'),
    'a_test_value',
    '_get_config() should execute successfully inside a hard READ ONLY transaction'
);
ROLLBACK TO SAVEPOINT analyze_readonly;

SELECT throws_ok(
    $$INSERT INTO pgfr_analyze.config (key, value) VALUES ('a_test_key', 'a_duplicate')$$,
    '23505',
    NULL,
    'inserting a duplicate config key should violate the primary key'
);

SELECT * FROM finish();
ROLLBACK;
