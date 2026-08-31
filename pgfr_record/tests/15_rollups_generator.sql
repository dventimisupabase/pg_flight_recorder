-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- milestone 8: generate_rollups()
-- =============================================================================
-- install.sql already calls generate_rollups() once at install time (after
-- generate_column_classes(), before generate_capture_plan()), so these
-- tests exercise its effects on the live install rather than calling it
-- fresh.

BEGIN;
SELECT plan(21);

SELECT has_function('pgfr_record', 'generate_rollups', 'Function pgfr_record.generate_rollups should exist');

-- ---------------------------------------------------------------------------
-- Every enabled, version-applicable manifest row with rollup_retention set
-- should have gotten a rollup table.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled AND m.rollup_retention IS NOT NULL
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)
       AND to_regclass('pgfr_record.r_' || pgfr_record._short_name(m.source_view)) IS NOT NULL),
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled AND m.rollup_retention IS NOT NULL
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)),
    'every enabled, version-applicable manifest row with rollup_retention set should have a rollup table'
);
SELECT is(
    (SELECT rollup_retention FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_wal_receiver'),
    NULL::interval,
    'pg_stat_wal_receiver should have no rollup_retention'
);
SELECT is(
    to_regclass('pgfr_record.r_pg_stat_wal_receiver'),
    NULL::regclass,
    'pg_stat_wal_receiver should have no rollup table (rollup_retention is NULL)'
);

-- ---------------------------------------------------------------------------
-- Endpoint shape (Group B, counters/odometers), spot-checked on
-- r_pg_stat_all_tables.
-- ---------------------------------------------------------------------------
SELECT has_table('pgfr_record', 'r_pg_stat_all_tables', 'Table pgfr_record.r_pg_stat_all_tables should exist');
SELECT is(
    (SELECT array_agg(column_name::text ORDER BY ordinal_position)
     FROM information_schema.columns
     WHERE table_schema = 'pgfr_record' AND table_name = 'r_pg_stat_all_tables'),
    ARRAY['bucket_start','key','key_hash','first_captured_at','last_captured_at','first_values','last_values','first_reset_values','last_reset_values'],
    'r_pg_stat_all_tables should have the uniform endpoint-rollup column set, in order'
);
SELECT has_index('pgfr_record', 'r_pg_stat_all_tables', 'r_pg_stat_all_tables_key_hash_idx', 'the (key_hash, bucket_start DESC) lookup index should exist');
SELECT is(
    (SELECT count(*)::int FROM pg_constraint WHERE conrelid = 'pgfr_record.r_pg_stat_all_tables'::regclass AND contype = 'p'),
    0,
    'r_pg_stat_all_tables should have no PRIMARY KEY, matching the archive-table convention -- uniqueness is the collector''s bucket-close discipline, not a DB constraint'
);

-- ---------------------------------------------------------------------------
-- Stat shape (Group C, gauges), spot-checked on r_pg_stat_activity.
-- ---------------------------------------------------------------------------
SELECT has_table('pgfr_record', 'r_pg_stat_activity', 'Table pgfr_record.r_pg_stat_activity should exist');
SELECT is(
    (SELECT array_agg(column_name::text ORDER BY ordinal_position)
     FROM information_schema.columns
     WHERE table_schema = 'pgfr_record' AND table_name = 'r_pg_stat_activity'),
    ARRAY['bucket_start','stat_name','value','sample_count'],
    'r_pg_stat_activity should have the uniform stat-rollup column set, in order'
);
SELECT has_index('pgfr_record', 'r_pg_stat_activity', 'r_pg_stat_activity_stat_idx', 'the (stat_name, bucket_start DESC) lookup index should exist');
SELECT is(
    (SELECT count(*)::int FROM pg_constraint WHERE conrelid = 'pgfr_record.r_pg_stat_activity'::regclass AND contype = 'p'),
    0,
    'r_pg_stat_activity should have no PRIMARY KEY either'
);

-- ---------------------------------------------------------------------------
-- _partition_targets() picks up rollup tables with their own
-- rollup_retention, distinct from the raw archive's retention.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT retention FROM pgfr_record._partition_targets() WHERE parent_table = 'r_pg_stat_all_tables'),
    interval '365 days',
    '_partition_targets() should report r_pg_stat_all_tables at its rollup_retention (365d), not the raw archive''s 30d retention'
);
SELECT is(
    (SELECT retention FROM pgfr_record._partition_targets() WHERE parent_table = 'a_pg_stat_all_tables'),
    interval '30 days',
    '_partition_targets() should still report a_pg_stat_all_tables at its own raw 30d retention, independent of the rollup'
);

-- ---------------------------------------------------------------------------
-- generate_rollups() pre-creates initial partitions (mirrors
-- generate_archives()).
-- ---------------------------------------------------------------------------
SELECT ok(
    (SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
     WHERE p.relname = 'r_pg_stat_all_tables') >= 3,
    'r_pg_stat_all_tables should have at least 3 initial partitions after generate_rollups()'
);
SELECT ok(
    (SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
     WHERE p.relname = 'r_pg_stat_activity') >= 3,
    'r_pg_stat_activity should have at least 3 initial partitions after generate_rollups()'
);

-- ---------------------------------------------------------------------------
-- Re-running is safe (§7): no duplicate tables.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.generate_rollups()$$, 're-running generate_rollups() should not error');
SELECT is(
    (SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgfr_record' AND c.relkind = 'p' AND c.relname LIKE 'r\_%' ESCAPE '\'),
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled AND m.rollup_retention IS NOT NULL
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)),
    're-running generate_rollups() should not create duplicate rollup tables'
);

-- ---------------------------------------------------------------------------
-- A manifest row with rollup_retention set but no counter/odometer columns
-- and no rollup_specs rows should be skipped with a NOTICE, not error.
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$INSERT INTO pgfr_record.manifest (source_view, cadence_tier, retention, size_class, rollup_retention, rollup_granularity)
      VALUES ('test.nothing_to_roll_up', 'medium', interval '30 days', 'singleton', interval '365 days', interval '1 day')$$,
    'inserting a manifest row with rollup_retention but no classes/specs should succeed'
);
SELECT lives_ok(
    $$SELECT pgfr_record.generate_rollups()$$,
    'generate_rollups() should not error on a target with nothing to roll up (test.nothing_to_roll_up), just skip it'
);
SELECT is(
    to_regclass('pgfr_record.r_nothing_to_roll_up'),
    NULL::regclass,
    'no rollup table should be created for a target with no counter/odometer columns and no rollup_specs rows'
);

SELECT * FROM finish();
ROLLBACK;
