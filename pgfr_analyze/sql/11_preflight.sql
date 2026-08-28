-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Preflight check: live-catalog readiness checks for installing and
-- enabling pgfr_record, independent of any captured history (there may be
-- none yet). Complements pgfr_record.health_check(), which verifies
-- ongoing operational health once running.

CREATE OR REPLACE FUNCTION pgfr_analyze.preflight_check()
RETURNS TABLE(check_name text, status text, details text, recommendation text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_max_connections     int;
    v_current_connections int;
    v_connection_pct      numeric;
    v_pgss_max            int;
    v_worker_processes    int;
    v_pg_cron_exists      boolean;
BEGIN
    -- System resources: max_worker_processes as a rough capacity signal.
    SELECT setting::int INTO v_worker_processes FROM pg_settings WHERE name = 'max_worker_processes';
    IF v_worker_processes < 4 THEN
        RETURN QUERY SELECT
            'System Resources'::text, 'CAUTION'::text,
            format('max_worker_processes = %s', v_worker_processes),
            'Capture overhead is normally small, but systems with limited worker-process headroom have less margin; consider testing in staging first.'::text;
    ELSE
        RETURN QUERY SELECT
            'System Resources'::text, 'GO'::text,
            format('max_worker_processes = %s', v_worker_processes),
            'Adequate headroom for always-on capture.'::text;
    END IF;

    -- Connection headroom.
    SELECT setting::int INTO v_max_connections FROM pg_settings WHERE name = 'max_connections';
    SELECT count(*) INTO v_current_connections FROM pg_stat_activity;
    v_connection_pct := round(v_current_connections::numeric / nullif(v_max_connections, 0) * 100, 1);
    IF v_connection_pct >= 70 THEN
        RETURN QUERY SELECT
            'Connection Headroom'::text, 'CAUTION'::text,
            format('%s%% of max_connections (%s/%s)', v_connection_pct, v_current_connections, v_max_connections),
            'Connections are already using most of max_connections; pgfr_record''s own backend needs headroom too. Consider raising max_connections or adding a pooler.'::text;
    ELSE
        RETURN QUERY SELECT
            'Connection Headroom'::text, 'GO'::text,
            format('%s%% of max_connections (%s/%s)', v_connection_pct, v_current_connections, v_max_connections),
            'Adequate connection headroom.'::text;
    END IF;

    -- pg_stat_statements budget: pgfr_record captures it like any other
    -- target (a manifest row with requires = 'pg_stat_statements
    -- extension'), isolated per-target via the capture ledger -- if the
    -- extension is absent or its slot budget is thin, that one target's
    -- captures fail without affecting any other tier.
    BEGIN
        SELECT setting::int INTO v_pgss_max FROM pg_settings WHERE name = 'pg_stat_statements.max';
        IF v_pgss_max < 5000 THEN
            RETURN QUERY SELECT
                'pg_stat_statements Budget'::text, 'CAUTION'::text,
                format('pg_stat_statements.max = %s', v_pgss_max),
                'A low statement budget means pgfr_record''s query-level capture will evict frequently; consider raising pg_stat_statements.max (requires a restart).'::text;
        ELSE
            RETURN QUERY SELECT
                'pg_stat_statements Budget'::text, 'GO'::text,
                format('pg_stat_statements.max = %s', v_pgss_max),
                'Adequate statement-tracking capacity.'::text;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            'pg_stat_statements Budget'::text, 'CAUTION'::text,
            'pg_stat_statements extension not found or not configured'::text,
            'Query-level capture (pg_stat_statements) will fail for that one target and show up as an error outcome in pgfr_record.ledger_captures; every other tier is unaffected. Install pg_stat_statements if query-level metrics are wanted.'::text;
    END;

    -- Storage: partition-based retention, not a fixed footprint.
    RETURN QUERY SELECT
        'Storage Overhead'::text, 'GO'::text,
        'Each captured target retains history for its own manifest-defined window (partitioned by hour, day, or month to match); maintain_partitions() drops expired partitions automatically.'::text,
        'Footprint depends on which tiers and targets are enabled and their retention settings; measure the current footprint directly with pgfr_analyze.self_overhead()''s storage_bytes metric once enabled.'::text;

    -- Scheduling: pg_cron is a hard install-time dependency (install.sql
    -- refuses to proceed without it), so its absence is NO-GO, not a
    -- workaround-with-caution case.
    SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') INTO v_pg_cron_exists;
    IF v_pg_cron_exists THEN
        RETURN QUERY SELECT
            'Scheduling (pg_cron)'::text, 'GO'::text,
            'pg_cron extension detected'::text,
            'pgfr_record.enable() will schedule the four cadence-tier jobs and partition maintenance automatically.'::text;
    ELSE
        RETURN QUERY SELECT
            'Scheduling (pg_cron)'::text, 'NO-GO'::text,
            'pg_cron extension not found'::text,
            'pg_cron is required at install time (pgfr_record''s install.sql refuses to proceed without it): CREATE EXTENSION pg_cron; then retry.'::text;
    END IF;

    -- Safety mechanisms actually present in this version: per-target
    -- failure isolation via the capture ledger, and a real preemptive
    -- statement_timeout on every tier run (see pgfr_record.apply_profile()).
    RETURN QUERY SELECT
        'Safety Mechanisms'::text, 'GO'::text,
        'Every target''s capture runs in its own exception block (ok/timeout/lock_timeout/denied/error), recorded in pgfr_record.ledger_captures -- one target failing cannot fail its tier run. Each tier run also carries a real, preemptive statement_timeout dispatched by pgfr_record.apply_profile().'::text,
        'Run pgfr_record.health_check() periodically after enabling to confirm jobs stay scheduled and captures keep pace; pgfr_analyze.self_overhead() measures the ongoing cost directly.'::text;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.preflight_check() IS
    'Live-catalog readiness checks for installing and enabling pgfr_record, independent of any captured history: System Resources, Connection Headroom, pg_stat_statements Budget, Storage Overhead, Scheduling (pg_cron), and Safety Mechanisms. Each row carries a GO/CAUTION/NO-GO verdict, the evidence behind it, and a recommendation. For an appended overall summary row, use preflight_check_with_summary(). Complements pgfr_record.health_check(), which verifies ongoing operational health once running.';

CREATE OR REPLACE FUNCTION pgfr_analyze.preflight_check_with_summary()
RETURNS TABLE(check_name text, status text, details text, recommendation text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nogo_count    int;
    v_caution_count int;
BEGIN
    RETURN QUERY SELECT * FROM pgfr_analyze.preflight_check();

    SELECT
        count(*) FILTER (WHERE c.status = 'NO-GO'),
        count(*) FILTER (WHERE c.status = 'CAUTION')
    INTO v_nogo_count, v_caution_count
    FROM pgfr_analyze.preflight_check() c;

    IF v_nogo_count > 0 THEN
        RETURN QUERY SELECT
            '=== SUMMARY ==='::text, 'NO-GO'::text,
            format('%s blocking issue(s) detected', v_nogo_count),
            'Resolve the NO-GO item(s) above before installing.'::text;
    ELSIF v_caution_count > 0 THEN
        RETURN QUERY SELECT
            '=== SUMMARY ==='::text, 'PROCEED WITH CAUTION'::text,
            format('%s caution(s) detected', v_caution_count),
            'Installation can proceed, but consider addressing the cautions above first.'::text;
    ELSE
        RETURN QUERY SELECT
            '=== SUMMARY ==='::text, 'READY'::text,
            'All checks passed'::text,
            'System is ready for pgfr_record installation. Run pgfr_record.health_check() periodically after enabling to verify continued health.'::text;
    END IF;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.preflight_check_with_summary() IS
    'preflight_check() with an appended === SUMMARY === row: NO-GO if any check is NO-GO, else PROCEED WITH CAUTION if any check is CAUTION, else READY.';
