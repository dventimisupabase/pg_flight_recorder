-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Coverage / gap accounting: expected vs observed tier runs, and where the
-- recorder was blind. Built directly on pgfr_record.ledger_runs, which
-- already records one row per completed tier run -- no separate expected-
-- tick model to maintain per collector, unlike v1's fixed one-tick-per-
-- minute assumption. The expected interval for each tier comes from that
-- tier's live pg_cron schedule (whichever profile is currently applied),
-- via pgfr_record._cron_schedule_to_interval().

CREATE OR REPLACE FUNCTION pgfr_analyze.coverage(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(cadence_tier text, expected_runs numeric, observed_runs bigint, coverage_ratio numeric)
LANGUAGE sql STABLE AS $$
    WITH tiers AS (
        SELECT t.tier, pgfr_record._cron_schedule_to_interval(j.schedule) AS tier_interval
        FROM unnest(ARRAY['fast', 'medium', 'slow', 'on_change']) AS t(tier)
        LEFT JOIN cron.job j ON j.jobname = 'pgfr_tier_' || t.tier
    ),
    observed AS (
        SELECT tier, count(DISTINCT run_id) AS n
        FROM pgfr_record.ledger_runs
        WHERE captured_at >= p_from_t AND captured_at < p_to_t
        GROUP BY tier
    )
    SELECT
        tiers.tier,
        CASE WHEN tiers.tier_interval IS NULL THEN NULL
             ELSE round(extract(epoch FROM (p_to_t - p_from_t)) / extract(epoch FROM tiers.tier_interval), 1)
        END,
        coalesce(observed.n, 0),
        CASE WHEN tiers.tier_interval IS NULL
                  OR extract(epoch FROM (p_to_t - p_from_t)) <= 0
                  OR extract(epoch FROM (p_to_t - p_from_t)) / extract(epoch FROM tiers.tier_interval) = 0
             THEN NULL
             ELSE round(coalesce(observed.n, 0) / (extract(epoch FROM (p_to_t - p_from_t)) / extract(epoch FROM tiers.tier_interval)), 3)
        END
    FROM tiers
    LEFT JOIN observed ON observed.tier = tiers.tier
    ORDER BY tiers.tier;
$$;

COMMENT ON FUNCTION pgfr_analyze.coverage(timestamptz, timestamptz) IS
    'Expected vs observed tier runs between p_from_t and p_to_t, per cadence tier. Expected count is derived from the tier''s live pg_cron schedule, not a hardcoded assumption; NULL when the tier has no scheduled job.';

CREATE OR REPLACE FUNCTION pgfr_analyze.coverage(p_window interval)
RETURNS TABLE(cadence_tier text, expected_runs numeric, observed_runs bigint, coverage_ratio numeric)
LANGUAGE sql STABLE AS $$
    SELECT * FROM pgfr_analyze.coverage(clock_timestamp() - p_window, clock_timestamp());
$$;

COMMENT ON FUNCTION pgfr_analyze.coverage(interval) IS
    'Convenience overload of coverage(from_t, to_t) for the trailing p_window ending now.';

-- Contiguous runs of missing tier runs. A "missed tick" is an expected
-- interval boundary with no ledger_runs row for that tier landing inside
-- it; consecutive missed ticks group into one gap via the standard
-- row_number()-offset islands-and-gaps technique. A tier with no
-- resolvable schedule at all (never enabled, fully unscheduled, or an
-- unparseable custom schedule) has no interval to grid against, so the
-- entire queried window is reported as one gap rather than silently
-- omitting that tier from the result.
CREATE OR REPLACE FUNCTION pgfr_analyze.coverage_gaps(p_from_t timestamptz, p_to_t timestamptz)
RETURNS TABLE(cadence_tier text, gap_start timestamptz, gap_end timestamptz, missed_ticks bigint, attributed_reason text)
LANGUAGE sql STABLE AS $$
    WITH tiers AS (
        SELECT t.tier, pgfr_record._cron_schedule_to_interval(j.schedule) AS tier_interval,
               coalesce(j.active, false) AS job_active
        FROM unnest(ARRAY['fast', 'medium', 'slow', 'on_change']) AS t(tier)
        LEFT JOIN cron.job j ON j.jobname = 'pgfr_tier_' || t.tier
    ),
    unscheduled AS (
        SELECT tier, p_from_t, p_to_t, NULL::bigint, 'cron_inactive'::text
        FROM tiers
        WHERE tier_interval IS NULL
    ),
    ticks AS (
        SELECT tiers.tier, tiers.tier_interval, tiers.job_active, gs AS tick
        FROM tiers, LATERAL generate_series(p_from_t, p_to_t, tiers.tier_interval) AS gs
        WHERE tiers.tier_interval IS NOT NULL
    ),
    missed AS (
        SELECT ticks.*
        FROM ticks
        WHERE NOT EXISTS (
            SELECT 1 FROM pgfr_record.ledger_runs lr
            WHERE lr.tier = ticks.tier
              AND lr.captured_at >= ticks.tick
              AND lr.captured_at < ticks.tick + ticks.tier_interval
        )
    ),
    flagged AS (
        SELECT *,
               tick - (row_number() OVER (PARTITION BY tier ORDER BY tick) * tier_interval) AS grp
        FROM missed
    ),
    scheduled_gaps AS (
        SELECT tier, min(tick), max(tick) + max(tier_interval), count(*),
               CASE WHEN NOT bool_and(job_active) THEN 'cron_inactive' ELSE 'unknown' END
        FROM flagged
        GROUP BY tier, grp
    )
    SELECT * FROM unscheduled
    UNION ALL
    SELECT * FROM scheduled_gaps
    ORDER BY 1, 2;
$$;

COMMENT ON FUNCTION pgfr_analyze.coverage_gaps(timestamptz, timestamptz) IS
    'Contiguous runs of missed tier ticks between p_from_t and p_to_t, per cadence tier, with an attributed_reason (cron_inactive when the tier''s job is missing or inactive, unknown otherwise). Per-target capture failures within a run that did happen are not gaps: query pgfr_record.ledger_captures directly for those (outcome <> ''ok'').';

CREATE OR REPLACE FUNCTION pgfr_analyze.coverage_gaps(p_window interval)
RETURNS TABLE(cadence_tier text, gap_start timestamptz, gap_end timestamptz, missed_ticks bigint, attributed_reason text)
LANGUAGE sql STABLE AS $$
    SELECT * FROM pgfr_analyze.coverage_gaps(clock_timestamp() - p_window, clock_timestamp());
$$;

COMMENT ON FUNCTION pgfr_analyze.coverage_gaps(interval) IS
    'Convenience overload of coverage_gaps(from_t, to_t) for the trailing p_window ending now.';
