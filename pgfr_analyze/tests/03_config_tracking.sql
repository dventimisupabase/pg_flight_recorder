-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- config_changes(), config_at(), config_health_check()
-- =============================================================================

BEGIN;
SELECT plan(13);

SELECT has_function('pgfr_analyze', 'config_changes', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.config_changes should exist');
SELECT has_function('pgfr_analyze', 'config_at', ARRAY['timestamptz', 'text'], 'Function pgfr_analyze.config_at should exist');
SELECT has_function('pgfr_analyze', 'config_health_check', 'Function pgfr_analyze.config_health_check should exist');

-- ---------------------------------------------------------------------------
-- config_changes() / config_at(): a real GUC change captured across two
-- pg_settings anchors (the first run_tier('on_change') call is always an
-- anchor -- no prior capture exists -- so it captures every setting; the
-- second is debounced and appends only what actually changed).
-- ---------------------------------------------------------------------------
SET work_mem = '4MB';
SELECT lives_ok($$SELECT pgfr_record.run_tier('on_change')$$, 'first on_change run (anchor) should capture pg_settings');
SELECT clock_timestamp() AS t0 \gset before_

SET work_mem = '32MB';
SELECT lives_ok($$SELECT pgfr_record.run_tier('on_change')$$, 'second on_change run should capture only the changed work_mem setting');
SELECT clock_timestamp() AS t1 \gset after_

SELECT is(
    (SELECT new_setting FROM pgfr_analyze.config_changes(:'before_t0'::timestamptz, :'after_t1'::timestamptz) WHERE name = 'work_mem'),
    '32768',
    'config_changes() should report work_mem''s new value (in its native kB unit)'
);
SELECT is(
    (SELECT old_setting FROM pgfr_analyze.config_changes(:'before_t0'::timestamptz, :'after_t1'::timestamptz) WHERE name = 'work_mem'),
    '4096',
    'config_changes() should report work_mem''s old value'
);
SELECT ok(
    (SELECT count(*)::int FROM pgfr_analyze.config_changes(:'before_t0'::timestamptz, :'after_t1'::timestamptz) WHERE name <> 'work_mem') = 0,
    'config_changes() should not report GUCs that did not actually change'
);

SELECT is(
    (SELECT setting FROM pgfr_analyze.config_at(:'after_t1'::timestamptz, 'work_mem')),
    '32768',
    'config_at() as of the second capture should show the new work_mem value'
);
SELECT is(
    (SELECT setting FROM pgfr_analyze.config_at(:'before_t0'::timestamptz, 'work_mem')),
    '4096',
    'config_at() as of the first capture should show the original work_mem value'
);
SELECT ok(
    (SELECT count(*)::int FROM pgfr_analyze.config_at(:'after_t1'::timestamptz, 'nonexistent_prefix_xyz')) = 0,
    'config_at() with a non-matching name prefix should return zero rows'
);

-- ---------------------------------------------------------------------------
-- config_health_check(): live-catalog checks, not historical.
-- ---------------------------------------------------------------------------
SET work_mem = '4MB';
SELECT ok(
    (SELECT count(*)::int FROM pgfr_analyze.config_health_check() WHERE parameter_name = 'work_mem') = 1,
    'config_health_check() should flag work_mem below 16MB'
);

SET work_mem = '32MB';
SELECT ok(
    (SELECT count(*)::int FROM pgfr_analyze.config_health_check() WHERE parameter_name = 'work_mem') = 0,
    'config_health_check() should not flag work_mem at or above 16MB'
);

SELECT * FROM finish();
ROLLBACK;
