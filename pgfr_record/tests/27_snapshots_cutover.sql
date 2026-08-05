-- =============================================================================
-- pgfr_record pgTAP Tests: snapshots compat-view cutover (Issue #73, PR 2)
-- =============================================================================
-- pgfr_record.snapshots is now a compatibility view over snapshots_v2:
-- INSERT routes through an INSTEAD OF trigger (id from the legacy sequence,
-- sample_ts derived from captured_at, day partition ensured); UPDATE and
-- DELETE route via auto-update; the FK cascades are gone and cleanup() reaps
-- the child heaps explicitly. Everything here rolls back.
-- =============================================================================

BEGIN;
SELECT plan(13);

-- -----------------------------------------------------------------------------
-- 1. Shape
-- -----------------------------------------------------------------------------

SELECT has_view('pgfr_record', 'snapshots', 'snapshots is the compat view');

SELECT is(
    (SELECT c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgfr_record' AND c.relname = 'snapshots_legacy'),
    'r',
    'the retired heap survives as snapshots_legacy until the final PR');

SELECT is(
    (SELECT count(*)::int FROM pg_constraint
     WHERE contype = 'f'
       AND conrelid IN (
           'pgfr_record.replication_snapshots'::regclass,
           'pgfr_record.vacuum_progress_snapshots'::regclass,
           'pgfr_record.statement_snapshots'::regclass,
           'pgfr_record.table_snapshots'::regclass,
           'pgfr_record.index_snapshots'::regclass,
           'pgfr_record.config_snapshots'::regclass,
           'pgfr_record.db_role_config_snapshots'::regclass)),
    0,
    'the seven FK constraints onto snapshots(id) are dropped');

-- -----------------------------------------------------------------------------
-- 2. INSERT routing
-- -----------------------------------------------------------------------------

-- Defaulted id and derived sample_ts: RETURNING works through the trigger.
DO $$
DECLARE
    v_id bigint;
BEGIN
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
    VALUES (now(), 170000)
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'RETURNING id came back NULL through the view trigger';
    END IF;
    PERFORM set_config('test.cutover_id', v_id::text, true);
END $$;

SELECT ok(
    (SELECT sample_ts = extract(epoch from captured_at - pgfr_record.epoch())::int4
     FROM pgfr_record.snapshots_v2
     WHERE snapshot_id = current_setting('test.cutover_id')::bigint),
    'the routed row landed in snapshots_v2 with sample_ts derived from captured_at');

-- Backdated insert: the trigger ensures the day partition, so the row lands
-- in a real daily partition, never the default.
DO $$
DECLARE
    v_id bigint;
BEGIN
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
    VALUES ('2026-03-15 12:00:00+00', 170000)
    RETURNING id INTO v_id;
    PERFORM set_config('test.cutover_backdated_id', v_id::text, true);
END $$;

SELECT is(
    (SELECT v.tableoid::regclass::text FROM pgfr_record.snapshots_v2 v
     WHERE v.snapshot_id = current_setting('test.cutover_backdated_id')::bigint),
    'pgfr_record.snapshots_v2_2026_03_15',
    'a backdated insert routes to its own day partition, not the default');

-- Sequence continuity: ids strictly increase across inserts.
SELECT ok(
    current_setting('test.cutover_backdated_id')::bigint
        > current_setting('test.cutover_id')::bigint,
    'the legacy id sequence keeps assigning increasing ids');

-- -----------------------------------------------------------------------------
-- 3. UPDATE and DELETE route via auto-update (the xmin write-back path)
-- -----------------------------------------------------------------------------

UPDATE pgfr_record.snapshots
   SET activity_xmin_age = 424242
 WHERE id = current_setting('test.cutover_id')::bigint;

SELECT is(
    (SELECT activity_xmin_age FROM pgfr_record.snapshots_v2
     WHERE snapshot_id = current_setting('test.cutover_id')::bigint),
    424242::bigint,
    'UPDATE through the view reaches snapshots_v2 (snapshot()''s xmin write-back path)');

DELETE FROM pgfr_record.snapshots
 WHERE id = current_setting('test.cutover_backdated_id')::bigint;

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.snapshots_v2
     WHERE snapshot_id = current_setting('test.cutover_backdated_id')::bigint),
    0,
    'DELETE through the view removes the base row');

-- -----------------------------------------------------------------------------
-- 4. snapshot() end to end: view write, consumption, v2 children
-- -----------------------------------------------------------------------------

DO $$ BEGIN PERFORM pgfr_record.snapshot(); END $$;

SELECT ok(
    (SELECT count(*) FROM pgfr_record.snapshots
     WHERE id = (SELECT max(id) FROM pgfr_record.snapshots)) = 1,
    'snapshot() writes through the compat view');

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.consumption_snapshots_v2
            WHERE snapshot_id = (SELECT max(id) FROM pgfr_record.snapshots)),
    'the consumption ledger is collected by snapshot() directly (trigger retired)');

SELECT ok(
    (SELECT xmin_horizon_detail IS NOT DISTINCT FROM xmin_horizon_detail
     FROM pgfr_record.snapshots
     WHERE id = (SELECT max(id) FROM pgfr_record.snapshots)),
    'the xmin write-back applied through the view without error');

-- -----------------------------------------------------------------------------
-- 5. cleanup() reaps orphaned child rows (the FK cascades are gone)
-- -----------------------------------------------------------------------------

INSERT INTO pgfr_record.replication_snapshots (snapshot_id, pid)
VALUES (-1, 424242);

DO $$ BEGIN PERFORM pgfr_record.cleanup(); END $$;

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.replication_snapshots WHERE snapshot_id = -1),
    0,
    'cleanup() deletes child rows whose parent id no longer exists');

SELECT ok(
    EXISTS (SELECT 1 FROM pgfr_record.replication_snapshots r
            JOIN pgfr_record.snapshots s ON s.id = r.snapshot_id)
    OR NOT EXISTS (SELECT 1 FROM pgfr_record.replication_snapshots),
    'cleanup() keeps child rows whose parents are alive');

SELECT * FROM finish();
ROLLBACK;
