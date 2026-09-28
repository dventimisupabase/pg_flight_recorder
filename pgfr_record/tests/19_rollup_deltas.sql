-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- milestone 8: rollup_deltas()
-- =============================================================================

BEGIN;
SELECT plan(13);

SELECT has_function('pgfr_record', 'rollup_deltas', 'Function pgfr_record.rollup_deltas should exist');

SELECT throws_ok(
    $$SELECT * FROM pgfr_record.rollup_deltas('pg_catalog.nonexistent_view', now() - interval '1 day', now()) AS d(x text)$$,
    'P0001', NULL,
    'rollup_deltas() on an unknown source_view should raise an exception'
);
SELECT throws_ok(
    $$SELECT * FROM pgfr_record.rollup_deltas('pg_catalog.pg_stat_bgwriter', now() - interval '1 day', now()) AS d(x text)$$,
    'P0001', NULL,
    'rollup_deltas() on a target with no rollup should raise an exception'
);
SELECT throws_ok(
    $$SELECT * FROM pgfr_record.rollup_deltas('pg_catalog.pg_stat_activity', now() - interval '1 day', now()) AS d(x text)$$,
    'P0001', NULL,
    'rollup_deltas() on a stat-shaped (Group C) target should raise an exception -- read the rollup table directly instead'
);

-- ---------------------------------------------------------------------------
-- Functional round-trip: manufacture two distinct, already-closed buckets
-- for the same synthetic relation with known seq_scan values (10, then
-- 50), close both, and confirm rollup_deltas() computes the expected
-- delta between them.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should capture a real baseline for pg_stat_all_tables');

SELECT array_position(columns, 'relid') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' AND kind = 'capture' ORDER BY schema_id DESC LIMIT 1 \gset relid_
SELECT array_position(columns, 'seq_scan') - 1 AS p FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_all_tables' AND kind = 'capture' ORDER BY schema_id DESC LIMIT 1 \gset ss_
SELECT set_config('pgfr_test.relid_p', :'relid_p', true), set_config('pgfr_test.ss_p', :'ss_p', true);

DO $do$
DECLARE
    v_bucket_a timestamptz := date_trunc('day', clock_timestamp()) - interval '2 days';
    v_bucket_b timestamptz := date_trunc('day', clock_timestamp()) - interval '1 day';
    v_relid_p  int := current_setting('pgfr_test.relid_p')::int;
    v_ss_p     int := current_setting('pgfr_test.ss_p')::int;
    v_tbl_payload jsonb;
    v_tbl_schema  smallint;
BEGIN
    SELECT payload, schema_id INTO v_tbl_payload, v_tbl_schema
    FROM pgfr_record.a_pg_stat_all_tables ORDER BY captured_at DESC LIMIT 1;

    -- The rollup table itself is monthly-partitioned regardless of its
    -- 1-day bucket granularity (_partition_unit() maps its 365d
    -- rollup_retention to 'month'), so each backdated bucket needs its
    -- own monthly rollup partition ensured too, in addition to the
    -- archive table's daily one.
    IF to_regclass('pgfr_record.' || pgfr_record._partition_child_name('r_pg_stat_all_tables', date_trunc('month', v_bucket_a), 'month')) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.r_pg_stat_all_tables FOR VALUES FROM (%L) TO (%L)',
            pgfr_record._partition_child_name('r_pg_stat_all_tables', date_trunc('month', v_bucket_a), 'month'),
            date_trunc('month', v_bucket_a), date_trunc('month', v_bucket_a) + interval '1 month');
    END IF;
    IF to_regclass('pgfr_record.' || pgfr_record._partition_child_name('r_pg_stat_all_tables', date_trunc('month', v_bucket_b), 'month')) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.r_pg_stat_all_tables FOR VALUES FROM (%L) TO (%L)',
            pgfr_record._partition_child_name('r_pg_stat_all_tables', date_trunc('month', v_bucket_b), 'month'),
            date_trunc('month', v_bucket_b), date_trunc('month', v_bucket_b) + interval '1 month');
    END IF;

    -- Bucket A (2 days ago): synthetic relid, seq_scan = 10.
    IF to_regclass('pgfr_record.' || pgfr_record._partition_child_name('a_pg_stat_all_tables', v_bucket_a, 'day')) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.a_pg_stat_all_tables FOR VALUES FROM (%L) TO (%L)',
            pgfr_record._partition_child_name('a_pg_stat_all_tables', v_bucket_a, 'day'), v_bucket_a, v_bucket_a + interval '1 day');
    END IF;
    INSERT INTO pgfr_record.a_pg_stat_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload)
    VALUES (v_bucket_a + interval '1 hour', NULL, NULL, 8100, v_tbl_schema,
            jsonb_set(jsonb_set(v_tbl_payload, ARRAY[v_relid_p::text], '999998900'::jsonb), ARRAY[v_ss_p::text], '10'::jsonb));

    -- Bucket B (1 day ago): same synthetic relid, seq_scan = 50.
    IF to_regclass('pgfr_record.' || pgfr_record._partition_child_name('a_pg_stat_all_tables', v_bucket_b, 'day')) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.a_pg_stat_all_tables FOR VALUES FROM (%L) TO (%L)',
            pgfr_record._partition_child_name('a_pg_stat_all_tables', v_bucket_b, 'day'), v_bucket_b, v_bucket_b + interval '1 day');
    END IF;
    INSERT INTO pgfr_record.a_pg_stat_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload)
    VALUES (v_bucket_b + interval '1 hour', NULL, NULL, 8101, v_tbl_schema,
            jsonb_set(jsonb_set(v_tbl_payload, ARRAY[v_relid_p::text], '999998900'::jsonb), ARRAY[v_ss_p::text], '50'::jsonb));
END $do$;

SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should close both manufactured buckets in one pass');

-- rollup_deltas() returns one <col>_delta per counter/odometer column of
-- the whole target, not just the one this test cares about -- the
-- column-definition list must match exactly, built dynamically the same
-- way 10_deltas.sql's own test builds deltas()'s column list.
SELECT 'relid oid, ' || string_agg(
           format('%I %s', u.c || '_delta', CASE WHEN u.t = 'pg_lsn' THEN 'numeric' ELSE u.t END),
           ', ' ORDER BY u.ord
       ) || ', from_bucket timestamptz, to_bucket timestamptz' AS defs
FROM (SELECT columns, type_names FROM pgfr_record.payload_schemas
      WHERE source_view = 'pg_catalog.pg_stat_all_tables' AND kind = 'capture' ORDER BY schema_id DESC LIMIT 1) ps,
     unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(c, t, ord),
     pgfr_record.column_classes cc
WHERE cc.source_view = 'pg_catalog.pg_stat_all_tables' AND cc.column_name = u.c AND cc.class IN ('counter', 'odometer')
\gset tbld_

SELECT is(
    (SELECT seq_scan_delta FROM pgfr_record.rollup_deltas(
        'pg_catalog.pg_stat_all_tables',
        date_trunc('day', clock_timestamp()) - interval '2 days',
        date_trunc('day', clock_timestamp()) - interval '1 day'
     ) AS d(:tbld_defs)
     WHERE relid = 999998900),
    40::bigint,
    'rollup_deltas() should compute seq_scan going from 10 to 50 as a delta of 40'
);
SELECT is(
    (SELECT relid FROM pgfr_record.rollup_deltas(
        'pg_catalog.pg_stat_all_tables',
        date_trunc('day', clock_timestamp()) - interval '2 days',
        date_trunc('day', clock_timestamp()) - interval '1 day'
     ) AS d(:tbld_defs)
     WHERE relid = 999998900),
    999998900::oid,
    'rollup_deltas() should extract the key column (relid) from the rollup row''s own key jsonb'
);

-- ---------------------------------------------------------------------------
-- The bucket run_tier() just closed should be array-encoded: a real
-- schema_id, resolving to a 'rollup' kind payload_schemas row that lists
-- seq_scan (REFERENCE.md's Rollups section).
-- ---------------------------------------------------------------------------
SELECT ok(
    (SELECT schema_id FROM pgfr_record.r_pg_stat_all_tables
     WHERE bucket_start = date_trunc('day', clock_timestamp()) - interval '1 day'
       AND (key->>'relid')::oid = 999998900) IS NOT NULL,
    'a freshly closed rollup bucket should record a non-NULL schema_id'
);
SELECT ok(
    (SELECT 'seq_scan' = ANY(columns) FROM pgfr_record.payload_schemas
     WHERE kind = 'rollup'
       AND schema_id = (SELECT schema_id FROM pgfr_record.r_pg_stat_all_tables
                         WHERE bucket_start = date_trunc('day', clock_timestamp()) - interval '1 day'
                           AND (key->>'relid')::oid = 999998900)),
    'the rollup row''s schema_id should resolve to a ''rollup'' kind payload_schemas row listing seq_scan'
);

-- ---------------------------------------------------------------------------
-- Backward compatibility: a rollup row written before the array-encoding
-- migration has schema_id NULL and name-keyed jsonb objects for
-- first_values/last_values -- never rewritten (§1 invariant 1), so
-- rollup_deltas() must still decode it correctly alongside array-encoded
-- rows (mirrors generate_presentation_views()'s own multi-schema-id
-- tolerance for archives).
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$INSERT INTO pgfr_record.r_pg_stat_all_tables
          (bucket_start, key, key_hash, first_captured_at, last_captured_at, schema_id, first_values, last_values)
      VALUES
          (date_trunc('day', clock_timestamp()) - interval '2 days',
           jsonb_build_object('relid', 999998901),
           hashtextextended((jsonb_build_object('relid', 999998901))::text, 0),
           date_trunc('day', clock_timestamp()) - interval '2 days' + interval '1 hour',
           date_trunc('day', clock_timestamp()) - interval '2 days' + interval '1 hour',
           NULL, jsonb_build_object('seq_scan', 10), jsonb_build_object('seq_scan', 10)),
          (date_trunc('day', clock_timestamp()) - interval '1 day',
           jsonb_build_object('relid', 999998901),
           hashtextextended((jsonb_build_object('relid', 999998901))::text, 0),
           date_trunc('day', clock_timestamp()) - interval '1 day' + interval '1 hour',
           date_trunc('day', clock_timestamp()) - interval '1 day' + interval '1 hour',
           NULL, jsonb_build_object('seq_scan', 50), jsonb_build_object('seq_scan', 50))$$,
    'manufacturing a legacy, object-encoded rollup row pair (schema_id NULL) should succeed'
);
SELECT is(
    (SELECT seq_scan_delta FROM pgfr_record.rollup_deltas(
        'pg_catalog.pg_stat_all_tables',
        date_trunc('day', clock_timestamp()) - interval '2 days',
        date_trunc('day', clock_timestamp()) - interval '1 day'
     ) AS d(:tbld_defs)
     WHERE relid = 999998901),
    40::bigint,
    'rollup_deltas() should compute the correct delta from a legacy, object-encoded (schema_id NULL) rollup row pair'
);
SELECT is(
    (SELECT relid FROM pgfr_record.rollup_deltas(
        'pg_catalog.pg_stat_all_tables',
        date_trunc('day', clock_timestamp()) - interval '2 days',
        date_trunc('day', clock_timestamp()) - interval '1 day'
     ) AS d(:tbld_defs)
     WHERE relid = 999998901),
    999998901::oid,
    'rollup_deltas() should extract the key column from a legacy rollup row exactly as from a current one'
);

SELECT * FROM finish();
ROLLBACK;
