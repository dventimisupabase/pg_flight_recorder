-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Query-level performance analysis: regression and storm detection, both
-- built on pgfr_record.deltas() over two comparison windows (recent vs. a
-- baseline offset by regression_baseline_days/storm_baseline_days). v1
-- compared per-tick samples and computed a z-score; pgfr_record's deltas()
-- gives one aggregate delta per window rather than a time series, so this
-- compares windowed per-call averages directly against a percent-change
-- threshold instead -- simpler, and well-suited to what's actually
-- available, at the cost of not fitting a distribution.

CREATE OR REPLACE FUNCTION pgfr_analyze.detect_regressions(
    p_lookback      interval DEFAULT NULL,
    p_threshold_pct numeric  DEFAULT NULL
)
RETURNS TABLE(
    queryid              bigint,
    query_fingerprint    text,
    severity              text,
    baseline_avg_ms        numeric,
    current_avg_ms          numeric,
    change_pct              numeric,
    baseline_avg_buffers     numeric,
    current_avg_buffers      numeric,
    buffer_change_pct        numeric,
    detection_metric         text,
    baseline_calls            bigint,
    current_calls             bigint
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lookback      interval := coalesce(p_lookback, pgfr_analyze._get_config('regression_lookback_interval', '1 hour')::interval);
    v_threshold_pct numeric  := coalesce(p_threshold_pct, pgfr_analyze._get_config('regression_threshold_pct', '50.0')::numeric);
    v_baseline_days int      := pgfr_analyze._get_config('regression_baseline_days', '7')::int;
    v_metric        text     := pgfr_analyze._get_config('regression_detection_metric', 'buffers');
    v_low_max       numeric  := pgfr_analyze._get_config('regression_severity_low_max', '200')::numeric;
    v_medium_max    numeric  := pgfr_analyze._get_config('regression_severity_medium_max', '500')::numeric;
    v_high_max      numeric  := pgfr_analyze._get_config('regression_severity_high_max', '1000')::numeric;
    v_col_defs      text := pgfr_analyze._deltas_col_defs('pg_stat_statements');
    v_now           timestamptz := clock_timestamp();
    v_recent_from   timestamptz := v_now - v_lookback;
    v_baseline_to   timestamptz := v_now - (v_baseline_days || ' days')::interval;
    v_baseline_from timestamptz := v_baseline_to - v_lookback;
    v_sql           text;
BEGIN
    IF v_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.detect_regressions: no payload schema minted yet for pg_stat_statements';
    END IF;
    IF v_metric NOT IN ('time', 'buffers') THEN
        RAISE EXCEPTION 'pgfr_analyze.detect_regressions: regression_detection_metric must be ''time'' or ''buffers'', got %', v_metric;
    END IF;

    v_sql := format(
        $q$
        WITH recent AS (
            SELECT queryid, query,
                   calls_delta AS calls,
                   round((total_exec_time_delta / calls_delta)::numeric, 3) AS avg_ms,
                   round((shared_blks_hit_delta + shared_blks_read_delta)::numeric / calls_delta, 3) AS avg_buffers
            FROM pgfr_record.deltas('pg_stat_statements', %L::timestamptz, %L::timestamptz) AS d(%s)
            WHERE calls_delta >= 5
        ),
        baseline AS (
            SELECT queryid,
                   calls_delta AS calls,
                   round((total_exec_time_delta / calls_delta)::numeric, 3) AS avg_ms,
                   round((shared_blks_hit_delta + shared_blks_read_delta)::numeric / calls_delta, 3) AS avg_buffers
            FROM pgfr_record.deltas('pg_stat_statements', %L::timestamptz, %L::timestamptz) AS d(%s)
            WHERE calls_delta >= 5
        ),
        compared AS (
            SELECT
                r.queryid,
                left(r.query, 120) AS query_fingerprint,
                b.avg_ms AS baseline_avg_ms, r.avg_ms AS current_avg_ms,
                CASE WHEN b.avg_ms > 0 THEN round(((r.avg_ms - b.avg_ms) / b.avg_ms * 100)::numeric, 1) END AS ms_change_pct,
                b.avg_buffers AS baseline_avg_buffers, r.avg_buffers AS current_avg_buffers,
                CASE WHEN b.avg_buffers > 0 THEN round(((r.avg_buffers - b.avg_buffers) / b.avg_buffers * 100)::numeric, 1) END AS buf_change_pct,
                b.calls AS baseline_calls, r.calls AS current_calls
            FROM recent r
            JOIN baseline b ON b.queryid = r.queryid
        ),
        chosen AS (
            SELECT *, CASE %L WHEN 'time' THEN ms_change_pct ELSE buf_change_pct END AS change_pct
            FROM compared
        )
        SELECT
            queryid, query_fingerprint,
            CASE
                WHEN change_pct > %L THEN 'CRITICAL'
                WHEN change_pct > %L THEN 'HIGH'
                WHEN change_pct > %L THEN 'MEDIUM'
                ELSE 'LOW'
            END,
            baseline_avg_ms, current_avg_ms, change_pct,
            baseline_avg_buffers, current_avg_buffers, buf_change_pct,
            %L, baseline_calls, current_calls
        FROM chosen
        WHERE change_pct > %L
        ORDER BY change_pct DESC
        $q$,
        v_recent_from, v_now, v_col_defs,
        v_baseline_from, v_baseline_to, v_col_defs,
        v_metric,
        v_high_max, v_medium_max, v_low_max,
        v_metric,
        v_threshold_pct
    );

    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.detect_regressions(interval, numeric) IS
    'Queries whose average execution time or buffer usage per call (per regression_detection_metric) worsened by more than p_threshold_pct between a recent window and a baseline window regression_baseline_days earlier. Requires at least 5 calls in both windows. Severity bands and defaults are tunable via pgfr_analyze.config (regression_lookback_interval, regression_threshold_pct, regression_baseline_days, regression_detection_metric, regression_severity_low/medium/high_max).';

CREATE OR REPLACE FUNCTION pgfr_analyze.detect_query_storms(
    p_lookback             interval DEFAULT NULL,
    p_threshold_multiplier numeric  DEFAULT NULL
)
RETURNS TABLE(
    queryid           bigint,
    query_fingerprint text,
    storm_type        text,
    severity          text,
    recent_calls      bigint,
    baseline_calls    bigint,
    multiplier        numeric
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lookback      interval := coalesce(p_lookback, pgfr_analyze._get_config('storm_lookback_interval', '1 hour')::interval);
    v_threshold     numeric  := coalesce(p_threshold_multiplier, pgfr_analyze._get_config('storm_threshold_multiplier', '3.0')::numeric);
    v_baseline_days int      := pgfr_analyze._get_config('storm_baseline_days', '7')::int;
    v_low_max       numeric  := pgfr_analyze._get_config('storm_severity_low_max', '5.0')::numeric;
    v_medium_max    numeric  := pgfr_analyze._get_config('storm_severity_medium_max', '10.0')::numeric;
    v_high_max      numeric  := pgfr_analyze._get_config('storm_severity_high_max', '50.0')::numeric;
    v_col_defs      text := pgfr_analyze._deltas_col_defs('pg_stat_statements');
    v_now           timestamptz := clock_timestamp();
    v_recent_from   timestamptz := v_now - v_lookback;
    v_baseline_to   timestamptz := v_now - (v_baseline_days || ' days')::interval;
    v_baseline_from timestamptz := v_baseline_to - v_lookback;
    v_sql           text;
BEGIN
    IF v_col_defs IS NULL THEN
        RAISE EXCEPTION 'pgfr_analyze.detect_query_storms: no payload schema minted yet for pg_stat_statements';
    END IF;

    -- CACHE_MISS's 10x cutoff is a fixed constant, not config-driven,
    -- matching v1; the severity bands (low/medium/high_max) remain
    -- tunable via pgfr_analyze.config.
    v_sql := format(
        $q$
        WITH recent AS (
            SELECT queryid, query, calls_delta AS calls
            FROM pgfr_record.deltas('pg_stat_statements', %L::timestamptz, %L::timestamptz) AS d(%s)
            WHERE calls_delta > 0
        ),
        baseline AS (
            SELECT queryid, calls_delta AS calls
            FROM pgfr_record.deltas('pg_stat_statements', %L::timestamptz, %L::timestamptz) AS d(%s)
        ),
        compared AS (
            SELECT
                r.queryid,
                left(r.query, 120) AS query_fingerprint,
                r.calls AS recent_calls,
                coalesce(b.calls, 0) AS baseline_calls,
                CASE WHEN coalesce(b.calls, 0) > 0 THEN round(r.calls::numeric / b.calls, 2) END AS multiplier
            FROM recent r
            LEFT JOIN baseline b ON b.queryid = r.queryid
        )
        SELECT
            queryid, query_fingerprint,
            CASE
                WHEN query_fingerprint ~* '(retry|for update)' THEN 'RETRY_STORM'
                WHEN baseline_calls = 0 THEN 'CACHE_MISS'
                WHEN multiplier > 10.0 THEN 'CACHE_MISS'
                WHEN multiplier > %L THEN 'SPIKE'
                ELSE 'NORMAL'
            END,
            CASE
                WHEN query_fingerprint ~* '(retry|for update)' THEN 'CRITICAL'
                WHEN baseline_calls = 0 THEN 'CRITICAL'
                WHEN multiplier > %L THEN 'CRITICAL'
                WHEN multiplier > %L THEN 'HIGH'
                WHEN multiplier > %L THEN 'MEDIUM'
                ELSE 'LOW'
            END,
            recent_calls, baseline_calls, multiplier
        FROM compared
        WHERE query_fingerprint ~* '(retry|for update)'
           OR baseline_calls = 0
           OR multiplier > %L
        ORDER BY coalesce(multiplier, 999999) DESC
        $q$,
        v_recent_from, v_now, v_col_defs,
        v_baseline_from, v_baseline_to, v_col_defs,
        v_threshold,
        v_high_max, v_medium_max, v_low_max,
        v_threshold
    );

    RETURN QUERY EXECUTE v_sql;
END;
$$;

COMMENT ON FUNCTION pgfr_analyze.detect_query_storms(interval, numeric) IS
    'Queries whose call rate in a recent window exceeds a baseline window (storm_baseline_days earlier) by more than p_threshold_multiplier, classified RETRY_STORM (query text matches retry/for-update patterns, always CRITICAL), CACHE_MISS (no baseline calls, or over 10x baseline), SPIKE (over the threshold multiplier), else omitted. Severity bands and defaults are tunable via pgfr_analyze.config (storm_lookback_interval, storm_threshold_multiplier, storm_baseline_days, storm_severity_low/medium/high_max).';
