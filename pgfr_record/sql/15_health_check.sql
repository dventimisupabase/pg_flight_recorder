-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- health_check() (§9): v1-like shape, reinterpreted for v2's mechanism --
-- pg_cron jobs active per tier, last capture per tier, ledger miss rate
-- (1h), and partition-maintenance status (partitions exist >= 2 widths
-- ahead for every target; no expired-but-still-attached partitions
-- lingering). Read-only and judgment-free: it reports facts against
-- fixed, structural thresholds (is a job scheduled, has a tier run
-- recently, is a partition still attached past its retention), never an
-- opinion about what's normal -- pgfr_analyze is where opinions live.
CREATE OR REPLACE FUNCTION pgfr_record.health_check()
RETURNS TABLE(check_name text, status text, detail text)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- Tier + maintenance jobs scheduled and active.
    RETURN QUERY
    SELECT
        'cron_job: ' || t.tier,
        CASE WHEN j.active THEN 'ok' ELSE 'missing' END,
        coalesce(format('schedule=%s', j.schedule), 'not scheduled -- see pgfr_record.enable()')
    FROM unnest(ARRAY['fast', 'medium', 'slow', 'on_change']) AS t(tier)
    LEFT JOIN cron.job j ON j.jobname = 'pgfr_tier_' || t.tier;

    RETURN QUERY
    SELECT
        'cron_job: maintenance',
        CASE WHEN j.active THEN 'ok' ELSE 'missing' END,
        coalesce(format('schedule=%s', j.schedule), 'not scheduled -- see pgfr_record.enable()')
    FROM cron.job j
    RIGHT JOIN (SELECT 1) x ON j.jobname = 'pgfr_maintain_partitions';

    -- Last capture per tier, judged against that tier's own interval
    -- (from whichever profile is currently applied, read back from
    -- cron.job -- not a hardcoded assumption).
    RETURN QUERY
    SELECT
        'last_capture: ' || t.tier,
        CASE
            WHEN lr.finished_at IS NULL THEN 'never'
            WHEN lr.finished_at >= clock_timestamp() - coalesce(pgfr_record._cron_schedule_to_interval(j.schedule), interval '15 minutes') * 3
                THEN 'ok'
            ELSE 'stale'
        END,
        coalesce('last finished ' || lr.finished_at::text, 'no run recorded yet')
    FROM unnest(ARRAY['fast', 'medium', 'slow', 'on_change']) AS t(tier)
    LEFT JOIN cron.job j ON j.jobname = 'pgfr_tier_' || t.tier
    LEFT JOIN LATERAL (
        SELECT finished_at FROM pgfr_record.ledger_runs WHERE tier = t.tier ORDER BY finished_at DESC LIMIT 1
    ) lr ON true;

    -- Ledger miss rate over the last hour.
    RETURN QUERY
    SELECT
        'ledger_miss_rate_1h',
        CASE WHEN m.miss_rate IS NULL OR m.miss_rate < 0.05 THEN 'ok' ELSE 'degraded' END,
        format('%s%% of captures missed in the last hour (%s of %s)', coalesce(round(m.miss_rate * 100, 1), 0), coalesce(m.missed, 0), coalesce(m.total, 0))
    FROM (
        SELECT
            count(*) FILTER (WHERE lc.outcome <> 'ok') AS missed,
            count(*) AS total,
            (count(*) FILTER (WHERE lc.outcome <> 'ok'))::numeric / NULLIF(count(*), 0) AS miss_rate
        FROM pgfr_record.ledger_captures lc
        JOIN pgfr_record.ledger_runs lr ON lr.run_id = lc.run_id
        WHERE lr.captured_at >= clock_timestamp() - interval '1 hour'
    ) m;

    -- Partition maintenance: every target should have partitions
    -- covering >= 2 widths beyond now(), and none expired-but-attached.
    RETURN QUERY
    SELECT
        'partitions: ' || t.parent_table,
        CASE WHEN c.ahead >= 2 AND c.expired = 0 THEN 'ok' ELSE 'attention' END,
        format('%s partition(s) ahead of the current one, %s expired-but-still-attached', c.ahead, c.expired)
    FROM pgfr_record._partition_targets() t
    CROSS JOIN LATERAL (
        SELECT
            count(*) FILTER (
                WHERE pgfr_record._partition_lower_bound(child.relname, t.parent_table, pgfr_record._partition_unit(t.retention))
                      > date_trunc(pgfr_record._partition_unit(t.retention), clock_timestamp())
            ) AS ahead,
            count(*) FILTER (
                WHERE pgfr_record._partition_lower_bound(child.relname, t.parent_table, pgfr_record._partition_unit(t.retention))
                          + ('1 ' || pgfr_record._partition_unit(t.retention))::interval
                      < clock_timestamp() - t.retention
            ) AS expired
        FROM pg_inherits i
        JOIN pg_class child ON child.oid = i.inhrelid
        JOIN pg_class parent ON parent.oid = i.inhparent
        WHERE parent.relname = t.parent_table
    ) c;
END;
$$;

COMMENT ON FUNCTION pgfr_record.health_check() IS
    'pg_cron jobs active per tier, last capture per tier, ledger miss rate (1h), and partition-maintenance status (§9). Read-only and threshold-free in the judgmental sense -- every check is against a fixed structural fact (is a job scheduled, is a partition still attached past retention), never an opinion; opinions are pgfr_analyze''s job.';
