-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- milestone 8: run_tier()'s bucket-close step
-- =============================================================================
-- Backdated rows are manufactured by copying a real captured row and
-- retimestamping it (the same technique 10_deltas.sql uses), into
-- manufactured historical partitions (the same technique
-- 08_anomaly_detection.sql uses), rather than waiting on wall-clock time
-- to actually pass.

BEGIN;
SELECT plan(11);

SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should capture a real anchor for pg_stat_all_tables');

-- ---------------------------------------------------------------------------
-- Ensure daily partitions exist for 1-2 days ago (create-ahead only builds
-- ahead of now(), never behind it) and manufacture a backdated copy of
-- today's capture into each -- two distinct, not-yet-rolled-up buckets.
-- (3 days ago is manufactured separately, later, so it is still genuinely
-- pending when the failure-containment test corrupts rollup_close_sql --
-- manufacturing it here too would let this first catch-up call close it
-- before corruption ever happens.)
--
-- The rollup table itself is monthly-partitioned (_partition_unit() maps
-- its 365d rollup_retention to 'month', independent of the 1-day bucket
-- granularity), so a backdated point near a month boundary needs its own
-- monthly partition ensured too -- create-ahead only ever looks forward
-- from the current month, same reasoning as the archive table above.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
    v_days_ago      int;
    v_lower         timestamptz;
    v_upper         timestamptz;
    v_child         text;
    v_rollup_lower  timestamptz;
    v_rollup_upper  timestamptz;
    v_rollup_child  text;
BEGIN
    FOREACH v_days_ago IN ARRAY ARRAY[1, 2]
    LOOP
        v_lower := date_trunc('day', clock_timestamp()) - (v_days_ago || ' days')::interval;
        v_upper := v_lower + interval '1 day';
        v_child := pgfr_record._partition_child_name('a_pg_stat_all_tables', v_lower, 'day');
        IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
            EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.a_pg_stat_all_tables FOR VALUES FROM (%L) TO (%L)', v_child, v_lower, v_upper);
        END IF;

        v_rollup_lower := date_trunc('month', v_lower);
        v_rollup_upper := v_rollup_lower + interval '1 month';
        v_rollup_child := pgfr_record._partition_child_name('r_pg_stat_all_tables', v_rollup_lower, 'month');
        IF to_regclass('pgfr_record.' || v_rollup_child) IS NULL THEN
            EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.r_pg_stat_all_tables FOR VALUES FROM (%L) TO (%L)', v_rollup_child, v_rollup_lower, v_rollup_upper);
        END IF;

        INSERT INTO pgfr_record.a_pg_stat_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload)
        SELECT v_lower + interval '1 hour', key, key_hash, row_hash, schema_id, payload
        FROM pgfr_record.a_pg_stat_all_tables
        WHERE captured_at = (SELECT max(captured_at) FROM pgfr_record.a_pg_stat_all_tables);
    END LOOP;
END $do$;

-- ---------------------------------------------------------------------------
-- One run_tier() call should catch up on both of the first two backdated
-- buckets (1 and 2 days ago) in a single pass, not just the one
-- immediately before now() -- the bounded multi-bucket self-heal.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should execute without error while catching up on backdated buckets');

SELECT is(
    (SELECT count(DISTINCT bucket_start)::int FROM pgfr_record.r_pg_stat_all_tables
     WHERE bucket_start IN (date_trunc('day', clock_timestamp()) - interval '1 day', date_trunc('day', clock_timestamp()) - interval '2 days')),
    2,
    'a single run_tier() call should close both the 1-day-ago and 2-days-ago buckets, not just the most recent one'
);

-- ---------------------------------------------------------------------------
-- Failure containment: manufacture one more, still-pending bucket
-- (3 days ago), then corrupt rollup_close_sql for pg_stat_all_tables. The
-- bucket-close failure must not roll back the raw capture, must not
-- propagate out of run_tier(), and must not fake a successful close.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
    v_lower        timestamptz := date_trunc('day', clock_timestamp()) - interval '3 days';
    v_upper        timestamptz := v_lower + interval '1 day';
    v_child        text := pgfr_record._partition_child_name('a_pg_stat_all_tables', v_lower, 'day');
    v_rollup_lower timestamptz := date_trunc('month', v_lower);
    v_rollup_upper timestamptz := v_rollup_lower + interval '1 month';
    v_rollup_child text := pgfr_record._partition_child_name('r_pg_stat_all_tables', v_rollup_lower, 'month');
BEGIN
    IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.a_pg_stat_all_tables FOR VALUES FROM (%L) TO (%L)', v_child, v_lower, v_upper);
    END IF;
    IF to_regclass('pgfr_record.' || v_rollup_child) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.r_pg_stat_all_tables FOR VALUES FROM (%L) TO (%L)', v_rollup_child, v_rollup_lower, v_rollup_upper);
    END IF;

    INSERT INTO pgfr_record.a_pg_stat_all_tables (captured_at, key, key_hash, row_hash, schema_id, payload)
    SELECT v_lower + interval '1 hour', key, key_hash, row_hash, schema_id, payload
    FROM pgfr_record.a_pg_stat_all_tables
    WHERE captured_at = (SELECT max(captured_at) FROM pgfr_record.a_pg_stat_all_tables);
END $do$;

SELECT lives_ok(
    $$UPDATE pgfr_record.capture_plan
      SET rollup_close_sql = 'INSERT INTO pgfr_record.r_pg_stat_all_tables (bucket_start) SELECT nonexistent_column_xyz'
      WHERE source_view = 'pg_catalog.pg_stat_all_tables'$$,
    'corrupting pg_stat_all_tables'' cached rollup_close_sql should succeed (capture_plan is regenerable config, not record)'
);
SELECT lives_ok(
    $$SELECT pgfr_record.run_tier('medium')$$,
    'run_tier(''medium'') should still complete even though pg_stat_all_tables'' rollup_close_sql is broken'
);
SELECT is(
    (SELECT outcome FROM pgfr_record.ledger_captures lc JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
     WHERE lr.tier = 'medium' AND lc.source_view = 'pg_catalog.pg_stat_all_tables'
     ORDER BY lr.finished_at DESC LIMIT 1),
    'ok',
    'the raw capture must still succeed even though this same target''s rollup close is broken -- the two are separate subtransactions'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.r_pg_stat_all_tables
        WHERE bucket_start = date_trunc('day', clock_timestamp()) - interval '3 days'
    ),
    'the 3-days-ago bucket should NOT appear as rolled up -- a genuinely broken close must not be silently recorded as a success'
);

-- ---------------------------------------------------------------------------
-- Stat shape functional round-trip: pg_stat_activity, hourly granularity.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should capture pg_stat_activity');

DO $do$
DECLARE
    v_lower        timestamptz := date_trunc('hour', clock_timestamp()) - interval '1 hour';
    v_upper        timestamptz := v_lower + interval '1 hour';
    v_child        text := pgfr_record._partition_child_name('a_pg_stat_activity', v_lower, 'hour');
    v_rollup_lower timestamptz := date_trunc('month', v_lower);
    v_rollup_upper timestamptz := v_rollup_lower + interval '1 month';
    v_rollup_child text := pgfr_record._partition_child_name('r_pg_stat_activity', v_rollup_lower, 'month');
BEGIN
    IF to_regclass('pgfr_record.' || v_child) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.a_pg_stat_activity FOR VALUES FROM (%L) TO (%L)', v_child, v_lower, v_upper);
    END IF;
    IF to_regclass('pgfr_record.' || v_rollup_child) IS NULL THEN
        EXECUTE format('CREATE TABLE pgfr_record.%I PARTITION OF pgfr_record.r_pg_stat_activity FOR VALUES FROM (%L) TO (%L)', v_rollup_child, v_rollup_lower, v_rollup_upper);
    END IF;

    INSERT INTO pgfr_record.a_pg_stat_activity (captured_at, key, key_hash, row_hash, schema_id, payload)
    SELECT v_lower + interval '5 minutes', key, key_hash, row_hash, schema_id, payload
    FROM pgfr_record.a_pg_stat_activity
    WHERE captured_at = (SELECT max(captured_at) FROM pgfr_record.a_pg_stat_activity);
END $do$;

SELECT lives_ok($$SELECT pgfr_record.run_tier('fast')$$, 'run_tier(''fast'') should execute without error while catching up on the backdated pg_stat_activity bucket');

SELECT is(
    (SELECT array_agg(stat_name ORDER BY stat_name) FROM pgfr_record.r_pg_stat_activity
     WHERE bucket_start = date_trunc('hour', clock_timestamp()) - interval '1 hour'),
    (SELECT array_agg(stat_name ORDER BY stat_name) FROM pgfr_record.rollup_specs WHERE source_view = 'pg_catalog.pg_stat_activity'),
    'the backdated hour should get one stat-rollup row per configured rollup_specs stat_name'
);
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.r_pg_stat_activity
        WHERE bucket_start = date_trunc('hour', clock_timestamp())
    ),
    'the current, still-open hour should not have a rollup row yet -- only closed buckets are rolled up'
);

SELECT * FROM finish();
ROLLBACK;
