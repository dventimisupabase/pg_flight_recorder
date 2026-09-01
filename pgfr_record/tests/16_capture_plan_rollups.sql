-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- milestone 8: rollup_close_sql minting
-- =============================================================================
-- install.sql already calls generate_capture_plan() once at install time
-- (after generate_column_classes() and generate_rollups()), so the shape
-- checks below exercise the live install; the functional checks execute
-- the cached rollup_close_sql directly against real captured data.

BEGIN;
SELECT plan(11);

-- ---------------------------------------------------------------------------
-- Shape: rollup_table/rollup_close_sql are set only for targets with a
-- rollup, NULL otherwise.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT rollup_table FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_stat_all_tables'),
    'r_pg_stat_all_tables',
    'pg_stat_all_tables capture_plan row should carry its rollup_table'
);
SELECT is(
    (SELECT rollup_granularity FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_stat_all_tables'),
    interval '1 day',
    'rollup_granularity should be copied through from the manifest row'
);
SELECT ok(
    (SELECT rollup_table FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_stat_bgwriter') IS NULL,
    'pg_stat_bgwriter (Group A, no rollup) should have a NULL rollup_table'
);
SELECT ok(
    (SELECT rollup_close_sql FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_stat_bgwriter') IS NULL,
    'pg_stat_bgwriter should have a NULL rollup_close_sql'
);

-- ---------------------------------------------------------------------------
-- rollup_close_sql is a full INSERT ... SELECT (so run_tier() can EXECUTE
-- it directly with no outer wrapper), not a bare SELECT -- so "is it valid
-- SQL" is proven by the functional round-trips below actually running it,
-- not by wrapping it in a dummy SELECT the way capture_select_sql's own
-- test does (that trick only works for a bare SELECT).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Functional round-trip, endpoint shape: capture pg_stat_all_tables once
-- (the first-ever capture of a debounced target is always an anchor, so
-- every relation gets a row), then execute its rollup_close_sql over a
-- bucket covering right now and confirm a rollup row lands with
-- first_captured_at = last_captured_at (only one sample in the bucket).
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should capture pg_stat_all_tables');

DO $do$
DECLARE
    v_sql    text;
    v_bucket timestamptz := date_trunc('day', clock_timestamp());
BEGIN
    SELECT rollup_close_sql INTO v_sql FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_stat_all_tables';
    EXECUTE v_sql USING v_bucket, v_bucket + interval '1 day';
END $do$;

SELECT ok(
    (SELECT count(*)::int FROM pgfr_record.r_pg_stat_all_tables) > 0,
    'executing pg_stat_all_tables'' rollup_close_sql should append at least one endpoint-rollup row'
);
SELECT ok(
    (SELECT bool_and(first_captured_at = last_captured_at) FROM pgfr_record.r_pg_stat_all_tables),
    'with only one sample in the bucket, first_captured_at should equal last_captured_at for every key'
);
SELECT ok(
    (SELECT bool_and(first_values = last_values) FROM pgfr_record.r_pg_stat_all_tables),
    'with only one sample in the bucket, first_values should equal last_values for every key'
);

-- ---------------------------------------------------------------------------
-- Functional round-trip, stat shape: capture pg_stat_activity once, then
-- execute its rollup_close_sql and confirm one row per configured
-- rollup_specs stat_name, each with a non-negative sample_count.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture pg_stat_activity');

DO $do$
DECLARE
    v_sql    text;
    v_bucket timestamptz := date_trunc('hour', clock_timestamp());
BEGIN
    SELECT rollup_close_sql INTO v_sql FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_stat_activity';
    EXECUTE v_sql USING v_bucket, v_bucket + interval '1 hour';
END $do$;

SELECT is(
    (SELECT array_agg(stat_name ORDER BY stat_name) FROM pgfr_record.r_pg_stat_activity),
    (SELECT array_agg(stat_name ORDER BY stat_name) FROM pgfr_record.rollup_specs WHERE source_view = 'pg_catalog.pg_stat_activity'),
    'executing pg_stat_activity''s rollup_close_sql should append exactly one row per configured rollup_specs stat_name'
);
SELECT ok(
    (SELECT bool_and(sample_count >= 0) FROM pgfr_record.r_pg_stat_activity),
    'every stat-rollup row should have a non-negative sample_count'
);

SELECT * FROM finish();
ROLLBACK;
