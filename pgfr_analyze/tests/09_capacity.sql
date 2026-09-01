-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- capacity_summary()
-- =============================================================================
-- Synthetic archive rows built the same way as 08_anomaly_detection.sql: a
-- captured payload copied and mutated at array_position()-derived offsets,
-- with a baseline row 10 minutes before the spike so deltas() has both
-- sides of its window to compare.

BEGIN;
SELECT plan(9);

SELECT has_function('pgfr_analyze', 'capacity_summary', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.capacity_summary should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture a real baseline for pg_stat_bgwriter and pg_stat_database');

SELECT clock_timestamp() AS t_ref \gset ref_
SELECT set_config('pgfr_test.t_ref', :'ref_t_ref', true);

-- ---------------------------------------------------------------------------
-- Every deltas()-based check below inserts a row-pair at t_ref - 10 minutes
-- and t_ref; if the test happens to run in the first 10 minutes after the
-- start of a month, t_ref - 10 minutes falls in the previous month's
-- (not-yet-existing) partition instead of the current one. Ensure it exists
-- for every Group A table this file backdates into.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
    v_point timestamptz := current_setting('pgfr_test.t_ref')::timestamptz - interval '10 minutes';
    v_lower timestamptz := date_trunc('month', v_point);
    v_upper timestamptz := v_lower + interval '1 month';
    v_table text;
    v_child text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['a_pg_stat_bgwriter', 'a_pg_stat_checkpointer', 'a_pg_stat_io', 'a_pg_stat_database']
    LOOP
        IF to_regclass('pgfr_record.' || v_table) IS NOT NULL THEN
            v_child := pgfr_record._partition_child_name(v_table, v_lower, 'month');
            IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
                EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.%I FOR VALUES FROM (%L) TO (%L)', v_child, v_table, v_lower, v_upper);
            END IF;
        END IF;
    END LOOP;
END $do$;

-- ---------------------------------------------------------------------------
-- Connections: always present when pg_stat_database has any capture in the
-- window: sanity-check the shape and that utilization is a true ratio
-- against max_connections.
-- ---------------------------------------------------------------------------
SELECT ok(
    (SELECT utilization_pct FROM pgfr_analyze.capacity_summary(:'ref_t_ref'::timestamptz - interval '5 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'connections') IS NOT NULL,
    'capacity_summary() should report a connections row with a non-null utilization_pct'
);
SELECT is(
    (SELECT provisioned_capacity FROM pgfr_analyze.capacity_summary(:'ref_t_ref'::timestamptz - interval '5 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'connections'),
    current_setting('max_connections'),
    'capacity_summary() should report max_connections as the connections dimension''s provisioned_capacity'
);

-- ---------------------------------------------------------------------------
-- pg_stat_bgwriter (singleton): 1500 backend-written buffers in the window
-- (>= the 1000-buffer reference used by anomaly_report()'s BUFFER_PRESSURE).
-- Version-aware exactly like anomaly_report()'s own test: PG15/16 read
-- buffers_backend off pg_stat_bgwriter directly; PG17+ removes that column
-- in favor of summed pg_stat_io client-backend rows.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
    v_t_ref timestamptz := current_setting('pgfr_test.t_ref')::timestamptz;
BEGIN
    IF pgfr_record._current_major() >= 17 THEN
        DECLARE
            v_key      jsonb;
            v_key_hash bigint;
            v_schema_id smallint;
            v_payload  jsonb;
            v_columns  text[];
            v_writes_pos int;
        BEGIN
            SELECT key, key_hash, schema_id, payload INTO v_key, v_key_hash, v_schema_id, v_payload
            FROM pgfr_record.a_pg_stat_io
            WHERE (key->>'backend_type') = 'client backend' AND (key->>'object') = 'relation' AND (key->>'context') = 'normal'
            ORDER BY captured_at DESC LIMIT 1;
            SELECT columns INTO v_columns FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_io' ORDER BY schema_id DESC LIMIT 1;
            v_writes_pos := array_position(v_columns, 'writes') - 1;

            EXECUTE format(
                'INSERT INTO pgfr_record.a_pg_stat_io (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
                    ($1 - interval ''10 minutes'', %1$L, %2$L, 7700, %3$L, jsonb_set($2, ARRAY[%4$L], ''0''::jsonb)),
                    ($1, %1$L, %2$L, 7701, %3$L, jsonb_set($2, ARRAY[%4$L], ''1500''::jsonb))',
                v_key, v_key_hash, v_schema_id, v_writes_pos::text
            ) USING v_t_ref, v_payload;
        END;
    ELSE
        DECLARE
            v_schema_id smallint;
            v_payload   jsonb;
            v_be_pos    int;
        BEGIN
            SELECT schema_id, payload INTO v_schema_id, v_payload FROM pgfr_record.a_pg_stat_bgwriter ORDER BY captured_at DESC LIMIT 1;
            SELECT array_position(columns, 'buffers_backend') - 1 INTO v_be_pos FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_bgwriter' ORDER BY schema_id DESC LIMIT 1;

            EXECUTE format(
                'INSERT INTO pgfr_record.a_pg_stat_bgwriter (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
                    ($1 - interval ''10 minutes'', NULL, NULL, 7700, %1$L, jsonb_set($2, ARRAY[%2$L], ''0''::jsonb)),
                    ($1, NULL, NULL, 7701, %1$L, jsonb_set($2, ARRAY[%2$L], ''1500''::jsonb))',
                v_schema_id, v_be_pos::text
            ) USING v_t_ref, v_payload;
        END;
    END IF;
END $do$;

SELECT is(
    (SELECT status FROM pgfr_analyze.capacity_summary(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'memory_shared_buffers'),
    'critical',
    'capacity_summary() should classify 1500 backend-written buffers as memory_shared_buffers/critical'
);

-- ---------------------------------------------------------------------------
-- pg_stat_database (current db): a 2GiB temp spill and a poor cache hit
-- ratio (900 reads, 100 hits -- 10%, well under the 80% critical cutoff).
-- ---------------------------------------------------------------------------
SELECT key, key_hash, schema_id, payload FROM pgfr_record.a_pg_stat_database a
    WHERE (a.key->>'datid')::oid = (SELECT oid FROM pg_database WHERE datname = current_database())
    ORDER BY captured_at DESC LIMIT 1 \gset db_
SELECT array_position(columns, 'temp_bytes') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_database' ORDER BY schema_id DESC LIMIT 1 \gset tb_
SELECT array_position(columns, 'blks_hit') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_database' ORDER BY schema_id DESC LIMIT 1 \gset bh_
SELECT array_position(columns, 'blks_read') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_database' ORDER BY schema_id DESC LIMIT 1 \gset br_

INSERT INTO pgfr_record.a_pg_stat_database (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz - interval '10 minutes', :'db_key'::jsonb, :db_key_hash, 7700, :db_schema_id,
     jsonb_set(jsonb_set(jsonb_set(:'db_payload'::jsonb, ARRAY[:'tb_p'], '0'::jsonb), ARRAY[:'bh_p'], '0'::jsonb), ARRAY[:'br_p'], '0'::jsonb)),
    (:'ref_t_ref'::timestamptz, :'db_key'::jsonb, :db_key_hash, 7702, :db_schema_id,
     jsonb_set(jsonb_set(jsonb_set(:'db_payload'::jsonb, ARRAY[:'tb_p'], '2147483648'::jsonb), ARRAY[:'bh_p'], '100'::jsonb), ARRAY[:'br_p'], '900'::jsonb));

SELECT is(
    (SELECT status FROM pgfr_analyze.capacity_summary(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'memory_work_mem'),
    'critical',
    'capacity_summary() should classify a 2GiB temp spill as memory_work_mem/critical'
);
SELECT is(
    (SELECT status FROM pgfr_analyze.capacity_summary(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'io_buffer_cache'),
    'critical',
    'capacity_summary() should classify a 10%% cache hit ratio as io_buffer_cache/critical'
);
SELECT is(
    (SELECT current_usage FROM pgfr_analyze.capacity_summary(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'transaction_rate'),
    '0 transactions in the window (0.0 tps avg)',
    'capacity_summary() should report zero transactions when xact_commit/xact_rollback do not move'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.capacity_summary(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz)) >= 0,
    'capacity_summary() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
