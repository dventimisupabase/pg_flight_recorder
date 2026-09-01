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
    v_activity_col_defs text := pgfr_analyze._state_col_defs('pg_catalog.pg_stat_activity');
    v_tables_col_defs   text := pgfr_analyze._state_col_defs('pg_catalog.pg_stat_all_tables');
    v_repl_col_defs  text := pgfr_analyze._state_col_defs('pg_catalog.pg_stat_replication');
    v_slots_col_defs text := pgfr_analyze._state_col_defs('pg_catalog.pg_replication_slots');
    v_pgdb_col_defs  text := pgfr_analyze._state_col_defs('pg_catalog.pg_database');
    v_cat_col_defs   text := pgfr_analyze._state_col_defs('pgfr_record.src_catalog_identity');
    v_sql            text;
BEGIN
    IF v_ckpt_col_defs IS NULL OR v_buf_col_defs IS NULL OR v_db_col_defs IS NULL
       OR v_activity_col_defs IS NULL OR v_tables_col_defs IS NULL
       OR v_repl_col_defs IS NULL OR v_slots_col_defs IS NULL
       OR v_pgdb_col_defs IS NULL OR v_cat_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.anomaly_report: no payload schema minted yet for one or more of pg_stat_bgwriter/pg_stat_checkpointer, pg_stat_io, pg_stat_database, pg_stat_activity, pg_stat_all_tables, pg_stat_replication, pg_replication_slots, pg_database, src_catalog_identity';
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

    -- Idle-in-transaction: a backend holding an open transaction without
    -- doing anything, blocking vacuum's xmin horizon and holding locks.
    -- Current-state read via latest_state(p_to_t), not deltas() -- state
    -- and xact_start are gauges, not counters; latest_state(), not
    -- state_as_of(), since a disconnected backend must actually disappear.
    v_sql := format(
        $q$
        SELECT
            'IDLE_IN_TRANSACTION',
            CASE WHEN %2$L::timestamptz - xact_start > interval '30 minutes' THEN 'HIGH' ELSE 'MEDIUM' END,
            format('Backend %%s (user %%s) has been idle in transaction for %%s', pid, usename, (age(%2$L::timestamptz, xact_start))::text),
            extract(epoch FROM (%2$L::timestamptz - xact_start))::numeric, 300::numeric,
            'Investigate the client holding this transaction open; a long idle transaction blocks vacuum''s xmin horizon and can hold locks'
        FROM pgfr_record.latest_state(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE state = 'idle in transaction' AND %2$L::timestamptz - xact_start > interval '5 minutes'
        $q$,
        'pg_catalog.pg_stat_activity', p_to_t, v_activity_col_defs
    );
    RETURN QUERY EXECUTE v_sql;

    -- Lock contention: a backend blocked waiting on a lock. This flags the
    -- wait itself (wait_event_type = 'Lock', already unencoded on
    -- pg_stat_activity); identifying the blocking session is forensics
    -- work (pg_locks joined to pg_stat_activity by pid at equal
    -- captured_at), deliberately out of scope for this threshold check.
    v_sql := format(
        $q$
        SELECT
            'LOCK_CONTENTION',
            CASE WHEN %2$L::timestamptz - query_start > interval '1 minute' THEN 'HIGH' ELSE 'MEDIUM' END,
            format('Backend %%s (user %%s) has been waiting on a lock for %%s (query: %%s)', pid, usename, (age(%2$L::timestamptz, query_start))::text, left(query, 120)),
            extract(epoch FROM (%2$L::timestamptz - query_start))::numeric, 10::numeric,
            'Identify the blocking session via pg_locks/pg_stat_activity, and consider a shorter lock_timeout or breaking up long-held locking transactions'
        FROM pgfr_record.latest_state(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE wait_event_type = 'Lock' AND %2$L::timestamptz - query_start > interval '10 seconds'
        $q$,
        'pg_catalog.pg_stat_activity', p_to_t, v_activity_col_defs
    );
    RETURN QUERY EXECUTE v_sql;

    -- Connection leak: backends sitting idle (not in a transaction) for a
    -- long time, suggesting a connection pool isn't releasing them.
    v_sql := format(
        $q$
        SELECT
            'CONNECTION_LEAK',
            CASE WHEN count(*) > 50 THEN 'HIGH' ELSE 'MEDIUM' END,
            format('%%s backend(s) have been idle for over an hour', count(*)),
            count(*)::numeric, 20::numeric,
            'Investigate whether the application''s connection pool is releasing connections; consider a lower idle_session_timeout'
        FROM pgfr_record.latest_state(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE state = 'idle' AND %2$L::timestamptz - state_change > interval '1 hour'
        HAVING count(*) > 20
        $q$,
        'pg_catalog.pg_stat_activity', p_to_t, v_activity_col_defs
    );
    RETURN QUERY EXECUTE v_sql;

    -- Dead tuple accumulation: relations where dead tuples make up a large
    -- share of live + dead tuples. Current-state read -- n_live_tup/
    -- n_dead_tup are gauges, not counters.
    v_sql := format(
        $q$
        SELECT
            'DEAD_TUPLE_ACCUMULATION',
            CASE WHEN n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) > 0.5 THEN 'HIGH' ELSE 'MEDIUM' END,
            format('%%s.%%s is %%s%%%% dead tuples (%%s of %%s total)', schemaname, relname,
                round((n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0)) * 100, 1), n_dead_tup, n_live_tup + n_dead_tup),
            round((n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0)) * 100, 1), 20::numeric,
            'Investigate why autovacuum is not keeping up: check for long-running transactions holding back the xmin horizon, or tune autovacuum_vacuum_scale_factor for this table'
        FROM pgfr_record.state_as_of(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE n_dead_tup > 1000 AND (n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0)) > 0.2
        $q$,
        'pg_catalog.pg_stat_all_tables', p_to_t, v_tables_col_defs
    );
    RETURN QUERY EXECUTE v_sql;

    -- Vacuum starvation: relations with meaningful dead-tuple buildup that
    -- haven't been (auto)vacuumed in a long time, or never at all.
    v_sql := format(
        $q$
        SELECT
            'VACUUM_STARVATION',
            CASE WHEN greatest(last_vacuum, last_autovacuum) IS NULL OR n_dead_tup > 100000 THEN 'HIGH' ELSE 'MEDIUM' END,
            format('%%s.%%s has %%s dead tuples and %%s', schemaname, relname, n_dead_tup,
                CASE WHEN greatest(last_vacuum, last_autovacuum) IS NULL THEN 'has never been vacuumed'
                     ELSE 'was last vacuumed ' || (age(%2$L::timestamptz, greatest(last_vacuum, last_autovacuum)))::text || ' ago' END),
            n_dead_tup::numeric, 10000::numeric,
            'Consider a manual VACUUM, or tuning autovacuum_vacuum_cost_limit / autovacuum_naptime so autovacuum keeps pace with this table''s write rate'
        FROM pgfr_record.state_as_of(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE n_dead_tup > 10000
          AND (greatest(last_vacuum, last_autovacuum) IS NULL OR %2$L::timestamptz - greatest(last_vacuum, last_autovacuum) > interval '7 days')
        $q$,
        'pg_catalog.pg_stat_all_tables', p_to_t, v_tables_col_defs
    );
    RETURN QUERY EXECUTE v_sql;

    -- Replication lag: a connected replica falling behind on replay.
    -- Current-state read -- write_lag/flush_lag/replay_lag are gauges,
    -- already expressed as intervals by the source view itself.
    v_sql := format(
        $q$
        SELECT
            'REPLICATION_LAG',
            CASE WHEN replay_lag > interval '5 minutes' THEN 'HIGH' ELSE 'MEDIUM' END,
            format('Replica %%s is replaying %%s behind', coalesce(application_name, client_addr::text, pid::text), replay_lag::text),
            extract(epoch FROM replay_lag)::numeric, 30::numeric,
            'Investigate replica I/O or network throughput; sustained replay lag risks the primary retaining excess WAL'
        FROM pgfr_record.latest_state(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE replay_lag > interval '30 seconds'
        $q$,
        'pg_catalog.pg_stat_replication', p_to_t, v_repl_col_defs
    );
    RETURN QUERY EXECUTE v_sql;

    -- Inactive replication slots: retain WAL and hold back the xmin
    -- horizon indefinitely until dropped or reactivated.
    v_sql := format(
        $q$
        SELECT
            'REPLICATION_SLOT_INACTIVE', 'HIGH',
            format('Replication slot %%s (database %%s) is inactive; it will retain WAL indefinitely until dropped or reactivated', slot_name, database),
            0::numeric, 0::numeric,
            'Drop this slot if it is no longer needed, or investigate why its consumer is not connected; an inactive slot blocks WAL recycling and vacuum''s xmin horizon'
        FROM pgfr_record.latest_state(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE active = false
        $q$,
        'pg_catalog.pg_replication_slots', p_to_t, v_slots_col_defs
    );
    RETURN QUERY EXECUTE v_sql;

    -- Database-level XID/MultiXID wraparound distance: age()/mxid_age() on
    -- the captured frozen horizon, evaluated against the current
    -- transaction counter at query time (a durable watermark, not a
    -- capture-time-relative reconstruction).
    v_sql := format(
        $q$
        SELECT
            'XID_WRAPAROUND_RISK',
            CASE WHEN age(datfrozenxid) > 1500000000 THEN 'HIGH' ELSE 'MEDIUM' END,
            format('Database %%s is %%s transactions past its frozen XID horizon', datname, age(datfrozenxid)),
            age(datfrozenxid)::numeric, 200000000::numeric,
            'Investigate why autovacuum is not advancing datfrozenxid: check for long-running transactions, disabled autovacuum, or a replication slot holding back xmin; this is approaching autovacuum_freeze_max_age'
        FROM pgfr_record.state_as_of(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE age(datfrozenxid) > 200000000
        UNION ALL
        SELECT
            'MXID_WRAPAROUND_RISK',
            CASE WHEN mxid_age(datminmxid) > 1500000000 THEN 'HIGH' ELSE 'MEDIUM' END,
            format('Database %%s is %%s multixact IDs past its frozen MXID horizon', datname, mxid_age(datminmxid)),
            mxid_age(datminmxid)::numeric, 200000000::numeric,
            'Investigate why autovacuum is not advancing datminmxid; this is approaching autovacuum_multixact_freeze_max_age'
        FROM pgfr_record.state_as_of(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE mxid_age(datminmxid) > 200000000
        $q$,
        'pg_catalog.pg_database', p_to_t, v_pgdb_col_defs
    );
    RETURN QUERY EXECUTE v_sql;

    -- Relation-level XID/MultiXID wraparound distance, restricted to
    -- relkinds relfrozenxid/relminmxid are actually meaningful for
    -- (ordinary tables, materialized views, TOAST tables).
    v_sql := format(
        $q$
        SELECT
            'RELATION_XID_WRAPAROUND_RISK',
            CASE WHEN age(relfrozenxid) > 1500000000 THEN 'HIGH' ELSE 'MEDIUM' END,
            format('Relation %%s.%%s is %%s transactions past its frozen XID horizon', nspname, relname, age(relfrozenxid)),
            age(relfrozenxid)::numeric, 200000000::numeric,
            'Run a manual VACUUM FREEZE on this relation, or investigate why autovacuum is not keeping up with it'
        FROM pgfr_record.state_as_of(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE relkind IN ('r', 'm', 't') AND age(relfrozenxid) > 200000000
        UNION ALL
        SELECT
            'RELATION_MXID_WRAPAROUND_RISK',
            CASE WHEN mxid_age(relminmxid) > 1500000000 THEN 'HIGH' ELSE 'MEDIUM' END,
            format('Relation %%s.%%s is %%s multixact IDs past its frozen MXID horizon', nspname, relname, mxid_age(relminmxid)),
            mxid_age(relminmxid)::numeric, 200000000::numeric,
            'Run a manual VACUUM FREEZE on this relation, or investigate why autovacuum is not keeping up with it'
        FROM pgfr_record.state_as_of(%1$L, %2$L::timestamptz) AS d(%3$s)
        WHERE relkind IN ('r', 'm', 't') AND mxid_age(relminmxid) > 200000000
        $q$,
        'pgfr_record.src_catalog_identity', p_to_t, v_cat_col_defs
    );
    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.anomaly_report(timestamptz, timestamptz) IS
    'Every anomaly flagged between p_from_t and p_to_t, across a growing set of checks (currently: forced checkpoints, checkpoint write time, buffer pressure, backend fsync, temp file spills, idle in transaction, lock contention, connection leak, dead tuple accumulation, vacuum starvation, replication lag, inactive replication slots, database and relation XID/MultiXID wraparound distance), each built on pgfr_record.deltas() or a current-state read.';
