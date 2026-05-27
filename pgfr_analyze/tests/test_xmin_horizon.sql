-- =============================================================================
-- pgfr_analyze pgTAP Tests — xmin Horizon Anomaly Reporting + Readers
-- =============================================================================
-- Synthetic-fixture tests for XMIN_HORIZON_STALL / CATALOG_XMIN_HORIZON_STALL
-- anomalies and the two reader functions. Live-fixture tests live in
-- pgfr_record/tests/16_xmin_horizon.sql.
-- =============================================================================

BEGIN;
SELECT plan(10);

-- Read autovacuum_freeze_max_age once for fixture math.
SELECT set_config('pgfr_test.fmax', current_setting('autovacuum_freeze_max_age'), false);

-- 1. Fresh DB / no fixtures: anomaly_report runs, no xmin anomalies fire.
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())$$,
    'anomaly_report() runs without error');

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
        WHERE anomaly_type IN ('XMIN_HORIZON_STALL', 'CATALOG_XMIN_HORIZON_STALL')
    ),
    'fresh DB fires no XMIN_HORIZON_STALL or CATALOG_XMIN_HORIZON_STALL');

-- Synthetic fixture: insert a snapshot we can mutate.
INSERT INTO pgfr_record.snapshots (id, captured_at, pg_version, datfrozenxid_age)
VALUES (10001, now() - interval '5 minutes', current_setting('server_version_num')::int / 10000, 100)
ON CONFLICT (id) DO UPDATE SET captured_at = EXCLUDED.captured_at;

-- 2. XMIN_HORIZON_STALL: high at 60% of autovacuum_freeze_max_age.
UPDATE pgfr_record.snapshots
   SET xmin_data_horizon_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
       xmin_any_horizon_age  = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
       xmin_horizon_detail = jsonb_build_object(
           'source', 'activity', 'age', (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
           'holder', jsonb_build_object(
               'pid', 48291, 'usename', 'app_rw', 'datname', 'orders',
               'application_name', 'orders_worker', 'backend_type', 'client backend',
               'state', 'idle in transaction', 'xact_age_seconds', 14400,
               'query_preview', 'BEGIN'))
 WHERE id = 10001;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL' AND severity = 'high'
          AND recommendation ILIKE '%pg_terminate_backend%'
    ),
    'XMIN_HORIZON_STALL fires at high with idle-in-txn → pg_terminate_backend recommendation');

-- 3. XMIN_HORIZON_STALL: critical at 90%.
UPDATE pgfr_record.snapshots
   SET xmin_data_horizon_age = (current_setting('pgfr_test.fmax')::bigint * 9 / 10),
       xmin_any_horizon_age  = (current_setting('pgfr_test.fmax')::bigint * 9 / 10)
 WHERE id = 10001;
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL' AND severity = 'critical'
    ),
    'XMIN_HORIZON_STALL escalates to critical at 90% of autovacuum_freeze_max_age');

-- 4. Autovacuum-worker recommendation routes to pg_stat_progress_vacuum.
UPDATE pgfr_record.snapshots
   SET xmin_horizon_detail = jsonb_build_object(
           'source', 'activity', 'age', xmin_data_horizon_age,
           'holder', jsonb_build_object(
               'pid', 7777, 'backend_type', 'autovacuum worker',
               'query_preview', 'autovacuum: VACUUM public.large_table'))
 WHERE id = 10001;
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
          AND recommendation ILIKE '%pg_stat_progress_vacuum%'
          AND recommendation NOT ILIKE '%pg_terminate_backend%'
    ),
    'autovacuum-worker dominant → recommendation routes to pg_stat_progress_vacuum');

-- 5. CATALOG_XMIN_HORIZON_STALL: independent (data NULL, catalog elevated).
UPDATE pgfr_record.snapshots
   SET xmin_data_horizon_age = NULL,
       slot_catalog_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
       xmin_any_horizon_age  = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
       xmin_horizon_detail   = jsonb_build_object(
           'source', 'slot_catalog',
           'age', (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
           'holder', jsonb_build_object('slot_name', 'logical_sub_1', 'slot_type', 'logical'))
 WHERE id = 10001;
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'CATALOG_XMIN_HORIZON_STALL' AND severity = 'high'
    )
    AND NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
        WHERE anomaly_type = 'XMIN_HORIZON_STALL'
    ),
    'CATALOG_XMIN_HORIZON_STALL fires independently when data horizon is NULL');

-- 6. Both fire together (non-XOR) when both horizons are elevated.
UPDATE pgfr_record.snapshots
   SET xmin_data_horizon_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
       slot_catalog_xmin_age = (current_setting('pgfr_test.fmax')::bigint * 6 / 10),
       xmin_any_horizon_age  = (current_setting('pgfr_test.fmax')::bigint * 6 / 10)
 WHERE id = 10001;
SELECT ok(
    (SELECT count(DISTINCT anomaly_type) FROM pgfr_analyze.anomaly_report(now() - interval '10 minutes', now())
       WHERE anomaly_type IN ('XMIN_HORIZON_STALL', 'CATALOG_XMIN_HORIZON_STALL')) = 2,
    'data and catalog anomalies fire together (non-XOR) when both horizons are elevated');

-- 7. Reader: xmin_horizon_history returns the row with parsed source/holder.
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.xmin_horizon_history(now() - interval '10 minutes', now())
        WHERE xmin_data_horizon_age IS NOT NULL
          AND source IS NOT NULL
          AND holder IS NOT NULL
    ),
    'xmin_horizon_history() returns rows with parsed source + holder JSONB');

-- 8. Reader: current_xmin_horizon_holder returns one row when fixture is present.
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.current_xmin_horizon_holder()) = 1,
    'current_xmin_horizon_holder() returns one row when a holder exists');

-- 9. Reader: current_xmin_horizon_holder returns zero rows on healthy cluster.
DELETE FROM pgfr_record.snapshots WHERE id = 10001;
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.current_xmin_horizon_holder()) = 0,
    'current_xmin_horizon_holder() returns zero rows on healthy cluster (no detail)');

SELECT * FROM finish();
ROLLBACK;
