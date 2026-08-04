-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

CREATE OR REPLACE FUNCTION pgfr_analyze.table_compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_limit INTEGER DEFAULT 25
)
RETURNS TABLE(
    schemaname              TEXT,
    relname                 TEXT,
    relid                   OID,
    seq_scan_delta          BIGINT,
    seq_tup_read_delta      BIGINT,
    idx_scan_delta          BIGINT,
    idx_tup_fetch_delta     BIGINT,
    n_tup_ins_delta         BIGINT,
    n_tup_upd_delta         BIGINT,
    n_tup_del_delta         BIGINT,
    n_tup_hot_upd_delta     BIGINT,
    dead_tup_pct            NUMERIC,
    vacuum_count_delta      BIGINT,
    autovacuum_count_delta  BIGINT,
    analyze_count_delta     BIGINT,
    autoanalyze_count_delta BIGINT,
    total_activity          BIGINT
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT DISTINCT ON (ts.relid) ts.*
        FROM pgfr_record.table_snapshots ts
        JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY ts.relid, s.captured_at DESC
    ),
    end_snap AS (
        SELECT DISTINCT ON (ts.relid) ts.*
        FROM pgfr_record.table_snapshots ts
        JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at >= p_end_time
        ORDER BY ts.relid, s.captured_at ASC
    ),
    matched AS (
        SELECT
            COALESCE(e.schemaname, split_part(e.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(e.relname, split_part(e.relid::regclass::text, '.', 2)) AS relname,
            e.relid,
            COALESCE(e.seq_scan, 0) - COALESCE(s.seq_scan, 0) AS seq_scan_delta,
            COALESCE(e.seq_tup_read, 0) - COALESCE(s.seq_tup_read, 0) AS seq_tup_read_delta,
            COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0) AS idx_scan_delta,
            COALESCE(e.idx_tup_fetch, 0) - COALESCE(s.idx_tup_fetch, 0) AS idx_tup_fetch_delta,
            COALESCE(e.n_tup_ins, 0) - COALESCE(s.n_tup_ins, 0) AS n_tup_ins_delta,
            COALESCE(e.n_tup_upd, 0) - COALESCE(s.n_tup_upd, 0) AS n_tup_upd_delta,
            COALESCE(e.n_tup_del, 0) - COALESCE(s.n_tup_del, 0) AS n_tup_del_delta,
            COALESCE(e.n_tup_hot_upd, 0) - COALESCE(s.n_tup_hot_upd, 0) AS n_tup_hot_upd_delta,
            e.n_live_tup,
            e.n_dead_tup,
            COALESCE(e.vacuum_count, 0) - COALESCE(s.vacuum_count, 0) AS vacuum_count_delta,
            COALESCE(e.autovacuum_count, 0) - COALESCE(s.autovacuum_count, 0) AS autovacuum_count_delta,
            COALESCE(e.analyze_count, 0) - COALESCE(s.analyze_count, 0) AS analyze_count_delta,
            COALESCE(e.autoanalyze_count, 0) - COALESCE(s.autoanalyze_count, 0) AS autoanalyze_count_delta
        FROM end_snap e
        LEFT JOIN start_snap s ON s.relid = e.relid
    )
    SELECT
        m.schemaname,
        m.relname,
        m.relid,
        m.seq_scan_delta,
        m.seq_tup_read_delta,
        m.idx_scan_delta,
        m.idx_tup_fetch_delta,
        m.n_tup_ins_delta,
        m.n_tup_upd_delta,
        m.n_tup_del_delta,
        m.n_tup_hot_upd_delta,
        CASE
            WHEN COALESCE(m.n_live_tup, 0) > 0
            THEN round(100.0 * COALESCE(m.n_dead_tup, 0) / (COALESCE(m.n_live_tup, 0) + COALESCE(m.n_dead_tup, 0)), 1)
            ELSE 0
        END AS dead_tup_pct,
        m.vacuum_count_delta,
        m.autovacuum_count_delta,
        m.analyze_count_delta,
        m.autoanalyze_count_delta,
        (m.seq_tup_read_delta + m.idx_tup_fetch_delta +
         m.n_tup_ins_delta + m.n_tup_upd_delta + m.n_tup_del_delta) AS total_activity
    FROM matched m
    WHERE (m.seq_tup_read_delta + m.idx_tup_fetch_delta +
           m.n_tup_ins_delta + m.n_tup_upd_delta + m.n_tup_del_delta) > 0
    ORDER BY total_activity DESC
    LIMIT p_limit
$$;
COMMENT ON FUNCTION pgfr_analyze.table_compare(TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) IS
'Compare table activity between two time points. Shows DML deltas, scan counts, dead tuple percentage, and maintenance events. Useful for identifying hot tables during incidents.

Output columns:
  schemaname: [dimension] [text] Schema of the table, from the end snapshot, falling back to parsing relid::regclass when the stored name is NULL.
  relname: [dimension] [text] Table name, from the end snapshot with regclass fallback.
  relid: [dimension] [oid] Table OID; the join key matching start and end snapshots.
  seq_scan_delta: [counter-delta] [count] Sequential scans (pg_stat_user_tables.seq_scan) between the last table snapshot at or before p_start_time and the first at or after p_end_time; when no start snapshot exists, the raw end counter is reported.
  seq_tup_read_delta: [counter-delta] [count] Rows read by sequential scans (seq_tup_read) over the comparison window.
  idx_scan_delta: [counter-delta] [count] Index scans against the table (idx_scan) over the comparison window.
  idx_tup_fetch_delta: [counter-delta] [count] Live rows fetched by index scans (idx_tup_fetch) over the comparison window.
  n_tup_ins_delta: [counter-delta] [count] Rows inserted (n_tup_ins) over the comparison window.
  n_tup_upd_delta: [counter-delta] [count] Rows updated (n_tup_upd) over the comparison window.
  n_tup_del_delta: [counter-delta] [count] Rows deleted (n_tup_del) over the comparison window.
  n_tup_hot_upd_delta: [counter-delta] [count] HOT updates (n_tup_hot_upd) over the comparison window.
  dead_tup_pct: [derived] [percent] Dead tuples as a percent of live plus dead tuples (n_dead_tup over n_live_tup + n_dead_tup, times 100) at the end snapshot only; both inputs are estimated gauges, and 0 is returned when n_live_tup is 0.
  vacuum_count_delta: [counter-delta] [count] Manual VACUUM runs (vacuum_count) over the comparison window.
  autovacuum_count_delta: [counter-delta] [count] Autovacuum runs (autovacuum_count) over the comparison window.
  analyze_count_delta: [counter-delta] [count] Manual ANALYZE runs (analyze_count) over the comparison window.
  autoanalyze_count_delta: [counter-delta] [count] Autoanalyze runs (autoanalyze_count) over the comparison window.
  total_activity: [derived] [count] Sum of seq_tup_read_delta, idx_tup_fetch_delta, n_tup_ins_delta, n_tup_upd_delta, and n_tup_del_delta over the comparison window; the ranking key, and rows where it is 0 are filtered out.';


-- Identifies table hotspots and potential issues
-- Returns actionable recommendations for tables with problems
CREATE OR REPLACE FUNCTION pgfr_analyze.table_hotspots(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    schemaname      TEXT,
    relname         TEXT,
    issue_type      TEXT,
    severity        TEXT,
    description     TEXT,
    recommendation  TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_table RECORD;
    v_hot_ratio NUMERIC;
BEGIN
    FOR v_table IN
        SELECT * FROM pgfr_analyze.table_compare(p_start_time, p_end_time, 100)
    LOOP
        -- High sequential scan activity
        IF v_table.seq_scan_delta > 100 AND v_table.seq_tup_read_delta > 100000 THEN
            schemaname := v_table.schemaname;
            relname := v_table.relname;
            issue_type := 'SEQUENTIAL_SCAN_STORM';
            severity := CASE
                WHEN v_table.seq_tup_read_delta > 10000000 THEN 'high'
                WHEN v_table.seq_tup_read_delta > 1000000 THEN 'medium'
                ELSE 'low'
            END;
            description := format('%s sequential scans reading %s tuples',
                                 v_table.seq_scan_delta,
                                 v_table.seq_tup_read_delta);
            recommendation := 'Consider adding an index or reviewing query WHERE clauses';
            RETURN NEXT;
        END IF;

        -- High dead tuple percentage (bloat)
        IF v_table.dead_tup_pct > 20 THEN
            schemaname := v_table.schemaname;
            relname := v_table.relname;
            issue_type := 'TABLE_BLOAT';
            severity := CASE
                WHEN v_table.dead_tup_pct > 50 THEN 'high'
                WHEN v_table.dead_tup_pct > 30 THEN 'medium'
                ELSE 'low'
            END;
            description := format('%s%% dead tuples', round(v_table.dead_tup_pct));
            recommendation := 'Run VACUUM or check autovacuum settings';
            RETURN NEXT;
        END IF;

        -- Low HOT update ratio (inefficient updates)
        IF v_table.n_tup_upd_delta > 1000 THEN
            v_hot_ratio := CASE
                WHEN v_table.n_tup_upd_delta > 0
                THEN 100.0 * v_table.n_tup_hot_upd_delta / v_table.n_tup_upd_delta
                ELSE 100
            END;

            IF v_hot_ratio < 50 THEN
                schemaname := v_table.schemaname;
                relname := v_table.relname;
                issue_type := 'LOW_HOT_UPDATE_RATIO';
                severity := 'medium';
                description := format('%s updates, only %s%% HOT',
                                     v_table.n_tup_upd_delta,
                                     round(v_hot_ratio, 1));
                recommendation := 'Consider increasing fillfactor or reducing indexed columns';
                RETURN NEXT;
            END IF;
        END IF;

        -- Frequent autovacuum (indicates high churn)
        IF v_table.autovacuum_count_delta > 5 THEN
            schemaname := v_table.schemaname;
            relname := v_table.relname;
            issue_type := 'HIGH_AUTOVACUUM_FREQUENCY';
            severity := 'low';
            description := format('%s autovacuums during period',
                                 v_table.autovacuum_count_delta);
            recommendation := 'High write activity detected; ensure autovacuum keeps up';
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.table_hotspots(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Identify table-level hotspots and issues. Returns actionable recommendations for sequential scan storms, table bloat, low HOT update ratios, and frequent autovacuum activity.

Output columns:
  schemaname: [dimension] [text] Schema of the flagged table.
  relname: [dimension] [text] Name of the flagged table.
  issue_type: [derived] [text] Detected issue class: SEQUENTIAL_SCAN_STORM, TABLE_BLOAT, LOW_HOT_UPDATE_RATIO, or HIGH_AUTOVACUUM_FREQUENCY, from fixed thresholds on table_compare() output between p_start_time and p_end_time.
  severity: [derived] [text] low, medium, or high, from magnitude thresholds on the triggering metric (tuples read, dead tuple percent, HOT ratio, autovacuum count).
  description: [derived] [text] Formatted evidence for the issue: scan and tuple-read counts, dead tuples as a percent of live plus dead tuples, HOT updates as a percent of all updates, or autovacuum count over the period.
  recommendation: [derived] [text] Suggested remediation for the issue type.';


-- =============================================================================
-- INDEX USAGE TRACKING ANALYSIS FUNCTIONS
-- =============================================================================

-- Identifies unused or rarely used indexes
-- Returns indexes that may be candidates for removal
