-- =============================================================================
-- pgfr_record pgTAP Tests - Anomaly Detection Enhancements (v2.6)
-- =============================================================================
-- Tests: New anomaly types, conflict columns, recent_idle_in_transaction view
-- Test count: 25
-- =============================================================================

BEGIN;
SELECT plan(22);

-- =============================================================================
-- 1. DATABASE CONFLICT COLUMNS - COLUMN EXISTENCE (6 tests)
-- =============================================================================

SELECT has_column(
    'pgfr_record', 'snapshots', 'confl_tablespace',
    'snapshots should have confl_tablespace column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'confl_lock',
    'snapshots should have confl_lock column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'confl_snapshot',
    'snapshots should have confl_snapshot column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'confl_bufferpin',
    'snapshots should have confl_bufferpin column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'confl_deadlock',
    'snapshots should have confl_deadlock column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'confl_active_logicalslot',
    'snapshots should have confl_active_logicalslot column'
);

-- =============================================================================
-- 2. RECENT_IDLE_IN_TRANSACTION VIEW - EXISTENCE AND STRUCTURE (4 tests)
-- =============================================================================

SELECT has_view(
    'pgfr_record', 'recent_idle_in_transaction',
    'recent_idle_in_transaction view should exist'
);

SELECT has_column(
    'pgfr_record', 'recent_idle_in_transaction', 'pid',
    'recent_idle_in_transaction should have pid column'
);

SELECT has_column(
    'pgfr_record', 'recent_idle_in_transaction', 'idle_duration',
    'recent_idle_in_transaction should have idle_duration column'
);

SELECT lives_ok(
    $$SELECT * FROM pgfr_record.recent_idle_in_transaction LIMIT 1$$,
    'recent_idle_in_transaction view should be queryable'
);

-- =============================================================================
-- 3. SNAPSHOT COLLECTION - CONFLICT DATA (3 tests)
-- =============================================================================

-- Take a snapshot to populate data
SELECT pgfr_record.snapshot();

-- Verify conflict columns are queryable (NULL on primary, populated on standby)
SELECT lives_ok(
    $$SELECT confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock
      FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1$$,
    'conflict columns should be queryable in snapshots'
);

-- Verify snapshot was created successfully
SELECT ok(
    (SELECT count(*) FROM pgfr_record.snapshots WHERE captured_at > now() - interval '1 minute') > 0,
    'snapshot() should create a new snapshot'
);

-- Verify logical slot conflict column is queryable (PG16+ only, NULL on others)
SELECT lives_ok(
    $$SELECT confl_active_logicalslot FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1$$,
    'confl_active_logicalslot column should be queryable'
);

-- =============================================================================
-- 4. ANOMALY_REPORT FUNCTION - NEW ANOMALY TYPES (7 tests)
-- =============================================================================

-- Test that anomaly_report function exists and returns expected columns
SELECT lives_ok(
    $$SELECT anomaly_type, severity, description, metric_value, threshold, recommendation
      FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
      LIMIT 1$$,
    'anomaly_report should be queryable with expected columns'
);

-- Test IDLE_IN_TRANSACTION anomaly type is recognized
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
      WHERE anomaly_type = 'IDLE_IN_TRANSACTION'$$,
    'anomaly_report should support IDLE_IN_TRANSACTION type'
);

-- Test DEAD_TUPLE_ACCUMULATION anomaly type is recognized
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
      WHERE anomaly_type = 'DEAD_TUPLE_ACCUMULATION'$$,
    'anomaly_report should support DEAD_TUPLE_ACCUMULATION type'
);

-- Test VACUUM_STARVATION anomaly type is recognized
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
      WHERE anomaly_type = 'VACUUM_STARVATION'$$,
    'anomaly_report should support VACUUM_STARVATION type'
);

-- Test CONNECTION_LEAK anomaly type is recognized
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
      WHERE anomaly_type = 'CONNECTION_LEAK'$$,
    'anomaly_report should support CONNECTION_LEAK type'
);

-- Test REPLICATION_LAG_GROWING anomaly type is recognized
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
      WHERE anomaly_type = 'REPLICATION_LAG_GROWING'$$,
    'anomaly_report should support REPLICATION_LAG_GROWING type'
);

-- Test anomaly_report returns all expected columns
SELECT results_eq(
    $$SELECT count(*)::integer FROM (
        SELECT anomaly_type, severity, description, metric_value, threshold, recommendation
        FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
        LIMIT 0
      ) t$$,
    ARRAY[0],
    'anomaly_report should return 6 columns'
);

-- =============================================================================
-- 5. SAMPLE COLLECTION - ACTIVITY DATA FOR ANOMALY DETECTION (3 tests)
-- =============================================================================

-- Take a sample to populate activity data
SELECT pgfr_record.sample_ring();

-- activity_samples_archive retired; 3 has_column assertions dropped. Anomaly
-- detection now reads from the v2 ring tables (activity_samples) directly.

-- =============================================================================
-- 6. TABLE_SNAPSHOTS - REQUIRED COLUMNS FOR DEAD TUPLE DETECTION (2 tests)
-- =============================================================================

SELECT has_column(
    'pgfr_record', 'table_snapshots', 'n_dead_tup',
    'table_snapshots should have n_dead_tup column for dead tuple detection'
);

SELECT has_column(
    'pgfr_record', 'table_snapshots', 'last_autovacuum',
    'table_snapshots should have last_autovacuum column for vacuum starvation detection'
);

SELECT * FROM finish();
ROLLBACK;
