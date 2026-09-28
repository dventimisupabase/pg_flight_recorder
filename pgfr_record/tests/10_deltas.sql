-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- deltas() (§4.5)
-- =============================================================================
-- pg_stat_wal is used for the functional round-trip: it is a singleton
-- (no key/JOIN complexity to set up), and its wal_records counter grows
-- naturally from run_tier()'s own INSERTs -- no need to manufacture
-- activity to get a real, non-synthetic increasing counter.

BEGIN;
SELECT plan(9);

SELECT has_function('pgfr_record', 'deltas', 'Function pgfr_record.deltas should exist');

SELECT throws_ok(
    $$SELECT * FROM pgfr_record.deltas('pg_catalog.pg_locks', now() - interval '1 hour', now()) AS d(x text)$$,
    'P0001', NULL,
    'deltas() on a keyless target should raise an exception'
);
SELECT throws_ok(
    $$SELECT * FROM pgfr_record.deltas('pg_catalog.nonexistent_view', now() - interval '1 hour', now()) AS d(x text)$$,
    'P0001', NULL,
    'deltas() on an unknown source_view should raise an exception'
);

-- Column-definition list for pg_stat_wal's deltas() output, built
-- dynamically (not hardcoded, since the exact column set can differ
-- across majors): counter/odometer columns become <col>_delta (numeric
-- instead of pg_lsn, if ever applicable); everything else passes through
-- under its own name and type.
SELECT string_agg(
           CASE
               WHEN cc.class IN ('counter','odometer') THEN format('%I %s', u.c || '_delta', CASE WHEN u.t = 'pg_lsn' THEN 'numeric' ELSE u.t END)
               ELSE format('%I %s', u.c, u.t)
           END,
           ', ' ORDER BY u.ord
       ) || ', from_captured_at timestamptz, to_captured_at timestamptz' AS defs
FROM (SELECT columns, type_names FROM pgfr_record.payload_schemas
      WHERE source_view = 'pg_catalog.pg_stat_wal' ORDER BY schema_id DESC LIMIT 1) ps,
     unnest(ps.columns, ps.type_names) WITH ORDINALITY AS u(c, t, ord),
     pgfr_record.column_classes cc
WHERE cc.source_view = 'pg_catalog.pg_stat_wal' AND cc.column_name = u.c
\gset wal_delta_

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'first run_tier(''fast'') should capture pg_stat_wal');
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'second run_tier(''fast'') should capture pg_stat_wal again, after real WAL activity from the first run''s own inserts');

SELECT min(captured_at) AS t1, max(captured_at) AS t2 FROM pgfr_record.a_pg_stat_wal \gset wal_

-- ---------------------------------------------------------------------------
-- Functional round-trip over two real captures with no reset in between.
-- ---------------------------------------------------------------------------
SELECT ok(
    (SELECT wal_records_delta FROM pgfr_record.deltas('pg_catalog.pg_stat_wal', :'wal_t1'::timestamptz, :'wal_t2'::timestamptz) AS d(:wal_delta_defs)) IS NOT NULL,
    'deltas() should compute a non-null wal_records_delta across two real captures with no reset in between'
);
SELECT ok(
    (SELECT wal_records_delta FROM pgfr_record.deltas('pg_catalog.pg_stat_wal', :'wal_t1'::timestamptz, :'wal_t2'::timestamptz) AS d(:wal_delta_defs)) >= 0,
    'wal_records_delta should never be negative'
);

-- ---------------------------------------------------------------------------
-- Reset-awareness: manufacture a synthetic sample with a lower counter
-- value and an advanced stats_reset, and confirm the delta into it is
-- NULL rather than a bogus negative-turned-positive rate.
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$INSERT INTO pgfr_record.a_pg_stat_wal (captured_at, key, key_hash, row_hash, schema_id, payload)
      SELECT
          a.captured_at + interval '1 second',
          a.key, a.key_hash, 999999999::bigint, a.schema_id,
          jsonb_set(
              jsonb_set(a.payload, ARRAY[(array_position(ps.columns, 'wal_records') - 1)::text], '5'::jsonb),
              ARRAY[(array_position(ps.columns, 'stats_reset') - 1)::text],
              to_jsonb((a.payload ->> (array_position(ps.columns, 'stats_reset') - 1))::timestamptz + interval '1 minute')
          )
      FROM pgfr_record.a_pg_stat_wal a,
           (SELECT columns FROM pgfr_record.payload_schemas WHERE source_view = 'pg_catalog.pg_stat_wal' ORDER BY schema_id DESC LIMIT 1) ps
      ORDER BY a.captured_at DESC LIMIT 1$$,
    'manufacturing a synthetic reset sample for pg_stat_wal should succeed'
);
SELECT ok(
    (SELECT wal_records_delta FROM pgfr_record.deltas('pg_catalog.pg_stat_wal', :'wal_t2'::timestamptz, (:'wal_t2'::timestamptz + interval '1 second')) AS d(:wal_delta_defs)) IS NULL,
    'a decreased counter value alongside an advanced reset_column should yield a NULL delta, not a negative one'
);

SELECT * FROM finish();
ROLLBACK;
