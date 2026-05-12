-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Uninstall pgfr_record (DESTRUCTIVE — removes all data)
-- Run with: psql --single-transaction -f pgfr_record/uninstall.sql

-- Unschedule cron jobs (they live in the cron schema, not ours)
DO $$
DECLARE
    v_jobids BIGINT[];
BEGIN
    SELECT array_agg(jobid) INTO v_jobids
    FROM cron.job
    WHERE jobname IN ('pgfr_snapshot', 'pgfr_sample', 'pgfr_flush', 'pgfr_archive', 'pgfr_cleanup');

    PERFORM cron.unschedule(jobname)
    FROM cron.job
    WHERE jobname IN ('pgfr_snapshot', 'pgfr_sample', 'pgfr_flush', 'pgfr_archive', 'pgfr_cleanup');

    IF v_jobids IS NOT NULL THEN
        DELETE FROM cron.job_run_details WHERE jobid = ANY(v_jobids);
    END IF;
EXCEPTION
    WHEN undefined_table THEN NULL;
    WHEN undefined_function THEN NULL;
END;
$$;

DROP SCHEMA IF EXISTS pgfr_analyze CASCADE;
DROP SCHEMA IF EXISTS pgfr_record CASCADE;
