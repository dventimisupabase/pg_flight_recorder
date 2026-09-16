-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- performance_report(): the recorder's own performance over a configurable
-- lookback (unlike quarterly_review()'s fixed 90 days), with two things
-- self_overhead() doesn't provide: per-tier max duration (not just avg) and
-- a before/after trend split within the window.

CREATE OR REPLACE FUNCTION pgfr_analyze.performance_report(p_lookback interval DEFAULT interval '24 hours')
RETURNS TABLE(metric text, value text, assessment text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_now              timestamptz := clock_timestamp();
    v_start            timestamptz := v_now - p_lookback;
    v_mid              timestamptz := v_now - p_lookback / 2;
    v_row              record;
    v_storage_bytes    numeric;
    v_total_captures   bigint;
    v_failed_captures  bigint;
    v_older_avg        numeric;
    v_recent_avg       numeric;
BEGIN
    -- Per-tier avg/max tick duration.
    FOR v_row IN
        SELECT tier,
               avg(extract(epoch FROM (finished_at - captured_at)) * 1000) AS avg_ms,
               max(extract(epoch FROM (finished_at - captured_at)) * 1000) AS max_ms
        FROM pgfr_record.ledger_runs
        WHERE captured_at BETWEEN v_start AND v_now
        GROUP BY tier
        ORDER BY tier
    LOOP
        metric := format('%s tier duration', v_row.tier);
        value := format('avg %s ms, max %s ms', round(v_row.avg_ms::numeric, 1), round(v_row.max_ms::numeric, 1));
        assessment := CASE
            WHEN v_row.avg_ms < 100 THEN 'Excellent'
            WHEN v_row.avg_ms < 500 THEN 'Good'
            WHEN v_row.avg_ms < 1000 THEN 'Acceptable'
            ELSE 'Poor -- consider a lighter profile (pgfr_record.apply_profile())'
        END;
        RETURN NEXT;
    END LOOP;

    -- Storage size, live (not window-relative).
    SELECT sum(pg_total_relation_size(c.oid)) INTO v_storage_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('pgfr_record', 'pgfr_analyze') AND c.relkind IN ('r', 'm');

    metric := 'Storage Size';
    value := pg_size_pretty(v_storage_bytes);
    assessment := CASE
        WHEN v_storage_bytes < 1000::bigint * 1024 * 1024 THEN 'Healthy'
        WHEN v_storage_bytes < 5000::bigint * 1024 * 1024 THEN 'Good'
        WHEN v_storage_bytes < 8000::bigint * 1024 * 1024 THEN 'Consider reviewing retention settings'
        ELSE 'Review retention settings soon'
    END;
    RETURN NEXT;

    -- Collection success rate over the window.
    SELECT
        count(*) FILTER (WHERE outcome NOT IN ('ok', 'skipped_disabled')),
        count(*)
    INTO v_failed_captures, v_total_captures
    FROM pgfr_record.ledger_captures
    WHERE captured_at BETWEEN v_start AND v_now;

    metric := 'Collection Success Rate';
    value := format('%s%% (%s/%s)',
        round(((v_total_captures - v_failed_captures)::numeric / nullif(v_total_captures, 0)) * 100, 1),
        v_total_captures - v_failed_captures, v_total_captures);
    assessment := CASE
        WHEN v_total_captures = 0 THEN 'No collections'
        WHEN v_failed_captures = 0 THEN 'Perfect'
        WHEN (v_failed_captures::numeric / nullif(v_total_captures, 0)) < 0.01 THEN 'Excellent'
        WHEN (v_failed_captures::numeric / nullif(v_total_captures, 0)) < 0.05 THEN 'Good'
        ELSE 'Issues detected -- inspect pgfr_record.ledger_captures for error patterns'
    END;
    RETURN NEXT;

    -- Trend: fast-tier avg duration, first half of window vs second half
    -- (fast is the most frequent tier, so the most data-rich for a split).
    SELECT avg(extract(epoch FROM (finished_at - captured_at)) * 1000) INTO v_older_avg
    FROM pgfr_record.ledger_runs WHERE tier = 'fast' AND captured_at BETWEEN v_start AND v_mid;
    SELECT avg(extract(epoch FROM (finished_at - captured_at)) * 1000) INTO v_recent_avg
    FROM pgfr_record.ledger_runs WHERE tier = 'fast' AND captured_at BETWEEN v_mid AND v_now;

    metric := 'Performance Trend (fast tier)';
    IF v_older_avg IS NULL OR v_recent_avg IS NULL THEN
        value := 'Insufficient data';
        assessment := 'Need more data in this window';
    ELSE
        value := format('%s -> %s ms (%s%s%%)',
            round(v_older_avg::numeric, 1), round(v_recent_avg::numeric, 1),
            CASE WHEN v_recent_avg >= v_older_avg THEN '+' ELSE '' END,
            round(((v_recent_avg - v_older_avg) / nullif(v_older_avg, 0)) * 100, 1));
        assessment := CASE
            WHEN v_recent_avg > v_older_avg * 1.5 THEN 'DEGRADING -- investigate system load'
            WHEN v_recent_avg < v_older_avg * 0.7 THEN 'IMPROVING'
            ELSE 'STABLE'
        END;
    END IF;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.performance_report(interval) IS
    'The recorder''s own performance over p_lookback (default 24 hours): per-tier tick duration (avg and max, from ledger_runs), live storage size, collection success rate (from ledger_captures), and a fast-tier performance trend comparing the window''s first half against its second half. Complements self_overhead() (a fixed set of self-measured figures) and quarterly_review() (a fixed 90-day grade).';
