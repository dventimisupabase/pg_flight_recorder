-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- quarterly_review(): a 90-day-lookback health grade across six
-- components, meant to be run periodically ("quarterly") rather than
-- continuously. Collection Performance and Reliability are computed
-- directly from pgfr_record.ledger_runs/ledger_captures (not via
-- self_overhead(), which additionally requires a minted pg_statio_all_tables
-- payload schema for a metric this review doesn't need); Data Freshness,
-- pg_cron Job Health, and Partition Maintenance are graded from
-- pgfr_record.health_check()'s own facts, grouped by check_name prefix.

CREATE OR REPLACE FUNCTION pgfr_analyze.quarterly_review()
RETURNS TABLE(component text, status text, metric text, assessment text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_now              timestamptz := clock_timestamp();
    v_lookback         interval := interval '90 days';
    v_worst_avg_ms     numeric;
    v_perf_detail      text;
    v_storage_bytes    numeric;
    v_failed_captures  bigint;
    v_total_captures   bigint;
    v_stale_count      int;
    v_cron_count       int;
    v_partition_count  int;
BEGIN
    RETURN QUERY SELECT
        '=== QUARTERLY REVIEW ==='::text, 'INFO'::text,
        format('Review period: last 90 days | Generated: %s', v_now::text),
        'This review grades pgfr_record health for continued always-on operation.'::text;

    -- 1. Collection Performance: worst (highest) average tick duration
    -- across cadence tiers, from ledger_runs directly.
    SELECT string_agg(format('%s: %s ms avg', tier, round(ms, 1)), ' | ' ORDER BY ms DESC), max(ms)
    INTO v_perf_detail, v_worst_avg_ms
    FROM (
        SELECT tier, avg(extract(epoch FROM (finished_at - captured_at)) * 1000) AS ms
        FROM pgfr_record.ledger_runs
        WHERE captured_at > v_now - v_lookback
        GROUP BY tier
    ) t;

    IF v_worst_avg_ms IS NULL THEN
        RETURN QUERY SELECT
            '1. Collection Performance'::text, 'ERROR'::text,
            'No tier runs in the last 90 days'::text,
            'pgfr_record may not be running. Check pg_cron jobs (SELECT * FROM cron.job WHERE jobname LIKE ''pgfr%'').'::text;
    ELSIF v_worst_avg_ms < 200 THEN
        RETURN QUERY SELECT '1. Collection Performance'::text, 'EXCELLENT'::text, v_perf_detail, 'Capture overhead is minimal. No action needed.'::text;
    ELSIF v_worst_avg_ms < 500 THEN
        RETURN QUERY SELECT '1. Collection Performance'::text, 'GOOD'::text, v_perf_detail, 'Capture overhead is acceptable. Continue monitoring.'::text;
    ELSE
        RETURN QUERY SELECT '1. Collection Performance'::text, 'REVIEW NEEDED'::text, v_perf_detail,
            'One or more tiers are running slower than expected; consider a lighter profile (pgfr_record.apply_profile()) or investigating system bottlenecks.'::text;
    END IF;

    -- 2. Storage Consumption: live, matching check_alerts()'s own
    -- storage query rather than self_overhead()'s (same reason: no
    -- dependency on a payload schema this review doesn't otherwise need).
    SELECT sum(pg_total_relation_size(c.oid)) INTO v_storage_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('pgfr_record', 'pgfr_analyze') AND c.relkind IN ('r', 'm');

    IF v_storage_bytes < 3000::bigint * 1024 * 1024 THEN
        RETURN QUERY SELECT '2. Storage Consumption'::text, 'EXCELLENT'::text, pg_size_pretty(v_storage_bytes), 'Storage usage is healthy. Partition retention is working correctly.'::text;
    ELSIF v_storage_bytes < 6000::bigint * 1024 * 1024 THEN
        RETURN QUERY SELECT '2. Storage Consumption'::text, 'GOOD'::text, pg_size_pretty(v_storage_bytes), 'Storage usage is acceptable. Monitor the growth trend.'::text;
    ELSE
        RETURN QUERY SELECT '2. Storage Consumption'::text, 'REVIEW NEEDED'::text, pg_size_pretty(v_storage_bytes), 'Storage usage is high. Review retention settings in pgfr_record.manifest, or disable lower-value targets.'::text;
    END IF;

    -- 3. Collection Reliability: non-ok, non-skipped-disabled outcomes
    -- over 90 days (a deliberately disabled target isn't a failure).
    SELECT
        count(*) FILTER (WHERE lc.outcome NOT IN ('ok', 'skipped_disabled')),
        count(*)
    INTO v_failed_captures, v_total_captures
    FROM pgfr_record.ledger_captures lc
    WHERE lc.captured_at > v_now - v_lookback;

    IF v_failed_captures = 0 THEN
        RETURN QUERY SELECT '3. Collection Reliability'::text, 'EXCELLENT'::text, format('0 failed captures out of %s in 90 days', v_total_captures), 'pgfr_record is capturing reliably.'::text;
    ELSIF v_failed_captures < 10 THEN
        RETURN QUERY SELECT '3. Collection Reliability'::text, 'GOOD'::text, format('%s failed captures out of %s in 90 days', v_failed_captures, v_total_captures), 'A small number of failures is normal and acceptable.'::text;
    ELSE
        RETURN QUERY SELECT '3. Collection Reliability'::text, 'REVIEW NEEDED'::text, format('%s failed captures out of %s in 90 days', v_failed_captures, v_total_captures), 'Frequent failures detected; inspect pgfr_record.ledger_captures for error patterns and their detail column.'::text;
    END IF;

    -- 4. Data Freshness, 5. pg_cron Job Health, 6. Partition Maintenance:
    -- all graded directly from pgfr_record.health_check(), grouped by
    -- check_name prefix.
    SELECT count(*) INTO v_stale_count FROM pgfr_record.health_check() hc WHERE hc.check_name LIKE 'last_capture:%' AND hc.status <> 'ok';
    IF v_stale_count = 0 THEN
        RETURN QUERY SELECT '4. Data Freshness'::text, 'EXCELLENT'::text, 'Every tier has a recent capture'::text, 'Captures are running on schedule.'::text;
    ELSE
        RETURN QUERY SELECT '4. Data Freshness'::text, 'ERROR'::text, format('%s tier(s) stale or never captured', v_stale_count), 'Check pg_cron job activity for the affected tier(s) (SELECT * FROM cron.job WHERE jobname LIKE ''pgfr%'').'::text;
    END IF;

    SELECT count(*) INTO v_cron_count FROM pgfr_record.health_check() hc WHERE hc.check_name LIKE 'cron_job:%' AND hc.status <> 'ok';
    IF v_cron_count = 0 THEN
        RETURN QUERY SELECT '5. pg_cron Job Health'::text, 'EXCELLENT'::text, 'All pgfr_ jobs active'::text, 'Scheduling is healthy.'::text;
    ELSE
        RETURN QUERY SELECT '5. pg_cron Job Health'::text, 'CRITICAL'::text, format('%s pgfr_ job(s) missing or inactive', v_cron_count), 'Run pgfr_record.enable() to (re)schedule the affected job(s).'::text;
    END IF;

    SELECT count(*) INTO v_partition_count FROM pgfr_record.health_check() hc WHERE hc.check_name LIKE 'partitions:%' AND hc.status <> 'ok';
    IF v_partition_count = 0 THEN
        RETURN QUERY SELECT '6. Partition Maintenance'::text, 'EXCELLENT'::text, 'Every target has partitions ahead of schedule, none expired-but-attached'::text, 'Partition maintenance is healthy.'::text;
    ELSE
        RETURN QUERY SELECT '6. Partition Maintenance'::text, 'REVIEW NEEDED'::text, format('%s target(s) need partition attention', v_partition_count), 'Run pgfr_record.maintain_partitions(); if this persists, confirm the pgfr_maintain_partitions cron job is scheduled and active.'::text;
    END IF;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.quarterly_review() IS
    'A 90-day-lookback health grade across six components: Collection Performance (tier tick duration from ledger_runs), Storage Consumption (live schema size), Collection Reliability (ledger_captures failure rate), Data Freshness, pg_cron Job Health, and Partition Maintenance (the last three from pgfr_record.health_check()). Each component grades EXCELLENT/GOOD/REVIEW NEEDED/ERROR/CRITICAL. For an appended overall summary row, use quarterly_review_with_summary().';

CREATE OR REPLACE FUNCTION pgfr_analyze.quarterly_review_with_summary()
RETURNS TABLE(component text, status text, metric text, assessment text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_issues_count int;
BEGIN
    RETURN QUERY SELECT * FROM pgfr_analyze.quarterly_review();

    SELECT count(*) INTO v_issues_count
    FROM pgfr_analyze.quarterly_review() qr
    WHERE qr.status IN ('ERROR', 'REVIEW NEEDED', 'CRITICAL');

    IF v_issues_count = 0 THEN
        RETURN QUERY SELECT
            '=== QUARTERLY REVIEW SUMMARY ==='::text, 'HEALTHY'::text,
            'All components within acceptable parameters'::text,
            'pgfr_record is operating as expected. Schedule the next review in 3 months.'::text;
    ELSE
        RETURN QUERY SELECT
            '=== QUARTERLY REVIEW SUMMARY ==='::text, 'ACTION REQUIRED'::text,
            format('%s component(s) need review', v_issues_count),
            'Address the components marked ERROR, REVIEW NEEDED, or CRITICAL above.'::text;
    END IF;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.quarterly_review_with_summary() IS
    'quarterly_review() with an appended === QUARTERLY REVIEW SUMMARY === row: ACTION REQUIRED if any component is ERROR, REVIEW NEEDED, or CRITICAL, else HEALTHY.';
