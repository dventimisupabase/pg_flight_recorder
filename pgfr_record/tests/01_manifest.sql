-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- Manifest + PG15 seed census
-- =============================================================================

BEGIN;
SELECT plan(31);

-- ---------------------------------------------------------------------------
-- Schema + core tables/views exist
-- ---------------------------------------------------------------------------
SELECT has_schema('pgfr_record', 'Schema pgfr_record should exist');
SELECT has_table('pgfr_record', 'manifest', 'Table pgfr_record.manifest should exist');
SELECT has_table('pgfr_record', 'column_classes', 'Table pgfr_record.column_classes should exist');
SELECT has_table('pgfr_record', 'payload_schemas', 'Table pgfr_record.payload_schemas should exist');
SELECT has_view('pgfr_record', 'src_catalog_identity', 'View pgfr_record.src_catalog_identity should exist');

-- ---------------------------------------------------------------------------
-- Manifest CHECK constraints (§3.1)
-- ---------------------------------------------------------------------------
SELECT throws_ok(
    $$INSERT INTO pgfr_record.manifest (source_view, cadence_tier, debounce, retention, size_class)
      VALUES ('test.debounce_without_anchor', 'medium', true, interval '1 day', 'singleton')$$,
    '23514',
    NULL,
    'debounce = true without anchor_every should violate the manifest CHECK constraint'
);

SELECT throws_ok(
    $$INSERT INTO pgfr_record.manifest (source_view, cadence_tier, keyless, debounce, anchor_every, retention, size_class)
      VALUES ('test.keyless_and_debounced', 'medium', true, true, interval '1 day', interval '1 day', 'singleton')$$,
    '23514',
    NULL,
    'keyless = true with debounce = true should violate the manifest CHECK constraint'
);

SELECT throws_ok(
    $$INSERT INTO pgfr_record.manifest (source_view, cadence_tier, retention, size_class)
      VALUES ('test.bad_tier', 'hourly', interval '1 day', 'singleton')$$,
    '23514',
    NULL,
    'an unrecognized cadence_tier should violate the manifest CHECK constraint'
);

-- ---------------------------------------------------------------------------
-- PG15 seed census row counts (pgfr-v2-context-pack.md §3.2)
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest),
    49,
    'manifest should have 49 total rows (8 Group A + 2 version-gated + 9 Group B + 15 Group C + 9 Group D + 6 Group E)'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest WHERE enabled),
    43,
    '43 manifest rows should be enabled (49 total - 6 disabled Group E rows)'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest WHERE NOT enabled),
    6,
    '6 manifest rows should be Group E (enabled = false, present with reasons)'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest WHERE min_major > 15),
    2,
    '2 manifest rows should be version-gated beyond PG15 (pg_stat_io, pg_stat_checkpointer)'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest WHERE debounce),
    17,
    '17 manifest rows should be debounced (8 Group B, excluding the non-debounced pg_stat_statements_info companion + 9 Group D)'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest WHERE keyless),
    1,
    'exactly 1 manifest row (pg_locks) should be keyless'
);

-- ---------------------------------------------------------------------------
-- Spot-check a representative row from each group
-- ---------------------------------------------------------------------------
SELECT results_eq(
    $$SELECT cadence_tier, retention, size_class FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_database'$$,
    $$VALUES ('fast'::text, interval '30 days', 'per_db'::text)$$,
    'pg_stat_database (Group A) should carry fast/30d/per_db'
);
SELECT results_eq(
    $$SELECT debounce, anchor_every, retention, compare_ignore FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_all_tables'$$,
    $$VALUES (true, interval '1 day', interval '30 days', ARRAY['n_live_tup','n_dead_tup','n_mod_since_analyze','n_ins_since_vacuum'])$$,
    'pg_stat_all_tables (Group B) should be debounced with a 1-day anchor and the estimator-churn ignore-list'
);
SELECT results_eq(
    $$SELECT keyless, retention, size_class FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_locks'$$,
    $$VALUES (true, interval '2 hours', 'per_backend'::text)$$,
    'pg_locks (Group C) should be keyless with 2h retention'
);
SELECT results_eq(
    $$SELECT debounce, anchor_every, retention FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_settings'$$,
    $$VALUES (true, interval '1 month', interval '365 days')$$,
    'pg_settings (Group D) should be debounced with a monthly anchor and 365d retention'
);
SELECT results_eq(
    $$SELECT natural_key, debounce, anchor_every, retention FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_database'$$,
    $$VALUES (ARRAY['oid'], true, interval '1 month', interval '365 days')$$,
    'pg_database (Group D addition) should be keyed by oid, debounced with a monthly anchor and 365d retention'
);
SELECT ok(
    (SELECT NOT enabled FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stats'),
    'pg_stats (Group E) should be disabled'
);
SELECT is(
    (SELECT min_major FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_io'),
    16,
    'pg_stat_io should be version-gated to min_major 16'
);
SELECT is(
    (SELECT min_major FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_checkpointer'),
    17,
    'pg_stat_checkpointer should be version-gated to min_major 17'
);
SELECT results_eq(
    $$SELECT natural_key, retention, size_class FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_replication_slots'$$,
    $$VALUES (ARRAY['slot_name'], interval '30 days', 'per_slot'::text)$$,
    'pg_stat_replication_slots (Group A addition) should be keyed by slot_name with 30d retention'
);
SELECT results_eq(
    $$SELECT natural_key, retention, size_class FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_subscription_stats'$$,
    $$VALUES (ARRAY['subid'], interval '30 days', 'per_slot'::text)$$,
    'pg_stat_subscription_stats (Group A addition) should be keyed by subid with 30d retention'
);
SELECT results_eq(
    $$SELECT natural_key, retention, size_class FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_ssl'$$,
    $$VALUES (ARRAY['pid'], interval '2 hours', 'per_backend'::text)$$,
    'pg_stat_ssl (Group C addition) should be keyed by pid with 2h retention'
);
SELECT results_eq(
    $$SELECT natural_key, retention, size_class FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_gssapi'$$,
    $$VALUES (ARRAY['pid'], interval '2 hours', 'per_backend'::text)$$,
    'pg_stat_gssapi (Group C addition) should be keyed by pid with 2h retention'
);
SELECT results_eq(
    $$SELECT natural_key, debounce, anchor_every, retention FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_sequences'$$,
    $$VALUES (ARRAY['schemaname','sequencename'], true, interval '1 day', interval '30 days')$$,
    'pg_sequences (Group B addition) should be keyed by schemaname/sequencename, debounced with a 1-day anchor'
);
SELECT results_eq(
    $$SELECT natural_key, debounce, anchor_every, retention FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_ident_file_mappings'$$,
    $$VALUES (ARRAY['line_number'], true, interval '1 month', interval '365 days')$$,
    'pg_ident_file_mappings (Group D addition) should be keyed by line_number, debounced with a monthly anchor'
);
SELECT results_eq(
    $$SELECT natural_key, debounce, anchor_every, retention FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_publication_tables'$$,
    $$VALUES (ARRAY['pubname','schemaname','tablename'], true, interval '1 month', interval '365 days')$$,
    'pg_publication_tables (Group D addition) should be keyed by pubname/schemaname/tablename, debounced with a monthly anchor'
);

-- ---------------------------------------------------------------------------
-- Idempotent re-seed (install.sql re-run is the upgrade path, §7): every
-- seed INSERT uses ON CONFLICT (source_view) DO NOTHING; exercise it
-- directly rather than re-sourcing the seed file (psql meta-commands like
-- \ir cannot run inside a pgTAP lives_ok() string).
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$INSERT INTO pgfr_record.manifest (source_view, cadence_tier, natural_key, retention, size_class, notes)
      VALUES ('pg_catalog.pg_stat_archiver', 'fast', '{}', interval '30 days', 'singleton', 'reset: stats_reset')
      ON CONFLICT (source_view) DO NOTHING$$,
    're-inserting an existing manifest row with ON CONFLICT DO NOTHING should not error'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_archiver'),
    1,
    're-inserting an existing manifest row should not duplicate it'
);

SELECT * FROM finish();
ROLLBACK;
