-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

CREATE OR REPLACE FUNCTION pgfr_analyze.recent_waits_current()
RETURNS TABLE (
    captured_at TIMESTAMPTZ,
    backend_type TEXT,
    wait_event_type TEXT,
    wait_event TEXT,
    state TEXT,
    count INTEGER
)
LANGUAGE sql STABLE AS $$
    SELECT
        sr.captured_at,
        w.backend_type,
        w.wait_event_type,
        w.wait_event,
        w.state,
        w.count
    FROM pgfr_record.samples_ring sr
    JOIN pgfr_record.wait_samples_ring w ON w.slot_id = sr.slot_id
    WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
      AND w.backend_type IS NOT NULL
    ORDER BY sr.captured_at DESC, w.count DESC;
$$;
COMMENT ON FUNCTION pgfr_analyze.recent_waits_current() IS 'Retrieves recent wait event samples from the flight recorder ring buffer.';

-- Retrieves recent backend session activity with query duration and wait event details
CREATE OR REPLACE FUNCTION pgfr_analyze.recent_activity_current()
RETURNS TABLE (
    captured_at TIMESTAMPTZ,
    pid INTEGER,
    usename TEXT,
    application_name TEXT,
    backend_type TEXT,
    state TEXT,
    wait_event_type TEXT,
    wait_event TEXT,
    query_start TIMESTAMPTZ,
    running_for INTERVAL,
    query_preview TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        sr.captured_at,
        a.pid,
        a.usename,
        a.application_name,
        a.backend_type,
        a.state,
        a.wait_event_type,
        a.wait_event,
        a.query_start,
        sr.captured_at - a.query_start AS running_for,
        a.query_preview
    FROM pgfr_record.samples_ring sr
    JOIN pgfr_record.activity_samples_ring a ON a.slot_id = sr.slot_id
    WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
      AND a.pid IS NOT NULL
    ORDER BY sr.captured_at DESC, a.query_start ASC;
$$;
COMMENT ON FUNCTION pgfr_analyze.recent_activity_current() IS 'Retrieves recent backend session activity with query duration and wait event details.';

-- Returns recent lock contention events showing which processes are blocked
CREATE OR REPLACE FUNCTION pgfr_analyze.recent_locks_current()
RETURNS TABLE (
    captured_at TIMESTAMPTZ,
    blocked_pid INTEGER,
    blocked_user TEXT,
    blocked_app TEXT,
    blocked_duration INTERVAL,
    blocking_pid INTEGER,
    blocking_user TEXT,
    blocking_app TEXT,
    lock_type TEXT,
    locked_relation TEXT,
    blocked_query_preview TEXT,
    blocking_query_preview TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        sr.captured_at,
        l.blocked_pid,
        l.blocked_user,
        l.blocked_app,
        l.blocked_duration,
        l.blocking_pid,
        l.blocking_user,
        l.blocking_app,
        l.lock_type,
        COALESCE(l.locked_relation_oid::regclass::text, 'OID:' || l.locked_relation_oid::text) AS locked_relation,
        l.blocked_query_preview,
        l.blocking_query_preview
    FROM pgfr_record.samples_ring sr
    JOIN pgfr_record.lock_samples_ring l ON l.slot_id = sr.slot_id
    WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
      AND l.blocked_pid IS NOT NULL
    ORDER BY sr.captured_at DESC, l.blocked_duration DESC;
$$;
COMMENT ON FUNCTION pgfr_analyze.recent_locks_current() IS 'Returns recent lock contention events showing which processes are blocked.';

-- Summarizes wait events within a time range, grouped by backend type and wait event
CREATE OR REPLACE FUNCTION pgfr_analyze.wait_summary(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    backend_type        TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    sample_count        BIGINT,
    total_waiters       BIGINT,
    avg_waiters         NUMERIC,
    max_waiters         INTEGER,
    pct_of_samples      NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH sample_range AS (
        SELECT slot_id, captured_at
        FROM pgfr_record.samples_ring
        WHERE captured_at BETWEEN p_start_time AND p_end_time
    ),
    total_samples AS (
        SELECT count(*) AS cnt FROM sample_range
    )
    SELECT
        w.backend_type,
        w.wait_event_type,
        w.wait_event,
        count(DISTINCT w.slot_id) AS sample_count,
        sum(w.count) AS total_waiters,
        round(avg(w.count), 2) AS avg_waiters,
        max(w.count) AS max_waiters,
        round(100.0 * count(DISTINCT w.slot_id) / NULLIF(t.cnt, 0), 1) AS pct_of_samples
    FROM pgfr_record.wait_samples_ring w
    JOIN sample_range sr ON sr.slot_id = w.slot_id
    CROSS JOIN total_samples t
    WHERE w.state NOT IN ('idle', 'idle in transaction')
    GROUP BY w.backend_type, w.wait_event_type, w.wait_event, t.cnt
    ORDER BY total_waiters DESC, sample_count DESC;
$$;
COMMENT ON FUNCTION pgfr_analyze.wait_summary(TIMESTAMPTZ, TIMESTAMPTZ) IS 'Summarizes wait events within a time range, grouped by backend type and wait event.';

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
COMMENT ON FUNCTION pgfr_analyze.statement_compare(TIMESTAMPTZ, TIMESTAMPTZ, DOUBLE PRECISION, INTEGER) IS 'Compares statement execution metrics between two snapshots, calculating performance deltas.';

-- Retrieves active session details at a specific point in time
