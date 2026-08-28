-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Anomaly detection: anomaly_report(from_t, to_t) returns every flagged
-- anomaly across a growing set of checks, each built on pgfr_record.deltas()
-- or a current-state read, never on a new capture. Checkpoint activity is
-- version-split at the source (PG15/16 keep it on pg_stat_bgwriter, PG17+
-- moves it to pg_stat_checkpointer, renaming checkpoints_req -> num_requested
-- and checkpoint_write_time -> write_time along the way); backend-buffer
-- pressure is version-split too (PG15/16 read buffers_backend/
-- buffers_backend_fsync straight off pg_stat_bgwriter; PG17+ removes both
-- columns entirely in favor of pg_stat_io, so the same signal comes from
-- summing writes/fsyncs across every client-backend row there). This
-- function reads whichever view, column names, and shape actually apply on
-- the running major via pgfr_record._current_major(), rather than assuming
-- one.

CREATE OR REPLACE FUNCTION pgfr_analyze.anomaly_report(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(anomaly_type text, severity text, description text, metric_value numeric, threshold numeric, recommendation text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ckpt_view      text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'pg_catalog.pg_stat_checkpointer' ELSE 'pg_catalog.pg_stat_bgwriter' END;
    v_req_col        text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'num_requested' ELSE 'checkpoints_req' END;
    v_wt_col         text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'write_time' ELSE 'checkpoint_write_time' END;
    v_ckpt_col_defs  text := pgfr_analyze._deltas_col_defs(v_ckpt_view);
    v_buf_source     text := CASE WHEN pgfr_record._current_major() >= 17 THEN 'pg_catalog.pg_stat_io' ELSE 'pg_catalog.pg_stat_bgwriter' END;
    v_buf_col_defs   text := pgfr_analyze._deltas_col_defs(v_buf_source);
    v_db_col_defs    text := pgfr_analyze._deltas_col_defs('pg_catalog.pg_stat_database');
    v_sql            text;
BEGIN
    IF v_ckpt_col_defs IS NULL OR v_buf_col_defs IS NULL OR v_db_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.anomaly_report: no payload schema minted yet for pg_stat_bgwriter/pg_stat_checkpointer, pg_stat_io, or pg_stat_database';
    END IF;

    -- Checkpoint anomalies: forced (non-timed) checkpoints, and long
    -- cumulative checkpoint write time. [hardcoded] bands, matching v1.
    v_sql := format(
        $q$
        SELECT
            'FORCED_CHECKPOINTS', 'HIGH',
            format('%%s forced (non-timed) checkpoint(s) in the window', %1$I),
            %1$I::numeric, 0::numeric,
            'Forced checkpoints mean WAL volume is outpacing checkpoint_timeout; consider raising max_wal_size'
        FROM pgfr_record.deltas(%2$L, %3$L::timestamptz, %4$L::timestamptz) AS d(%5$s)
        WHERE %1$I > 0
        UNION ALL
        SELECT
            'CHECKPOINT_WRITE_TIME_HIGH',
            CASE WHEN %6$I > 30000 THEN 'HIGH' ELSE 'MEDIUM' END,
            format('Cumulative checkpoint write time was %%s ms in the window', round(%6$I::numeric, 0)),
            %6$I::numeric, 10000::numeric,
            'Consider spreading checkpoint I/O further with a higher checkpoint_completion_target'
        FROM pgfr_record.deltas(%2$L, %3$L::timestamptz, %4$L::timestamptz) AS d(%5$s)
        WHERE %6$I > 10000
        $q$,
        v_req_col || '_delta',
        v_ckpt_view, p_from_t, p_to_t, v_ckpt_col_defs,
        v_wt_col || '_delta'
    );
    RETURN QUERY EXECUTE v_sql;

    -- Buffer pressure: backends writing their own dirty buffers (bgwriter/
    -- checkpointer falling behind), and any backend-forced fsync at all.
    IF pgfr_record._current_major() >= 17 THEN
        v_sql := format(
            $q$
            SELECT
                'BUFFER_PRESSURE',
                CASE WHEN sum(writes_delta) > 1000 THEN 'HIGH' ELSE 'MEDIUM' END,
                format('Backends wrote %%s of their own dirty buffers in the window (bgwriter/checkpointer falling behind)', sum(writes_delta)),
                sum(writes_delta)::numeric, 100::numeric,
                'Consider raising bgwriter_lru_maxpages or checkpoint frequency'
            FROM pgfr_record.deltas(%1$L, %2$L::timestamptz, %3$L::timestamptz) AS d(%4$s)
            WHERE backend_type = 'client backend'
            HAVING sum(writes_delta) > 100
            UNION ALL
            SELECT
                'BACKEND_FSYNC', 'HIGH',
                format('Backends had to fsync their own writes %%s time(s) in the window', sum(fsyncs_delta)),
                sum(fsyncs_delta)::numeric, 0::numeric,
                'The OS fsync request queue is full; investigate I/O subsystem saturation'
            FROM pgfr_record.deltas(%1$L, %2$L::timestamptz, %3$L::timestamptz) AS d(%4$s)
            WHERE backend_type = 'client backend'
            HAVING sum(fsyncs_delta) > 0
            $q$,
            v_buf_source, p_from_t, p_to_t, v_buf_col_defs
        );
    ELSE
        v_sql := format(
            $q$
            SELECT
                'BUFFER_PRESSURE',
                CASE WHEN buffers_backend_delta > 1000 THEN 'HIGH' ELSE 'MEDIUM' END,
                format('Backends wrote %%s of their own dirty buffers in the window (bgwriter/checkpointer falling behind)', buffers_backend_delta),
                buffers_backend_delta::numeric, 100::numeric,
                'Consider raising bgwriter_lru_maxpages or checkpoint frequency'
            FROM pgfr_record.deltas(%1$L, %2$L::timestamptz, %3$L::timestamptz) AS d(%4$s)
            WHERE buffers_backend_delta > 100
            UNION ALL
            SELECT
                'BACKEND_FSYNC', 'HIGH',
                format('Backends had to fsync their own writes %%s time(s) in the window', buffers_backend_fsync_delta),
                buffers_backend_fsync_delta::numeric, 0::numeric,
                'The OS fsync request queue is full; investigate I/O subsystem saturation'
            FROM pgfr_record.deltas(%1$L, %2$L::timestamptz, %3$L::timestamptz) AS d(%4$s)
            WHERE buffers_backend_fsync_delta > 0
            $q$,
            v_buf_source, p_from_t, p_to_t, v_buf_col_defs
        );
    END IF;
    RETURN QUERY EXECUTE v_sql;

    -- Temp file spills: summed across all databases in the window.
    v_sql := format(
        $q$
        SELECT
            'TEMP_FILE_SPILLS',
            CASE WHEN sum(temp_bytes_delta) > 1073741824 THEN 'HIGH' ELSE 'MEDIUM' END,
            format('%%s of temp files spilled to disk across %%s file(s) in the window', pg_size_pretty(sum(temp_bytes_delta)), sum(temp_files_delta)),
            sum(temp_bytes_delta)::numeric, 104857600::numeric,
            'Consider raising work_mem, or investigate the specific queries spilling via pg_stat_statements'
        FROM pgfr_record.deltas('pg_catalog.pg_stat_database', %L::timestamptz, %L::timestamptz) AS d(%s)
        HAVING sum(temp_bytes_delta) > 104857600
        $q$,
        p_from_t, p_to_t, v_db_col_defs
    );
    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.anomaly_report(timestamptz, timestamptz) IS
    'Every anomaly flagged between p_from_t and p_to_t, across a growing set of checks (currently: forced checkpoints, checkpoint write time, buffer pressure, backend fsync, temp file spills), each built on pgfr_record.deltas() or a current-state read.';
