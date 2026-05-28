-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

CREATE OR REPLACE FUNCTION pgfr_analyze.performance_report(p_lookback_interval INTERVAL DEFAULT '24 hours')
RETURNS TABLE(
    metric TEXT,
    value TEXT,
    assessment TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_avg_sample_ms NUMERIC;
    v_max_sample_ms INTEGER;
    v_avg_snapshot_ms NUMERIC;
    v_max_snapshot_ms INTEGER;
    v_total_collections INTEGER;
    v_failed_collections INTEGER;
    v_skipped_collections INTEGER;
    v_schema_size_mb NUMERIC;
BEGIN
    SELECT
        avg(duration_ms) FILTER (WHERE collection_type = 'sample' AND success = true AND skipped = false),
        max(duration_ms) FILTER (WHERE collection_type = 'sample' AND success = true AND skipped = false),
        avg(duration_ms) FILTER (WHERE collection_type = 'snapshot' AND success = true AND skipped = false),
        max(duration_ms) FILTER (WHERE collection_type = 'snapshot' AND success = true AND skipped = false),
        count(*),
        count(*) FILTER (WHERE success = false),
        count(*) FILTER (WHERE skipped = true)
    INTO v_avg_sample_ms, v_max_sample_ms, v_avg_snapshot_ms, v_max_snapshot_ms,
         v_total_collections, v_failed_collections, v_skipped_collections
    FROM pgfr_record.collection_stats
    WHERE started_at > now() - p_lookback_interval;
    SELECT schema_size_mb INTO v_schema_size_mb FROM pgfr_record._check_schema_size();
    RETURN QUERY SELECT
        'Avg Sample Duration'::text,
        COALESCE(round(v_avg_sample_ms)::text || ' ms', 'N/A'),
        CASE
            WHEN v_avg_sample_ms IS NULL THEN 'No data'
            WHEN v_avg_sample_ms < 100 THEN 'Excellent'
            WHEN v_avg_sample_ms < 500 THEN 'Good'
            WHEN v_avg_sample_ms < 1000 THEN 'Acceptable'
            ELSE 'Poor - consider emergency mode'
        END::text;
    RETURN QUERY SELECT
        'Max Sample Duration'::text,
        COALESCE(v_max_sample_ms::text || ' ms', 'N/A'),
        CASE
            WHEN v_max_sample_ms IS NULL THEN 'No data'
            WHEN v_max_sample_ms < 1000 THEN 'Good'
            WHEN v_max_sample_ms < 5000 THEN 'Acceptable'
            ELSE 'Circuit breaker may trip'
        END::text;
    RETURN QUERY SELECT
        'Avg Snapshot Duration'::text,
        COALESCE(round(v_avg_snapshot_ms)::text || ' ms', 'N/A'),
        CASE
            WHEN v_avg_snapshot_ms IS NULL THEN 'No data'
            WHEN v_avg_snapshot_ms < 500 THEN 'Excellent'
            WHEN v_avg_snapshot_ms < 2000 THEN 'Good'
            WHEN v_avg_snapshot_ms < 5000 THEN 'Acceptable'
            ELSE 'Poor'
        END::text;
    RETURN QUERY SELECT
        'Schema Size'::text,
        round(v_schema_size_mb)::text || ' MB',
        CASE
            WHEN v_schema_size_mb < 1000 THEN 'Healthy'
            WHEN v_schema_size_mb < 5000 THEN 'Good'
            WHEN v_schema_size_mb < 8000 THEN 'Consider cleanup()'
            ELSE 'Run cleanup() soon'
        END::text;
    RETURN QUERY SELECT
        'Collection Success Rate'::text,
        format('%s%% (%s/%s)',
               round(((v_total_collections - v_failed_collections)::numeric / NULLIF(v_total_collections, 0)) * 100, 1)::text,
               v_total_collections - v_failed_collections,
               v_total_collections),
        CASE
            WHEN v_total_collections = 0 THEN 'No collections'
            WHEN v_failed_collections = 0 THEN 'Perfect'
            WHEN (v_failed_collections::numeric / v_total_collections) < 0.01 THEN 'Excellent'
            WHEN (v_failed_collections::numeric / v_total_collections) < 0.05 THEN 'Good'
            ELSE 'Issues detected'
        END::text;
    RETURN QUERY SELECT
        'Skipped Collections'::text,
        v_skipped_collections::text,
        CASE
            WHEN v_skipped_collections = 0 THEN 'No skips'
            WHEN v_skipped_collections < 5 THEN 'Minimal'
            WHEN v_skipped_collections < 20 THEN 'Moderate - check system load'
            ELSE 'Significant - system under stress'
        END::text;
    RETURN QUERY SELECT
        'Section Success Rate'::text,
        COALESCE(
            round(100.0 * avg(sections_succeeded::numeric / NULLIF(sections_total, 0)), 1)::text || '%',
            'N/A'
        ),
        CASE
            WHEN avg(sections_succeeded::numeric / NULLIF(sections_total, 0)) IS NULL THEN 'No data'
            WHEN avg(sections_succeeded::numeric / NULLIF(sections_total, 0)) >= 0.95 THEN 'Excellent'
            WHEN avg(sections_succeeded::numeric / NULLIF(sections_total, 0)) >= 0.90 THEN 'Good'
            WHEN avg(sections_succeeded::numeric / NULLIF(sections_total, 0)) >= 0.75 THEN 'Fair - some section failures'
            ELSE 'Poor - frequent section failures'
        END::text
    FROM pgfr_record.collection_stats
    WHERE started_at > now() - p_lookback_interval
      AND sections_total IS NOT NULL;
    RETURN QUERY
    WITH recent AS (
        SELECT duration_ms
        FROM pgfr_record.collection_stats
        WHERE collection_type = 'sample'
          AND success = true
          AND skipped = false
          AND started_at > now() - p_lookback_interval
        ORDER BY started_at DESC
        LIMIT 10
    ),
    baseline AS (
        SELECT duration_ms
        FROM pgfr_record.collection_stats
        WHERE collection_type = 'sample'
          AND success = true
          AND skipped = false
          AND started_at > now() - p_lookback_interval
        ORDER BY started_at DESC
        LIMIT 100 OFFSET 50
    )
    SELECT
        'Performance Trend'::text,
        COALESCE(
            CASE
                WHEN (SELECT avg(duration_ms) FROM recent) IS NULL OR (SELECT avg(duration_ms) FROM baseline) IS NULL THEN 'Insufficient data'
                ELSE format('%s → %s ms (%s%s)',
                    round((SELECT avg(duration_ms) FROM baseline))::text,
                    round((SELECT avg(duration_ms) FROM recent))::text,
                    CASE WHEN ((SELECT avg(duration_ms) FROM recent) - (SELECT avg(duration_ms) FROM baseline)) > 0 THEN '+' ELSE '' END,
                    round((((SELECT avg(duration_ms) FROM recent) - (SELECT avg(duration_ms) FROM baseline)) / NULLIF((SELECT avg(duration_ms) FROM baseline), 0)) * 100, 1)::text || '%'
                )
            END,
            'N/A'
        ),
        CASE
            WHEN (SELECT avg(duration_ms) FROM recent) IS NULL OR (SELECT avg(duration_ms) FROM baseline) IS NULL THEN 'Need more data'
            WHEN (SELECT avg(duration_ms) FROM recent) > (SELECT avg(duration_ms) FROM baseline) * 1.5 THEN 'DEGRADING - investigate system load'
            WHEN (SELECT avg(duration_ms) FROM recent) < (SELECT avg(duration_ms) FROM baseline) * 0.7 THEN 'IMPROVING'
            ELSE 'STABLE'
        END::text;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.performance_report(INTERVAL) IS
'Reports on flight recorder collection performance: sample/snapshot timing, success rates, schema size, and qualitative health assessments over a configurable lookback window.';

-- Monitors flight recorder system health by checking for circuit breaker trips, schema size limits, collection failures, and stale data
-- Returns alerts with severity levels (CRITICAL/WARNING) and recommendations when thresholds are exceeded
CREATE OR REPLACE FUNCTION pgfr_analyze.check_alerts(p_lookback_interval INTERVAL DEFAULT '1 hour')
RETURNS TABLE(
    alert_type TEXT,
    severity TEXT,
    message TEXT,
    triggered_at TIMESTAMPTZ,
    recommendation TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_cb_threshold INTEGER;
    v_cb_count INTEGER;
    v_schema_threshold_mb INTEGER;
    v_schema_size_mb NUMERIC;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('alert_enabled', 'false')::boolean,
        false
    );
    IF NOT v_enabled THEN
        RETURN;
    END IF;
    v_cb_threshold := COALESCE(
        pgfr_record._get_config('alert_circuit_breaker_count', '5')::integer,
        5
    );
    SELECT count(*) INTO v_cb_count
    FROM pgfr_record.collection_stats
    WHERE skipped = true
      AND started_at > now() - p_lookback_interval
      AND skipped_reason LIKE '%Circuit breaker%';
    IF v_cb_count >= v_cb_threshold THEN
        RETURN QUERY SELECT
            'CIRCUIT_BREAKER_TRIPS'::text,
            'CRITICAL'::text,
            format('Circuit breaker tripped %s times in last %s', v_cb_count, p_lookback_interval),
            now(),
            'System under severe stress. Consider switching to emergency mode or disabling flight recorder temporarily.'::text;
    END IF;
    v_schema_threshold_mb := COALESCE(
        pgfr_record._get_config('alert_schema_size_mb', '8000')::integer,
        8000
    );
    SELECT schema_size_mb INTO v_schema_size_mb FROM pgfr_record._check_schema_size();
    IF v_schema_size_mb >= v_schema_threshold_mb THEN
        RETURN QUERY SELECT
            'SCHEMA_SIZE_HIGH'::text,
            'WARNING'::text,
            format('Schema size is %s MB (threshold: %s MB)', round(v_schema_size_mb)::text, v_schema_threshold_mb),
            now(),
            'Run pgfr_record.cleanup() to reclaim space.'::text;
    END IF;
    DECLARE
        v_recent_failures INTEGER;
    BEGIN
        SELECT count(*) INTO v_recent_failures
        FROM pgfr_record.collection_stats
        WHERE success = false
          AND started_at > now() - p_lookback_interval;
        IF v_recent_failures >= 5 THEN
            RETURN QUERY SELECT
                'COLLECTION_FAILURES'::text,
                'WARNING'::text,
                format('%s collection failures in last %s', v_recent_failures, p_lookback_interval),
                now(),
                'Check PostgreSQL logs for error details.'::text;
        END IF;
    END;
    DECLARE
        v_last_sample TIMESTAMPTZ;
    BEGIN
        SELECT pgfr_record.epoch() + max(sample_ts) * interval '1 second' INTO v_last_sample FROM pgfr_record.wait_samples;
        IF v_last_sample IS NULL OR v_last_sample < now() - interval '15 minutes' THEN
            RETURN QUERY SELECT
                'STALE_DATA'::text,
                'CRITICAL'::text,
                CASE
                    WHEN v_last_sample IS NULL THEN 'No samples collected yet'
                    ELSE format('Last sample was %s ago', age(now(), v_last_sample))
                END,
                now(),
                'Check pg_cron jobs: SELECT * FROM cron.job WHERE jobname LIKE ''pgfr_%'''::text;
        END IF;
    END;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.check_alerts(INTERVAL) IS
'Monitors flight recorder system health and returns alerts with severity levels (CRITICAL/WARNING) for circuit breaker trips, schema size limits, collection failures, and stale data.';

-- Exports flight recorder diagnostic data as human-readable Markdown
-- Produces a report with tables that is legible to both humans and AI
CREATE OR REPLACE FUNCTION pgfr_analyze.report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_result TEXT := '';
    v_version TEXT;
    v_row RECORD;
    v_count INTEGER;
BEGIN
    -- Get schema version from config
    SELECT value INTO v_version FROM pgfr_record.config WHERE key = 'schema_version';
    v_version := COALESCE(v_version, 'unknown');

    -- Header
    v_result := v_result || '# PostgreSQL Flight Recorder Report' || E'\n\n';
    v_result := v_result || '**Generated:** ' || to_char(now(), 'YYYY-MM-DD HH24:MI:SS TZ') || E'\n';
    v_result := v_result || '**Version:** ' || v_version || E'\n';
    v_result := v_result || '**Range:** ' || to_char(p_start_time, 'YYYY-MM-DD HH24:MI:SS') ||
                           ' to ' || to_char(p_end_time, 'YYYY-MM-DD HH24:MI:SS') || E'\n\n';
    v_result := v_result || 'Analyze this data. The database may be healthy—only flag genuine issues.' || E'\n\n';

    -- ==========================================================================
    -- Anomalies Section
    -- ==========================================================================
    v_result := v_result || '## Anomalies' || E'\n\n';

    SELECT count(*) INTO v_count FROM pgfr_analyze.anomaly_report(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '**No anomalies detected.** System appears healthy.' || E'\n\n';
    ELSE
        v_result := v_result || '| Type | Severity | Description | Metric | Recommendation |' || E'\n';
        v_result := v_result || '|------|----------|-------------|--------|----------------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.anomaly_report(p_start_time, p_end_time) LOOP
            v_result := v_result || '| ' ||
                COALESCE(v_row.anomaly_type, '-') || ' | ' ||
                COALESCE(v_row.severity, '-') || ' | ' ||
                COALESCE(v_row.description, '-') || ' | ' ||
                COALESCE(v_row.metric_value, '-') || ' | ' ||
                COALESCE(v_row.recommendation, '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Wait Event Summary Section
    -- ==========================================================================
    v_result := v_result || '## Wait Event Summary' || E'\n\n';

    SELECT count(*) INTO v_count FROM pgfr_analyze.wait_summary(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no wait events recorded)' || E'\n\n';
    ELSE
        v_result := v_result || '| Backend | Event Type | Event | Samples | Avg Waiters | Max | % |' || E'\n';
        v_result := v_result || '|---------|------------|-------|---------|-------------|-----|---|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.wait_summary(p_start_time, p_end_time) LOOP
            v_result := v_result || '| ' ||
                COALESCE(v_row.backend_state, '-') || ' | ' ||
                COALESCE(v_row.wait_event_type, '-') || ' | ' ||
                COALESCE(v_row.wait_event, '-') || ' | ' ||
                COALESCE(v_row.sample_count::TEXT, '-') || ' | ' ||
                COALESCE(v_row.avg_waiters::TEXT, '-') || ' | ' ||
                COALESCE(v_row.max_waiters::TEXT, '-') || ' | ' ||
                COALESCE(v_row.pct_of_samples::TEXT, '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Snapshots Section
    -- ==========================================================================
    v_result := v_result || '## Snapshots' || E'\n\n';

    SELECT count(*) INTO v_count
    FROM pgfr_record.snapshots
    WHERE captured_at BETWEEN p_start_time AND p_end_time;

    IF v_count = 0 THEN
        v_result := v_result || '(no snapshots in range)' || E'\n\n';
    ELSE
        v_result := v_result || '| Captured At | WAL Bytes | Ckpt (Timed) | Ckpt (Req) | Backend Writes |' || E'\n';
        v_result := v_result || '|-------------|-----------|--------------|------------|----------------|' || E'\n';
        FOR v_row IN
            SELECT captured_at, wal_bytes, ckpt_timed, ckpt_requested, bgw_buffers_backend
            FROM pgfr_record.snapshots
            WHERE captured_at BETWEEN p_start_time AND p_end_time
            ORDER BY captured_at
        LOOP
            v_result := v_result || '| ' ||
                to_char(v_row.captured_at, 'YYYY-MM-DD HH24:MI:SS') || ' | ' ||
                COALESCE(pgfr_record._pretty_bytes(v_row.wal_bytes), '-') || ' | ' ||
                COALESCE(v_row.ckpt_timed::TEXT, '-') || ' | ' ||
                COALESCE(v_row.ckpt_requested::TEXT, '-') || ' | ' ||
                COALESCE(v_row.bgw_buffers_backend::TEXT, '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Table Hotspots Section
    -- ==========================================================================
    v_result := v_result || '## Table Hotspots' || E'\n\n';

    SELECT count(*) INTO v_count FROM pgfr_analyze.table_hotspots(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no issues detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Schema | Table | Issue | Severity | Description | Recommendation |' || E'\n';
        v_result := v_result || '|--------|-------|-------|----------|-------------|----------------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.table_hotspots(p_start_time, p_end_time) LOOP
            v_result := v_result || '| ' ||
                COALESCE(v_row.schemaname, '-') || ' | ' ||
                COALESCE(v_row.relname, '-') || ' | ' ||
                COALESCE(v_row.issue_type, '-') || ' | ' ||
                COALESCE(v_row.severity, '-') || ' | ' ||
                COALESCE(v_row.description, '-') || ' | ' ||
                COALESCE(v_row.recommendation, '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Index Efficiency Section
    -- ==========================================================================
    v_result := v_result || '## Index Efficiency' || E'\n\n';

    SELECT count(*) INTO v_count FROM pgfr_analyze.index_efficiency(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no index activity in range)' || E'\n\n';
    ELSE
        v_result := v_result || '| Schema | Table | Index | Scans | Selectivity | Size | Scans/GB |' || E'\n';
        v_result := v_result || '|--------|-------|-------|-------|-------------|------|----------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.index_efficiency(p_start_time, p_end_time) LOOP
            v_result := v_result || '| ' ||
                COALESCE(v_row.schemaname, '-') || ' | ' ||
                COALESCE(v_row.relname, '-') || ' | ' ||
                COALESCE(v_row.indexrelname, '-') || ' | ' ||
                COALESCE(v_row.idx_scan_delta::TEXT, '-') || ' | ' ||
                COALESCE(v_row.selectivity::TEXT || '%', '-') || ' | ' ||
                COALESCE(v_row.index_size, '-') || ' | ' ||
                COALESCE(v_row.scans_per_gb::TEXT, '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Statement Performance Section (requires pg_stat_statements)
    -- ==========================================================================
    v_result := v_result || '## Statement Performance' || E'\n\n';

    BEGIN
        SELECT count(*) INTO v_count FROM pgfr_analyze.statement_compare(p_start_time, p_end_time, 100, 25);
        IF v_count = 0 THEN
            v_result := v_result || '(no significant query changes)' || E'\n\n';
        ELSE
            v_result := v_result || '| Query | Calls Δ | Total Time Δ (ms) | Mean (ms) | Temp Writes | Hit % |' || E'\n';
            v_result := v_result || '|-------|---------|-------------------|-----------|-------------|-------|' || E'\n';
            FOR v_row IN
                SELECT * FROM pgfr_analyze.statement_compare(p_start_time, p_end_time, 100, 25)
                ORDER BY total_exec_time_delta_ms DESC NULLS LAST
            LOOP
                v_result := v_result || '| ' ||
                    COALESCE(left(v_row.query_preview, 60), '-') || ' | ' ||
                    COALESCE(v_row.calls_delta::TEXT, '-') || ' | ' ||
                    COALESCE(round(v_row.total_exec_time_delta_ms::NUMERIC, 1)::TEXT, '-') || ' | ' ||
                    COALESCE(round(v_row.mean_exec_time_end_ms::NUMERIC, 2)::TEXT, '-') || ' | ' ||
                    COALESCE(v_row.temp_blks_written_delta::TEXT, '-') || ' | ' ||
                    COALESCE(v_row.hit_ratio_pct::TEXT, '-') || ' |' || E'\n';
            END LOOP;
            v_result := v_result || E'\n';
        END IF;
    EXCEPTION
        WHEN undefined_table OR undefined_function THEN
            v_result := v_result || '(pg_stat_statements not available)' || E'\n\n';
    END;

    -- ==========================================================================
    -- Lock Contention Section
    -- (Migrated from legacy lock_samples_archive to v2 lock_samples; lock_type
    -- decoded via lock_type_map. v2 doesn't retain blocked_query_preview, so
    -- that column is omitted from the report.)
    -- ==========================================================================
    v_result := v_result || '## Lock Contention' || E'\n\n';

    SELECT count(*) INTO v_count
    FROM pgfr_record.lock_samples ls
    WHERE pgfr_record.epoch() + ls.sample_ts * interval '1 second'
          BETWEEN p_start_time AND p_end_time;

    IF v_count = 0 THEN
        v_result := v_result || '(no lock contention recorded)' || E'\n\n';
    ELSE
        v_result := v_result || '| Time | Blocked PID | Blocking PID | Lock Type | Duration | Relation |' || E'\n';
        v_result := v_result || '|------|-------------|--------------|-----------|----------|----------|' || E'\n';
        FOR v_row IN
            SELECT pgfr_record.epoch() + ls.sample_ts * interval '1 second' AS captured_at,
                   ls.blocked_pid,
                   ls.blocking_pid,
                   coalesce(ltm.lock_type, ls.lock_type::text) AS lock_type,
                   ls.blocked_duration_s * interval '1 second' AS blocked_duration,
                   ls.locked_relation_oid::regclass::text AS locked_relation
            FROM pgfr_record.lock_samples ls
            LEFT JOIN pgfr_record.lock_type_map ltm ON ltm.id = ls.lock_type
            WHERE pgfr_record.epoch() + ls.sample_ts * interval '1 second'
                  BETWEEN p_start_time AND p_end_time
            ORDER BY ls.sample_ts DESC
            LIMIT 50
        LOOP
            v_result := v_result || '| ' ||
                to_char(v_row.captured_at, 'HH24:MI:SS') || ' | ' ||
                COALESCE(v_row.blocked_pid::TEXT, '-') || ' | ' ||
                COALESCE(v_row.blocking_pid::TEXT, '-') || ' | ' ||
                COALESCE(v_row.lock_type, '-') || ' | ' ||
                COALESCE(v_row.blocked_duration::TEXT, '-') || ' | ' ||
                COALESCE(v_row.locked_relation, '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Long-Running Transactions Section
    -- (Migrated from legacy activity_samples_archive to v2 activity_samples.)
    -- ==========================================================================
    v_result := v_result || '## Long-Running Transactions' || E'\n\n';

    SELECT count(*) INTO v_count
    FROM pgfr_record.activity_samples a
    WHERE pgfr_record.epoch() + a.sample_ts * interval '1 second'
          BETWEEN p_start_time AND p_end_time
      AND a.xact_start IS NOT NULL
      AND (pgfr_record.epoch() + a.sample_ts * interval '1 second') - a.xact_start
          > interval '5 minutes';

    IF v_count = 0 THEN
        v_result := v_result || '(no long-running transactions detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Time | PID | User | App | Transaction Age | State | Query Preview |' || E'\n';
        v_result := v_result || '|------|-----|------|-----|-----------------|-------|---------------|' || E'\n';
        FOR v_row IN
            SELECT DISTINCT ON (a.pid, a.xact_start)
                pgfr_record.epoch() + a.sample_ts * interval '1 second' AS captured_at,
                a.pid,
                a.usename,
                a.application_name,
                (pgfr_record.epoch() + a.sample_ts * interval '1 second') - a.xact_start AS xact_age,
                a.state,
                a.query_preview
            FROM pgfr_record.activity_samples a
            WHERE pgfr_record.epoch() + a.sample_ts * interval '1 second'
                  BETWEEN p_start_time AND p_end_time
              AND a.xact_start IS NOT NULL
              AND (pgfr_record.epoch() + a.sample_ts * interval '1 second') - a.xact_start
                  > interval '5 minutes'
            ORDER BY a.pid, a.xact_start, a.sample_ts DESC
            LIMIT 25
        LOOP
            v_result := v_result || '| ' ||
                to_char(v_row.captured_at, 'HH24:MI:SS') || ' | ' ||
                COALESCE(v_row.pid::TEXT, '-') || ' | ' ||
                COALESCE(v_row.usename, '-') || ' | ' ||
                COALESCE(left(v_row.application_name, 15), '-') || ' | ' ||
                COALESCE(v_row.xact_age::TEXT, '-') || ' | ' ||
                COALESCE(v_row.state, '-') || ' | ' ||
                COALESCE(left(v_row.query_preview, 30), '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Vacuum Progress Section
    -- ==========================================================================
    v_result := v_result || '## Vacuum Progress' || E'\n\n';

    SELECT count(*) INTO v_count
    FROM pgfr_record.vacuum_progress_snapshots v
    JOIN pgfr_record.snapshots s ON s.id = v.snapshot_id
    WHERE s.captured_at BETWEEN p_start_time AND p_end_time;

    IF v_count = 0 THEN
        v_result := v_result || '(no vacuums captured during this period)' || E'\n\n';
    ELSE
        v_result := v_result || '| Time | Database | Table | Phase | % Scanned | % Vacuumed | Dead Tuples |' || E'\n';
        v_result := v_result || '|------|----------|-------|-------|-----------|------------|-------------|' || E'\n';
        FOR v_row IN
            SELECT
                s.captured_at,
                v.datname,
                v.relname,
                v.phase,
                CASE WHEN v.heap_blks_total > 0
                    THEN round(100.0 * v.heap_blks_scanned / v.heap_blks_total, 1)
                    ELSE NULL
                END AS pct_scanned,
                CASE WHEN v.heap_blks_total > 0
                    THEN round(100.0 * v.heap_blks_vacuumed / v.heap_blks_total, 1)
                    ELSE NULL
                END AS pct_vacuumed,
                v.num_dead_tuples
            FROM pgfr_record.vacuum_progress_snapshots v
            JOIN pgfr_record.snapshots s ON s.id = v.snapshot_id
            WHERE s.captured_at BETWEEN p_start_time AND p_end_time
            ORDER BY s.captured_at DESC
            LIMIT 25
        LOOP
            v_result := v_result || '| ' ||
                to_char(v_row.captured_at, 'HH24:MI:SS') || ' | ' ||
                COALESCE(v_row.datname, '-') || ' | ' ||
                COALESCE(v_row.relname, '-') || ' | ' ||
                COALESCE(v_row.phase, '-') || ' | ' ||
                COALESCE(v_row.pct_scanned::TEXT || '%', '-') || ' | ' ||
                COALESCE(v_row.pct_vacuumed::TEXT || '%', '-') || ' | ' ||
                COALESCE(v_row.num_dead_tuples::TEXT, '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Archiver Status Section
    -- ==========================================================================
    v_result := v_result || '## WAL Archiver Status' || E'\n\n';

    SELECT count(*) INTO v_count
    FROM pgfr_record.snapshots
    WHERE captured_at BETWEEN p_start_time AND p_end_time
      AND archived_count IS NOT NULL;

    IF v_count = 0 THEN
        v_result := v_result || '(archiving not enabled or no data in range)' || E'\n\n';
    ELSE
        -- Show summary: total archived, total failed, any failures
        FOR v_row IN
            SELECT
                min(archived_count) AS start_archived,
                max(archived_count) AS end_archived,
                max(archived_count) - min(archived_count) AS archived_delta,
                min(failed_count) AS start_failed,
                max(failed_count) AS end_failed,
                max(failed_count) - min(failed_count) AS failed_delta,
                max(last_failed_wal) AS last_failed_wal,
                max(last_failed_time) AS last_failed_time
            FROM pgfr_record.snapshots
            WHERE captured_at BETWEEN p_start_time AND p_end_time
              AND archived_count IS NOT NULL
        LOOP
            v_result := v_result || '| Metric | Value |' || E'\n';
            v_result := v_result || '|--------|-------|' || E'\n';
            v_result := v_result || '| WAL Files Archived | ' ||
                COALESCE(v_row.archived_delta::TEXT, '0') || ' |' || E'\n';
            v_result := v_result || '| Archive Failures | ' ||
                COALESCE(v_row.failed_delta::TEXT, '0') || ' |' || E'\n';
            IF v_row.failed_delta > 0 AND v_row.last_failed_wal IS NOT NULL THEN
                v_result := v_result || '| Last Failed WAL | ' ||
                    v_row.last_failed_wal || ' |' || E'\n';
                v_result := v_result || '| Last Failure Time | ' ||
                    to_char(v_row.last_failed_time, 'YYYY-MM-DD HH24:MI:SS') || ' |' || E'\n';
            END IF;
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Configuration Changes Section
    -- ==========================================================================
    v_result := v_result || '## Configuration Changes' || E'\n\n';

    SELECT count(*) INTO v_count FROM pgfr_analyze.config_changes(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no changes detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Parameter | Old Value | New Value | Old Source | New Source | Changed At |' || E'\n';
        v_result := v_result || '|-----------|-----------|-----------|------------|------------|------------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.config_changes(p_start_time, p_end_time) LOOP
            v_result := v_result || '| ' ||
                COALESCE(v_row.parameter_name, '-') || ' | ' ||
                COALESCE(v_row.old_value, '-') || ' | ' ||
                COALESCE(v_row.new_value, '-') || ' | ' ||
                COALESCE(v_row.old_source, '-') || ' | ' ||
                COALESCE(v_row.new_source, '-') || ' | ' ||
                COALESCE(to_char(v_row.changed_at, 'YYYY-MM-DD HH24:MI:SS'), '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Role Configuration Changes Section
    -- ==========================================================================
    v_result := v_result || '## Role Configuration Changes' || E'\n\n';

    SELECT count(*) INTO v_count FROM pgfr_analyze.db_role_config_changes(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no changes detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Database | Role | Parameter | Old Value | New Value | Type |' || E'\n';
        v_result := v_result || '|----------|------|-----------|-----------|-----------|------|' || E'\n';
        FOR v_row IN SELECT * FROM pgfr_analyze.db_role_config_changes(p_start_time, p_end_time) LOOP
            v_result := v_result || '| ' ||
                COALESCE(v_row.database_name, '-') || ' | ' ||
                COALESCE(v_row.role_name, '-') || ' | ' ||
                COALESCE(v_row.parameter_name, '-') || ' | ' ||
                COALESCE(v_row.old_value, '-') || ' | ' ||
                COALESCE(v_row.new_value, '-') || ' | ' ||
                COALESCE(v_row.change_type, '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.report(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Generate diagnostic report from flight recorder data. Readable by humans and AI systems.';

-- Interval convenience overload: report('1 hour') instead of timestamps
CREATE OR REPLACE FUNCTION pgfr_analyze.report(
    p_interval INTERVAL
)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT pgfr_analyze.report(now() - p_interval, now());
$$;
COMMENT ON FUNCTION pgfr_analyze.report(INTERVAL) IS
'Generate diagnostic report for the specified interval ending now. Usage: SELECT pgfr_analyze.report(''1 hour'')';
-- Validates system readiness for flight recorder installation by checking resources, connections, and dependencies
-- Returns component status (GO/CAUTION/NO-GO) to determine installation viability
CREATE OR REPLACE FUNCTION pgfr_analyze.preflight_check()
RETURNS TABLE(
    check_name TEXT,
    status TEXT,
    details TEXT,
    recommendation TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_max_connections INTEGER;
    v_current_connections INTEGER;
    v_pg_stat_statements_max INTEGER;
    v_cpu_count INTEGER;
    v_shared_buffers_mb INTEGER;
    v_connection_pct NUMERIC;
    v_pg_cron_exists BOOLEAN;
BEGIN
    BEGIN
        v_cpu_count := (SELECT setting::integer FROM pg_settings WHERE name = 'max_worker_processes');
        IF v_cpu_count < 4 THEN
            RETURN QUERY SELECT
                'System Resources'::text,
                'CAUTION'::text,
                format('Detected %s worker processes (CPU estimate)', v_cpu_count),
                'Flight recorder overhead (0.5%%) is acceptable but consider testing in staging first. Systems with <4 cores have less overhead margin.'::text;
        ELSE
            RETURN QUERY SELECT
                'System Resources'::text,
                'GO'::text,
                format('Detected %s worker processes', v_cpu_count),
                'System has adequate resources for always-on monitoring.'::text;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            'System Resources'::text,
            'GO'::text,
            'Unable to detect CPU count',
            'Verify your system has ≥4 CPU cores for comfortable always-on operation.'::text;
    END;
    SELECT setting::integer INTO v_max_connections FROM pg_settings WHERE name = 'max_connections';
    SELECT count(*) INTO v_current_connections FROM pg_stat_activity;
    v_connection_pct := (v_current_connections::numeric / v_max_connections) * 100;
    IF v_connection_pct > 70 THEN
        RETURN QUERY SELECT
            'Connection Headroom'::text,
            'CAUTION'::text,
            format('Currently %s%% of max_connections (%s/%s)', round(v_connection_pct, 1), v_current_connections, v_max_connections),
            'System frequently near max_connections. Adaptive mode will trigger often. Consider increasing max_connections or monitoring connection patterns.'::text;
    ELSE
        RETURN QUERY SELECT
            'Connection Headroom'::text,
            'GO'::text,
            format('Currently %s%% of max_connections (%s/%s)', round(v_connection_pct, 1), v_current_connections, v_max_connections),
            'Adequate connection headroom for normal operations.'::text;
    END IF;
    BEGIN
        SELECT setting::integer INTO v_pg_stat_statements_max
        FROM pg_settings WHERE name = 'pg_stat_statements.max';
        IF v_pg_stat_statements_max < 5000 THEN
            RETURN QUERY SELECT
                'pg_stat_statements Budget'::text,
                'NO-GO'::text,
                format('pg_stat_statements.max = %s (too low)', v_pg_stat_statements_max),
                'Flight recorder will consume 20-40% of statement budget. Increase to at least 10,000: ALTER SYSTEM SET pg_stat_statements.max = 10000; (requires restart)'::text;
        ELSIF v_pg_stat_statements_max < 10000 THEN
            RETURN QUERY SELECT
                'pg_stat_statements Budget'::text,
                'CAUTION'::text,
                format('pg_stat_statements.max = %s (minimal)', v_pg_stat_statements_max),
                'Flight recorder will consume 20-40% of statement budget. Consider increasing to 10,000+ for comfortable operation.'::text;
        ELSE
            RETURN QUERY SELECT
                'pg_stat_statements Budget'::text,
                'GO'::text,
                format('pg_stat_statements.max = %s', v_pg_stat_statements_max),
                'Adequate statement tracking capacity.'::text;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            'pg_stat_statements Budget'::text,
            'CAUTION'::text,
            'pg_stat_statements extension not found or not configured',
            'Statement collection will be disabled (statements_enabled=auto). This is acceptable if you don''t need query-level metrics.'::text;
    END;
    BEGIN
        SELECT setting::integer INTO v_shared_buffers_mb
        FROM pg_settings WHERE name = 'shared_buffers';
        v_shared_buffers_mb := (v_shared_buffers_mb * 8) / 1024;
        RETURN QUERY SELECT
            'Storage Overhead'::text,
            'GO'::text,
            'Ring buffer memory depends on slot count (default 120 slots, configurable 72-2880). Aggregates: ~2-3 GB per week (7-day retention).',
            'UNLOGGED ring buffers minimize WAL overhead. Ring buffers self-clean automatically. Daily aggregate cleanup prevents unbounded growth.'::text;
    END;
    SELECT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'pg_cron'
    ) INTO v_pg_cron_exists;
    IF v_pg_cron_exists THEN
        RETURN QUERY SELECT
            'Scheduling (pg_cron)'::text,
            'GO'::text,
            'pg_cron extension detected',
            'Automatic scheduling will work. Flight recorder will run automatically every minute.'::text;
    ELSE
        RETURN QUERY SELECT
            'Scheduling (pg_cron)'::text,
            'CAUTION'::text,
            'pg_cron extension not found',
            'You will need to schedule pgfr_record.sample() and pgfr_record.snapshot() manually via external cron or pg_agent.'::text;
    END IF;
    RETURN QUERY SELECT
        'Safety Mechanisms'::text,
        'GO'::text,
        'Circuit breaker, adaptive mode, timeouts all enabled by default',
        'Flight recorder will auto-reduce overhead under stress.'::text;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.preflight_check() IS

'Pre-installation validation checks. Returns component status (GO/CAUTION/NO-GO). For summary, use preflight_check_with_summary().';
-- Executes preflight validation checks and appends a summary row indicating overall system readiness (READY, CAUTION, or NO-GO)
CREATE OR REPLACE FUNCTION pgfr_analyze.preflight_check_with_summary()
RETURNS TABLE(
    check_name TEXT,
    status TEXT,
    details TEXT,
    recommendation TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_nogo_count INTEGER;
    v_caution_count INTEGER;
BEGIN
    RETURN QUERY SELECT * FROM pgfr_analyze.preflight_check();
    SELECT
        count(*) FILTER (WHERE c.status = 'NO-GO'),
        count(*) FILTER (WHERE c.status = 'CAUTION')
    INTO v_nogo_count, v_caution_count
    FROM pgfr_analyze.preflight_check() c;
    IF v_nogo_count > 0 THEN
        RETURN QUERY SELECT
            '=== SUMMARY ==='::text,
            'NO-GO'::text,
            format('%s critical issues detected', v_nogo_count),
            'Address NO-GO items before enabling always-on monitoring. See recommendations above.'::text;
    ELSIF v_caution_count > 0 THEN
        RETURN QUERY SELECT
            '=== SUMMARY ==='::text,
            'PROCEED WITH CAUTION'::text,
            format('%s cautions detected', v_caution_count),
            'System is acceptable for always-on monitoring but consider addressing cautions. Test in staging first if possible.'::text;
    ELSE
        RETURN QUERY SELECT
            '=== SUMMARY ==='::text,
            'READY FOR PRODUCTION'::text,
            'All checks passed',
            'System is well-suited for "set and forget" always-on monitoring. Run quarterly_review() every 3 months to verify continued health.'::text;
    END IF;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.preflight_check_with_summary() IS

'Pre-installation validation with summary. Calls preflight_check() twice - once for results, once to count. More expensive but includes summary row.';
-- Generates a comprehensive quarterly health review of the pgfr_record system
-- Assesses collection performance, storage consumption, reliability, circuit breaker activity, and data freshness
CREATE OR REPLACE FUNCTION pgfr_analyze.quarterly_review()
RETURNS TABLE(
    component TEXT,
    status TEXT,
    metric TEXT,
    assessment TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_avg_duration_ms NUMERIC;
    v_max_duration_ms NUMERIC;
    v_skipped_count INTEGER;
    v_total_count INTEGER;
    v_schema_size_mb NUMERIC;
    v_last_sample TIMESTAMPTZ;
    v_last_snapshot TIMESTAMPTZ;
    v_circuit_breaker_trips INTEGER;
    v_failed_collections INTEGER;
    v_sample_count INTEGER;
BEGIN
    RETURN QUERY SELECT
        '=== FLIGHT RECORDER QUARTERLY REVIEW ==='::text,
        'INFO'::text,
        format('Review period: Last 90 days | Generated: %s', now()::text),
        'This review validates flight recorder health for continued always-on operation.'::text;
    SELECT
        avg(duration_ms),
        max(duration_ms),
        count(*) FILTER (WHERE skipped),
        count(*)
    INTO v_avg_duration_ms, v_max_duration_ms, v_skipped_count, v_total_count
    FROM pgfr_record.collection_stats
    WHERE started_at > now() - interval '30 days'
      AND collection_type = 'sample';
    IF v_avg_duration_ms IS NULL THEN
        RETURN QUERY SELECT
            '1. Collection Performance'::text,
            'ERROR'::text,
            'No collections in last 30 days',
            'Flight recorder may not be running. Check pg_cron jobs.'::text;
    ELSIF v_avg_duration_ms < 200 THEN
        RETURN QUERY SELECT
            '1. Collection Performance'::text,
            'EXCELLENT'::text,
            format('Avg: %sms | Max: %sms | Skipped: %s/%s',
                   round(v_avg_duration_ms), round(v_max_duration_ms), v_skipped_count, v_total_count),
            'Collection overhead is minimal. No action needed.'::text;
    ELSIF v_avg_duration_ms < 500 THEN
        RETURN QUERY SELECT
            '1. Collection Performance'::text,
            'GOOD'::text,
            format('Avg: %sms | Max: %sms | Skipped: %s/%s',
                   round(v_avg_duration_ms), round(v_max_duration_ms), v_skipped_count, v_total_count),
            'Collection overhead is acceptable. Continue monitoring.'::text;
    ELSE
        RETURN QUERY SELECT
            '1. Collection Performance'::text,
            'REVIEW NEEDED'::text,
            format('Avg: %sms | Max: %sms | Skipped: %s/%s',
                   round(v_avg_duration_ms), round(v_max_duration_ms), v_skipped_count, v_total_count),
            'Collections are slower than expected. Consider: (1) switching to light mode, (2) increasing sample_interval_seconds to 300, or (3) checking for system bottlenecks.'::text;
    END IF;
    SELECT schema_size_mb INTO v_schema_size_mb FROM pgfr_record._check_schema_size();
    SELECT count(*) INTO v_sample_count FROM pgfr_record.wait_samples;
    IF v_schema_size_mb < 3000 THEN
        RETURN QUERY SELECT
            '2. Storage Consumption'::text,
            'EXCELLENT'::text,
            format('%s MB | %s samples', round(v_schema_size_mb), v_sample_count),
            'Storage usage is healthy. Daily cleanup is working correctly.'::text;
    ELSIF v_schema_size_mb < 6000 THEN
        RETURN QUERY SELECT
            '2. Storage Consumption'::text,
            'GOOD'::text,
            format('%s MB | %s samples', round(v_schema_size_mb), v_sample_count),
            'Storage usage is acceptable. Monitor growth trend.'::text;
    ELSE
        RETURN QUERY SELECT
            '2. Storage Consumption'::text,
            'REVIEW NEEDED'::text,
            format('%s MB | %s samples', round(v_schema_size_mb), v_sample_count),
            'Storage usage is high. Run cleanup() or reduce retention_samples_days.'::text;
    END IF;
    SELECT
        count(*) FILTER (WHERE NOT success AND NOT skipped)
    INTO v_failed_collections
    FROM pgfr_record.collection_stats
    WHERE started_at > now() - interval '90 days';
    IF v_failed_collections = 0 THEN
        RETURN QUERY SELECT
            '3. Collection Reliability'::text,
            'EXCELLENT'::text,
            format('0 failed collections in 90 days'),
            'Flight recorder is operating reliably.'::text;
    ELSIF v_failed_collections < 10 THEN
        RETURN QUERY SELECT
            '3. Collection Reliability'::text,
            'GOOD'::text,
            format('%s failed collections in 90 days', v_failed_collections),
            'Minimal failures detected. This is normal and acceptable.'::text;
    ELSE
        RETURN QUERY SELECT
            '3. Collection Reliability'::text,
            'REVIEW NEEDED'::text,
            format('%s failed collections in 90 days', v_failed_collections),
            'Frequent failures detected. Check collection_stats for error patterns.'::text;
    END IF;
    SELECT count(*) INTO v_circuit_breaker_trips
    FROM pgfr_record.collection_stats
    WHERE skipped = true
      AND skipped_reason LIKE '%Circuit breaker%'
      AND started_at > now() - interval '90 days';
    IF v_circuit_breaker_trips = 0 THEN
        RETURN QUERY SELECT
            '4. Circuit Breaker Activity'::text,
            'EXCELLENT'::text,
            '0 trips in 90 days',
            'System has not experienced collection stress.'::text;
    ELSIF v_circuit_breaker_trips < 20 THEN
        RETURN QUERY SELECT
            '4. Circuit Breaker Activity'::text,
            'GOOD'::text,
            format('%s trips in 90 days', v_circuit_breaker_trips),
            'Circuit breaker has triggered occasionally. This is normal during temporary load spikes.'::text;
    ELSE
        RETURN QUERY SELECT
            '4. Circuit Breaker Activity'::text,
            'REVIEW NEEDED'::text,
            format('%s trips in 90 days', v_circuit_breaker_trips),
            'Frequent circuit breaker trips indicate system stress. Consider switching to light mode permanently.'::text;
    END IF;
    SELECT pgfr_record.epoch() + max(sample_ts) * interval '1 second' INTO v_last_sample FROM pgfr_record.wait_samples;
    SELECT max(captured_at) INTO v_last_snapshot FROM pgfr_record.snapshots;
    IF v_last_sample > now() - interval '10 minutes' AND v_last_snapshot > now() - interval '15 minutes' THEN
        RETURN QUERY SELECT
            '5. Data Freshness'::text,
            'EXCELLENT'::text,
            format('Last sample: %s ago | Last snapshot: %s ago',
                   age(now(), v_last_sample)::text, age(now(), v_last_snapshot)::text),
            'Collections are running on schedule.'::text;
    ELSE
        RETURN QUERY SELECT
            '5. Data Freshness'::text,
            'ERROR'::text,
            format('Last sample: %s ago | Last snapshot: %s ago',
                   age(now(), v_last_sample)::text, age(now(), v_last_snapshot)::text),
            'Collections are stale. Check pg_cron jobs: SELECT * FROM cron.job WHERE jobname LIKE ''pgfr_%'';'::text;
    END IF;
    DECLARE
        v_missing_count INTEGER;
        v_inactive_count INTEGER;
        v_missing_jobs TEXT[];
        v_inactive_jobs TEXT[];
    BEGIN
        WITH required_jobs AS (
            SELECT unnest(ARRAY[
                'pgfr_sample',
                'pgfr_snapshot',
                'pgfr_flush',
                'pgfr_cleanup'
            ]) AS job_name
        )
        SELECT
            count(*) FILTER (WHERE j.jobid IS NULL),
            count(*) FILTER (WHERE j.jobid IS NOT NULL AND NOT j.active),
            array_agg(r.job_name) FILTER (WHERE j.jobid IS NULL),
            array_agg(r.job_name) FILTER (WHERE j.jobid IS NOT NULL AND NOT j.active)
        INTO v_missing_count, v_inactive_count, v_missing_jobs, v_inactive_jobs
        FROM required_jobs r
        LEFT JOIN cron.job j ON j.jobname = r.job_name;
        IF v_missing_count = 0 AND v_inactive_count = 0 THEN
            RETURN QUERY SELECT
                '6. pg_cron Job Health'::text,
                'EXCELLENT'::text,
                '4/4 jobs active (sample, snapshot, flush, cleanup)',
                'All pg_cron jobs are running correctly.'::text;
        ELSIF v_missing_count > 0 THEN
            RETURN QUERY SELECT
                '6. pg_cron Job Health'::text,
                'CRITICAL'::text,
                format('%s/%s jobs missing: %s', v_missing_count, 4, array_to_string(v_missing_jobs, ', ')),
                'CRITICAL: Flight recorder is not collecting data. Run pgfr_record.enable() to restore.'::text;
        ELSE
            RETURN QUERY SELECT
                '6. pg_cron Job Health'::text,
                'CRITICAL'::text,
                format('%s/%s jobs inactive: %s', v_inactive_count, 4, array_to_string(v_inactive_jobs, ', ')),
                'CRITICAL: pg_cron jobs exist but are disabled. Run pgfr_record.enable() to reactivate.'::text;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            '7. pg_cron Job Health'::text,
            'ERROR'::text,
            format('Failed to check pg_cron jobs: %s', SQLERRM),
            'Verify pg_cron extension is installed and accessible.'::text;
    END;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.quarterly_review() IS

'Quarterly health check for flight recorder. Returns component metrics (EXCELLENT/GOOD/REVIEW NEEDED/ERROR). For summary, use quarterly_review_with_summary().';
-- Quarterly health check with summary. Appends overall health status (HEALTHY or ACTION REQUIRED) based on count of ERROR or REVIEW NEEDED items detected
-- More expensive than quarterly_review() as it calls it twice - once for detailed results, once to count critical issues
CREATE OR REPLACE FUNCTION pgfr_analyze.quarterly_review_with_summary()
RETURNS TABLE(
    component TEXT,
    status TEXT,
    metric TEXT,
    assessment TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_issues_count INTEGER;
BEGIN
    RETURN QUERY SELECT * FROM pgfr_analyze.quarterly_review();
    SELECT count(*) INTO v_issues_count
    FROM pgfr_analyze.quarterly_review() qr
    WHERE qr.status IN ('ERROR', 'REVIEW NEEDED');
    IF v_issues_count = 0 THEN
        RETURN QUERY SELECT
            '=== QUARTERLY REVIEW SUMMARY ==='::text,
            'HEALTHY'::text,
            'All metrics within acceptable parameters',
            'Flight recorder is operating as expected. Schedule next review in 3 months. No action required.'::text;
    ELSE
        RETURN QUERY SELECT
            '=== QUARTERLY REVIEW SUMMARY ==='::text,
            'ACTION REQUIRED'::text,
            format('%s items need review', v_issues_count),
            'Address items marked ERROR or REVIEW NEEDED above. Run config_recommendations() for specific tuning suggestions.'::text;
    END IF;
END;
$$;
COMMENT ON FUNCTION pgfr_analyze.quarterly_review_with_summary() IS

'Quarterly health check with summary. Calls quarterly_review() twice - once for results, once to count. More expensive but includes summary row.';
-- Analyzes database resource capacity metrics (connections, memory, storage, transactions) over a time window
-- Returns utilization status with actionable recommendations
