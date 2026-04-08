-- =============================================================================
-- pgfr_record pgTAP Tests - OID Exhaustion Metrics
-- =============================================================================
-- Tests: OID exhaustion columns exist and are populated with reasonable values
-- Test count: 10
-- =============================================================================

BEGIN;
SELECT plan(10);

-- =============================================================================
-- 1. COLUMN EXISTENCE (2 tests)
-- =============================================================================

SELECT has_column(
    'pgfr_record', 'snapshots', 'max_catalog_oid',
    'snapshots table should have max_catalog_oid column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'large_object_count',
    'snapshots table should have large_object_count column'
);

-- =============================================================================
-- 2. DATA POPULATION (4 tests)
-- =============================================================================

-- Take a snapshot to populate data
SELECT pgfr_record.snapshot();

-- Verify max_catalog_oid is populated
SELECT ok(
    (SELECT max_catalog_oid FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) IS NOT NULL,
    'max_catalog_oid should be populated after snapshot()'
);

-- Verify large_object_count is populated
SELECT ok(
    (SELECT large_object_count FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) IS NOT NULL,
    'large_object_count should be populated after snapshot()'
);

-- Verify max_catalog_oid is a reasonable value (> 0, < 4.3 billion)
SELECT ok(
    (SELECT max_catalog_oid FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) > 0,
    'max_catalog_oid should be greater than 0'
);

SELECT ok(
    (SELECT max_catalog_oid FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) < 4294967295,
    'max_catalog_oid should be less than max OID (4.3 billion)'
);

-- =============================================================================
-- 3. VALUE REASONABLENESS (2 tests)
-- =============================================================================

-- Verify large_object_count is non-negative
SELECT ok(
    (SELECT large_object_count FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) >= 0,
    'large_object_count should be non-negative'
);

-- Verify max_catalog_oid represents actual pg_class OIDs
SELECT ok(
    (SELECT max_catalog_oid FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1)
        >= (SELECT max(oid)::bigint FROM pg_class) - 1000,
    'max_catalog_oid should be close to actual max pg_class OID'
);

-- =============================================================================
-- 4. ANOMALY REPORT INTEGRATION (2 tests)
-- =============================================================================

-- Verify anomaly_report() runs without error when checking OID exhaustion
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())$$,
    'anomaly_report() should run without error with OID exhaustion checks'
);

-- In a fresh test database, OID usage should be low, so no OID exhaustion anomalies expected
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
        WHERE anomaly_type = 'OID_EXHAUSTION_RISK'
    ),
    'Fresh database should not trigger OID exhaustion anomalies'
);

SELECT * FROM finish();
ROLLBACK;
