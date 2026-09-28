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
DECLARE
    v_rollup          record;
    v_rollup_unit     text;
    v_last_closed     timestamptz;
    v_rollup_ok       boolean;
    v_rollup_has_data boolean;
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

    -- Rollup lag (milestone 8): for every rollup-enabled target, does the
    -- most recently closed bucket have a row yet -- but only when that
    -- bucket actually has raw data to roll up. Without that guard, a
    -- brand-new install would report "attention" for every rollup target
    -- on day one: yesterday's bucket has neither a rollup row nor any raw
    -- data (the install didn't exist yesterday), which is correctly
    -- nothing to do, not a lagging collector -- the same "empty candidate
    -- is not a problem" distinction run_tier()'s own bucket-close step
    -- already makes. A gap where raw data *does* exist means either the
    -- collector hasn't ticked since that bucket closed, or its
    -- bucket-close step is genuinely failing (see run_tier()'s RAISE
    -- WARNING) -- either way, a structural fact worth surfacing, not an
    -- opinion about whether it matters (that judgment is pgfr_analyze's).
    -- Needs per-target dynamic SQL (unlike the partition check above,
    -- there is no generic catalog view that answers "does this specific
    -- table have a row for this bucket"), so this is a loop, not a single
    -- RETURN QUERY SELECT like every other check here.
    FOR v_rollup IN
        SELECT DISTINCT source_view, archive_table, rollup_table, rollup_granularity
        FROM pgfr_record.capture_plan
        WHERE rollup_table IS NOT NULL
    LOOP
        v_rollup_unit := pgfr_record._partition_unit(v_rollup.rollup_granularity);
        v_last_closed := date_trunc(v_rollup_unit, clock_timestamp()) - v_rollup.rollup_granularity;
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM pgfr_record.%I WHERE bucket_start = $1),
                    EXISTS (SELECT 1 FROM pgfr_record.%I WHERE captured_at >= $1 AND captured_at < $1 + $2::interval)',
            v_rollup.rollup_table, v_rollup.archive_table
        )
        INTO v_rollup_ok, v_rollup_has_data
        USING v_last_closed, v_rollup.rollup_granularity;

        check_name := 'rollup: ' || v_rollup.source_view;
        status := CASE WHEN v_rollup_ok OR NOT v_rollup_has_data THEN 'ok' ELSE 'attention' END;
        detail := CASE
            WHEN v_rollup_ok THEN format('most recently closed bucket (%s) is rolled up', v_last_closed)
            WHEN NOT v_rollup_has_data THEN format('most recently closed bucket (%s) has no raw data to roll up', v_last_closed)
            ELSE format('most recently closed bucket (%s) has raw data but is not rolled up yet', v_last_closed)
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION pgfr_record.health_check() IS
    'pg_cron jobs active per tier, last capture per tier, ledger miss rate (1h), partition-maintenance status (§9), and rollup lag per rollup-enabled target (milestone 8). Read-only and threshold-free in the judgmental sense -- every check is against a fixed structural fact (is a job scheduled, is a partition still attached past retention, does the most recently closed bucket have a rollup row), never an opinion; opinions are pgfr_analyze''s job.';
