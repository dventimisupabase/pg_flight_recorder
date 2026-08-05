-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

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
    -- The FK cascades from the child heaps died with the snapshots cutover
    -- (Issue #73: a view cannot be an FK target), so the children are reaped
    -- explicitly: a child row whose parent id no longer exists is dead,
    -- which also covers parents removed by partition truncation.
    DELETE FROM pgfr_record.replication_snapshots
    WHERE snapshot_id < (SELECT coalesce(min(id), 9223372036854775807) FROM pgfr_record.snapshots);
    DELETE FROM pgfr_record.vacuum_progress_snapshots
    WHERE snapshot_id < (SELECT coalesce(min(id), 9223372036854775807) FROM pgfr_record.snapshots);
    DELETE FROM pgfr_record.table_snapshots
    WHERE snapshot_id < (SELECT coalesce(min(id), 9223372036854775807) FROM pgfr_record.snapshots);
    DELETE FROM pgfr_record.index_snapshots
    WHERE snapshot_id < (SELECT coalesce(min(id), 9223372036854775807) FROM pgfr_record.snapshots);
    DELETE FROM pgfr_record.config_snapshots
    WHERE snapshot_id < (SELECT coalesce(min(id), 9223372036854775807) FROM pgfr_record.snapshots);
    DELETE FROM pgfr_record.db_role_config_snapshots
    WHERE snapshot_id < (SELECT coalesce(min(id), 9223372036854775807) FROM pgfr_record.snapshots);

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
DROP FUNCTION IF EXISTS pgfr_record.configure_ring_autovacuum(boolean);
DROP FUNCTION IF EXISTS pgfr_record.rebuild_ring_buffers(integer);

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

-- Enables flight recorder by scheduling periodic cron jobs for collection, archival, and cleanup
-- Requires pg_cron extension; returns status message on success
CREATE OR REPLACE FUNCTION pgfr_record.enable()
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_mode TEXT;
    v_pgcron_version TEXT;
    v_supports_subsecond BOOLEAN := FALSE;
    v_scheduled INTEGER := 0;
BEGIN
    v_mode := pgfr_record._get_config('mode', 'normal');
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
        -- The collection cadence is a fixed design constant: one minute for
        -- both collectors (Issue #106 retired the sample_interval_seconds
        -- config key, which computed a cron expression here that was never
        -- used). The statistical layer (coverage(), STATISTICS.md's
        -- detection limits) is built on this constant.
        -- Legacy ring writers (pgfr_sample, pgfr_flush, pgfr_archive) retired.
        -- The unschedule block at the top of enable() still removes them if
        -- they exist from an older install. The v2 path (pgfr_sample_ring,
        -- pgfr_rotate_ring, scheduled below) is the canonical sampler now.
        PERFORM cron.schedule('pgfr_cleanup', '0 3 * * *',
            'SET statement_timeout = ''60s''; SELECT * FROM pgfr_record.cleanup(''30 days''::interval); '
            'SELECT pgfr_record._rollup_consumption_daily();');
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
            -- *_archive_v2 _ensure_partition calls retired; archive tables
            -- (legacy and _v2 partitioned) had no writers after the legacy
            -- archive_ring_samples() was retired and are dropped in
            -- 02_tables.sql / 09_phase3_snapshots_v2.sql.
            'END $x$');
        v_scheduled := v_scheduled + 1;
        -- Ensure pg_cron uses the unix socket for all pgfr jobs (not TCP).
        -- Managed Postgres (e.g. Supabase) typically does not grant UPDATE
        -- on cron.job to the SQL-editor role. In that environment the unix
        -- socket vs TCP distinction is also irrelevant, so swallowing the
        -- permission error is safe -- jobs are already scheduled via
        -- cron.schedule() above.
        BEGIN
            UPDATE cron.job SET nodename = '' WHERE jobname LIKE 'pgfr%' AND nodename <> '';
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'pgfr_record.enable(): skipped cron.job.nodename normalization (insufficient_privilege). Jobs were still scheduled.';
        END;
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
        -- pg_cron writes one row to cron.job_run_details per job execution
        -- with no built-in purge. The counts in the warning are computed from
        -- the jobs actually on the schedule (Issue #107: a hardcoded figure
        -- here went stale when the job roster changed), with per-minute jobs
        -- contributing 1440 rows/day each and the daily/monthly jobs roughly
        -- one each. Errors from failed jobs still appear in the Postgres
        -- server log via cron.log_min_messages (default WARNING); see README
        -- "pg_cron run history".
        DECLARE
            v_cron_log_run TEXT;
            v_job_count INTEGER;
            v_per_minute INTEGER;
            v_rows_per_day INTEGER;
        BEGIN
            v_cron_log_run := current_setting('cron.log_run', true);
            IF v_cron_log_run IS NULL OR lower(v_cron_log_run) IN ('on', 'true', 'yes', '1') THEN
                SELECT count(*),
                       count(*) FILTER (WHERE schedule = '* * * * *')
                INTO v_job_count, v_per_minute
                FROM cron.job
                WHERE jobname LIKE 'pgfr%';
                v_rows_per_day := v_per_minute * 1440 + (v_job_count - v_per_minute);
                RAISE WARNING 'pg_cron run history [WARNING]: cron.log_run is on; cron.job_run_details grows unbounded (roughly % rows/day from the % pgfr jobs, % of them every minute). Recommended: ALTER SYSTEM SET cron.log_run = off (requires restart). Alternative: schedule a periodic DELETE on cron.job_run_details. See README "pg_cron run history".',
                    v_rows_per_day, v_job_count, v_per_minute;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Don't fail enable() if the GUC is unavailable
            NULL;
        END;
        RETURN format('Flight Recorder collection restarted. Scheduled %s cron jobs in %s mode (sample: every 60 seconds, fixed).',
                     v_scheduled, v_mode);
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
      AND COALESCE(skip_kind, pgfr_record._skip_kind(skipped_reason)) = 'circuit_breaker';
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
    -- Last sample comes from the v2 wait_samples partitioned tables; the
    -- sample_ts is an int4 offset from pgfr_record.epoch().
    SELECT pgfr_record.epoch() + max(sample_ts) * interval '1 second'
      INTO v_last_sample
      FROM pgfr_record.wait_samples;
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
    -- Sample volume from v2 wait_samples (one row per active wait group per tick).
    SELECT count(*) INTO v_sample_count FROM pgfr_record.wait_samples;
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
        -- Core jobs after the legacy-ring retirement: pgfr_snapshot,
        -- pgfr_cleanup, pgfr_sample_ring (v2 sampler), pgfr_rotate_ring
        -- (v2 ring rotation). Partition-maintenance jobs
        -- (pgfr_truncate_partitions / pgfr_drop_ancient_partitions /
        -- pgfr_precreate_partitions) run on slower cadences and are
        -- considered optional for health-check purposes.
        WITH required_jobs AS (
            SELECT unnest(ARRAY[
                'pgfr_snapshot',
                'pgfr_cleanup',
                'pgfr_sample_ring',
                'pgfr_rotate_ring'
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

    -- Archives + aggregates (activity_samples_archive, lock_samples_archive,
    -- wait_samples_archive, wait_event_aggregates, activity_aggregates,
    -- lock_aggregates) retired with the legacy ring; export_for_upgrade no
    -- longer reports row counts for those tables.

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
    -- Archive-tier volume: the retention_archive_days advice below must
    -- count what that key actually governs, the three _archive_v2 rollup
    -- tables (ring raw samples are bounded by rotation, not retention).
    SELECT (SELECT count(*) FROM pgfr_record.wait_event_rollups_archive_v2)
         + (SELECT count(*) FROM pgfr_record.lock_rollups_archive_v2)
         + (SELECT count(*) FROM pgfr_record.activity_rollups_archive_v2)
    INTO v_sample_count;
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
            'Reduce archive rollup retention period'::text,
            format('High archive rollup row count (%s) with %s day retention', v_sample_count, v_retention_samples),
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



