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
SELECT plan(20);

SELECT has_function('pgfr_analyze', 'anomaly_report', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.anomaly_report should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture a real baseline for pg_stat_bgwriter and pg_stat_database');
SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should capture a real baseline for pg_stat_all_tables');
SELECT lives_ok($$SELECT pgfr_record.run_tier('on_change')$$, 'run_tier(''on_change'') should capture a real baseline for pg_database and src_catalog_identity');

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
-- pg_stat_activity (Group C, current-state reads via state_as_of()): a
-- backend idle in transaction for 10 minutes, and 25 backends idle for 2+
-- hours (a connection-leak scenario).
-- ---------------------------------------------------------------------------
SELECT payload, schema_id FROM pgfr_record.a_pg_stat_activity ORDER BY captured_at DESC LIMIT 1 \gset act_row_
SELECT array_position(columns, 'pid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_activity' ORDER BY schema_id DESC LIMIT 1 \gset pid_
SELECT array_position(columns, 'backend_start') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_activity' ORDER BY schema_id DESC LIMIT 1 \gset bs_
SELECT array_position(columns, 'state') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_activity' ORDER BY schema_id DESC LIMIT 1 \gset state_
SELECT array_position(columns, 'xact_start') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_activity' ORDER BY schema_id DESC LIMIT 1 \gset xact_
SELECT array_position(columns, 'state_change') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_activity' ORDER BY schema_id DESC LIMIT 1 \gset chg_

INSERT INTO pgfr_record.a_pg_stat_activity (captured_at, key, key_hash, row_hash, schema_id, payload)
VALUES (
    :'ref_t_ref'::timestamptz, NULL, NULL, 8101, :act_row_schema_id,
    jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'act_row_payload'::jsonb,
        ARRAY[:'pid_p'], '999001'::jsonb),
        ARRAY[:'bs_p'], to_jsonb(:'ref_t_ref'::timestamptz - interval '1 hour')),
        ARRAY[:'state_p'], '"idle in transaction"'::jsonb),
        ARRAY[:'xact_p'], to_jsonb(:'ref_t_ref'::timestamptz - interval '10 minutes'))
);

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'IDLE_IN_TRANSACTION' AND description LIKE '%999001%'),
    'MEDIUM',
    'anomaly_report() should flag a 10-minute idle-in-transaction backend as IDLE_IN_TRANSACTION/MEDIUM'
);

INSERT INTO pgfr_record.a_pg_stat_activity (captured_at, key, key_hash, row_hash, schema_id, payload)
SELECT :'ref_t_ref'::timestamptz, NULL, NULL, 8200 + gs, :act_row_schema_id,
    jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'act_row_payload'::jsonb,
        ARRAY[:'pid_p'], to_jsonb(999100 + gs)),
        ARRAY[:'bs_p'], to_jsonb(:'ref_t_ref'::timestamptz - interval '3 hours')),
        ARRAY[:'state_p'], '"idle"'::jsonb),
        ARRAY[:'chg_p'], to_jsonb(:'ref_t_ref'::timestamptz - interval '2 hours'))
FROM generate_series(1, 25) AS gs;

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'CONNECTION_LEAK'),
    'MEDIUM',
    'anomaly_report() should flag 25 backends idle for 2+ hours as CONNECTION_LEAK/MEDIUM (below the 50-backend HIGH band)'
);

-- ---------------------------------------------------------------------------
-- pg_stat_all_tables (Group B, current-state reads via state_as_of()): a
-- 60%-dead-tuple table, and a never-vacuumed table with 200000 dead tuples.
-- ---------------------------------------------------------------------------
SELECT payload, schema_id FROM pgfr_record.a_pg_stat_all_tables ORDER BY captured_at DESC LIMIT 1 \gset tbl_row_
SELECT array_position(columns, 'relid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset relid_
SELECT array_position(columns, 'schemaname') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset sn_
SELECT array_position(columns, 'relname') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset rn_
SELECT array_position(columns, 'n_live_tup') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset live_
SELECT array_position(columns, 'n_dead_tup') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset dead_
SELECT array_position(columns, 'last_vacuum') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset lv_
SELECT array_position(columns, 'last_autovacuum') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset lav_

INSERT INTO pgfr_record.a_pg_stat_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload)
VALUES (
    :'ref_t_ref'::timestamptz, NULL, NULL, 8301, :tbl_row_schema_id,
    jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'tbl_row_payload'::jsonb,
        ARRAY[:'relid_p'], '999999901'::jsonb),
        ARRAY[:'rn_p'], '"synth_dead_tuple_tbl"'::jsonb),
        ARRAY[:'live_p'], '4000'::jsonb),
        ARRAY[:'dead_p'], '6000'::jsonb)
);

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'DEAD_TUPLE_ACCUMULATION' AND description LIKE '%synth_dead_tuple_tbl%'),
    'HIGH',
    'anomaly_report() should flag a 60% dead-tuple table as DEAD_TUPLE_ACCUMULATION/HIGH'
);

INSERT INTO pgfr_record.a_pg_stat_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload)
VALUES (
    :'ref_t_ref'::timestamptz, NULL, NULL, 8302, :tbl_row_schema_id,
    jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'tbl_row_payload'::jsonb,
        ARRAY[:'relid_p'], '999999902'::jsonb),
        ARRAY[:'rn_p'], '"synth_vacuum_starved_tbl"'::jsonb),
        ARRAY[:'live_p'], '10000000'::jsonb),
        ARRAY[:'dead_p'], '200000'::jsonb),
        ARRAY[:'lv_p'], 'null'::jsonb),
        ARRAY[:'lav_p'], 'null'::jsonb)
);

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'VACUUM_STARVATION' AND description LIKE '%synth_vacuum_starved_tbl%'),
    'HIGH',
    'anomaly_report() should flag a never-vacuumed table with 200000 dead tuples as VACUUM_STARVATION/HIGH'
);

-- ---------------------------------------------------------------------------
-- pg_database / src_catalog_identity (on_change tier, current-state reads):
-- database- and relation-level XID/MultiXID wraparound distance.
-- age()/mxid_age() are evaluated against the current transaction counter at
-- query time, so a synthetic frozen horizon N transactions old (constructed
-- via modular arithmetic on the running counter) reliably produces an age
-- of exactly N, with no dependency on how old the database actually is.
-- ---------------------------------------------------------------------------
SELECT key, key_hash, schema_id, payload FROM pgfr_record.a_pg_database ORDER BY captured_at DESC LIMIT 1 \gset dbrow_
SELECT array_position(columns, 'datfrozenxid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_database' ORDER BY schema_id DESC LIMIT 1 \gset fxid_
SELECT array_position(columns, 'datminmxid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_database' ORDER BY schema_id DESC LIMIT 1 \gset fmxid_
SELECT array_position(columns, 'datname') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_database' ORDER BY schema_id DESC LIMIT 1 \gset dn_
SELECT ((pg_current_xact_id()::text::bigint - 250000001 + 4294967296) % 4294967296)::text::xid AS x \gset oldxid_
SELECT ((next_multixact_id::text::bigint - 250000001 + 4294967296) % 4294967296)::text::xid AS x FROM pg_control_checkpoint() \gset oldmxid_

INSERT INTO pgfr_record.a_pg_database (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz, :'dbrow_key'::jsonb, :dbrow_key_hash, 9101, :dbrow_schema_id,
     jsonb_set(jsonb_set(jsonb_set(:'dbrow_payload'::jsonb,
        ARRAY[:'fxid_p'], to_jsonb(:'oldxid_x'::text)),
        ARRAY[:'fmxid_p'], to_jsonb(:'oldmxid_x'::text)),
        ARRAY[:'dn_p'], '"synth_wraparound_db"'::jsonb));

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'XID_WRAPAROUND_RISK' AND description LIKE '%synth_wraparound_db%'),
    'MEDIUM',
    'anomaly_report() should flag a 250M-transaction-old datfrozenxid as XID_WRAPAROUND_RISK/MEDIUM (below the 1.5B HIGH band)'
);
SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'MXID_WRAPAROUND_RISK' AND description LIKE '%synth_wraparound_db%'),
    'MEDIUM',
    'anomaly_report() should flag a 250M-multixact-old datminmxid as MXID_WRAPAROUND_RISK/MEDIUM (below the 1.5B HIGH band)'
);

SELECT key, key_hash, schema_id, payload FROM pgfr_record.a_src_catalog_identity ORDER BY captured_at DESC LIMIT 1 \gset catrow_
SELECT array_position(columns, 'oid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pgfr_record.src_catalog_identity' ORDER BY schema_id DESC LIMIT 1 \gset roid_
SELECT array_position(columns, 'relfrozenxid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pgfr_record.src_catalog_identity' ORDER BY schema_id DESC LIMIT 1 \gset rfxid_
SELECT array_position(columns, 'relminmxid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pgfr_record.src_catalog_identity' ORDER BY schema_id DESC LIMIT 1 \gset rfmxid_
SELECT array_position(columns, 'relname') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pgfr_record.src_catalog_identity' ORDER BY schema_id DESC LIMIT 1 \gset rn_
SELECT array_position(columns, 'relkind') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pgfr_record.src_catalog_identity' ORDER BY schema_id DESC LIMIT 1 \gset rk_
SELECT ((pg_current_xact_id()::text::bigint - 1600000001 + 4294967296) % 4294967296)::text::xid AS x \gset oldrelxid_
SELECT ((next_multixact_id::text::bigint - 1600000001 + 4294967296) % 4294967296)::text::xid AS x FROM pg_control_checkpoint() \gset oldrelmxid_
SELECT (:'catrow_key'::jsonb->>'oid')::bigint + 1 AS oid \gset newoid_

-- The synthetic oid must be mutated in both the archive row's key column
-- (what state_as_of()'s DISTINCT ON groups by at the storage layer) and the
-- payload's own embedded oid field (what the presentation view -- and so
-- state_as_of()'s actual natural-key comparison -- reads); otherwise both
-- rows collapse into one identity and only one survives DISTINCT ON.
INSERT INTO pgfr_record.a_src_catalog_identity (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz, :'catrow_key'::jsonb, :catrow_key_hash, 9201, :catrow_schema_id,
     jsonb_set(jsonb_set(jsonb_set(:'catrow_payload'::jsonb,
        ARRAY[:'rfxid_p'], to_jsonb(:'oldrelxid_x'::text)),
        ARRAY[:'rn_p'], '"synth_wraparound_tbl"'::jsonb),
        ARRAY[:'rk_p'], '"r"'::jsonb)),
    (:'ref_t_ref'::timestamptz, jsonb_set(:'catrow_key'::jsonb, '{oid}', to_jsonb(:'newoid_oid'::text)), :catrow_key_hash + 1, 9202, :catrow_schema_id,
     jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'catrow_payload'::jsonb,
        ARRAY[:'roid_p'], to_jsonb(:'newoid_oid'::text)),
        ARRAY[:'rfmxid_p'], to_jsonb(:'oldrelmxid_x'::text)),
        ARRAY[:'rn_p'], '"synth_mxid_wraparound_tbl"'::jsonb),
        ARRAY[:'rk_p'], '"r"'::jsonb));

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'RELATION_XID_WRAPAROUND_RISK' AND description LIKE '%synth_wraparound_tbl%'),
    'HIGH',
    'anomaly_report() should flag a 1.6B-transaction-old relfrozenxid as RELATION_XID_WRAPAROUND_RISK/HIGH'
);
SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'RELATION_MXID_WRAPAROUND_RISK' AND description LIKE '%synth_mxid_wraparound_tbl%'),
    'HIGH',
    'anomaly_report() should flag a 1.6B-multixact-old relminmxid as RELATION_MXID_WRAPAROUND_RISK/HIGH'
);

-- ---------------------------------------------------------------------------
-- pg_stat_replication / pg_replication_slots (fast tier, current-state
-- reads): a lagging replica, and an inactive slot. A standalone test
-- instance has no real replicas, so both rows are built from scratch (one
-- default value per column by type, the same technique 06_query_
-- performance.sql uses), rather than mutating a captured template.
-- ---------------------------------------------------------------------------
SELECT jsonb_agg(
    (CASE
        WHEN t IN ('bigint', 'integer', 'smallint', 'oid') THEN '0'
        WHEN t = 'boolean' THEN 'false'
        WHEN t IN ('text', 'name') THEN '"synthetic"'
        WHEN t = 'inet' THEN '"127.0.0.1"'
        WHEN t = 'xid' THEN '"3"'
        WHEN t = 'pg_lsn' THEN '"0/0"'
        WHEN t = 'interval' THEN '"00:00:00"'
        WHEN t IN ('timestamp with time zone', 'timestamp without time zone') THEN '"2020-01-01T00:00:00+00:00"'
        ELSE '0'
    END)::jsonb ORDER BY ord
) AS base_payload
FROM (SELECT columns, type_names FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_replication' ORDER BY schema_id DESC LIMIT 1) ps,
     unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(c, t, ord)
\gset repl_base_
SELECT schema_id FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_replication' ORDER BY schema_id DESC LIMIT 1 \gset replschema_
SELECT array_position(columns, 'replay_lag') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_replication' ORDER BY schema_id DESC LIMIT 1 \gset lag_
SELECT array_position(columns, 'application_name') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_replication' ORDER BY schema_id DESC LIMIT 1 \gset an_
SELECT array_position(columns, 'pid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_replication' ORDER BY schema_id DESC LIMIT 1 \gset repid_

INSERT INTO pgfr_record.a_pg_stat_replication (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz, NULL, NULL, 9301, :replschema_schema_id,
     jsonb_set(jsonb_set(jsonb_set(:'repl_base_base_payload'::jsonb,
        ARRAY[:'lag_p'], '"00:10:00"'::jsonb),
        ARRAY[:'an_p'], '"synth_replica"'::jsonb),
        ARRAY[:'repid_p'], '999501'::jsonb));

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'REPLICATION_LAG' AND description LIKE '%synth_replica%'),
    'HIGH',
    'anomaly_report() should flag a 10-minute replay lag as REPLICATION_LAG/HIGH'
);

SELECT jsonb_agg(
    (CASE
        WHEN t IN ('bigint', 'integer', 'smallint', 'oid') THEN '0'
        WHEN t = 'boolean' THEN 'false'
        WHEN t IN ('text', 'name') THEN '"synthetic"'
        WHEN t = 'xid' THEN '"3"'
        WHEN t = 'pg_lsn' THEN '"0/0"'
        WHEN t IN ('timestamp with time zone', 'timestamp without time zone') THEN '"2020-01-01T00:00:00+00:00"'
        ELSE '0'
    END)::jsonb ORDER BY ord
) AS base_payload
FROM (SELECT columns, type_names FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_replication_slots' ORDER BY schema_id DESC LIMIT 1) ps,
     unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(c, t, ord)
\gset slot_base_
SELECT schema_id FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_replication_slots' ORDER BY schema_id DESC LIMIT 1 \gset slotschema_
SELECT array_position(columns, 'active') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_replication_slots' ORDER BY schema_id DESC LIMIT 1 \gset act_
SELECT array_position(columns, 'slot_name') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_replication_slots' ORDER BY schema_id DESC LIMIT 1 \gset sn_

INSERT INTO pgfr_record.a_pg_replication_slots (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz, NULL, NULL, 9401, :slotschema_schema_id,
     jsonb_set(jsonb_set(:'slot_base_base_payload'::jsonb,
        ARRAY[:'act_p'], 'false'::jsonb),
        ARRAY[:'sn_p'], '"synth_inactive_slot"'::jsonb));

SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE anomaly_type = 'REPLICATION_SLOT_INACTIVE' AND description LIKE '%synth_inactive_slot%'),
    'HIGH',
    'anomaly_report() should flag an inactive replication slot as REPLICATION_SLOT_INACTIVE/HIGH'
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
