-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- enable() / disable() (§9): the single source of truth for whether
-- pgfr_record's pg_cron jobs are scheduled. Nothing before this point in
-- the install schedules anything -- generators build tables/views/plans,
-- but only enable() turns the collector on, applying the default
-- profile and scheduling the hourly maintenance job alongside the four
-- tier jobs. cron.schedule()/cron.unschedule() are idempotent, so both
-- functions are safe to call repeatedly.
CREATE OR REPLACE FUNCTION pgfr_record.enable()
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pgfr_record.apply_profile('default');
    PERFORM cron.schedule('pgfr_maintain_partitions', '0 * * * *', 'SELECT pgfr_record.maintain_partitions()');
    -- See the comment in apply_profile(): cron.schedule() does not
    -- reactivate an already-existing, deactivated job on its own.
    UPDATE cron.job SET active = true WHERE jobname = 'pgfr_maintain_partitions';
END;
$$;

COMMENT ON FUNCTION pgfr_record.enable() IS
    'Applies the default profile (scheduling the four tier jobs) and schedules the hourly partition-maintenance job. The single "turn pgfr_record on" operation (§10.1 acceptance criterion 1); idempotent.';

CREATE OR REPLACE FUNCTION pgfr_record.disable()
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM cron.unschedule(jobname)
    FROM cron.job
    WHERE jobname IN ('pgfr_tier_fast', 'pgfr_tier_medium', 'pgfr_tier_slow', 'pgfr_tier_on_change', 'pgfr_maintain_partitions');
END;
$$;

COMMENT ON FUNCTION pgfr_record.disable() IS
    'Unschedules the four tier jobs and the maintenance job. Archive data, the manifest, and the capture plan are untouched -- this only stops new captures. Idempotent (unscheduling an absent job is a no-op).';
