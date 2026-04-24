CREATE OR REPLACE FUNCTION pgfr_record.snapshot()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql AS $$
DECLARE
    v_pg_version INTEGER;
    v_captured_at TIMESTAMPTZ := now();
    v_snapshot_id BIGINT;
    v_autovacuum_workers INTEGER;
    v_slots_count INTEGER;
    v_slots_max_retained BIGINT;
    v_temp_files BIGINT;
    v_temp_bytes BIGINT;
    v_io_ckpt_reads BIGINT;
    v_io_ckpt_read_time DOUBLE PRECISION;
    v_io_ckpt_writes BIGINT;
    v_io_ckpt_write_time DOUBLE PRECISION;
    v_io_ckpt_fsyncs BIGINT;
    v_io_ckpt_fsync_time DOUBLE PRECISION;
    v_io_av_reads BIGINT;
    v_io_av_read_time DOUBLE PRECISION;
    v_io_av_writes BIGINT;
    v_io_av_write_time DOUBLE PRECISION;
    v_io_client_reads BIGINT;
    v_io_client_read_time DOUBLE PRECISION;
    v_io_client_writes BIGINT;
    v_io_client_write_time DOUBLE PRECISION;
    v_io_bgw_reads BIGINT;
    v_io_bgw_read_time DOUBLE PRECISION;
    v_io_bgw_writes BIGINT;
    v_io_bgw_write_time DOUBLE PRECISION;
    v_stat_id INTEGER;
    v_should_skip BOOLEAN;
    v_checkpoint_info RECORD;
    v_xact_commit BIGINT;
    v_xact_rollback BIGINT;
    v_blks_read BIGINT;
    v_blks_hit BIGINT;
    v_connections_active INTEGER;
    v_connections_total INTEGER;
    v_connections_max INTEGER;
    v_db_size_bytes BIGINT;
    v_capacity_enabled BOOLEAN;
    v_datfrozenxid_age INTEGER;
    v_datminmxid_age INTEGER;
    v_archived_count BIGINT;
    v_last_archived_wal TEXT;
    v_last_archived_time TIMESTAMPTZ;
    v_failed_count BIGINT;
    v_last_failed_wal TEXT;
    v_last_failed_time TIMESTAMPTZ;
    v_archiver_stats_reset TIMESTAMPTZ;
    v_archive_mode TEXT;
    v_confl_tablespace BIGINT;
    v_confl_lock BIGINT;
    v_confl_snapshot BIGINT;
    v_confl_bufferpin BIGINT;
    v_confl_deadlock BIGINT;
    v_confl_active_logicalslot BIGINT;
    v_is_standby BOOLEAN;
    v_max_catalog_oid BIGINT;
    v_large_object_count BIGINT;
BEGIN
    v_should_skip := pgfr_record._check_circuit_breaker('snapshot');
    IF v_should_skip THEN
        PERFORM pgfr_record._record_collection_skip('snapshot', 'Circuit breaker tripped - last run exceeded threshold');
        RAISE NOTICE 'pgfr_record: Skipping snapshot collection due to circuit breaker';
        RETURN v_captured_at;
    END IF;
    PERFORM pgfr_record._check_schema_size();
    v_stat_id := pgfr_record._record_collection_start('snapshot', 7);
    DECLARE
        v_lock_strategy TEXT;
        v_lock_timeout_ms INTEGER;
    BEGIN
        v_lock_strategy := COALESCE(
            pgfr_record._get_config('lock_timeout_strategy', 'fail_fast'),
            'fail_fast'
        );
        v_lock_timeout_ms := CASE v_lock_strategy
            WHEN 'skip_if_locked' THEN 0
            WHEN 'patient' THEN 500
            ELSE 100
        END;
        PERFORM set_config('lock_timeout', v_lock_timeout_ms::text, true);
    END;
    PERFORM set_config('work_mem',
        COALESCE(pgfr_record._get_config('work_mem_kb', '2048'), '2048') || 'kB',
        true);
    v_pg_version := pgfr_record._pg_version();
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        SELECT count(*)::integer INTO v_autovacuum_workers
        FROM pg_stat_activity
        WHERE backend_type = 'autovacuum worker';
        SELECT
            count(*)::integer,
            COALESCE(max(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)), 0)
        INTO v_slots_count, v_slots_max_retained
        FROM pg_replication_slots;
        SELECT COALESCE(temp_files, 0), COALESCE(temp_bytes, 0)
        INTO v_temp_files, v_temp_bytes
        FROM pg_stat_database
        WHERE datname = current_database();
        v_checkpoint_info := pg_control_checkpoint();
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: System stats collection failed: %', SQLERRM;
        v_autovacuum_workers := 0;
        v_slots_count := 0;
        v_slots_max_retained := 0;
        v_temp_files := 0;
        v_temp_bytes := 0;
    END;
    IF v_pg_version >= 16 THEN
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        SELECT
            COALESCE(sum(reads) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(read_time) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(writes) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(write_time) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(fsyncs) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(fsync_time) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(reads) FILTER (WHERE backend_type = 'autovacuum worker'), 0),
            COALESCE(sum(read_time) FILTER (WHERE backend_type = 'autovacuum worker'), 0),
            COALESCE(sum(writes) FILTER (WHERE backend_type = 'autovacuum worker'), 0),
            COALESCE(sum(write_time) FILTER (WHERE backend_type = 'autovacuum worker'), 0),
            COALESCE(sum(reads) FILTER (WHERE backend_type = 'client backend'), 0),
            COALESCE(sum(read_time) FILTER (WHERE backend_type = 'client backend'), 0),
            COALESCE(sum(writes) FILTER (WHERE backend_type = 'client backend'), 0),
            COALESCE(sum(write_time) FILTER (WHERE backend_type = 'client backend'), 0),
            COALESCE(sum(reads) FILTER (WHERE backend_type = 'background writer'), 0),
            COALESCE(sum(read_time) FILTER (WHERE backend_type = 'background writer'), 0),
            COALESCE(sum(writes) FILTER (WHERE backend_type = 'background writer'), 0),
            COALESCE(sum(write_time) FILTER (WHERE backend_type = 'background writer'), 0)
        INTO
            v_io_ckpt_reads, v_io_ckpt_read_time, v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time,
            v_io_av_reads, v_io_av_read_time, v_io_av_writes, v_io_av_write_time,
            v_io_client_reads, v_io_client_read_time, v_io_client_writes, v_io_client_write_time,
            v_io_bgw_reads, v_io_bgw_read_time, v_io_bgw_writes, v_io_bgw_write_time
        FROM pg_stat_io;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: pg_stat_io collection failed: %', SQLERRM;
        v_io_ckpt_reads := 0;
        v_io_ckpt_read_time := 0;
        v_io_ckpt_writes := 0;
        v_io_ckpt_write_time := 0;
        v_io_ckpt_fsyncs := 0;
        v_io_ckpt_fsync_time := 0;
        v_io_av_reads := 0;
        v_io_av_read_time := 0;
        v_io_av_writes := 0;
        v_io_av_write_time := 0;
        v_io_client_reads := 0;
        v_io_client_read_time := 0;
        v_io_client_writes := 0;
        v_io_client_write_time := 0;
        v_io_bgw_reads := 0;
        v_io_bgw_read_time := 0;
        v_io_bgw_writes := 0;
        v_io_bgw_write_time := 0;
    END;
    END IF;
    v_capacity_enabled := COALESCE(
        pgfr_record._get_config('capacity_planning_enabled', 'true')::boolean,
        true
    );
    IF v_capacity_enabled THEN
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        IF COALESCE(pgfr_record._get_config('collect_connection_metrics', 'true')::boolean, true) THEN
            SELECT
                xact_commit,
                xact_rollback,
                blks_read,
                blks_hit
            INTO v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit
            FROM pg_stat_database
            WHERE datname = current_database();
        END IF;
        IF COALESCE(pgfr_record._get_config('collect_connection_metrics', 'true')::boolean, true) THEN
            v_connections_max := current_setting('max_connections')::integer;
            SELECT
                count(*) FILTER (WHERE state NOT IN ('idle')),
                count(*)
            INTO v_connections_active, v_connections_total
            FROM pg_stat_activity;
        END IF;
        IF COALESCE(pgfr_record._get_config('collect_database_size', 'true')::boolean, true) THEN
            SELECT sum(relpages::bigint * current_setting('block_size')::bigint)
            INTO v_db_size_bytes
            FROM pg_class
            WHERE relkind IN ('r', 't', 'i', 'm')
              AND relpages > 0;
        END IF;
        SELECT
            age(datfrozenxid)::integer,
            mxid_age(datminmxid)::integer
        INTO v_datfrozenxid_age, v_datminmxid_age
        FROM pg_database
        WHERE datname = current_database();
        -- Collect OID exhaustion metrics
        SELECT max(oid)::bigint INTO v_max_catalog_oid FROM pg_class;
        SELECT count(*)::bigint INTO v_large_object_count FROM pg_largeobject_metadata;
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Capacity planning metrics collection failed: %', SQLERRM;
        v_xact_commit := NULL;
        v_xact_rollback := NULL;
        v_blks_read := NULL;
        v_blks_hit := NULL;
        v_connections_active := NULL;
        v_connections_total := NULL;
        v_connections_max := NULL;
        v_db_size_bytes := NULL;
        v_datfrozenxid_age := NULL;
        v_datminmxid_age := NULL;
        v_max_catalog_oid := NULL;
        v_large_object_count := NULL;
    END;
    END IF;
    -- Collect archiver stats (conditional on archive_mode != 'off')
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        v_archive_mode := current_setting('archive_mode', true);
        IF v_archive_mode IS NOT NULL AND v_archive_mode != 'off' THEN
            SELECT
                archived_count,
                last_archived_wal,
                last_archived_time,
                failed_count,
                last_failed_wal,
                last_failed_time,
                stats_reset
            INTO
                v_archived_count,
                v_last_archived_wal,
                v_last_archived_time,
                v_failed_count,
                v_last_failed_wal,
                v_last_failed_time,
                v_archiver_stats_reset
            FROM pg_stat_archiver;
        END IF;
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Archiver stats collection failed: %', SQLERRM;
    END;
    -- Collect database conflict stats (only populated on standby servers)
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        v_is_standby := pg_is_in_recovery();
        IF v_is_standby THEN
            IF v_pg_version >= 16 THEN
                SELECT
                    confl_tablespace,
                    confl_lock,
                    confl_snapshot,
                    confl_bufferpin,
                    confl_deadlock,
                    confl_active_logicalslot
                INTO
                    v_confl_tablespace,
                    v_confl_lock,
                    v_confl_snapshot,
                    v_confl_bufferpin,
                    v_confl_deadlock,
                    v_confl_active_logicalslot
                FROM pg_stat_database_conflicts
                WHERE datname = current_database();
            ELSE
                SELECT
                    confl_tablespace,
                    confl_lock,
                    confl_snapshot,
                    confl_bufferpin,
                    confl_deadlock
                INTO
                    v_confl_tablespace,
                    v_confl_lock,
                    v_confl_snapshot,
                    v_confl_bufferpin,
                    v_confl_deadlock
                FROM pg_stat_database_conflicts
                WHERE datname = current_database();
            END IF;
        END IF;
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Database conflict stats collection failed: %', SQLERRM;
    END;
    IF v_pg_version >= 18 THEN
        INSERT INTO pgfr_record.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            io_checkpointer_reads, io_checkpointer_read_time,
            io_checkpointer_writes, io_checkpointer_write_time, io_checkpointer_fsyncs, io_checkpointer_fsync_time,
            io_autovacuum_reads, io_autovacuum_read_time,
            io_autovacuum_writes, io_autovacuum_write_time,
            io_client_reads, io_client_read_time,
            io_client_writes, io_client_write_time,
            io_bgwriter_reads, io_bgwriter_read_time,
            io_bgwriter_writes, io_bgwriter_write_time,
            temp_files, temp_bytes,
            xact_commit, xact_rollback, blks_read, blks_hit,
            connections_active, connections_total, connections_max,
            db_size_bytes, datfrozenxid_age, datminmxid_age,
            archived_count, last_archived_wal, last_archived_time,
            failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
            confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock, confl_active_logicalslot,
            max_catalog_oid, large_object_count
        )
        SELECT
            v_captured_at, v_pg_version,
            -- pg18: pg_stat_wal dropped wal_write_time and wal_sync_time; store null
            w.wal_records, w.wal_fpi, w.wal_bytes::bigint, NULL, NULL,
            v_checkpoint_info.redo_lsn,
            v_checkpoint_info.checkpoint_time,
            c.num_timed, c.num_requested, c.write_time, c.sync_time, c.buffers_written,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            NULL, NULL,
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_io_ckpt_reads, v_io_ckpt_read_time,
            v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time,
            v_io_av_reads, v_io_av_read_time,
            v_io_av_writes, v_io_av_write_time,
            v_io_client_reads, v_io_client_read_time,
            v_io_client_writes, v_io_client_write_time,
            v_io_bgw_reads, v_io_bgw_read_time,
            v_io_bgw_writes, v_io_bgw_write_time,
            v_temp_files, v_temp_bytes,
            v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit,
            v_connections_active, v_connections_total, v_connections_max,
            v_db_size_bytes, v_datfrozenxid_age, v_datminmxid_age,
            v_archived_count, v_last_archived_wal, v_last_archived_time,
            v_failed_count, v_last_failed_wal, v_last_failed_time, v_archiver_stats_reset,
            v_confl_tablespace, v_confl_lock, v_confl_snapshot, v_confl_bufferpin, v_confl_deadlock, v_confl_active_logicalslot,
            v_max_catalog_oid, v_large_object_count
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_checkpointer c
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;
    ELSIF v_pg_version = 17 THEN
        INSERT INTO pgfr_record.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            io_checkpointer_reads, io_checkpointer_read_time,
            io_checkpointer_writes, io_checkpointer_write_time, io_checkpointer_fsyncs, io_checkpointer_fsync_time,
            io_autovacuum_reads, io_autovacuum_read_time,
            io_autovacuum_writes, io_autovacuum_write_time,
            io_client_reads, io_client_read_time,
            io_client_writes, io_client_write_time,
            io_bgwriter_reads, io_bgwriter_read_time,
            io_bgwriter_writes, io_bgwriter_write_time,
            temp_files, temp_bytes,
            xact_commit, xact_rollback, blks_read, blks_hit,
            connections_active, connections_total, connections_max,
            db_size_bytes, datfrozenxid_age, datminmxid_age,
            archived_count, last_archived_wal, last_archived_time,
            failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
            confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock, confl_active_logicalslot,
            max_catalog_oid, large_object_count
        )
        SELECT
            v_captured_at, v_pg_version,
            w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_write_time, w.wal_sync_time,
            v_checkpoint_info.redo_lsn,
            v_checkpoint_info.checkpoint_time,
            c.num_timed, c.num_requested, c.write_time, c.sync_time, c.buffers_written,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            NULL, NULL,
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_io_ckpt_reads, v_io_ckpt_read_time,
            v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time,
            v_io_av_reads, v_io_av_read_time,
            v_io_av_writes, v_io_av_write_time,
            v_io_client_reads, v_io_client_read_time,
            v_io_client_writes, v_io_client_write_time,
            v_io_bgw_reads, v_io_bgw_read_time,
            v_io_bgw_writes, v_io_bgw_write_time,
            v_temp_files, v_temp_bytes,
            v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit,
            v_connections_active, v_connections_total, v_connections_max,
            v_db_size_bytes, v_datfrozenxid_age, v_datminmxid_age,
            v_archived_count, v_last_archived_wal, v_last_archived_time,
            v_failed_count, v_last_failed_wal, v_last_failed_time, v_archiver_stats_reset,
            v_confl_tablespace, v_confl_lock, v_confl_snapshot, v_confl_bufferpin, v_confl_deadlock, v_confl_active_logicalslot,
            v_max_catalog_oid, v_large_object_count
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_checkpointer c
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;
    ELSIF v_pg_version = 16 THEN
        INSERT INTO pgfr_record.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            io_checkpointer_reads, io_checkpointer_read_time,
            io_checkpointer_writes, io_checkpointer_write_time, io_checkpointer_fsyncs, io_checkpointer_fsync_time,
            io_autovacuum_reads, io_autovacuum_read_time,
            io_autovacuum_writes, io_autovacuum_write_time,
            io_client_reads, io_client_read_time,
            io_client_writes, io_client_write_time,
            io_bgwriter_reads, io_bgwriter_read_time,
            io_bgwriter_writes, io_bgwriter_write_time,
            temp_files, temp_bytes,
            xact_commit, xact_rollback, blks_read, blks_hit,
            connections_active, connections_total, connections_max,
            db_size_bytes, datfrozenxid_age, datminmxid_age,
            archived_count, last_archived_wal, last_archived_time,
            failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
            confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock, confl_active_logicalslot,
            max_catalog_oid, large_object_count
        )
        SELECT
            v_captured_at, v_pg_version,
            w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_write_time, w.wal_sync_time,
            v_checkpoint_info.redo_lsn,
            v_checkpoint_info.checkpoint_time,
            b.checkpoints_timed, b.checkpoints_req, b.checkpoint_write_time, b.checkpoint_sync_time, b.buffers_checkpoint,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            b.buffers_backend, b.buffers_backend_fsync,
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_io_ckpt_reads, v_io_ckpt_read_time,
            v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time,
            v_io_av_reads, v_io_av_read_time,
            v_io_av_writes, v_io_av_write_time,
            v_io_client_reads, v_io_client_read_time,
            v_io_client_writes, v_io_client_write_time,
            v_io_bgw_reads, v_io_bgw_read_time,
            v_io_bgw_writes, v_io_bgw_write_time,
            v_temp_files, v_temp_bytes,
            v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit,
            v_connections_active, v_connections_total, v_connections_max,
            v_db_size_bytes, v_datfrozenxid_age, v_datminmxid_age,
            v_archived_count, v_last_archived_wal, v_last_archived_time,
            v_failed_count, v_last_failed_wal, v_last_failed_time, v_archiver_stats_reset,
            v_confl_tablespace, v_confl_lock, v_confl_snapshot, v_confl_bufferpin, v_confl_deadlock, v_confl_active_logicalslot,
            v_max_catalog_oid, v_large_object_count
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;
    ELSIF v_pg_version = 15 THEN
        INSERT INTO pgfr_record.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            temp_files, temp_bytes,
            xact_commit, xact_rollback, blks_read, blks_hit,
            connections_active, connections_total, connections_max,
            db_size_bytes, datfrozenxid_age, datminmxid_age,
            archived_count, last_archived_wal, last_archived_time,
            failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
            confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock,
            max_catalog_oid, large_object_count
        )
        SELECT
            v_captured_at, v_pg_version,
            w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_write_time, w.wal_sync_time,
            v_checkpoint_info.redo_lsn,
            v_checkpoint_info.checkpoint_time,
            b.checkpoints_timed, b.checkpoints_req, b.checkpoint_write_time, b.checkpoint_sync_time, b.buffers_checkpoint,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            b.buffers_backend, b.buffers_backend_fsync,
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_temp_files, v_temp_bytes,
            v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit,
            v_connections_active, v_connections_total, v_connections_max,
            v_db_size_bytes, v_datfrozenxid_age, v_datminmxid_age,
            v_archived_count, v_last_archived_wal, v_last_archived_time,
            v_failed_count, v_last_failed_wal, v_last_failed_time, v_archiver_stats_reset,
            v_confl_tablespace, v_confl_lock, v_confl_snapshot, v_confl_bufferpin, v_confl_deadlock,
            v_max_catalog_oid, v_large_object_count
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;
    ELSE
        RAISE EXCEPTION 'Unsupported PostgreSQL version: %. Requires 15, 16, 17, or 18.', v_pg_version;
    END IF;
    PERFORM pgfr_record._record_section_success(v_stat_id);
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        INSERT INTO pgfr_record.replication_snapshots (
            snapshot_id, pid, client_addr, application_name, state, sync_state,
            sent_lsn, write_lsn, flush_lsn, replay_lsn,
            write_lag, flush_lag, replay_lag
        )
        SELECT
            v_snapshot_id,
            pid,
            client_addr,
            application_name,
            state,
            sync_state,
            sent_lsn,
            write_lsn,
            flush_lsn,
            replay_lsn,
            write_lag,
            flush_lag,
            replay_lag
        FROM pg_stat_replication;
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Replication stats collection failed: %', SQLERRM;
    END;
    IF pgfr_record._has_pg_stat_statements()
       AND pgfr_record._get_config('statements_enabled', 'auto') != 'false'
    THEN
        DECLARE
            v_stmt_status TEXT;
            v_last_statements_collection TIMESTAMPTZ;
            v_statements_interval_minutes INTEGER;
            v_should_collect BOOLEAN := TRUE;
            v_prev_snapshot_id BIGINT;
        BEGIN
            v_statements_interval_minutes := COALESCE(
                pgfr_record._get_config('statements_interval_minutes', '1')::integer,
                1
            );
            SELECT s.id, s.captured_at
              INTO v_prev_snapshot_id, v_last_statements_collection
            FROM pgfr_record.snapshots s
            WHERE EXISTS (
                SELECT 1 FROM pgfr_record.statement_snapshots ss
                WHERE ss.snapshot_id = s.id
            )
            ORDER BY s.captured_at DESC
            LIMIT 1;
            IF v_last_statements_collection IS NOT NULL
               AND v_last_statements_collection > now() - (v_statements_interval_minutes || ' minutes')::interval
            THEN
                v_should_collect := FALSE;
            END IF;
            IF v_should_collect THEN
                PERFORM pgfr_record._set_section_timeout();
                DECLARE
                    v_check_conflicts BOOLEAN;
                    v_pss_conflict BOOLEAN;
                BEGIN
                    v_check_conflicts := COALESCE(
                        pgfr_record._get_config('check_pss_conflicts', 'true')::boolean,
                        true
                    );
                    IF v_check_conflicts THEN
                        SELECT EXISTS(
                            SELECT 1 FROM pg_stat_activity
                            WHERE query ILIKE '%pg_stat_statements%'
                              AND state = 'active'
                              AND pid != pg_backend_pid()
                              AND backend_type = 'client backend'
                        ) INTO v_pss_conflict;
                        IF v_pss_conflict THEN
                            RAISE NOTICE 'pgfr_record: Skipping pg_stat_statements - concurrent reader detected';
                            v_should_collect := FALSE;
                        END IF;
                    END IF;
                END;
                IF v_should_collect THEN
                    SELECT status INTO v_stmt_status
                    FROM pgfr_record._check_statements_health();
                    IF v_stmt_status = 'HIGH_CHURN' THEN
                        RAISE WARNING 'pgfr_record: Skipping pg_stat_statements collection - high churn detected (>95%% utilization)';
                    ELSE
                -- pg17 renamed blk_read_time -> shared_blk_read_time in pg_stat_statements.
                -- case when cannot reference a nonexistent column even in a dead branch;
                -- use execute with the correct column name chosen at runtime.
                EXECUTE format(
                    $q$
                    WITH current_stmts AS (
                        SELECT
                            s.queryid, s.userid, s.dbid,
                            left(s.query, 500) AS query_preview,
                            s.calls, s.total_exec_time, s.min_exec_time,
                            s.max_exec_time, s.mean_exec_time, s.rows,
                            s.shared_blks_hit, s.shared_blks_read,
                            s.shared_blks_dirtied, s.shared_blks_written,
                            s.temp_blks_read, s.temp_blks_written,
                            s.%I AS blk_read_time,
                            s.%I AS blk_write_time,
                            s.wal_records, s.wal_bytes
                        FROM pg_stat_statements s
                        WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
                          AND s.calls >= COALESCE(pgfr_record._get_config('statements_min_calls', '1')::integer, 1)
                        ORDER BY CASE
                            WHEN pgfr_record._get_config('statements_ranking_metric', 'buffers') = 'time'
                            THEN s.total_exec_time
                            ELSE s.shared_blks_hit + s.shared_blks_read + s.temp_blks_read + s.temp_blks_written
                        END DESC
                        LIMIT COALESCE(pgfr_record._get_config('statements_top_n', '50')::integer, 50)
                    )
                    INSERT INTO pgfr_record.statement_snapshots (
                        snapshot_id, queryid, userid, dbid, query_preview,
                        calls, total_exec_time, min_exec_time, max_exec_time,
                        mean_exec_time, rows,
                        shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
                        temp_blks_read, temp_blks_written,
                        blk_read_time, blk_write_time,
                        wal_records, wal_bytes,
                        calls_delta, total_exec_time_delta, rows_delta,
                        shared_blks_hit_delta, shared_blks_read_delta,
                        shared_blks_dirtied_delta, shared_blks_written_delta,
                        temp_blks_read_delta, temp_blks_written_delta,
                        blk_read_time_delta, blk_write_time_delta,
                        wal_records_delta, wal_bytes_delta
                    )
                    SELECT
                        $1, c.queryid, c.userid, c.dbid, c.query_preview,
                        c.calls, c.total_exec_time, c.min_exec_time,
                        c.max_exec_time, c.mean_exec_time, c.rows,
                        c.shared_blks_hit, c.shared_blks_read,
                        c.shared_blks_dirtied, c.shared_blks_written,
                        c.temp_blks_read, c.temp_blks_written,
                        c.blk_read_time, c.blk_write_time,
                        c.wal_records, c.wal_bytes,
                        CASE WHEN prev.calls IS NOT NULL AND c.calls >= prev.calls THEN c.calls - prev.calls ELSE NULL END,
                        CASE WHEN prev.total_exec_time IS NOT NULL AND c.total_exec_time >= prev.total_exec_time THEN c.total_exec_time - prev.total_exec_time ELSE NULL END,
                        CASE WHEN prev.rows IS NOT NULL AND c.rows >= prev.rows THEN c.rows - prev.rows ELSE NULL END,
                        CASE WHEN prev.shared_blks_hit IS NOT NULL AND c.shared_blks_hit >= prev.shared_blks_hit THEN c.shared_blks_hit - prev.shared_blks_hit ELSE NULL END,
                        CASE WHEN prev.shared_blks_read IS NOT NULL AND c.shared_blks_read >= prev.shared_blks_read THEN c.shared_blks_read - prev.shared_blks_read ELSE NULL END,
                        CASE WHEN prev.shared_blks_dirtied IS NOT NULL AND c.shared_blks_dirtied >= prev.shared_blks_dirtied THEN c.shared_blks_dirtied - prev.shared_blks_dirtied ELSE NULL END,
                        CASE WHEN prev.shared_blks_written IS NOT NULL AND c.shared_blks_written >= prev.shared_blks_written THEN c.shared_blks_written - prev.shared_blks_written ELSE NULL END,
                        CASE WHEN prev.temp_blks_read IS NOT NULL AND c.temp_blks_read >= prev.temp_blks_read THEN c.temp_blks_read - prev.temp_blks_read ELSE NULL END,
                        CASE WHEN prev.temp_blks_written IS NOT NULL AND c.temp_blks_written >= prev.temp_blks_written THEN c.temp_blks_written - prev.temp_blks_written ELSE NULL END,
                        CASE WHEN prev.blk_read_time IS NOT NULL AND c.blk_read_time >= prev.blk_read_time THEN c.blk_read_time - prev.blk_read_time ELSE NULL END,
                        CASE WHEN prev.blk_write_time IS NOT NULL AND c.blk_write_time >= prev.blk_write_time THEN c.blk_write_time - prev.blk_write_time ELSE NULL END,
                        CASE WHEN prev.wal_records IS NOT NULL AND c.wal_records >= prev.wal_records THEN c.wal_records - prev.wal_records ELSE NULL END,
                        CASE WHEN prev.wal_bytes IS NOT NULL AND c.wal_bytes >= prev.wal_bytes THEN c.wal_bytes - prev.wal_bytes ELSE NULL END
                    FROM current_stmts c
                    LEFT JOIN pgfr_record.statement_snapshots prev
                        ON prev.snapshot_id = $2
                       AND prev.queryid = c.queryid
                       AND prev.dbid = c.dbid
                    $q$,
                    CASE WHEN v_pg_version >= 17 THEN 'shared_blk_read_time'  ELSE 'blk_read_time'  END,
                    CASE WHEN v_pg_version >= 17 THEN 'shared_blk_write_time' ELSE 'blk_write_time' END
                ) USING v_snapshot_id, v_prev_snapshot_id;
                    PERFORM pgfr_record._record_section_success(v_stat_id);
                    END IF;
                END IF;
            END IF;
        EXCEPTION
            WHEN undefined_table THEN NULL;
            WHEN undefined_column THEN NULL;
            WHEN OTHERS THEN
                RAISE WARNING 'pgfr_record: pg_stat_statements collection failed: %', SQLERRM;
        END;
    END IF;
    -- Collect table stats
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        PERFORM pgfr_record._collect_table_stats(v_snapshot_id);
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Table stats collection failed: %', SQLERRM;
    END;
    -- Collect index stats
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        PERFORM pgfr_record._collect_index_stats(v_snapshot_id);
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Index stats collection failed: %', SQLERRM;
    END;
    -- Collect config snapshot
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        PERFORM pgfr_record._collect_config_snapshot(v_snapshot_id);
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Config snapshot collection failed: %', SQLERRM;
    END;
    -- Collect database/role config overrides
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        PERFORM pgfr_record._collect_db_role_config_snapshot(v_snapshot_id);
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Database/role config collection failed: %', SQLERRM;
    END;
    -- Collect vacuum progress
    -- Note: In PG17, max_dead_tuples was renamed to max_dead_tuple_bytes
    --       and num_dead_tuples was renamed to num_dead_item_ids
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        IF v_pg_version >= 17 THEN
            INSERT INTO pgfr_record.vacuum_progress_snapshots (
                snapshot_id, pid, datid, datname, relid, relname, phase,
                heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
                index_vacuum_count, max_dead_tuples, num_dead_tuples
            )
            SELECT
                v_snapshot_id,
                p.pid,
                p.datid,
                d.datname,
                p.relid,
                c.relname,
                p.phase,
                p.heap_blks_total,
                p.heap_blks_scanned,
                p.heap_blks_vacuumed,
                p.index_vacuum_count,
                p.max_dead_tuple_bytes,  -- Renamed in PG17
                p.num_dead_item_ids      -- Renamed in PG17
            FROM pg_stat_progress_vacuum p
            LEFT JOIN pg_database d ON d.oid = p.datid
            LEFT JOIN pg_class c ON c.oid = p.relid;
        ELSE
            INSERT INTO pgfr_record.vacuum_progress_snapshots (
                snapshot_id, pid, datid, datname, relid, relname, phase,
                heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
                index_vacuum_count, max_dead_tuples, num_dead_tuples
            )
            SELECT
                v_snapshot_id,
                p.pid,
                p.datid,
                d.datname,
                p.relid,
                c.relname,
                p.phase,
                p.heap_blks_total,
                p.heap_blks_scanned,
                p.heap_blks_vacuumed,
                p.index_vacuum_count,
                p.max_dead_tuples,
                p.num_dead_tuples
            FROM pg_stat_progress_vacuum p
            LEFT JOIN pg_database d ON d.oid = p.datid
            LEFT JOIN pg_class c ON c.oid = p.relid;
        END IF;
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Vacuum progress collection failed: %', SQLERRM;
    END;
    -- Ensure today's partitions exist for v2 sparse tables (O(1) on happy path)
    -- Wrapped in EXCEPTION blocks: missing parent table (Issue #8 not yet merged) is a
    -- recoverable error during the dual-write migration period.
    begin
        perform pgfr_record._ensure_partition('statement_snapshots_v2', current_date);
    exception when others then
        raise warning 'pgfr_record: _ensure_partition(statement_snapshots_v2) failed [%]: %', sqlstate, sqlerrm;
    end;
    begin
        perform pgfr_record._ensure_partition('table_snapshots_v2', current_date,
            'relid, dbid, sample_ts desc');
    exception when others then
        raise warning 'pgfr_record: _ensure_partition(table_snapshots_v2) failed [%]: %', sqlstate, sqlerrm;
    end;
    begin
        perform pgfr_record._ensure_partition('index_snapshots_v2', current_date,
            'indexrelid, dbid, sample_ts desc');
    exception when others then
        raise warning 'pgfr_record: _ensure_partition(index_snapshots_v2) failed [%]: %', sqlstate, sqlerrm;
    end;
    -- Sparse collectors: each isolated so failure of one does not abort others.
    -- Dual-write: old _collect_*_stats() calls above continue writing to legacy tables
    -- during migration period. Sparse collectors write to v2 partitioned tables.
    begin
        perform pgfr_record._collect_statement_snapshot_sparse(v_snapshot_id::bigint);
    exception when others then
        raise warning 'pgfr_record: sparse statement collector failed [%]: %', sqlstate, sqlerrm;
    end;
    begin
        perform pgfr_record._collect_table_snapshot_sparse(v_snapshot_id::bigint);
    exception when others then
        raise warning 'pgfr_record: sparse table collector failed [%]: %', sqlstate, sqlerrm;
    end;
    begin
        perform pgfr_record._collect_index_snapshot_sparse(v_snapshot_id::bigint);
    exception when others then
        raise warning 'pgfr_record: sparse index collector failed [%]: %', sqlstate, sqlerrm;
    end;
    PERFORM pgfr_record._record_collection_end(v_stat_id, true, NULL);
    PERFORM set_config('statement_timeout', '0', true);
    RETURN v_captured_at;
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pgfr_record._record_collection_end(v_stat_id, false, SQLERRM);
        PERFORM set_config('statement_timeout', '0', true);
        RAISE;
END;
$$;
COMMENT ON FUNCTION pgfr_record.snapshot() IS
'Durable snapshots: Collect comprehensive system metrics (WAL, checkpoints, I/O, connections, table/index stats, replication, statements). Version-aware for PG 15/16/17 differences. '
'Dual-write: calls both legacy _collect_*_stats() and new sparse v2 collectors. '
'Each sparse collector is isolated in its own EXCEPTION block — failure of one does not abort others.';

CREATE OR REPLACE VIEW pgfr_record.deltas AS
SELECT
    s.id,
    s.captured_at,
    s.pg_version,
    EXTRACT(EPOCH FROM (s.captured_at - prev.captured_at))::numeric AS interval_seconds,
    (s.checkpoint_time IS DISTINCT FROM prev.checkpoint_time) AS checkpoint_occurred,
    s.ckpt_timed - prev.ckpt_timed AS ckpt_timed_delta,
    s.ckpt_requested - prev.ckpt_requested AS ckpt_requested_delta,
    (s.ckpt_write_time - prev.ckpt_write_time)::numeric AS ckpt_write_time_ms,
    (s.ckpt_sync_time - prev.ckpt_sync_time)::numeric AS ckpt_sync_time_ms,
    s.ckpt_buffers - prev.ckpt_buffers AS ckpt_buffers_delta,
    s.wal_bytes - prev.wal_bytes AS wal_bytes_delta,
    pgfr_record._pretty_bytes(s.wal_bytes - prev.wal_bytes) AS wal_bytes_pretty,
    (s.wal_write_time - prev.wal_write_time)::numeric AS wal_write_time_ms,
    (s.wal_sync_time - prev.wal_sync_time)::numeric AS wal_sync_time_ms,
    s.bgw_buffers_clean - prev.bgw_buffers_clean AS bgw_buffers_clean_delta,
    s.bgw_buffers_alloc - prev.bgw_buffers_alloc AS bgw_buffers_alloc_delta,
    s.bgw_buffers_backend - prev.bgw_buffers_backend AS bgw_buffers_backend_delta,
    s.bgw_buffers_backend_fsync - prev.bgw_buffers_backend_fsync AS bgw_buffers_backend_fsync_delta,
    s.autovacuum_workers AS autovacuum_workers_active,
    s.slots_count,
    s.slots_max_retained_wal,
    pgfr_record._pretty_bytes(s.slots_max_retained_wal) AS slots_max_retained_pretty,
    s.io_checkpointer_reads - prev.io_checkpointer_reads AS io_ckpt_reads_delta,
    (s.io_checkpointer_read_time - prev.io_checkpointer_read_time)::numeric AS io_ckpt_read_time_ms,
    s.io_checkpointer_writes - prev.io_checkpointer_writes AS io_ckpt_writes_delta,
    (s.io_checkpointer_write_time - prev.io_checkpointer_write_time)::numeric AS io_ckpt_write_time_ms,
    s.io_checkpointer_fsyncs - prev.io_checkpointer_fsyncs AS io_ckpt_fsyncs_delta,
    (s.io_checkpointer_fsync_time - prev.io_checkpointer_fsync_time)::numeric AS io_ckpt_fsync_time_ms,
    s.io_autovacuum_reads - prev.io_autovacuum_reads AS io_autovacuum_reads_delta,
    (s.io_autovacuum_read_time - prev.io_autovacuum_read_time)::numeric AS io_autovacuum_read_time_ms,
    s.io_autovacuum_writes - prev.io_autovacuum_writes AS io_autovacuum_writes_delta,
    (s.io_autovacuum_write_time - prev.io_autovacuum_write_time)::numeric AS io_autovacuum_write_time_ms,
    s.io_client_reads - prev.io_client_reads AS io_client_reads_delta,
    (s.io_client_read_time - prev.io_client_read_time)::numeric AS io_client_read_time_ms,
    s.io_client_writes - prev.io_client_writes AS io_client_writes_delta,
    (s.io_client_write_time - prev.io_client_write_time)::numeric AS io_client_write_time_ms,
    s.io_bgwriter_reads - prev.io_bgwriter_reads AS io_bgwriter_reads_delta,
    (s.io_bgwriter_read_time - prev.io_bgwriter_read_time)::numeric AS io_bgwriter_read_time_ms,
    s.io_bgwriter_writes - prev.io_bgwriter_writes AS io_bgwriter_writes_delta,
    (s.io_bgwriter_write_time - prev.io_bgwriter_write_time)::numeric AS io_bgwriter_write_time_ms,
    s.temp_files - prev.temp_files AS temp_files_delta,
    s.temp_bytes - prev.temp_bytes AS temp_bytes_delta,
    pgfr_record._pretty_bytes(s.temp_bytes - prev.temp_bytes) AS temp_bytes_pretty
FROM pgfr_record.snapshots s
JOIN pgfr_record.snapshots prev ON prev.id = (
    SELECT MAX(id) FROM pgfr_record.snapshots WHERE id < s.id
)
ORDER BY s.captured_at DESC;
-- Returns the ring buffer retention interval based on configured sample interval
-- Used by recent_* views and recent_*_current() functions to determine query window
CREATE OR REPLACE FUNCTION pgfr_record._get_ring_retention_interval()
RETURNS INTERVAL
LANGUAGE sql STABLE AS $$
    SELECT ((pgfr_record._get_ring_buffer_slots() * COALESCE(
        pgfr_record._get_config('sample_interval_seconds', '60')::integer,
        60
    ))::text || ' seconds')::interval;
$$;

CREATE OR REPLACE VIEW pgfr_record.recent_waits AS
SELECT
    sr.captured_at,
    w.backend_type,
    w.wait_event_type,
    w.wait_event,
    w.state,
    w.count
FROM pgfr_record.samples_ring sr
JOIN pgfr_record.wait_samples_ring w ON w.slot_id = sr.slot_id
WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
  AND w.backend_type IS NOT NULL
ORDER BY sr.captured_at DESC, w.count DESC;
CREATE OR REPLACE VIEW pgfr_record.recent_activity AS
SELECT
    sr.captured_at,
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.backend_type,
    a.state,
    a.wait_event_type,
    a.wait_event,
    a.backend_start,
    a.xact_start,
    a.query_start,
    sr.captured_at - a.backend_start AS session_age,
    sr.captured_at - a.xact_start AS xact_age,
    sr.captured_at - a.query_start AS running_for,
    a.query_preview
FROM pgfr_record.samples_ring sr
JOIN pgfr_record.activity_samples_ring a ON a.slot_id = sr.slot_id
WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
  AND a.pid IS NOT NULL
ORDER BY sr.captured_at DESC, a.query_start ASC;
CREATE OR REPLACE VIEW pgfr_record.recent_locks AS
SELECT
    sr.captured_at,
    l.blocked_pid,
    l.blocked_user,
    l.blocked_app,
    l.blocked_duration,
    l.blocking_pid,
    l.blocking_user,
    l.blocking_app,
    l.lock_type,
    COALESCE(l.locked_relation_oid::regclass::text, 'OID:' || l.locked_relation_oid::text) AS locked_relation,
    l.blocked_query_preview,
    l.blocking_query_preview
FROM pgfr_record.samples_ring sr
JOIN pgfr_record.lock_samples_ring l ON l.slot_id = sr.slot_id
WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
  AND l.blocked_pid IS NOT NULL
ORDER BY sr.captured_at DESC, l.blocked_duration DESC;

-- Shows sessions currently idle in transaction, ordered by how long they have been idle
-- Used for quick visibility into problem sessions that may be blocking vacuum or holding locks
CREATE OR REPLACE VIEW pgfr_record.recent_idle_in_transaction AS
SELECT
    sr.captured_at,
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.xact_start,
    sr.captured_at - a.xact_start AS idle_duration,
    a.query_preview
FROM pgfr_record.samples_ring sr
JOIN pgfr_record.activity_samples_ring a ON a.slot_id = sr.slot_id
WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
  AND a.pid IS NOT NULL
  AND a.state = 'idle in transaction'
ORDER BY a.xact_start ASC NULLS LAST;

COMMENT ON VIEW pgfr_record.recent_idle_in_transaction IS
'Sessions currently idle in transaction, ordered by how long they have been idle';

CREATE OR REPLACE VIEW pgfr_record.recent_replication AS
SELECT
    sn.captured_at,
    r.pid,
    r.client_addr,
    r.application_name,
    r.state,
    r.sync_state,
    r.sent_lsn,
    r.write_lsn,
    r.flush_lsn,
    r.replay_lsn,
    pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn)::bigint AS replay_lag_bytes,
    pgfr_record._pretty_bytes(pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn)::bigint) AS replay_lag_pretty,
    r.write_lag,
    r.flush_lag,
    r.replay_lag
FROM pgfr_record.snapshots sn
JOIN pgfr_record.replication_snapshots r ON r.snapshot_id = sn.id
WHERE sn.captured_at > now() - interval '2 hours'
ORDER BY sn.captured_at DESC, r.application_name;

-- Shows vacuum progress from recent snapshots with percentage calculations
CREATE OR REPLACE VIEW pgfr_record.recent_vacuum_progress AS
SELECT
    sn.captured_at,
    v.pid,
    v.datname,
    v.relname,
    v.phase,
    v.heap_blks_total,
    v.heap_blks_scanned,
    v.heap_blks_vacuumed,
    CASE WHEN v.heap_blks_total > 0
        THEN round(100.0 * v.heap_blks_scanned / v.heap_blks_total, 1)
        ELSE NULL
    END AS pct_scanned,
    CASE WHEN v.heap_blks_total > 0
        THEN round(100.0 * v.heap_blks_vacuumed / v.heap_blks_total, 1)
        ELSE NULL
    END AS pct_vacuumed,
    v.index_vacuum_count,
    v.max_dead_tuples,
    v.num_dead_tuples
FROM pgfr_record.snapshots sn
JOIN pgfr_record.vacuum_progress_snapshots v ON v.snapshot_id = sn.id
WHERE sn.captured_at > now() - interval '2 hours'
ORDER BY sn.captured_at DESC, v.pid;
COMMENT ON VIEW pgfr_record.recent_vacuum_progress IS 'Recent vacuum progress with percentage scanned/vacuumed calculations';

-- Shows archiver status with delta calculations between snapshots
CREATE OR REPLACE VIEW pgfr_record.archiver_status AS
SELECT
    s.id AS snapshot_id,
    s.captured_at,
    s.archived_count,
    s.last_archived_wal,
    s.last_archived_time,
    s.failed_count,
    s.last_failed_wal,
    s.last_failed_time,
    s.archiver_stats_reset,
    s.archived_count - prev.archived_count AS archived_delta,
    s.failed_count - prev.failed_count AS failed_delta
FROM pgfr_record.snapshots s
JOIN pgfr_record.snapshots prev ON prev.id = (
    SELECT MAX(id) FROM pgfr_record.snapshots WHERE id < s.id
)
WHERE s.captured_at > now() - interval '24 hours'
  AND s.archived_count IS NOT NULL
ORDER BY s.captured_at DESC;
COMMENT ON VIEW pgfr_record.archiver_status IS 'WAL archiver status with delta calculations between snapshots';

-- Switches flight recorder to specified mode (normal/light/emergency) with different overhead and retention trade-offs
-- Validates mode and configures sampling interval and collector enablement accordingly
CREATE OR REPLACE FUNCTION pgfr_record.set_mode(p_mode TEXT)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_enable_locks BOOLEAN;
    v_enable_progress BOOLEAN;
    v_description TEXT;
    v_sample_interval_seconds INTEGER;
    v_sample_interval_minutes INTEGER;
    v_cron_expression TEXT;
    v_current_interval INTEGER;
BEGIN
    IF p_mode NOT IN ('normal', 'light', 'emergency') THEN
        RAISE EXCEPTION 'Invalid mode: %. Must be normal, light, or emergency.', p_mode;
    END IF;
    v_current_interval := COALESCE(
        pgfr_record._get_config('sample_interval_seconds', '60')::integer,
        60
    );
    CASE p_mode
        WHEN 'normal' THEN
            v_enable_locks := TRUE;
            v_enable_progress := TRUE;
            v_sample_interval_seconds := 60;
            v_description := 'Normal mode: 60s sampling, all collectors enabled (2h retention)';
        WHEN 'light' THEN
            v_enable_locks := TRUE;
            v_enable_progress := FALSE;
            v_sample_interval_seconds := 60;
            v_description := 'Light mode: 60s sampling, progress disabled (2h retention, minimal overhead)';
        WHEN 'emergency' THEN
            v_enable_locks := FALSE;
            v_enable_progress := FALSE;
            v_sample_interval_seconds := 300;
            v_description := 'Emergency mode: 300s sampling, locks/progress disabled (10h retention, 60% less overhead)';
    END CASE;
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('mode', p_mode, now())
    ON CONFLICT (key) DO UPDATE SET value = p_mode, updated_at = now();
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('enable_locks', v_enable_locks::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_enable_locks::text, updated_at = now();
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('enable_progress', v_enable_progress::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_enable_progress::text, updated_at = now();
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('sample_interval_seconds', v_sample_interval_seconds::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_sample_interval_seconds::text, updated_at = now();
    BEGIN
        IF v_sample_interval_seconds < 60 THEN
            v_cron_expression := '* * * * *';
        ELSIF v_sample_interval_seconds = 60 THEN
            v_cron_expression := '* * * * *';
        ELSE
            v_sample_interval_minutes := CEILING(v_sample_interval_seconds::numeric / 60.0)::integer;
            v_cron_expression := format('*/%s * * * *', v_sample_interval_minutes);
        END IF;
        -- Only reschedule if the job exists (i.e., collection is enabled)
        IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_sample') THEN
            PERFORM cron.unschedule('pgfr_sample');
            PERFORM cron.schedule('pgfr_sample', v_cron_expression, 'SET statement_timeout = ''5s''; SELECT pgfr_record.sample()');
        END IF;
    EXCEPTION
        WHEN undefined_table THEN NULL;
        WHEN undefined_function THEN NULL;
    END;
    RETURN v_description;
END;
$$;
COMMENT ON FUNCTION pgfr_record.set_mode(TEXT) IS
'Set operating mode: normal (60s, all collectors), light (60s, no progress tracking), or emergency (300s, minimal collectors). Reschedules the sample cron job if running.';

-- Retrieve the current flight recorder operating mode and its associated configuration
-- Returns mode, sample interval, and feature flags for locks, progress, and statement tracking
CREATE OR REPLACE FUNCTION pgfr_record.get_mode()
RETURNS TABLE(
    mode                TEXT,
    sample_interval     TEXT,
    locks_enabled       BOOLEAN,
    progress_enabled    BOOLEAN,
    statements_enabled  TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        pgfr_record._get_config('mode', 'normal') AS mode,
        CASE pgfr_record._get_config('mode', 'normal')
            WHEN 'normal' THEN '* * * * *'
            WHEN 'light' THEN '* * * * *'
            WHEN 'emergency' THEN '300 seconds'
            ELSE 'unknown'
        END AS sample_interval,
        COALESCE(pgfr_record._get_config('enable_locks', 'true')::boolean, true) AS locks_enabled,
        COALESCE(pgfr_record._get_config('enable_progress', 'true')::boolean, true) AS progress_enabled,
        pgfr_record._get_config('statements_enabled', 'auto') AS statements_enabled
$$;
COMMENT ON FUNCTION pgfr_record.get_mode() IS
'Returns current operating mode and configuration: mode name, sample interval, and feature flags for locks, progress, and statement tracking.';

-- Lists the available monitoring profiles for flight recorder with their configurations, use cases, and overhead levels
CREATE OR REPLACE FUNCTION pgfr_record.list_profiles()
RETURNS TABLE(
    profile_name        TEXT,
    description         TEXT,
    use_case            TEXT,
    sample_interval     TEXT,
    overhead_level      TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT * FROM (VALUES
        ('default',
         'Balanced configuration for most users',
         'General purpose monitoring - staging, development, or production',
         '60s (2h retention)',
         'Low (~0.04% CPU)'),
        ('production_safe',
         'Ultra-conservative for production environments',
         'Production always-on monitoring with maximum safety',
         '300s (10h retention)',
         'Ultra-minimal (~0.008% CPU)'),
        ('development',
         'Balanced for staging and development',
         'Active development, testing, or staging environments',
         '60s (2h retention)',
         'Low (~0.04% CPU)'),
        ('troubleshooting',
         'Aggressive collection during incidents',
         'Active incident response - detailed data collection',
         '60s (2h retention)',
         'Low (~0.04% CPU)'),
        ('minimal_overhead',
         'Absolute minimum footprint',
         'Resource-constrained systems, replicas, or minimal monitoring',
         '300s (10h retention)',
         'Ultra-minimal (~0.008% CPU)')
    ) AS t(profile_name, description, use_case, sample_interval, overhead_level)
$$;
COMMENT ON FUNCTION pgfr_record.list_profiles() IS
'Lists available monitoring profiles (default, production_safe, development, troubleshooting, minimal_overhead) with descriptions, use cases, sample intervals, and overhead levels.';

-- Returns ring buffer optimization profiles for different use cases
-- Profiles provide pre-configured ring_buffer_slots, sample_interval, and archive settings
CREATE OR REPLACE FUNCTION pgfr_record.get_optimization_profiles()
RETURNS TABLE(
    profile_name            TEXT,
    slots                   INTEGER,
    sample_interval_seconds INTEGER,
    archive_frequency_min   INTEGER,
    retention_hours         NUMERIC,
    description             TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT * FROM (VALUES
        ('standard',
         120, 60, 15,
         ROUND(120 * 60 / 3600.0, 1),
         'Default: 2h retention, 1min granularity, 0.042% CPU'),
        ('fine_grained',
         360, 60, 15,
         ROUND(360 * 60 / 3600.0, 1),
         'Fine: 6h retention, 1min granularity, 0.042% CPU'),
        ('ultra_fine',
         720, 30, 10,
         ROUND(720 * 30 / 3600.0, 1),
         'Ultra-fine: 6h retention, 30s granularity, 0.083% CPU'),
        ('low_overhead',
         72, 300, 30,
         ROUND(72 * 300 / 3600.0, 1),
         'Low overhead: 6h retention, 5min granularity, 0.008% CPU'),
        ('high_retention',
         240, 180, 30,
         ROUND(240 * 180 / 3600.0, 1),
         'High retention: 12h retention, 3min granularity, 0.014% CPU'),
        ('forensic',
         1440, 15, 5,
         ROUND(1440 * 15 / 3600.0, 1),
         'Forensic: 6h retention, 15s granularity, 0.167% CPU (temporary use only)')
    ) AS t(profile_name, slots, sample_interval_seconds, archive_frequency_min, retention_hours, description)
$$;
COMMENT ON FUNCTION pgfr_record.get_optimization_profiles() IS 'Returns ring buffer optimization profiles for different use cases. Profiles configure ring_buffer_slots, sample_interval_seconds, and archive_sample_frequency_minutes for specific monitoring scenarios.';

-- Applies a ring buffer optimization profile
-- Updates config values and warns if rebuild is needed
CREATE OR REPLACE FUNCTION pgfr_record.apply_optimization_profile(p_profile TEXT)
RETURNS TABLE(
    setting_key     TEXT,
    old_value       TEXT,
    new_value       TEXT,
    changed         BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_profile RECORD;
    v_old_slots TEXT;
    v_old_interval TEXT;
    v_old_archive TEXT;
    v_current_slots INTEGER;
    v_rebuild_needed BOOLEAN := false;
BEGIN
    -- Validate profile exists
    SELECT * INTO v_profile
    FROM pgfr_record.get_optimization_profiles()
    WHERE profile_name = p_profile;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown optimization profile: %. Available: standard, fine_grained, ultra_fine, low_overhead, high_retention, forensic', p_profile;
    END IF;

    -- Get current values
    v_old_slots := pgfr_record._get_config('ring_buffer_slots', '120');
    v_old_interval := pgfr_record._get_config('sample_interval_seconds', '60');
    v_old_archive := pgfr_record._get_config('archive_sample_frequency_minutes', '15');

    -- Check if rebuild will be needed
    SELECT COUNT(*) INTO v_current_slots FROM pgfr_record.samples_ring;
    IF v_current_slots != v_profile.slots THEN
        v_rebuild_needed := true;
    END IF;

    -- Update ring_buffer_slots
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('ring_buffer_slots', v_profile.slots::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_profile.slots::text, updated_at = now();

    RETURN QUERY SELECT
        'ring_buffer_slots'::text,
        v_old_slots,
        v_profile.slots::text,
        (v_old_slots IS DISTINCT FROM v_profile.slots::text);

    -- Update sample_interval_seconds
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('sample_interval_seconds', v_profile.sample_interval_seconds::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_profile.sample_interval_seconds::text, updated_at = now();

    RETURN QUERY SELECT
        'sample_interval_seconds'::text,
        v_old_interval,
        v_profile.sample_interval_seconds::text,
        (v_old_interval IS DISTINCT FROM v_profile.sample_interval_seconds::text);

    -- Update archive_sample_frequency_minutes
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('archive_sample_frequency_minutes', v_profile.archive_frequency_min::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_profile.archive_frequency_min::text, updated_at = now();

    RETURN QUERY SELECT
        'archive_sample_frequency_minutes'::text,
        v_old_archive,
        v_profile.archive_frequency_min::text,
        (v_old_archive IS DISTINCT FROM v_profile.archive_frequency_min::text);

    -- Warn if rebuild is needed
    IF v_rebuild_needed THEN
        RAISE WARNING 'Ring buffer slot count changed. Run pgfr_record.rebuild_ring_buffers() to resize. Data in ring buffers will be lost.';
    END IF;

    RAISE NOTICE 'Applied optimization profile: % (%)', p_profile, v_profile.description;
END;
$$;
COMMENT ON FUNCTION pgfr_record.apply_optimization_profile(TEXT) IS 'Applies a ring buffer optimization profile. Updates ring_buffer_slots, sample_interval_seconds, and archive_sample_frequency_minutes. Call rebuild_ring_buffers() after if slot count changed.';

-- Preview the configuration changes from applying a specified profile
-- Compares current settings against profile values to show impact before applying
CREATE OR REPLACE FUNCTION pgfr_record.explain_profile(p_profile_name TEXT)
RETURNS TABLE(
    setting_key         TEXT,
    current_value       TEXT,
    profile_value       TEXT,
    will_change         BOOLEAN,
    description         TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pgfr_record.list_profiles() WHERE profile_name = p_profile_name) THEN
        RAISE EXCEPTION 'Unknown profile: %. Run pgfr_record.list_profiles() to see available profiles.', p_profile_name;
    END IF;
    RETURN QUERY
    SELECT
        ps.key::text AS setting_key,
        c.value::text AS current_value,
        ps.value::text AS profile_value,
        (c.value IS DISTINCT FROM ps.value)::boolean AS will_change,
        ps.description::text AS description
    FROM pgfr_record._profile_settings() ps
    LEFT JOIN pgfr_record.config c ON c.key = ps.key
    WHERE ps.profile = p_profile_name
    ORDER BY will_change DESC, ps.key;
END $$;
COMMENT ON FUNCTION pgfr_record.explain_profile(TEXT) IS
'Preview configuration changes for a profile without applying them. Compares current settings against profile values to show what would change.';

-- Applies a named configuration profile to pgfr_record by upserting configuration settings
-- Returns details of changed settings and adjusts recording mode based on the profile
CREATE OR REPLACE FUNCTION pgfr_record.apply_profile(p_profile_name TEXT)
RETURNS TABLE(
    setting_key     TEXT,
    old_value       TEXT,
    new_value       TEXT,
    changed         BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_mode TEXT;
    v_changes_made INTEGER := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pgfr_record.list_profiles() WHERE profile_name = p_profile_name) THEN
        RAISE EXCEPTION 'Unknown profile: %. Run pgfr_record.list_profiles() to see available profiles.', p_profile_name;
    END IF;
    RAISE NOTICE 'Applying profile: %', p_profile_name;
    RETURN QUERY
    WITH profile_settings AS (
        SELECT ps.profile, ps.key, ps.value
        FROM pgfr_record._profile_settings() ps
        WHERE ps.profile = p_profile_name
    ),
    updates AS (
        INSERT INTO pgfr_record.config (key, value, updated_at)
        SELECT ps.key, ps.value, now()
        FROM profile_settings ps
        ON CONFLICT (key) DO UPDATE
        SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at
        WHERE pgfr_record.config.value IS DISTINCT FROM EXCLUDED.value
        RETURNING key, value
    )
    SELECT
        COALESCE(u.key, ps.key)::text AS setting_key,
        c.value::text AS old_value,
        ps.value::text AS new_value,
        (u.key IS NOT NULL)::boolean AS changed
    FROM profile_settings ps
    LEFT JOIN updates u ON u.key = ps.key
    LEFT JOIN pgfr_record.config c ON c.key = ps.key
    ORDER BY changed DESC, setting_key;
    GET DIAGNOSTICS v_changes_made = ROW_COUNT;
    v_mode := CASE p_profile_name
        WHEN 'production_safe' THEN 'emergency'
        WHEN 'minimal_overhead' THEN 'emergency'
        WHEN 'troubleshooting' THEN 'normal'
        ELSE 'normal'
    END;
    PERFORM pgfr_record.set_mode(v_mode);
    RAISE NOTICE 'Profile "%" applied: % settings changed, mode set to %',
        p_profile_name, v_changes_made, v_mode;
END $$;
COMMENT ON FUNCTION pgfr_record.apply_profile(TEXT) IS
'Apply a named configuration profile by upserting all profile settings. Also sets the operating mode (normal or emergency) based on the profile. Returns details of which settings changed.';

-- Identifies the closest matching predefined profile for current configuration and returns match percentage with differences
-- Helps users understand their configuration state relative to available profiles
CREATE OR REPLACE FUNCTION pgfr_record.get_current_profile()
RETURNS TABLE(
    closest_profile     TEXT,
    match_percentage    NUMERIC,
    differences         TEXT[],
    recommendation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_profile RECORD;
    v_best_match TEXT;
    v_best_pct NUMERIC := 0;
    v_current_pct NUMERIC;
    v_diffs TEXT[];
BEGIN
    FOR v_profile IN SELECT profile_name FROM pgfr_record.list_profiles() LOOP
        WITH profile_settings AS (
            SELECT setting_key, profile_value
            FROM pgfr_record.explain_profile(v_profile.profile_name)
        ),
        matches AS (
            SELECT
                count(*) FILTER (WHERE NOT will_change) AS matched,
                count(*) AS total,
                array_agg(setting_key) FILTER (WHERE will_change) AS diff_keys
            FROM pgfr_record.explain_profile(v_profile.profile_name)
        )
        SELECT
            (matched::numeric / NULLIF(total, 0) * 100)::numeric(5,1),
            diff_keys
        INTO v_current_pct, v_diffs
        FROM matches;
        IF v_current_pct > v_best_pct THEN
            v_best_pct := v_current_pct;
            v_best_match := v_profile.profile_name;
        END IF;
    END LOOP;
    RETURN QUERY
    SELECT
        COALESCE(v_best_match, 'custom')::text,
        COALESCE(v_best_pct, 0)::numeric,
        (SELECT array_agg(setting_key) FROM pgfr_record.explain_profile(v_best_match) WHERE will_change)::text[],
        CASE
            WHEN v_best_pct = 100 THEN 'Configuration matches "' || v_best_match || '" profile perfectly'
            WHEN v_best_pct >= 80 THEN 'Configuration is close to "' || v_best_match || '" profile'
            WHEN v_best_pct >= 50 THEN 'Configuration is partially based on "' || v_best_match || '" profile'
            ELSE 'Configuration appears to be custom (not matching any profile)'
        END::text;
END $$;
COMMENT ON FUNCTION pgfr_record.get_current_profile() IS
'Identifies the closest matching predefined profile for current configuration. Returns profile name, match percentage, differences array, and a recommendation.';

DROP FUNCTION IF EXISTS pgfr_record.cleanup(INTERVAL);

-- Removes old snapshot and sample data based on configured retention periods
-- Cleans up snapshots, statement_snapshots, replication_snapshots tables
