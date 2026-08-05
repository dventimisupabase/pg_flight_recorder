-- =============================================================================
-- pgfr_record pgTAP Tests: snapshots_v2 column parity (Issue #73 foundation)
-- =============================================================================
-- PR 1 of the legacy-snapshots cutover: snapshots_v2 (and its replication /
-- vacuum twins) reach column parity with the legacy heap, the dual-write
-- paths populate the new columns, and default partitions (which
-- _partition_inventory() cannot see) are garbage-collected once everything
-- in them is past retention.
-- =============================================================================

BEGIN;
SELECT plan(10);

-- -----------------------------------------------------------------------------
-- 1. Column parity
-- -----------------------------------------------------------------------------

SELECT is(
    (SELECT count(*)::int FROM information_schema.columns
     WHERE table_schema = 'pgfr_record' AND table_name = 'snapshots_v2'
       AND column_name IN (
           'bgw_buffers_backend', 'bgw_buffers_backend_fsync',
           'activity_xmin', 'activity_xmin_age',
           'slot_xmin', 'slot_xmin_age',
           'slot_catalog_xmin', 'slot_catalog_xmin_age',
           'replication_xmin', 'replication_xmin_age',
           'prepared_xmin', 'prepared_xmin_age',
           'xmin_data_horizon_age', 'xmin_any_horizon_age', 'xmin_horizon_detail')),
    15,
    'snapshots_v2 carries all 15 parity columns (2 bgwriter + 13 xmin)');

SELECT is(
    (SELECT count(*)::int FROM information_schema.columns
     WHERE table_schema = 'pgfr_record' AND table_name = 'replication_snapshots_v2'
       AND column_name IN ('backend_xmin', 'backend_xmin_age', 'slot_name', 'is_logical_walsender')),
    4,
    'replication_snapshots_v2 carries the xmin/walsender parity columns');

SELECT is(
    (SELECT count(*)::int FROM information_schema.columns
     WHERE table_schema = 'pgfr_record' AND table_name = 'vacuum_progress_snapshots_v2'
       AND column_name IN ('datid', 'relname')),
    2,
    'vacuum_progress_snapshots_v2 carries datid and relname');

-- -----------------------------------------------------------------------------
-- 2. Dual-write: a fresh snapshot() populates the parity columns identically
--    on the legacy row and its v2 twin
-- -----------------------------------------------------------------------------

DO $$ BEGIN PERFORM pgfr_record.snapshot(); END $$;

SELECT ok(
    (SELECT s.xmin_data_horizon_age IS NOT DISTINCT FROM v.xmin_data_horizon_age
     FROM pgfr_record.snapshots s
     JOIN pgfr_record.snapshots_v2 v ON v.snapshot_id = s.id
     ORDER BY s.id DESC LIMIT 1),
    'xmin_data_horizon_age matches between the legacy row and its v2 twin');

SELECT ok(
    (SELECT s.xmin_horizon_detail IS NOT DISTINCT FROM v.xmin_horizon_detail
     FROM pgfr_record.snapshots s
     JOIN pgfr_record.snapshots_v2 v ON v.snapshot_id = s.id
     ORDER BY s.id DESC LIMIT 1),
    'xmin_horizon_detail matches between the legacy row and its v2 twin');

-- On PG15/16 both sides carry real bgwriter backend counters; on PG17+ both
-- are NULL. Either way they must agree.
SELECT ok(
    (SELECT s.bgw_buffers_backend IS NOT DISTINCT FROM v.bgw_buffers_backend
     FROM pgfr_record.snapshots s
     JOIN pgfr_record.snapshots_v2 v ON v.snapshot_id = s.id
     ORDER BY s.id DESC LIMIT 1),
    'bgw_buffers_backend matches between the legacy row and its v2 twin');

-- -----------------------------------------------------------------------------
-- 3. Default-partition garbage collection
-- -----------------------------------------------------------------------------

-- Deterministic fixture: clear any strays other suites left in the default
-- partition (everything here rolls back), then plant a backdated stray
-- (sample_ts = 1000: no partition exists, routes to snapshots_v2_default)
-- plus a future stray (3 days out: past the precreated partitions, also
-- default, well inside retention).
DELETE FROM pgfr_record.snapshots_v2_default;
INSERT INTO pgfr_record.snapshots_v2 (snapshot_id, sample_ts, captured_at, pg_version)
VALUES (-73001, 1000, pgfr_record.epoch() + interval '1000 seconds', 170000),
       (-73002, extract(epoch from now() + interval '3 days' - pgfr_record.epoch())::int4,
        now() + interval '3 days', 170000);

SELECT lives_ok($$SELECT pgfr_record.truncate_old_partitions()$$,
    'truncate_old_partitions() runs with strays in the default partition');

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.snapshots_v2_default
     WHERE snapshot_id IN (-73001, -73002)),
    2,
    'a default partition with any in-retention row is kept whole');

-- Remove the in-retention stray: now everything in the default partition is
-- ancient, so the GC pass may reclaim it.
DELETE FROM pgfr_record.snapshots_v2_default WHERE snapshot_id = -73002;
DO $$ BEGIN PERFORM pgfr_record.truncate_old_partitions(); END $$;

SELECT is(
    (SELECT count(*)::int FROM pgfr_record.snapshots_v2_default
     WHERE snapshot_id = -73001),
    0,
    'a default partition whose newest row is past retention is truncated');

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record._partition_inventory()
        WHERE partition_name LIKE '%\_default'),
    'sanity: _partition_inventory() still cannot see default partitions (the GC pass covers them)');

SELECT * FROM finish();
ROLLBACK;
