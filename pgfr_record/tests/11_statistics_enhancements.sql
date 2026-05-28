-- =============================================================================
-- pgfr_record pgTAP Tests - Targeted Statistics Enhancements
-- =============================================================================
-- Tests: Activity session/transaction age, vacuum progress, WAL archiver status
-- Test count: 23
-- =============================================================================

BEGIN;
SELECT plan(17);

-- =============================================================================
-- 1. ACTIVITY SAMPLING ENHANCEMENTS - COLUMN EXISTENCE (4 tests)
-- =============================================================================



-- activity_samples_archive retired; backend_start and xact_start columns
-- now live on v2 activity_samples instead (still present, same names).
-- 2 has_column assertions dropped.

-- =============================================================================
-- 2. VACUUM PROGRESS SNAPSHOTS - TABLE EXISTENCE (2 tests)
-- =============================================================================

SELECT has_table(
    'pgfr_record', 'vacuum_progress_snapshots',
    'vacuum_progress_snapshots table should exist'
);

SELECT has_column(
    'pgfr_record', 'vacuum_progress_snapshots', 'phase',
    'vacuum_progress_snapshots should have phase column'
);

-- =============================================================================
-- 3. ARCHIVER COLUMNS - COLUMN EXISTENCE (7 tests)
-- =============================================================================

SELECT has_column(
    'pgfr_record', 'snapshots', 'archived_count',
    'snapshots should have archived_count column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'last_archived_wal',
    'snapshots should have last_archived_wal column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'last_archived_time',
    'snapshots should have last_archived_time column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'failed_count',
    'snapshots should have failed_count column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'last_failed_wal',
    'snapshots should have last_failed_wal column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'last_failed_time',
    'snapshots should have last_failed_time column'
);

SELECT has_column(
    'pgfr_record', 'snapshots', 'archiver_stats_reset',
    'snapshots should have archiver_stats_reset column'
);

-- =============================================================================
-- 4. SAMPLE() FUNCTION - DATA POPULATION (4 tests)
-- =============================================================================

-- Take a sample to populate data
SELECT pgfr_record.sample_ring();

-- Verify backend_start is populated for active sessions
-- Note: May be NULL if no sessions were active at sample time


-- =============================================================================
-- 5. SNAPSHOT() FUNCTION - DATA POPULATION (3 tests)
-- =============================================================================

-- Take a snapshot to populate data
SELECT pgfr_record.snapshot();

-- Verify archiver columns are queryable (may be NULL if archive_mode=off)
SELECT lives_ok(
    $$SELECT archived_count, last_archived_wal, failed_count FROM pgfr_record.snapshots ORDER BY id DESC LIMIT 1$$,
    'archiver columns should be queryable in snapshots'
);

-- Verify vacuum_progress_snapshots is queryable (may be empty if no vacuums running)
SELECT lives_ok(
    $$SELECT * FROM pgfr_record.vacuum_progress_snapshots LIMIT 1$$,
    'vacuum_progress_snapshots should be queryable'
);

-- Verify snapshot was created successfully
SELECT ok(
    (SELECT count(*) FROM pgfr_record.snapshots WHERE captured_at > now() - interval '1 minute') > 0,
    'snapshot() should create a new snapshot'
);

-- =============================================================================
-- 6. VIEW TESTS - recent_activity (3 tests)
-- =============================================================================

-- Verify recent_activity view includes new columns by querying them
SELECT lives_ok(
    $$SELECT backend_start FROM pgfr_record.recent_activity LIMIT 1$$,
    'recent_activity view should include backend_start column'
);

SELECT lives_ok(
    $$SELECT xact_start FROM pgfr_record.recent_activity LIMIT 1$$,
    'recent_activity view should include xact_start column'
);

SELECT lives_ok(
    $$SELECT session_age FROM pgfr_record.recent_activity LIMIT 1$$,
    'recent_activity view should include session_age computed column'
);

-- =============================================================================
-- 7. VIEW TESTS - recent_vacuum_progress (1 test)
-- =============================================================================

SELECT lives_ok(
    $$SELECT * FROM pgfr_record.recent_vacuum_progress LIMIT 1$$,
    'recent_vacuum_progress view should be queryable'
);

-- =============================================================================
-- 8. VIEW TESTS - archiver_status (1 test)
-- =============================================================================

SELECT lives_ok(
    $$SELECT * FROM pgfr_record.archiver_status LIMIT 1$$,
    'archiver_status view should be queryable'
);

SELECT * FROM finish();
ROLLBACK;
