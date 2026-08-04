-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- Issue #111: capacity_summary() gained numeric_value, which changes its
-- return type; CREATE OR REPLACE cannot do that, and capacity_dashboard
-- depends on the function, so the view drops first (both are recreated
-- below in this file, comments included).
do $$
begin
    set local client_min_messages = warning;
    drop view if exists pgfr_analyze.capacity_dashboard;
    drop function if exists pgfr_analyze.capacity_summary(interval);
end $$;

CREATE OR REPLACE FUNCTION pgfr_analyze.capacity_summary(
    p_time_window INTERVAL DEFAULT interval '24 hours'
)
RETURNS TABLE(
    metric                  TEXT,
    current_usage           TEXT,
    provisioned_capacity    TEXT,
    utilization_pct         NUMERIC,
    headroom_pct            NUMERIC,
    status                  TEXT,
    recommendation          TEXT,
    numeric_value           NUMERIC  -- the row's primary figure, machine-readable (Issue #111)
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_warning_pct INTEGER;
    v_critical_pct INTEGER;
    v_window_start TIMESTAMPTZ;
    v_current_connections INTEGER;
    v_max_connections INTEGER;
    v_avg_connections NUMERIC;
    v_peak_connections INTEGER;
    v_bgw_backend_total BIGINT;
    v_bgw_backend_avg_per_min NUMERIC;
    v_shared_buffers_setting TEXT;
    v_temp_bytes_total BIGINT;
    v_temp_bytes_per_hour NUMERIC;
    v_blks_read_total BIGINT;
    v_blks_hit_total BIGINT;
    v_cache_hit_ratio NUMERIC;
    v_current_db_size BIGINT;
    v_oldest_db_size BIGINT;
    v_storage_growth_mb_per_day NUMERIC;
    v_xact_total BIGINT;
    v_xact_rate_avg NUMERIC;
    v_xact_rate_peak NUMERIC;
    v_window_hours NUMERIC;
    v_sample_count INTEGER;
BEGIN
    v_warning_pct := COALESCE(
        pgfr_record._get_config('capacity_thresholds_warning_pct', '60')::integer,
        60
    );
    v_critical_pct := COALESCE(
        pgfr_record._get_config('capacity_thresholds_critical_pct', '80')::integer,
        80
    );
    v_window_start := now() - p_time_window;
    v_window_hours := EXTRACT(EPOCH FROM p_time_window) / 3600.0;
    SELECT count(*) INTO v_sample_count
    FROM pgfr_record.snapshots
    WHERE captured_at >= v_window_start;
    IF v_sample_count < 2 THEN
        RETURN QUERY SELECT
            'insufficient_data'::text,
            NULL::text,
            NULL::text,
            NULL::numeric,
            NULL::numeric,
            'insufficient_data'::text,
            format('Need at least 2 snapshots. Only %s found in window. Wait %s for capacity analysis.',
                   v_sample_count,
                   CASE WHEN v_sample_count = 0 THEN '5 minutes' ELSE 'a few more minutes' END)::text,
            NULL::numeric;
        RETURN;
    END IF;
    SELECT setting::integer INTO v_max_connections
    FROM pg_settings WHERE name = 'max_connections';
    SELECT COALESCE(connections_total, 0)
    INTO v_current_connections
    FROM pgfr_record.snapshots
    WHERE captured_at >= v_window_start
      AND connections_total IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;
    SELECT
        COALESCE(round(avg(connections_total), 0), 0),
        COALESCE(max(connections_total), 0)
    INTO v_avg_connections, v_peak_connections
    FROM pgfr_record.snapshots
    WHERE captured_at >= v_window_start
      AND connections_total IS NOT NULL;
    IF v_current_connections IS NOT NULL THEN
        metric := 'connections';
        current_usage := format('%s current / %s avg / %s peak',
                               v_current_connections,
                               v_avg_connections::integer,
                               v_peak_connections);
        provisioned_capacity := v_max_connections::text;
        utilization_pct := LEAST(100, round((v_peak_connections::numeric / NULLIF(v_max_connections, 0)) * 100, 1));
        headroom_pct := CASE WHEN utilization_pct IS NOT NULL THEN round(GREATEST(0, 100 - utilization_pct), 1) ELSE NULL END;
        status := CASE
            WHEN utilization_pct >= v_critical_pct THEN 'critical'
            WHEN utilization_pct >= v_warning_pct THEN 'warning'
            ELSE 'healthy'
        END;
        recommendation := CASE
            WHEN utilization_pct >= v_critical_pct THEN
                format('CRITICAL: Peak connections at %s%%. Increase max_connections to %s+ or implement connection pooling (PgBouncer)',
                       utilization_pct, (v_peak_connections * 1.5)::integer)
            WHEN utilization_pct >= v_warning_pct THEN
                format('WARNING: Peak connections at %s%%. Monitor closely. Consider connection pooling if trend continues.',
                       utilization_pct)
            WHEN utilization_pct < 40 THEN
                format('HEALTHY: Peak usage %s%% (%s connections). max_connections may be over-provisioned (potential cost savings).',
                       utilization_pct, v_peak_connections)
            ELSE
                format('HEALTHY: Peak usage %s%% with %s%% headroom. No action needed.',
                       utilization_pct, headroom_pct)
        END;
        RETURN NEXT;
    END IF;
    WITH buffer_deltas AS (
        SELECT
            s.captured_at,
            s.bgw_buffers_backend - prev.bgw_buffers_backend AS backend_writes_delta,
            EXTRACT(EPOCH FROM (s.captured_at - prev.captured_at)) / 60.0 AS interval_minutes
        FROM pgfr_record.snapshots s
        JOIN pgfr_record.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM pgfr_record.snapshots WHERE id < s.id
        )
        WHERE s.captured_at >= v_window_start
          AND s.bgw_buffers_backend IS NOT NULL
          AND prev.bgw_buffers_backend IS NOT NULL
          AND s.bgw_buffers_backend >= prev.bgw_buffers_backend
    )
    SELECT
        GREATEST(0, COALESCE(sum(backend_writes_delta), 0)),
        GREATEST(0, COALESCE(sum(backend_writes_delta) / NULLIF(sum(interval_minutes), 0), 0))
    INTO v_bgw_backend_total, v_bgw_backend_avg_per_min
    FROM buffer_deltas;
    SELECT setting INTO v_shared_buffers_setting
    FROM pg_settings WHERE name = 'shared_buffers';
    metric := 'memory_shared_buffers';
    current_usage := format('%s backend writes total (%s/min avg)',
                           v_bgw_backend_total,
                           round(v_bgw_backend_avg_per_min, 1));
    provisioned_capacity := v_shared_buffers_setting;
    utilization_pct := CASE
        WHEN v_bgw_backend_avg_per_min IS NULL OR v_bgw_backend_avg_per_min <= 0 THEN 0
        WHEN v_bgw_backend_avg_per_min < 100 THEN round((v_bgw_backend_avg_per_min / 100.0) * 60, 1)
        ELSE LEAST(100, round(60 + ((v_bgw_backend_avg_per_min - 100) / 900.0) * 40, 1))
    END;
    headroom_pct := round(GREATEST(0, 100 - utilization_pct), 1);
    status := CASE
        WHEN v_bgw_backend_avg_per_min >= 1000 THEN 'critical'
        WHEN v_bgw_backend_avg_per_min >= 100 THEN 'warning'
        ELSE 'healthy'
    END;
    recommendation := CASE
        WHEN v_bgw_backend_avg_per_min >= 1000 THEN
            format('CRITICAL: Heavy shared_buffers pressure (%s backend writes/min). Increase shared_buffers or reduce concurrent write load.',
                   round(v_bgw_backend_avg_per_min, 1))
        WHEN v_bgw_backend_avg_per_min >= 100 THEN
            format('WARNING: Moderate shared_buffers pressure (%s backend writes/min). Monitor trend and consider increasing shared_buffers.',
                   round(v_bgw_backend_avg_per_min, 1))
        WHEN v_bgw_backend_total = 0 THEN
            'HEALTHY: No shared_buffers pressure detected. Current setting appears adequate.'
        ELSE
            format('HEALTHY: Minimal shared_buffers pressure (%s backend writes/min). No action needed.',
                   round(v_bgw_backend_avg_per_min, 1))
    END;
    RETURN NEXT;
    WITH temp_deltas AS (
        SELECT
            s.temp_bytes - prev.temp_bytes AS temp_bytes_delta
        FROM pgfr_record.snapshots s
        JOIN pgfr_record.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM pgfr_record.snapshots WHERE id < s.id
        )
        WHERE s.captured_at >= v_window_start
          AND s.temp_bytes IS NOT NULL
          AND prev.temp_bytes IS NOT NULL
          AND s.temp_bytes >= prev.temp_bytes
    )
    SELECT
        COALESCE(sum(temp_bytes_delta), 0)
    INTO v_temp_bytes_total
    FROM temp_deltas;
    v_temp_bytes_per_hour := v_temp_bytes_total / NULLIF(v_window_hours, 0);
    metric := 'memory_work_mem';
    current_usage := format('%s spilled (%s/hour)',
                           pgfr_record._pretty_bytes(v_temp_bytes_total),
                           pgfr_record._pretty_bytes(v_temp_bytes_per_hour::bigint));
    provisioned_capacity := (SELECT setting FROM pg_settings WHERE name = 'work_mem');
    utilization_pct := CASE
        WHEN v_temp_bytes_per_hour IS NULL OR v_temp_bytes_per_hour <= 0 THEN 0
        WHEN v_temp_bytes_per_hour < 104857600 THEN round((v_temp_bytes_per_hour / 104857600.0) * 60, 1)
        ELSE LEAST(100, round(60 + ((v_temp_bytes_per_hour - 104857600) / 939524096.0) * 40, 1))
    END;
    headroom_pct := round(GREATEST(0, 100 - utilization_pct), 1);
    status := CASE
        WHEN v_temp_bytes_per_hour >= 1073741824 THEN 'critical'
        WHEN v_temp_bytes_per_hour >= 104857600 THEN 'warning'
        ELSE 'healthy'
    END;
    recommendation := CASE
        WHEN v_temp_bytes_per_hour >= 1073741824 THEN
            format('CRITICAL: Heavy temp file spills (%s/hour). Increase work_mem for affected queries or globally.',
                   pgfr_record._pretty_bytes(v_temp_bytes_per_hour::bigint))
        WHEN v_temp_bytes_per_hour >= 104857600 THEN
            format('WARNING: Moderate temp file spills (%s/hour). Consider increasing work_mem for sort/hash operations.',
                   pgfr_record._pretty_bytes(v_temp_bytes_per_hour::bigint))
        WHEN v_temp_bytes_total = 0 THEN
            'HEALTHY: No temp file spills detected. Queries fitting in work_mem.'
        ELSE
            format('HEALTHY: Minimal temp file spills (%s/hour). Current work_mem adequate.',
                   pgfr_record._pretty_bytes(v_temp_bytes_per_hour::bigint))
    END;
    RETURN NEXT;
    WITH io_deltas AS (
        SELECT
            s.blks_read - prev.blks_read AS read_delta,
            s.blks_hit - prev.blks_hit AS hit_delta
        FROM pgfr_record.snapshots s
        JOIN pgfr_record.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM pgfr_record.snapshots WHERE id < s.id
        )
        WHERE s.captured_at >= v_window_start
          AND s.blks_read IS NOT NULL
          AND prev.blks_read IS NOT NULL
          AND s.blks_read >= prev.blks_read
    )
    SELECT
        COALESCE(sum(read_delta), 0),
        COALESCE(sum(hit_delta), 0)
    INTO v_blks_read_total, v_blks_hit_total
    FROM io_deltas;
    v_cache_hit_ratio := CASE
        WHEN (v_blks_read_total + v_blks_hit_total) > 0
        THEN round((v_blks_hit_total::numeric / (v_blks_read_total + v_blks_hit_total)) * 100, 2)
        ELSE NULL
    END;
    metric := 'io_buffer_cache';
    current_usage := format('%s%% cache hit ratio (%s reads / %s hits)',
                           v_cache_hit_ratio,
                           v_blks_read_total,
                           v_blks_hit_total);
    provisioned_capacity := 'Target: >95%';
    utilization_pct := CASE
        WHEN v_cache_hit_ratio IS NULL THEN NULL
        WHEN v_cache_hit_ratio >= 95 THEN LEAST(100, GREATEST(0, round((100 - v_cache_hit_ratio) * 20, 1)))
        ELSE LEAST(100, GREATEST(0, round(100 - (v_cache_hit_ratio / 95.0) * 100, 1)))
    END;
    headroom_pct := CASE WHEN utilization_pct IS NOT NULL THEN round(GREATEST(0, 100 - utilization_pct), 1) ELSE NULL END;
    status := CASE
        WHEN v_cache_hit_ratio IS NULL THEN 'insufficient_data'
        WHEN v_cache_hit_ratio < 80 THEN 'critical'
        WHEN v_cache_hit_ratio < 95 THEN 'warning'
        ELSE 'healthy'
    END;
    recommendation := CASE
        WHEN v_cache_hit_ratio IS NULL THEN
            'Insufficient I/O data. Need more snapshots for cache hit ratio analysis.'
        WHEN v_cache_hit_ratio < 80 THEN
            format('CRITICAL: Poor cache hit ratio (%s%%). Increase shared_buffers or optimize queries to reduce I/O.',
                   v_cache_hit_ratio)
        WHEN v_cache_hit_ratio < 95 THEN
            format('WARNING: Below-optimal cache hit ratio (%s%%). Consider increasing shared_buffers for better performance.',
                   v_cache_hit_ratio)
        ELSE
            format('HEALTHY: Good cache hit ratio (%s%%). I/O performance is adequate.',
                   v_cache_hit_ratio)
    END;
    RETURN NEXT;
    SELECT
        COALESCE(
            (SELECT db_size_bytes FROM pgfr_record.snapshots
             WHERE captured_at >= v_window_start AND db_size_bytes IS NOT NULL
             ORDER BY captured_at DESC LIMIT 1),
            0
        ),
        COALESCE(
            (SELECT db_size_bytes FROM pgfr_record.snapshots
             WHERE captured_at >= v_window_start AND db_size_bytes IS NOT NULL
             ORDER BY captured_at ASC LIMIT 1),
            0
        )
    INTO v_current_db_size, v_oldest_db_size;
    IF v_current_db_size > 0 AND v_oldest_db_size > 0 THEN
        v_storage_growth_mb_per_day := ((v_current_db_size - v_oldest_db_size)::numeric / (1024.0 * 1024.0))
                                       / NULLIF(v_window_hours / 24.0, 0);
        metric := 'storage_growth';
        -- The machine-readable figure the dashboard consumes; keeping it a
        -- column kills the prose-regexp round trip that Issue #111 caught
        -- (the dashboard used to parse a number out of recommendation text
        -- that never contained it, yielding NULL always).
        numeric_value := round(v_storage_growth_mb_per_day, 1);
        current_usage := format('%s current size, growing %s MB/day',
                               pgfr_record._pretty_bytes(v_current_db_size),
                               CASE
                                   WHEN v_storage_growth_mb_per_day < 0 THEN '~0'
                                   ELSE round(v_storage_growth_mb_per_day, 1)::text
                               END);
        provisioned_capacity := 'Disk capacity dependent';
        utilization_pct := CASE
            WHEN v_storage_growth_mb_per_day <= 0 THEN 0
            WHEN v_storage_growth_mb_per_day < 1024 THEN round((v_storage_growth_mb_per_day / 1024.0) * 60, 1)
            ELSE LEAST(100, round(60 + ((v_storage_growth_mb_per_day - 1024) / 9216.0) * 40, 1))
        END;
        headroom_pct := round(GREATEST(0, 100 - utilization_pct), 1);
        status := CASE
            WHEN v_storage_growth_mb_per_day >= 10240 THEN 'critical'
            WHEN v_storage_growth_mb_per_day >= 1024 THEN 'warning'
            ELSE 'healthy'
        END;
        recommendation := CASE
            WHEN v_storage_growth_mb_per_day >= 10240 THEN
                format('CRITICAL: Rapid storage growth (%s MB/day). Review VACUUM, bloat, and retention policies.',
                       round(v_storage_growth_mb_per_day, 1))
            WHEN v_storage_growth_mb_per_day >= 1024 THEN
                format('WARNING: Significant storage growth (%s MB/day). Monitor disk capacity and plan expansion.',
                       round(v_storage_growth_mb_per_day, 1))
            WHEN v_storage_growth_mb_per_day < 0 THEN
                'HEALTHY: Database size stable or shrinking (VACUUM/DELETE activity). No concerns.'
            ELSE
                format('HEALTHY: Moderate storage growth (%s MB/day). Current rate is sustainable.',
                       round(v_storage_growth_mb_per_day, 1))
        END;
        RETURN NEXT;
        -- OUT variables persist across RETURN NEXT in plpgsql: reset so the
        -- transaction-rate row that follows does not inherit this figure.
        numeric_value := NULL;
    END IF;
    WITH xact_deltas AS (
        SELECT
            (s.xact_commit + s.xact_rollback - prev.xact_commit - prev.xact_rollback) AS xact_delta,
            EXTRACT(EPOCH FROM (s.captured_at - prev.captured_at)) AS interval_seconds
        FROM pgfr_record.snapshots s
        JOIN pgfr_record.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM pgfr_record.snapshots WHERE id < s.id
        )
        WHERE s.captured_at >= v_window_start
          AND s.xact_commit IS NOT NULL
          AND prev.xact_commit IS NOT NULL
          AND (s.xact_commit + s.xact_rollback) >= (prev.xact_commit + prev.xact_rollback)
    )
    SELECT
        COALESCE(sum(xact_delta), 0),
        COALESCE(round(avg(xact_delta / NULLIF(interval_seconds, 0)), 1), 0),
        COALESCE(round(max(xact_delta / NULLIF(interval_seconds, 0)), 1), 0)
    INTO v_xact_total, v_xact_rate_avg, v_xact_rate_peak
    FROM xact_deltas;
    IF v_xact_total > 0 THEN
        metric := 'transaction_rate';
        current_usage := format('%s total (%s/sec avg, %s/sec peak)',
                               v_xact_total,
                               v_xact_rate_avg,
                               v_xact_rate_peak);
        provisioned_capacity := 'Workload dependent';
        utilization_pct := CASE
            WHEN v_xact_rate_peak IS NULL OR v_xact_rate_peak <= 0 THEN 0
            WHEN v_xact_rate_peak < 1000 THEN round((v_xact_rate_peak / 1000.0) * 60, 1)
            ELSE LEAST(100, round(60 + ((v_xact_rate_peak - 1000) / 4000.0) * 40, 1))
        END;
        headroom_pct := round(GREATEST(0, 100 - utilization_pct), 1);
        status := CASE
            WHEN v_xact_rate_peak >= 5000 THEN 'warning'
            ELSE 'healthy'
        END;
        recommendation := CASE
            WHEN v_xact_rate_peak >= 5000 THEN
                format('High transaction rate (%s tps peak). Ensure connection pooling and monitoring CPU/I/O capacity.',
                       v_xact_rate_peak)
            WHEN v_xact_rate_avg < 10 THEN
                format('Low transaction rate (%s tps avg). Database may be under-utilized.',
                       v_xact_rate_avg)
            ELSE
                format('HEALTHY: Transaction rate %s tps avg, %s tps peak. Workload appears normal.',
                       v_xact_rate_avg, v_xact_rate_peak)
        END;
        RETURN NEXT;
    END IF;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.capacity_summary(INTERVAL) IS

'Capacity planning summary across all resource dimensions. Analyzes connections, memory (shared_buffers, work_mem), I/O (cache hit ratio), storage growth, and transaction rates over the specified time window. Returns utilization, status (healthy/warning/critical), and actionable recommendations. Part of Phase 1 MVP capacity planning enhancements (FR-2.1).

Output columns:
  metric: [dimension] [text] Capacity dimension name: connections, memory_shared_buffers, memory_work_mem, io_buffer_cache, storage_growth, or transaction_rate; a single insufficient_data row appears instead when fewer than 2 snapshots fall in the window.
  current_usage: [derived] [text] Human-readable usage summary for the dimension, formatted from snapshot gauges (connection counts, database size) and counter deltas (backend buffer writes, temp bytes, transactions) over the window.
  provisioned_capacity: [dimension] [text] Configured capacity for the dimension: max_connections, the shared_buffers or work_mem setting, a fixed cache hit ratio target string, or a workload or disk dependent placeholder.
  utilization_pct: [derived] [percent] Utilization score on a 0-100 scale. For connections it is peak connections_total over max_connections times 100; the other dimensions map their measured rate (backend writes/min, temp bytes/hour, cache hit ratio shortfall against a 95 percent target, storage growth in MB/day, peak tps) onto 0-100 via a piecewise scale, so only the connections row is a true capacity ratio.
  headroom_pct: [derived] [percent] 100 minus utilization_pct, floored at 0: the unused share of the same 0-100 scale.
  status: [derived] [text] Threshold assessment of the dimension: healthy, warning, critical, or insufficient_data. Connection thresholds come from the capacity_thresholds_warning_pct and capacity_thresholds_critical_pct config; other dimensions use fixed thresholds on their measured rate.
  recommendation: [derived] [text] Actionable prose built from the status and the measured values for the dimension.
  numeric_value: [derived] [mixed] The row''s primary figure as a number rather than prose, in the dimension''s natural units. Currently populated only for storage_growth (MB/day, negative reported as its true value; the prose rounds negatives to ~0); NULL for the other dimensions. Exists so consumers like capacity_dashboard never parse numbers back out of recommendation text (Issue #111).';

-- Generates a human-readable markdown capacity report grouped by severity
-- Calls capacity_summary() and formats results as prose text
CREATE OR REPLACE FUNCTION pgfr_analyze.capacity_report(
    p_time_window INTERVAL DEFAULT interval '24 hours'
)
RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_result TEXT := '';
    v_row RECORD;
    v_has_critical BOOLEAN := FALSE;
    v_has_warning BOOLEAN := FALSE;
    v_has_healthy BOOLEAN := FALSE;
    v_critical_section TEXT := '';
    v_warning_section TEXT := '';
    v_healthy_section TEXT := '';
    v_metric_name TEXT;
    v_recommendation TEXT;
BEGIN
    -- Header
    v_result := '# Capacity Report' || E'\n';
    v_result := v_result || 'Generated: ' || to_char(now(), 'YYYY-MM-DD HH24:MI:SS') ||
                ' | Window: ' || p_time_window::text || E'\n';
    -- Coverage disclosure (Issue #102): capacity figures derive from snapshot
    -- ticks; say how many of the window's expected ticks actually exist.
    v_result := v_result || COALESCE(
        (SELECT format('Coverage: %s/%s snapshot ticks (%s%%); rates below are interval means over the window (see STATISTICS.md)',
                       c.observed_samples, c.expected_samples,
                       round(c.coverage_ratio * 100, 1))
         FROM pgfr_analyze.coverage(p_time_window) c
         WHERE c.collector = 'snapshot'),
        'Coverage: no expected snapshot ticks in window') || E'\n';

    -- Process each metric from capacity_summary
    FOR v_row IN
        SELECT *
        FROM pgfr_analyze.capacity_summary(p_time_window)
        WHERE metric != 'insufficient_data'
        ORDER BY
            CASE status
                WHEN 'critical' THEN 1
                WHEN 'warning' THEN 2
                ELSE 3
            END,
            metric
    LOOP
        -- Map metric names to readable names
        v_metric_name := CASE v_row.metric
            WHEN 'connections' THEN 'Connections'
            WHEN 'memory_shared_buffers' THEN 'Shared Buffers'
            WHEN 'memory_work_mem' THEN 'Work Mem'
            WHEN 'io_buffer_cache' THEN 'Cache Hit Ratio'
            WHEN 'storage_growth' THEN 'Storage Growth'
            WHEN 'transaction_rate' THEN 'Transaction Rate'
            ELSE initcap(replace(v_row.metric, '_', ' '))
        END;

        -- Strip severity prefix from recommendation
        v_recommendation := regexp_replace(v_row.recommendation, '^(CRITICAL|WARNING|HEALTHY): ', '');

        -- Build section content based on status
        IF v_row.status = 'critical' THEN
            v_has_critical := TRUE;
            v_critical_section := v_critical_section ||
                E'\n**' || v_metric_name || '** - ' || v_row.current_usage || E'\n' ||
                '  → ' || v_recommendation || E'\n';
        ELSIF v_row.status = 'warning' THEN
            v_has_warning := TRUE;
            v_warning_section := v_warning_section ||
                E'\n**' || v_metric_name || '** - ' || v_row.current_usage || E'\n' ||
                '  → ' || v_recommendation || E'\n';
        ELSE
            v_has_healthy := TRUE;
            v_healthy_section := v_healthy_section ||
                E'\n**' || v_metric_name || '** - ' || v_row.current_usage || E'\n';
        END IF;
    END LOOP;

    -- Handle insufficient data case
    FOR v_row IN
        SELECT *
        FROM pgfr_analyze.capacity_summary(p_time_window)
        WHERE metric = 'insufficient_data'
    LOOP
        v_result := v_result || E'\n' || v_row.recommendation || E'\n';
        RETURN v_result;
    END LOOP;

    -- Assemble sections
    IF v_has_critical THEN
        v_result := v_result || E'\n## Critical Issues' || v_critical_section;
    END IF;

    IF v_has_warning THEN
        v_result := v_result || E'\n## Warnings' || v_warning_section;
    END IF;

    IF v_has_healthy THEN
        v_result := v_result || E'\n## Healthy' || v_healthy_section;
    END IF;

    -- If nothing was found
    IF NOT v_has_critical AND NOT v_has_warning AND NOT v_has_healthy THEN
        v_result := v_result || E'\nNo capacity data available for the specified time window.\n';
    END IF;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.capacity_report(INTERVAL) IS
'Human-readable capacity report in markdown format. Groups metrics by severity (critical, warning, healthy) with actionable recommendations. Calls capacity_summary() internally for data. Use this for incident reports and documentation.';

CREATE OR REPLACE VIEW pgfr_analyze.capacity_dashboard AS
WITH
latest_snapshot AS (
    SELECT max(captured_at) AS last_updated
    FROM pgfr_record.snapshots
),
capacity_metrics AS (
    SELECT
        metric,
        utilization_pct,
        headroom_pct,
        status,
        recommendation,
        numeric_value
    FROM pgfr_analyze.capacity_summary(interval '24 hours')
    WHERE metric != 'insufficient_data'
),
connections_metric AS (
    SELECT
        status AS connections_status,
        utilization_pct AS connections_utilization_pct,
        headroom_pct AS connections_headroom,
        recommendation AS connections_recommendation
    FROM capacity_metrics
    WHERE metric = 'connections'
),
memory_sb_metric AS (
    SELECT
        status,
        utilization_pct
    FROM capacity_metrics
    WHERE metric = 'memory_shared_buffers'
),
memory_wm_metric AS (
    SELECT
        status,
        utilization_pct
    FROM capacity_metrics
    WHERE metric = 'memory_work_mem'
),
io_metric AS (
    SELECT
        status AS io_status,
        utilization_pct AS io_saturation_pct,
        recommendation AS io_recommendation
    FROM capacity_metrics
    WHERE metric = 'io_buffer_cache'
),
storage_metric AS (
    SELECT
        status AS storage_status,
        utilization_pct AS storage_utilization_pct,
        recommendation AS storage_recommendation,
        numeric_value AS storage_growth_mb_per_day
    FROM capacity_metrics
    WHERE metric = 'storage_growth'
)
SELECT
    l.last_updated,
    COALESCE(c.connections_status, 'insufficient_data') AS connections_status,
    c.connections_utilization_pct,
    c.connections_headroom,
    CASE
        WHEN ms.status IS NULL AND mw.status IS NULL THEN 'insufficient_data'
        WHEN ms.status = 'critical' OR mw.status = 'critical' THEN 'critical'
        WHEN ms.status = 'warning' OR mw.status = 'warning' THEN 'warning'
        ELSE COALESCE(ms.status, mw.status, 'healthy')
    END AS memory_status,
    GREATEST(0, LEAST(100, round(
        COALESCE(ms.utilization_pct, 0) * 0.6 +
        COALESCE(mw.utilization_pct, 0) * 0.4,
        1
    ))) AS memory_pressure_score,
    COALESCE(io.io_status, 'insufficient_data') AS io_status,
    io.io_saturation_pct,
    COALESCE(s.storage_status, 'insufficient_data') AS storage_status,
    s.storage_utilization_pct,
    s.storage_growth_mb_per_day,
    CASE
        WHEN 'critical' IN (
            c.connections_status,
            CASE WHEN ms.status = 'critical' OR mw.status = 'critical' THEN 'critical' END,
            io.io_status,
            s.storage_status
        ) THEN 'critical'
        WHEN 'warning' IN (
            c.connections_status,
            CASE WHEN ms.status = 'warning' OR mw.status = 'warning' THEN 'warning' END,
            io.io_status,
            s.storage_status
        ) THEN 'warning'
        WHEN 'insufficient_data' IN (
            COALESCE(c.connections_status, 'insufficient_data'),
            CASE WHEN ms.status IS NULL AND mw.status IS NULL THEN 'insufficient_data' END,
            COALESCE(io.io_status, 'insufficient_data'),
            COALESCE(s.storage_status, 'insufficient_data')
        ) THEN 'insufficient_data'
        ELSE 'healthy'
    END AS overall_status,
    ARRAY_REMOVE(ARRAY[
        CASE WHEN c.connections_status IN ('critical', 'warning')
             THEN 'CONNECTIONS: ' || c.connections_recommendation END,
        CASE WHEN ms.status IN ('critical', 'warning')
             THEN 'MEMORY (shared_buffers): ' ||
                  (SELECT recommendation FROM capacity_metrics WHERE metric = 'memory_shared_buffers') END,
        CASE WHEN mw.status IN ('critical', 'warning')
             THEN 'MEMORY (work_mem): ' ||
                  (SELECT recommendation FROM capacity_metrics WHERE metric = 'memory_work_mem') END,
        CASE WHEN io.io_status IN ('critical', 'warning')
             THEN 'I/O: ' || io.io_recommendation END,
        CASE WHEN s.storage_status IN ('critical', 'warning')
             THEN 'STORAGE: ' || s.storage_recommendation END
    ], NULL) AS critical_issues
FROM latest_snapshot l
LEFT JOIN connections_metric c ON true
LEFT JOIN memory_sb_metric ms ON true
LEFT JOIN memory_wm_metric mw ON true
LEFT JOIN io_metric io ON true
LEFT JOIN storage_metric s ON true;
COMMENT ON VIEW pgfr_analyze.capacity_dashboard IS
'At-a-glance capacity planning dashboard. Shows current status (healthy/warning/critical) across all resource dimensions: connections, memory, I/O, storage. Includes utilization percentages, composite memory pressure score, and array of critical issues requiring attention. Based on last 24 hours of data. Part of Phase 1 MVP capacity planning enhancements (FR-3.1).';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.last_updated IS
'[dimension] [timestamp] Capture time of the most recent pgfr_record.snapshots row; freshness marker for the whole dashboard.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.connections_status IS
'[derived] [text] Connections dimension status from capacity_summary() over the last 24 hours: healthy, warning, or critical from thresholds on connection utilization; insufficient_data when the connections row is absent.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.connections_utilization_pct IS
'[derived] [percent] Peak connections_total over max_connections times 100, over the last 24 hours (from the connections row of capacity_summary()).';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.connections_headroom IS
'[derived] [percent] 100 minus connections_utilization_pct, floored at 0: the unused share of max_connections at the 24-hour peak.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.memory_status IS
'[derived] [text] Worst of the shared_buffers and work_mem statuses from capacity_summary() (critical over warning over healthy); insufficient_data when neither memory row exists.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.memory_pressure_score IS
'[derived] [percent] Composite memory pressure on a 0-100 scale: 0.6 times the shared_buffers utilization score plus 0.4 times the work_mem utilization score, clamped to 0-100. Both inputs are piecewise scores from capacity_summary(), not ratios of a physical memory capacity.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.io_status IS
'[derived] [text] Buffer-cache dimension status from capacity_summary() (the io_buffer_cache row); insufficient_data when absent.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.io_saturation_pct IS
'[derived] [percent] Buffer-cache utilization score from capacity_summary(): a piecewise 0-100 mapping of the cache hit ratio shortfall against a 95 percent target, computed from blks_hit and blks_read deltas over the last 24 hours; not a ratio of device I/O capacity.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.storage_status IS
'[derived] [text] Storage growth dimension status from capacity_summary(); insufficient_data when absent.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.storage_utilization_pct IS
'[derived] [percent] Storage growth utilization score from capacity_summary(): a piecewise 0-100 mapping of the MB/day growth rate (reaches 60 at 1 GB/day and saturates toward 100 at 10 GB/day).';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.storage_growth_mb_per_day IS
'[derived] [mb/day] [interval-mean] Mean database size growth over the 24-hour window: last db_size_bytes minus first, divided by the window length in days (a two-point difference, not a regression). Carried numerically from capacity_summary().numeric_value (Issue #111 replaced the earlier prose-regexp extraction, which never matched and left this NULL). NULL only when fewer than 2 sized snapshots fall in the window.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.overall_status IS
'[derived] [text] Worst status across connections, memory, I/O, and storage: critical if any dimension is critical, else warning if any is warning, else insufficient_data if any dimension lacks data, else healthy.';
COMMENT ON COLUMN pgfr_analyze.capacity_dashboard.critical_issues IS
'[derived] [text] Array of prefixed recommendation strings (CONNECTIONS:, MEMORY:, I/O:, STORAGE:) for every dimension whose status is critical or warning; empty when nothing needs attention.';

-- NOTE: Storm and Regression dashboard views removed in 2.21
-- Use detect_query_storms() and detect_regressions() for on-demand analysis

-- TABLE-LEVEL HOTSPOT TRACKING ANALYSIS FUNCTIONS
-- =============================================================================

-- Compares table activity between two time points
-- Returns delta metrics for DML activity, scans, and maintenance events
