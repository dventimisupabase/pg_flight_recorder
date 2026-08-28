-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- anomaly_report()
-- =============================================================================
-- Synthetic archive rows built by copying a real captured payload and
-- mutating specific positions via jsonb_set (positions resolved by name via
-- array_position(), never hardcoded), the same technique used in
-- 06_query_performance.sql and pgfr_record's own 10_deltas.sql test.
-- pg_stat_bgwriter/pg_stat_database are Group A (30d retention, daily
-- partitions), and today's partition already exists, so no manual
-- partition creation is needed here (unlike the query-performance tests,
-- which needed a "yesterday" partition for their baseline window).

BEGIN;
SELECT plan(8);

SELECT has_function('pgfr_analyze', 'anomaly_report', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.anomaly_report should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture a real baseline for pg_stat_bgwriter and pg_stat_database');

SELECT clock_timestamp() AS t_ref \gset ref_

-- ---------------------------------------------------------------------------
-- Checkpoint + buffer-pressure anomalies: version-aware on two axes.
-- Checkpoint columns live on pg_stat_bgwriter under the pre-PG17 names
-- (PG15/16) or on pg_stat_checkpointer under renamed columns (PG17+:
-- checkpoints_req -> num_requested, checkpoint_write_time -> write_time).
-- Buffer-pressure columns (buffers_backend/buffers_backend_fsync) live on
-- pg_stat_bgwriter on PG15/16, but PG17+ removes them entirely in favor of
-- pg_stat_io (summed writes/fsyncs across every client-backend row) --
-- matching anomaly_report()'s own version branches. On PG15/16 checkpoint
-- and buffer-pressure columns land on the same table, so they're merged
-- into one row-pair (two separate 2-row inserts at the same captured_at
-- would violate the singleton archive's one-row-per-timestamp shape); on
-- PG17+ they're independent inserts on three different tables.
-- ---------------------------------------------------------------------------
SELECT set_config('pgfr_test.t_ref', :'ref_t_ref', true);

DO $do$
DECLARE
    v_ckpt_view       text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'pg_catalog.pg_stat_checkpointer' ELSE 'pg_catalog.pg_stat_bgwriter' END;
    v_ckpt_short      text := pgfr_record._short_name(v_ckpt_view);
    v_req_col         text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'num_requested' ELSE 'checkpoints_req' END;
    v_wt_col          text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'write_time' ELSE 'checkpoint_write_time' END;
    v_t_ref           timestamptz := current_setting('pgfr_test.t_ref')::timestamptz;
    v_ckpt_schema_id  smallint;
    v_ckpt_columns    text[];
    v_ckpt_payload    jsonb;
    v_req_pos         int;
    v_wt_pos          int;
    v_bgw_schema_id   smallint;
    v_bgw_columns     text[];
    v_bgw_payload     jsonb;
    v_be_pos          int;
    v_fs_pos          int;
    v_io_key          jsonb;
    v_io_key_hash     bigint;
    v_io_schema_id    smallint;
    v_io_columns      text[];
    v_io_payload      jsonb;
    v_writes_pos      int;
    v_fsyncs_pos      int;
BEGIN
    SELECT schema_id, columns INTO v_ckpt_schema_id, v_ckpt_columns
    FROM pgfr_record.payload_schemas WHERE source_view = v_ckpt_view ORDER BY schema_id DESC LIMIT 1;
    EXECUTE format('SELECT payload FROM pgfr_record.a_%I ORDER BY captured_at DESC LIMIT 1', v_ckpt_short) INTO v_ckpt_payload;
    v_req_pos := array_position(v_ckpt_columns, v_req_col) - 1;
    v_wt_pos  := array_position(v_ckpt_columns, v_wt_col) - 1;

    IF pgfr_record._current_major() >= 17 THEN
        -- Checkpoint row-pair on pg_stat_checkpointer (singleton).
        EXECUTE format(
            'INSERT INTO pgfr_record.a_%1$I (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
                ($1 - interval ''10 minutes'', NULL, NULL, 8001, %2$L, jsonb_set(jsonb_set($2, ARRAY[%3$L], ''0''::jsonb), ARRAY[%4$L], ''0''::jsonb)),
                ($1, NULL, NULL, 8002, %2$L, jsonb_set(jsonb_set($2, ARRAY[%3$L], ''1''::jsonb), ARRAY[%4$L], ''15000''::jsonb))',
            v_ckpt_short, v_ckpt_schema_id, v_req_pos::text, v_wt_pos::text
        ) USING v_t_ref, v_ckpt_payload;

        -- Buffer-pressure row-pair on pg_stat_io, keyed to one real
        -- (client backend, relation, normal) row so deltas() sees a single
        -- series; anomaly_report() sums writes/fsyncs across every
        -- client-backend row regardless of object/context.
        SELECT key, key_hash, schema_id, payload INTO v_io_key, v_io_key_hash, v_io_schema_id, v_io_payload
        FROM pgfr_record.a_pg_stat_io
        WHERE (key->>'backend_type') = 'client backend' AND (key->>'object') = 'relation' AND (key->>'context') = 'normal'
        ORDER BY captured_at DESC LIMIT 1;
        SELECT columns INTO v_io_columns FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_io' ORDER BY schema_id DESC LIMIT 1;
        v_writes_pos := array_position(v_io_columns, 'writes') - 1;
        v_fsyncs_pos := array_position(v_io_columns, 'fsyncs') - 1;

        EXECUTE format(
            'INSERT INTO pgfr_record.a_pg_stat_io (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
                ($1 - interval ''10 minutes'', %1$L, %2$L, 8003, %3$L, jsonb_set(jsonb_set($2, ARRAY[%4$L], ''0''::jsonb), ARRAY[%5$L], ''0''::jsonb)),
                ($1, %1$L, %2$L, 8004, %3$L, jsonb_set(jsonb_set($2, ARRAY[%4$L], ''1500''::jsonb), ARRAY[%5$L], ''1''::jsonb))',
            v_io_key, v_io_key_hash, v_io_schema_id, v_writes_pos::text, v_fsyncs_pos::text
        ) USING v_t_ref, v_io_payload;
    ELSE
        -- Same table (pg_stat_bgwriter): merge checkpoint + buffer-pressure
        -- columns into one row-pair.
        SELECT schema_id, columns INTO v_bgw_schema_id, v_bgw_columns
        FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_bgwriter' ORDER BY schema_id DESC LIMIT 1;
        SELECT payload INTO v_bgw_payload FROM pgfr_record.a_pg_stat_bgwriter ORDER BY captured_at DESC LIMIT 1;
        v_be_pos := array_position(v_bgw_columns, 'buffers_backend') - 1;
        v_fs_pos := array_position(v_bgw_columns, 'buffers_backend_fsync') - 1;

        EXECUTE format(
            'INSERT INTO pgfr_record.a_%1$I (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
                ($1 - interval ''10 minutes'', NULL, NULL, 8001, %2$L, jsonb_set(jsonb_set(jsonb_set(jsonb_set($2, ARRAY[%3$L], ''0''::jsonb), ARRAY[%4$L], ''0''::jsonb), ARRAY[%5$L], ''0''::jsonb), ARRAY[%6$L], ''0''::jsonb)),
                ($1, NULL, NULL, 8002, %2$L, jsonb_set(jsonb_set(jsonb_set(jsonb_set($2, ARRAY[%3$L], ''1''::jsonb), ARRAY[%4$L], ''15000''::jsonb), ARRAY[%5$L], ''1500''::jsonb), ARRAY[%6$L], ''1''::jsonb))',
            v_ckpt_short, v_bgw_schema_id, v_req_pos::text, v_wt_pos::text, v_be_pos::text, v_fs_pos::text
        ) USING v_t_ref, v_bgw_payload;
    END IF;
END $do$;

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'FORCED_CHECKPOINTS'),
    'HIGH',
    'anomaly_report() should flag a forced checkpoint as FORCED_CHECKPOINTS/HIGH'
);
SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'CHECKPOINT_WRITE_TIME_HIGH'),
    'MEDIUM',
    'anomaly_report() should flag 15000ms checkpoint write time as MEDIUM (below the 30000ms HIGH band)'
);

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'BUFFER_PRESSURE'),
    'HIGH',
    'anomaly_report() should flag 1500 backend-written buffers as BUFFER_PRESSURE/HIGH'
);
SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'BACKEND_FSYNC'),
    'HIGH',
    'anomaly_report() should flag any backend fsync as BACKEND_FSYNC/HIGH'
);

-- ---------------------------------------------------------------------------
-- pg_stat_database (postgres db): a large temp-byte jump.
-- ---------------------------------------------------------------------------
SELECT key, key_hash, schema_id, payload FROM pgfr_record.a_pg_stat_database a
    WHERE (a.key->>'datid')::oid = (SELECT oid FROM pg_database WHERE datname = current_database())
    ORDER BY captured_at DESC LIMIT 1 \gset db_row_
SELECT array_position(columns, 'temp_files') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_database' ORDER BY schema_id DESC LIMIT 1 \gset tf_
SELECT array_position(columns, 'temp_bytes') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_database' ORDER BY schema_id DESC LIMIT 1 \gset tb_

INSERT INTO pgfr_record.a_pg_stat_database (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz - interval '10 minutes', :'db_row_key'::jsonb, :db_row_key_hash, 9001, :db_row_schema_id,
     jsonb_set(jsonb_set(:'db_row_payload'::jsonb, ARRAY[:'tf_p'], '0'::jsonb), ARRAY[:'tb_p'], '0'::jsonb)),
    (:'ref_t_ref'::timestamptz, :'db_row_key'::jsonb, :db_row_key_hash, 9002, :db_row_schema_id,
     jsonb_set(jsonb_set(:'db_row_payload'::jsonb, ARRAY[:'tf_p'], '5'::jsonb), ARRAY[:'tb_p'], '2147483648'::jsonb));

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'TEMP_FILE_SPILLS'),
    'HIGH',
    'anomaly_report() should flag a 2GiB temp spill as TEMP_FILE_SPILLS/HIGH'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SAVEPOINT analyze_readonly;
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz)) >= 0,
    'anomaly_report() should execute successfully inside a hard READ ONLY transaction'
);
ROLLBACK TO SAVEPOINT analyze_readonly;

SELECT * FROM finish();
ROLLBACK;
