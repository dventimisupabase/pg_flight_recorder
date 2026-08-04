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
'Identify unused or rarely used indexes. Returns indexes that may be candidates for removal to save space and improve write performance. Default lookback is 7 days.

Output columns:
  schemaname: [dimension] [text] Schema of the table the index belongs to, falling back to parsing relid::regclass when the stored name is NULL.
  relname: [dimension] [text] Table the index belongs to, with regclass fallback.
  indexrelname: [dimension] [text] Index name, with regclass fallback; primary key indexes (names ending in _pkey) are excluded.
  index_size: [derived] [text] Pretty-printed rendering of the index_size_bytes gauge from the latest snapshot in the lookback window.
  last_scan_count: [counter-delta] [count] idx_scan delta between the earliest and latest snapshots inside the lookback window; despite the name it is a count of index scans over the window, not a timestamp. Only indexes with fewer than 100 scans are returned.
  recommendation: [derived] [text] Drop or keep advice from thresholds on last_scan_count: 0 scans suggests DROP INDEX, under 10 suggests considering a drop, otherwise keep.';


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
'Analyze index efficiency and usage patterns. Returns selectivity (fetch/read ratio) and scans-per-GB metrics. Low selectivity may indicate poor index choices.

Output columns:
  schemaname: [dimension] [text] Schema of the table the index belongs to, from the end snapshot, falling back to parsing relid::regclass when the stored name is NULL.
  relname: [dimension] [text] Table the index belongs to, from the end snapshot with regclass fallback.
  indexrelname: [dimension] [text] Index name, from the end snapshot with regclass fallback.
  idx_scan_delta: [counter-delta] [count] Index scans (pg_stat_user_indexes.idx_scan) between the last index snapshot at or before p_start_time and the first at or after p_end_time; only indexes with a positive delta are returned, and a missing start snapshot makes this the raw end counter.
  idx_tup_read_delta: [counter-delta] [count] Index entries returned by scans (idx_tup_read) over the comparison window.
  idx_tup_fetch_delta: [counter-delta] [count] Live table rows fetched by index scans (idx_tup_fetch) over the comparison window.
  selectivity: [derived] [percent] idx_tup_fetch_delta as a percent of idx_tup_read_delta over the comparison window, a ratio of two exact counter deltas; NULL when idx_tup_read_delta is 0. Low values mean many index entries are read per live row actually fetched.
  index_size: [derived] [text] Pretty-printed rendering of the index_size_bytes gauge from the end snapshot.
  scans_per_gb: [derived] [count/gb] idx_scan_delta divided by the end-snapshot index size in GB (index_size_bytes over 1073741824): index scans over the comparison window per GB of index; NULL when the size is 0 or NULL.';


-- =============================================================================
-- CONFIGURATION SNAPSHOT ANALYSIS FUNCTIONS
-- =============================================================================

-- Detects configuration changes between two time points
-- Returns parameters that changed with old and new values
