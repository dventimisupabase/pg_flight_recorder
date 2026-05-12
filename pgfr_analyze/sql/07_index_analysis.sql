-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

CREATE OR REPLACE FUNCTION pgfr_analyze.unused_indexes(
    p_lookback_interval INTERVAL DEFAULT '7 days'
)
RETURNS TABLE(
    schemaname      TEXT,
    relname         TEXT,
    indexrelname    TEXT,
    index_size      TEXT,
    last_scan_count BIGINT,
    recommendation  TEXT
)
LANGUAGE sql STABLE AS $$
    WITH latest_snapshot AS (
        SELECT max(id) AS snapshot_id
        FROM pgfr_record.snapshots
        WHERE captured_at > now() - p_lookback_interval
    ),
    earliest_snapshot AS (
        SELECT min(id) AS snapshot_id
        FROM pgfr_record.snapshots
        WHERE captured_at > now() - p_lookback_interval
    ),
    index_usage AS (
        SELECT
            COALESCE(e.schemaname, split_part(e.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(e.relname, split_part(e.relid::regclass::text, '.', 2)) AS relname,
            COALESCE(e.indexrelname, split_part(e.indexrelid::regclass::text, '.', 2)) AS indexrelname,
            e.indexrelid,
            e.index_size_bytes,
            COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0) AS scan_delta
        FROM pgfr_record.index_snapshots e
        CROSS JOIN latest_snapshot ls
        LEFT JOIN pgfr_record.index_snapshots s
            ON s.indexrelid = e.indexrelid
            AND s.snapshot_id = (SELECT snapshot_id FROM earliest_snapshot)
        WHERE e.snapshot_id = ls.snapshot_id
    )
    SELECT
        iu.schemaname,
        iu.relname,
        iu.indexrelname,
        pgfr_record._pretty_bytes(iu.index_size_bytes) AS index_size,
        iu.scan_delta AS last_scan_count,
        CASE
            WHEN iu.scan_delta = 0 THEN 'DROP INDEX (never used in ' || p_lookback_interval::text || ')'
            WHEN iu.scan_delta < 10 THEN 'Consider dropping (rarely used)'
            ELSE 'Keep (actively used)'
        END AS recommendation
    FROM index_usage iu
    WHERE iu.scan_delta < 100  -- Threshold for "rarely used"
        AND iu.indexrelname NOT LIKE '%_pkey'  -- Don't suggest dropping primary keys
    ORDER BY iu.index_size_bytes DESC
$$;
COMMENT ON FUNCTION pgfr_analyze.unused_indexes(INTERVAL) IS
'Identify unused or rarely used indexes. Returns indexes that may be candidates for removal to save space and improve write performance. Default lookback is 7 days.';


-- Analyzes index efficiency and usage patterns
-- Returns selectivity and scans-per-GB metrics
CREATE OR REPLACE FUNCTION pgfr_analyze.index_efficiency(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_limit INTEGER DEFAULT 25
)
RETURNS TABLE(
    schemaname          TEXT,
    relname             TEXT,
    indexrelname        TEXT,
    idx_scan_delta      BIGINT,
    idx_tup_read_delta  BIGINT,
    idx_tup_fetch_delta BIGINT,
    selectivity         NUMERIC,
    index_size          TEXT,
    scans_per_gb        NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT DISTINCT ON (i.indexrelid) i.*
        FROM pgfr_record.index_snapshots i
        JOIN pgfr_record.snapshots s ON s.id = i.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY i.indexrelid, s.captured_at DESC
    ),
    end_snap AS (
        SELECT DISTINCT ON (i.indexrelid) i.*
        FROM pgfr_record.index_snapshots i
        JOIN pgfr_record.snapshots s ON s.id = i.snapshot_id
        WHERE s.captured_at >= p_end_time
        ORDER BY i.indexrelid, s.captured_at ASC
    )
    SELECT
        COALESCE(e.schemaname, split_part(e.relid::regclass::text, '.', 1)) AS schemaname,
        COALESCE(e.relname, split_part(e.relid::regclass::text, '.', 2)) AS relname,
        COALESCE(e.indexrelname, split_part(e.indexrelid::regclass::text, '.', 2)) AS indexrelname,
        COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0) AS idx_scan_delta,
        COALESCE(e.idx_tup_read, 0) - COALESCE(s.idx_tup_read, 0) AS idx_tup_read_delta,
        COALESCE(e.idx_tup_fetch, 0) - COALESCE(s.idx_tup_fetch, 0) AS idx_tup_fetch_delta,
        CASE
            WHEN (COALESCE(e.idx_tup_read, 0) - COALESCE(s.idx_tup_read, 0)) > 0
            THEN round(100.0 * (COALESCE(e.idx_tup_fetch, 0) - COALESCE(s.idx_tup_fetch, 0)) /
                             (COALESCE(e.idx_tup_read, 0) - COALESCE(s.idx_tup_read, 0)), 1)
            ELSE NULL
        END AS selectivity,
        pgfr_record._pretty_bytes(e.index_size_bytes) AS index_size,
        CASE
            WHEN COALESCE(e.index_size_bytes, 0) > 0
            THEN round((COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0)) /
                      (e.index_size_bytes / 1073741824.0::numeric), 2)
            ELSE NULL
        END AS scans_per_gb
    FROM end_snap e
    LEFT JOIN start_snap s ON s.indexrelid = e.indexrelid
    WHERE (COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0)) > 0
    ORDER BY idx_scan_delta DESC
    LIMIT p_limit
$$;
COMMENT ON FUNCTION pgfr_analyze.index_efficiency(TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) IS
'Analyze index efficiency and usage patterns. Returns selectivity (fetch/read ratio) and scans-per-GB metrics. Low selectivity may indicate poor index choices.';


-- =============================================================================
-- CONFIGURATION SNAPSHOT ANALYSIS FUNCTIONS
-- =============================================================================

-- Detects configuration changes between two time points
-- Returns parameters that changed with old and new values
