-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- generate_archives() (§4.3.1)
-- =============================================================================
-- install.sql already calls generate_archives() once at install time, so
-- these tests exercise its effects on the live install rather than
-- calling it fresh.

BEGIN;
SELECT plan(16);

SELECT has_function('pgfr_record', 'generate_archives', 'Function pgfr_record.generate_archives should exist');
SELECT has_function('pgfr_record', '_introspect_columns', 'Function pgfr_record._introspect_columns should exist');

-- ---------------------------------------------------------------------------
-- Every enabled, version-applicable manifest row should have gotten an
-- archive table and a minted payload_schemas row.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)
       AND to_regclass('pgfr_record.a_' || pgfr_record._short_name(m.source_view)) IS NOT NULL),
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)),
    'every enabled, version-applicable manifest row should have an archive table'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.payload_schemas),
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)),
    'exactly one payload_schemas row should be minted per applicable manifest row (no live schema drift in a fresh install)'
);

-- ---------------------------------------------------------------------------
-- Uniform archive shape (§4.1), spot-checked on a_pg_stat_database.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT array_agg(column_name::text ORDER BY ordinal_position)
     FROM information_schema.columns
     WHERE table_schema = 'pgfr_record' AND table_name = 'a_pg_stat_database'),
    ARRAY['captured_at','key','key_hash','row_hash','schema_id','payload'],
    'a_pg_stat_database should have the uniform archive column set, in order'
);
SELECT is(
    (SELECT array_agg(data_type::text ORDER BY ordinal_position)
     FROM information_schema.columns
     WHERE table_schema = 'pgfr_record' AND table_name = 'a_pg_stat_database'),
    ARRAY['timestamp with time zone','jsonb','bigint','bigint','smallint','jsonb'],
    'a_pg_stat_database columns should have the uniform archive types, in order'
);
SELECT is(
    (SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'pgfr_record' AND table_name = 'a_pg_stat_database' AND column_name = 'row_hash'),
    'NO',
    'row_hash should be NOT NULL'
);
SELECT is(
    (SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'pgfr_record' AND table_name = 'a_pg_stat_database' AND column_name = 'schema_id'),
    'NO',
    'schema_id should be NOT NULL'
);
SELECT is(
    (SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'pgfr_record' AND table_name = 'a_pg_stat_database' AND column_name = 'payload'),
    'NO',
    'payload should be NOT NULL'
);
SELECT has_index('pgfr_record', 'a_pg_stat_database', 'a_pg_stat_database_key_hash_idx', 'the debounce/LOCF index (key_hash, captured_at DESC) should exist');

-- ---------------------------------------------------------------------------
-- Introspection works uniformly across relkinds: a catalog table
-- (pg_extension), and a pgfr-defined projection view (src_catalog_identity).
-- ---------------------------------------------------------------------------
SELECT has_table('pgfr_record', 'a_pg_extension', 'pg_extension (a catalog table, not a view) should get an archive table');
SELECT has_table('pgfr_record', 'a_src_catalog_identity', 'src_catalog_identity (a pgfr-defined projection view) should get an archive table');

-- ---------------------------------------------------------------------------
-- generate_archives() pre-creates initial partitions (§4.3.1).
-- ---------------------------------------------------------------------------
SELECT ok(
    (SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_class p ON p.oid = i.inhparent
     WHERE p.relname = 'a_pg_stat_database') >= 3,
    'a_pg_stat_database should have at least 3 initial partitions after generate_archives()'
);

-- ---------------------------------------------------------------------------
-- Re-running is safe (§7): no duplicate schemas, no duplicate tables.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.generate_archives()$$, 're-running generate_archives() should not error');
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.payload_schemas),
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)),
    're-running generate_archives() should not mint duplicate payload_schemas rows for an unchanged live catalog'
);
SELECT is(
    (SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgfr_record' AND c.relkind = 'p' AND c.relname LIKE 'a\_%' ESCAPE '\'),
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)),
    're-running generate_archives() should not create duplicate archive tables (relkind = ''p'' excludes the child partitions, which also match the a_ naming prefix)'
);

SELECT * FROM finish();
ROLLBACK;
