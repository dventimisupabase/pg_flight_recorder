-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- generate_comments() (§4.5)
-- =============================================================================

BEGIN;
SELECT plan(10);

SELECT has_function('pgfr_record', 'generate_comments', 'Function pgfr_record.generate_comments should exist');

-- ---------------------------------------------------------------------------
-- Archive table + its scaffolding columns.
-- ---------------------------------------------------------------------------
SELECT ok(
    obj_description('pgfr_record.a_pg_stat_database'::regclass, 'pg_class') LIKE 'Archive of pg_catalog.pg_stat_database.%',
    'the archive table comment should identify its source_view'
);
SELECT ok(
    obj_description('pgfr_record.a_pg_stat_database'::regclass, 'pg_class') LIKE '%Cadence: fast%',
    'the archive table comment should carry the manifest''s cadence_tier'
);
SELECT is(
    col_description('pgfr_record.a_pg_stat_database'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'pgfr_record.a_pg_stat_database'::regclass AND attname = 'payload')),
    'Positional jsonb array of every captured column value, per payload_schemas.columns for this row''s schema_id (§4.4).',
    'the payload column should carry its fixed, uniform-shape description'
);

-- ---------------------------------------------------------------------------
-- Presentation view + its per-column class annotations.
-- ---------------------------------------------------------------------------
SELECT ok(
    obj_description('pgfr_record.v_pg_stat_database'::regclass, 'pg_class') LIKE 'Typed projection of pg_catalog.pg_stat_database%',
    'the presentation view comment should identify its source_view'
);
SELECT ok(
    col_description('pgfr_record.v_pg_stat_database'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'pgfr_record.v_pg_stat_database'::regclass AND attname = 'datid')) LIKE 'class: key%',
    'a key column''s presentation-view comment should say class: key'
);
SELECT ok(
    col_description('pgfr_record.v_pg_stat_all_tables'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'pgfr_record.v_pg_stat_all_tables'::regclass AND attname = 'n_live_tup')) LIKE 'class: gauge%',
    'an estimator-churn column''s presentation-view comment should say class: gauge'
);
SELECT ok(
    col_description('pgfr_record.v_pg_stat_archiver'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'pgfr_record.v_pg_stat_archiver'::regclass AND attname = 'archived_count')) LIKE '%reset: stats_reset%',
    'a counter column''s presentation-view comment should carry its reset_column linkage'
);

-- ---------------------------------------------------------------------------
-- Regeneration is safe to re-run.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.generate_comments()$$, 're-running generate_comments() should not error');
SELECT ok(
    obj_description('pgfr_record.a_pg_stat_database'::regclass, 'pg_class') IS NOT NULL,
    'comments should still be present after re-running generate_comments()'
);

SELECT * FROM finish();
ROLLBACK;
