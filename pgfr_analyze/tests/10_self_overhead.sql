-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- self_overhead()
-- =============================================================================
-- ledger_runs.tier has no CHECK constraint restricting it to the four real
-- cadence tiers, so a synthetic 'synthtest' tier gives an isolated,
-- precisely-controlled duration assertion with no risk of colliding with
-- real tier runs. Block-share rows are synthesized the same way as
-- 08/09's tests: a captured payload copied and mutated at
-- array_position()-derived offsets, with a baseline 10 minutes before the
-- spike so deltas() has both sides of its window to compare.

BEGIN;
SELECT plan(7);

SELECT has_function('pgfr_analyze', 'self_overhead', ARRAY['timestamptz', 'timestamptz'], 'Function pgfr_analyze.self_overhead should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('slow')$$, 'run_tier(''slow'') should capture a real baseline for pg_statio_all_tables');

SELECT clock_timestamp() AS t_ref \gset ref_
SELECT set_config('pgfr_test.t_ref', :'ref_t_ref', true);

-- ---------------------------------------------------------------------------
-- Backdated rows below (ledger_runs at t_ref - 5 minutes, pg_statio_all_tables
-- at t_ref - 10 minutes) need a partition covering that point; if the test
-- happens to run in the first few minutes after midnight, that point falls
-- in yesterday's (not-yet-existing) partition instead of today's.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
    v_point timestamptz := current_setting('pgfr_test.t_ref')::timestamptz - interval '10 minutes';
    v_lower timestamptz := date_trunc('day', v_point);
    v_upper timestamptz := v_lower + interval '1 day';
    v_table text;
    v_child text;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['ledger_runs', 'a_pg_statio_all_tables']
    LOOP
        IF to_regclass('pgfr_record.' || v_table) IS NOT NULL THEN
            v_child := pgfr_record._partition_child_name(v_table, v_lower, 'day');
            IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
                EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.%I FOR VALUES FROM (%L) TO (%L)', v_child, v_table, v_lower, v_upper);
            END IF;
        END IF;
    END LOOP;
END $do$;

-- ---------------------------------------------------------------------------
-- ledger_runs: a synthetic tier with two runs, 100ms and 300ms, averaging
-- exactly 200ms.
-- ---------------------------------------------------------------------------
INSERT INTO pgfr_record.ledger_runs (tier, captured_at, finished_at) VALUES
    ('synthtest', :'ref_t_ref'::timestamptz - interval '5 minutes', :'ref_t_ref'::timestamptz - interval '5 minutes' + interval '100 milliseconds'),
    ('synthtest', :'ref_t_ref'::timestamptz, :'ref_t_ref'::timestamptz + interval '300 milliseconds');

SELECT is(
    (SELECT value FROM pgfr_analyze.self_overhead(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'synthtest_ms_per_tick'),
    200.0::numeric,
    'self_overhead() should average two synthetic ledger_runs durations (100ms, 300ms) to exactly 200ms'
);

-- ---------------------------------------------------------------------------
-- pg_statio_all_tables: two relations, one in pgfr_record's own schema and
-- one elsewhere, with a known 800:200 block-hit split (0.8 recorder share).
-- ---------------------------------------------------------------------------
SELECT key, key_hash, schema_id, payload FROM pgfr_record.a_pg_statio_all_tables a WHERE (a.key->>'relid')::oid = (SELECT oid FROM pg_class WHERE relname = 'manifest' AND relnamespace = 'pgfr_record'::regnamespace) ORDER BY captured_at DESC LIMIT 1 \gset pgfr_
SELECT key, key_hash, schema_id, payload FROM pgfr_record.a_pg_statio_all_tables a WHERE (a.key->>'relid')::oid = 2619 ORDER BY captured_at DESC LIMIT 1 \gset other_
SELECT array_position(columns, 'heap_blks_hit') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_statio_all_tables' ORDER BY schema_id DESC LIMIT 1 \gset hh_

INSERT INTO pgfr_record.a_pg_statio_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz - interval '10 minutes', :'pgfr_key'::jsonb, :pgfr_key_hash, 7801, :pgfr_schema_id, jsonb_set(:'pgfr_payload'::jsonb, ARRAY[:'hh_p'], '0'::jsonb)),
    (:'ref_t_ref'::timestamptz, :'pgfr_key'::jsonb, :pgfr_key_hash, 7802, :pgfr_schema_id, jsonb_set(:'pgfr_payload'::jsonb, ARRAY[:'hh_p'], '800'::jsonb)),
    (:'ref_t_ref'::timestamptz - interval '10 minutes', :'other_key'::jsonb, :other_key_hash, 7803, :other_schema_id, jsonb_set(:'other_payload'::jsonb, ARRAY[:'hh_p'], '0'::jsonb)),
    (:'ref_t_ref'::timestamptz, :'other_key'::jsonb, :other_key_hash, 7804, :other_schema_id, jsonb_set(:'other_payload'::jsonb, ARRAY[:'hh_p'], '200'::jsonb));

SELECT is(
    (SELECT value FROM pgfr_analyze.self_overhead(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'recorder_block_share'),
    0.8::numeric,
    'self_overhead() should compute an 800:200 block-hit split as an 0.8 recorder_block_share'
);

-- ---------------------------------------------------------------------------
-- Live, point-in-time metrics: sanity-check presence and shape rather than
-- an exact value (these are read straight from pg_class/pg_stat_statements
-- at call time, not from a controlled window).
-- ---------------------------------------------------------------------------
SELECT ok(
    (SELECT value FROM pgfr_analyze.self_overhead(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'storage_bytes') > 0,
    'self_overhead() should report a positive storage_bytes footprint for the pgfr_record/pgfr_analyze schemas'
);
SELECT ok(
    (SELECT value FROM pgfr_analyze.self_overhead(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz) WHERE metric = 'pgss_time_share') IS NOT NULL,
    'self_overhead() should report a non-null pgss_time_share when pg_stat_statements is installed'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SAVEPOINT analyze_readonly;
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.self_overhead(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz)) >= 0,
    'self_overhead() should execute successfully inside a hard READ ONLY transaction'
);
ROLLBACK TO SAVEPOINT analyze_readonly;

SELECT * FROM finish();
ROLLBACK;
