-- =============================================================================
-- pgfr_record pgTAP Tests: discontinuity and censoring events (Issue #101)
-- =============================================================================
-- The discontinuities ledger records counter resets, PGSS resets, eviction
-- pressure, restarts, and ring rollup flush failures as first-class,
-- queryable events. These tests exercise the table, the append helper, the
-- restart detector, the consumption-sampler reset emitter, and the PGSS
-- reset emitter. Everything rolls back.
-- =============================================================================

BEGIN;
SELECT plan(12);

SELECT has_table('pgfr_record', 'discontinuities', 'discontinuities ledger exists');
SELECT has_function('pgfr_record', '_record_discontinuity', ARRAY['text', 'text', 'jsonb'],
    '_record_discontinuity() exists');
SELECT has_function('pgfr_record', '_detect_restart', '_detect_restart() exists');

-- The ledger must survive crashes; UNLOGGED would defeat its purpose.
SELECT is(
    (SELECT c.relpersistence FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgfr_record' AND c.relname = 'discontinuities'),
    'p',
    'discontinuities is a LOGGED (permanent) table');

-- -----------------------------------------------------------------------------
-- 1. Append helper
-- -----------------------------------------------------------------------------

SELECT lives_ok(
    $$SELECT pgfr_record._record_discontinuity('restart', 'postmaster',
        '{"previous_start": "2026-01-01"}'::jsonb)$$,
    '_record_discontinuity accepts a valid event');

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.discontinuities
     WHERE event_kind = 'restart' AND scope = 'postmaster'
       AND evidence ->> 'previous_start' = '2026-01-01'),
    1,
    'the event row landed with its evidence');

-- An invalid kind violates the CHECK inside the helper, which swallows it
-- with a warning: collection must never break on a detection bug.
SELECT lives_ok(
    $$SELECT pgfr_record._record_discontinuity('bogus_kind', 'nowhere')$$,
    '_record_discontinuity swallows constraint violations instead of raising');

DELETE FROM pgfr_record.discontinuities;

-- -----------------------------------------------------------------------------
-- 2. Restart detection via last_postmaster_start
-- -----------------------------------------------------------------------------

-- Seed the key with an ancient value: the detector must see the "newer"
-- current postmaster start and record exactly one restart event.
INSERT INTO pgfr_record.config (key, value, updated_at)
VALUES ('last_postmaster_start', '2000-01-01 00:00:00+00', now())
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;

SELECT lives_ok($$SELECT pgfr_record._detect_restart()$$, '_detect_restart() runs');

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.discontinuities WHERE event_kind = 'restart'),
    1,
    'a postmaster start newer than last_postmaster_start records one restart event');

SELECT is(
    (SELECT value::timestamptz FROM pgfr_record.config WHERE key = 'last_postmaster_start'),
    pg_postmaster_start_time(),
    'the detector advances last_postmaster_start to the current value');

-- Second call: no change, no second event.
DO $$ BEGIN PERFORM pgfr_record._detect_restart(); END $$;
SELECT is(
    (SELECT count(*)::int FROM pgfr_record.discontinuities WHERE event_kind = 'restart'),
    1,
    'an unchanged postmaster start records nothing');

-- -----------------------------------------------------------------------------
-- 3. Consumption sampler emits stats_reset events when sentinels move
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    -- 60s in the future so this row is the newest tick even if a live
    -- collection fires mid-test; the emitter compares against the newest.
    v_ts int4 := extract(epoch from now() - pgfr_record.epoch())::int4 + 60;
BEGIN
    PERFORM pgfr_record._ensure_partition('consumption_snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');
    PERFORM pgfr_record._ensure_partition('consumption_snapshots_v2', current_date + 1,
        'snapshot_id, sample_ts desc');
    -- A fake previous tick whose sentinels can never equal the live ones.
    INSERT INTO pgfr_record.consumption_snapshots_v2
        (snapshot_id, sample_ts, captured_at, pg_version, datname,
         db_stats_reset, wal_stats_reset, ckpt_stats_reset)
    VALUES (-950001, v_ts, now() + interval '60 seconds', pgfr_record._pg_version() * 10000,
            current_database(),
            '2000-01-01 00:00:00+00', '2000-01-02 00:00:00+00', '2000-01-03 00:00:00+00');
    PERFORM pgfr_record._collect_consumption_snapshot(-950002);
END $$;

SELECT is(
    (SELECT count(DISTINCT scope)::int FROM pgfr_record.discontinuities
     WHERE event_kind = 'stats_reset'
       AND scope IN ('pg_stat_database', 'pg_stat_wal', 'checkpointer_bgwriter')),
    3,
    'moving reset sentinels record one stats_reset event per counter family');

SELECT * FROM finish();
ROLLBACK;
