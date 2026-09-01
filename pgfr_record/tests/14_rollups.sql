-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- milestone 8: rollup manifest + seed data
-- =============================================================================
-- Covers the schema-level slice of milestone 8 (long-horizon, compressed
-- history for Groups B and C): the manifest's rollup_retention/
-- rollup_granularity columns and CHECK constraint, the rollup_specs table,
-- Group A's retention bump to 365d, and the Group B/C/rollup_specs seed
-- data. generate_rollups(), the collector's bucket-close step, and
-- health_check()'s rollup-lag clause are covered by later test files as
-- those pieces land.

BEGIN;
SELECT plan(22);

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
SELECT has_table('pgfr_record', 'rollup_specs', 'Table pgfr_record.rollup_specs should exist');
SELECT has_column('pgfr_record', 'manifest', 'rollup_retention', 'manifest should have a rollup_retention column');
SELECT has_column('pgfr_record', 'manifest', 'rollup_granularity', 'manifest should have a rollup_granularity column');

-- ---------------------------------------------------------------------------
-- rollup_shape CHECK constraint
-- ---------------------------------------------------------------------------
SELECT throws_ok(
    $$INSERT INTO pgfr_record.manifest (source_view, cadence_tier, retention, size_class, rollup_retention)
      VALUES ('test.rollup_no_granularity', 'medium', interval '1 day', 'singleton', interval '365 days')$$,
    '23514',
    NULL,
    'rollup_retention set without rollup_granularity should violate the rollup_shape CHECK constraint'
);

SELECT throws_ok(
    $$INSERT INTO pgfr_record.manifest (source_view, cadence_tier, retention, size_class, rollup_retention, rollup_granularity)
      VALUES ('test.rollup_wider_than_retention', 'medium', interval '1 day', 'singleton', interval '365 days', interval '1 day')$$,
    '23514',
    NULL,
    'rollup_granularity >= retention should violate the rollup_shape CHECK constraint (a bucket cannot be wider than the raw window it aggregates from)'
);

SELECT lives_ok(
    $$INSERT INTO pgfr_record.manifest (source_view, cadence_tier, retention, size_class, rollup_retention, rollup_granularity)
      VALUES ('test.rollup_ok', 'medium', interval '30 days', 'singleton', interval '365 days', interval '1 day')$$,
    'rollup_granularity strictly less than retention should be a valid manifest row'
);
SELECT lives_ok(
    $$INSERT INTO pgfr_record.manifest (source_view, cadence_tier, retention, size_class)
      VALUES ('test.no_rollup', 'medium', interval '30 days', 'singleton')$$,
    'rollup_retention/rollup_granularity both NULL (no rollup) should remain a valid manifest row'
);

-- ---------------------------------------------------------------------------
-- Group A: retention bumped to 365d directly (no rollup -- bounded,
-- singleton/per-db cardinality, cheap even at a year's depth).
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT retention FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_bgwriter'),
    interval '365 days',
    'Group A (pg_stat_bgwriter) retention should be 365 days'
);
SELECT is(
    (SELECT rollup_retention FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_bgwriter'),
    NULL::interval,
    'Group A should have no rollup_retention -- 365d raw retention already covers the long horizon'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest WHERE retention = interval '365 days'),
    19,
    '19 manifest rows should now carry 365d retention (10 Group A + 9 Group D)'
);

-- ---------------------------------------------------------------------------
-- Group B: raw retention unchanged at 30d (still the cost-model frontier);
-- rollup_retention/rollup_granularity set mechanically on every row.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT retention FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_all_tables'),
    interval '30 days',
    'Group B (pg_stat_all_tables) raw retention should remain 30 days'
);
SELECT is(
    (SELECT (rollup_retention, rollup_granularity) FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_all_tables'),
    (interval '365 days', interval '1 day'),
    'Group B (pg_stat_all_tables) should roll up to 365d at 1-day buckets'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest
     WHERE source_view IN (
        'pg_catalog.pg_stat_all_tables', 'pg_catalog.pg_stat_all_indexes',
        'pg_catalog.pg_statio_all_tables', 'pg_catalog.pg_statio_all_indexes',
        'pg_catalog.pg_statio_all_sequences', 'pg_catalog.pg_stat_user_functions',
        'pg_stat_statements', 'pg_stat_statements_info', 'pg_catalog.pg_sequences'
     )
     AND rollup_retention = interval '365 days' AND rollup_granularity = interval '1 day'),
    9,
    'every Group B target (9 rows) should have a 365d/1-day rollup configured'
);

-- ---------------------------------------------------------------------------
-- Group C: rollup set only on targets with rollup_specs rows.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT (rollup_retention, rollup_granularity) FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_activity'),
    (interval '365 days', interval '1 hour'),
    'Group C (pg_stat_activity) should roll up to 365d at 1-hour buckets'
);
SELECT is(
    (SELECT (rollup_retention, rollup_granularity) FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_wal_receiver'),
    (interval '365 days', interval '1 hour'),
    'pg_stat_wal_receiver should roll up to 365d at 1-hour buckets (mechanical, via its own LSN odometer columns, no rollup_specs needed)'
);
SELECT is(
    (SELECT (rollup_retention, rollup_granularity) FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_progress_vacuum'),
    (interval '365 days', interval '1 hour'),
    'pg_stat_progress_vacuum should roll up to 365d at 1-hour buckets'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest
     WHERE source_view LIKE '%pg_catalog%' AND rollup_retention IS NOT NULL
       AND source_view IN (
         'pg_catalog.pg_stat_activity', 'pg_catalog.pg_locks', 'pg_catalog.pg_stat_replication',
         'pg_catalog.pg_stat_wal_receiver', 'pg_catalog.pg_stat_subscription', 'pg_catalog.pg_replication_slots',
         'pg_catalog.pg_prepared_xacts', 'pg_catalog.pg_stat_progress_vacuum', 'pg_catalog.pg_stat_progress_cluster',
         'pg_catalog.pg_stat_progress_create_index', 'pg_catalog.pg_stat_progress_basebackup',
         'pg_catalog.pg_stat_progress_analyze', 'pg_catalog.pg_stat_progress_copy',
         'pg_catalog.pg_stat_ssl', 'pg_catalog.pg_stat_gssapi'
       )),
    15,
    'all 15 Group C targets should now have a rollup configured'
);

-- ---------------------------------------------------------------------------
-- rollup_specs seed data
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.rollup_specs),
    15,
    'rollup_specs should have 15 seeded rows (9 original + 6 for the progress views)'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.rollup_specs WHERE predicate_sql ~* '[0-9]+ *(second|minute|hour)s?'),
    0,
    'no rollup_specs predicate should embed a hardcoded duration threshold -- that judgment belongs to pgfr_analyze at read time'
);
SELECT is(
    (SELECT count(*)::int
     FROM pgfr_record.rollup_specs rs
     WHERE NOT EXISTS (
         SELECT 1 FROM pgfr_record.manifest m
         WHERE m.source_view = rs.source_view AND m.rollup_retention IS NOT NULL
     )),
    0,
    'every rollup_specs row should reference a manifest row that actually has a rollup configured'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.rollup_specs WHERE source_view = 'pg_catalog.pg_stat_wal_receiver'),
    0,
    'pg_stat_wal_receiver should have no rollup_specs row -- its rollup is mechanical (odometer columns), not hand-picked'
);

-- ---------------------------------------------------------------------------
-- Global invariant: rollup_granularity < retention holds for every row
-- that carries a rollup (not just the two spot-checked above) -- if this
-- ever fails, a bucket could close before its own source data does.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.manifest
     WHERE rollup_retention IS NOT NULL AND rollup_granularity >= retention),
    0,
    'no manifest row should have a rollup bucket as wide as or wider than its own raw retention'
);

SELECT * FROM finish();
ROLLBACK;
