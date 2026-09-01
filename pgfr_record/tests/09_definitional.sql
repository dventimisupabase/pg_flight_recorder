-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- state_as_of(), resolve_relation(),
-- resolve_index() (§4.5)
-- =============================================================================
-- state_as_of() returns SETOF record: the caller must supply a column
-- definition list matching the target's presentation-view shape. These
-- are built dynamically here (via \gset, since this is plain psql at the
-- file's top level, not inside a pgTAP lives_ok() string) so the test
-- stays correct across majors rather than hardcoding a PG15-specific
-- column list.

BEGIN;
SELECT plan(16);

SELECT has_function('pgfr_record', 'state_as_of', 'Function pgfr_record.state_as_of should exist');
SELECT has_function('pgfr_record', 'latest_state', 'Function pgfr_record.latest_state should exist');
SELECT has_function('pgfr_record', 'resolve_relation', 'Function pgfr_record.resolve_relation should exist');
SELECT has_function('pgfr_record', 'resolve_index', 'Function pgfr_record.resolve_index should exist');

SELECT format('captured_at timestamptz, %s', string_agg(format('%I %s', c, t), ', ' ORDER BY ord)) AS defs
FROM (SELECT columns, type_names FROM pgfr_record.payload_schemas
      WHERE source_view = 'pg_catalog.pg_stat_archiver' ORDER BY schema_id DESC LIMIT 1) ps,
     unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(c, t, ord) \gset archiver_

SELECT format('captured_at timestamptz, %s', string_agg(format('%I %s', c, t), ', ' ORDER BY ord)) AS defs
FROM (SELECT columns, type_names FROM pgfr_record.payload_schemas
      WHERE source_view = 'pg_catalog.pg_settings' ORDER BY schema_id DESC LIMIT 1) ps,
     unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(c, t, ord) \gset settings_

SELECT clock_timestamp() AS t0 \gset before_

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture pg_stat_archiver');
SELECT lives_ok($$SELECT pgfr_record.run_tier('on_change')$$, 'run_tier(''on_change'') should capture pg_settings and src_catalog_identity');

-- ---------------------------------------------------------------------------
-- Singleton / non-debounced target.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.state_as_of('pg_catalog.pg_stat_archiver', clock_timestamp()) AS t(:archiver_defs)),
    1,
    'state_as_of on a singleton, non-debounced target should return exactly one row'
);

-- ---------------------------------------------------------------------------
-- Keyed / debounced target, spot-checked against the live value.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT setting FROM pgfr_record.state_as_of('pg_catalog.pg_settings', clock_timestamp()) AS t(:settings_defs) WHERE name = 'max_connections'),
    current_setting('max_connections'),
    'state_as_of on a keyed target should return the captured value matching the live setting'
);

-- ---------------------------------------------------------------------------
-- Boundary: a point in time before any capture existed should reconstruct
-- to nothing, not silently return the earliest available row.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.state_as_of('pg_catalog.pg_settings', :'before_t0'::timestamptz - interval '1 hour') AS t(:settings_defs)),
    0,
    'state_as_of before any capture existed should return zero rows'
);

-- ---------------------------------------------------------------------------
-- latest_state(): the true-current-snapshot sibling of state_as_of(),
-- for non-debounced targets. Correctness on fresh data, and both guards
-- (unknown source_view, debounced target).
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.latest_state('pg_catalog.pg_stat_archiver', clock_timestamp()) AS t(:archiver_defs)),
    1,
    'latest_state on a singleton, non-debounced target should return exactly one row'
);
SELECT throws_ok(
    $$SELECT * FROM pgfr_record.latest_state('pg_catalog.pg_settings', clock_timestamp()) AS t(name text, setting text)$$,
    NULL,
    'pgfr_record.latest_state: pg_catalog.pg_settings is debounced; a missing row means unchanged, not absent -- use state_as_of() instead',
    'latest_state on a debounced target should raise, not silently return misleading results'
);
SELECT throws_ok(
    $$SELECT * FROM pgfr_record.latest_state('pg_catalog.not_a_real_view', clock_timestamp()) AS t(x text)$$,
    NULL,
    'pgfr_record.latest_state: unknown source_view pg_catalog.not_a_real_view',
    'latest_state on an unknown source_view should raise'
);

-- ---------------------------------------------------------------------------
-- resolve_relation() / resolve_index().
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT relname FROM pgfr_record.resolve_relation('pgfr_record.manifest'::regclass::oid)),
    'manifest',
    'resolve_relation should identify the manifest table by its own oid'
);
SELECT is(
    (SELECT nspname FROM pgfr_record.resolve_relation('pgfr_record.manifest'::regclass::oid)),
    'pgfr_record',
    'resolve_relation should report the correct namespace'
);
SELECT is(
    (SELECT relkind FROM pgfr_record.resolve_index((SELECT oid FROM pg_class WHERE relname = 'manifest_pkey'))),
    'i',
    'resolve_index should identify an actual index oid as relkind i'
);
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.resolve_relation(999999999)),
    0,
    'resolve_relation on a nonexistent oid should return zero rows, not error'
);

SELECT * FROM finish();
ROLLBACK;
