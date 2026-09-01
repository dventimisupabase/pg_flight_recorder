-- =============================================================================
-- pgfr_record v2 pgTAP Tests -- milestone 8: health_check() rollup lag
-- =============================================================================
-- The core cron_job/last_capture/ledger_miss_rate/partition checks are
-- already covered by 12_profiles.sql; this file covers only the new
-- rollup-lag clause.

BEGIN;
SELECT plan(5);

SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should capture a real anchor for pg_stat_all_tables');

-- ---------------------------------------------------------------------------
-- Fresh state: yesterday's bucket has no raw data at all (this install
-- didn't exist yesterday), which must read as ok, not attention -- the
-- same "empty candidate is not a problem" distinction run_tier()'s own
-- bucket-close step makes.
-- ---------------------------------------------------------------------------
SELECT is(
    (SELECT status FROM pgfr_record.health_check() WHERE check_name = 'rollup: pg_catalog.pg_stat_all_tables'),
    'ok',
    'a rollup target with no raw data yet in its most recently closed bucket should read as ok, not a false attention'
);

-- ---------------------------------------------------------------------------
-- Manufacture raw data in yesterday's bucket without ever running the
-- collector's own bucket-close step (no run_tier() call after this), so
-- the bucket genuinely has data pending rollup -- health_check() should
-- now flag it.
-- ---------------------------------------------------------------------------
-- The rollup table itself is monthly-partitioned regardless of its 1-day
-- bucket granularity (_partition_unit() maps its 365d rollup_retention to
-- 'month'), so a backdated point near a month boundary needs its own
-- monthly partition ensured too, same reasoning as the archive table.
DO $do$
DECLARE
    v_lower        timestamptz := date_trunc('day', clock_timestamp()) - interval '1 day';
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

SELECT is(
    (SELECT status FROM pgfr_record.health_check() WHERE check_name = 'rollup: pg_catalog.pg_stat_all_tables'),
    'attention',
    'a rollup target with real raw data in its most recently closed bucket, not yet rolled up, should read as attention'
);

-- ---------------------------------------------------------------------------
-- After the collector actually closes the bucket, health_check() should
-- clear.
-- ---------------------------------------------------------------------------
SELECT lives_ok($$SELECT pgfr_record.run_tier('medium')$$, 'run_tier(''medium'') should close the pending bucket');
SELECT is(
    (SELECT status FROM pgfr_record.health_check() WHERE check_name = 'rollup: pg_catalog.pg_stat_all_tables'),
    'ok',
    'once the bucket is actually rolled up, health_check() should clear'
);

SELECT * FROM finish();
ROLLBACK;
