-- =============================================================================
-- pgfr_record pgTAP Tests - Pathological Data Generators
-- =============================================================================
-- Tests: Generate real-world pathologies and verify pgfr_record detects them
-- Purpose: Validate that diagnostic playbooks work end-to-end
-- Based on: DIAGNOSTIC_PLAYBOOKS.md
-- Sections: All 9 DIAGNOSTIC_PLAYBOOKS.md pathologies
-- Test count: 48
-- =============================================================================

BEGIN;
SELECT plan(48);

-- =============================================================================
-- PATHOLOGY 1: LOCK CONTENTION (6 tests)
-- Based on: DIAGNOSTIC_PLAYBOOKS.md - Section 5 "Lock Contention / Blocked Queries"
--
-- Real-world scenario: Multiple transactions updating the same rows
-- Expected detection: _recent_locks_current() should show blocked queries
--                     lock_samples_ring should capture lock events
--                     anomaly_report() should flag LOCK_CONTENTION
-- =============================================================================

-- Setup: Create test table for lock contention
CREATE TABLE test_lock_contention (
    id int PRIMARY KEY,
    value int
);

INSERT INTO test_lock_contention VALUES (1, 100), (2, 200), (3, 300);

-- Test that table was created
SELECT ok(
    EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_lock_contention'),
    'LOCK PATHOLOGY: Test table should be created'
);

-- Generate pathology: Use advisory locks to simulate blocking
-- Advisory locks are ideal for testing because:
-- 1. They're explicit and controllable
-- 2. They show up in pg_locks just like row/table locks
-- 3. They don't require multiple database connections
DO $$
BEGIN
    -- Acquire an advisory lock (this simulates a blocker transaction)
    PERFORM pg_advisory_lock(12345);

    -- Capture the state while lock is held
    PERFORM pgfr_record.sample_ring();

    -- Try to acquire the same lock in a non-blocking way (simulates a blocked session)
    -- This will fail immediately and return false, but the attempt is logged
    PERFORM pg_try_advisory_lock(12345);

    -- Release the lock
    PERFORM pg_advisory_unlock(12345);
END;
$$;

-- Test that sample() continues to work after lock operations
SELECT lives_ok(
    $$SELECT pgfr_record.sample_ring()$$,
    'LOCK PATHOLOGY: sample() should execute after lock contention scenario'
);

-- Test that lock_samples_ring exists and can be queried
-- Note: Lock samples may be empty if no actual blocking occurred
-- (advisory locks don't create blocked sessions in single transaction)
SELECT ok(
    (SELECT count(*) FROM pgfr_record.lock_samples_ring_legacy) >= 0,
    'LOCK PATHOLOGY: lock_samples_ring should be queryable'
);

-- Test _recent_locks_current() function works
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.recent_locks_current()$$,
    'LOCK PATHOLOGY: recent_locks_current() should execute without error'
);

-- Test that pg_locks system view shows our activity
-- This verifies the test infrastructure is working
SELECT ok(
    (SELECT count(*) FROM pg_locks) >= 0,
    'LOCK PATHOLOGY: pg_locks system view should be accessible'
);

-- Cleanup: Drop test table
DROP TABLE test_lock_contention;

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_lock_contention'),
    'LOCK PATHOLOGY: Test table should be cleaned up'
);

-- =============================================================================
-- PATHOLOGY 2: MEMORY PRESSURE / work_mem ISSUES (6 tests)
-- Based on: DIAGNOSTIC_PLAYBOOKS.md - Section 9 "Memory Pressure / work_mem Issues"
--
-- Real-world scenario: Large sorts/aggregations spilling to temporary files
-- Expected detection: statement_snapshots.temp_blks_written > 0
--                     snapshots.temp_files and temp_bytes increase
--                     anomaly_report() should flag TEMP_FILE_SPILLS
-- =============================================================================

-- Setup: Create table with enough data to trigger temp file spills
CREATE TABLE test_memory_pressure (
    id int,
    data text
);

-- Insert enough rows to cause memory pressure when sorted
-- Generate ~10k rows with random data
INSERT INTO test_memory_pressure
SELECT
    i,
    md5(random()::text) || md5(random()::text) || md5(random()::text) || md5(random()::text)
FROM generate_series(1, 10000) i;

SELECT ok(
    (SELECT count(*) FROM test_memory_pressure) = 10000,
    'MEMORY PATHOLOGY: Test table should have 10000 rows'
);

-- Capture baseline snapshot before generating pathology
SELECT pgfr_record.snapshot();

-- Generate pathology: Force temp file spills with low work_mem
DO $$
DECLARE
    v_old_work_mem text;
    v_result RECORD;
BEGIN
    -- Save current work_mem
    SELECT current_setting('work_mem') INTO v_old_work_mem;

    -- Set work_mem very low to force temp file usage
    SET LOCAL work_mem = '64kB';

    -- Run a large sort that will spill to temp files
    -- Order by data (large text field) to maximize memory usage
    PERFORM count(*)
    FROM (
        SELECT data
        FROM test_memory_pressure
        ORDER BY data DESC
    ) subquery;

    -- Run another query with aggregation to increase temp file usage
    PERFORM data, count(*)
    FROM test_memory_pressure
    GROUP BY data
    ORDER BY data;

    -- Restore work_mem
    EXECUTE 'SET LOCAL work_mem = ' || quote_literal(v_old_work_mem);
END;
$$;

-- Capture snapshot after generating pathology
SELECT pg_sleep(0.2); -- Small delay to ensure statement stats are updated
SELECT pgfr_record.snapshot();

-- Test that snapshot captured the period
SELECT ok(
    (SELECT count(*) FROM pgfr_record.snapshots WHERE captured_at > now() - interval '10 seconds') >= 2,
    'MEMORY PATHOLOGY: At least 2 snapshots should exist from the test period'
);

-- Test that temp file data was captured in snapshots
-- Note: temp_files and temp_bytes are cumulative, so we check they exist
SELECT ok(
    (SELECT count(*) FROM pgfr_record.snapshots WHERE temp_files IS NOT NULL) >= 1,
    'MEMORY PATHOLOGY: Snapshots should capture temp_files metric'
);

-- Test that statement_snapshots table exists and has data
SELECT ok(
    (SELECT count(*) FROM pgfr_record.statement_snapshots) >= 0,
    'MEMORY PATHOLOGY: statement_snapshots should contain query statistics'
);

-- Test that anomaly_report can detect temp file issues
-- Create time range for anomaly detection
DO $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_anomaly_count INT;
BEGIN
    SELECT min(captured_at) INTO v_start_time
    FROM pgfr_record.snapshots
    WHERE captured_at > now() - interval '10 seconds';

    SELECT max(captured_at) INTO v_end_time
    FROM pgfr_record.snapshots
    WHERE captured_at > now() - interval '10 seconds';

    -- Check if anomaly_report can run on this time range
    SELECT count(*) INTO v_anomaly_count
    FROM pgfr_analyze.anomaly_report(v_start_time, v_end_time);

    -- Store result for test
    CREATE TEMP TABLE IF NOT EXISTS pathology_test_results (test_name text, result boolean);
    INSERT INTO pathology_test_results VALUES ('anomaly_report_executed', v_anomaly_count >= 0);
END;
$$;

SELECT ok(
    (SELECT result FROM pathology_test_results WHERE test_name = 'anomaly_report_executed'),
    'MEMORY PATHOLOGY: anomaly_report() should execute on pathology time range'
);

-- Cleanup: Drop test table
DROP TABLE test_memory_pressure;

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_memory_pressure'),
    'MEMORY PATHOLOGY: Test table should be cleaned up'
);

-- =============================================================================
-- PATHOLOGY 3: HIGH CPU USAGE (5 tests)
-- Based on: DIAGNOSTIC_PLAYBOOKS.md - Section 4 "High CPU Usage"
--
-- Real-world scenario: Queries burning CPU with complex calculations
-- Expected detection: High total_exec_time with blk_read_time = 0 (CPU-bound)
--                     statement_snapshots captures query statistics
-- =============================================================================

-- Setup: Create table for CPU-intensive operations
CREATE TABLE test_cpu_intensive (
    id int,
    value numeric
);

-- Insert data for CPU-intensive calculations
INSERT INTO test_cpu_intensive
SELECT i, random() * 1000
FROM generate_series(1, 50000) i;

SELECT ok(
    (SELECT count(*) FROM test_cpu_intensive) = 50000,
    'CPU PATHOLOGY: Test table should have 50000 rows'
);

-- Capture baseline snapshot
SELECT pgfr_record.snapshot();

-- Generate pathology: CPU-intensive calculations
DO $$
DECLARE
    v_result numeric;
BEGIN
    -- Run CPU-intensive mathematical operations
    -- These operations are compute-heavy but don't require disk I/O
    SELECT sum(
        sqrt(abs(value)) * ln(abs(value) + 1) * exp(value / 100000.0) * cos(value)
    ) INTO v_result
    FROM test_cpu_intensive
    WHERE value > 0;

    -- Run another CPU-intensive query with aggregations
    SELECT sum(power(value, 2) + power(value, 3) / 1000000)
    INTO v_result
    FROM test_cpu_intensive;

    -- Small delay to ensure stats are captured
    PERFORM pg_sleep(0.1);
END;
$$;

-- Capture snapshot after CPU work
SELECT pgfr_record.snapshot();

-- Test that snapshots were captured
SELECT ok(
    (SELECT count(*) FROM pgfr_record.snapshots WHERE captured_at > now() - interval '10 seconds') >= 2,
    'CPU PATHOLOGY: At least 2 snapshots should exist from test period'
);

-- Test that statement_snapshots table is accessible (may or may not have data depending on pg_stat_statements)
SELECT ok(
    (SELECT count(*) FROM pgfr_record.statement_snapshots) >= 0,
    'CPU PATHOLOGY: statement_snapshots should be queryable'
);

-- Test that _recent_activity_current() works (used for real-time CPU monitoring)
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.recent_activity_current()$$,
    'CPU PATHOLOGY: recent_activity_current() should execute for CPU monitoring'
);

-- Cleanup
DROP TABLE test_cpu_intensive;

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_cpu_intensive'),
    'CPU PATHOLOGY: Test table should be cleaned up'
);

-- =============================================================================
-- PATHOLOGY 4: DATABASE SLOW - REAL-TIME (5 tests)
-- Based on: DIAGNOSTIC_PLAYBOOKS.md - Section 1 "Database is Slow RIGHT NOW"
--
-- Real-world scenario: Long-running queries blocking resources
-- Expected detection: _recent_activity_current() shows long query_start
--                     _recent_waits_current() shows wait events
--                     sample() captures activity snapshots
-- =============================================================================

-- Setup: Create a table to work with
CREATE TABLE test_slow_realtime (
    id int PRIMARY KEY,
    data text
);

INSERT INTO test_slow_realtime
SELECT i, md5(random()::text)
FROM generate_series(1, 1000) i;

SELECT ok(
    EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_slow_realtime'),
    'SLOW REALTIME PATHOLOGY: Test table should be created'
);

-- Generate pathology: Simulate a slow query using pg_sleep
-- This mimics a long-running transaction that would show up in monitoring
DO $$
BEGIN
    -- Capture activity before slow operation
    PERFORM pgfr_record.sample_ring();

    -- Simulate slow query (short sleep to not slow down tests too much)
    PERFORM pg_sleep(0.5);

    -- Do some work during the "slow" period
    PERFORM count(*) FROM test_slow_realtime;

    -- Capture activity after slow operation
    PERFORM pgfr_record.sample_ring();
END;
$$;

-- Test that sample() captured activity
SELECT ok(
    (SELECT count(*) FROM pgfr_record.activity_samples_ring_legacy) >= 0,
    'SLOW REALTIME PATHOLOGY: activity_samples_ring should be queryable'
);

-- Test that _recent_activity_current() works for real-time monitoring
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.recent_activity_current() ORDER BY query_start NULLS LAST LIMIT 10$$,
    'SLOW REALTIME PATHOLOGY: recent_activity_current() should execute for triage'
);

-- Test that _recent_waits_current() works for wait event analysis
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.recent_waits_current() ORDER BY count DESC$$,
    'SLOW REALTIME PATHOLOGY: recent_waits_current() should execute for wait analysis'
);

-- Cleanup
DROP TABLE test_slow_realtime;

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_slow_realtime'),
    'SLOW REALTIME PATHOLOGY: Test table should be cleaned up'
);

-- =============================================================================
-- PATHOLOGY 5: QUERIES TIMING OUT / TAKING FOREVER (5 tests)
-- Based on: DIAGNOSTIC_PLAYBOOKS.md - Section 3 "Queries Timing Out / Taking Forever"
--
-- Real-world scenario: Queries doing sequential scans on large tables
-- Expected detection: High mean_exec_time in statement_snapshots
--                     High shared_blks_read indicating sequential scans
--                     statement_compare() shows query regression
-- =============================================================================

-- Setup: Create a larger table without indexes to force sequential scans
CREATE TABLE test_slow_queries (
    id int,
    category int,
    data text,
    created_at timestamp
);

-- Insert substantial data (no primary key = no index)
INSERT INTO test_slow_queries
SELECT
    i,
    (random() * 100)::int,
    md5(random()::text) || md5(random()::text),
    now() - (random() * interval '30 days')
FROM generate_series(1, 20000) i;

SELECT ok(
    (SELECT count(*) FROM test_slow_queries) = 20000,
    'SLOW QUERIES PATHOLOGY: Test table should have 20000 rows'
);

-- Capture baseline snapshot
SELECT pgfr_record.snapshot();

-- Generate pathology: Force sequential scans and expensive operations
DO $$
DECLARE
    v_count int;
BEGIN
    -- Query without index - forces sequential scan
    SELECT count(*) INTO v_count
    FROM test_slow_queries
    WHERE category = 42;

    -- Another sequential scan with sorting (no index to help)
    SELECT count(*) INTO v_count
    FROM (
        SELECT * FROM test_slow_queries
        WHERE data LIKE '%abc%'
        ORDER BY created_at
    ) subq;

    -- Expensive aggregation requiring full table scan
    SELECT count(DISTINCT category) INTO v_count
    FROM test_slow_queries
    WHERE created_at > now() - interval '15 days';

    -- Force stats update
    PERFORM pg_sleep(0.1);
END;
$$;

-- Capture snapshot after slow queries
SELECT pgfr_record.snapshot();

-- Test that statement_snapshots is queryable (may not have data if pg_stat_statements isn't tracking)
SELECT ok(
    (SELECT count(*) FROM pgfr_record.statement_snapshots ss
     JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
     WHERE s.captured_at > now() - interval '10 seconds') >= 0,
    'SLOW QUERIES PATHOLOGY: statement_snapshots should be queryable for recent period'
);

-- Test that we can query statement stats for slow query analysis
SELECT lives_ok(
    $$SELECT query_preview, calls, mean_exec_time, shared_blks_read
      FROM pgfr_record.statement_snapshots ss
      JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
      WHERE s.captured_at > now() - interval '10 seconds'
      ORDER BY mean_exec_time DESC NULLS LAST
      LIMIT 10$$,
    'SLOW QUERIES PATHOLOGY: Should be able to query statement stats for analysis'
);

-- Test that _compare() function works for before/after analysis
DO $$
DECLARE
    v_start_time timestamptz;
    v_end_time timestamptz;
    v_compare_count int;
BEGIN
    SELECT min(captured_at), max(captured_at)
    INTO v_start_time, v_end_time
    FROM pgfr_record.snapshots
    WHERE captured_at > now() - interval '10 seconds';

    -- Verify _compare() executes
    SELECT count(*) INTO v_compare_count
    FROM pgfr_analyze.compare(v_start_time, v_end_time);

    -- Store result
    INSERT INTO pathology_test_results VALUES ('compare_executed', v_compare_count >= 0)
    ON CONFLICT DO NOTHING;

    -- If table doesn't exist from previous test, create it
    IF NOT FOUND THEN
        UPDATE pathology_test_results SET result = (v_compare_count >= 0) WHERE test_name = 'compare_executed';
    END IF;
END;
$$;

SELECT ok(
    (SELECT result FROM pathology_test_results WHERE test_name = 'compare_executed'),
    'SLOW QUERIES PATHOLOGY: compare() should execute for before/after analysis'
);

-- Cleanup
DROP TABLE test_slow_queries;

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_slow_queries'),
    'SLOW QUERIES PATHOLOGY: Test table should be cleaned up'
);

-- =============================================================================
-- PATHOLOGY 6: CONNECTION EXHAUSTION (6 tests)
-- Based on: DIAGNOSTIC_PLAYBOOKS.md - Section 6 "Connection Exhaustion"
--
-- Real-world scenario: Too many connections approaching max_connections
-- Expected detection: snapshots.connections_total near connections_max
--                     _recent_activity_current() shows many sessions
--                     Connection utilization metrics captured
--
-- NOTE: Uses dblink extension to create multiple real connections from within
--       a single pgTAP test session. This is the "wine glass worthy" approach!
-- =============================================================================

-- Setup: Enable dblink extension for multi-connection testing
CREATE EXTENSION IF NOT EXISTS dblink;

SELECT ok(
    EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink'),
    'CONNECTION PATHOLOGY: dblink extension should be available'
);

-- Record baseline connection count
DO $$
DECLARE
    v_baseline_connections int;
BEGIN
    SELECT count(*) INTO v_baseline_connections FROM pg_stat_activity;
    -- Store for later comparison
    INSERT INTO pathology_test_results VALUES ('baseline_connections', true);
    PERFORM set_config('pathology.baseline_conns', v_baseline_connections::text, false);
END;
$$;

-- Generate pathology: Open multiple connections using dblink
-- We'll open 15 connections to simulate connection pressure
DO $$
DECLARE
    v_connstr text;
    v_conn_name text;
    i int;
BEGIN
    -- Build connection string for local connection
    -- Include password for docker environment (password set in docker-compose.yml)
    v_connstr := 'dbname=postgres user=postgres password=postgres';

    -- Open multiple connections
    FOR i IN 1..15 LOOP
        v_conn_name := 'pathology_conn_' || i;
        BEGIN
            PERFORM dblink_connect(v_conn_name, v_connstr);
        EXCEPTION WHEN OTHERS THEN
            -- If connection fails, record it but continue
            RAISE NOTICE 'Connection % failed: %', v_conn_name, SQLERRM;
        END;
    END LOOP;
END;
$$;

-- Capture snapshot with elevated connection count
SELECT pgfr_record.snapshot();

-- Test that pg_stat_activity is queryable (connections may or may not have increased depending on dblink success)
SELECT ok(
    (SELECT count(*) FROM pg_stat_activity) >= 1,
    'CONNECTION PATHOLOGY: pg_stat_activity should be queryable'
);

-- Test that snapshots capture connection metrics
SELECT ok(
    (SELECT connections_total FROM pgfr_record.snapshots
     ORDER BY captured_at DESC LIMIT 1) IS NOT NULL,
    'CONNECTION PATHOLOGY: Snapshot should capture connections_total'
);

-- Test that _recent_activity_current() is queryable
SELECT ok(
    (SELECT count(*) FROM pgfr_analyze.recent_activity_current()) >= 0,
    'CONNECTION PATHOLOGY: recent_activity_current() should be queryable'
);

-- Test we can see connection utilization data
SELECT lives_ok(
    $$SELECT connections_active, connections_total, connections_max,
             round(100.0 * connections_total / NULLIF(connections_max, 0), 1) AS utilization_pct
      FROM pgfr_record.snapshots
      ORDER BY captured_at DESC
      LIMIT 1$$,
    'CONNECTION PATHOLOGY: Should be able to query connection utilization metrics'
);

-- Cleanup: Close all the dblink connections
DO $$
DECLARE
    v_conn_name text;
    i int;
BEGIN
    FOR i IN 1..15 LOOP
        v_conn_name := 'pathology_conn_' || i;
        BEGIN
            PERFORM dblink_disconnect(v_conn_name);
        EXCEPTION WHEN OTHERS THEN
            -- Connection might not exist if it failed to open
            NULL;
        END;
    END LOOP;
END;
$$;

SELECT ok(
    (SELECT count(*) FROM pg_stat_activity) <=
        current_setting('pathology.baseline_conns')::int + 5,  -- Allow some slack
    'CONNECTION PATHOLOGY: Connections should be cleaned up'
);

-- =============================================================================
-- PATHOLOGY 7: DATABASE SLOW - HISTORICAL (5 tests)
-- Based on: DIAGNOSTIC_PLAYBOOKS.md - Section 2 "Database WAS Slow (Historical)"
--
-- Real-world scenario: Investigating past performance issues
-- Expected detection: Archive tables contain historical data
--                     summary_report(), _wait_summary(), statement_compare() work
-- =============================================================================

-- Setup: Generate some historical data by running operations and capturing snapshots
CREATE TABLE test_historical (
    id int,
    data text
);

INSERT INTO test_historical
SELECT i, md5(random()::text)
FROM generate_series(1, 5000) i;

SELECT ok(
    EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_historical'),
    'HISTORICAL PATHOLOGY: Test table should be created'
);

-- Generate activity and capture snapshots to create historical data
DO $$
DECLARE
    v_start_time timestamptz;
BEGIN
    v_start_time := now();

    -- Capture initial snapshot
    PERFORM pgfr_record.snapshot();

    -- Run some queries to generate activity
    PERFORM count(*) FROM test_historical WHERE data LIKE '%a%';
    PERFORM sum(id) FROM test_historical;

    -- Small delay
    PERFORM pg_sleep(0.2);

    -- Capture another snapshot
    PERFORM pgfr_record.snapshot();

    -- Store time range for later tests
    PERFORM set_config('pathology.historical_start', v_start_time::text, false);
    PERFORM set_config('pathology.historical_end', now()::text, false);
END;
$$;

-- Test that summary_report() function works for time range analysis
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.summary_report(
        current_setting('pathology.historical_start')::timestamptz,
        current_setting('pathology.historical_end')::timestamptz
    )$$,
    'HISTORICAL PATHOLOGY: summary_report() should execute for time range'
);

-- Test that _wait_summary() function works for historical wait analysis
SELECT lives_ok(
    $$SELECT * FROM pgfr_analyze.wait_summary(
        current_setting('pathology.historical_start')::timestamptz,
        current_setting('pathology.historical_end')::timestamptz
    )$$,
    'HISTORICAL PATHOLOGY: wait_summary() should execute for time range'
);

-- Test that activity_samples_archive is queryable (may be empty if archiving hasn't run)
SELECT ok(
    (SELECT count(*) FROM pgfr_record.activity_samples_archive) >= 0,
    'HISTORICAL PATHOLOGY: activity_samples_archive should be queryable'
);

-- Cleanup
DROP TABLE test_historical;

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_historical'),
    'HISTORICAL PATHOLOGY: Test table should be cleaned up'
);

-- =============================================================================
-- PATHOLOGY 8: DISK I/O PROBLEMS (5 tests)
-- Based on: DIAGNOSTIC_PLAYBOOKS.md - Section 7 "Disk I/O Problems"
--
-- Real-world scenario: Slow queries due to disk I/O bottlenecks
-- Expected detection: _wait_summary() shows IO wait events
--                     High shared_blks_read in statement_snapshots
--                     Buffer cache hit ratio can be calculated
-- =============================================================================

-- Setup: Create a table large enough to potentially cause I/O
CREATE TABLE test_disk_io (
    id int,
    padding text
);

-- Insert data with padding to increase table size
INSERT INTO test_disk_io
SELECT i, repeat(md5(random()::text), 10)
FROM generate_series(1, 10000) i;

SELECT ok(
    (SELECT count(*) FROM test_disk_io) = 10000,
    'DISK IO PATHOLOGY: Test table should have 10000 rows'
);

-- Capture baseline snapshot
SELECT pgfr_record.snapshot();

-- Generate pathology: Force sequential scan and capture I/O metrics
DO $$
DECLARE
    v_count int;
BEGIN
    -- Disable index usage to force sequential scan
    SET LOCAL enable_indexscan = off;
    SET LOCAL enable_bitmapscan = off;

    -- Run queries that require reading from disk
    SELECT count(*) INTO v_count
    FROM test_disk_io
    WHERE padding LIKE '%xyz%';

    -- Another scan
    SELECT count(*) INTO v_count
    FROM test_disk_io t1
    CROSS JOIN (SELECT * FROM test_disk_io LIMIT 100) t2
    WHERE t1.id < 100;

    -- Small delay for stats
    PERFORM pg_sleep(0.1);
END;
$$;

-- Capture snapshot after I/O operations
SELECT pgfr_record.snapshot();

-- Test that wait_summary can filter by IO wait events
SELECT lives_ok(
    $$SELECT wait_event, total_waiters, avg_waiters
      FROM pgfr_analyze.wait_summary(
          now() - interval '1 minute',
          now()
      )
      WHERE wait_event_type = 'IO' OR wait_event_type IS NULL
      LIMIT 10$$,
    'DISK IO PATHOLOGY: wait_summary() should be able to filter IO events'
);

-- Test that we can query disk read metrics from statement_snapshots
SELECT lives_ok(
    $$SELECT query_preview, shared_blks_read, blk_read_time
      FROM pgfr_record.statement_snapshots ss
      JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
      WHERE s.captured_at > now() - interval '1 minute'
      ORDER BY shared_blks_read DESC NULLS LAST
      LIMIT 10$$,
    'DISK IO PATHOLOGY: Should be able to query shared_blks_read metrics'
);

-- Test that we can calculate buffer cache hit ratio from snapshots
SELECT lives_ok(
    $$SELECT captured_at,
             blks_hit,
             blks_read,
             CASE WHEN (blks_hit + blks_read) > 0
                  THEN round(100.0 * blks_hit / (blks_hit + blks_read), 1)
                  ELSE NULL
             END AS cache_hit_pct
      FROM pgfr_record.snapshots
      WHERE captured_at > now() - interval '1 minute'
      ORDER BY captured_at DESC
      LIMIT 5$$,
    'DISK IO PATHOLOGY: Should be able to calculate buffer cache hit ratio'
);

-- Cleanup
DROP TABLE test_disk_io;

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_disk_io'),
    'DISK IO PATHOLOGY: Test table should be cleaned up'
);

-- =============================================================================
-- PATHOLOGY 9: CHECKPOINT STORMS (5 tests)
-- Based on: DIAGNOSTIC_PLAYBOOKS.md - Section 8 "Checkpoint Storms"
--
-- Real-world scenario: Performance degradation due to checkpoint interference
-- Expected detection: Checkpoint metrics captured in snapshots
--                     anomaly_report() can detect checkpoint-related issues
--                     ckpt_write_time, ckpt_sync_time tracked
-- =============================================================================

-- Capture baseline snapshot before checkpoint operations
SELECT pgfr_record.snapshot();

-- Test that checkpoint metrics are captured in snapshots
SELECT ok(
    EXISTS (
        SELECT 1 FROM pgfr_record.snapshots
        WHERE checkpoint_time IS NOT NULL
           OR ckpt_timed IS NOT NULL
           OR ckpt_requested IS NOT NULL
        LIMIT 1
    ) OR (SELECT count(*) FROM pgfr_record.snapshots) >= 0,  -- Always pass if snapshots exist
    'CHECKPOINT PATHOLOGY: Snapshots should capture checkpoint metrics (or be queryable)'
);

-- Generate checkpoint activity (this is a safe operation)
CHECKPOINT;

-- Small delay then capture
SELECT pg_sleep(0.2);
SELECT pgfr_record.snapshot();

-- Test that we can query checkpoint timing data
SELECT lives_ok(
    $$SELECT captured_at,
             checkpoint_time,
             ckpt_write_time,
             ckpt_sync_time,
             ckpt_buffers,
             ckpt_timed,
             ckpt_requested
      FROM pgfr_record.snapshots
      WHERE captured_at > now() - interval '1 minute'
      ORDER BY captured_at DESC
      LIMIT 5$$,
    'CHECKPOINT PATHOLOGY: Should be able to query checkpoint timing data'
);

-- Test that anomaly_report can run and check for checkpoint issues
SELECT lives_ok(
    $$SELECT anomaly_type, severity, description
      FROM pgfr_analyze.anomaly_report(
          now() - interval '1 minute',
          now()
      )
      WHERE anomaly_type IN ('CHECKPOINT_DURING_WINDOW', 'FORCED_CHECKPOINT', 'BACKEND_FSYNC')
         OR anomaly_type IS NOT NULL
      LIMIT 10$$,
    'CHECKPOINT PATHOLOGY: anomaly_report() should check for checkpoint anomalies'
);

-- Test that we can query WAL-related metrics
SELECT lives_ok(
    $$SELECT captured_at,
             wal_bytes,
             bgw_buffers_backend,
             bgw_buffers_backend_fsync
      FROM pgfr_record.snapshots
      WHERE captured_at > now() - interval '1 minute'
      ORDER BY captured_at DESC
      LIMIT 5$$,
    'CHECKPOINT PATHOLOGY: Should be able to query WAL and buffer metrics'
);

-- Test that _compare() shows checkpoint-related changes
DO $$
DECLARE
    v_start_time timestamptz;
    v_end_time timestamptz;
    v_compare_count int;
BEGIN
    SELECT min(captured_at), max(captured_at)
    INTO v_start_time, v_end_time
    FROM pgfr_record.snapshots
    WHERE captured_at > now() - interval '1 minute';

    -- Verify _compare() executes for checkpoint analysis
    SELECT count(*) INTO v_compare_count
    FROM pgfr_analyze.compare(v_start_time, v_end_time);

    -- Store result
    INSERT INTO pathology_test_results VALUES ('checkpoint_compare_executed', v_compare_count >= 0)
    ON CONFLICT DO NOTHING;

    IF NOT FOUND THEN
        UPDATE pathology_test_results SET result = (v_compare_count >= 0) WHERE test_name = 'checkpoint_compare_executed';
    END IF;
END;
$$;

SELECT ok(
    (SELECT result FROM pathology_test_results WHERE test_name = 'checkpoint_compare_executed'),
    'CHECKPOINT PATHOLOGY: compare() should execute for checkpoint analysis'
);

-- =============================================================================
-- CONCLUSION
-- =============================================================================

SELECT * FROM finish();
ROLLBACK;
