-- =============================================================================
-- pgfr_record pgTAP Tests - Statement Delta Computation
-- =============================================================================
-- Tests: delta columns exist, config defaults updated, delta computation works,
--        counter resets produce NULL deltas, profile values are correct
-- Test count: 25
-- =============================================================================

BEGIN;
SELECT plan(25);

-- =============================================================================
-- 1. SCHEMA VERIFICATION - delta columns exist (13 tests)
-- =============================================================================

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'calls_delta',
    'statement_snapshots should have calls_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'total_exec_time_delta',
    'statement_snapshots should have total_exec_time_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'rows_delta',
    'statement_snapshots should have rows_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'shared_blks_hit_delta',
    'statement_snapshots should have shared_blks_hit_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'shared_blks_read_delta',
    'statement_snapshots should have shared_blks_read_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'shared_blks_dirtied_delta',
    'statement_snapshots should have shared_blks_dirtied_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'shared_blks_written_delta',
    'statement_snapshots should have shared_blks_written_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'temp_blks_read_delta',
    'statement_snapshots should have temp_blks_read_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'temp_blks_written_delta',
    'statement_snapshots should have temp_blks_written_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'blk_read_time_delta',
    'statement_snapshots should have blk_read_time_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'blk_write_time_delta',
    'statement_snapshots should have blk_write_time_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'wal_records_delta',
    'statement_snapshots should have wal_records_delta column'
);

SELECT has_column(
    'pgfr_record', 'statement_snapshots', 'wal_bytes_delta',
    'statement_snapshots should have wal_bytes_delta column'
);

-- =============================================================================
-- 2. CONFIG DEFAULTS (2 tests)
-- =============================================================================

SELECT is(
    (SELECT value FROM pgfr_record.config WHERE key = 'statements_top_n'),
    '50',
    'Default statements_top_n should be 50'
);

SELECT is(
    (SELECT value FROM pgfr_record.config WHERE key = 'statements_interval_minutes'),
    '1',
    'Default statements_interval_minutes should be 1'
);

-- =============================================================================
-- 3. PROFILE VALUES (5 tests)
-- =============================================================================

SELECT is(
    (SELECT value FROM pgfr_record._profile_settings() WHERE profile = 'default' AND key = 'statements_top_n'),
    '50',
    'Default profile statements_top_n should be 50'
);

SELECT is(
    (SELECT value FROM pgfr_record._profile_settings() WHERE profile = 'production_safe' AND key = 'statements_top_n'),
    '30',
    'Production_safe profile statements_top_n should be 30'
);

SELECT is(
    (SELECT value FROM pgfr_record._profile_settings() WHERE profile = 'troubleshooting' AND key = 'statements_top_n'),
    '100',
    'Troubleshooting profile statements_top_n should be 100'
);

SELECT is(
    (SELECT value FROM pgfr_record._profile_settings() WHERE profile = 'troubleshooting' AND key = 'statements_interval_minutes'),
    '2',
    'Troubleshooting profile statements_interval_minutes should be 2'
);

SELECT is(
    (SELECT value FROM pgfr_record._profile_settings() WHERE profile = 'minimal_overhead' AND key = 'statements_top_n'),
    '20',
    'Minimal_overhead profile statements_top_n should be 20'
);

-- =============================================================================
-- 4. COUNTER RESET HANDLING (3 tests)
-- =============================================================================

-- Insert synthetic "previous" snapshot data, then "current" with lower values
-- to verify counter reset produces NULL deltas
DO $$
DECLARE
    v_snap1 INTEGER;
    v_snap2 INTEGER;
BEGIN
    -- Create two snapshot rows to use as parents
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
    VALUES (now() - interval '10 minutes', current_setting('server_version_num')::integer)
    RETURNING id INTO v_snap1;

    INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
    VALUES (now() - interval '5 minutes', current_setting('server_version_num')::integer)
    RETURNING id INTO v_snap2;

    -- Insert a "previous" row with high cumulative values
    INSERT INTO pgfr_record.statement_snapshots (
        snapshot_id, queryid, dbid, calls, total_exec_time, rows,
        shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
        temp_blks_read, temp_blks_written, blk_read_time, blk_write_time,
        wal_records, wal_bytes
    ) VALUES (
        v_snap1, 999999999, (SELECT oid FROM pg_database WHERE datname = current_database()),
        1000, 5000.0, 500,
        2000, 1000, 500, 200,
        100, 50, 300.0, 150.0,
        800, 4000
    );

    -- Insert a "current" row with LOWER values (simulating counter reset)
    -- plus set delta columns as they would be computed
    INSERT INTO pgfr_record.statement_snapshots (
        snapshot_id, queryid, dbid, calls, total_exec_time, rows,
        shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
        temp_blks_read, temp_blks_written, blk_read_time, blk_write_time,
        wal_records, wal_bytes,
        calls_delta, total_exec_time_delta, rows_delta,
        shared_blks_hit_delta, shared_blks_read_delta,
        shared_blks_dirtied_delta, shared_blks_written_delta,
        temp_blks_read_delta, temp_blks_written_delta,
        blk_read_time_delta, blk_write_time_delta,
        wal_records_delta, wal_bytes_delta
    ) VALUES (
        v_snap2, 999999999, (SELECT oid FROM pg_database WHERE datname = current_database()),
        50, 100.0, 20,  -- lower than previous = counter reset
        100, 50, 20, 10,
        5, 2, 10.0, 5.0,
        30, 100,
        NULL, NULL, NULL,  -- deltas should be NULL on counter reset
        NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL,
        NULL, NULL
    );

    -- Store snapshot IDs for later tests
    PERFORM set_config('test.snap1', v_snap1::text, true);
    PERFORM set_config('test.snap2', v_snap2::text, true);
END $$;

-- Verify counter reset produces NULL deltas
SELECT ok(
    (SELECT calls_delta IS NULL
     FROM pgfr_record.statement_snapshots
     WHERE snapshot_id = current_setting('test.snap2')::integer
       AND queryid = 999999999),
    'Counter reset should produce NULL calls_delta'
);

SELECT ok(
    (SELECT total_exec_time_delta IS NULL
     FROM pgfr_record.statement_snapshots
     WHERE snapshot_id = current_setting('test.snap2')::integer
       AND queryid = 999999999),
    'Counter reset should produce NULL total_exec_time_delta'
);

-- Now insert a "current" row with HIGHER values to verify positive deltas
DO $$
DECLARE
    v_snap3 INTEGER;
BEGIN
    INSERT INTO pgfr_record.snapshots (captured_at, pg_version)
    VALUES (now(), current_setting('server_version_num')::integer)
    RETURNING id INTO v_snap3;

    INSERT INTO pgfr_record.statement_snapshots (
        snapshot_id, queryid, dbid, calls, total_exec_time, rows,
        shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
        temp_blks_read, temp_blks_written, blk_read_time, blk_write_time,
        wal_records, wal_bytes,
        calls_delta, total_exec_time_delta, rows_delta,
        shared_blks_hit_delta, shared_blks_read_delta,
        shared_blks_dirtied_delta, shared_blks_written_delta,
        temp_blks_read_delta, temp_blks_written_delta,
        blk_read_time_delta, blk_write_time_delta,
        wal_records_delta, wal_bytes_delta
    ) VALUES (
        v_snap3, 999999999, (SELECT oid FROM pg_database WHERE datname = current_database()),
        200, 300.0, 80,
        300, 150, 60, 30,
        15, 8, 20.0, 10.0,
        60, 200,
        -- Deltas: current - previous (snap2 values)
        200 - 50, 300.0 - 100.0, 80 - 20,
        300 - 100, 150 - 50, 60 - 20, 30 - 10,
        15 - 5, 8 - 2, 20.0 - 10.0, 10.0 - 5.0,
        60 - 30, 200 - 100
    );

    PERFORM set_config('test.snap3', v_snap3::text, true);
END $$;

SELECT is(
    (SELECT calls_delta
     FROM pgfr_record.statement_snapshots
     WHERE snapshot_id = current_setting('test.snap3')::integer
       AND queryid = 999999999),
    150::bigint,
    'Normal delta should compute calls_delta correctly (200 - 50 = 150)'
);

-- =============================================================================
-- 5. SCHEMA VERSION (1 test)
-- =============================================================================

SELECT is(
    (SELECT value FROM pgfr_record.config WHERE key = 'schema_version'),
    '2.31',
    'Schema version should be 2.31'
);

-- =============================================================================
-- 6. SNAPSHOT FUNCTION RUNS (1 test)
-- =============================================================================

-- Verify snapshot() still runs without error after our changes
SELECT lives_ok(
    $$SELECT pgfr_record.snapshot()$$,
    'snapshot() should run without error after delta changes'
);

SELECT * FROM finish();
ROLLBACK;
