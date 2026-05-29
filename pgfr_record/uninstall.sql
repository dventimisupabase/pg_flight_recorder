-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Uninstall pgfr_record (DESTRUCTIVE — removes all data)
-- Run with: psql --single-transaction -f pgfr_record/uninstall.sql

-- Unschedule every pgfr_ cron job (the legacy and v2 sets, plus any future
-- jobs we add) and drop their job_run_details. Matches on prefix rather
-- than a fixed name list so this script stays correct as the recorder's
-- cron surface evolves.
DO $$
DECLARE
    v_jobids BIGINT[];
BEGIN
    SELECT array_agg(jobid) INTO v_jobids
    FROM cron.job
    WHERE jobname LIKE 'pgfr%';

    PERFORM cron.unschedule(jobname)
    FROM cron.job
    WHERE jobname LIKE 'pgfr%';

    -- DELETE on cron.job_run_details is best-effort. Managed Postgres
    -- (e.g. Supabase) typically grants USAGE on cron + EXECUTE on
    -- cron.unschedule but does not grant DELETE on cron.job_run_details;
    -- swallow the permission error so the rest of the uninstall proceeds.
    IF v_jobids IS NOT NULL THEN
        BEGIN
            DELETE FROM cron.job_run_details WHERE jobid = ANY(v_jobids);
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE 'pgfr_record uninstall: skipped cron.job_run_details cleanup (insufficient_privilege). Jobs were still unscheduled.';
        END;
    END IF;
EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN undefined_function THEN NULL;
    WHEN insufficient_privilege THEN NULL;
END;
$$;

DROP SCHEMA IF EXISTS pgfr_analyze CASCADE;
DROP SCHEMA IF EXISTS pgfr_record CASCADE;
