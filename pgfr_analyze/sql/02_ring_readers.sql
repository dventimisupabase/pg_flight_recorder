-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia


-- recent_waits_current, recent_activity_current, recent_locks_current, and
-- wait_summary previously lived here as SQL-language functions over the
-- legacy 120-slot ring. They've been retired; the v2 definitions in
-- 10_v2_readers.sql replace them. statement_compare survives because it
-- reads from pgfr_record.statement_snapshots (separate Phase 3 cutover).

-- Compares statement execution metrics between two snapshots, calculating performance deltas
CREATE OR REPLACE FUNCTION pgfr_analyze.statement_compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_min_delta_ms DOUBLE PRECISION DEFAULT 100,
    p_limit INTEGER DEFAULT 25
)
RETURNS TABLE(
    queryid                     BIGINT,
    query_preview               TEXT,
    calls_start                 BIGINT,
    calls_end                   BIGINT,
    calls_delta                 BIGINT,
    total_exec_time_start_ms    DOUBLE PRECISION,
    total_exec_time_end_ms      DOUBLE PRECISION,
    total_exec_time_delta_ms    DOUBLE PRECISION,
    mean_exec_time_start_ms     DOUBLE PRECISION,
    mean_exec_time_end_ms       DOUBLE PRECISION,
    rows_delta                  BIGINT,
    shared_blks_hit_delta       BIGINT,
    shared_blks_read_delta      BIGINT,
    shared_blks_written_delta   BIGINT,
    temp_blks_read_delta        BIGINT,
    temp_blks_written_delta     BIGINT,
    wal_bytes_delta             NUMERIC,
    hit_ratio_pct               NUMERIC,
    time_per_call_ms            DOUBLE PRECISION
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT ss.*, s.captured_at
        FROM pgfr_record.statement_snapshots ss
        JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY s.captured_at DESC
        LIMIT 1000
    ),
    end_snap AS (
        SELECT ss.*, s.captured_at
        FROM pgfr_record.statement_snapshots ss
        JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at >= p_end_time
        ORDER BY s.captured_at ASC
        LIMIT 1000
    ),
    matched AS (
        SELECT
            e.queryid,
            COALESCE(e.query_preview, s.query_preview) AS query_preview,
            s.calls AS calls_start,
            e.calls AS calls_end,
            s.total_exec_time AS total_exec_time_start,
            e.total_exec_time AS total_exec_time_end,
            s.mean_exec_time AS mean_exec_time_start,
            e.mean_exec_time AS mean_exec_time_end,
            s.rows AS rows_start,
            e.rows AS rows_end,
            s.shared_blks_hit AS shared_blks_hit_start,
            e.shared_blks_hit AS shared_blks_hit_end,
            s.shared_blks_read AS shared_blks_read_start,
            e.shared_blks_read AS shared_blks_read_end,
            s.shared_blks_written AS shared_blks_written_start,
            e.shared_blks_written AS shared_blks_written_end,
            s.temp_blks_read AS temp_blks_read_start,
            e.temp_blks_read AS temp_blks_read_end,
            s.temp_blks_written AS temp_blks_written_start,
            e.temp_blks_written AS temp_blks_written_end,
            s.wal_bytes AS wal_bytes_start,
            e.wal_bytes AS wal_bytes_end
        FROM end_snap e
        LEFT JOIN start_snap s ON s.queryid = e.queryid AND s.dbid = e.dbid
    )
    SELECT
        m.queryid,
        m.query_preview,
        COALESCE(m.calls_start, 0),
        m.calls_end,
        m.calls_end - COALESCE(m.calls_start, 0),
        COALESCE(m.total_exec_time_start, 0),
        m.total_exec_time_end,
        m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0),
        m.mean_exec_time_start,
        m.mean_exec_time_end,
        m.rows_end - COALESCE(m.rows_start, 0),
        m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0),
        m.shared_blks_read_end - COALESCE(m.shared_blks_read_start, 0),
        m.shared_blks_written_end - COALESCE(m.shared_blks_written_start, 0),
        m.temp_blks_read_end - COALESCE(m.temp_blks_read_start, 0),
        m.temp_blks_written_end - COALESCE(m.temp_blks_written_start, 0),
        m.wal_bytes_end - COALESCE(m.wal_bytes_start, 0),
        CASE
            WHEN (m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0) +
                  m.shared_blks_read_end - COALESCE(m.shared_blks_read_start, 0)) > 0
            THEN round(
                100.0 * (m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0)) /
                (m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0) +
                 m.shared_blks_read_end - COALESCE(m.shared_blks_read_start, 0)), 1
            )
            ELSE NULL
        END,
        CASE
            WHEN (m.calls_end - COALESCE(m.calls_start, 0)) > 0
            THEN (m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0)) /
                 (m.calls_end - COALESCE(m.calls_start, 0))
            ELSE NULL
        END
    FROM matched m
    WHERE (m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0)) >= p_min_delta_ms
    ORDER BY (m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0)) DESC
    LIMIT p_limit
$$;
COMMENT ON FUNCTION pgfr_analyze.statement_compare(TIMESTAMPTZ, TIMESTAMPTZ, DOUBLE PRECISION, INTEGER) IS 'Compares statement execution metrics between two snapshots, calculating performance deltas.

Output columns:
  queryid: [dimension] [bigint] pg_stat_statements query identifier; start and end snapshot rows are matched on queryid and dbid.
  query_preview: [dimension] [text] Truncated normalized query text, taken from the end snapshot with fallback to the start snapshot.
  calls_start: [gauge] [count] Cumulative pg_stat_statements calls counter level at the start snapshot; 0 when the query is absent from the start snapshot.
  calls_end: [gauge] [count] Cumulative pg_stat_statements calls counter level at the end snapshot.
  calls_delta: [counter-delta] [count] Executions over the interval: calls_end minus calls_start. Exact over the interval, modulo pg_stat_statements resets or evictions between the snapshots.
  total_exec_time_start_ms: [gauge] [milliseconds] Cumulative total execution time counter level at the start snapshot; 0 when the query is absent from the start snapshot.
  total_exec_time_end_ms: [gauge] [milliseconds] Cumulative total execution time counter level at the end snapshot.
  total_exec_time_delta_ms: [counter-delta] [milliseconds] Execution time accumulated over the interval (end minus start); also the p_min_delta_ms row filter and the sort key.
  mean_exec_time_start_ms: [gauge] [milliseconds] pg_stat_statements lifetime mean execution time per call as recorded at the start snapshot instant, not an interval mean.
  mean_exec_time_end_ms: [gauge] [milliseconds] pg_stat_statements lifetime mean execution time per call as recorded at the end snapshot instant, not an interval mean.
  rows_delta: [counter-delta] [count] Rows returned or affected by the statement over the interval (end minus start).
  shared_blks_hit_delta: [counter-delta] [blocks] Shared buffer cache hits over the interval (end minus start).
  shared_blks_read_delta: [counter-delta] [blocks] Shared blocks read from storage over the interval (end minus start).
  shared_blks_written_delta: [counter-delta] [blocks] Shared blocks written over the interval (end minus start).
  temp_blks_read_delta: [counter-delta] [blocks] Temporary blocks read over the interval (end minus start).
  temp_blks_written_delta: [counter-delta] [blocks] Temporary blocks written over the interval (end minus start).
  wal_bytes_delta: [counter-delta] [bytes] WAL bytes generated by the statement over the interval (end minus start).
  hit_ratio_pct: [derived] [percent] Buffer cache hit rate on a 0-100 scale: numerator shared_blks_hit_delta, denominator shared_blks_hit_delta plus shared_blks_read_delta; NULL when that denominator is zero.
  time_per_call_ms: [derived] [milliseconds] Mean execution time per call over the interval: numerator total_exec_time_delta_ms, denominator calls_delta; NULL when calls_delta is zero.';

-- Retrieves active session details at a specific point in time
