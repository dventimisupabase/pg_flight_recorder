-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Index usage analysis, both built on pgfr_record.deltas() over
-- pg_stat_all_indexes. Index size isn't a captured column anywhere (it's
-- never a pg_stat_* counter/gauge), so both read it live via
-- pg_relation_size(indexrelid) at call time rather than from a capture.

CREATE OR REPLACE FUNCTION pgfr_analyze.unused_indexes(p_lookback interval DEFAULT interval '7 days')
RETURNS TABLE(schemaname text, relname text, indexrelname text, index_size text, scan_delta bigint, recommendation text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col_defs text := pgfr_analyze._deltas_col_defs('pg_catalog.pg_stat_all_indexes');
    v_now      timestamptz := clock_timestamp();
    v_sql      text;
BEGIN
    IF v_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.unused_indexes: no payload schema minted yet for pg_stat_all_indexes';
    END IF;

    v_sql := format(
        $q$
        SELECT schemaname::text, relname::text, indexrelname::text,
               pg_size_pretty(pg_relation_size(indexrelid)),
               idx_scan_delta,
               CASE
                   WHEN idx_scan_delta = 0 THEN 'DROP INDEX (never used in ' || %1$L || ')'
                   WHEN idx_scan_delta < 10 THEN 'Consider dropping (rarely used)'
                   ELSE 'Keep (actively used)'
               END
        FROM pgfr_record.deltas('pg_catalog.pg_stat_all_indexes', %2$L::timestamptz, %3$L::timestamptz) AS d(%4$s)
        WHERE idx_scan_delta < 100 AND indexrelname NOT LIKE '%%_pkey'
        ORDER BY pg_relation_size(indexrelid) DESC
        $q$,
        p_lookback::text, v_now - p_lookback, v_now, v_col_defs
    );
    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.unused_indexes(interval) IS
    'Indexes with fewer than 100 scans over p_lookback (default 7 days), excluding primary keys, ordered by current size descending. index_size is read live via pg_relation_size(); scan_delta is from pg_stat_all_indexes deltas() over the window. recommendation: DROP INDEX when scan_delta is 0, consider dropping under 10, otherwise keep.';

CREATE OR REPLACE FUNCTION pgfr_analyze.index_efficiency(p_from_t timestamptz, p_to_t timestamptz, p_limit int DEFAULT 25)
RETURNS TABLE(
    schemaname          text,
    relname             text,
    indexrelname        text,
    idx_scan_delta      bigint,
    idx_tup_read_delta  bigint,
    idx_tup_fetch_delta bigint,
    selectivity         numeric,
    index_size          text,
    scans_per_gb        numeric
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col_defs text := pgfr_analyze._deltas_col_defs('pg_catalog.pg_stat_all_indexes');
    v_sql      text;
BEGIN
    IF v_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.index_efficiency: no payload schema minted yet for pg_stat_all_indexes';
    END IF;

    v_sql := format(
        $q$
        SELECT schemaname::text, relname::text, indexrelname::text,
               idx_scan_delta, idx_tup_read_delta, idx_tup_fetch_delta,
               CASE WHEN idx_tup_read_delta > 0 THEN round(100.0 * idx_tup_fetch_delta / idx_tup_read_delta, 1) ELSE NULL END,
               pg_size_pretty(pg_relation_size(indexrelid)),
               CASE WHEN pg_relation_size(indexrelid) > 0 THEN round(idx_scan_delta / (pg_relation_size(indexrelid) / 1073741824.0), 2) ELSE NULL END
        FROM pgfr_record.deltas('pg_catalog.pg_stat_all_indexes', %1$L::timestamptz, %2$L::timestamptz) AS d(%3$s)
        WHERE idx_scan_delta > 0
        ORDER BY idx_scan_delta DESC
        LIMIT %4$L
        $q$,
        p_from_t, p_to_t, v_col_defs, p_limit
    );
    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.index_efficiency(timestamptz, timestamptz, int) IS
    'The p_limit busiest indexes (by idx_scan delta) between p_from_t and p_to_t, from pg_stat_all_indexes deltas(). selectivity is idx_tup_fetch_delta as a percent of idx_tup_read_delta (low means many index entries read per row actually fetched); index_size and scans_per_gb read current size live via pg_relation_size().';
