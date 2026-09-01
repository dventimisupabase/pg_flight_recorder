-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- generate_presentation_views() (§4.3.2, §4.4)
-- =============================================================================

BEGIN;
SELECT plan(9);

SELECT has_function('pgfr_record', 'generate_presentation_views', 'Function pgfr_record.generate_presentation_views should exist');

-- ---------------------------------------------------------------------------
-- Every target with a minted schema should have a presentation view.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.payload_schemas ps
     WHERE ps.schema_id = (SELECT max(schema_id) FROM pgfr_record.payload_schemas WHERE source_view = ps.source_view)
       AND to_regclass('pgfr_record.v_' || pgfr_record._short_name(ps.source_view)) IS NOT NULL),
    (SELECT count(DISTINCT source_view)::int FROM pgfr_record.payload_schemas),
    'every source_view with a minted schema should have a v_<short_name> presentation view'
);

-- ---------------------------------------------------------------------------
-- Presentation fidelity (§10.1 acceptance criterion 2): captured_at plus
-- every v_<short_name> column name and type should match the live source
-- view exactly, using the same introspection path on both sides.
-- ---------------------------------------------------------------------------
SELECT is(
    (WITH targets AS (
        SELECT DISTINCT source_view FROM pgfr_record.payload_schemas
     ),
     view_cols AS (
        SELECT t.source_view, array_agg(ic.column_name ORDER BY ic.attnum) AS cols, array_agg(ic.type_name ORDER BY ic.attnum) AS types
        FROM targets t, pgfr_record._introspect_columns('pgfr_record.v_' || pgfr_record._short_name(t.source_view)) ic
        GROUP BY t.source_view
     ),
     source_cols AS (
        SELECT t.source_view,
               ARRAY['captured_at'] || array_agg(ic.column_name ORDER BY ic.attnum) AS cols,
               ARRAY['timestamp with time zone'] || array_agg(ic.type_name ORDER BY ic.attnum) AS types
        FROM targets t, pgfr_record._introspect_columns(t.source_view) ic
        GROUP BY t.source_view
     )
     SELECT count(*)::int FROM view_cols v JOIN source_cols s USING (source_view)
     WHERE v.cols IS DISTINCT FROM s.cols OR v.types IS DISTINCT FROM s.types),
    0,
    'every presentation view''s column names and types should exactly match its live source view'
);

SELECT lives_ok($$SELECT pgfr_record.generate_presentation_views()$$, 're-running generate_presentation_views() should not error');

-- ---------------------------------------------------------------------------
-- Mid-major accretion (§4.4): a source_view can carry more than one
-- payload_schemas row over time. Manufacture a narrower "old" schema for
-- pg_stat_database_conflicts (chosen for a small, version-stable, all-
-- numeric column set) missing its newest column, and an archive row
-- captured under it, then verify the presentation view NULL-fills the
-- missing column while still surfacing shared columns correctly.
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$INSERT INTO pgfr_record.payload_schemas (source_view, columns, type_names, fingerprint)
      SELECT source_view, columns[1:array_length(columns,1)-1], type_names[1:array_length(type_names,1)-1], 'test-old-schema'
      FROM pgfr_record.payload_schemas
      WHERE source_view = 'pg_catalog.pg_stat_database_conflicts'
      ORDER BY schema_id DESC LIMIT 1$$,
    'manufacturing a narrower prior schema_id should succeed'
);
SELECT lives_ok(
    $$INSERT INTO pgfr_record.a_pg_stat_database_conflicts (captured_at, key, key_hash, row_hash, schema_id, payload)
      SELECT now(), NULL, NULL, 111,
             (SELECT schema_id FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_database_conflicts' AND fingerprint = 'test-old-schema'),
             (SELECT jsonb_agg(to_jsonb(900 + i)) FROM generate_series(1, array_length(columns,1)) i)
      FROM pgfr_record.payload_schemas
      WHERE source_view = 'pg_catalog.pg_stat_database_conflicts' AND fingerprint = 'test-old-schema'$$,
    'inserting an archive row under the narrower prior schema should succeed'
);
SELECT lives_ok(
    $$SELECT pgfr_record.generate_presentation_views()$$,
    're-running generate_presentation_views() should pick up the new schema_id branch'
);
SELECT is(
    (SELECT to_jsonb(v)->>(cur.columns[array_length(cur.columns,1)])
     FROM pgfr_record.v_pg_stat_database_conflicts v,
          (SELECT columns FROM pgfr_record.payload_schemas
           WHERE source_view = 'pg_catalog.pg_stat_database_conflicts' AND fingerprint <> 'test-old-schema'
           ORDER BY schema_id DESC LIMIT 1) cur),
    NULL,
    'a row captured under the narrower prior schema should be NULL for the column that did not exist yet'
);
SELECT is(
    (SELECT to_jsonb(v)->>(cur.columns[1])
     FROM pgfr_record.v_pg_stat_database_conflicts v,
          (SELECT columns FROM pgfr_record.payload_schemas
           WHERE source_view = 'pg_catalog.pg_stat_database_conflicts' AND fingerprint <> 'test-old-schema'
           ORDER BY schema_id DESC LIMIT 1) cur),
    '901',
    'a column shared with the current schema should still surface its captured value from the prior schema''s own position'
);

SELECT * FROM finish();
ROLLBACK;
