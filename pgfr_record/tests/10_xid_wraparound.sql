-- =============================================================================
-- pgfr_record pgTAP Tests - XID and MultiXID Wraparound Metrics
-- =============================================================================
-- Tests: XID and MultiXID age columns exist and are populated with reasonable values
-- MultiXID monitoring per
--   https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-transaction-id-wraparound-risks
-- Test count: 26
-- =============================================================================

BEGIN;
SELECT plan(26);

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

-- =============================================================================
-- 6. V2 PARTITIONED TABLES (4 tests)
-- =============================================================================

-- Column existence on v2 tables (dual-write path populated via trigger)
SELECT has_column(
    'pgfr_record', 'snapshots_v2', 'datminmxid_age',
    'snapshots_v2 should have datminmxid_age column'
);

SELECT has_column(
    'pgfr_record', 'table_snapshots_v2', 'relminmxid_age',
    'table_snapshots_v2 should have relminmxid_age column'
);

-- Verify _snapshot_v2() dual-write populated datminmxid_age
SELECT ok(
    (SELECT datminmxid_age FROM pgfr_record.snapshots_v2 ORDER BY sample_ts DESC LIMIT 1) IS NOT NULL,
    'snapshots_v2.datminmxid_age should be populated by dual-write'
);

-- Verify sparse collector populates relminmxid_age. The collector only INSERTs
-- when metrics differ from last_state, so we must (a) seed last_state via an
-- initial snapshot() — which triggers the auto-rebuild path — and then
-- (b) poison every tracked metric to -1 (same trick the day-boundary branch
-- uses) so the "changed" predicate matches every top-N row on the next tick.
SELECT pgfr_record.snapshot();  -- seeds table_last_state via _rebuild path
UPDATE pgfr_record.table_last_state
SET seq_scan = -1, idx_scan = -1,
    n_tup_ins = -1, n_tup_upd = -1, n_tup_del = -1,
    n_live_tup = -1, n_dead_tup = -1, n_mod_since_analyze = -1;
SELECT pgfr_record.snapshot();  -- forces sparse insert with real values
SELECT ok(
    EXISTS(
        SELECT 1 FROM pgfr_record.table_snapshots_v2
        WHERE relminmxid_age IS NOT NULL
    ),
    'table_snapshots_v2.relminmxid_age should be populated by sparse collector'
);

-- =============================================================================
-- 7. RING BUFFER HEALTH EXPOSES MXID (2 tests)
-- =============================================================================

-- ring_buffer_health() returns an mxid_age column — lives_ok fails if the
-- column doesn't exist in the function signature
SELECT lives_ok(
    $$SELECT mxid_age FROM pgfr_record.ring_buffer_health() LIMIT 1$$,
    'ring_buffer_health() should expose an mxid_age output column'
);

-- Functional check: mxid_age is non-null for all ring buffer tables
SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pgfr_record.ring_buffer_health()
        WHERE mxid_age IS NULL
    ),
    'ring_buffer_health() should populate mxid_age for all 4 ring buffer tables'
);

-- =============================================================================
-- 8. POSITIVE ANOMALY TESTS (3 tests)
-- =============================================================================
-- Inject a synthetic snapshot with a high datminmxid_age to prove the
-- MXID_WRAPAROUND_RISK anomaly actually fires. Uses a savepoint so the
-- injection doesn't leak into other tests in this file.

-- Inside a single transaction now() is frozen, so all existing snapshots share
-- captured_at. anomaly_report picks "latest" via ORDER BY captured_at DESC LIMIT 1
-- which is non-deterministic on ties. Clear the 5-minute window and inject one
-- synthetic row so it's unambiguously the latest. The outer BEGIN/ROLLBACK
-- wrapping the whole test file discards all of this.
-- (Don't use SAVEPOINT+ROLLBACK TO here — pgTAP's internal test counter lives
-- in a table that savepoint rollback reverts, breaking finish()'s plan count.)
DELETE FROM pgfr_record.table_snapshots
WHERE snapshot_id IN (
    SELECT id FROM pgfr_record.snapshots
    WHERE captured_at BETWEEN now() - interval '5 minutes' AND now()
);
DELETE FROM pgfr_record.snapshots
WHERE captured_at BETWEEN now() - interval '5 minutes' AND now();

-- Insert a synthetic snapshot with mxid age well above the 80% threshold of
-- autovacuum_multixact_freeze_max_age (default 400M → critical at 320M). 350M
-- crosses the critical line unambiguously.
WITH ins AS (
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version, datfrozenxid_age, datminmxid_age)
    VALUES (now(), current_setting('server_version_num')::integer / 10000, 100, 350000000)
    RETURNING id
)
SELECT id AS synth_snapshot_id FROM ins \gset

-- T24: MXID_WRAPAROUND_RISK fires when datminmxid_age exceeds warning threshold
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '5 minutes', now())
        WHERE anomaly_type = 'MXID_WRAPAROUND_RISK'
    ),
    'MXID_WRAPAROUND_RISK should fire when datminmxid_age > 50% of autovacuum_multixact_freeze_max_age'
);

-- T25: severity is 'critical' when datminmxid_age exceeds 80% threshold
SELECT is(
    (SELECT severity FROM pgfr_analyze.anomaly_report(now() - interval '5 minutes', now())
     WHERE anomaly_type = 'MXID_WRAPAROUND_RISK' LIMIT 1),
    'critical',
    'MXID_WRAPAROUND_RISK severity should be critical at 350M (>80% of 400M default)'
);

-- T26: table-level anomaly fires when we inject high relminmxid_age for a real table
INSERT INTO pgfr_record.table_snapshots (snapshot_id, relid, relminmxid_age, relfrozenxid_age)
VALUES (
    :synth_snapshot_id,
    'pgfr_record.snapshots'::regclass::oid,
    350000000,
    100
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_analyze.anomaly_report(now() - interval '5 minutes', now())
        WHERE anomaly_type = 'TABLE_MXID_WRAPAROUND_RISK'
    ),
    'TABLE_MXID_WRAPAROUND_RISK should fire when relminmxid_age exceeds per-table threshold'
);

SELECT * FROM finish();
ROLLBACK;
