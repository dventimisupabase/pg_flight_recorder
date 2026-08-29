-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- generate_column_classes() (§3.1, §4.5)
-- =============================================================================

BEGIN;
SELECT plan(22);

SELECT has_function('pgfr_record', 'generate_column_classes', 'Function pgfr_record.generate_column_classes should exist');

-- ---------------------------------------------------------------------------
-- Coverage: exactly one column_classes row per column of every applicable
-- target's current schema.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.column_classes),
    (SELECT sum(array_length(ps.columns, 1))::int
     FROM pgfr_record.manifest m
     JOIN LATERAL (
        SELECT columns FROM pgfr_record.payload_schemas p
        WHERE p.source_view = m.source_view ORDER BY p.schema_id DESC LIMIT 1
     ) ps ON true
     WHERE m.enabled
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)),
    'column_classes should have exactly one row per column across every applicable target''s current schema'
);

-- ---------------------------------------------------------------------------
-- Every natural_key column, across every target, should be classified
-- ''key'' -- this is mechanically derived, not a guess, so it should hold
-- with zero exceptions.
-- ---------------------------------------------------------------------------
SELECT ok(
    NOT EXISTS (
        SELECT 1
        FROM pgfr_record.manifest m, unnest(m.natural_key) k, pgfr_record.column_classes cc
        WHERE cc.source_view = m.source_view
          AND cc.column_name = k
          AND cc.class <> 'key'
    ),
    'every natural_key column of every target should be classified as key'
);

-- ---------------------------------------------------------------------------
-- Known overrides and type-driven rules, spot-checked.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT class FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_stat_database' AND column_name = 'numbackends'),
    'gauge',
    'pg_stat_database.numbackends should be overridden to gauge (a current count, not a cumulative counter)'
);
SELECT ok(
    (SELECT bool_and(class = 'odometer') FROM pgfr_record.column_classes
     WHERE source_view = 'pg_catalog.pg_stat_replication' AND column_name IN ('sent_lsn','write_lsn','flush_lsn','replay_lsn')),
    'pg_stat_replication''s LSN columns should all be classified odometer (§2''s definition: LSNs are odometers)'
);
SELECT ok(
    (SELECT bool_and(class = 'odometer') FROM pgfr_record.column_classes
     WHERE source_view = 'pg_catalog.pg_replication_slots' AND column_name IN ('restart_lsn','confirmed_flush_lsn')),
    'pg_replication_slots''s LSN columns should all be classified odometer'
);
SELECT is(
    (SELECT reset_column FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_stat_archiver' AND column_name = 'archived_count'),
    'stats_reset',
    'a counter column in a view with its own stats_reset column should link to it as reset_column'
);
SELECT ok(
    (SELECT bool_and(class = 'gauge') FROM pgfr_record.column_classes
     WHERE source_view = 'pg_catalog.pg_stat_all_tables' AND column_name IN ('n_live_tup','n_dead_tup','n_mod_since_analyze','n_ins_since_vacuum')),
    'pg_stat_all_tables''s compare_ignore (estimator-churn) columns should be classified gauge, not counter'
);
SELECT ok(
    (SELECT class FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_stat_archiver' AND column_name = 'stats_reset') = 'label',
    'the stats_reset column itself should be classified label'
);
SELECT ok(
    (SELECT bool_and(class = 'odometer') FROM pgfr_record.column_classes
     WHERE source_view = 'pgfr_record.src_catalog_identity' AND column_name IN ('relfrozenxid', 'relminmxid')),
    'src_catalog_identity''s relfrozenxid/relminmxid should be classified odometer (xid-typed)'
);
SELECT is(
    (SELECT class FROM pgfr_record.column_classes WHERE source_view = 'pgfr_record.src_catalog_identity' AND column_name = 'reltuples'),
    'gauge',
    'src_catalog_identity''s reltuples should be overridden to gauge (a periodically-recomputed estimate, not a counter)'
);
SELECT is(
    (SELECT class FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_stat_ssl' AND column_name = 'bits'),
    'gauge',
    'pg_stat_ssl.bits should be overridden to gauge (a fixed per-connection property, not a counter)'
);
SELECT is(
    (SELECT class FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_stat_ssl' AND column_name = 'client_serial'),
    'gauge',
    'pg_stat_ssl.client_serial should be overridden to gauge (a certificate identifier, not a counter)'
);
SELECT is(
    (SELECT class FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_sequences' AND column_name = 'last_value'),
    'counter',
    'pg_sequences.last_value should classify as counter (the intended consumption-rate signal via deltas())'
);
SELECT ok(
    (SELECT bool_and(class = 'gauge') FROM pgfr_record.column_classes
     WHERE source_view = 'pg_catalog.pg_sequences' AND column_name IN ('min_value', 'max_value', 'start_value', 'increment_by', 'cache_size')),
    'pg_sequences'' fixed config columns (min/max/start_value, increment_by, cache_size) should all classify as gauge, not counter'
);

SELECT ok(
    (SELECT class = 'gauge' FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_ident_file_mappings' AND column_name = 'map_number')
    OR NOT EXISTS (SELECT 1 FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_ident_file_mappings' AND column_name = 'map_number'),
    'pg_ident_file_mappings.map_number, when present (a PG16+ column), should classify as gauge (an ordinal position, not a counter)'
);
SELECT ok(
    (SELECT bool_and(class = 'gauge') FROM pgfr_record.column_classes
     WHERE source_view = 'pg_catalog.pg_stat_activity' AND column_name IN ('leader_pid', 'query_id')),
    'pg_stat_activity''s leader_pid/query_id should classify as gauge, not counter (identity-shaped values, not cumulative)'
);
SELECT ok(
    (SELECT class = 'gauge' FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_stat_subscription' AND column_name = 'leader_pid')
    OR NOT EXISTS (SELECT 1 FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_stat_subscription' AND column_name = 'leader_pid'),
    'pg_stat_subscription.leader_pid, when present (added after PG15), should classify as gauge, not counter'
);
SELECT ok(
    (SELECT bool_and(class = 'gauge') FROM pgfr_record.column_classes
     WHERE source_view = 'pg_catalog.pg_stat_activity' AND column_name IN ('wait_event', 'wait_event_type', 'state')),
    'pg_stat_activity''s wait_event/wait_event_type/state should classify as gauge (the point-in-time condition Mode A sampling is built on), not label'
);
SELECT is(
    (SELECT class FROM pgfr_record.column_classes WHERE source_view = 'pg_catalog.pg_stat_replication' AND column_name = 'state'),
    'gauge',
    'pg_stat_replication.state should classify as gauge, not label'
);

-- ---------------------------------------------------------------------------
-- Regeneration is wholesale and idempotent.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.generate_column_classes()$$, 're-running generate_column_classes() should not error');
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.column_classes),
    (SELECT sum(array_length(ps.columns, 1))::int
     FROM pgfr_record.manifest m
     JOIN LATERAL (
        SELECT columns FROM pgfr_record.payload_schemas p
        WHERE p.source_view = m.source_view ORDER BY p.schema_id DESC LIMIT 1
     ) ps ON true
     WHERE m.enabled
       AND m.min_major <= pgfr_record._current_major()
       AND pgfr_record._current_major() <= coalesce(m.max_major, 999)),
    're-running generate_column_classes() should settle at the same row count'
);

SELECT * FROM finish();
ROLLBACK;
