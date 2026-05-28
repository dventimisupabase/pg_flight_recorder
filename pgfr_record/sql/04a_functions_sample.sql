-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia


-- The legacy ring buffer writers (sample, flush_ring_to_aggregates,
-- archive_ring_samples) and their COMMENT ON statements were removed when
-- the legacy 120-slot ring was retired. The v2 sampler lives in
-- pgfr_record.sample_ring() (08_ring_buffer_v2.sql); rotation lives in
-- pgfr_record.rotate_ring(). The cron jobs that drove the legacy writers
-- (pgfr_sample, pgfr_flush, pgfr_archive) are dropped by enable()'s
-- standing unschedule block on next install.


-- Removes aged aggregate and archived sample data based on configured retention periods
-- Deletes expired records from wait_event_aggregates, lock_aggregates, activity_aggregates, and all *_samples_archive tables
CREATE OR REPLACE FUNCTION pgfr_record.cleanup_aggregates()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_aggregate_retention interval;
    v_archive_retention interval;
    v_deleted_waits INTEGER;
    v_deleted_locks INTEGER;
    v_deleted_queries INTEGER;
    v_deleted_activity_archive INTEGER;
    v_deleted_lock_archive INTEGER;
    v_deleted_wait_archive INTEGER;
BEGIN
    v_aggregate_retention := (pgfr_record._get_config('aggregate_retention_days', '7') || ' days')::interval;
    v_archive_retention   := (pgfr_record._get_config('archive_retention_days', '7') || ' days')::interval;
    DELETE FROM pgfr_record.wait_event_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_waits = ROW_COUNT;
    DELETE FROM pgfr_record.lock_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_locks = ROW_COUNT;
    DELETE FROM pgfr_record.activity_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_queries = ROW_COUNT;
    DELETE FROM pgfr_record.activity_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_activity_archive = ROW_COUNT;
    DELETE FROM pgfr_record.lock_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_lock_archive = ROW_COUNT;
    DELETE FROM pgfr_record.wait_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_wait_archive = ROW_COUNT;
    IF v_deleted_waits > 0 OR v_deleted_locks > 0 OR v_deleted_queries > 0 OR
       v_deleted_activity_archive > 0 OR v_deleted_lock_archive > 0 OR v_deleted_wait_archive > 0 THEN
        RAISE NOTICE 'pgfr_record: Cleaned up % wait aggregates, % lock aggregates, % query aggregates, % activity archives, % lock archives, % wait archives',
            v_deleted_waits, v_deleted_locks, v_deleted_queries, v_deleted_activity_archive, v_deleted_lock_archive, v_deleted_wait_archive;
    END IF;
END;
$$;
COMMENT ON FUNCTION pgfr_record.cleanup_aggregates() IS 'Cleanup: Remove old aggregate and archive data based on retention periods';


-- Collects table-level statistics from pg_stat_user_tables
-- Captures tables based on configurable sampling mode: top_n, all, or threshold
CREATE OR REPLACE FUNCTION pgfr_record._collect_table_stats(p_snapshot_id BIGINT)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_top_n INTEGER;
    v_mode TEXT;
    v_threshold BIGINT;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('table_stats_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    v_top_n := COALESCE(
        pgfr_record._get_config('table_stats_top_n', '50')::integer,
        50
    );

    v_mode := COALESCE(
        pgfr_record._get_config('table_stats_mode', 'top_n'),
        'top_n'
    );

    v_threshold := COALESCE(
        pgfr_record._get_config('table_stats_activity_threshold', '0')::bigint,
        0
    );

    -- Handle different collection modes
    IF v_mode = 'all' THEN
        -- Collect all user tables
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO pgfr_record.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age, relminmxid_age, reltuples, vacuum_running,
            table_size_bytes, total_size_bytes, indexes_size_bytes
        )
        SELECT
            p_snapshot_id,
            NULL,  -- schemaname deprecated: derive via relid
            NULL,  -- relname deprecated: derive via relid
            st.relid,
            st.seq_scan,
            st.seq_tup_read,
            st.idx_scan,
            st.idx_tup_fetch,
            st.n_tup_ins,
            st.n_tup_upd,
            st.n_tup_del,
            st.n_tup_hot_upd,
            st.n_live_tup,
            st.n_dead_tup,
            st.n_mod_since_analyze,
            st.vacuum_count,
            st.autovacuum_count,
            st.analyze_count,
            st.autoanalyze_count,
            st.last_vacuum,
            st.last_autovacuum,
            st.last_analyze,
            st.last_autoanalyze,
            nullif(age(c.relfrozenxid)::integer, 2147483647) AS relfrozenxid_age,
            nullif(mxid_age(c.relminmxid)::integer, 2147483647) AS relminmxid_age,
            c.reltuples::bigint AS reltuples,
            EXISTS(SELECT 1 FROM pg_stat_progress_vacuum pv WHERE pv.relid = st.relid) AS vacuum_running,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid;

    ELSIF v_mode = 'threshold' THEN
        -- Collect tables with activity score above threshold
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO pgfr_record.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age, relminmxid_age, reltuples, vacuum_running,
            table_size_bytes, total_size_bytes, indexes_size_bytes
        )
        SELECT
            p_snapshot_id,
            NULL,  -- schemaname deprecated: derive via relid
            NULL,  -- relname deprecated: derive via relid
            st.relid,
            st.seq_scan,
            st.seq_tup_read,
            st.idx_scan,
            st.idx_tup_fetch,
            st.n_tup_ins,
            st.n_tup_upd,
            st.n_tup_del,
            st.n_tup_hot_upd,
            st.n_live_tup,
            st.n_dead_tup,
            st.n_mod_since_analyze,
            st.vacuum_count,
            st.autovacuum_count,
            st.analyze_count,
            st.autoanalyze_count,
            st.last_vacuum,
            st.last_autovacuum,
            st.last_analyze,
            st.last_autoanalyze,
            nullif(age(c.relfrozenxid)::integer, 2147483647) AS relfrozenxid_age,
            nullif(mxid_age(c.relminmxid)::integer, 2147483647) AS relminmxid_age,
            c.reltuples::bigint AS reltuples,
            EXISTS(SELECT 1 FROM pg_stat_progress_vacuum pv WHERE pv.relid = st.relid) AS vacuum_running,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid
        WHERE (COALESCE(st.seq_tup_read, 0) + COALESCE(st.idx_tup_fetch, 0) +
               COALESCE(st.n_tup_ins, 0) + COALESCE(st.n_tup_upd, 0) + COALESCE(st.n_tup_del, 0)) >= v_threshold;

    ELSE
        -- Default: top_n mode (also handles invalid mode values)
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO pgfr_record.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age, relminmxid_age, reltuples, vacuum_running,
            table_size_bytes, total_size_bytes, indexes_size_bytes
        )
        SELECT
            p_snapshot_id,
            NULL,  -- schemaname deprecated: derive via relid
            NULL,  -- relname deprecated: derive via relid
            st.relid,
            st.seq_scan,
            st.seq_tup_read,
            st.idx_scan,
            st.idx_tup_fetch,
            st.n_tup_ins,
            st.n_tup_upd,
            st.n_tup_del,
            st.n_tup_hot_upd,
            st.n_live_tup,
            st.n_dead_tup,
            st.n_mod_since_analyze,
            st.vacuum_count,
            st.autovacuum_count,
            st.analyze_count,
            st.autoanalyze_count,
            st.last_vacuum,
            st.last_autovacuum,
            st.last_analyze,
            st.last_autoanalyze,
            nullif(age(c.relfrozenxid)::integer, 2147483647) AS relfrozenxid_age,
            nullif(mxid_age(c.relminmxid)::integer, 2147483647) AS relminmxid_age,
            c.reltuples::bigint AS reltuples,
            EXISTS(SELECT 1 FROM pg_stat_progress_vacuum pv WHERE pv.relid = st.relid) AS vacuum_running,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid
        ORDER BY (COALESCE(st.seq_tup_read, 0) + COALESCE(st.idx_tup_fetch, 0) +
                  COALESCE(st.n_tup_ins, 0) + COALESCE(st.n_tup_upd, 0) + COALESCE(st.n_tup_del, 0)) DESC
        LIMIT v_top_n;
    END IF;

END;
$$;


-- Collects index-level statistics from pg_stat_user_indexes
-- Captures all user indexes with their usage metrics and sizes
CREATE OR REPLACE FUNCTION pgfr_record._collect_index_stats(p_snapshot_id BIGINT)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('index_stats_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Note: schemaname/relname/indexrelname are deprecated; derive via relation_names or ::regclass
    INSERT INTO pgfr_record.index_snapshots (
        snapshot_id, schemaname, relname, indexrelname, relid, indexrelid,
        idx_scan, idx_tup_read, idx_tup_fetch, index_size_bytes
    )
    SELECT
        p_snapshot_id,
        NULL,  -- schemaname deprecated: derive via relid
        NULL,  -- relname deprecated: derive via relid
        NULL,  -- indexrelname deprecated: derive via indexrelid
        i.relid,
        i.indexrelid,
        i.idx_scan,
        i.idx_tup_read,
        i.idx_tup_fetch,
        pg_relation_size(i.indexrelid) AS index_size_bytes
    FROM pg_stat_user_indexes i;
END;
$$;


-- Collects PostgreSQL configuration snapshot from pg_settings
-- Captures relevant settings for incident analysis and change tracking
CREATE OR REPLACE FUNCTION pgfr_record._collect_config_snapshot(p_snapshot_id BIGINT)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_relevant_params TEXT[] := ARRAY[
        -- Memory
        'shared_buffers',
        'work_mem',
        'maintenance_work_mem',
        'effective_cache_size',
        'temp_buffers',
        -- Connections
        'max_connections',
        'superuser_reserved_connections',
        -- Query Planning
        'random_page_cost',
        'seq_page_cost',
        'effective_io_concurrency',
        'default_statistics_target',
        'enable_seqscan',
        'enable_indexscan',
        'enable_bitmapscan',
        'enable_hashjoin',
        'enable_mergejoin',
        'enable_nestloop',
        -- Parallelism
        'max_parallel_workers',
        'max_parallel_workers_per_gather',
        'max_worker_processes',
        'parallel_setup_cost',
        'parallel_tuple_cost',
        -- WAL
        'wal_level',
        'max_wal_size',
        'min_wal_size',
        'wal_buffers',
        'checkpoint_timeout',
        'checkpoint_completion_target',
        'checkpoint_warning',
        -- Autovacuum
        'autovacuum',
        'autovacuum_max_workers',
        'autovacuum_naptime',
        'autovacuum_vacuum_threshold',
        'autovacuum_vacuum_scale_factor',
        'autovacuum_analyze_threshold',
        'autovacuum_analyze_scale_factor',
        'autovacuum_vacuum_cost_delay',
        'autovacuum_vacuum_cost_limit',
        'autovacuum_freeze_max_age',
        -- Logging
        'log_min_duration_statement',
        'log_lock_waits',
        'log_temp_files',
        'log_autovacuum_min_duration',
        -- Statement Behavior
        'statement_timeout',
        'lock_timeout',
        'idle_in_transaction_session_timeout',
        -- Resource Limits
        'temp_file_limit',
        'max_prepared_transactions',
        'max_locks_per_transaction',
        -- Extensions
        'shared_preload_libraries',
        'pg_stat_statements.track',
        'pg_stat_statements.max'
    ];
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('config_snapshots_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Only insert parameters that have changed since the most recent snapshot
    -- This reduces storage by 99%+ in stable environments while maintaining
    -- full point-in-time query capability via DISTINCT ON (cs.name) pattern
    INSERT INTO pgfr_record.config_snapshots (
        snapshot_id, name, setting, unit, source, sourcefile
    )
    WITH latest_config AS (
        SELECT DISTINCT ON (cs.name)
            cs.name,
            cs.setting,
            cs.unit,
            cs.source,
            cs.sourcefile
        FROM pgfr_record.config_snapshots cs
        JOIN pgfr_record.snapshots s ON s.id = cs.snapshot_id
        WHERE s.id < p_snapshot_id  -- Previous snapshots only
        ORDER BY cs.name, s.id DESC
    )
    SELECT
        p_snapshot_id,
        pg.name,
        pg.setting,
        pg.unit,
        pg.source,
        pg.sourcefile
    FROM pg_settings pg
    WHERE pg.name = ANY(v_relevant_params)
    AND (
        -- No previous snapshot exists (first run)
        NOT EXISTS (SELECT 1 FROM latest_config)
        OR
        -- Parameter didn't exist in previous snapshot (new parameter tracked)
        NOT EXISTS (SELECT 1 FROM latest_config lc WHERE lc.name = pg.name)
        OR
        -- Parameter value changed
        EXISTS (
            SELECT 1 FROM latest_config lc
            WHERE lc.name = pg.name
            AND (
                lc.setting IS DISTINCT FROM pg.setting
                OR lc.source IS DISTINCT FROM pg.source
                OR lc.sourcefile IS DISTINCT FROM pg.sourcefile
            )
        )
    );
END;
$$;


-- Collects database-level and role-level configuration overrides from pg_db_role_setting
-- These overrides (ALTER DATABASE/ROLE SET) can significantly impact performance but are easily overlooked
CREATE OR REPLACE FUNCTION pgfr_record._collect_db_role_config_snapshot(p_snapshot_id BIGINT)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('db_role_config_snapshots_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Only insert database/role config overrides that have changed since the most recent snapshot
    -- This reduces storage significantly in stable environments
    INSERT INTO pgfr_record.db_role_config_snapshots (
        snapshot_id, database_name, role_name, parameter_name, parameter_value
    )
    WITH latest_db_role_config AS (
        SELECT DISTINCT ON (drc.database_name, drc.role_name, drc.parameter_name)
            drc.database_name,
            drc.role_name,
            drc.parameter_name,
            drc.parameter_value
        FROM pgfr_record.db_role_config_snapshots drc
        JOIN pgfr_record.snapshots s ON s.id = drc.snapshot_id
        WHERE s.id < p_snapshot_id  -- Previous snapshots only
        ORDER BY drc.database_name, drc.role_name, drc.parameter_name, s.id DESC
    ),
    current_config AS (
        SELECT
            p_snapshot_id AS snapshot_id,
            COALESCE(d.datname, '') AS database_name,
            COALESCE(r.rolname, '') AS role_name,
            split_part(setting, '=', 1) AS parameter_name,
            split_part(setting, '=', 2) AS parameter_value
        FROM pg_db_role_setting drs
        CROSS JOIN LATERAL unnest(drs.setconfig) AS setting
        LEFT JOIN pg_database d ON d.oid = drs.setdatabase
        LEFT JOIN pg_roles r ON r.oid = drs.setrole
        WHERE drs.setconfig IS NOT NULL
    )
    SELECT
        cc.snapshot_id,
        cc.database_name,
        cc.role_name,
        cc.parameter_name,
        cc.parameter_value
    FROM current_config cc
    WHERE (
        -- No previous snapshot exists (first run)
        NOT EXISTS (SELECT 1 FROM latest_db_role_config)
        OR
        -- Override didn't exist in previous snapshot (new override)
        NOT EXISTS (
            SELECT 1 FROM latest_db_role_config lc
            WHERE lc.database_name = cc.database_name
            AND lc.role_name = cc.role_name
            AND lc.parameter_name = cc.parameter_name
        )
        OR
        -- Override value changed
        EXISTS (
            SELECT 1 FROM latest_db_role_config lc
            WHERE lc.database_name = cc.database_name
            AND lc.role_name = cc.role_name
            AND lc.parameter_name = cc.parameter_name
            AND lc.parameter_value IS DISTINCT FROM cc.parameter_value
        )
    )
    UNION ALL
    -- Capture removed overrides as NULL value to track deletions
    SELECT
        p_snapshot_id,
        lc.database_name,
        lc.role_name,
        lc.parameter_name,
        NULL AS parameter_value
    FROM latest_db_role_config lc
    WHERE NOT EXISTS (
        SELECT 1 FROM current_config cc
        WHERE cc.database_name = lc.database_name
        AND cc.role_name = lc.role_name
        AND cc.parameter_name = lc.parameter_name
    );
END;
$$;


-- Snapshots: Collect comprehensive snapshot of PostgreSQL system metrics (WAL, checkpoints, I/O, replication, statements)
-- Returns the captured timestamp for downstream processing and analysis
