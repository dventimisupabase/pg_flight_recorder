-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- vacuum_progress(), wal_archiver_status(),
-- long_running_transactions()
-- =============================================================================
-- pg_stat_progress_vacuum is normally empty (no vacuum in flight), so its
-- synthetic row is built from scratch by type (the same technique
-- 08_anomaly_detection.sql uses for pg_stat_replication/pg_replication_slots)
-- rather than mutating a captured template. pg_stat_archiver and
-- pg_stat_activity do have real captured rows to mutate.

BEGIN;
SELECT plan(8);

SELECT has_function('pgfr_analyze', 'vacuum_progress', ARRAY['timestamptz'], 'Function pgfr_analyze.vacuum_progress should exist');
SELECT has_function('pgfr_analyze', 'wal_archiver_status', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.wal_archiver_status should exist');
SELECT has_function('pgfr_analyze', 'long_running_transactions', ARRAY['timestamptz', 'interval'], 'Function pgfr_analyze.long_running_transactions should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture a real baseline for pg_stat_archiver and pg_stat_activity');

SELECT clock_timestamp() AS t_ref \gset ref_
SELECT set_config('pgfr_test.t_ref', :'ref_t_ref', true);

-- Group A (pg_stat_archiver) is monthly-partitioned; ensure a possible-
-- previous-month partition exists for the backdated point.
DO $do$
DECLARE
    v_point timestamptz := current_setting('pgfr_test.t_ref')::timestamptz - interval '10 minutes';
    v_lower timestamptz := date_trunc('month', v_point);
    v_upper timestamptz := v_lower + interval '1 month';
    v_child text := pgfr_record._partition_child_name('a_pg_stat_archiver', v_lower, 'month');
BEGIN
    IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.a_pg_stat_archiver FOR VALUES FROM (%L) TO (%L)', v_child, v_lower, v_upper);
    END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- wal_archiver_status(): a 5-file archiving jump.
-- ---------------------------------------------------------------------------
SELECT payload, schema_id FROM pgfr_record.a_pg_stat_archiver ORDER BY captured_at DESC LIMIT 1 \gset arc_
SELECT array_position(columns, 'archived_count') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_archiver' ORDER BY schema_id DESC LIMIT 1 \gset ac_

INSERT INTO pgfr_record.a_pg_stat_archiver (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz - interval '10 minutes', NULL, NULL, 8801, :arc_schema_id, jsonb_set(:'arc_payload'::jsonb, ARRAY[:'ac_p'], '0'::jsonb)),
    (:'ref_t_ref'::timestamptz, NULL, NULL, 8802, :arc_schema_id, jsonb_set(:'arc_payload'::jsonb, ARRAY[:'ac_p'], '5'::jsonb));

SELECT is(
    (SELECT archived_delta FROM pgfr_analyze.wal_archiver_status(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz)),
    5::bigint,
    'wal_archiver_status() should report a 5-file archived_delta'
);

-- ---------------------------------------------------------------------------
-- vacuum_progress(): a synthetic in-flight vacuum, built from scratch by
-- type since the view is normally empty.
-- ---------------------------------------------------------------------------
SELECT jsonb_agg(
    (CASE
        WHEN t IN ('bigint', 'integer', 'oid') THEN '0'
        WHEN t = 'name' THEN '"synthetic"'
        WHEN t = 'text' THEN '"initializing"'
        ELSE '0'
    END)::jsonb ORDER BY ord
) AS base_payload
FROM (SELECT columns, type_names FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_progress_vacuum' ORDER BY schema_id DESC LIMIT 1) ps,
     unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(c, t, ord)
\gset vac_base_
SELECT schema_id FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_progress_vacuum' ORDER BY schema_id DESC LIMIT 1 \gset vacschema_
SELECT array_position(columns, 'pid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_progress_vacuum' ORDER BY schema_id DESC LIMIT 1 \gset vpid_
SELECT array_position(columns, 'phase') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_progress_vacuum' ORDER BY schema_id DESC LIMIT 1 \gset phase_
SELECT array_position(columns, 'heap_blks_total') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_progress_vacuum' ORDER BY schema_id DESC LIMIT 1 \gset hbt_
SELECT array_position(columns, 'heap_blks_scanned') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_progress_vacuum' ORDER BY schema_id DESC LIMIT 1 \gset hbs_

INSERT INTO pgfr_record.a_pg_stat_progress_vacuum (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz, NULL, NULL, 8901, :vacschema_schema_id,
     jsonb_set(jsonb_set(jsonb_set(:'vac_base_base_payload'::jsonb,
        ARRAY[:'vpid_p'], '999701'::jsonb),
        ARRAY[:'hbt_p'], '1000'::jsonb),
        ARRAY[:'hbs_p'], '250'::jsonb));

SELECT is(
    (SELECT pct_scanned FROM pgfr_analyze.vacuum_progress(:'ref_t_ref'::timestamptz) WHERE pid = 999701),
    25.0::numeric,
    'vacuum_progress() should compute 250/1000 heap blocks scanned as 25%%'
);

-- ---------------------------------------------------------------------------
-- long_running_transactions(): a synthetic active (not idle) backend whose
-- transaction has been open for 10 minutes -- broader than IDLE_IN_TRANSACTION.
-- ---------------------------------------------------------------------------
SELECT payload, schema_id FROM pgfr_record.a_pg_stat_activity ORDER BY captured_at DESC LIMIT 1 \gset act_
SELECT array_position(columns, 'pid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_activity' ORDER BY schema_id DESC LIMIT 1 \gset apid_
SELECT array_position(columns, 'state') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_activity' ORDER BY schema_id DESC LIMIT 1 \gset astate_
SELECT array_position(columns, 'xact_start') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_activity' ORDER BY schema_id DESC LIMIT 1 \gset axact_

INSERT INTO pgfr_record.a_pg_stat_activity (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz, NULL, NULL, 8902, :act_schema_id,
     jsonb_set(jsonb_set(jsonb_set(:'act_payload'::jsonb,
        ARRAY[:'apid_p'], '999702'::jsonb),
        ARRAY[:'astate_p'], '"active"'::jsonb),
        ARRAY[:'axact_p'], to_jsonb(:'ref_t_ref'::timestamptz - interval '10 minutes')));

SELECT ok(
    (SELECT xact_age FROM pgfr_analyze.long_running_transactions(:'ref_t_ref'::timestamptz, interval '5 minutes') WHERE pid = 999702) >= interval '10 minutes',
    'long_running_transactions() should flag a 10-minute-old active (not idle) transaction'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.vacuum_progress(:'ref_t_ref'::timestamptz)) >= 0
    AND (SELECT count(*) FROM pgfr_analyze.wal_archiver_status(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz)) >= 0
    AND (SELECT count(*) FROM pgfr_analyze.long_running_transactions(:'ref_t_ref'::timestamptz, interval '5 minutes')) >= 0,
    'vacuum_progress(), wal_archiver_status(), and long_running_transactions() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
