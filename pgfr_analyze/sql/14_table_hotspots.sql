-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- table_hotspots(): four fixed threshold checks over pg_stat_all_tables
-- deltas() in the window -- sequential scan storms, table bloat (dead
-- tuple percent), low HOT-update ratio, and high autovacuum frequency.
-- Built directly on pgfr_record.deltas(); no separate "table_compare()"
-- wrapper is needed since deltas() itself already is that comparison.

CREATE OR REPLACE FUNCTION pgfr_analyze.table_hotspots(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(schemaname text, relname text, issue_type text, severity text, description text, recommendation text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col_defs text := pgfr_analyze._deltas_col_defs('pg_catalog.pg_stat_all_tables');
    v_sql      text;
BEGIN
    IF v_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.table_hotspots: no payload schema minted yet for pg_stat_all_tables';
    END IF;

    v_sql := format(
        $q$
        WITH t AS (
            SELECT *,
                CASE WHEN n_live_tup + n_dead_tup > 0 THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 1) ELSE 0 END AS dead_tup_pct,
                CASE WHEN n_tup_upd_delta > 0 THEN round(100.0 * n_tup_hot_upd_delta / n_tup_upd_delta, 1) ELSE 100 END AS hot_ratio
            FROM pgfr_record.deltas('pg_catalog.pg_stat_all_tables', %1$L::timestamptz, %2$L::timestamptz) AS d(%3$s)
        )
        SELECT schemaname::text, relname::text,
            'SEQUENTIAL_SCAN_STORM',
            CASE WHEN seq_tup_read_delta > 10000000 THEN 'high' WHEN seq_tup_read_delta > 1000000 THEN 'medium' ELSE 'low' END,
            format('%%s sequential scans reading %%s tuples', seq_scan_delta, seq_tup_read_delta),
            'Consider adding an index or reviewing query WHERE clauses'
        FROM t WHERE seq_scan_delta > 100 AND seq_tup_read_delta > 100000
        UNION ALL
        SELECT schemaname::text, relname::text,
            'TABLE_BLOAT',
            CASE WHEN dead_tup_pct > 50 THEN 'high' WHEN dead_tup_pct > 30 THEN 'medium' ELSE 'low' END,
            format('%%s%%%% dead tuples', dead_tup_pct),
            'Run VACUUM or check autovacuum settings'
        FROM t WHERE dead_tup_pct > 20
        UNION ALL
        SELECT schemaname::text, relname::text,
            'LOW_HOT_UPDATE_RATIO', 'medium',
            format('%%s updates, only %%s%%%% HOT', n_tup_upd_delta, hot_ratio),
            'Consider increasing fillfactor or reducing indexed columns'
        FROM t WHERE n_tup_upd_delta > 1000 AND hot_ratio < 50
        UNION ALL
        SELECT schemaname::text, relname::text,
            'HIGH_AUTOVACUUM_FREQUENCY', 'low',
            format('%%s autovacuums during period', autovacuum_count_delta),
            'High write activity detected; ensure autovacuum keeps up'
        FROM t WHERE autovacuum_count_delta > 5
        $q$,
        p_from_t, p_to_t, v_col_defs
    );
    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.table_hotspots(timestamptz, timestamptz) IS
    'Table-level hotspots between p_from_t and p_to_t, from fixed thresholds on pg_stat_all_tables deltas(): SEQUENTIAL_SCAN_STORM (>100 seq scans reading >100k tuples), TABLE_BLOAT (>20% dead tuples), LOW_HOT_UPDATE_RATIO (>1000 updates, <50% HOT), HIGH_AUTOVACUUM_FREQUENCY (>5 autovacuums in the window). A table can appear more than once if it trips more than one check.';
