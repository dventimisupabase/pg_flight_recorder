-- =============================================================================
-- pgfr_analyze pgTAP Tests - xmin Horizon Anomaly Reporting
-- =============================================================================
-- Red-phase tests for blueprints/XMIN_HORIZON.md §7.2.
--
-- All anomaly assertions use synthetic fixtures (UPDATE rows in
-- pgfr_record.snapshots, INSERT rows in the sidecars). Live xmin holders are
-- exercised in pgfr_record/tests/16_xmin_horizon.sql; this file only covers
-- the analyzer side: anomaly_report() severity, attribution, recommendation
-- text formatting, tie-breaking, and the two reader functions
-- (xmin_horizon_history, current_xmin_horizon_holder).
--
-- Every assertion currently fails against main — analyzer code does not yet
-- exist. Milestone 4 (Green 3) will turn them green.
-- =============================================================================

BEGIN;
SELECT plan(22);

-- =============================================================================
-- Setup helpers — read autovacuum_freeze_max_age once for fixture math
-- =============================================================================

SELECT set_config(
    'pgfr_test.fmax',
    current_setting('autovacuum_freeze_max_age'),
    false
);

-- Fresh-DB sanity: no anomalies of these types should fire on a
-- newly-installed extension before any synthetic fixture is loaded.
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())$$,
    'anomaly_report() runs without error before fixtures'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
        WHERE anomaly_type IN (
            'XMIN_HORIZON_STALL_WARNING',
            'XMIN_HORIZON_STALL',
            'CATALOG_XMIN_HORIZON_STALL_WARNING',
            'CATALOG_XMIN_HORIZON_STALL'
        )
    ),
    'fresh DB fires no XMIN_HORIZON_* or CATALOG_XMIN_* anomalies'
);

-- =============================================================================
-- 1. SEVERITY LADDER — XMIN_HORIZON_STALL{,_WARNING} on data horizon (3 fixtures)
-- =============================================================================

-- Fixture A — warning onset at 60M xids (above 50M default xmin_stall_warning_age)
INSERT INTO pgfr_record.snapshots (id, captured_at, xmin_data_horizon_age)
VALUES (10001, now() - interval '5 minutes', 60000000)
ON CONFLICT (id) DO UPDATE SET
    captured_at = EXCLUDED.captured_at,
    xmin_data_horizon_age = EXCLUDED.xmin_data_horizon_age;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL_WARNING' AND severity = 'warning'
    ),
    'fixture A: xmin_data_horizon_age=60M fires XMIN_HORIZON_STALL_WARNING (warning)'
);

-- Fixture B — high at 60% of autovacuum_freeze_max_age
UPDATE pgfr_record.snapshots
SET xmin_data_horizon_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10)
WHERE id = 10001;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL' AND severity = 'high'
    ),
    'fixture B: xmin_data_horizon_age=0.6*freeze_max fires XMIN_HORIZON_STALL (high)'
);

-- Fixture C — critical at 90%
UPDATE pgfr_record.snapshots
SET xmin_data_horizon_age = (current_setting('pgfr_test.fmax')::bigint * 9 / 10)
WHERE id = 10001;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL' AND severity = 'critical'
    ),
    'fixture C: xmin_data_horizon_age=0.9*freeze_max fires XMIN_HORIZON_STALL (critical)'
);

-- =============================================================================
-- 2. CATALOG HORIZON — symmetric warning + high (2 fixtures)
-- =============================================================================

-- Fixture D — catalog warning, no data horizon stall
UPDATE pgfr_record.snapshots
SET xmin_data_horizon_age = NULL,
    slot_catalog_xmin_age = 60000000
WHERE id = 10001;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'CATALOG_XMIN_HORIZON_STALL_WARNING' AND severity = 'warning'
    ),
    'fixture D: slot_catalog_xmin_age=60M fires CATALOG_XMIN_HORIZON_STALL_WARNING'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type IN ('XMIN_HORIZON_STALL_WARNING', 'XMIN_HORIZON_STALL')
    ),
    'fixture D: catalog-only stall does NOT fire data anomalies (xmin_data_horizon_age IS NULL)'
);

-- Fixture F — both fire at high (verifies non-XOR)
UPDATE pgfr_record.snapshots
SET xmin_data_horizon_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    slot_catalog_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10)
WHERE id = 10001;

SELECT ok(
    (SELECT count(DISTINCT anomaly_type) FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
     WHERE anomaly_type IN ('XMIN_HORIZON_STALL', 'CATALOG_XMIN_HORIZON_STALL')
       AND severity = 'high') = 2,
    'fixture F: both XMIN_HORIZON_STALL and CATALOG_XMIN_HORIZON_STALL fire at high (non-XOR)'
);

-- =============================================================================
-- 3. ATTRIBUTION FALLBACK — only `below_floor` and `collector_failed` reachable
-- (no_holders is unreachable per v0.6 — would imply NULL aggregate age, which
-- means the source can't be the dominant one by definition)
-- =============================================================================

-- Reset to clean fixture: data horizon high, activity below floor
UPDATE pgfr_record.snapshots
SET xmin_data_horizon_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    slot_catalog_xmin_age = NULL,
    activity_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    xmin_activity_collection_status = 'below_floor',
    xmin_slot_collection_status = 'no_holders',
    xmin_prepared_collection_status = 'no_holders',
    xmin_replication_collection_status = 'no_holders'
WHERE id = 10001;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
          AND recommendation ILIKE '%below_floor%'
    ),
    'attribution fallback: recommendation includes "below_floor" suffix when sidecar is below floor'
);

UPDATE pgfr_record.snapshots
SET xmin_activity_collection_status = 'collector_failed'
WHERE id = 10001;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
          AND recommendation ILIKE '%collector_failed%'
    ),
    'attribution fallback: recommendation includes "collector_failed" suffix when collector failed'
);

-- =============================================================================
-- 4. CROSS-SOURCE TIE-BREAKING — slot > activity priority (1 test)
-- Per §6.1: when activity and slot share the same age, slot wins by priority.
-- =============================================================================

UPDATE pgfr_record.snapshots
SET xmin_data_horizon_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    activity_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    slot_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    xmin_activity_collection_status = 'collected',
    xmin_slot_collection_status = 'collected'
WHERE id = 10001;

INSERT INTO pgfr_record.xmin_activity_holders
    (sample_ts, snapshot_id, pid, backend_xmin, backend_xmin_age, backend_type, state)
VALUES
    (0, 10001, 5000, '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10), 'client backend', 'idle in transaction')
ON CONFLICT (sample_ts, snapshot_id, pid) DO NOTHING;

INSERT INTO pgfr_record.xmin_slot_holders
    (sample_ts, snapshot_id, slot_name, slot_type, xmin, xmin_age)
VALUES
    (0, 10001, 'tie_test_slot', 'physical', '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10))
ON CONFLICT (sample_ts, snapshot_id, slot_name) DO NOTHING;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
          AND (recommendation ILIKE '%DROP REPLICATION SLOT%'
               OR recommendation ILIKE '%tie_test_slot%')
    ),
    'cross-source tie-break: slot wins over activity at equal ages (priority slot > activity)'
);

-- =============================================================================
-- 5. INTRA-SOURCE TIE-BREAKING — lower pid wins on identical age (1 test)
-- =============================================================================

INSERT INTO pgfr_record.xmin_activity_holders
    (sample_ts, snapshot_id, pid, backend_xmin, backend_xmin_age, backend_type, state)
VALUES
    (0, 10001, 1000, '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10), 'client backend', 'active'),
    (0, 10001, 2000, '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10), 'client backend', 'active')
ON CONFLICT (sample_ts, snapshot_id, pid) DO NOTHING;

-- Drop the slot fixture so activity becomes the dominant source
DELETE FROM pgfr_record.xmin_slot_holders WHERE snapshot_id = 10001;
UPDATE pgfr_record.snapshots SET slot_xmin_age = NULL WHERE id = 10001;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
          AND (recommendation ILIKE '%PID 1000%' OR recommendation ILIKE '%pid=1000%')
    ),
    'intra-source tie-break: pid 1000 wins over pid 2000 at identical age (lower pid first)'
);

-- =============================================================================
-- 6. AUTOVACUUM-WORKER RECOMMENDATION — points at pg_stat_progress_vacuum (1 test)
-- =============================================================================

DELETE FROM pgfr_record.xmin_activity_holders WHERE snapshot_id = 10001;

INSERT INTO pgfr_record.xmin_activity_holders
    (sample_ts, snapshot_id, pid, backend_xmin, backend_xmin_age, backend_type, query_preview)
VALUES
    (0, 10001, 7777, '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
     'autovacuum worker', 'autovacuum: VACUUM public.large_table')
ON CONFLICT (sample_ts, snapshot_id, pid) DO NOTHING;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
          AND recommendation ILIKE '%pg_stat_progress_vacuum%'
          AND recommendation NOT ILIKE '%pg_terminate_backend%'
    ),
    'autovacuum-worker recommendation: points at pg_stat_progress_vacuum, NOT pg_terminate_backend'
);

-- =============================================================================
-- 7. ACTIVE-VS-IDLE RECOMMENDATION WORDING (2 tests)
-- §6.1: active → pg_cancel_backend first; idle in transaction → pg_terminate_backend
-- =============================================================================

DELETE FROM pgfr_record.xmin_activity_holders WHERE snapshot_id = 10001;
INSERT INTO pgfr_record.xmin_activity_holders
    (sample_ts, snapshot_id, pid, backend_xmin, backend_xmin_age, backend_type, state, query_preview)
VALUES
    (0, 10001, 3001, '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
     'client backend', 'active', 'SELECT pg_sleep(99999)')
ON CONFLICT (sample_ts, snapshot_id, pid) DO NOTHING;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
          AND recommendation ILIKE '%pg_cancel_backend%'
    ),
    'active-state recommendation: pg_cancel_backend appears first'
);

DELETE FROM pgfr_record.xmin_activity_holders WHERE snapshot_id = 10001;
INSERT INTO pgfr_record.xmin_activity_holders
    (sample_ts, snapshot_id, pid, backend_xmin, backend_xmin_age, backend_type, state, query_preview)
VALUES
    (0, 10001, 3002, '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
     'client backend', 'idle in transaction', 'BEGIN')
ON CONFLICT (sample_ts, snapshot_id, pid) DO NOTHING;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
          AND recommendation ILIKE '%pg_terminate_backend%'
    ),
    'idle-in-transaction recommendation: pg_terminate_backend recommended directly'
);

-- =============================================================================
-- 8. HSF + PHYSICAL SLOT COMBINED CONTEXT (1 test)
-- When the standby identity in replication_snapshots matches a slot in
-- xmin_slot_holders, recommendation notes both sources describe the same standby.
-- =============================================================================

DELETE FROM pgfr_record.xmin_activity_holders WHERE snapshot_id = 10001;
DELETE FROM pgfr_record.xmin_slot_holders WHERE snapshot_id = 10001;

INSERT INTO pgfr_record.xmin_slot_holders
    (sample_ts, snapshot_id, slot_name, slot_type, xmin, xmin_age)
VALUES
    (0, 10001, 'replica_west', 'physical', '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10))
ON CONFLICT (sample_ts, snapshot_id, slot_name) DO NOTHING;

-- Also seed replication_snapshots to match the slot
INSERT INTO pgfr_record.replication_snapshots
    (snapshot_id, pid, application_name, slot_name, is_logical_walsender, backend_xmin, backend_xmin_age)
VALUES
    (10001, 4321, 'replica_west', 'replica_west', false, '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10))
ON CONFLICT (snapshot_id, pid) DO NOTHING;

UPDATE pgfr_record.snapshots
SET activity_xmin_age = NULL,
    xmin_activity_collection_status = 'no_holders',
    slot_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    replication_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    xmin_replication_collection_status = 'collected'
WHERE id = 10001;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
          AND recommendation ILIKE '%replica_west%'
          AND (recommendation ILIKE '%related%' OR recommendation ILIKE '%same standby%' OR recommendation ILIKE '%related physical slot%')
    ),
    'HSF + slot combined: when slot_name matches between sources, recommendation notes the combined context'
);

-- =============================================================================
-- 9. LOGICAL WALSENDER FILTERING (1 test)
-- replication_snapshots rows where is_logical_walsender = true must NOT
-- contribute to the `replication` source attribution; they're routed via slot.
-- =============================================================================

DELETE FROM pgfr_record.xmin_slot_holders WHERE snapshot_id = 10001;
DELETE FROM pgfr_record.replication_snapshots WHERE snapshot_id = 10001;

INSERT INTO pgfr_record.xmin_slot_holders
    (sample_ts, snapshot_id, slot_name, slot_type, xmin, xmin_age, catalog_xmin, catalog_xmin_age)
VALUES
    (0, 10001, 'logical_sub_1', 'logical', '999'::xid,
     (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
     '999'::xid,
     (current_setting('pgfr_test.fmax')::bigint * 6 / 10))
ON CONFLICT (sample_ts, snapshot_id, slot_name) DO NOTHING;

INSERT INTO pgfr_record.replication_snapshots
    (snapshot_id, pid, application_name, slot_name, is_logical_walsender, backend_xmin, backend_xmin_age)
VALUES
    (10001, 5555, 'logical_sub_1', 'logical_sub_1', true, '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10))
ON CONFLICT (snapshot_id, pid) DO NOTHING;

UPDATE pgfr_record.snapshots
SET slot_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    slot_catalog_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    replication_xmin_age = NULL,                 -- logical walsenders excluded from this aggregate
    xmin_replication_collection_status = 'no_holders'
WHERE id = 10001;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type IN ('XMIN_HORIZON_STALL', 'CATALOG_XMIN_HORIZON_STALL')
          AND recommendation NOT ILIKE '%hot_standby_feedback%'
    ),
    'logical walsender filtering: dominant attribution does NOT mention hot_standby_feedback (routed via slot)'
);

-- =============================================================================
-- 10. xmin_horizon_history() READER — row shape + partition pruning (3 tests)
-- =============================================================================

SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.xmin_horizon_history(
        now() - interval '1 hour', now()
    )$$,
    'xmin_horizon_history() runs without error'
);

-- Row shape: must include horizon_type column (v0.5+ disambiguates slot rows).
-- has_column doesn't apply to set-returning functions; query pg_proc directly.
SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgfr_analyze'
          AND p.proname = 'xmin_horizon_history'
          AND 'horizon_type' = ANY(p.proargnames)
    ),
    'horizon_type column is part of xmin_horizon_history return shape'
);

-- Partition pruning: the function must declare WHERE sample_ts BETWEEN ... AND ...
-- on each partitioned sidecar. Direct test on the SQL body — the planner-level
-- assertion (Append node child count under EXPLAIN) is brittle to partition
-- naming and cluster size, so we test the predicate is present at all.
SELECT ok(
    (SELECT pg_get_functiondef(p.oid)
     FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgfr_analyze'
       AND p.proname = 'xmin_horizon_history'
     LIMIT 1) LIKE '%sample_ts BETWEEN%',
    'xmin_horizon_history() pushes down sample_ts BETWEEN predicate for partition pruning'
);

-- =============================================================================
-- 11. current_xmin_horizon_holder() READER (2 tests)
-- =============================================================================

-- Cleanup all fixtures first to ensure healthy-cluster row count = 0
DELETE FROM pgfr_record.xmin_activity_holders WHERE snapshot_id = 10001;
DELETE FROM pgfr_record.xmin_slot_holders WHERE snapshot_id = 10001;
DELETE FROM pgfr_record.replication_snapshots WHERE snapshot_id = 10001;
UPDATE pgfr_record.snapshots
SET xmin_data_horizon_age = NULL,
    slot_catalog_xmin_age = NULL,
    activity_xmin_age = NULL,
    slot_xmin_age = NULL,
    replication_xmin_age = NULL,
    xmin_activity_collection_status = 'no_holders',
    xmin_slot_collection_status = 'no_holders',
    xmin_prepared_collection_status = 'no_holders',
    xmin_replication_collection_status = 'no_holders'
WHERE id = 10001;

SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.current_xmin_horizon_holder()) = 0,
    'current_xmin_horizon_holder(): zero rows on healthy cluster (no holder)'
);

-- Reseed an activity row and verify horizon_type='data'
INSERT INTO pgfr_record.xmin_activity_holders
    (sample_ts, snapshot_id, pid, backend_xmin, backend_xmin_age, backend_type, state)
VALUES
    (0, 10001, 6001, '999'::xid, (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
     'client backend', 'idle in transaction')
ON CONFLICT (sample_ts, snapshot_id, pid) DO NOTHING;

UPDATE pgfr_record.snapshots
SET activity_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    xmin_data_horizon_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
    xmin_activity_collection_status = 'collected'
WHERE id = 10001;

SELECT ok(
    (SELECT horizon_type FROM pgfr_analyze.current_xmin_horizon_holder() LIMIT 1) = 'data',
    'current_xmin_horizon_holder(): horizon_type = ''data'' for non-slot dominant source'
);

DELETE FROM pgfr_record.snapshots WHERE id = 10001;

SELECT * FROM finish();
ROLLBACK;
