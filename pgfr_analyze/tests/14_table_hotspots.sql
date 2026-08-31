-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- table_hotspots()
-- =============================================================================
-- Synthetic archive rows built the same way as 08/09/10's tests: a captured
-- payload copied and mutated at array_position()-derived offsets, with a
-- baseline row 10 minutes before the spike so deltas() has both sides of
-- its window to compare (a key present only at the spike end is excluded
-- by deltas()'s inner join, not fabricated).

BEGIN;
SELECT plan(7);

SELECT has_function('pgfr_analyze', 'table_hotspots', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.table_hotspots should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should capture a real baseline for pg_stat_all_tables');

SELECT clock_timestamp() AS t_ref \gset ref_
SELECT set_config('pgfr_test.t_ref', :'ref_t_ref', true);

-- Group B (pg_stat_all_tables) is daily-partitioned; ensure a possible-
-- yesterday partition exists for the backdated point, same reasoning as
-- 08/09/10.
DO $do$
DECLARE
    v_point timestamptz := current_setting('pgfr_test.t_ref')::timestamptz - interval '10 minutes';
    v_lower timestamptz := date_trunc('day', v_point);
    v_upper timestamptz := v_lower + interval '1 day';
    v_child text := pgfr_record._partition_child_name('a_pg_stat_all_tables', v_lower, 'day');
BEGIN
    IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.a_pg_stat_all_tables FOR VALUES FROM (%L) TO (%L)', v_child, v_lower, v_upper);
    END IF;
END $do$;

SELECT payload, schema_id FROM pgfr_record.a_pg_stat_all_tables ORDER BY captured_at DESC LIMIT 1 \gset tbl_
SELECT array_position(columns, 'relid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset relid_
SELECT array_position(columns, 'relname') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset rn_
SELECT array_position(columns, 'seq_scan') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset ss_
SELECT array_position(columns, 'seq_tup_read') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset str_
SELECT array_position(columns, 'n_live_tup') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset live_
SELECT array_position(columns, 'n_dead_tup') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset dead_
SELECT array_position(columns, 'n_tup_upd') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset upd_
SELECT array_position(columns, 'n_tup_hot_upd') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset hot_
SELECT array_position(columns, 'autovacuum_count') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset av_

-- :tbl_payload is "whichever row happened to be captured most recently" --
-- not necessarily a low-activity table, since pg_stat_all_tables captures
-- pgfr_record's own tables too, and every test file before this one
-- queries them. Cloning it as-is for a baseline risks inheriting a
-- seq_scan/seq_tup_read/n_dead_tup/n_tup_upd/autovacuum_count already
-- past this file's own thresholds -- which would either trip
-- deltas()'s reset-guard (a baseline "higher" than the synthetic spike
-- reads as a reset, yielding NULL, not a large delta) or pre-trip a
-- check the baseline was never meant to touch. Zero every counter this
-- function reads once, up front, so every synthetic scenario below starts
-- from a deterministic, isolated 0 regardless of real background activity.
SELECT jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'tbl_payload'::jsonb,
    ARRAY[:'ss_p'], '0'::jsonb),
    ARRAY[:'str_p'], '0'::jsonb),
    ARRAY[:'live_p'], '0'::jsonb),
    ARRAY[:'dead_p'], '0'::jsonb),
    ARRAY[:'upd_p'], '0'::jsonb),
    ARRAY[:'hot_p'], '0'::jsonb) AS clean_payload \gset base_
SELECT jsonb_set(:'base_clean_payload'::jsonb, ARRAY[:'av_p'], '0'::jsonb) AS clean_payload \gset base_

-- SEQUENTIAL_SCAN_STORM + TABLE_BLOAT on one relation (150 seq scans
-- reading 20M tuples, 100% dead tuples).
INSERT INTO pgfr_record.a_pg_stat_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz - interval '10 minutes', NULL, NULL, 7900, :tbl_schema_id,
     jsonb_set(jsonb_set(:'base_clean_payload'::jsonb, ARRAY[:'relid_p'], '999998801'::jsonb), ARRAY[:'rn_p'], '"synth_seqscan_tbl"'::jsonb)),
    (:'ref_t_ref'::timestamptz, NULL, NULL, 7901, :tbl_schema_id,
     jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'base_clean_payload'::jsonb,
        ARRAY[:'relid_p'], '999998801'::jsonb),
        ARRAY[:'rn_p'], '"synth_seqscan_tbl"'::jsonb),
        ARRAY[:'ss_p'], '150'::jsonb),
        ARRAY[:'str_p'], '20000000'::jsonb),
        ARRAY[:'dead_p'], '600000'::jsonb));

SELECT is(
    (SELECT severity FROM pgfr_analyze.table_hotspots(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE relname = 'synth_seqscan_tbl' AND issue_type = 'SEQUENTIAL_SCAN_STORM'),
    'high',
    'table_hotspots() should flag 150 seq scans reading 20M tuples as SEQUENTIAL_SCAN_STORM/high'
);
SELECT is(
    (SELECT severity FROM pgfr_analyze.table_hotspots(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE relname = 'synth_seqscan_tbl' AND issue_type = 'TABLE_BLOAT'),
    'high',
    'table_hotspots() should flag 100%% dead tuples as TABLE_BLOAT/high'
);

-- LOW_HOT_UPDATE_RATIO + HIGH_AUTOVACUUM_FREQUENCY on a second relation
-- (2000 updates, 0 HOT; 8 autovacuums).
INSERT INTO pgfr_record.a_pg_stat_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz - interval '10 minutes', NULL, NULL, 7902, :tbl_schema_id,
     jsonb_set(jsonb_set(:'base_clean_payload'::jsonb, ARRAY[:'relid_p'], '999998802'::jsonb), ARRAY[:'rn_p'], '"synth_hotupdate_tbl"'::jsonb)),
    (:'ref_t_ref'::timestamptz, NULL, NULL, 7903, :tbl_schema_id,
     jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'base_clean_payload'::jsonb,
        ARRAY[:'relid_p'], '999998802'::jsonb),
        ARRAY[:'rn_p'], '"synth_hotupdate_tbl"'::jsonb),
        ARRAY[:'upd_p'], '2000'::jsonb),
        ARRAY[:'av_p'], '8'::jsonb));

SELECT is(
    (SELECT severity FROM pgfr_analyze.table_hotspots(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE relname = 'synth_hotupdate_tbl' AND issue_type = 'LOW_HOT_UPDATE_RATIO'),
    'medium',
    'table_hotspots() should flag 2000 updates with 0%% HOT as LOW_HOT_UPDATE_RATIO/medium'
);
SELECT is(
    (SELECT severity FROM pgfr_analyze.table_hotspots(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE relname = 'synth_hotupdate_tbl' AND issue_type = 'HIGH_AUTOVACUUM_FREQUENCY'),
    'low',
    'table_hotspots() should flag 8 autovacuums in the window as HIGH_AUTOVACUUM_FREQUENCY/low'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.table_hotspots(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz)) >= 0,
    'table_hotspots() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
