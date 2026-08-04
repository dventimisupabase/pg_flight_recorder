-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

CREATE OR REPLACE FUNCTION pgfr_analyze.activity_at(p_timestamp TIMESTAMPTZ)
RETURNS TABLE(
    sample_captured_at      TIMESTAMPTZ,
    sample_offset_seconds   NUMERIC,
    active_sessions         INTEGER,
    waiting_sessions        INTEGER,
    idle_in_transaction     INTEGER,
    top_wait_event_1        TEXT,
    top_wait_count_1        INTEGER,
    top_wait_event_2        TEXT,
    top_wait_count_2        INTEGER,
    top_wait_event_3        TEXT,
    top_wait_count_3        INTEGER,
    blocked_pids            INTEGER,
    longest_blocked_duration INTERVAL,
    vacuums_running         INTEGER,
    copies_running          INTEGER,
    indexes_building        INTEGER,
    analyzes_running        INTEGER,
    snapshot_captured_at    TIMESTAMPTZ,
    snapshot_offset_seconds NUMERIC,
    autovacuum_workers      INTEGER,
    checkpoint_occurred     BOOLEAN
)
LANGUAGE sql STABLE AS $$
    WITH
    -- find nearest sample_ts from v2 ring (legacy fallback retired)
    nearest_sample AS (
        SELECT pgfr_record.epoch() + sample_ts * interval '1 second' AS captured_at,
               abs(extract(epoch FROM (
                   pgfr_record.epoch() + sample_ts * interval '1 second' - p_timestamp
               ))) AS offset_secs,
               sample_ts
        FROM pgfr_record.activity_samples
        ORDER BY offset_secs
        LIMIT 1
    ),
    nearest_snapshot AS (
        SELECT s.id, s.captured_at, s.autovacuum_workers,
               (s.checkpoint_time IS DISTINCT FROM prev.checkpoint_time) AS checkpoint_occurred,
               ABS(EXTRACT(EPOCH FROM (s.captured_at - p_timestamp))) AS offset_secs
        FROM pgfr_record.snapshots s
        LEFT JOIN pgfr_record.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM pgfr_record.snapshots WHERE id < s.id
        )
        ORDER BY ABS(EXTRACT(EPOCH FROM (s.captured_at - p_timestamp)))
        LIMIT 1
    ),
    sample_waits AS (
        SELECT wem.type || ':' || wem.event AS wait_event,
               abs(ws.data[i + 1]) AS count
        FROM pgfr_record.wait_samples ws
        CROSS JOIN nearest_sample ns
        CROSS JOIN generate_subscripts(ws.data, 1) AS i
        JOIN pgfr_record.wait_event_map wem ON wem.id = abs(ws.data[i])::smallint
        WHERE ws.data[i] < 0
          AND ws.sample_ts = ns.sample_ts
          AND wem.state NOT IN ('idle', 'idle in transaction')
    ),
    wait_ranked AS (
        SELECT wait_event, sum(count) AS count
        FROM sample_waits
        GROUP BY wait_event
        ORDER BY count DESC
        LIMIT 3
    ),
    wait_array AS (
        SELECT array_agg(wait_event ORDER BY count DESC) AS events,
               array_agg(count ORDER BY count DESC) AS counts
        FROM wait_ranked
    ),
    sample_activity AS (
        SELECT
            count(*) FILTER (WHERE a.state = 'active') AS active_sessions,
            count(*) FILTER (WHERE a.wait_event IS NOT NULL) AS waiting_sessions,
            count(*) FILTER (WHERE a.state = 'idle in transaction') AS idle_in_transaction
        FROM pgfr_record.activity_samples a
        JOIN nearest_sample ns ON a.sample_ts = ns.sample_ts
    ),
    sample_locks AS (
        SELECT
            count(DISTINCT ls.blocked_pid) AS blocked_pids,
            max(ls.blocked_duration_s * interval '1 second') AS longest_blocked
        FROM pgfr_record.lock_samples ls
        JOIN nearest_sample ns ON ls.sample_ts = ns.sample_ts
    ),
    sample_progress AS (
        SELECT 0 AS vacuums, 0 AS copies, 0 AS indexes, 0 AS analyzes
    )
    SELECT
        ns.captured_at,
        ns.offset_secs::numeric,
        COALESCE(sa.active_sessions, 0)::integer,
        COALESCE(sa.waiting_sessions, 0)::integer,
        COALESCE(sa.idle_in_transaction, 0)::integer,
        wa.events[1],
        wa.counts[1]::integer,
        wa.events[2],
        wa.counts[2]::integer,
        wa.events[3],
        wa.counts[3]::integer,
        COALESCE(sl.blocked_pids, 0)::integer,
        sl.longest_blocked,
        COALESCE(sp.vacuums, 0)::integer,
        COALESCE(sp.copies, 0)::integer,
        COALESCE(sp.indexes, 0)::integer,
        COALESCE(sp.analyzes, 0)::integer,
        sn.captured_at,
        sn.offset_secs::numeric,
        sn.autovacuum_workers,
        sn.checkpoint_occurred
    FROM nearest_sample ns
    CROSS JOIN nearest_snapshot sn
    CROSS JOIN sample_activity sa
    CROSS JOIN sample_locks sl
    CROSS JOIN sample_progress sp
    CROSS JOIN wait_array wa
$$;
COMMENT ON FUNCTION pgfr_analyze.activity_at(TIMESTAMPTZ) IS 'Retrieves active session details at a specific point in time.

Output columns:
  sample_captured_at: [dimension] [timestamp] Capture time of the ring sample tick nearest to the requested time; all sample-derived columns describe this tick, not the requested instant.
  sample_offset_seconds: [derived] [seconds] Absolute gap between the requested time and sample_captured_at, computed from the two timestamps; large values mean the sample columns describe a different moment than requested.
  active_sessions: [point-sample] [count] Sessions observed in state active in activity_samples at the nearest sample tick, not at the requested instant; a point-in-time reading with no claim about activity between ticks.
  waiting_sessions: [point-sample] [count] Sessions with a non-null wait_event in activity_samples at the nearest sample tick, not at the requested instant.
  idle_in_transaction: [point-sample] [count] Sessions in state idle in transaction in activity_samples at the nearest sample tick, not at the requested instant.
  top_wait_event_1: [dimension] [text] Label (type:event, decoded via wait_event_map) of the non-idle wait event with the most waiters at the nearest sample tick; NULL if no non-idle waits were observed.
  top_wait_count_1: [point-sample] [count] Backends observed waiting on top_wait_event_1 at the nearest sample tick; measures occupancy at that instant, never event frequency.
  top_wait_event_2: [dimension] [text] Label (type:event) of the second-ranked non-idle wait event at the nearest sample tick; NULL if fewer than two distinct waits were observed.
  top_wait_count_2: [point-sample] [count] Backends observed waiting on top_wait_event_2 at the nearest sample tick; occupancy at that instant, never event frequency.
  top_wait_event_3: [dimension] [text] Label (type:event) of the third-ranked non-idle wait event at the nearest sample tick; NULL if fewer than three distinct waits were observed.
  top_wait_count_3: [point-sample] [count] Backends observed waiting on top_wait_event_3 at the nearest sample tick; occupancy at that instant, never event frequency.
  blocked_pids: [point-sample] [count] Distinct blocked pids in lock_samples at the nearest sample tick, not at the requested instant; 0 when no blocking was observed at that tick.
  longest_blocked_duration: [point-sample] [duration] Largest blocked_duration_s among lock_samples rows at the nearest sample tick, that is how long the longest-blocked session had been blocked as of the sample instant; NULL when no blocking was observed.
  vacuums_running: [point-sample] [count] Placeholder: command-progress sampling is not collected in the v2 ring, so this is always 0.
  copies_running: [point-sample] [count] Placeholder: command-progress sampling is not collected in the v2 ring, so this is always 0.
  indexes_building: [point-sample] [count] Placeholder: command-progress sampling is not collected in the v2 ring, so this is always 0.
  analyzes_running: [point-sample] [count] Placeholder: command-progress sampling is not collected in the v2 ring, so this is always 0.
  snapshot_captured_at: [dimension] [timestamp] Capture time of the snapshot nearest to the requested time; the snapshot-derived columns describe this snapshot, not the requested instant.
  snapshot_offset_seconds: [derived] [seconds] Absolute gap between the requested time and snapshot_captured_at, computed from the two timestamps.
  autovacuum_workers: [gauge] [count] Autovacuum workers running at the nearest snapshot instant, not at the requested time; exact at that instant, undefined between snapshots.
  checkpoint_occurred: [derived] [boolean] True when checkpoint_time differs between the nearest snapshot and its immediate predecessor, meaning a checkpoint completed somewhere in the interval between those two snapshots.';

-- Detects query storms by comparing recent query execution counts to baseline
-- Issue #102: detect_query_storms() gained sample-count columns, which
-- changes its return type; CREATE OR REPLACE cannot do that.
do $$
begin
    set local client_min_messages = warning;
    drop function if exists pgfr_analyze.detect_query_storms(interval, numeric);
end $$;

CREATE OR REPLACE FUNCTION pgfr_analyze.detect_query_storms(
    p_lookback INTERVAL DEFAULT NULL,
    p_threshold_multiplier NUMERIC DEFAULT NULL
)
RETURNS TABLE(
    queryid BIGINT,
    query_fingerprint TEXT,
    storm_type TEXT,
    severity TEXT,
    recent_count BIGINT,
    baseline_count BIGINT,
    multiplier NUMERIC,
    recent_samples INTEGER,
    baseline_samples INTEGER
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lookback INTERVAL;
    v_threshold NUMERIC;
    v_baseline_days INTEGER;
    v_low_max NUMERIC;
    v_medium_max NUMERIC;
    v_high_max NUMERIC;
BEGIN
    -- Get configuration with defaults
    v_lookback := COALESCE(
        p_lookback,
        pgfr_record._get_config('storm_lookback_interval', '1 hour')::interval
    );
    v_threshold := COALESCE(
        p_threshold_multiplier,
        pgfr_record._get_config('storm_threshold_multiplier', '3.0')::numeric
    );
    v_baseline_days := COALESCE(
        pgfr_record._get_config('storm_baseline_days', '7')::integer,
        7
    );

    -- Get severity thresholds
    v_low_max := pgfr_record._get_config('storm_severity_low_max', '5.0')::numeric;
    v_medium_max := pgfr_record._get_config('storm_severity_medium_max', '10.0')::numeric;
    v_high_max := pgfr_record._get_config('storm_severity_high_max', '50.0')::numeric;

    RETURN QUERY
    WITH recent_stats AS (
        -- Recent query call deltas from statement_snapshots. Both the
        -- per-tick average (the rate the multiplier compares) and the window
        -- total (reported as recent_count) are computed; comparing the
        -- window SUM against the baseline per-tick AVG, as this function did
        -- before Issue #102, inflated the multiplier by roughly the number
        -- of ticks in the lookback window (~60x at default cadence).
        SELECT
            ss.queryid,
            left(ss.query_preview, 100) AS query_preview,
            SUM(COALESCE(ss.calls_delta, 0)) AS total_calls,
            AVG(COALESCE(ss.calls_delta, 0)) AS avg_calls,
            COUNT(*) AS n_samples
        FROM pgfr_record.statement_snapshots ss
        JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at >= now() - v_lookback
        GROUP BY ss.queryid, left(ss.query_preview, 100)
    ),
    baseline_stats AS (
        -- Baseline query call deltas (over baseline period, excluding recent)
        SELECT
            ss.queryid,
            AVG(COALESCE(ss.calls_delta, 0)) AS avg_calls,
            COUNT(*) AS n_samples,
            COUNT(DISTINCT date_trunc('day', s.captured_at)) AS days_sampled
        FROM pgfr_record.statement_snapshots ss
        JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at >= now() - (v_baseline_days || ' days')::interval
          AND s.captured_at < now() - v_lookback
        GROUP BY ss.queryid
        HAVING COUNT(DISTINCT date_trunc('day', s.captured_at)) >= 2  -- Need at least 2 days of baseline
    ),
    storms AS (
        SELECT
            r.queryid,
            r.query_preview AS query_fingerprint,
            CASE
                WHEN r.query_preview ILIKE '%RETRY%' OR r.query_preview ILIKE '%FOR UPDATE%'
                    THEN 'RETRY_STORM'
                WHEN r.avg_calls > COALESCE(b.avg_calls, 0) * 10
                    THEN 'CACHE_MISS'
                WHEN r.avg_calls > COALESCE(b.avg_calls, 1) * v_threshold
                    THEN 'SPIKE'
                ELSE 'NORMAL'
            END AS storm_type,
            r.total_calls::BIGINT AS recent_count,
            COALESCE(b.avg_calls, 0)::BIGINT AS baseline_count,
            CASE
                WHEN COALESCE(b.avg_calls, 0) > 0
                THEN ROUND(r.avg_calls::numeric / b.avg_calls, 2)
                ELSE NULL
            END AS multiplier,
            r.n_samples::INTEGER AS recent_samples,
            COALESCE(b.n_samples, 0)::INTEGER AS baseline_samples
        FROM recent_stats r
        LEFT JOIN baseline_stats b ON b.queryid = r.queryid
        WHERE r.avg_calls > COALESCE(b.avg_calls, 1) * v_threshold
           OR (r.query_preview ILIKE '%RETRY%' OR r.query_preview ILIKE '%FOR UPDATE%')
    )
    SELECT
        st.queryid,
        st.query_fingerprint,
        st.storm_type,
        CASE
            WHEN st.storm_type = 'RETRY_STORM' THEN 'CRITICAL'
            WHEN st.multiplier > v_high_max THEN 'CRITICAL'
            WHEN st.multiplier > v_medium_max THEN 'HIGH'
            WHEN st.multiplier > v_low_max THEN 'MEDIUM'
            ELSE 'LOW'
        END AS severity,
        st.recent_count,
        st.baseline_count,
        st.multiplier,
        st.recent_samples,
        st.baseline_samples
    FROM storms st
    ORDER BY
        CASE
            WHEN st.storm_type = 'RETRY_STORM' THEN 1
            WHEN st.multiplier > v_high_max THEN 2
            WHEN st.multiplier > v_medium_max THEN 3
            WHEN st.multiplier > v_low_max THEN 4
            ELSE 5
        END,
        st.recent_count DESC;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.detect_query_storms(INTERVAL, NUMERIC) IS 'Detect query storms by comparing recent execution counts to baseline. Classifies as RETRY_STORM, CACHE_MISS, SPIKE, or NORMAL with severity levels (LOW, MEDIUM, HIGH, CRITICAL).

Output columns:
  queryid: [dimension] [bigint] pg_stat_statements query identifier, as recorded in statement_snapshots.
  query_fingerprint: [dimension] [text] First 100 characters of the recorded query_preview for this queryid.
  storm_type: [derived] [text] Classification (RETRY_STORM, CACHE_MISS, SPIKE, NORMAL) computed from query text patterns (RETRY, FOR UPDATE) and the ratio of the recent per-snapshot average of calls_delta to the baseline per-snapshot average (like units on both sides).
  severity: [derived] [text] LOW, MEDIUM, HIGH, or CRITICAL, from multiplier against the storm_severity_* config thresholds; RETRY_STORM is always CRITICAL.
  recent_count: [counter-delta] [count] Sum of per-snapshot calls_delta over the recent window (p_lookback, default 1 hour): the exact number of executions recorded in that window, modulo counter resets.
  baseline_count: [counter-delta] [count] Average calls_delta per snapshot over the baseline period (storm_baseline_days, default 7 days, excluding the recent window; at least 2 distinct days required), truncated to bigint; 0 when no baseline exists.
  multiplier: [derived] [ratio] Dimensionless ratio of the recent per-snapshot average of calls_delta (numerator, over recent_samples snapshots) to the baseline per-snapshot average (denominator, over baseline_samples snapshots); NULL when the baseline average is zero or missing. Like units on both sides (Issue #102 fixed the earlier window-total vs per-snapshot asymmetry, which inflated this by roughly the tick count of the lookback window).
  recent_samples: [derived] [count] Number of statement snapshots behind the recent window''s average: the denominator disclosure for the multiplier''s numerator.
  baseline_samples: [derived] [count] Number of statement snapshots behind the baseline average; 0 when no baseline exists. The denominator disclosure for the multiplier''s denominator.';

-- Diagnose probable causes for a query's performance regression
CREATE OR REPLACE FUNCTION pgfr_analyze._diagnose_regression_causes(
    p_queryid BIGINT
)
RETURNS TEXT[]
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_causes TEXT[] := ARRAY[]::TEXT[];
    v_stats RECORD;
    v_recent_snapshot RECORD;
BEGIN
    -- Get current stats from pg_stat_statements
    BEGIN
        SELECT
            temp_blks_written,
            shared_blks_hit,
            shared_blks_read,
            rows
        INTO v_stats
        FROM pg_stat_statements
        WHERE queryid = p_queryid
        LIMIT 1;
    EXCEPTION
        WHEN undefined_table THEN
            v_stats := NULL;
    END;

    IF v_stats IS NOT NULL THEN
        -- Check for temp file spills
        IF COALESCE(v_stats.temp_blks_written, 0) > 0 THEN
            v_causes := array_append(v_causes, 'Query is spilling to disk (temp files) - consider increasing work_mem');
        END IF;

        -- Check cache hit ratio
        IF v_stats.shared_blks_hit IS NOT NULL AND v_stats.shared_blks_read IS NOT NULL THEN
            IF v_stats.shared_blks_hit + v_stats.shared_blks_read > 0 THEN
                IF v_stats.shared_blks_hit::numeric / (v_stats.shared_blks_hit + v_stats.shared_blks_read) < 0.9 THEN
                    v_causes := array_append(v_causes, 'Low cache hit ratio - check shared_buffers or index usage');
                END IF;
            END IF;
        END IF;
    END IF;

    -- Check for recent checkpoint activity
    SELECT
        checkpoint_time,
        ckpt_write_time,
        ckpt_sync_time
    INTO v_recent_snapshot
    FROM pgfr_record.snapshots
    WHERE captured_at >= now() - interval '1 hour'
    ORDER BY captured_at DESC
    LIMIT 1;

    IF v_recent_snapshot IS NOT NULL THEN
        IF v_recent_snapshot.checkpoint_time >= now() - interval '5 minutes' THEN
            v_causes := array_append(v_causes, 'Recent checkpoint activity may be affecting I/O');
        END IF;
    END IF;

    -- Default causes if nothing specific found
    IF array_length(v_causes, 1) IS NULL THEN
        v_causes := array_append(v_causes, 'Statistics may be out of date - consider ANALYZE on involved tables');
        v_causes := array_append(v_causes, 'Query plan may have changed - check with EXPLAIN');
    END IF;

    RETURN v_causes;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze._diagnose_regression_causes(BIGINT) IS 'Internal: Analyze a query to suggest probable causes for performance regression.';

-- Issue #102: detect_regressions() gained z_score and sample-count columns,
-- which changes its return type; CREATE OR REPLACE cannot do that.
do $$
begin
    set local client_min_messages = warning;
    drop function if exists pgfr_analyze.detect_regressions(interval, numeric);
end $$;

-- Detects performance regressions by comparing recent query metrics to baseline
CREATE OR REPLACE FUNCTION pgfr_analyze.detect_regressions(
    p_lookback INTERVAL DEFAULT NULL,
    p_threshold_pct NUMERIC DEFAULT NULL
)
RETURNS TABLE(
    queryid BIGINT,
    query_fingerprint TEXT,
    severity TEXT,
    baseline_avg_ms NUMERIC,
    current_avg_ms NUMERIC,
    change_pct NUMERIC,
    baseline_avg_buffers NUMERIC,
    current_avg_buffers NUMERIC,
    buffer_change_pct NUMERIC,
    detection_metric TEXT,
    probable_causes TEXT[],
    z_score NUMERIC,
    baseline_samples INTEGER,
    current_samples INTEGER
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lookback INTERVAL;
    v_threshold_pct NUMERIC;
    v_baseline_days INTEGER;
    v_low_max NUMERIC;
    v_medium_max NUMERIC;
    v_high_max NUMERIC;
    v_detection_metric TEXT;
BEGIN
    -- Get configuration with defaults
    v_lookback := COALESCE(
        p_lookback,
        pgfr_record._get_config('regression_lookback_interval', '1 hour')::interval
    );
    v_threshold_pct := COALESCE(
        p_threshold_pct,
        pgfr_record._get_config('regression_threshold_pct', '50.0')::numeric
    );
    v_baseline_days := COALESCE(
        pgfr_record._get_config('regression_baseline_days', '7')::integer,
        7
    );

    -- Get severity thresholds (percentage-based)
    v_low_max := pgfr_record._get_config('regression_severity_low_max', '200.0')::numeric;
    v_medium_max := pgfr_record._get_config('regression_severity_medium_max', '500.0')::numeric;
    v_high_max := pgfr_record._get_config('regression_severity_high_max', '1000.0')::numeric;

    -- Get detection metric (default to buffers)
    v_detection_metric := pgfr_record._get_config('regression_detection_metric', 'buffers');

    RETURN QUERY
    WITH recent_stats AS (
        -- Recent query metrics from statement_snapshots
        SELECT
            ss.queryid,
            left(ss.query_preview, 100) AS query_preview,
            AVG(ss.mean_exec_time) AS avg_mean_time,
            STDDEV(ss.mean_exec_time) AS stddev_mean_time,
            AVG(COALESCE(ss.shared_blks_hit_delta, 0) + COALESCE(ss.shared_blks_read_delta, 0)
                + COALESCE(ss.temp_blks_read_delta, 0)) AS avg_total_buffers,
            STDDEV(COALESCE(ss.shared_blks_hit_delta, 0) + COALESCE(ss.shared_blks_read_delta, 0)
                + COALESCE(ss.temp_blks_read_delta, 0)) AS stddev_total_buffers,
            COUNT(*) AS sample_count
        FROM pgfr_record.statement_snapshots ss
        JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at >= now() - v_lookback
          AND ss.mean_exec_time IS NOT NULL
          AND ss.mean_exec_time > 0
        GROUP BY ss.queryid, left(ss.query_preview, 100)
    ),
    baseline_stats AS (
        -- Baseline query metrics (over baseline period, excluding recent)
        SELECT
            ss.queryid,
            AVG(ss.mean_exec_time) AS avg_mean_time,
            STDDEV(ss.mean_exec_time) AS stddev_mean_time,
            AVG(COALESCE(ss.shared_blks_hit_delta, 0) + COALESCE(ss.shared_blks_read_delta, 0)
                + COALESCE(ss.temp_blks_read_delta, 0)) AS avg_total_buffers,
            STDDEV(COALESCE(ss.shared_blks_hit_delta, 0) + COALESCE(ss.shared_blks_read_delta, 0)
                + COALESCE(ss.temp_blks_read_delta, 0)) AS stddev_total_buffers,
            COUNT(*) AS sample_count,
            COUNT(DISTINCT date_trunc('day', s.captured_at)) AS days_sampled
        FROM pgfr_record.statement_snapshots ss
        JOIN pgfr_record.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at >= now() - (v_baseline_days || ' days')::interval
          AND s.captured_at < now() - v_lookback
          AND ss.mean_exec_time IS NOT NULL
          AND ss.mean_exec_time > 0
        GROUP BY ss.queryid
        HAVING COUNT(DISTINCT date_trunc('day', s.captured_at)) >= 2  -- Need at least 2 days of baseline
    ),
    regressions AS (
        SELECT
            r.queryid,
            r.query_preview AS query_fingerprint,
            -- Timing metrics
            b.avg_mean_time::numeric AS baseline_avg_ms,
            r.avg_mean_time::numeric AS current_avg_ms,
            ROUND(((r.avg_mean_time - b.avg_mean_time) / NULLIF(b.avg_mean_time, 0))::numeric * 100, 2) AS time_change_pct,
            -- Buffer metrics
            b.avg_total_buffers::numeric AS baseline_avg_buffers,
            r.avg_total_buffers::numeric AS current_avg_buffers,
            ROUND(((r.avg_total_buffers - b.avg_total_buffers) / NULLIF(b.avg_total_buffers, 0))::numeric * 100, 2) AS buffer_change_pct,
            -- Z-score for statistical significance (based on detection
            -- metric). NULL, not 0, when the baseline dispersion is
            -- unavailable: "no dispersion information" is a different fact
            -- from "exactly at the baseline mean" (Issue #102).
            CASE
                WHEN v_detection_metric = 'time' THEN
                    CASE
                        WHEN COALESCE(b.stddev_mean_time, 0) > 0
                        THEN (r.avg_mean_time - b.avg_mean_time) / b.stddev_mean_time
                        ELSE NULL
                    END
                ELSE
                    CASE
                        WHEN COALESCE(b.stddev_total_buffers, 0) > 0
                        THEN (r.avg_total_buffers - b.avg_total_buffers) / b.stddev_total_buffers
                        ELSE NULL
                    END
            END AS z_score,
            r.sample_count AS current_samples,
            b.sample_count AS baseline_samples,
            -- Change percentage based on detection metric
            CASE
                WHEN v_detection_metric = 'time' THEN
                    ROUND(((r.avg_mean_time - b.avg_mean_time) / NULLIF(b.avg_mean_time, 0))::numeric * 100, 2)
                ELSE
                    ROUND(((r.avg_total_buffers - b.avg_total_buffers) / NULLIF(b.avg_total_buffers, 0))::numeric * 100, 2)
            END AS primary_change_pct
        FROM recent_stats r
        JOIN baseline_stats b ON b.queryid = r.queryid
        WHERE r.sample_count >= 2  -- Need multiple samples to be confident
          AND CASE
              WHEN v_detection_metric = 'time' THEN
                  r.avg_mean_time > b.avg_mean_time * (1 + v_threshold_pct / 100)
              ELSE
                  COALESCE(r.avg_total_buffers, 0) > COALESCE(b.avg_total_buffers, 0) * (1 + v_threshold_pct / 100)
                  AND b.avg_total_buffers IS NOT NULL AND b.avg_total_buffers > 0
          END
    )
    SELECT
        reg.queryid,
        reg.query_fingerprint,
        CASE
            WHEN reg.primary_change_pct > v_high_max THEN 'CRITICAL'
            WHEN reg.primary_change_pct > v_medium_max THEN 'HIGH'
            WHEN reg.primary_change_pct > v_low_max THEN 'MEDIUM'
            ELSE 'LOW'
        END AS severity,
        ROUND(reg.baseline_avg_ms, 2) AS baseline_avg_ms,
        ROUND(reg.current_avg_ms, 2) AS current_avg_ms,
        reg.time_change_pct AS change_pct,
        ROUND(reg.baseline_avg_buffers, 0) AS baseline_avg_buffers,
        ROUND(reg.current_avg_buffers, 0) AS current_avg_buffers,
        reg.buffer_change_pct,
        v_detection_metric AS detection_metric,
        pgfr_analyze._diagnose_regression_causes(reg.queryid) AS probable_causes,
        ROUND(reg.z_score::numeric, 2) AS z_score,
        reg.baseline_samples::INTEGER AS baseline_samples,
        reg.current_samples::INTEGER AS current_samples
    FROM regressions reg
    WHERE reg.z_score > 2 OR reg.primary_change_pct > v_medium_max  -- Statistical filter or significant change
    ORDER BY
        CASE
            WHEN reg.primary_change_pct > v_high_max THEN 1
            WHEN reg.primary_change_pct > v_medium_max THEN 2
            WHEN reg.primary_change_pct > v_low_max THEN 3
            ELSE 4
        END,
        reg.primary_change_pct DESC;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.detect_regressions(INTERVAL, NUMERIC) IS 'Detect performance regressions using buffer metrics (default) or timing. Classifies severity based on percentage change (LOW <200%, MEDIUM <500%, HIGH <1000%, CRITICAL >1000%). Configure via regression_detection_metric.

Output columns:
  queryid: [dimension] [bigint] pg_stat_statements query identifier, as recorded in statement_snapshots.
  query_fingerprint: [dimension] [text] First 100 characters of the recorded query_preview for this queryid.
  severity: [derived] [text] LOW, MEDIUM, HIGH, or CRITICAL, from the change percentage of the configured detection metric against the regression_severity_* config thresholds.
  baseline_avg_ms: [derived] [milliseconds] Average of per-snapshot mean_exec_time for this queryid over the baseline period (regression_baseline_days, default 7 days, excluding the recent window; at least 2 distinct days required), rounded to 2 decimals.
  current_avg_ms: [derived] [milliseconds] Average of per-snapshot mean_exec_time for this queryid over the recent window (p_lookback, default 1 hour), rounded to 2 decimals.
  change_pct: [derived] [percent] Timing change: (current_avg_ms minus baseline_avg_ms) as a percentage of baseline_avg_ms (the denominator); NULL when the baseline average is zero.
  baseline_avg_buffers: [derived] [blocks] Average per-snapshot total buffer traffic (shared_blks_hit_delta plus shared_blks_read_delta plus temp_blks_read_delta) over the baseline period, rounded to whole blocks; an average of exact counter deltas.
  current_avg_buffers: [derived] [blocks] Average per-snapshot total buffer traffic (same three deltas) over the recent window, rounded to whole blocks.
  buffer_change_pct: [derived] [percent] Buffer change: (current_avg_buffers minus baseline_avg_buffers) as a percentage of baseline_avg_buffers (the denominator); NULL when the baseline average is zero.
  detection_metric: [dimension] [text] Name of the metric that drove detection and severity: the regression_detection_metric config value, buffers (default) or time.
  probable_causes: [derived] [text] Array of heuristic diagnostic strings from _diagnose_regression_causes: live pg_stat_statements temp spills and cache hit ratio, recent checkpoint activity from snapshots, or generic advice when nothing specific is found.
  z_score: [derived] [ratio] Effect size of the detected change: (recent average minus baseline average) of the detection metric, divided by the baseline standard deviation over baseline_samples snapshots. NULL when the baseline dispersion is unavailable (fewer than 2 distinct values), which is different from 0 (exactly at the baseline mean). Rows pass the internal filter when z_score exceeds 2 or the change percentage exceeds regression_severity_medium_max.
  baseline_samples: [derived] [count] Number of statement snapshots behind the baseline averages and standard deviation: the sample-size disclosure for the baseline side.
  current_samples: [derived] [count] Number of statement snapshots behind the recent-window averages (at least 2 by construction): the sample-size disclosure for the current side.';
-- Generates a health report of flight recorder operations, including collection performance metrics,
-- success rates, and schema size with qualitative assessments
