-- =============================================================================
-- pgfr_record pgTAP Tests - XID and MultiXID Wraparound Metrics
-- =============================================================================
-- Tests: XID and MultiXID age columns exist and are populated with reasonable values
-- MultiXID monitoring per postgres-howto #0044
-- Test count: 17
-- =============================================================================

BEGIN;
SELECT plan(17);

-- =============================================================================
-- 1. COLUMN EXISTENCE (4 tests)
-- =============================================================================

SELECT has_column(
    'pgfr_record', 'snapshots', 'datfrozenxid_age',
    'snapshots table should have datfrozenxid_age column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'datminmxid_age',
    'snapshots table should have datminmxid_age column (MultiXID)'
);

SELECT has_column(
    'pgfr_record', 'table_snapshots', 'relfrozenxid_age',
    'table_snapshots table should have relfrozenxid_age column'
);

SELECT has_column(
    'pgfr_record', 'table_snapshots', 'relminmxid_age',
    'table_snapshots table should have relminmxid_age column (MultiXID)'
);

-- =============================================================================
-- 2. DATA POPULATION (6 tests)
-- =============================================================================

-- Take a snapshot to populate data
SELECT pgfr_record.snapshot();

-- Verify datfrozenxid_age is populated
SELECT ok(
    (SELECT datfrozenxid_age FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) IS NOT NULL,
    'datfrozenxid_age should be populated after snapshot()'
);

-- Verify datfrozenxid_age is a reasonable value (> 0, < 2 billion)
SELECT ok(
    (SELECT datfrozenxid_age FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) > 0,
    'datfrozenxid_age should be greater than 0'
);

SELECT ok(
    (SELECT datfrozenxid_age FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) < 2000000000,
    'datfrozenxid_age should be less than 2 billion'
);

-- Verify datminmxid_age is populated (MultiXID age at cluster/db level)
SELECT ok(
    (SELECT datminmxid_age FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) IS NOT NULL,
    'datminmxid_age should be populated after snapshot()'
);

-- Verify datminmxid_age is non-negative and under the 2^31 ceiling
SELECT ok(
    (SELECT datminmxid_age FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) >= 0,
    'datminmxid_age should be non-negative'
);

SELECT ok(
    (SELECT datminmxid_age FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1) < 2147483647,
    'datminmxid_age should be below the 2^31 MultiXID ceiling'
);

-- =============================================================================
-- 3. PER-TABLE POPULATION (2 tests)
-- =============================================================================

-- Verify relfrozenxid_age is populated for at least some tables
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.table_snapshots ts
        WHERE ts.snapshot_id = (SELECT max(id) FROM pgfr_record.snapshots)
          AND ts.relfrozenxid_age IS NOT NULL
    ),
    'relfrozenxid_age should be populated for tables after snapshot()'
);

-- relminmxid_age may be 0 on a fresh cluster with no row-level locks; the
-- contract is simply that the column exists and is non-negative where present.
-- Some rows may be NULL (via nullif() filter on the 2^31 sentinel).
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.table_snapshots ts
        WHERE ts.snapshot_id = (SELECT max(id) FROM pgfr_record.snapshots)
          AND ts.relminmxid_age IS NOT NULL
          AND ts.relminmxid_age < 0
    ),
    'relminmxid_age values should be non-negative where populated'
);

-- =============================================================================
-- 4. VALUE REASONABLENESS (3 tests)
-- =============================================================================

-- Verify relfrozenxid_age values are reasonable where populated (>= 0, as newly created tables can have age 0)
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.table_snapshots ts
        WHERE ts.snapshot_id = (SELECT max(id) FROM pgfr_record.snapshots)
          AND ts.relfrozenxid_age IS NOT NULL
          AND ts.relfrozenxid_age < 0
    ),
    'relfrozenxid_age values should be non-negative'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.table_snapshots ts
        WHERE ts.snapshot_id = (SELECT max(id) FROM pgfr_record.snapshots)
          AND ts.relfrozenxid_age IS NOT NULL
          AND ts.relfrozenxid_age >= 2000000000
    ),
    'relfrozenxid_age values should be less than 2 billion'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.table_snapshots ts
        WHERE ts.snapshot_id = (SELECT max(id) FROM pgfr_record.snapshots)
          AND ts.relminmxid_age IS NOT NULL
          AND ts.relminmxid_age >= 2147483647
    ),
    'relminmxid_age values should be below 2^31 (nullif sentinel filter)'
);

-- =============================================================================
-- 5. ANOMALY REPORT INTEGRATION (2 tests)
-- =============================================================================

-- Verify anomaly_report() runs without error when checking XID and MXID ages
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())$$,
    'anomaly_report() should run without error with XID/MXID age checks'
);

-- In a fresh test database, XID and MXID ages should be low, so no wraparound anomalies expected
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '1 hour', now())
        WHERE anomaly_type IN (
            'XID_WRAPAROUND_RISK', 'TABLE_XID_WRAPAROUND_RISK',
            'MXID_WRAPAROUND_RISK', 'TABLE_MXID_WRAPAROUND_RISK'
        )
    ),
    'Fresh database should not trigger XID or MXID wraparound anomalies'
);

SELECT * FROM finish();
ROLLBACK;
