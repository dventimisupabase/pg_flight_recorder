-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- query_dict, refresh_query_dict(),
-- detect_regressions(), detect_query_storms()
-- =============================================================================
-- pg_stat_statements is a debounced, daily-partitioned Group B target, so a
-- real baseline-vs-recent comparison needs a "yesterday" partition and
-- backdated rows -- neither exists yet in a freshly-built container
-- (create-ahead only creates partitions ahead of now()). Rather than rely on
-- live pg_stat_statements activity being deterministically trackable within
-- a test transaction (observed unreliable in this environment for reasons
-- unrelated to pgfr_analyze itself), every scenario below constructs its own
-- synthetic archive rows directly: a template payload is built from the
-- current payload_schemas column/type list (default per type), then
-- jsonb_set positions specific columns by name via array_position(), the
-- same technique pgfr_record's own 10_deltas.sql test uses.

BEGIN;
SELECT plan(15);

SELECT has_table('pgfr_analyze', 'query_dict', 'Table pgfr_analyze.query_dict should exist');
SELECT has_function('pgfr_analyze', 'refresh_query_dict', 'Function pgfr_analyze.refresh_query_dict should exist');
SELECT has_function('pgfr_analyze', 'detect_regressions', ARRAY['interval', 'numeric'], 'Function pgfr_analyze.detect_regressions should exist');
SELECT has_function('pgfr_analyze', 'detect_query_storms', ARRAY['interval', 'numeric'], 'Function pgfr_analyze.detect_query_storms should exist');

-- ---------------------------------------------------------------------------
-- Template payload: one default value per column, positioned to match the
-- live pg_stat_statements shape. archive_table already exists with today's
-- partition (generate_archives() pre-creates it at install time), so no
-- run_tier() call is needed to set up storage.
-- ---------------------------------------------------------------------------
SELECT jsonb_agg(
    (CASE
        WHEN t IN ('bigint', 'integer', 'smallint', 'oid', 'double precision', 'numeric') THEN '0'
        WHEN t = 'boolean' THEN 'false'
        WHEN t = 'text' THEN '"synthetic"'
        ELSE '0'
    END)::jsonb ORDER BY ord
) AS base_payload
FROM (SELECT columns, type_names FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1) ps,
     unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(c, t, ord)
\gset base_

SELECT schema_id FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset schema_
SELECT array_position(columns, 'queryid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset queryid_
SELECT array_position(columns, 'dbid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset dbid_
SELECT array_position(columns, 'userid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset userid_
SELECT array_position(columns, 'toplevel') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset toplevel_
SELECT array_position(columns, 'query') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset query_
SELECT array_position(columns, 'calls') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset calls_
SELECT array_position(columns, 'total_exec_time') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset exec_
SELECT array_position(columns, 'shared_blks_hit') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset hit_
SELECT array_position(columns, 'shared_blks_read') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_stat_statements' ORDER BY schema_id DESC LIMIT 1 \gset read_

-- ---------------------------------------------------------------------------
-- query_dict / refresh_query_dict()
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.a_pg_stat_statements (captured_at, key, key_hash, row_hash, schema_id, payload)
VALUES (
    clock_timestamp(),
    jsonb_build_object('userid', 10, 'dbid', 5, 'queryid', 111111111111, 'toplevel', true),
    hashtextextended('{"userid": 10, "dbid": 5, "queryid": 111111111111, "toplevel": true}', 0),
    5001, :schema_schema_id,
    jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'base_base_payload'::jsonb,
        ARRAY[:'queryid_p'], '111111111111'::jsonb),
        ARRAY[:'dbid_p'], '5'::jsonb),
        ARRAY[:'userid_p'], '10'::jsonb),
        ARRAY[:'query_p'], '"SELECT 1 FROM query_dict_test_table"'::jsonb)
);

SELECT lives_ok($$SELECT pgfr_analyze.refresh_query_dict()$$, 'refresh_query_dict() should succeed');
SELECT is(
    (SELECT query_text FROM pgfr_analyze.query_dict WHERE queryid = 111111111111),
    'SELECT 1 FROM query_dict_test_table',
    'query_dict should carry the query text for the synthetic queryid'
);
SELECT lives_ok($$SELECT pgfr_analyze.refresh_query_dict()$$, 're-running refresh_query_dict() should not error');

-- ---------------------------------------------------------------------------
-- detect_regressions(): a synthetic queryid whose per-call latency jumps
-- from 10ms/call at baseline to 270ms/call recently (2600% -- CRITICAL).
-- ---------------------------------------------------------------------------
-- This scenario is a pure exec-time regression (buffers are left at the
-- template's default 0 on both sides, which the 'buffers' metric's own
-- zero-guard would otherwise report as NULL and filter out).
INSERT INTO pgfr_analyze.config (key, value) VALUES
    ('regression_baseline_days', '1'),
    ('regression_detection_metric', 'time')
ON CONFLICT (key) DO UPDATE SET value = excluded.value;

DO $$
DECLARE
    v_lower timestamptz := date_trunc('day', now()) - interval '1 day';
    v_upper timestamptz := date_trunc('day', now());
    v_child text := 'a_pg_stat_statements_p' || to_char(v_lower, 'YYYYMMDD');
BEGIN
    IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.a_pg_stat_statements FOR VALUES FROM (%L) TO (%L)', v_child, v_lower, v_upper);
    END IF;
END $$;

SELECT clock_timestamp() AS t_ref \gset ref_

INSERT INTO pgfr_record.a_pg_stat_statements (captured_at, key, key_hash, row_hash, schema_id, payload)
SELECT c.t, jsonb_build_object('userid', 10, 'dbid', 5, 'queryid', 222222222222, 'toplevel', true), 555, c.rh, :schema_schema_id,
       jsonb_set(jsonb_set(jsonb_set(jsonb_set(jsonb_set(:'base_base_payload'::jsonb,
           ARRAY[:'queryid_p'], '222222222222'::jsonb),
           ARRAY[:'toplevel_p'], 'true'::jsonb),
           ARRAY[:'query_p'], '"SELECT 1 FROM regression_test_table"'::jsonb),
           ARRAY[:'calls_p'], to_jsonb(c.calls)),
           ARRAY[:'exec_p'], to_jsonb(c.exec_time))
FROM (VALUES
    (:'ref_t_ref'::timestamptz - interval '1 day' - interval '1 hour', 10::bigint, 100::double precision, 6001),
    (:'ref_t_ref'::timestamptz - interval '1 day',                     20::bigint, 200::double precision, 6002),
    (:'ref_t_ref'::timestamptz - interval '1 hour',                    30::bigint, 300::double precision, 6003),
    (:'ref_t_ref'::timestamptz,                                        40::bigint, 3000::double precision, 6004)
) AS c(t, calls, exec_time, rh);

SELECT is(
    (SELECT severity FROM pgfr_analyze.detect_regressions(interval '1 hour', 50.0) WHERE queryid = 222222222222),
    'CRITICAL',
    'detect_regressions() should classify a 10ms/call -> 270ms/call jump as CRITICAL'
);
SELECT ok(
    (SELECT change_pct FROM pgfr_analyze.detect_regressions(interval '1 hour', 50.0) WHERE queryid = 222222222222) > 1000,
    'detect_regressions() should report change_pct above the CRITICAL threshold'
);
SELECT is(
    (SELECT current_calls FROM pgfr_analyze.detect_regressions(interval '1 hour', 50.0) WHERE queryid = 222222222222),
    10::bigint,
    'detect_regressions() should report the recent window''s call delta'
);

-- ---------------------------------------------------------------------------
-- detect_query_storms(): a synthetic queryid whose call rate jumps from
-- 1 call/window at baseline to 200 calls/window recently (200x -- CRITICAL).
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_analyze.config (key, value) VALUES ('storm_baseline_days', '1') ON CONFLICT (key) DO UPDATE SET value = excluded.value;

INSERT INTO pgfr_record.a_pg_stat_statements (captured_at, key, key_hash, row_hash, schema_id, payload)
SELECT c.t, jsonb_build_object('userid', 10, 'dbid', 5, 'queryid', 333333333333, 'toplevel', true), 777, c.rh, :schema_schema_id,
       jsonb_set(jsonb_set(jsonb_set(:'base_base_payload'::jsonb,
           ARRAY[:'queryid_p'], '333333333333'::jsonb),
           ARRAY[:'query_p'], '"SELECT 1 FROM storm_test_table"'::jsonb),
           ARRAY[:'calls_p'], to_jsonb(c.calls))
FROM (VALUES
    (:'ref_t_ref'::timestamptz - interval '1 day' - interval '1 hour', 10::bigint, 7001),
    (:'ref_t_ref'::timestamptz - interval '1 day',                     11::bigint, 7002),
    (:'ref_t_ref'::timestamptz - interval '1 hour',                    11::bigint, 7003),
    (:'ref_t_ref'::timestamptz,                                        211::bigint, 7004)
) AS c(t, calls, rh);

SELECT is(
    (SELECT storm_type FROM pgfr_analyze.detect_query_storms(interval '1 hour', 3.0) WHERE queryid = 333333333333),
    'CACHE_MISS',
    'detect_query_storms() should classify a 200x call-rate jump as CACHE_MISS (over the 10x hardcoded cutoff)'
);
SELECT is(
    (SELECT severity FROM pgfr_analyze.detect_query_storms(interval '1 hour', 3.0) WHERE queryid = 333333333333),
    'CRITICAL',
    'detect_query_storms() should classify the same jump as CRITICAL severity'
);
SELECT is(
    (SELECT recent_calls FROM pgfr_analyze.detect_query_storms(interval '1 hour', 3.0) WHERE queryid = 333333333333),
    200::bigint,
    'detect_query_storms() should report the recent window''s call delta'
);

-- ---------------------------------------------------------------------------
-- Neither function should write anywhere.
-- ---------------------------------------------------------------------------
SAVEPOINT analyze_readonly;
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.detect_regressions(interval '1 hour', 50.0)) >= 0,
    'detect_regressions() should execute successfully inside a hard READ ONLY transaction'
);
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.detect_query_storms(interval '1 hour', 3.0)) >= 0,
    'detect_query_storms() should execute successfully inside a hard READ ONLY transaction'
);
ROLLBACK TO SAVEPOINT analyze_readonly;

SELECT * FROM finish();
ROLLBACK;
