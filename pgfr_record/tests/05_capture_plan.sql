-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- generate_capture_plan() (§4.3.3)
-- =============================================================================

BEGIN;
SELECT plan(10);

SELECT has_function('pgfr_record', 'generate_capture_plan', 'Function pgfr_record.generate_capture_plan should exist');
SELECT has_table('pgfr_record', 'capture_plan', 'Table pgfr_record.capture_plan should exist');

-- ---------------------------------------------------------------------------
-- The plan should have exactly one row per target that actually has a
-- minted schema (i.e. an unmet precondition excludes a target from the
-- plan, not include it with a dangling schema_id).
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.capture_plan),
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)
       AND EXISTS (SELECT 1 FROM pgfr_record.payload_schemas p WHERE p.source_view = m.source_view)),
    'capture_plan should have exactly one row per applicable manifest row with a minted schema'
);

-- ---------------------------------------------------------------------------
-- Spot-check that plan rows carry the manifest's own facts through
-- unchanged.
-- ---------------------------------------------------------------------------
SELECT results_eq(
    $$SELECT cadence_tier, natural_key, debounce, anchor_every, compare_ignore, keyless
      FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_stat_all_tables'$$,
    $$SELECT cadence_tier, natural_key, debounce, anchor_every, compare_ignore, keyless
      FROM pgfr_record.manifest WHERE source_view = 'pg_catalog.pg_stat_all_tables'$$,
    'a capture_plan row should carry its manifest row''s cadence/key/debounce/anchor/compare_ignore facts unchanged'
);
SELECT is(
    (SELECT archive_table FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_stat_database'),
    'a_pg_stat_database',
    'archive_table should follow the a_<short_name> naming convention'
);
SELECT is(
    (SELECT retention FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_settings'),
    interval '365 days',
    'retention should be copied through from the manifest row'
);

-- ---------------------------------------------------------------------------
-- The cached capture_select_sql (§4.4 mint-together invariant) should
-- actually be a working SELECT, not just non-null text.
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    (SELECT format('SELECT 1 FROM (%s) q LIMIT 0', capture_select_sql)
     FROM pgfr_record.capture_plan WHERE source_view = 'pg_catalog.pg_stat_database'),
    'a target''s cached capture_select_sql should be directly executable SQL'
);

-- ---------------------------------------------------------------------------
-- plan_order is a dense 1..N sequence within each tier (§5: "ORDER BY
-- manifest order").
-- ---------------------------------------------------------------------------
SELECT ok(
    NOT EXISTS (
        SELECT cadence_tier
        FROM pgfr_record.capture_plan
        GROUP BY cadence_tier
        HAVING min(plan_order) <> 1
            OR max(plan_order) <> count(*)
            OR count(DISTINCT plan_order) <> count(*)
    ),
    'plan_order should be a dense 1..N sequence (no gaps or duplicates) within each cadence_tier'
);

-- ---------------------------------------------------------------------------
-- Regeneration is wholesale and idempotent (TRUNCATE + repopulate, not an
-- append -- see the comment in 07_capture_plan.sql for why this table is
-- not governed by invariant 1's append-only rule).
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.generate_capture_plan()$$, 're-running generate_capture_plan() should not error');
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.capture_plan),
    (SELECT count(*)::int FROM pgfr_record.manifest m
     WHERE m.enabled
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)
       AND EXISTS (SELECT 1 FROM pgfr_record.payload_schemas p WHERE p.source_view = m.source_view)),
    're-running generate_capture_plan() should settle at the same row count, not accumulate duplicates'
);

SELECT * FROM finish();
ROLLBACK;
