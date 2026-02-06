-- =============================================================================
-- Uninstall pg-flight-recorder (DATA PRESERVING)
-- =============================================================================
-- Stops cron jobs and removes functions/views, but KEEPS your data.
-- This allows you to reinstall or upgrade without losing historical data.
--
-- Run with: psql -f uninstall.sql
--
-- To completely remove including all data:
--   psql -f uninstall_full.sql
--   OR after this script: DROP SCHEMA flight_recorder CASCADE;
-- =============================================================================

\set ON_ERROR_STOP on

DO $$
DECLARE
    v_version TEXT;
    v_snapshot_count BIGINT;
    v_jobids BIGINT[];
    v_deleted_count INTEGER;
BEGIN
    -- Get current version for reporting
    BEGIN
        SELECT value INTO v_version
        FROM flight_recorder.config WHERE key = 'schema_version';
    EXCEPTION
        WHEN undefined_table THEN v_version := 'unknown';
    END;

    -- Count snapshots to show what's being preserved
    BEGIN
        SELECT count(*) INTO v_snapshot_count FROM flight_recorder.snapshots;
    EXCEPTION
        WHEN undefined_table THEN v_snapshot_count := 0;
    END;

    RAISE NOTICE E'\n=== Uninstalling Flight Recorder (v%) ===', COALESCE(v_version, 'unknown');
    RAISE NOTICE 'Preserving % snapshots and all historical data.', v_snapshot_count;
    RAISE NOTICE '';

    -- =========================================================================
    -- Step 1: Stop all cron jobs
    -- =========================================================================
    BEGIN
        SELECT array_agg(jobid) INTO v_jobids
        FROM cron.job
        WHERE jobname IN (
            'flight_recorder_snapshot',
            'flight_recorder_sample',
            'flight_recorder_flush',
            'flight_recorder_archive',
            'flight_recorder_cleanup'
        );

        PERFORM cron.unschedule('flight_recorder_snapshot')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_snapshot');

        PERFORM cron.unschedule('flight_recorder_sample')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_sample');

        PERFORM cron.unschedule('flight_recorder_flush')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_flush');

        PERFORM cron.unschedule('flight_recorder_archive')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_archive');

        PERFORM cron.unschedule('flight_recorder_cleanup')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_cleanup');

        IF v_jobids IS NOT NULL THEN
            DELETE FROM cron.job_run_details WHERE jobid = ANY(v_jobids);
            GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
            IF v_deleted_count > 0 THEN
                RAISE NOTICE 'Cleaned up % cron job history records.', v_deleted_count;
            END IF;
        END IF;

        RAISE NOTICE 'Stopped all scheduled jobs.';
    EXCEPTION
        WHEN undefined_table THEN
            RAISE NOTICE 'pg_cron not found, skipping job cleanup.';
        WHEN undefined_function THEN
            RAISE NOTICE 'pg_cron functions not available, skipping job cleanup.';
    END;
END $$;

-- =========================================================================
-- Step 2: Drop views (these reference functions)
-- =========================================================================
DROP VIEW IF EXISTS flight_recorder.deltas CASCADE;
DROP VIEW IF EXISTS flight_recorder.recent_waits CASCADE;
DROP VIEW IF EXISTS flight_recorder.recent_activity CASCADE;
DROP VIEW IF EXISTS flight_recorder.recent_locks CASCADE;
DROP VIEW IF EXISTS flight_recorder.recent_replication CASCADE;
DROP VIEW IF EXISTS flight_recorder.capacity_dashboard CASCADE;

-- =========================================================================
-- Step 3: Drop all functions
-- =========================================================================
-- Internal functions
DROP FUNCTION IF EXISTS flight_recorder._get_config(TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._get_config_int(TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._get_config_bool(TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._get_config_interval(TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._circuit_breaker_check() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._circuit_breaker_record(TEXT, BIGINT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._check_schema_size() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._detect_pg_version() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._safe_query_preview(TEXT, INTEGER) CASCADE;

-- Core collection functions
DROP FUNCTION IF EXISTS flight_recorder.sample() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.snapshot() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.flush_ring_to_aggregates() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.archive_ring_samples() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.cleanup() CASCADE;

-- Configuration functions
DROP FUNCTION IF EXISTS flight_recorder.set_mode(TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.get_mode() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.apply_profile(TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.list_profiles() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.config_recommendations() CASCADE;

-- Analysis functions (from install.sql core)
DROP FUNCTION IF EXISTS flight_recorder.compare(TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.wait_summary(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.export_for_upgrade() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.health_check() CASCADE;

-- Reporting functions (from reporting.sql, may or may not be installed)
DROP FUNCTION IF EXISTS flight_recorder.dead_tuple_growth_rate(OID, INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.table_size_growth_rate(OID, INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.estimate_table_bloat(OID) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.bloat_report(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.modification_rate(OID, INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.hot_update_ratio(OID) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.time_to_budget_exhaustion(OID, BIGINT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.oid_consumption_rate(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.time_to_oid_exhaustion() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.anomaly_report(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.summary_report(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.detect_query_storms(INTERVAL, NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder._diagnose_regression_causes(BIGINT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.detect_regressions(INTERVAL, NUMERIC) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.performance_report(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.check_alerts(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.report(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.report(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.preflight_check() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.preflight_check_with_summary() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.quarterly_review() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.quarterly_review_with_summary() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.capacity_summary(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.capacity_report(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.table_compare(TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.table_hotspots(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.unused_indexes(INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.index_efficiency(TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.config_changes(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.config_at(TIMESTAMPTZ, TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.config_health_check() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.db_role_config_at(TIMESTAMPTZ, TEXT, TEXT, TEXT) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.db_role_config_changes(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.db_role_config_summary() CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.what_happened_at(TIMESTAMPTZ, INTERVAL) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.incident_timeline(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.blast_radius(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;
DROP FUNCTION IF EXISTS flight_recorder.blast_radius_report(TIMESTAMPTZ, TIMESTAMPTZ) CASCADE;

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== Flight Recorder Uninstalled ===';
    RAISE NOTICE '';
    RAISE NOTICE 'Removed:';
    RAISE NOTICE '  - All scheduled cron jobs';
    RAISE NOTICE '  - All functions and views';
    RAISE NOTICE '';
    RAISE NOTICE 'Preserved (in flight_recorder schema):';
    RAISE NOTICE '  - snapshots and all related tables';
    RAISE NOTICE '  - archive tables (activity, locks, waits)';
    RAISE NOTICE '  - aggregate tables';
    RAISE NOTICE '  - configuration settings';
    RAISE NOTICE '';
    RAISE NOTICE 'To reinstall: psql -f install.sql';
    RAISE NOTICE 'To remove data: DROP SCHEMA flight_recorder CASCADE;';
    RAISE NOTICE '';
END $$;
