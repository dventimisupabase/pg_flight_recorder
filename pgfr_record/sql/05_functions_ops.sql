CREATE OR REPLACE FUNCTION pgfr_record.cleanup(p_retain_interval INTERVAL DEFAULT NULL)
RETURNS TABLE(
    deleted_snapshots   BIGINT,
    deleted_samples     BIGINT,
    deleted_statements  BIGINT,
    deleted_stats       BIGINT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_deleted_snapshots BIGINT;
    v_deleted_samples BIGINT;
    v_deleted_statements BIGINT;
    v_deleted_stats BIGINT;
    v_samples_retention_days INTEGER;
    v_snapshots_retention_days INTEGER;
    v_statements_retention_days INTEGER;
    v_stats_retention_days INTEGER;
    v_samples_cutoff TIMESTAMPTZ;
    v_snapshots_cutoff TIMESTAMPTZ;
    v_statements_cutoff TIMESTAMPTZ;
    v_stats_cutoff TIMESTAMPTZ;
BEGIN
    IF p_retain_interval IS NOT NULL THEN
        v_samples_cutoff := now() - p_retain_interval;
        v_snapshots_cutoff := now() - p_retain_interval;
        v_statements_cutoff := now() - p_retain_interval;
        v_stats_cutoff := now() - p_retain_interval;
    ELSE
        v_samples_retention_days := COALESCE(
            pgfr_record._get_config('retention_archive_days', '7')::integer,
            7
        );
        v_snapshots_retention_days := COALESCE(
            pgfr_record._get_config('retention_snapshots_days', '30')::integer,
            30
        );
        v_statements_retention_days := COALESCE(
            pgfr_record._get_config('retention_statements_days', '30')::integer,
            30
        );
        v_stats_retention_days := COALESCE(
            pgfr_record._get_config('retention_collection_stats_days', '30')::integer,
            30
        );
        v_samples_cutoff := now() - (v_samples_retention_days || ' days')::interval;
        v_snapshots_cutoff := now() - (v_snapshots_retention_days || ' days')::interval;
        v_statements_cutoff := now() - (v_statements_retention_days || ' days')::interval;
        v_stats_cutoff := now() - (v_stats_retention_days || ' days')::interval;
    END IF;
    v_deleted_samples := 0;
    -- Delete statement_snapshots first: the subquery references snapshots.id,
    -- so snapshots must still exist when this runs.
    WITH deleted AS (
        DELETE FROM pgfr_record.statement_snapshots
        WHERE snapshot_id IN (
            SELECT id FROM pgfr_record.snapshots WHERE captured_at < v_statements_cutoff
        )
        RETURNING 1
    )
    SELECT count(*) INTO v_deleted_statements FROM deleted;
    WITH deleted AS (
        DELETE FROM pgfr_record.snapshots WHERE captured_at < v_snapshots_cutoff RETURNING 1
    )
    SELECT count(*) INTO v_deleted_snapshots FROM deleted;
    WITH deleted AS (
        DELETE FROM pgfr_record.collection_stats WHERE started_at < v_stats_cutoff RETURNING 1
    )
    SELECT count(*) INTO v_deleted_stats FROM deleted;
    RETURN QUERY SELECT v_deleted_snapshots, v_deleted_samples, v_deleted_statements, v_deleted_stats;
END;
$$;
COMMENT ON FUNCTION pgfr_record.cleanup(INTERVAL) IS
'Remove old data based on configured retention periods (snapshots, statements, collection_stats). Pass an interval to override per-table retention, or NULL to use configured defaults.';

DROP FUNCTION IF EXISTS pgfr_record.ring_buffer_health();

-- Monitor ring buffer health: XID age, dead tuple bloat, HOT update effectiveness, and autovacuum status
CREATE OR REPLACE FUNCTION pgfr_record.ring_buffer_health()
RETURNS TABLE(
    table_name              TEXT,
    row_count               BIGINT,
    dead_tuples             BIGINT,
    dead_tuple_pct          NUMERIC,
    xid_age                 INTEGER,
    mxid_age                INTEGER,
    total_updates           BIGINT,
    hot_updates             BIGINT,
    hot_update_pct          NUMERIC,
    last_vacuum             TIMESTAMPTZ,
    last_autovacuum         TIMESTAMPTZ,
    autovacuum_threshold    BIGINT,
    needs_vacuum            BOOLEAN,
    status                  TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        c.relname::text,
        s.n_live_tup,
        s.n_dead_tup,
        CASE
            WHEN s.n_live_tup > 0 THEN round(100.0 * s.n_dead_tup / NULLIF(s.n_live_tup, 0), 1)
            ELSE 0
        END,
        age(c.relfrozenxid)::integer,
        mxid_age(c.relminmxid)::integer,
        s.n_tup_upd,
        s.n_tup_hot_upd,
        CASE
            WHEN s.n_tup_upd > 0 THEN round(100.0 * s.n_tup_hot_upd / NULLIF(s.n_tup_upd, 0), 1)
            ELSE 0
        END,
        s.last_vacuum,
        s.last_autovacuum,
        (50 + (0.2 * s.n_live_tup)::bigint),
        s.n_dead_tup > (50 + (0.2 * s.n_live_tup)::bigint),
        CASE
            WHEN age(c.relfrozenxid) > 200000000 THEN 'CRITICAL: XID wraparound risk'
            WHEN mxid_age(c.relminmxid) > 200000000 THEN 'CRITICAL: MultiXID wraparound risk'
            WHEN age(c.relfrozenxid) > 100000000 THEN 'WARNING: High XID age'
            WHEN mxid_age(c.relminmxid) > 100000000 THEN 'WARNING: High MultiXID age'
            WHEN c.relname = 'samples_ring' AND s.n_tup_upd > 100 AND (100.0 * s.n_tup_hot_upd / NULLIF(s.n_tup_upd, 0)) < 50 THEN 'WARNING: Low HOT update ratio'
            WHEN s.n_dead_tup > (50 + (0.2 * s.n_live_tup)::bigint) THEN 'INFO: Autovacuum pending'
            ELSE 'OK'
        END::text
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE n.nspname = 'pgfr_record'
      AND c.relkind = 'r'
      AND c.relname IN ('samples_ring', 'wait_samples_ring', 'activity_samples_ring', 'lock_samples_ring')
    ORDER BY c.relname;
$$;
COMMENT ON FUNCTION pgfr_record.ring_buffer_health() IS

'Monitor ring buffer XID/MultiXID age, dead tuple bloat, and HOT update effectiveness. samples_ring uses UPSERT (1,440x/day) and should achieve >90% HOT update ratio with fillfactor=70. Child tables use DELETE/INSERT so HOT updates are N/A. MultiXID thresholds match XID (200M critical, 100M warning); see https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-transaction-id-wraparound-risks';
-- Disable Flight Recorder by unscheduling all cron jobs and updating the enabled configuration flag to false
CREATE OR REPLACE FUNCTION pgfr_record.disable()
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_unscheduled INTEGER := 0;
BEGIN
    BEGIN
        PERFORM cron.unschedule('pgfr_snapshot')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_snapshot');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_sample')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_sample');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_cleanup')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_cleanup');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_flush')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_flush');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_archive')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_archive');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        -- v2 ring buffer + partition maintenance jobs (current underscore names)
        PERFORM cron.unschedule('pgfr_sample_ring')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_sample_ring');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_rotate_ring')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_rotate_ring');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_truncate_partitions')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_truncate_partitions');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_drop_ancient_partitions')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_drop_ancient_partitions');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_precreate_partitions')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_precreate_partitions');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        -- Defensive: also unschedule old hyphenated names (#59 rename migration)
        -- in case disable() is called on an install that hasn't yet run enable()
        -- after the rename PR.
        PERFORM cron.unschedule('pgfr-sample-ring')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-sample-ring');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr-rotate-ring')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-rotate-ring');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr-truncate-partitions')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-truncate-partitions');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr-drop-ancient-partitions')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-drop-ancient-partitions');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr-precreate-partitions')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-precreate-partitions');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        INSERT INTO pgfr_record.config (key, value, updated_at)
        VALUES ('enabled', 'false', now())
        ON CONFLICT (key) DO UPDATE SET value = 'false', updated_at = now();
        RETURN format('Flight Recorder collection stopped. Unscheduled %s cron jobs. Use pgfr_record.enable() to restart.', v_unscheduled);
    EXCEPTION
        WHEN undefined_table THEN
            RETURN 'pg_cron extension not found. No jobs to unschedule.';
        WHEN undefined_function THEN
            RETURN 'pg_cron extension not found. No jobs to unschedule.';
    END;
END;
$$;
COMMENT ON FUNCTION pgfr_record.disable() IS
'Stop Flight Recorder by unscheduling all pg_cron jobs (sample, snapshot, flush, archive, cleanup) and setting enabled=false. Use enable() to restart.';

-- Configure autovacuum on ring buffer tables
-- Ring buffers use pre-allocated rows with UPDATE-only pattern, achieving high HOT update ratios.
-- With fillfactor 70-90, most updates are HOT (no dead tuples in indexes), but tuple chains still
-- form within pages. Autovacuum collapses these chains. Since ring buffers are fixed-size UNLOGGED
-- tables with bounded bloat, autovacuum is optional - page pruning during UPSERTs provides cleanup.
-- Autovacuum enabled by default; disable for minimal observer effect if desired.
CREATE OR REPLACE FUNCTION pgfr_record.configure_ring_autovacuum(p_enabled BOOLEAN DEFAULT true)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    EXECUTE format('ALTER TABLE pgfr_record.samples_ring SET (autovacuum_enabled = %L)', p_enabled);
    EXECUTE format('ALTER TABLE pgfr_record.wait_samples_ring SET (autovacuum_enabled = %L)', p_enabled);
    EXECUTE format('ALTER TABLE pgfr_record.activity_samples_ring SET (autovacuum_enabled = %L)', p_enabled);
    EXECUTE format('ALTER TABLE pgfr_record.lock_samples_ring SET (autovacuum_enabled = %L)', p_enabled);

    IF p_enabled THEN
        v_status := 'Autovacuum ENABLED on ring buffer tables. Autovacuum will periodically collapse HOT chains.';
    ELSE
        v_status := 'Autovacuum DISABLED on ring buffer tables. Page pruning during UPSERTs handles cleanup.';
    END IF;

    RETURN v_status;
END;
$$;

COMMENT ON FUNCTION pgfr_record.configure_ring_autovacuum(BOOLEAN) IS
'Toggle autovacuum on ring buffer tables. Enabled by default (PostgreSQL standard behavior). Ring buffers are fixed-size UNLOGGED tables with bounded bloat, so autovacuum can be disabled to minimize observer effect if desired.';

-- Rebuilds ring buffers to match configured slot count
-- WARNING: This clears all data in ring buffers (archives and aggregates are preserved)
CREATE OR REPLACE FUNCTION pgfr_record.rebuild_ring_buffers(p_slots INTEGER DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_target_slots INTEGER;
    v_current_slots INTEGER;
    v_autovacuum_enabled BOOLEAN := true;
BEGIN
    -- Get target slot count from param or config
    v_target_slots := COALESCE(p_slots, pgfr_record._get_ring_buffer_slots());

    -- Validate range
    IF v_target_slots < 72 OR v_target_slots > 2880 THEN
        RAISE EXCEPTION 'Ring buffer slots must be between 72 and 2880. Got: %', v_target_slots;
    END IF;

    -- Get current slot count
    SELECT COUNT(*) INTO v_current_slots FROM pgfr_record.samples_ring;

    -- Check if resize is needed
    IF v_current_slots = v_target_slots THEN
        RETURN format('Ring buffers already sized for %s slots. No rebuild needed.', v_target_slots);
    END IF;

    -- Preserve autovacuum setting
    SELECT COALESCE(
        (SELECT reloptions::text LIKE '%autovacuum_enabled=false%'
         FROM pg_class WHERE relname = 'samples_ring' AND relnamespace = 'pgfr_record'::regnamespace),
        false
    ) INTO v_autovacuum_enabled;
    v_autovacuum_enabled := NOT v_autovacuum_enabled;  -- Invert because we checked for false

    RAISE NOTICE 'Rebuilding ring buffers from % to % slots...', v_current_slots, v_target_slots;

    -- TRUNCATE CASCADE clears all child tables via FK
    TRUNCATE pgfr_record.samples_ring CASCADE;

    -- Rebuild samples_ring
    INSERT INTO pgfr_record.samples_ring (slot_id, captured_at, epoch_seconds)
    SELECT
        generate_series AS slot_id,
        '1970-01-01'::timestamptz,
        0
    FROM generate_series(0, v_target_slots - 1);

    -- Rebuild wait_samples_ring
    INSERT INTO pgfr_record.wait_samples_ring (slot_id, row_num)
    SELECT s.slot_id, r.row_num
    FROM generate_series(0, v_target_slots - 1) s(slot_id)
    CROSS JOIN generate_series(0, 99) r(row_num);

    -- Rebuild activity_samples_ring
    INSERT INTO pgfr_record.activity_samples_ring (slot_id, row_num)
    SELECT s.slot_id, r.row_num
    FROM generate_series(0, v_target_slots - 1) s(slot_id)
    CROSS JOIN generate_series(0, 24) r(row_num);

    -- Rebuild lock_samples_ring
    INSERT INTO pgfr_record.lock_samples_ring (slot_id, row_num)
    SELECT s.slot_id, r.row_num
    FROM generate_series(0, v_target_slots - 1) s(slot_id)
    CROSS JOIN generate_series(0, 99) r(row_num);

    -- Restore autovacuum setting
    IF NOT v_autovacuum_enabled THEN
        PERFORM pgfr_record.configure_ring_autovacuum(false);
    END IF;

    -- Update config if p_slots was provided
    IF p_slots IS NOT NULL THEN
        INSERT INTO pgfr_record.config (key, value, updated_at)
        VALUES ('ring_buffer_slots', p_slots::text, now())
        ON CONFLICT (key) DO UPDATE SET value = p_slots::text, updated_at = now();
    END IF;

    RETURN format('Ring buffers rebuilt: %s → %s slots. Tables: samples_ring (%s), wait_samples_ring (%s), activity_samples_ring (%s), lock_samples_ring (%s)',
        v_current_slots, v_target_slots,
        v_target_slots,
        v_target_slots * 100,
        v_target_slots * 25,
        v_target_slots * 100);
END;
$$;
COMMENT ON FUNCTION pgfr_record.rebuild_ring_buffers(INTEGER) IS 'Rebuilds ring buffers to match configured slot count (72-2880). WARNING: Clears all ring buffer data. Archives and aggregates are preserved. Pass slot count as parameter or use ring_buffer_slots config.';

-- Enables flight recorder by scheduling periodic cron jobs for collection, archival, and cleanup
-- Requires pg_cron extension; returns status message on success
CREATE OR REPLACE FUNCTION pgfr_record.enable()
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_mode TEXT;
    v_pgcron_version TEXT;
    v_supports_subsecond BOOLEAN := FALSE;
    v_sample_schedule TEXT;
    v_scheduled INTEGER := 0;
    v_sample_interval_seconds INTEGER;
    v_sample_interval_minutes INTEGER;
    v_cron_expression TEXT;
BEGIN
    v_mode := pgfr_record._get_config('mode', 'normal');
    v_sample_interval_seconds := COALESCE(
        pgfr_record._get_config('sample_interval_seconds', '60')::integer,
        60
    );
    BEGIN
        SELECT extversion INTO v_pgcron_version FROM pg_extension WHERE extname = 'pg_cron';
        IF v_pgcron_version IS NULL THEN
            RETURN 'pg_cron extension not found. Cannot schedule automatic collection.';
        END IF;
        v_pgcron_version := split_part(v_pgcron_version, '-', 1);
        v_supports_subsecond := (
            split_part(v_pgcron_version, '.', 1)::int > 1 OR
            (split_part(v_pgcron_version, '.', 1)::int = 1 AND
             split_part(v_pgcron_version, '.', 2)::int > 4) OR
            (split_part(v_pgcron_version, '.', 1)::int = 1 AND
             split_part(v_pgcron_version, '.', 2)::int = 4 AND
             COALESCE(NULLIF(split_part(v_pgcron_version, '.', 3), '')::int, 0) >= 1)
        );
        PERFORM cron.schedule('pgfr_snapshot', '* * * * *', 'SET statement_timeout = ''10s''; SELECT pgfr_record.snapshot()');
        v_scheduled := v_scheduled + 1;
        IF v_sample_interval_seconds <= 60 THEN
            v_cron_expression := '* * * * *';
            v_sample_schedule := 'every 60 seconds';
        ELSIF v_sample_interval_seconds % 60 = 0 THEN
            v_sample_interval_minutes := v_sample_interval_seconds / 60;
            v_cron_expression := format('*/%s * * * *', v_sample_interval_minutes);
            v_sample_schedule := format('every %s seconds', v_sample_interval_seconds);
        ELSE
            v_sample_interval_minutes := CEILING(v_sample_interval_seconds::numeric / 60.0)::integer;
            v_cron_expression := format('*/%s * * * *', v_sample_interval_minutes);
            v_sample_schedule := format('approximately every %s seconds', v_sample_interval_seconds);
        END IF;
        PERFORM cron.schedule('pgfr_sample', v_cron_expression, 'SET statement_timeout = ''5s''; SELECT pgfr_record.sample()');
        v_scheduled := v_scheduled + 1;
        PERFORM cron.schedule('pgfr_flush', '*/5 * * * *', 'SET statement_timeout = ''10s''; SELECT pgfr_record.flush_ring_to_aggregates()');
        v_scheduled := v_scheduled + 1;
        PERFORM cron.schedule('pgfr_archive', '*/15 * * * *', 'SET statement_timeout = ''10s''; SELECT pgfr_record.archive_ring_samples()');
        v_scheduled := v_scheduled + 1;
        PERFORM cron.schedule('pgfr_cleanup', '0 3 * * *',
            'SET statement_timeout = ''60s''; SELECT pgfr_record.cleanup_aggregates(); SELECT * FROM pgfr_record.cleanup(''30 days''::interval);');
        v_scheduled := v_scheduled + 1;
        -- One-time rename migration (#59): unschedule old hyphenated job names
        -- if a prior install left them. Self-healing on next enable().
        PERFORM cron.unschedule('pgfr-sample-ring')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-sample-ring');
        PERFORM cron.unschedule('pgfr-rotate-ring')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-rotate-ring');
        PERFORM cron.unschedule('pgfr-truncate-partitions')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-truncate-partitions');
        PERFORM cron.unschedule('pgfr-drop-ancient-partitions')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-drop-ancient-partitions');
        PERFORM cron.unschedule('pgfr-precreate-partitions')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr-precreate-partitions');
        -- Ring buffer v2 sampler (every minute); tight 500ms timeout matches low-overhead goal
        PERFORM cron.schedule('pgfr_sample_ring', '* * * * *',
            'SET statement_timeout = ''500ms''; SELECT pgfr_record.sample_ring()');
        v_scheduled := v_scheduled + 1;
        -- Ring buffer v2 rotation (every 2 hours). Internal lock_timeout = 2s; outer 10s envelope.
        PERFORM cron.schedule('pgfr_rotate_ring', '0 */2 * * *',
            'SET statement_timeout = ''10s''; SELECT pgfr_record.rotate_ring()');
        v_scheduled := v_scheduled + 1;
        -- Nightly retention GC (03:00 UTC): truncate expired v2 partitions
        PERFORM cron.schedule('pgfr_truncate_partitions', '0 3 * * *',
            'SET statement_timeout = ''30s''; SELECT pgfr_record.truncate_old_partitions()');
        v_scheduled := v_scheduled + 1;
        -- Monthly catalog cleanup (1st of month, 04:00 UTC): drop ancient empty partitions
        PERFORM cron.schedule('pgfr_drop_ancient_partitions', '0 4 1 * *',
            'SET statement_timeout = ''30s''; SELECT pgfr_record.drop_ancient_partitions()');
        v_scheduled := v_scheduled + 1;
        -- Daily precreate of tomorrow's partitions (23:55 UTC), covers all v2 parents
        PERFORM cron.schedule('pgfr_precreate_partitions', '55 23 * * *',
            'SET statement_timeout = ''5s''; '
            'DO $x$ BEGIN '
            'PERFORM pgfr_record._ensure_partition(''snapshots_v2'', current_date + 1, ''snapshot_id, sample_ts desc''); '
            'PERFORM pgfr_record._ensure_partition(''replication_snapshots_v2'', current_date + 1, ''snapshot_id, sample_ts desc''); '
            'PERFORM pgfr_record._ensure_partition(''vacuum_progress_snapshots_v2'', current_date + 1, ''snapshot_id, sample_ts desc''); '
            'PERFORM pgfr_record._ensure_partition(''statement_snapshots_v2'', current_date + 1); '
            'PERFORM pgfr_record._ensure_partition(''table_snapshots_v2'', current_date + 1, ''relid, dbid, sample_ts desc''); '
            'PERFORM pgfr_record._ensure_partition(''index_snapshots_v2'', current_date + 1, ''indexrelid, dbid, sample_ts desc''); '
            'PERFORM pgfr_record._ensure_partition(''activity_samples_archive_v2'', current_date + 1, ''sample_ts desc, pid''); '
            'PERFORM pgfr_record._ensure_partition(''lock_samples_archive_v2'', current_date + 1, ''sample_ts desc, blocked_pid''); '
            'PERFORM pgfr_record._ensure_partition(''wait_samples_archive_v2'', current_date + 1, ''sample_ts desc, wait_event_type, wait_event''); '
            'END $x$');
        v_scheduled := v_scheduled + 1;
        -- Ensure pg_cron uses the unix socket for all pgfr jobs (not TCP).
        UPDATE cron.job SET nodename = '' WHERE jobname LIKE 'pgfr%' AND nodename <> '';
        INSERT INTO pgfr_record.config (key, value, updated_at)
        VALUES ('enabled', 'true', now())
        ON CONFLICT (key) DO UPDATE SET value = 'true', updated_at = now();
        -- Emit warnings for suboptimal ring buffer configuration
        DECLARE
            v_check RECORD;
        BEGIN
            FOR v_check IN
                SELECT * FROM pgfr_record.validate_ring_configuration()
                WHERE status IN ('WARNING', 'ERROR')
            LOOP
                RAISE WARNING '% [%]: % - %', v_check.check_name, v_check.status, v_check.message, v_check.recommendation;
            END LOOP;
        EXCEPTION WHEN OTHERS THEN
            -- Don't fail enable() if validation has issues
            NULL;
        END;
        -- pg_cron writes one row to cron.job_run_details per job execution with
        -- no built-in purge. pgfr schedules ~10 jobs (4 of them every minute),
        -- so at default cadence this is roughly 5,000 rows/day forever. Errors
        -- from failed jobs still appear in the Postgres server log via
        -- cron.log_min_messages (default WARNING) — see README "pg_cron run history".
        DECLARE
            v_cron_log_run TEXT;
        BEGIN
            v_cron_log_run := current_setting('cron.log_run', true);
            IF v_cron_log_run IS NULL OR lower(v_cron_log_run) IN ('on', 'true', 'yes', '1') THEN
                RAISE WARNING 'pg_cron run history [WARNING]: cron.log_run is on — cron.job_run_details grows unbounded (~5000 rows/day from pgfr jobs at default cadence). Recommended: ALTER SYSTEM SET cron.log_run = off (requires restart). Alternative: schedule a periodic DELETE on cron.job_run_details. See README "pg_cron run history".';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Don't fail enable() if the GUC is unavailable
            NULL;
        END;
        RETURN format('Flight Recorder collection restarted. Scheduled %s cron jobs in %s mode (sample: %s).',
                     v_scheduled, v_mode, v_sample_schedule);
    EXCEPTION
        WHEN undefined_table THEN
            RETURN 'pg_cron extension not found. Cannot schedule automatic collection.';
        WHEN undefined_function THEN
            RETURN 'pg_cron extension not found. Cannot schedule automatic collection.';
    END;
END;
$$;
COMMENT ON FUNCTION pgfr_record.enable() IS
'Start Flight Recorder by scheduling all pg_cron jobs (legacy collectors + v2 ring buffer + partition maintenance). Requires pg_cron extension. Configures schedules based on current mode and sample interval.';

-- Install-time scheduling is consolidated into enable(), which install.sql
-- calls as its final step. Previously a DO block here duplicated enable()'s
-- logic; see the consolidation commit / issue #57 for rationale.

-- Performs comprehensive health check of Flight Recorder system components
-- Reports status, metrics, and recommended actions for critical subsystems
CREATE OR REPLACE FUNCTION pgfr_record.health_check()
RETURNS TABLE(
    component TEXT,
    status TEXT,
    details TEXT,
    action_required TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled TEXT;
    v_schema_size_mb NUMERIC;
    v_schema_critical_mb INTEGER;
    v_recent_trips INTEGER;
    v_last_sample TIMESTAMPTZ;
    v_last_snapshot TIMESTAMPTZ;
    v_sample_count INTEGER;
    v_snapshot_count INTEGER;
BEGIN
    v_enabled := pgfr_record._get_config('enabled', 'true');
    IF v_enabled = 'false' THEN
        RETURN QUERY SELECT
            'Flight Recorder System'::text,
            'DISABLED'::text,
            'Collection is disabled'::text,
            'Run pgfr_record.enable() to restart'::text;
        RETURN;
    END IF;
    RETURN QUERY SELECT
        'Flight Recorder System'::text,
        'ENABLED'::text,
        format('Mode: %s', pgfr_record._get_config('mode', 'normal')),
        NULL::text;
    SELECT s.schema_size_mb, s.critical_threshold_mb, s.status
    INTO v_schema_size_mb, v_schema_critical_mb, v_enabled
    FROM pgfr_record._check_schema_size() s;
    RETURN QUERY SELECT
        'Schema Size'::text,
        v_enabled::text,
        format('%s MB / %s MB (%s%%)',
               round(v_schema_size_mb, 2)::text,
               v_schema_critical_mb::text,
               round((v_schema_size_mb / NULLIF(v_schema_critical_mb, 0)) * 100, 1)::text),
        CASE
            WHEN v_enabled = 'CRITICAL' THEN 'Run cleanup() immediately'
            WHEN v_enabled = 'WARNING' THEN 'Schedule cleanup() soon'
            ELSE NULL
        END::text;
    SELECT count(*)
    INTO v_recent_trips
    FROM pgfr_record.collection_stats
    WHERE skipped = true
      AND started_at > now() - interval '1 hour'
      AND skipped_reason LIKE '%Circuit breaker%';
    RETURN QUERY SELECT
        'Circuit Breaker'::text,
        CASE
            WHEN v_recent_trips = 0 THEN 'OK'
            WHEN v_recent_trips < 3 THEN 'WARNING'
            ELSE 'CRITICAL'
        END::text,
        format('%s trips in last hour', v_recent_trips),
        CASE
            WHEN v_recent_trips >= 3 THEN 'System under stress - consider emergency mode'
            ELSE NULL
        END::text;
    SELECT max(captured_at) INTO v_last_sample FROM pgfr_record.samples_ring;
    SELECT max(captured_at) INTO v_last_snapshot FROM pgfr_record.snapshots;
    RETURN QUERY SELECT
        'Sample Collection'::text,
        CASE
            WHEN v_last_sample IS NULL THEN 'ERROR'
            WHEN v_last_sample > now() - interval '5 minutes' THEN 'OK'
            WHEN v_last_sample > now() - interval '15 minutes' THEN 'WARNING'
            ELSE 'CRITICAL'
        END::text,
        CASE
            WHEN v_last_sample IS NULL THEN 'No samples collected'
            ELSE format('Last: %s ago', age(now(), v_last_sample))
        END,
        CASE
            WHEN v_last_sample IS NULL OR v_last_sample < now() - interval '15 minutes'
            THEN 'Check pg_cron jobs'
            ELSE NULL
        END::text;
    RETURN QUERY SELECT
        'Snapshot Collection'::text,
        CASE
            WHEN v_last_snapshot IS NULL THEN 'ERROR'
            WHEN v_last_snapshot > now() - interval '10 minutes' THEN 'OK'
            WHEN v_last_snapshot > now() - interval '30 minutes' THEN 'WARNING'
            ELSE 'CRITICAL'
        END::text,
        CASE
            WHEN v_last_snapshot IS NULL THEN 'No snapshots collected'
            ELSE format('Last: %s ago', age(now(), v_last_snapshot))
        END,
        CASE
            WHEN v_last_snapshot IS NULL OR v_last_snapshot < now() - interval '30 minutes'
            THEN 'Check pg_cron jobs'
            ELSE NULL
        END::text;
    SELECT count(*) INTO v_sample_count FROM pgfr_record.samples_ring;
    SELECT count(*) INTO v_snapshot_count FROM pgfr_record.snapshots;
    RETURN QUERY SELECT
        'Data Volume'::text,
        'INFO'::text,
        format('Samples: %s, Snapshots: %s', v_sample_count, v_snapshot_count),
        NULL::text;
    RETURN QUERY SELECT
        'pg_stat_statements'::text,
        CASE h.status
            WHEN 'DISABLED' THEN 'N/A'
            WHEN 'OK' THEN 'Healthy'
            WHEN 'WARNING' THEN 'Warning'
            WHEN 'HIGH_CHURN' THEN 'Degraded'
            ELSE 'Unknown'
        END::text,
        CASE
            WHEN h.status = 'DISABLED' THEN 'Extension not available'
            ELSE format('Utilization: %s%% (%s/%s statements)',
                       h.utilization_pct::text,
                       h.current_statements::text,
                       h.max_statements::text)
        END,
        CASE
            WHEN h.status = 'HIGH_CHURN' THEN 'Increase pg_stat_statements.max'
            WHEN h.status = 'WARNING' THEN 'Monitor for increased churn'
            ELSE NULL
        END::text
    FROM pgfr_record._check_statements_health() h;
    DECLARE
        v_job_count INTEGER;
        v_active_jobs INTEGER;
        v_missing_jobs TEXT[];
        v_inactive_jobs TEXT[];
    BEGIN
        WITH required_jobs AS (
            SELECT unnest(ARRAY[
                'pgfr_sample',
                'pgfr_snapshot',
                'pgfr_flush',
                'pgfr_cleanup'
            ]) AS job_name
        )
        SELECT
            count(*) FILTER (WHERE j.jobid IS NULL),
            count(*) FILTER (WHERE j.jobid IS NOT NULL AND j.active),
            array_agg(r.job_name) FILTER (WHERE j.jobid IS NULL),
            array_agg(r.job_name) FILTER (WHERE j.jobid IS NOT NULL AND NOT j.active)
        INTO v_job_count, v_active_jobs, v_missing_jobs, v_inactive_jobs
        FROM required_jobs r
        LEFT JOIN cron.job j ON j.jobname = r.job_name;
        RETURN QUERY SELECT
            'pg_cron Jobs'::text,
            CASE
                WHEN v_job_count > 0 THEN 'CRITICAL'
                WHEN v_active_jobs < 4 THEN 'CRITICAL'
                WHEN v_active_jobs = 4 THEN 'OK'
                ELSE 'UNKNOWN'
            END::text,
            CASE
                WHEN v_job_count > 0 THEN
                    format('%s/%s jobs missing: %s', v_job_count, 4, array_to_string(v_missing_jobs, ', '))
                WHEN v_active_jobs < 4 THEN
                    format('%s/%s jobs inactive: %s', 4 - v_active_jobs, 4, array_to_string(v_inactive_jobs, ', '))
                ELSE '4/4 jobs active and running'
            END,
            CASE
                WHEN v_job_count > 0 OR v_active_jobs < 4 THEN
                    'Run pgfr_record.enable() to restore missing/inactive jobs'
                ELSE NULL
            END::text;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            'pg_cron Jobs'::text,
            'ERROR'::text,
            format('Failed to check pg_cron jobs: %s', SQLERRM),
            'Verify pg_cron extension is installed and accessible'::text;
    END;
END;
$$;
COMMENT ON FUNCTION pgfr_record.health_check() IS
'Comprehensive system health check reporting status, metrics, and recommended actions for: system state, schema size, circuit breaker, sample/snapshot collection, pg_stat_statements, pg_cron jobs, and data volume.';

-- Exports all data before an upgrade, saving to a file for backup
-- Returns summary of what was exported and the recommended restore command
CREATE OR REPLACE FUNCTION pgfr_record.export_for_upgrade()
RETURNS TABLE(
    data_type TEXT,
    row_count BIGINT,
    date_range TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_version TEXT;
BEGIN
    SELECT value INTO v_version FROM pgfr_record.config WHERE key = 'schema_version';

    RAISE NOTICE '';
    RAISE NOTICE '=== Flight Recorder Export for Upgrade ===';
    RAISE NOTICE 'Current version: %', COALESCE(v_version, 'unknown');
    RAISE NOTICE '';
    RAISE NOTICE 'To export all data, run:';
    RAISE NOTICE '  psql -At -c "SELECT pgfr_record.report(now() - interval ''30 days'', now())" > backup.md';
    RAISE NOTICE '';
    RAISE NOTICE 'Or for specific tables:';
    RAISE NOTICE '  pg_dump -t pgfr_record.snapshots -t pgfr_record.statement_snapshots ... > backup.sql';
    RAISE NOTICE '';

    -- Return summary of data that would be exported
    RETURN QUERY
    SELECT 'snapshots'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.snapshots;

    RETURN QUERY
    SELECT 'statement_snapshots'::TEXT, count(*)::BIGINT,
           min(sample_ts)::TEXT || ' to ' || max(sample_ts)::TEXT
    FROM pgfr_record.statement_snapshots;

    RETURN QUERY
    SELECT 'table_snapshots'::TEXT, count(*)::BIGINT,
           min(sample_ts)::TEXT || ' to ' || max(sample_ts)::TEXT
    FROM pgfr_record.table_snapshots;

    RETURN QUERY
    SELECT 'index_snapshots'::TEXT, count(*)::BIGINT,
           min(sample_ts)::TEXT || ' to ' || max(sample_ts)::TEXT
    FROM pgfr_record.index_snapshots;

    RETURN QUERY
    SELECT 'activity_samples_archive'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.activity_samples_archive;

    RETURN QUERY
    SELECT 'lock_samples_archive'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.lock_samples_archive;

    RETURN QUERY
    SELECT 'wait_samples_archive'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.wait_samples_archive;

    RETURN QUERY
    SELECT 'wait_event_aggregates'::TEXT, count(*)::BIGINT,
           min(start_time)::TEXT || ' to ' || max(start_time)::TEXT
    FROM pgfr_record.wait_event_aggregates;

    RETURN QUERY
    SELECT 'activity_aggregates'::TEXT, count(*)::BIGINT,
           min(start_time)::TEXT || ' to ' || max(start_time)::TEXT
    FROM pgfr_record.activity_aggregates;

    RETURN QUERY
    SELECT 'lock_aggregates'::TEXT, count(*)::BIGINT,
           min(start_time)::TEXT || ' to ' || max(start_time)::TEXT
    FROM pgfr_record.lock_aggregates;

    RETURN QUERY
    SELECT 'config'::TEXT, count(*)::BIGINT,
           'current settings'::TEXT
    FROM pgfr_record.config;
END;
$$;
COMMENT ON FUNCTION pgfr_record.export_for_upgrade() IS
'Returns summary of all stored data (snapshots, statements, archives, aggregates, config) with row counts and date ranges. Use before pg_dump to assess export scope.';

-- Analyzes current metrics (schema size, sample duration, retention settings) and returns configuration optimization recommendations
-- Provides actionable SQL commands for performance, storage, and automation tuning
CREATE OR REPLACE FUNCTION pgfr_record.config_recommendations()
RETURNS TABLE(
    category TEXT,
    recommendation TEXT,
    reason TEXT,
    sql_command TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_mode TEXT;
    v_schema_size_mb NUMERIC;
    v_avg_sample_ms NUMERIC;
    v_sample_count INTEGER;
    v_snapshot_count INTEGER;
    v_retention_samples INTEGER;
    v_retention_snapshots INTEGER;
BEGIN
    v_mode := pgfr_record._get_config('mode', 'normal');
    SELECT schema_size_mb INTO v_schema_size_mb FROM pgfr_record._check_schema_size();
    SELECT count(*) INTO v_sample_count FROM pgfr_record.samples_ring;
    SELECT count(*) INTO v_snapshot_count FROM pgfr_record.snapshots;
    SELECT avg(duration_ms) INTO v_avg_sample_ms
    FROM pgfr_record.collection_stats
    WHERE collection_type = 'sample'
      AND success = true
      AND skipped = false
      AND started_at > now() - interval '24 hours';
    v_retention_samples := pgfr_record._get_config('retention_archive_days', '7')::integer;
    v_retention_snapshots := pgfr_record._get_config('retention_snapshots_days', '30')::integer;
    IF v_avg_sample_ms > 1000 AND v_mode = 'normal' THEN
        RETURN QUERY SELECT
            'Performance'::text,
            'Switch to light mode'::text,
            format('Average sample duration is %s ms, which may impact system performance', round(v_avg_sample_ms)),
            'SELECT pgfr_record.set_mode(''light'');'::text;
    END IF;
    IF v_schema_size_mb > 5000 THEN
        RETURN QUERY SELECT
            'Storage'::text,
            'Run cleanup to reclaim space'::text,
            format('Schema size is %s MB', round(v_schema_size_mb)::text),
            'SELECT * FROM pgfr_record.cleanup();'::text;
    END IF;
    IF v_sample_count > 50000 AND v_retention_samples > 7 THEN
        RETURN QUERY SELECT
            'Storage'::text,
            'Reduce sample retention period'::text,
            format('High sample count (%s) with %s day retention', v_sample_count, v_retention_samples),
            format('UPDATE pgfr_record.config SET value = ''3'' WHERE key = ''retention_archive_days'';')::text;
    END IF;
    IF NOT FOUND THEN
        RETURN QUERY SELECT
            'System Health'::text,
            'Configuration looks optimal'::text,
            'No configuration changes recommended at this time'::text,
            NULL::text;
    END IF;
END;
$$;
COMMENT ON FUNCTION pgfr_record.config_recommendations() IS
'Analyzes current system metrics (schema size, sample duration, retention) and returns actionable tuning recommendations with SQL commands for performance, storage, and automation.';



