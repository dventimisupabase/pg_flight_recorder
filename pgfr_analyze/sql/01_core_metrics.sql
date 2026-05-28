-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pgfr_record.config WHERE key = 'schema_version') THEN
        RAISE EXCEPTION 'Flight Recorder core not installed. Run pgfr_record/install.sql first.';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS pgfr_analyze;

-- Calculates the rate of row modifications (INSERT/UPDATE/DELETE) over a time window
-- Returns modifications per second, or NULL if insufficient data
CREATE OR REPLACE FUNCTION pgfr_analyze.modification_rate(
    p_relid OID,
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_first_snapshot RECORD;
    v_last_snapshot RECORD;
    v_delta_mods BIGINT;
    v_delta_seconds NUMERIC;
BEGIN
    -- Get earliest snapshot within window
    SELECT ts.n_tup_ins, ts.n_tup_upd, ts.n_tup_del, s.captured_at
    INTO v_first_snapshot
    FROM pgfr_record.table_snapshots ts
    JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at ASC
    LIMIT 1;

    -- Get latest snapshot
    SELECT ts.n_tup_ins, ts.n_tup_upd, ts.n_tup_del, s.captured_at
    INTO v_last_snapshot
    FROM pgfr_record.table_snapshots ts
    JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Need at least 2 distinct snapshots
    IF v_first_snapshot.captured_at IS NULL OR v_last_snapshot.captured_at IS NULL
       OR v_first_snapshot.captured_at = v_last_snapshot.captured_at THEN
        RETURN NULL;
    END IF;

    v_delta_mods := (COALESCE(v_last_snapshot.n_tup_ins, 0) + COALESCE(v_last_snapshot.n_tup_upd, 0) + COALESCE(v_last_snapshot.n_tup_del, 0))
                  - (COALESCE(v_first_snapshot.n_tup_ins, 0) + COALESCE(v_first_snapshot.n_tup_upd, 0) + COALESCE(v_first_snapshot.n_tup_del, 0));
    v_delta_seconds := EXTRACT(EPOCH FROM (v_last_snapshot.captured_at - v_first_snapshot.captured_at));

    IF v_delta_seconds <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_delta_mods::numeric / v_delta_seconds, 4);
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.modification_rate(OID, INTERVAL) IS 'Returns row modification rate (modifications/second) for a table over a time window';

-- Calculates the HOT (Heap-Only Tuple) update ratio for a table
-- Higher ratio indicates more efficient updates that don't require index maintenance
-- Returns percentage (0-100), or NULL if no updates
CREATE OR REPLACE FUNCTION pgfr_analyze.hot_update_ratio(
    p_relid OID
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_n_tup_upd BIGINT;
    v_n_tup_hot_upd BIGINT;
BEGIN
    -- Get latest snapshot for this table
    SELECT ts.n_tup_upd, ts.n_tup_hot_upd
    INTO v_n_tup_upd, v_n_tup_hot_upd
    FROM pgfr_record.table_snapshots ts
    JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
    ORDER BY s.captured_at DESC
    LIMIT 1;

    IF v_n_tup_upd IS NULL OR v_n_tup_upd = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND((COALESCE(v_n_tup_hot_upd, 0)::numeric / v_n_tup_upd) * 100, 2);
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.hot_update_ratio(OID) IS 'Returns HOT update percentage (0-100) for a table based on latest snapshot';

-- Analyzes database metrics within a time window and reports detected anomalies (checkpoints, buffer pressure, lock contention, etc.)
-- Returns anomalies with severity levels and actionable remediation recommendations
CREATE OR REPLACE FUNCTION pgfr_analyze.anomaly_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    anomaly_type        TEXT,
    severity            TEXT,
    description         TEXT,
    metric_value        TEXT,
    threshold           TEXT,
    recommendation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cmp RECORD;
    v_wait_pct NUMERIC;
    v_lock_count INTEGER;
    v_max_block_duration INTERVAL;
    v_datfrozenxid_age INTEGER;
    v_datminmxid_age INTEGER;
    v_table_xid_rec RECORD;
    v_table_mxid_rec RECORD;
    v_freeze_max_age BIGINT;
    v_warning_threshold BIGINT;
    v_critical_threshold BIGINT;
    v_mxid_freeze_max_age BIGINT;
    v_mxid_warning_threshold BIGINT;
    v_mxid_critical_threshold BIGINT;
    v_xid_warning_ratio NUMERIC;
    v_xid_critical_ratio NUMERIC;
    v_mxid_warning_ratio NUMERIC;
    v_mxid_critical_ratio NUMERIC;
    v_row RECORD;
BEGIN
    -- XID / MultiXID wraparound thresholds are a configurable fraction of the
    -- corresponding autovacuum_*_freeze_max_age GUC. Ratios are read from
    -- pgfr_record.config so operators can tune without patching analyze code —
    -- defaults are conservative (0.5 warning, 0.8 critical) but 0.5 may be too
    -- high for warning on busy clusters; see config keys xid_warning_ratio etc.
    -- Both GUCs are always defined, so current_setting() never misses. See:
    --   https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-transaction-id-wraparound-risks
    v_xid_warning_ratio  := coalesce(pgfr_record._get_config('xid_warning_ratio',  '0.5')::numeric, 0.5);
    v_xid_critical_ratio := coalesce(pgfr_record._get_config('xid_critical_ratio', '0.8')::numeric, 0.8);
    v_mxid_warning_ratio  := coalesce(pgfr_record._get_config('mxid_warning_ratio',  '0.5')::numeric, 0.5);
    v_mxid_critical_ratio := coalesce(pgfr_record._get_config('mxid_critical_ratio', '0.8')::numeric, 0.8);
    v_freeze_max_age      := current_setting('autovacuum_freeze_max_age')::int8;
    v_warning_threshold   := (v_freeze_max_age  * v_xid_warning_ratio )::bigint;
    v_critical_threshold  := (v_freeze_max_age  * v_xid_critical_ratio)::bigint;
    v_mxid_freeze_max_age       := current_setting('autovacuum_multixact_freeze_max_age')::int8;
    v_mxid_warning_threshold    := (v_mxid_freeze_max_age * v_mxid_warning_ratio )::bigint;
    v_mxid_critical_threshold   := (v_mxid_freeze_max_age * v_mxid_critical_ratio)::bigint;

    SELECT * INTO v_cmp FROM pgfr_analyze.compare(p_start_time, p_end_time);
    IF v_cmp.checkpoint_occurred THEN
        anomaly_type := 'CHECKPOINT_DURING_WINDOW';
        severity := CASE
            WHEN v_cmp.ckpt_write_time_ms > 30000 THEN 'high'
            WHEN v_cmp.ckpt_write_time_ms > 10000 THEN 'medium'
            ELSE 'low'
        END;
        description := 'A checkpoint occurred during this time window';
        metric_value := format('write_time: %s ms, sync_time: %s ms',
                              round(v_cmp.ckpt_write_time_ms::numeric, 1),
                              round(v_cmp.ckpt_sync_time_ms::numeric, 1));
        threshold := 'Any checkpoint';
        recommendation := 'Consider increasing max_wal_size or scheduling heavy writes after checkpoint_timeout';
        RETURN NEXT;
    END IF;
    IF v_cmp.ckpt_requested_delta > 0 THEN
        anomaly_type := 'FORCED_CHECKPOINT';
        severity := 'high';
        description := 'WAL exceeded max_wal_size, forcing checkpoint';
        metric_value := format('%s forced checkpoints', v_cmp.ckpt_requested_delta);
        threshold := 'ckpt_requested_delta > 0';
        recommendation := 'Increase max_wal_size to prevent mid-batch checkpoints';
        RETURN NEXT;
    END IF;
    IF COALESCE(v_cmp.bgw_buffers_backend_delta, 0) > 0 THEN
        anomaly_type := 'BUFFER_PRESSURE';
        severity := CASE
            WHEN v_cmp.bgw_buffers_backend_delta > 1000 THEN 'high'
            WHEN v_cmp.bgw_buffers_backend_delta > 100 THEN 'medium'
            ELSE 'low'
        END;
        description := 'Backends forced to write buffers directly (shared_buffers exhaustion)';
        metric_value := format('%s backend buffer writes', v_cmp.bgw_buffers_backend_delta);
        threshold := 'bgw_buffers_backend_delta > 0';
        recommendation := 'Increase shared_buffers, reduce concurrent writers, or use faster storage';
        RETURN NEXT;
    END IF;
    IF COALESCE(v_cmp.bgw_buffers_backend_fsync_delta, 0) > 0 THEN
        anomaly_type := 'BACKEND_FSYNC';
        severity := 'high';
        description := 'Backends forced to perform fsync (severe I/O bottleneck)';
        metric_value := format('%s backend fsyncs', v_cmp.bgw_buffers_backend_fsync_delta);
        threshold := 'bgw_buffers_backend_fsync_delta > 0';
        recommendation := 'Urgent: increase shared_buffers, reduce write load, or upgrade storage';
        RETURN NEXT;
    END IF;
    IF COALESCE(v_cmp.temp_files_delta, 0) > 0 THEN
        anomaly_type := 'TEMP_FILE_SPILLS';
        severity := CASE
            WHEN v_cmp.temp_bytes_delta > 1073741824 THEN 'high'
            WHEN v_cmp.temp_bytes_delta > 104857600 THEN 'medium'
            ELSE 'low'
        END;
        description := 'Queries spilling to temp files (work_mem exhaustion)';
        metric_value := format('%s temp files, %s written',
                              v_cmp.temp_files_delta, v_cmp.temp_bytes_pretty);
        threshold := 'temp_files_delta > 0';
        recommendation := 'Increase work_mem for affected sessions or globally';
        RETURN NEXT;
    END IF;
    -- Lock contention from v2 ring (legacy fallback retired).
    SELECT count(DISTINCT ls.blocked_pid),
           max(ls.blocked_duration_s * interval '1 second')
      INTO v_lock_count, v_max_block_duration
      FROM pgfr_record.lock_samples ls
     WHERE pgfr_record.epoch() + ls.sample_ts * interval '1 second'
           BETWEEN p_start_time AND p_end_time;
    IF v_lock_count > 0 THEN
        anomaly_type := 'LOCK_CONTENTION';
        severity := CASE
            WHEN v_max_block_duration > interval '30 seconds' THEN 'high'
            WHEN v_max_block_duration > interval '5 seconds' THEN 'medium'
            ELSE 'low'
        END;
        description := 'Lock contention detected';
        metric_value := format('%s blocked sessions, max duration: %s',
                              v_lock_count, v_max_block_duration);
        threshold := 'Any lock contention';
        recommendation := 'Check recent_locks for blocking queries; consider shorter transactions';
        RETURN NEXT;
    END IF;

    -- xmin horizon anomalies. Fires when the data or catalog xmin horizon
    -- crosses the same fraction-of-autovacuum_freeze_max_age thresholds that
    -- XID_WRAPAROUND_RISK uses, but emitted FIRST so cause precedes the
    -- wraparound symptom. Holder details come from snapshots.xmin_horizon_detail
    -- (JSONB; populated by the collector). Data and catalog fire independently:
    -- both can trigger when a logical slot pins xmin and catalog_xmin together.
    DECLARE
        v_xmin RECORD;
        v_xmin_rec TEXT;
        v_xmin_src TEXT;
    BEGIN
        SELECT xmin_data_horizon_age, slot_catalog_xmin_age, xmin_horizon_detail
          INTO v_xmin
        FROM pgfr_record.snapshots
        WHERE captured_at BETWEEN p_start_time AND p_end_time
          AND (xmin_data_horizon_age IS NOT NULL OR slot_catalog_xmin_age IS NOT NULL)
        ORDER BY captured_at DESC
        LIMIT 1;

        IF v_xmin.xmin_horizon_detail IS NOT NULL THEN
            v_xmin_src := v_xmin.xmin_horizon_detail->>'source';
            v_xmin_rec := CASE v_xmin_src
                WHEN 'activity' THEN
                    CASE
                        WHEN v_xmin.xmin_horizon_detail->'holder'->>'backend_type' = 'autovacuum worker' THEN
                            format('long autovacuum (pid=%s) holding xmin — check pg_stat_progress_vacuum',
                                v_xmin.xmin_horizon_detail->'holder'->>'pid')
                        WHEN v_xmin.xmin_horizon_detail->'holder'->>'state' LIKE 'idle in transaction%' THEN
                            format('PID %s idle in transaction for %ss (user=%s, db=%s) — pg_terminate_backend(%s); cancel does nothing on an idle backend. Prevent recurrence: set idle_in_transaction_session_timeout (or transaction_timeout on PG17+).',
                                v_xmin.xmin_horizon_detail->'holder'->>'pid',
                                v_xmin.xmin_horizon_detail->'holder'->>'xact_age_seconds',
                                v_xmin.xmin_horizon_detail->'holder'->>'usename',
                                v_xmin.xmin_horizon_detail->'holder'->>'datname',
                                v_xmin.xmin_horizon_detail->'holder'->>'pid')
                        WHEN v_xmin.xmin_horizon_detail->'holder'->>'state' = 'active' THEN
                            -- Active txn pinning xmin is just as bad as idle-in-txn — autovacuum
                            -- still can't freeze. pg_cancel_backend ends the current query (and
                            -- the implicit txn for autocommit, releasing xmin) but if the query
                            -- runs inside an explicit BEGIN the txn stays open and xmin will
                            -- typically reappear; escalate to pg_terminate_backend in that case.
                            format('PID %s active for %ss holding xmin (user=%s, db=%s, query: %s) — pg_cancel_backend(%s); escalate to pg_terminate_backend(%s) if backend_xmin reappears (txn was inside explicit BEGIN). Prevent recurrence: set statement_timeout (and transaction_timeout on PG17+).',
                                v_xmin.xmin_horizon_detail->'holder'->>'pid',
                                v_xmin.xmin_horizon_detail->'holder'->>'query_age_seconds',
                                v_xmin.xmin_horizon_detail->'holder'->>'usename',
                                v_xmin.xmin_horizon_detail->'holder'->>'datname',
                                v_xmin.xmin_horizon_detail->'holder'->>'query_preview',
                                v_xmin.xmin_horizon_detail->'holder'->>'pid',
                                v_xmin.xmin_horizon_detail->'holder'->>'pid')
                        ELSE
                            format('PID %s holding xmin (state=%s, backend_type=%s) — investigate via pg_stat_activity; pg_terminate_backend(%s) if no other path releases backend_xmin',
                                v_xmin.xmin_horizon_detail->'holder'->>'pid',
                                v_xmin.xmin_horizon_detail->'holder'->>'state',
                                v_xmin.xmin_horizon_detail->'holder'->>'backend_type',
                                v_xmin.xmin_horizon_detail->'holder'->>'pid')
                    END
                WHEN 'slot' THEN
                    format('investigate slot ''%s'' (type=%s); advance or DROP REPLICATION SLOT once subscriber state is confirmed',
                        v_xmin.xmin_horizon_detail->'holder'->>'slot_name',
                        v_xmin.xmin_horizon_detail->'holder'->>'slot_type')
                WHEN 'slot_catalog' THEN
                    format('logical slot ''%s'' pinning catalog_xmin — advance or DROP REPLICATION SLOT',
                        v_xmin.xmin_horizon_detail->'holder'->>'slot_name')
                WHEN 'prepared' THEN
                    format('ROLLBACK PREPARED ''%s'' (owner=%s, database=%s, prepared_at=%s)',
                        v_xmin.xmin_horizon_detail->'holder'->>'gid',
                        v_xmin.xmin_horizon_detail->'holder'->>'owner',
                        v_xmin.xmin_horizon_detail->'holder'->>'database',
                        v_xmin.xmin_horizon_detail->'holder'->>'prepared_at')
                WHEN 'replication' THEN
                    -- The walsender PID is on the primary; the actual cause is a
                    -- long-running query on the standby whose snapshot xmin is
                    -- being shipped back via hot_standby_feedback. Standby
                    -- workloads are usually autocommit reads, so pg_cancel_backend
                    -- on the standby is the right first action. Don't disable
                    -- hot_standby_feedback — that just trades xmin holdback for
                    -- "canceling statement due to conflict with recovery" failures
                    -- on the standby.
                    format('standby ''%s'' (addr=%s, slot=%s) is reporting backend_xmin via hot_standby_feedback — connect to that standby, find the long-running query in its pg_stat_activity, and pg_cancel_backend it there. Do not disable hot_standby_feedback (causes recovery-conflict cancellations on the standby).',
                        v_xmin.xmin_horizon_detail->'holder'->>'application_name',
                        v_xmin.xmin_horizon_detail->'holder'->>'client_addr',
                        v_xmin.xmin_horizon_detail->'holder'->>'slot_name')
                ELSE 'see snapshots.xmin_horizon_detail'
            END;
        END IF;

        IF v_xmin.xmin_data_horizon_age IS NOT NULL
           AND v_xmin.xmin_data_horizon_age > v_warning_threshold THEN
            anomaly_type := 'XMIN_HORIZON_STALL';
            severity := CASE WHEN v_xmin.xmin_data_horizon_age > v_critical_threshold
                             THEN 'critical' ELSE 'high' END;
            description := 'xmin horizon stalled — autovacuum cannot freeze user-table tuples';
            metric_value := format('xmin_data_horizon_age=%s (%s%% of autovacuum_freeze_max_age); source=%s',
                to_char(v_xmin.xmin_data_horizon_age, 'FM999,999,999'),
                round(v_xmin.xmin_data_horizon_age::numeric / v_freeze_max_age * 100, 1),
                COALESCE(v_xmin_src, 'unknown'));
            threshold := format('xmin_data_horizon_age > %s%% of autovacuum_freeze_max_age',
                round(v_xid_warning_ratio * 100, 0));
            recommendation := COALESCE(v_xmin_rec, 'see snapshots.xmin_horizon_detail');
            RETURN NEXT;
        END IF;

        IF v_xmin.slot_catalog_xmin_age IS NOT NULL
           AND v_xmin.slot_catalog_xmin_age > v_warning_threshold THEN
            anomaly_type := 'CATALOG_XMIN_HORIZON_STALL';
            severity := CASE WHEN v_xmin.slot_catalog_xmin_age > v_critical_threshold
                             THEN 'critical' ELSE 'high' END;
            description := 'logical-replication catalog cleanup stalled by replication slot catalog_xmin';
            metric_value := format('slot_catalog_xmin_age=%s (%s%% of autovacuum_freeze_max_age)',
                to_char(v_xmin.slot_catalog_xmin_age, 'FM999,999,999'),
                round(v_xmin.slot_catalog_xmin_age::numeric / v_freeze_max_age * 100, 1));
            threshold := format('slot_catalog_xmin_age > %s%% of autovacuum_freeze_max_age',
                round(v_xid_warning_ratio * 100, 0));
            recommendation := COALESCE(
                CASE WHEN v_xmin_src IN ('slot','slot_catalog') THEN v_xmin_rec END,
                'investigate logical replication slots with non-null catalog_xmin (see pg_replication_slots)');
            RETURN NEXT;
        END IF;
    END;

    -- Database-level XID wraparound check
    SELECT datfrozenxid_age INTO v_datfrozenxid_age
    FROM pgfr_record.snapshots
    WHERE captured_at BETWEEN p_start_time AND p_end_time
      AND datfrozenxid_age IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;
    IF v_datfrozenxid_age IS NOT NULL AND v_datfrozenxid_age > v_warning_threshold THEN
        anomaly_type := 'XID_WRAPAROUND_RISK';
        severity := CASE
            WHEN v_datfrozenxid_age > v_critical_threshold THEN 'critical'
            ELSE 'high'
        END;
        description := 'Database approaching transaction ID wraparound';
        metric_value := format('XID age: %s (%s%% of autovacuum_freeze_max_age)',
                              to_char(v_datfrozenxid_age, 'FM999,999,999'),
                              round(v_datfrozenxid_age::numeric / v_freeze_max_age * 100, 1));
        threshold := format('datfrozenxid_age > %s (50%% of %s)',
                           to_char(v_warning_threshold, 'FM999,999,999'),
                           to_char(v_freeze_max_age, 'FM999,999,999'));
        recommendation := 'Run VACUUM FREEZE on large tables or enable more aggressive autovacuum';
        RETURN NEXT;
    END IF;
    -- Database-level MultiXID wraparound check. See:
    --   https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-transaction-id-wraparound-risks
    SELECT datminmxid_age INTO v_datminmxid_age
    FROM pgfr_record.snapshots
    WHERE captured_at BETWEEN p_start_time AND p_end_time
      AND datminmxid_age IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;
    IF v_datminmxid_age IS NOT NULL AND v_datminmxid_age > v_mxid_warning_threshold THEN
        anomaly_type := 'MXID_WRAPAROUND_RISK';
        severity := CASE
            WHEN v_datminmxid_age > v_mxid_critical_threshold THEN 'critical'
            ELSE 'high'
        END;
        description := 'Database approaching MultiXact ID wraparound';
        metric_value := format('MXID age: %s (%s%% of autovacuum_multixact_freeze_max_age)',
                              to_char(v_datminmxid_age, 'FM999,999,999'),
                              round(v_datminmxid_age::numeric / v_mxid_freeze_max_age * 100, 1));
        threshold := format('datminmxid_age > %s (50%% of %s)',
                           to_char(v_mxid_warning_threshold, 'FM999,999,999'),
                           to_char(v_mxid_freeze_max_age, 'FM999,999,999'));
        recommendation := 'Investigate row-level locks (SELECT FOR SHARE/UPDATE), foreign-key-heavy updates, and unfrozen MultiXacts. Run VACUUM (FREEZE) on largest tables; autovacuum may be blocked by long transactions or idle-in-transaction sessions.';
        RETURN NEXT;
    END IF;
    -- Table-level XID wraparound check (find tables approaching their threshold)
    -- Each table may have its own autovacuum_freeze_max_age setting
    FOR v_table_xid_rec IN
        SELECT
            COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
            ts.relfrozenxid_age,
            COALESCE(
                (SELECT (regexp_match(opt, 'autovacuum_freeze_max_age=(\d+)'))[1]::bigint
                 FROM unnest(c.reloptions) opt
                 WHERE opt LIKE 'autovacuum_freeze_max_age=%'
                 LIMIT 1),
                v_freeze_max_age
            ) AS table_freeze_max_age
        FROM pgfr_record.table_snapshots ts
        LEFT JOIN pg_class c ON c.oid = ts.relid
        WHERE ts.snapshot_id = (
            SELECT id FROM pgfr_record.snapshots
            WHERE captured_at BETWEEN p_start_time AND p_end_time
            ORDER BY captured_at DESC
            LIMIT 1
        )
          AND ts.relfrozenxid_age IS NOT NULL
          AND COALESCE(c.relkind, 'r') <> 'p' -- exclude partitioned tables (relfrozenxid is always 0)
        ORDER BY ts.relfrozenxid_age::numeric / COALESCE(
            (SELECT (regexp_match(opt, 'autovacuum_freeze_max_age=(\d+)'))[1]::bigint
             FROM unnest(c.reloptions) opt
             WHERE opt LIKE 'autovacuum_freeze_max_age=%'
             LIMIT 1),
            v_freeze_max_age
        ) DESC
        LIMIT 5  -- Check top 5 tables by relative XID age
    LOOP
        IF v_table_xid_rec.relfrozenxid_age > (v_table_xid_rec.table_freeze_max_age * v_xid_warning_ratio)::bigint THEN
            anomaly_type := 'TABLE_XID_WRAPAROUND_RISK';
            severity := CASE
                WHEN v_table_xid_rec.relfrozenxid_age > (v_table_xid_rec.table_freeze_max_age * v_xid_critical_ratio)::bigint THEN 'critical'
                ELSE 'high'
            END;
            description := format('Table %s.%s approaching XID wraparound',
                                 v_table_xid_rec.schemaname, v_table_xid_rec.relname);
            metric_value := format('XID age: %s (%s%% of table autovacuum_freeze_max_age=%s)',
                                  to_char(v_table_xid_rec.relfrozenxid_age, 'FM999,999,999'),
                                  round(v_table_xid_rec.relfrozenxid_age::numeric / v_table_xid_rec.table_freeze_max_age * 100, 1),
                                  to_char(v_table_xid_rec.table_freeze_max_age, 'FM999,999,999'));
            threshold := format('relfrozenxid_age > %s (%s%% of %s)',
                               to_char((v_table_xid_rec.table_freeze_max_age * v_xid_warning_ratio)::bigint, 'FM999,999,999'),
                               round(v_xid_warning_ratio * 100),
                               to_char(v_table_xid_rec.table_freeze_max_age, 'FM999,999,999'));
            recommendation := format('Run VACUUM FREEZE on %s.%s',
                                    v_table_xid_rec.schemaname, v_table_xid_rec.relname);
            RETURN NEXT;
        END IF;
    END LOOP;

    -- Table-level MultiXID wraparound check. Each table may have its own
    -- autovacuum_multixact_freeze_max_age reloption override. See:
    --   https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-transaction-id-wraparound-risks
    FOR v_table_mxid_rec IN
        SELECT
            COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
            ts.relminmxid_age,
            COALESCE(
                (SELECT (regexp_match(opt, 'autovacuum_multixact_freeze_max_age=(\d+)'))[1]::bigint
                 FROM unnest(c.reloptions) opt
                 WHERE opt LIKE 'autovacuum_multixact_freeze_max_age=%'
                 LIMIT 1),
                v_mxid_freeze_max_age
            ) AS table_mxid_freeze_max_age
        FROM pgfr_record.table_snapshots ts
        LEFT JOIN pg_class c ON c.oid = ts.relid
        WHERE ts.snapshot_id = (
            SELECT id FROM pgfr_record.snapshots
            WHERE captured_at BETWEEN p_start_time AND p_end_time
            ORDER BY captured_at DESC
            LIMIT 1
        )
          AND ts.relminmxid_age IS NOT NULL
          AND COALESCE(c.relkind, 'r') <> 'p' -- exclude partitioned tables (relminmxid is always 0)
        ORDER BY ts.relminmxid_age::numeric / COALESCE(
            (SELECT (regexp_match(opt, 'autovacuum_multixact_freeze_max_age=(\d+)'))[1]::bigint
             FROM unnest(c.reloptions) opt
             WHERE opt LIKE 'autovacuum_multixact_freeze_max_age=%'
             LIMIT 1),
            v_mxid_freeze_max_age
        ) DESC
        LIMIT 5
    LOOP
        IF v_table_mxid_rec.relminmxid_age > (v_table_mxid_rec.table_mxid_freeze_max_age * v_mxid_warning_ratio)::bigint THEN
            anomaly_type := 'TABLE_MXID_WRAPAROUND_RISK';
            severity := CASE
                WHEN v_table_mxid_rec.relminmxid_age > (v_table_mxid_rec.table_mxid_freeze_max_age * v_mxid_critical_ratio)::bigint THEN 'critical'
                ELSE 'high'
            END;
            description := format('Table %s.%s approaching MultiXact ID wraparound',
                                 v_table_mxid_rec.schemaname, v_table_mxid_rec.relname);
            metric_value := format('MXID age: %s (%s%% of table autovacuum_multixact_freeze_max_age=%s)',
                                  to_char(v_table_mxid_rec.relminmxid_age, 'FM999,999,999'),
                                  round(v_table_mxid_rec.relminmxid_age::numeric / v_table_mxid_rec.table_mxid_freeze_max_age * 100, 1),
                                  to_char(v_table_mxid_rec.table_mxid_freeze_max_age, 'FM999,999,999'));
            threshold := format('relminmxid_age > %s (%s%% of %s)',
                               to_char((v_table_mxid_rec.table_mxid_freeze_max_age * v_mxid_warning_ratio)::bigint, 'FM999,999,999'),
                               round(v_mxid_warning_ratio * 100),
                               to_char(v_table_mxid_rec.table_mxid_freeze_max_age, 'FM999,999,999'));
            recommendation := format('Run VACUUM FREEZE on %s.%s; check for row-level lock / FK contention generating unfrozen MultiXacts',
                                    v_table_mxid_rec.schemaname, v_table_mxid_rec.relname);
            RETURN NEXT;
        END IF;
    END LOOP;

    -- OID exhaustion detection
    -- OIDs are 32-bit unsigned integers (max ~4.3 billion)
    -- Unlike XIDs, OIDs are not recycled - they simply exhaust
    DECLARE
        v_max_catalog_oid BIGINT;
        v_large_object_count BIGINT;
        v_oid_max BIGINT := 4294967295;  -- 2^32 - 1
        v_oid_warning_threshold BIGINT := (v_oid_max * 0.75)::bigint;   -- 75% = ~3.22 billion
        v_oid_critical_threshold BIGINT := (v_oid_max * 0.90)::bigint;  -- 90% = ~3.87 billion
    BEGIN
        SELECT max_catalog_oid, large_object_count
        INTO v_max_catalog_oid, v_large_object_count
        FROM pgfr_record.snapshots
        WHERE captured_at BETWEEN p_start_time AND p_end_time
          AND max_catalog_oid IS NOT NULL
        ORDER BY captured_at DESC
        LIMIT 1;

        IF v_max_catalog_oid IS NOT NULL AND v_max_catalog_oid > v_oid_warning_threshold THEN
            anomaly_type := 'OID_EXHAUSTION_RISK';
            severity := CASE
                WHEN v_max_catalog_oid > v_oid_critical_threshold THEN 'critical'
                ELSE 'high'
            END;
            description := 'Database approaching OID exhaustion';
            metric_value := format('Max catalog OID: %s (%s%% of 4.3 billion), Large objects: %s',
                                  to_char(v_max_catalog_oid, 'FM999,999,999,999'),
                                  round(v_max_catalog_oid::numeric / v_oid_max * 100, 1),
                                  COALESCE(to_char(v_large_object_count, 'FM999,999,999'), 'N/A'));
            threshold := format('max_catalog_oid > %s (75%% of 4,294,967,295)',
                               to_char(v_oid_warning_threshold, 'FM999,999,999,999'));
            recommendation := 'OID exhaustion requires pg_dump/pg_restore to reset counter. Review lo_create() usage and large object cleanup.';
            RETURN NEXT;
        END IF;
    END;

    -- Idle-in-transaction detection (migrated to v2 activity_samples).
    FOR v_row IN
        SELECT a.pid, a.usename, a.application_name,
               EXTRACT(EPOCH FROM (now() - a.xact_start))/60 AS idle_minutes
        FROM pgfr_record.activity_samples a
        WHERE pgfr_record.epoch() + a.sample_ts * interval '1 second'
              BETWEEN p_start_time AND p_end_time
          AND a.state = 'idle in transaction'
          AND a.xact_start IS NOT NULL
          AND now() - a.xact_start > interval '5 minutes'
        ORDER BY a.xact_start ASC
        LIMIT 5
    LOOP
        anomaly_type := 'IDLE_IN_TRANSACTION';
        severity := CASE WHEN v_row.idle_minutes > 60 THEN 'critical'
             WHEN v_row.idle_minutes > 15 THEN 'high'
             ELSE 'medium' END;
        description := format('Session %s (%s) idle in transaction for %s minutes',
               v_row.pid, v_row.usename, round(v_row.idle_minutes::numeric));
        metric_value := format('PID %s, %s minutes', v_row.pid, round(v_row.idle_minutes::numeric));
        threshold := '>5 minutes idle in transaction';
        recommendation := 'Investigate and terminate if stale. Blocks vacuum and holds locks.';
        RETURN NEXT;
    END LOOP;

    -- Dead tuple accumulation (bloat risk)
    FOR v_row IN
        SELECT COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
               COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
               ts.n_dead_tup, ts.n_live_tup,
               round(100.0 * ts.n_dead_tup / NULLIF(ts.n_dead_tup + ts.n_live_tup, 0), 1) AS dead_pct
        FROM pgfr_record.table_snapshots ts
        JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at = (SELECT MAX(s2.captured_at) FROM pgfr_record.snapshots s2
                               JOIN pgfr_record.table_snapshots ts2 ON ts2.snapshot_id = s2.id
                               WHERE s2.captured_at <= p_end_time)
          AND ts.n_dead_tup > 10000
          AND ts.n_dead_tup::float / NULLIF(ts.n_dead_tup + ts.n_live_tup, 0) > 0.1
        ORDER BY ts.n_dead_tup DESC
        LIMIT 5
    LOOP
        anomaly_type := 'DEAD_TUPLE_ACCUMULATION';
        severity := CASE WHEN v_row.dead_pct > 30 THEN 'high'
             ELSE 'medium' END;
        description := format('Table %s.%s has %s%% dead tuples (%s dead)',
               v_row.schemaname, v_row.relname, v_row.dead_pct, v_row.n_dead_tup);
        metric_value := format('%s%% dead tuples', v_row.dead_pct);
        threshold := '>10% dead tuples and >10000 dead rows';
        recommendation := 'Run VACUUM on this table. Check autovacuum settings.';
        RETURN NEXT;
    END LOOP;

    -- Vacuum starvation (dead tuples growing, vacuum not running)
    FOR v_row IN
        WITH recent AS (
            SELECT COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
                   COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
                   ts.relid, ts.n_dead_tup, ts.last_autovacuum,
                   s.captured_at,
                   LAG(ts.n_dead_tup) OVER (PARTITION BY ts.relid ORDER BY s.captured_at) AS prev_dead
            FROM pgfr_record.table_snapshots ts
            JOIN pgfr_record.snapshots s ON s.id = ts.snapshot_id
            WHERE s.captured_at BETWEEN p_start_time AND p_end_time
        )
        SELECT schemaname, relname, n_dead_tup, last_autovacuum,
               n_dead_tup - COALESCE(prev_dead, 0) AS dead_growth
        FROM recent
        WHERE captured_at = (SELECT MAX(captured_at) FROM recent)
          AND n_dead_tup > prev_dead + 1000
          AND (last_autovacuum IS NULL OR last_autovacuum < now() - interval '24 hours')
        ORDER BY n_dead_tup - COALESCE(prev_dead, 0) DESC
        LIMIT 3
    LOOP
        anomaly_type := 'VACUUM_STARVATION';
        severity := 'high';
        description := format('Table %s.%s: dead tuples growing (+%s) but no vacuum in 24h',
               v_row.schemaname, v_row.relname, v_row.dead_growth);
        metric_value := format('+%s dead tuples, last vacuum: %s', v_row.dead_growth,
               COALESCE(v_row.last_autovacuum::TEXT, 'never'));
        threshold := 'Dead tuples growing >1000 with no vacuum in 24h';
        recommendation := 'Check autovacuum_vacuum_threshold and autovacuum_vacuum_scale_factor.';
        RETURN NEXT;
    END LOOP;

    -- Connection leak detection (sessions open > 7 days; migrated to v2).
    FOR v_row IN
        SELECT DISTINCT ON (a.pid) a.pid, a.usename, a.application_name, a.backend_start,
               EXTRACT(DAY FROM (now() - a.backend_start)) AS days_open
        FROM pgfr_record.activity_samples a
        WHERE pgfr_record.epoch() + a.sample_ts * interval '1 second'
              BETWEEN p_start_time AND p_end_time
          AND a.backend_start IS NOT NULL
          AND a.backend_start < now() - interval '7 days'
        ORDER BY a.pid, a.backend_start
        LIMIT 5
    LOOP
        anomaly_type := 'CONNECTION_LEAK';
        severity := CASE WHEN v_row.days_open > 30 THEN 'high' ELSE 'medium' END;
        description := format('Session %s (%s/%s) open for %s days',
               v_row.pid, v_row.usename, v_row.application_name, round(v_row.days_open::numeric));
        metric_value := format('%s days', round(v_row.days_open::numeric));
        threshold := '>7 days session age';
        recommendation := 'Investigate if this is a connection leak. Consider connection pooling.';
        RETURN NEXT;
    END LOOP;

    -- Replication lag velocity (lag is growing)
    FOR v_row IN
        WITH lag_samples AS (
            SELECT r.application_name,
                   EXTRACT(EPOCH FROM r.replay_lag) AS lag_seconds,
                   s.captured_at,
                   ROW_NUMBER() OVER (PARTITION BY r.application_name ORDER BY s.captured_at) AS rn
            FROM pgfr_record.replication_snapshots r
            JOIN pgfr_record.snapshots s ON s.id = r.snapshot_id
            WHERE s.captured_at BETWEEN p_start_time AND p_end_time
              AND r.replay_lag IS NOT NULL
        ),
        lag_trend AS (
            SELECT application_name,
                   MAX(lag_seconds) - MIN(lag_seconds) AS lag_growth,
                   MAX(lag_seconds) AS current_lag,
                   COUNT(*) AS samples
            FROM lag_samples
            GROUP BY application_name
            HAVING COUNT(*) >= 3
        )
        SELECT * FROM lag_trend
        WHERE lag_growth > 60  -- Growing by more than 60 seconds
          AND current_lag > 30 -- And currently > 30 seconds behind
    LOOP
        anomaly_type := 'REPLICATION_LAG_GROWING';
        severity := CASE WHEN v_row.current_lag > 300 THEN 'critical'
             WHEN v_row.current_lag > 60 THEN 'high'
             ELSE 'medium' END;
        description := format('Replica %s: lag growing (+%ss), now %ss behind',
               v_row.application_name, round(v_row.lag_growth::numeric), round(v_row.current_lag::numeric));
        metric_value := format('+%ss growth, %ss current', round(v_row.lag_growth::numeric), round(v_row.current_lag::numeric));
        threshold := '>60s growth and >30s current lag';
        recommendation := 'Check replica capacity, network, and long-running queries on primary.';
        RETURN NEXT;
    END LOOP;

    RETURN;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.anomaly_report(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Analyzes database metrics within a time window and reports detected anomalies (checkpoints, buffer pressure, lock contention, XID wraparound, bloat, replication lag) with severity levels and remediation recommendations.';

-- Generates a comprehensive performance report with metrics and interpretations for a specified time window
-- Aggregates data from compare, anomaly detection, wait events, and lock contention to provide human-readable insights
CREATE OR REPLACE FUNCTION pgfr_analyze.summary_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    section             TEXT,
    metric              TEXT,
    value               TEXT,
    interpretation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cmp RECORD;
    v_sample_count INTEGER;
    v_anomaly_count INTEGER;
    v_top_wait RECORD;
    v_lock_summary RECORD;
BEGIN
    SELECT * INTO v_cmp FROM pgfr_analyze.compare(p_start_time, p_end_time);
    -- Sample count from v2 activity_samples (legacy ring retired).
    SELECT count(*) INTO v_sample_count
      FROM pgfr_record.activity_samples
     WHERE pgfr_record.epoch() + sample_ts * interval '1 second'
           BETWEEN p_start_time AND p_end_time;
    SELECT count(*) INTO v_anomaly_count
    FROM pgfr_analyze.anomaly_report(p_start_time, p_end_time);
    section := 'OVERVIEW';
    metric := 'Time Window';
    value := format('%s to %s', p_start_time, p_end_time);
    interpretation := format('%s seconds elapsed', round(COALESCE(v_cmp.elapsed_seconds, 0), 1));
    RETURN NEXT;
    metric := 'Data Coverage';
    value := format('%s snapshots, %s samples',
                   (SELECT count(*) FROM pgfr_record.snapshots
                    WHERE captured_at BETWEEN p_start_time AND p_end_time),
                   v_sample_count);
    interpretation := CASE
        WHEN v_sample_count = 0 THEN 'WARNING: No sample data in window'
        ELSE 'OK'
    END;
    RETURN NEXT;
    metric := 'Anomalies Detected';
    value := v_anomaly_count::text;
    interpretation := CASE
        WHEN v_anomaly_count = 0 THEN 'No issues detected'
        WHEN v_anomaly_count <= 2 THEN 'Minor issues'
        ELSE 'Multiple issues - review anomaly_report()'
    END;
    RETURN NEXT;
    section := 'CHECKPOINT & WAL';
    metric := 'Checkpoint Occurred';
    value := COALESCE(v_cmp.checkpoint_occurred::text, 'unknown');
    interpretation := CASE
        WHEN v_cmp.checkpoint_occurred THEN
            format('Checkpoint write: %s ms', round(COALESCE(v_cmp.ckpt_write_time_ms, 0)::numeric, 1))
        ELSE 'No checkpoint during window'
    END;
    RETURN NEXT;
    metric := 'WAL Generated';
    value := COALESCE(v_cmp.wal_bytes_pretty, 'N/A');
    interpretation := format('%s MB/sec',
                            round((COALESCE(v_cmp.wal_bytes_delta, 0) / 1048576.0) / NULLIF(v_cmp.elapsed_seconds, 0), 2));
    RETURN NEXT;
    section := 'BUFFERS & I/O';
    metric := 'Buffers Allocated';
    value := COALESCE(v_cmp.bgw_buffers_alloc_delta::text, 'N/A');
    interpretation := 'New buffer allocations';
    RETURN NEXT;
    metric := 'Backend Buffer Writes';
    value := COALESCE(v_cmp.bgw_buffers_backend_delta::text, 'N/A');
    interpretation := CASE
        WHEN COALESCE(v_cmp.bgw_buffers_backend_delta, 0) > 0 THEN 'WARNING: Backends writing directly'
        ELSE 'OK'
    END;
    RETURN NEXT;
    metric := 'Temp File Spills';
    value := format('%s files, %s', COALESCE(v_cmp.temp_files_delta, 0), COALESCE(v_cmp.temp_bytes_pretty, '0 B'));
    interpretation := CASE
        WHEN COALESCE(v_cmp.temp_files_delta, 0) > 0 THEN 'Consider increasing work_mem'
        ELSE 'No temp file usage'
    END;
    RETURN NEXT;
    section := 'WAIT EVENTS';
    FOR v_top_wait IN
        SELECT wait_event_type || ':' || wait_event AS we, total_waiters, pct_of_samples
        FROM pgfr_analyze.wait_summary(p_start_time, p_end_time)
        LIMIT 5
    LOOP
        metric := v_top_wait.we;
        value := format('%s total waiters (%s%% of samples)',
                       v_top_wait.total_waiters, v_top_wait.pct_of_samples);
        interpretation := CASE
            WHEN v_top_wait.we LIKE 'Lock:%' THEN 'Lock contention'
            WHEN v_top_wait.we LIKE 'LWLock:Buffer%' THEN 'Buffer contention'
            WHEN v_top_wait.we LIKE 'LWLock:WAL%' THEN 'WAL contention'
            WHEN v_top_wait.we LIKE 'IO:%' THEN 'I/O bound'
            WHEN v_top_wait.we = 'Running:CPU' THEN 'CPU active (normal)'
            ELSE 'Review PostgreSQL docs'
        END;
        RETURN NEXT;
    END LOOP;
    section := 'LOCK CONTENTION';
    SELECT
        count(DISTINCT blocked_pid) AS blocked_count,
        max(blocked_duration) AS max_duration
    INTO v_lock_summary
    FROM (
        -- Lock contention from v2 ring (legacy retired).
        SELECT ls.blocked_pid,
               ls.blocked_duration_s * interval '1 second' AS blocked_duration
        FROM pgfr_record.lock_samples ls
        WHERE pgfr_record.epoch() + ls.sample_ts * interval '1 second'
              BETWEEN p_start_time AND p_end_time
    ) combined;
    metric := 'Blocked Sessions';
    value := COALESCE(v_lock_summary.blocked_count, 0)::text;
    interpretation := CASE
        WHEN COALESCE(v_lock_summary.blocked_count, 0) = 0 THEN 'No lock contention'
        ELSE format('Max blocked duration: %s', v_lock_summary.max_duration)
    END;
    RETURN NEXT;
    RETURN;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.summary_report(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Generates a comprehensive performance report aggregating compare, anomaly detection, wait events, and lock contention data into human-readable metrics and interpretations.';

-- =============================================================================
-- ANALYSIS FUNCTIONS (full implementations, cross-schema reads from pgfr_record.*)
-- =============================================================================

-- Compares database metrics between two time points, returning checkpoint, WAL, buffer, and IO activity deltas
CREATE OR REPLACE FUNCTION pgfr_analyze.compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    start_snapshot_at       TIMESTAMPTZ,
    end_snapshot_at         TIMESTAMPTZ,
    elapsed_seconds         NUMERIC,
    checkpoint_occurred     BOOLEAN,
    ckpt_timed_delta        BIGINT,
    ckpt_requested_delta    BIGINT,
    ckpt_write_time_ms      NUMERIC,
    ckpt_sync_time_ms       NUMERIC,
    ckpt_buffers_delta      BIGINT,
    wal_bytes_delta         BIGINT,
    wal_bytes_pretty        TEXT,
    wal_write_time_ms       NUMERIC,
    wal_sync_time_ms        NUMERIC,
    bgw_buffers_clean_delta       BIGINT,
    bgw_buffers_alloc_delta       BIGINT,
    bgw_buffers_backend_delta     BIGINT,
    bgw_buffers_backend_fsync_delta BIGINT,
    slots_count             INTEGER,
    slots_max_retained_wal  BIGINT,
    slots_max_retained_pretty TEXT,
    io_ckpt_reads_delta           BIGINT,
    io_ckpt_read_time_ms          NUMERIC,
    io_ckpt_writes_delta          BIGINT,
    io_ckpt_write_time_ms         NUMERIC,
    io_ckpt_fsyncs_delta          BIGINT,
    io_ckpt_fsync_time_ms         NUMERIC,
    io_autovacuum_reads_delta     BIGINT,
    io_autovacuum_read_time_ms    NUMERIC,
    io_autovacuum_writes_delta    BIGINT,
    io_autovacuum_write_time_ms   NUMERIC,
    io_client_reads_delta         BIGINT,
    io_client_read_time_ms        NUMERIC,
    io_client_writes_delta        BIGINT,
    io_client_write_time_ms       NUMERIC,
    io_bgwriter_reads_delta       BIGINT,
    io_bgwriter_read_time_ms      NUMERIC,
    io_bgwriter_writes_delta      BIGINT,
    io_bgwriter_write_time_ms     NUMERIC,
    temp_files_delta              BIGINT,
    temp_bytes_delta              BIGINT,
    temp_bytes_pretty             TEXT
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT * FROM pgfr_record.snapshots
        WHERE captured_at <= p_start_time
        ORDER BY captured_at DESC
        LIMIT 1
    ),
    end_snap AS (
        SELECT * FROM pgfr_record.snapshots
        WHERE captured_at >= p_end_time
        ORDER BY captured_at ASC
        LIMIT 1
    )
    SELECT
        s.captured_at,
        e.captured_at,
        EXTRACT(EPOCH FROM (e.captured_at - s.captured_at))::numeric,
        (s.checkpoint_time IS DISTINCT FROM e.checkpoint_time),
        e.ckpt_timed - s.ckpt_timed,
        e.ckpt_requested - s.ckpt_requested,
        (e.ckpt_write_time - s.ckpt_write_time)::numeric,
        (e.ckpt_sync_time - s.ckpt_sync_time)::numeric,
        e.ckpt_buffers - s.ckpt_buffers,
        e.wal_bytes - s.wal_bytes,
        pgfr_record._pretty_bytes(e.wal_bytes - s.wal_bytes),
        (e.wal_write_time - s.wal_write_time)::numeric,
        (e.wal_sync_time - s.wal_sync_time)::numeric,
        e.bgw_buffers_clean - s.bgw_buffers_clean,
        e.bgw_buffers_alloc - s.bgw_buffers_alloc,
        e.bgw_buffers_backend - s.bgw_buffers_backend,
        e.bgw_buffers_backend_fsync - s.bgw_buffers_backend_fsync,
        e.slots_count,
        e.slots_max_retained_wal,
        pgfr_record._pretty_bytes(e.slots_max_retained_wal),
        e.io_checkpointer_reads - s.io_checkpointer_reads,
        (e.io_checkpointer_read_time - s.io_checkpointer_read_time)::numeric,
        e.io_checkpointer_writes - s.io_checkpointer_writes,
        (e.io_checkpointer_write_time - s.io_checkpointer_write_time)::numeric,
        e.io_checkpointer_fsyncs - s.io_checkpointer_fsyncs,
        (e.io_checkpointer_fsync_time - s.io_checkpointer_fsync_time)::numeric,
        e.io_autovacuum_reads - s.io_autovacuum_reads,
        (e.io_autovacuum_read_time - s.io_autovacuum_read_time)::numeric,
        e.io_autovacuum_writes - s.io_autovacuum_writes,
        (e.io_autovacuum_write_time - s.io_autovacuum_write_time)::numeric,
        e.io_client_reads - s.io_client_reads,
        (e.io_client_read_time - s.io_client_read_time)::numeric,
        e.io_client_writes - s.io_client_writes,
        (e.io_client_write_time - s.io_client_write_time)::numeric,
        e.io_bgwriter_reads - s.io_bgwriter_reads,
        (e.io_bgwriter_read_time - s.io_bgwriter_read_time)::numeric,
        e.io_bgwriter_writes - s.io_bgwriter_writes,
        (e.io_bgwriter_write_time - s.io_bgwriter_write_time)::numeric,
        e.temp_files - s.temp_files,
        e.temp_bytes - s.temp_bytes,
        pgfr_record._pretty_bytes(e.temp_bytes - s.temp_bytes)
    FROM start_snap s, end_snap e
$$;
COMMENT ON FUNCTION pgfr_analyze.compare(TIMESTAMPTZ, TIMESTAMPTZ) IS 'Compares database metrics between two time points, returning checkpoint, WAL, buffer, and IO activity deltas.';

-- xmin horizon readers. Both read pgfr_record.snapshots.xmin_horizon_detail
-- (JSONB) directly; no sidecar joins. The collector populates the JSONB
-- with {source, age, holder} for the dominant holder per snapshot. See
-- REFERENCE.md "xmin horizon monitoring".

CREATE OR REPLACE FUNCTION pgfr_analyze.xmin_horizon_history(
    p_start TIMESTAMPTZ,
    p_end   TIMESTAMPTZ
)
RETURNS TABLE (
    captured_at           TIMESTAMPTZ,
    xmin_data_horizon_age BIGINT,
    slot_catalog_xmin_age BIGINT,
    xmin_any_horizon_age  BIGINT,
    source                TEXT,
    holder                JSONB
)
LANGUAGE sql STABLE AS $$
    SELECT s.captured_at,
           s.xmin_data_horizon_age,
           s.slot_catalog_xmin_age,
           s.xmin_any_horizon_age,
           s.xmin_horizon_detail->>'source' AS source,
           s.xmin_horizon_detail->'holder'  AS holder
    FROM pgfr_record.snapshots s
    WHERE s.captured_at BETWEEN p_start AND p_end
      AND (s.xmin_data_horizon_age IS NOT NULL OR s.slot_catalog_xmin_age IS NOT NULL)
    ORDER BY s.captured_at DESC;
$$;
COMMENT ON FUNCTION pgfr_analyze.xmin_horizon_history(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Timeline of xmin horizon ages and dominant-holder JSONB detail across snapshots in a window.';

CREATE OR REPLACE FUNCTION pgfr_analyze.current_xmin_horizon_holder()
RETURNS TABLE (
    captured_at           TIMESTAMPTZ,
    xmin_data_horizon_age BIGINT,
    slot_catalog_xmin_age BIGINT,
    source                TEXT,
    holder                JSONB
)
LANGUAGE sql STABLE AS $$
    SELECT s.captured_at,
           s.xmin_data_horizon_age,
           s.slot_catalog_xmin_age,
           s.xmin_horizon_detail->>'source' AS source,
           s.xmin_horizon_detail->'holder'  AS holder
    FROM pgfr_record.snapshots s
    WHERE s.xmin_horizon_detail IS NOT NULL
    ORDER BY s.captured_at DESC
    LIMIT 1;
$$;
COMMENT ON FUNCTION pgfr_analyze.current_xmin_horizon_holder() IS
'Quick-answer reader: zero rows on a healthy cluster, otherwise one row for the dominant xmin holder at the latest snapshot.';

-- Retrieves recent wait event samples from the flight recorder ring buffer
