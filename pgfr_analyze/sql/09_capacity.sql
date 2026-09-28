-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Capacity views: capacity_summary(from_t, to_t) reports utilization
-- against a provisioned or reference capacity for each resource dimension
-- pgfr_record actually captures, one row per dimension with data in the
-- window. Thresholds and the buffer-pressure/temp-spill reference points
-- match anomaly_report()'s own bands, so the two stay consistent with each
-- other. Buffer pressure is version-split at the source exactly as in
-- anomaly_report() (PG17+ reads pg_stat_io in place of pg_stat_bgwriter's
-- removed buffers_backend column).

CREATE OR REPLACE FUNCTION pgfr_analyze.capacity_summary(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(
    metric               text,
    current_usage        text,
    provisioned_capacity  text,
    utilization_pct       numeric,
    headroom_pct          numeric,
    status                text,
    recommendation        text
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_buf_source    text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'pg_catalog.pg_stat_io' ELSE 'pg_catalog.pg_stat_bgwriter' END;
    v_buf_col_defs  text := pgfr_analyze._deltas_col_defs(v_buf_source);
    v_db_col_defs   text := pgfr_analyze._deltas_col_defs('pg_catalog.pg_stat_database');
    v_peak_conn     bigint;
    v_max_conn      int := current_setting('max_connections')::int;
    v_buf_writes    numeric;
    v_temp_bytes    numeric;
    v_blks_hit      numeric;
    v_blks_read     numeric;
    v_hit_pct       numeric;
    v_xact_total    numeric;
    v_window_secs   numeric := extract(epoch FROM (p_to_t - p_from_t));
    v_sql           text;
BEGIN
    IF v_buf_col_defs IS NULL OR v_db_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.capacity_summary: no payload schema minted yet for pg_stat_bgwriter/pg_stat_io or pg_stat_database';
    END IF;

    -- Connections: peak concurrent backends (summed across databases at
    -- each capture tick) against max_connections.
    SELECT max(tick_total) INTO v_peak_conn
    FROM (
        SELECT sum(numbackends) AS tick_total
        FROM pgfr_record.v_pg_stat_database
        WHERE captured_at BETWEEN p_from_t AND p_to_t
        GROUP BY captured_at
    ) t;

    IF v_peak_conn IS NOT NULL THEN
        metric := 'connections';
        current_usage := format('%s peak concurrent backends', v_peak_conn);
        provisioned_capacity := v_max_conn::text;
        utilization_pct := least(100, round(v_peak_conn::numeric / nullif(v_max_conn, 0) * 100, 1));
        headroom_pct := round(greatest(0, 100 - utilization_pct), 1);
        status := CASE WHEN utilization_pct >= 90 THEN 'critical' WHEN utilization_pct >= 60 THEN 'warning' ELSE 'healthy' END;
        recommendation := CASE
            WHEN utilization_pct >= 90 THEN 'Peak connections are close to max_connections; raise max_connections or add connection pooling (e.g. PgBouncer)'
            WHEN utilization_pct >= 60 THEN 'Peak connections are using a majority of max_connections; monitor the trend and consider pooling'
            ELSE 'Peak connections have ample headroom against max_connections'
        END;
        RETURN NEXT;
    END IF;

    -- Buffer pressure (shared_buffers proxy): backend-written buffers in
    -- the window, against the same 1000-buffer HIGH reference as
    -- anomaly_report()'s BUFFER_PRESSURE check.
    IF pgfr_record._current_major() >= 17 THEN
        v_sql := format(
            $q$SELECT sum(writes_delta) FROM pgfr_record.deltas(%1$L, %2$L::timestamptz, %3$L::timestamptz) AS d(%4$s) WHERE backend_type = 'client backend'$q$,
            v_buf_source, p_from_t, p_to_t, v_buf_col_defs
        );
    ELSE
        v_sql := format(
            $q$SELECT buffers_backend_delta FROM pgfr_record.deltas(%1$L, %2$L::timestamptz, %3$L::timestamptz) AS d(%4$s)$q$,
            v_buf_source, p_from_t, p_to_t, v_buf_col_defs
        );
    END IF;
    EXECUTE v_sql INTO v_buf_writes;

    IF v_buf_writes IS NOT NULL THEN
        metric := 'memory_shared_buffers';
        current_usage := format('%s backend-written buffers in the window', v_buf_writes);
        provisioned_capacity := current_setting('shared_buffers');
        utilization_pct := least(100, round(v_buf_writes / 1000.0 * 100, 1));
        headroom_pct := round(greatest(0, 100 - utilization_pct), 1);
        status := CASE WHEN utilization_pct >= 100 THEN 'critical' WHEN utilization_pct >= 10 THEN 'warning' ELSE 'healthy' END;
        recommendation := CASE
            WHEN utilization_pct >= 100 THEN 'Backends are writing their own dirty buffers heavily; raise shared_buffers or bgwriter_lru_maxpages'
            WHEN utilization_pct >= 10 THEN 'Backends are writing some of their own dirty buffers; monitor the trend'
            ELSE 'bgwriter/checkpointer are keeping up; no backend buffer-write pressure'
        END;
        RETURN NEXT;
    END IF;

    -- Temp file spills (work_mem proxy), against the same 1GiB HIGH
    -- reference as anomaly_report()'s TEMP_FILE_SPILLS check.
    v_sql := format(
        $q$SELECT sum(temp_bytes_delta) FROM pgfr_record.deltas('pg_catalog.pg_stat_database', %L::timestamptz, %L::timestamptz) AS d(%s)$q$,
        p_from_t, p_to_t, v_db_col_defs
    );
    EXECUTE v_sql INTO v_temp_bytes;

    IF v_temp_bytes IS NOT NULL THEN
        metric := 'memory_work_mem';
        current_usage := format('%s spilled to temp files in the window', pg_size_pretty(v_temp_bytes));
        provisioned_capacity := current_setting('work_mem');
        utilization_pct := least(100, round(v_temp_bytes / 1073741824.0 * 100, 1));
        headroom_pct := round(greatest(0, 100 - utilization_pct), 1);
        status := CASE WHEN utilization_pct >= 100 THEN 'critical' WHEN utilization_pct >= 10 THEN 'warning' ELSE 'healthy' END;
        recommendation := CASE
            WHEN utilization_pct >= 100 THEN 'Heavy temp file spillage; raise work_mem or investigate the specific queries spilling via pg_stat_statements'
            WHEN utilization_pct >= 10 THEN 'Some temp file spillage; monitor the trend and consider raising work_mem'
            ELSE 'Minimal temp file spillage; work_mem appears adequate'
        END;
        RETURN NEXT;
    END IF;

    -- Cache hit ratio: block read misses against shared_buffers, summed
    -- across every database in the window.
    v_sql := format(
        $q$SELECT sum(blks_hit_delta), sum(blks_read_delta) FROM pgfr_record.deltas('pg_catalog.pg_stat_database', %L::timestamptz, %L::timestamptz) AS d(%s)$q$,
        p_from_t, p_to_t, v_db_col_defs
    );
    EXECUTE v_sql INTO v_blks_hit, v_blks_read;

    IF v_blks_hit IS NOT NULL AND (v_blks_hit + v_blks_read) > 0 THEN
        v_hit_pct := round(v_blks_hit / (v_blks_hit + v_blks_read) * 100, 2);
        metric := 'io_buffer_cache';
        current_usage := format('%s%% cache hit ratio (%s reads, %s hits)', v_hit_pct, v_blks_read, v_blks_hit);
        provisioned_capacity := 'target: 95%+ hit ratio';
        utilization_pct := round(100 - v_hit_pct, 1);
        headroom_pct := round(greatest(0, 100 - utilization_pct), 1);
        status := CASE WHEN v_hit_pct < 80 THEN 'critical' WHEN v_hit_pct < 95 THEN 'warning' ELSE 'healthy' END;
        recommendation := CASE
            WHEN v_hit_pct < 80 THEN 'Cache hit ratio is poor; raise shared_buffers or investigate queries driving heavy disk reads'
            WHEN v_hit_pct < 95 THEN 'Cache hit ratio is below the 95% target; consider raising shared_buffers'
            ELSE 'Cache hit ratio is healthy'
        END;
        RETURN NEXT;
    END IF;

    -- Transaction rate: informational, no fixed provisioned capacity.
    v_sql := format(
        $q$SELECT sum(xact_commit_delta + xact_rollback_delta) FROM pgfr_record.deltas('pg_catalog.pg_stat_database', %L::timestamptz, %L::timestamptz) AS d(%s)$q$,
        p_from_t, p_to_t, v_db_col_defs
    );
    EXECUTE v_sql INTO v_xact_total;

    IF v_xact_total IS NOT NULL AND v_window_secs > 0 THEN
        metric := 'transaction_rate';
        current_usage := format('%s transactions in the window (%s tps avg)', v_xact_total, round(v_xact_total / v_window_secs, 1));
        provisioned_capacity := 'workload dependent';
        utilization_pct := NULL;
        headroom_pct := NULL;
        status := CASE WHEN (v_xact_total / v_window_secs) >= 5000 THEN 'warning' ELSE 'healthy' END;
        recommendation := CASE
            WHEN (v_xact_total / v_window_secs) >= 5000 THEN 'High transaction rate; ensure connection pooling and CPU/I/O capacity keep pace'
            ELSE 'Transaction rate is within a normal range'
        END;
        RETURN NEXT;
    END IF;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.capacity_summary(timestamptz, timestamptz) IS
    'Utilization against a provisioned or reference capacity for each resource dimension pgfr_record captures (connections vs max_connections, backend buffer writes vs shared_buffers, temp spills vs work_mem, cache hit ratio, transaction rate), one row per dimension with data in the window. Buffer-pressure and temp-spill reference points match anomaly_report()''s own thresholds.';
