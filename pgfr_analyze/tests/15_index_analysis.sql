-- =============================================================================
-- pgfr_analyze v2 pgTAP Tests -- unused_indexes(), index_efficiency()
-- =============================================================================
-- Index size comes from live pg_relation_size(), so both functions are
-- exercised against a real, existing index's captured row (pg_relation_size()
-- needs a real indexrelid), with its idx_scan/idx_tup_read/idx_tup_fetch
-- counters overridden via jsonb_set to a known baseline+spike pair -- the
-- same technique used throughout this suite -- rather than relying on
-- incidental real background scan activity, which a freshly built, quiet
-- container may not generate enough of within the test's own window.

BEGIN;
SELECT plan(9);

SELECT has_function('pgfr_analyze', 'unused_indexes', ARRAY['interval'], 'Function pgfr_analyze.unused_indexes should exist');
SELECT has_function('pgfr_analyze', 'index_efficiency', ARRAY['timestamptz', 'timestamptz', 'int4'], 'Function pgfr_analyze.index_efficiency should exist');

SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should capture a real baseline for pg_stat_all_indexes');

SELECT clock_timestamp() AS t_ref \gset ref_
SELECT set_config('pgfr_test.t_ref', :'ref_t_ref', true);

-- Group B (pg_stat_all_indexes) is daily-partitioned; ensure a possible-
-- yesterday partition exists for the backdated point.
DO $do$
DECLARE
    v_point timestamptz := current_setting('pgfr_test.t_ref')::timestamptz - interval '10 minutes';
    v_lower timestamptz := date_trunc('day', v_point);
    v_upper timestamptz := v_lower + interval '1 day';
    v_child text := pgfr_record._partition_child_name('a_pg_stat_all_indexes', v_lower, 'day');
BEGIN
    IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.a_pg_stat_all_indexes FOR VALUES FROM (%L) TO (%L)', v_child, v_lower, v_upper);
    END IF;
END $do$;

SELECT array_position(columns, 'indexrelname') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_indexes' ORDER BY schema_id DESC LIMIT 1 \gset irn_
SELECT array_position(columns, 'idx_scan') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_indexes' ORDER BY schema_id DESC LIMIT 1 \gset is_
SELECT array_position(columns, 'idx_tup_read') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_indexes' ORDER BY schema_id DESC LIMIT 1 \gset itr_
SELECT array_position(columns, 'idx_tup_fetch') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_indexes' ORDER BY schema_id DESC LIMIT 1 \gset itf_

-- A busy real index: pgfr_record.payload_schemas_pkey, a genuinely existing
-- index (pg_relation_size() needs one), given a known 500-scan, 95%-
-- selectivity delta.
SELECT key, key_hash, schema_id, payload FROM pgfr_record.a_pg_stat_all_indexes a
    WHERE (a.payload->>:'irn_p'::int) = 'payload_schemas_pkey' ORDER BY captured_at DESC LIMIT 1 \gset busy_

INSERT INTO pgfr_record.a_pg_stat_all_indexes (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz - interval '10 minutes', :'busy_key'::jsonb, :busy_key_hash, 7801, :busy_schema_id,
     jsonb_set(jsonb_set(jsonb_set(:'busy_payload'::jsonb, ARRAY[:'is_p'], '0'::jsonb), ARRAY[:'itr_p'], '0'::jsonb), ARRAY[:'itf_p'], '0'::jsonb)),
    (:'ref_t_ref'::timestamptz, :'busy_key'::jsonb, :busy_key_hash, 7802, :busy_schema_id,
     jsonb_set(jsonb_set(jsonb_set(:'busy_payload'::jsonb, ARRAY[:'is_p'], '500'::jsonb), ARRAY[:'itr_p'], '1000'::jsonb), ARRAY[:'itf_p'], '950'::jsonb));

-- A quiet real index (any captured non-primary-key index): given a known
-- zero-scan delta, so unused_indexes()'s never-used branch is deterministic.
SELECT key, key_hash, schema_id, payload, (payload->>:'irn_p'::int) AS indexrelname FROM pgfr_record.a_pg_stat_all_indexes a
    WHERE (a.payload->>:'irn_p'::int) NOT LIKE '%_pkey' ORDER BY captured_at DESC LIMIT 1 \gset quiet_

INSERT INTO pgfr_record.a_pg_stat_all_indexes (captured_at, key, key_hash, row_hash, schema_id, payload) VALUES
    (:'ref_t_ref'::timestamptz - interval '10 minutes', :'quiet_key'::jsonb, :quiet_key_hash, 7803, :quiet_schema_id,
     jsonb_set(:'quiet_payload'::jsonb, ARRAY[:'is_p'], '0'::jsonb)),
    (:'ref_t_ref'::timestamptz, :'quiet_key'::jsonb, :quiet_key_hash, 7804, :quiet_schema_id,
     jsonb_set(:'quiet_payload'::jsonb, ARRAY[:'is_p'], '0'::jsonb));

-- ---------------------------------------------------------------------------
-- unused_indexes(): every returned row should have fewer than 100 scans,
-- exclude primary keys, and carry a recommendation matching its scan_delta;
-- the quiet index above should appear with the never-used recommendation.
-- ---------------------------------------------------------------------------
SELECT ok(
    (SELECT bool_and(scan_delta < 100) FROM pgfr_analyze.unused_indexes(interval '10 minutes')),
    'every unused_indexes() row should have fewer than 100 scans in the window'
);
SELECT ok(
    NOT EXISTS (SELECT 1 FROM pgfr_analyze.unused_indexes(interval '10 minutes') WHERE indexrelname LIKE '%_pkey'),
    'unused_indexes() should never recommend dropping a primary key'
);
SELECT is(
    (SELECT recommendation FROM pgfr_analyze.unused_indexes(interval '10 minutes') WHERE indexrelname = :'quiet_indexrelname'),
    'DROP INDEX (never used in 00:10:00)',
    'unused_indexes() should recommend dropping the synthetic zero-scan index'
);

-- ---------------------------------------------------------------------------
-- index_efficiency(): the synthetic 500-scan spike should show up exactly.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT idx_scan_delta FROM pgfr_analyze.index_efficiency(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz, 1000) WHERE indexrelname = 'payload_schemas_pkey'),
    500::bigint,
    'index_efficiency() should report the synthetic 500-scan delta for payload_schemas_pkey'
);
SELECT is(
    (SELECT selectivity FROM pgfr_analyze.index_efficiency(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz, 1000) WHERE indexrelname = 'payload_schemas_pkey'),
    95.0::numeric,
    'index_efficiency() should compute 950/1000 as 95%% selectivity'
);

-- ---------------------------------------------------------------------------
-- Should not write anywhere.
-- ---------------------------------------------------------------------------
SET TRANSACTION READ ONLY;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.unused_indexes(interval '10 minutes')) >= 0
    AND (SELECT count(*) FROM pgfr_analyze.index_efficiency(:'ref_t_ref'::timestamptz - interval '10 minutes', :'ref_t_ref'::timestamptz)) >= 0,
    'unused_indexes() and index_efficiency() should execute successfully inside a hard READ ONLY transaction'
);

SELECT * FROM finish();
ROLLBACK;
