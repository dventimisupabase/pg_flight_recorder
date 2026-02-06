-- =============================================================================
-- pg-flight-recorder: Reporting & Analysis Functions
-- =============================================================================
-- Optional add-on for install.sql. Provides analysis, forensics, and reporting.
-- Requires: install.sql must be run first (creates tables and core functions).
--
-- Install: psql -f reporting.sql
-- =============================================================================

-- Verify core is installed
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM flight_recorder.config WHERE key = 'schema_version') THEN
        RAISE EXCEPTION 'Flight Recorder core not installed. Run install.sql first.';
    END IF;
END $$;

-- =============================================================================
-- Autovacuum Observer Rate Calculation Functions (v2.7)
-- =============================================================================

-- Calculates the rate of dead tuple accumulation over a time window
-- Returns tuples per second, or NULL if insufficient data
CREATE OR REPLACE FUNCTION flight_recorder.dead_tuple_growth_rate(
    p_relid OID,
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_first_snapshot RECORD;
    v_last_snapshot RECORD;
    v_delta_tuples BIGINT;
    v_delta_seconds NUMERIC;
BEGIN
    -- Get earliest snapshot within window
    SELECT ts.n_dead_tup, s.captured_at
    INTO v_first_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at ASC
    LIMIT 1;

    -- Get latest snapshot
    SELECT ts.n_dead_tup, s.captured_at
    INTO v_last_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Need at least 2 distinct snapshots
    IF v_first_snapshot.captured_at IS NULL OR v_last_snapshot.captured_at IS NULL
       OR v_first_snapshot.captured_at = v_last_snapshot.captured_at THEN
        RETURN NULL;
    END IF;

    v_delta_tuples := COALESCE(v_last_snapshot.n_dead_tup, 0) - COALESCE(v_first_snapshot.n_dead_tup, 0);
    v_delta_seconds := EXTRACT(EPOCH FROM (v_last_snapshot.captured_at - v_first_snapshot.captured_at));

    IF v_delta_seconds <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_delta_tuples::numeric / v_delta_seconds, 4);
END;
$$;
COMMENT ON FUNCTION flight_recorder.dead_tuple_growth_rate(OID, INTERVAL) IS 'Returns dead tuple growth rate (tuples/second) for a table over a time window';

-- Calculates the rate of table size growth in bytes per second over a time window
-- Useful for detecting bloat accumulation between vacuums
CREATE OR REPLACE FUNCTION flight_recorder.table_size_growth_rate(
    p_relid OID,
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_first_snapshot RECORD;
    v_last_snapshot RECORD;
    v_delta_bytes BIGINT;
    v_delta_seconds NUMERIC;
BEGIN
    -- Get earliest snapshot within window
    SELECT ts.table_size_bytes, s.captured_at
    INTO v_first_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
      AND ts.table_size_bytes IS NOT NULL
    ORDER BY s.captured_at ASC
    LIMIT 1;

    -- Get latest snapshot
    SELECT ts.table_size_bytes, s.captured_at
    INTO v_last_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND ts.table_size_bytes IS NOT NULL
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Need at least two snapshots to calculate rate
    IF v_first_snapshot IS NULL OR v_last_snapshot IS NULL THEN
        RETURN NULL;
    END IF;

    v_delta_bytes := COALESCE(v_last_snapshot.table_size_bytes, 0) - COALESCE(v_first_snapshot.table_size_bytes, 0);
    v_delta_seconds := EXTRACT(EPOCH FROM (v_last_snapshot.captured_at - v_first_snapshot.captured_at));

    IF v_delta_seconds <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_delta_bytes::numeric / v_delta_seconds, 4);
END;
$$;
COMMENT ON FUNCTION flight_recorder.table_size_growth_rate(OID, INTERVAL) IS 'Returns table size growth rate (bytes/second) for a table over a time window. Useful for detecting bloat accumulation.';

-- Estimates table bloat without requiring pgstattuple extension
-- Uses heuristics based on dead tuple ratio and size metrics
-- Returns estimated bloat percentage and wasted bytes
CREATE OR REPLACE FUNCTION flight_recorder.estimate_table_bloat(
    p_relid OID DEFAULT NULL
)
RETURNS TABLE(
    schemaname          TEXT,
    relname             TEXT,
    relid               OID,
    table_size_bytes    BIGINT,
    total_size_bytes    BIGINT,
    indexes_size_bytes  BIGINT,
    n_live_tup          BIGINT,
    n_dead_tup          BIGINT,
    dead_tuple_pct      NUMERIC,
    est_bytes_per_row   NUMERIC,
    est_live_data_bytes BIGINT,
    est_bloat_bytes     BIGINT,
    est_bloat_pct       NUMERIC,
    bloat_status        TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    WITH latest AS (
        SELECT DISTINCT ON (ts.relid)
            COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
            ts.relid,
            ts.table_size_bytes,
            ts.total_size_bytes,
            ts.indexes_size_bytes,
            ts.n_live_tup,
            ts.n_dead_tup
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE ts.table_size_bytes IS NOT NULL
          AND (p_relid IS NULL OR ts.relid = p_relid)
        ORDER BY ts.relid, s.captured_at DESC
    ),
    with_estimates AS (
        SELECT
            l.*,
            -- Dead tuple percentage
            CASE
                WHEN COALESCE(l.n_live_tup, 0) + COALESCE(l.n_dead_tup, 0) > 0
                THEN round(100.0 * COALESCE(l.n_dead_tup, 0) /
                     (COALESCE(l.n_live_tup, 0) + COALESCE(l.n_dead_tup, 0)), 1)
                ELSE 0
            END AS dead_pct,
            -- Estimated bytes per row (if we have live tuples and size data)
            CASE
                WHEN COALESCE(l.n_live_tup, 0) > 100 AND COALESCE(l.table_size_bytes, 0) > 0
                THEN round(l.table_size_bytes::numeric / l.n_live_tup, 2)
                ELSE NULL
            END AS bytes_per_row
        FROM latest l
    )
    SELECT
        e.schemaname::TEXT,
        e.relname::TEXT,
        e.relid,
        e.table_size_bytes,
        e.total_size_bytes,
        e.indexes_size_bytes,
        e.n_live_tup,
        e.n_dead_tup,
        e.dead_pct,
        e.bytes_per_row,
        -- Estimated live data bytes (rough: live_tuples * bytes_per_row, adjusted for overhead)
        CASE
            WHEN e.bytes_per_row IS NOT NULL AND e.n_live_tup > 0
            THEN (e.n_live_tup * e.bytes_per_row * 0.85)::BIGINT  -- 15% overhead estimate
            ELSE NULL
        END AS live_data_bytes,
        -- Estimated bloat bytes
        CASE
            WHEN e.bytes_per_row IS NOT NULL AND e.n_live_tup > 0
            THEN greatest(0, e.table_size_bytes - (e.n_live_tup * e.bytes_per_row * 0.85)::BIGINT)
            ELSE NULL
        END AS bloat_bytes,
        -- Estimated bloat percentage
        CASE
            WHEN e.bytes_per_row IS NOT NULL AND e.n_live_tup > 0 AND e.table_size_bytes > 0
            THEN round(100.0 * greatest(0, e.table_size_bytes - (e.n_live_tup * e.bytes_per_row * 0.85)::BIGINT) / e.table_size_bytes, 1)
            ELSE e.dead_pct  -- Fall back to dead tuple percentage as bloat proxy
        END AS bloat_pct,
        -- Status classification
        CASE
            WHEN e.dead_pct >= 50 THEN 'critical'
            WHEN e.dead_pct >= 25 THEN 'high'
            WHEN e.dead_pct >= 10 THEN 'moderate'
            WHEN e.dead_pct >= 5 THEN 'low'
            ELSE 'minimal'
        END::TEXT AS status
    FROM with_estimates e
    ORDER BY e.dead_pct DESC, e.table_size_bytes DESC;
END;
$$;
COMMENT ON FUNCTION flight_recorder.estimate_table_bloat(OID) IS 'Estimates table bloat without pgstattuple. Uses dead tuple ratio and size metrics. Pass NULL or omit argument for all tables.';

-- Generates a bloat report with trends and recommendations
-- Compares current state to historical data to detect bloat accumulation
CREATE OR REPLACE FUNCTION flight_recorder.bloat_report(
    p_window INTERVAL DEFAULT '24 hours'::INTERVAL
)
RETURNS TABLE(
    schemaname          TEXT,
    relname             TEXT,
    current_size        TEXT,
    size_change         TEXT,
    dead_tuple_pct      NUMERIC,
    dead_tuple_trend    TEXT,
    bloat_status        TEXT,
    recommendation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    WITH current_stats AS (
        SELECT * FROM flight_recorder.estimate_table_bloat(NULL)
    ),
    historical AS (
        SELECT DISTINCT ON (ts.relid)
            ts.relid,
            ts.table_size_bytes AS old_size,
            ts.n_dead_tup AS old_dead_tup,
            ts.n_live_tup AS old_live_tup
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at <= now() - p_window
          AND ts.table_size_bytes IS NOT NULL
        ORDER BY ts.relid, s.captured_at DESC
    )
    SELECT
        c.schemaname,
        c.relname,
        pg_size_pretty(c.table_size_bytes) AS current_size,
        CASE
            WHEN h.old_size IS NULL THEN 'N/A (no history)'
            WHEN c.table_size_bytes > h.old_size
            THEN '+' || pg_size_pretty(c.table_size_bytes - h.old_size)
            WHEN c.table_size_bytes < h.old_size
            THEN '-' || pg_size_pretty(h.old_size - c.table_size_bytes)
            ELSE 'unchanged'
        END AS size_change,
        c.dead_tuple_pct,
        CASE
            WHEN h.old_dead_tup IS NULL THEN 'N/A'
            WHEN COALESCE(c.n_dead_tup, 0) > COALESCE(h.old_dead_tup, 0) * 1.5 THEN 'increasing rapidly'
            WHEN COALESCE(c.n_dead_tup, 0) > COALESCE(h.old_dead_tup, 0) THEN 'increasing'
            WHEN COALESCE(c.n_dead_tup, 0) < COALESCE(h.old_dead_tup, 0) THEN 'decreasing'
            ELSE 'stable'
        END AS dead_tuple_trend,
        c.bloat_status,
        CASE
            WHEN c.bloat_status = 'critical'
            THEN 'URGENT: Run VACUUM FULL or pg_repack immediately'
            WHEN c.bloat_status = 'high'
            THEN 'Run VACUUM FULL or pg_repack soon'
            WHEN c.bloat_status = 'moderate' AND
                 COALESCE(c.n_dead_tup, 0) > COALESCE(h.old_dead_tup, 0) * 1.5
            THEN 'Check autovacuum settings - dead tuples accumulating'
            WHEN c.bloat_status = 'moderate'
            THEN 'Monitor - consider VACUUM if trend continues'
            ELSE 'No action needed'
        END AS recommendation
    FROM current_stats c
    LEFT JOIN historical h ON h.relid = c.relid
    WHERE c.table_size_bytes > 1024 * 1024  -- Only tables > 1MB
    ORDER BY
        CASE c.bloat_status
            WHEN 'critical' THEN 1
            WHEN 'high' THEN 2
            WHEN 'moderate' THEN 3
            WHEN 'low' THEN 4
            ELSE 5
        END,
        c.table_size_bytes DESC;
END;
$$;
COMMENT ON FUNCTION flight_recorder.bloat_report(INTERVAL) IS 'Generates a bloat report with size trends and recommendations. Compares current state to historical data over the specified window.';

-- Calculates the rate of row modifications (INSERT/UPDATE/DELETE) over a time window
-- Returns modifications per second, or NULL if insufficient data
CREATE OR REPLACE FUNCTION flight_recorder.modification_rate(
    p_relid OID,
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_first_snapshot RECORD;
    v_last_snapshot RECORD;
    v_delta_mods BIGINT;
    v_delta_seconds NUMERIC;
BEGIN
    -- Get earliest snapshot within window
    SELECT ts.n_tup_ins, ts.n_tup_upd, ts.n_tup_del, s.captured_at
    INTO v_first_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at ASC
    LIMIT 1;

    -- Get latest snapshot
    SELECT ts.n_tup_ins, ts.n_tup_upd, ts.n_tup_del, s.captured_at
    INTO v_last_snapshot
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
      AND s.captured_at >= now() - p_window
    ORDER BY s.captured_at DESC
    LIMIT 1;

    -- Need at least 2 distinct snapshots
    IF v_first_snapshot.captured_at IS NULL OR v_last_snapshot.captured_at IS NULL
       OR v_first_snapshot.captured_at = v_last_snapshot.captured_at THEN
        RETURN NULL;
    END IF;

    v_delta_mods := (COALESCE(v_last_snapshot.n_tup_ins, 0) + COALESCE(v_last_snapshot.n_tup_upd, 0) + COALESCE(v_last_snapshot.n_tup_del, 0))
                  - (COALESCE(v_first_snapshot.n_tup_ins, 0) + COALESCE(v_first_snapshot.n_tup_upd, 0) + COALESCE(v_first_snapshot.n_tup_del, 0));
    v_delta_seconds := EXTRACT(EPOCH FROM (v_last_snapshot.captured_at - v_first_snapshot.captured_at));

    IF v_delta_seconds <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_delta_mods::numeric / v_delta_seconds, 4);
END;
$$;
COMMENT ON FUNCTION flight_recorder.modification_rate(OID, INTERVAL) IS 'Returns row modification rate (modifications/second) for a table over a time window';

-- Calculates the HOT (Heap-Only Tuple) update ratio for a table
-- Higher ratio indicates more efficient updates that don't require index maintenance
-- Returns percentage (0-100), or NULL if no updates
CREATE OR REPLACE FUNCTION flight_recorder.hot_update_ratio(
    p_relid OID
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_n_tup_upd BIGINT;
    v_n_tup_hot_upd BIGINT;
BEGIN
    -- Get latest snapshot for this table
    SELECT ts.n_tup_upd, ts.n_tup_hot_upd
    INTO v_n_tup_upd, v_n_tup_hot_upd
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
    ORDER BY s.captured_at DESC
    LIMIT 1;

    IF v_n_tup_upd IS NULL OR v_n_tup_upd = 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND((COALESCE(v_n_tup_hot_upd, 0)::numeric / v_n_tup_upd) * 100, 2);
END;
$$;
COMMENT ON FUNCTION flight_recorder.hot_update_ratio(OID) IS 'Returns HOT update percentage (0-100) for a table based on latest snapshot';

-- Estimates time until dead tuple budget is exhausted based on current growth rate
-- Returns interval until budget exceeded, NULL if insufficient data or no growth
CREATE OR REPLACE FUNCTION flight_recorder.time_to_budget_exhaustion(
    p_relid OID,
    p_budget BIGINT
)
RETURNS INTERVAL
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_current_dead_tuples BIGINT;
    v_growth_rate NUMERIC;
    v_remaining_budget BIGINT;
    v_seconds_to_exhaustion NUMERIC;
BEGIN
    -- Get current dead tuple count
    SELECT ts.n_dead_tup
    INTO v_current_dead_tuples
    FROM flight_recorder.table_snapshots ts
    JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
    WHERE ts.relid = p_relid
    ORDER BY s.captured_at DESC
    LIMIT 1;

    IF v_current_dead_tuples IS NULL THEN
        RETURN NULL;
    END IF;

    -- Get growth rate over last hour
    v_growth_rate := flight_recorder.dead_tuple_growth_rate(p_relid, '1 hour'::interval);

    -- If no growth rate data or rate is zero/negative, can't estimate
    IF v_growth_rate IS NULL OR v_growth_rate <= 0 THEN
        RETURN NULL;
    END IF;

    v_remaining_budget := p_budget - v_current_dead_tuples;

    -- Already over budget
    IF v_remaining_budget <= 0 THEN
        RETURN '0 seconds'::interval;
    END IF;

    v_seconds_to_exhaustion := v_remaining_budget::numeric / v_growth_rate;

    RETURN make_interval(secs => v_seconds_to_exhaustion);
END;
$$;
COMMENT ON FUNCTION flight_recorder.time_to_budget_exhaustion(OID, BIGINT) IS 'Estimates time until dead tuple budget is exhausted based on growth rate';

-- Calculates the rate of OID consumption over a time window
-- Returns OIDs per second based on max_catalog_oid changes in snapshots
CREATE OR REPLACE FUNCTION flight_recorder.oid_consumption_rate(
    p_window INTERVAL
)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_first_snapshot RECORD;
    v_last_snapshot RECORD;
    v_delta_oids BIGINT;
    v_delta_seconds NUMERIC;
BEGIN
    SELECT max_catalog_oid, captured_at
    INTO v_first_snapshot
    FROM flight_recorder.snapshots
    WHERE captured_at >= now() - p_window
      AND max_catalog_oid IS NOT NULL
    ORDER BY captured_at ASC
    LIMIT 1;

    SELECT max_catalog_oid, captured_at
    INTO v_last_snapshot
    FROM flight_recorder.snapshots
    WHERE captured_at >= now() - p_window
      AND max_catalog_oid IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;

    IF v_first_snapshot.captured_at IS NULL OR v_last_snapshot.captured_at IS NULL
       OR v_first_snapshot.captured_at = v_last_snapshot.captured_at THEN
        RETURN NULL;
    END IF;

    v_delta_oids := v_last_snapshot.max_catalog_oid - v_first_snapshot.max_catalog_oid;
    v_delta_seconds := EXTRACT(EPOCH FROM (v_last_snapshot.captured_at - v_first_snapshot.captured_at));

    IF v_delta_seconds <= 0 THEN
        RETURN NULL;
    END IF;

    RETURN ROUND(v_delta_oids::numeric / v_delta_seconds, 6);
END;
$$;
COMMENT ON FUNCTION flight_recorder.oid_consumption_rate(INTERVAL) IS 'Returns OID consumption rate (OIDs/second) over a time window';

-- Estimates time until OID exhaustion based on current consumption rate
-- OIDs are 32-bit unsigned integers (max ~4.3 billion) that are not recycled
CREATE OR REPLACE FUNCTION flight_recorder.time_to_oid_exhaustion()
RETURNS INTERVAL
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_current_max_oid BIGINT;
    v_consumption_rate NUMERIC;
    v_oid_max BIGINT := 4294967295;  -- 2^32 - 1
    v_remaining_oids BIGINT;
    v_seconds_to_exhaustion NUMERIC;
BEGIN
    SELECT max_catalog_oid
    INTO v_current_max_oid
    FROM flight_recorder.snapshots
    WHERE max_catalog_oid IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;

    IF v_current_max_oid IS NULL THEN
        RETURN NULL;
    END IF;

    -- Use 1-hour window for rate calculation
    v_consumption_rate := flight_recorder.oid_consumption_rate('1 hour'::interval);

    IF v_consumption_rate IS NULL OR v_consumption_rate <= 0 THEN
        RETURN NULL;  -- No consumption or negative rate
    END IF;

    v_remaining_oids := v_oid_max - v_current_max_oid;

    IF v_remaining_oids <= 0 THEN
        RETURN '0 seconds'::interval;
    END IF;

    v_seconds_to_exhaustion := v_remaining_oids::numeric / v_consumption_rate;

    RETURN make_interval(secs => v_seconds_to_exhaustion);
END;
$$;
COMMENT ON FUNCTION flight_recorder.time_to_oid_exhaustion() IS 'Estimates time until OID exhaustion based on consumption rate over the last hour';

-- =============================================================================
-- End Autovacuum Observer Functions
-- =============================================================================

-- Analyzes database metrics within a time window and reports detected anomalies (checkpoints, buffer pressure, lock contention, etc.)
-- Returns anomalies with severity levels and actionable remediation recommendations
CREATE OR REPLACE FUNCTION flight_recorder.anomaly_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    anomaly_type        TEXT,
    severity            TEXT,
    description         TEXT,
    metric_value        TEXT,
    threshold           TEXT,
    recommendation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cmp RECORD;
    v_wait_pct NUMERIC;
    v_lock_count INTEGER;
    v_max_block_duration INTERVAL;
    v_datfrozenxid_age INTEGER;
    v_table_xid_rec RECORD;
    v_freeze_max_age BIGINT;
    v_warning_threshold BIGINT;
    v_critical_threshold BIGINT;
    v_row RECORD;
BEGIN
    -- Get autovacuum_freeze_max_age for XID wraparound thresholds
    SELECT setting::bigint INTO v_freeze_max_age
    FROM pg_settings WHERE name = 'autovacuum_freeze_max_age';
    v_freeze_max_age := COALESCE(v_freeze_max_age, 200000000);
    v_warning_threshold := (v_freeze_max_age * 0.5)::bigint;   -- 50% of freeze_max_age
    v_critical_threshold := (v_freeze_max_age * 0.8)::bigint;  -- 80% of freeze_max_age

    SELECT * INTO v_cmp FROM flight_recorder.compare(p_start_time, p_end_time);
    IF v_cmp.checkpoint_occurred THEN
        anomaly_type := 'CHECKPOINT_DURING_WINDOW';
        severity := CASE
            WHEN v_cmp.ckpt_write_time_ms > 30000 THEN 'high'
            WHEN v_cmp.ckpt_write_time_ms > 10000 THEN 'medium'
            ELSE 'low'
        END;
        description := 'A checkpoint occurred during this time window';
        metric_value := format('write_time: %s ms, sync_time: %s ms',
                              round(v_cmp.ckpt_write_time_ms::numeric, 1),
                              round(v_cmp.ckpt_sync_time_ms::numeric, 1));
        threshold := 'Any checkpoint';
        recommendation := 'Consider increasing max_wal_size or scheduling heavy writes after checkpoint_timeout';
        RETURN NEXT;
    END IF;
    IF v_cmp.ckpt_requested_delta > 0 THEN
        anomaly_type := 'FORCED_CHECKPOINT';
        severity := 'high';
        description := 'WAL exceeded max_wal_size, forcing checkpoint';
        metric_value := format('%s forced checkpoints', v_cmp.ckpt_requested_delta);
        threshold := 'ckpt_requested_delta > 0';
        recommendation := 'Increase max_wal_size to prevent mid-batch checkpoints';
        RETURN NEXT;
    END IF;
    IF COALESCE(v_cmp.bgw_buffers_backend_delta, 0) > 0 THEN
        anomaly_type := 'BUFFER_PRESSURE';
        severity := CASE
            WHEN v_cmp.bgw_buffers_backend_delta > 1000 THEN 'high'
            WHEN v_cmp.bgw_buffers_backend_delta > 100 THEN 'medium'
            ELSE 'low'
        END;
        description := 'Backends forced to write buffers directly (shared_buffers exhaustion)';
        metric_value := format('%s backend buffer writes', v_cmp.bgw_buffers_backend_delta);
        threshold := 'bgw_buffers_backend_delta > 0';
        recommendation := 'Increase shared_buffers, reduce concurrent writers, or use faster storage';
        RETURN NEXT;
    END IF;
    IF COALESCE(v_cmp.bgw_buffers_backend_fsync_delta, 0) > 0 THEN
        anomaly_type := 'BACKEND_FSYNC';
        severity := 'high';
        description := 'Backends forced to perform fsync (severe I/O bottleneck)';
        metric_value := format('%s backend fsyncs', v_cmp.bgw_buffers_backend_fsync_delta);
        threshold := 'bgw_buffers_backend_fsync_delta > 0';
        recommendation := 'Urgent: increase shared_buffers, reduce write load, or upgrade storage';
        RETURN NEXT;
    END IF;
    IF COALESCE(v_cmp.temp_files_delta, 0) > 0 THEN
        anomaly_type := 'TEMP_FILE_SPILLS';
        severity := CASE
            WHEN v_cmp.temp_bytes_delta > 1073741824 THEN 'high'
            WHEN v_cmp.temp_bytes_delta > 104857600 THEN 'medium'
            ELSE 'low'
        END;
        description := 'Queries spilling to temp files (work_mem exhaustion)';
        metric_value := format('%s temp files, %s written',
                              v_cmp.temp_files_delta, v_cmp.temp_bytes_pretty);
        threshold := 'temp_files_delta > 0';
        recommendation := 'Increase work_mem for affected sessions or globally';
        RETURN NEXT;
    END IF;
    SELECT count(DISTINCT blocked_pid), max(blocked_duration)
    INTO v_lock_count, v_max_block_duration
    FROM flight_recorder.lock_samples_ring l
    JOIN flight_recorder.samples_ring s ON s.slot_id = l.slot_id
    WHERE s.captured_at BETWEEN p_start_time AND p_end_time;
    IF v_lock_count > 0 THEN
        anomaly_type := 'LOCK_CONTENTION';
        severity := CASE
            WHEN v_max_block_duration > interval '30 seconds' THEN 'high'
            WHEN v_max_block_duration > interval '5 seconds' THEN 'medium'
            ELSE 'low'
        END;
        description := 'Lock contention detected';
        metric_value := format('%s blocked sessions, max duration: %s',
                              v_lock_count, v_max_block_duration);
        threshold := 'Any lock contention';
        recommendation := 'Check recent_locks for blocking queries; consider shorter transactions';
        RETURN NEXT;
    END IF;
    -- Database-level XID wraparound check
    SELECT datfrozenxid_age INTO v_datfrozenxid_age
    FROM flight_recorder.snapshots
    WHERE captured_at BETWEEN p_start_time AND p_end_time
      AND datfrozenxid_age IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;
    IF v_datfrozenxid_age IS NOT NULL AND v_datfrozenxid_age > v_warning_threshold THEN
        anomaly_type := 'XID_WRAPAROUND_RISK';
        severity := CASE
            WHEN v_datfrozenxid_age > v_critical_threshold THEN 'critical'
            ELSE 'high'
        END;
        description := 'Database approaching transaction ID wraparound';
        metric_value := format('XID age: %s (%s%% of autovacuum_freeze_max_age)',
                              to_char(v_datfrozenxid_age, 'FM999,999,999'),
                              round(v_datfrozenxid_age::numeric / v_freeze_max_age * 100, 1));
        threshold := format('datfrozenxid_age > %s (50%% of %s)',
                           to_char(v_warning_threshold, 'FM999,999,999'),
                           to_char(v_freeze_max_age, 'FM999,999,999'));
        recommendation := 'Run VACUUM FREEZE on large tables or enable more aggressive autovacuum';
        RETURN NEXT;
    END IF;
    -- Table-level XID wraparound check (find tables approaching their threshold)
    -- Each table may have its own autovacuum_freeze_max_age setting
    FOR v_table_xid_rec IN
        SELECT
            COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
            ts.relfrozenxid_age,
            COALESCE(
                (SELECT (regexp_match(opt, 'autovacuum_freeze_max_age=(\d+)'))[1]::bigint
                 FROM unnest(c.reloptions) opt
                 WHERE opt LIKE 'autovacuum_freeze_max_age=%'
                 LIMIT 1),
                v_freeze_max_age
            ) AS table_freeze_max_age
        FROM flight_recorder.table_snapshots ts
        LEFT JOIN pg_class c ON c.oid = ts.relid
        WHERE ts.snapshot_id = (
            SELECT id FROM flight_recorder.snapshots
            WHERE captured_at BETWEEN p_start_time AND p_end_time
            ORDER BY captured_at DESC
            LIMIT 1
        )
          AND ts.relfrozenxid_age IS NOT NULL
        ORDER BY ts.relfrozenxid_age::numeric / COALESCE(
            (SELECT (regexp_match(opt, 'autovacuum_freeze_max_age=(\d+)'))[1]::bigint
             FROM unnest(c.reloptions) opt
             WHERE opt LIKE 'autovacuum_freeze_max_age=%'
             LIMIT 1),
            v_freeze_max_age
        ) DESC
        LIMIT 5  -- Check top 5 tables by relative XID age
    LOOP
        IF v_table_xid_rec.relfrozenxid_age > (v_table_xid_rec.table_freeze_max_age * 0.5)::bigint THEN
            anomaly_type := 'TABLE_XID_WRAPAROUND_RISK';
            severity := CASE
                WHEN v_table_xid_rec.relfrozenxid_age > (v_table_xid_rec.table_freeze_max_age * 0.8)::bigint THEN 'critical'
                ELSE 'high'
            END;
            description := format('Table %s.%s approaching XID wraparound',
                                 v_table_xid_rec.schemaname, v_table_xid_rec.relname);
            metric_value := format('XID age: %s (%s%% of table autovacuum_freeze_max_age=%s)',
                                  to_char(v_table_xid_rec.relfrozenxid_age, 'FM999,999,999'),
                                  round(v_table_xid_rec.relfrozenxid_age::numeric / v_table_xid_rec.table_freeze_max_age * 100, 1),
                                  to_char(v_table_xid_rec.table_freeze_max_age, 'FM999,999,999'));
            threshold := format('relfrozenxid_age > %s (50%% of %s)',
                               to_char((v_table_xid_rec.table_freeze_max_age * 0.5)::bigint, 'FM999,999,999'),
                               to_char(v_table_xid_rec.table_freeze_max_age, 'FM999,999,999'));
            recommendation := format('Run VACUUM FREEZE on %s.%s',
                                    v_table_xid_rec.schemaname, v_table_xid_rec.relname);
            RETURN NEXT;
        END IF;
    END LOOP;

    -- OID exhaustion detection
    -- OIDs are 32-bit unsigned integers (max ~4.3 billion)
    -- Unlike XIDs, OIDs are not recycled - they simply exhaust
    DECLARE
        v_max_catalog_oid BIGINT;
        v_large_object_count BIGINT;
        v_oid_max BIGINT := 4294967295;  -- 2^32 - 1
        v_oid_warning_threshold BIGINT := (v_oid_max * 0.75)::bigint;   -- 75% = ~3.22 billion
        v_oid_critical_threshold BIGINT := (v_oid_max * 0.90)::bigint;  -- 90% = ~3.87 billion
    BEGIN
        SELECT max_catalog_oid, large_object_count
        INTO v_max_catalog_oid, v_large_object_count
        FROM flight_recorder.snapshots
        WHERE captured_at BETWEEN p_start_time AND p_end_time
          AND max_catalog_oid IS NOT NULL
        ORDER BY captured_at DESC
        LIMIT 1;

        IF v_max_catalog_oid IS NOT NULL AND v_max_catalog_oid > v_oid_warning_threshold THEN
            anomaly_type := 'OID_EXHAUSTION_RISK';
            severity := CASE
                WHEN v_max_catalog_oid > v_oid_critical_threshold THEN 'critical'
                ELSE 'high'
            END;
            description := 'Database approaching OID exhaustion';
            metric_value := format('Max catalog OID: %s (%s%% of 4.3 billion), Large objects: %s',
                                  to_char(v_max_catalog_oid, 'FM999,999,999,999'),
                                  round(v_max_catalog_oid::numeric / v_oid_max * 100, 1),
                                  COALESCE(to_char(v_large_object_count, 'FM999,999,999'), 'N/A'));
            threshold := format('max_catalog_oid > %s (75%% of 4,294,967,295)',
                               to_char(v_oid_warning_threshold, 'FM999,999,999,999'));
            recommendation := 'OID exhaustion requires pg_dump/pg_restore to reset counter. Review lo_create() usage and large object cleanup.';
            RETURN NEXT;
        END IF;
    END;

    -- Idle-in-transaction detection
    FOR v_row IN
        SELECT pid, usename, application_name,
               EXTRACT(EPOCH FROM (now() - xact_start))/60 AS idle_minutes
        FROM flight_recorder.activity_samples_archive
        WHERE captured_at BETWEEN p_start_time AND p_end_time
          AND state = 'idle in transaction'
          AND xact_start IS NOT NULL
          AND now() - xact_start > interval '5 minutes'
        ORDER BY xact_start ASC
        LIMIT 5
    LOOP
        anomaly_type := 'IDLE_IN_TRANSACTION';
        severity := CASE WHEN v_row.idle_minutes > 60 THEN 'critical'
             WHEN v_row.idle_minutes > 15 THEN 'high'
             ELSE 'medium' END;
        description := format('Session %s (%s) idle in transaction for %s minutes',
               v_row.pid, v_row.usename, round(v_row.idle_minutes::numeric));
        metric_value := format('PID %s, %s minutes', v_row.pid, round(v_row.idle_minutes::numeric));
        threshold := '>5 minutes idle in transaction';
        recommendation := 'Investigate and terminate if stale. Blocks vacuum and holds locks.';
        RETURN NEXT;
    END LOOP;

    -- Dead tuple accumulation (bloat risk)
    FOR v_row IN
        SELECT COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
               COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
               ts.n_dead_tup, ts.n_live_tup,
               round(100.0 * ts.n_dead_tup / NULLIF(ts.n_dead_tup + ts.n_live_tup, 0), 1) AS dead_pct
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at = (SELECT MAX(s2.captured_at) FROM flight_recorder.snapshots s2
                               JOIN flight_recorder.table_snapshots ts2 ON ts2.snapshot_id = s2.id
                               WHERE s2.captured_at <= p_end_time)
          AND ts.n_dead_tup > 10000
          AND ts.n_dead_tup::float / NULLIF(ts.n_dead_tup + ts.n_live_tup, 0) > 0.1
        ORDER BY ts.n_dead_tup DESC
        LIMIT 5
    LOOP
        anomaly_type := 'DEAD_TUPLE_ACCUMULATION';
        severity := CASE WHEN v_row.dead_pct > 30 THEN 'high'
             ELSE 'medium' END;
        description := format('Table %s.%s has %s%% dead tuples (%s dead)',
               v_row.schemaname, v_row.relname, v_row.dead_pct, v_row.n_dead_tup);
        metric_value := format('%s%% dead tuples', v_row.dead_pct);
        threshold := '>10% dead tuples and >10000 dead rows';
        recommendation := 'Run VACUUM on this table. Check autovacuum settings.';
        RETURN NEXT;
    END LOOP;

    -- Vacuum starvation (dead tuples growing, vacuum not running)
    FOR v_row IN
        WITH recent AS (
            SELECT COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
                   COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
                   ts.relid, ts.n_dead_tup, ts.last_autovacuum,
                   s.captured_at,
                   LAG(ts.n_dead_tup) OVER (PARTITION BY ts.relid ORDER BY s.captured_at) AS prev_dead
            FROM flight_recorder.table_snapshots ts
            JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
            WHERE s.captured_at BETWEEN p_start_time AND p_end_time
        )
        SELECT schemaname, relname, n_dead_tup, last_autovacuum,
               n_dead_tup - COALESCE(prev_dead, 0) AS dead_growth
        FROM recent
        WHERE captured_at = (SELECT MAX(captured_at) FROM recent)
          AND n_dead_tup > prev_dead + 1000
          AND (last_autovacuum IS NULL OR last_autovacuum < now() - interval '24 hours')
        ORDER BY n_dead_tup - COALESCE(prev_dead, 0) DESC
        LIMIT 3
    LOOP
        anomaly_type := 'VACUUM_STARVATION';
        severity := 'high';
        description := format('Table %s.%s: dead tuples growing (+%s) but no vacuum in 24h',
               v_row.schemaname, v_row.relname, v_row.dead_growth);
        metric_value := format('+%s dead tuples, last vacuum: %s', v_row.dead_growth,
               COALESCE(v_row.last_autovacuum::TEXT, 'never'));
        threshold := 'Dead tuples growing >1000 with no vacuum in 24h';
        recommendation := 'Check autovacuum_vacuum_threshold and autovacuum_vacuum_scale_factor.';
        RETURN NEXT;
    END LOOP;

    -- Connection leak detection (sessions open > 7 days)
    FOR v_row IN
        SELECT DISTINCT ON (pid) pid, usename, application_name, backend_start,
               EXTRACT(DAY FROM (now() - backend_start)) AS days_open
        FROM flight_recorder.activity_samples_archive
        WHERE captured_at BETWEEN p_start_time AND p_end_time
          AND backend_start IS NOT NULL
          AND backend_start < now() - interval '7 days'
        ORDER BY pid, backend_start
        LIMIT 5
    LOOP
        anomaly_type := 'CONNECTION_LEAK';
        severity := CASE WHEN v_row.days_open > 30 THEN 'high' ELSE 'medium' END;
        description := format('Session %s (%s/%s) open for %s days',
               v_row.pid, v_row.usename, v_row.application_name, round(v_row.days_open::numeric));
        metric_value := format('%s days', round(v_row.days_open::numeric));
        threshold := '>7 days session age';
        recommendation := 'Investigate if this is a connection leak. Consider connection pooling.';
        RETURN NEXT;
    END LOOP;

    -- Replication lag velocity (lag is growing)
    FOR v_row IN
        WITH lag_samples AS (
            SELECT r.application_name,
                   EXTRACT(EPOCH FROM r.replay_lag) AS lag_seconds,
                   s.captured_at,
                   ROW_NUMBER() OVER (PARTITION BY r.application_name ORDER BY s.captured_at) AS rn
            FROM flight_recorder.replication_snapshots r
            JOIN flight_recorder.snapshots s ON s.id = r.snapshot_id
            WHERE s.captured_at BETWEEN p_start_time AND p_end_time
              AND r.replay_lag IS NOT NULL
        ),
        lag_trend AS (
            SELECT application_name,
                   MAX(lag_seconds) - MIN(lag_seconds) AS lag_growth,
                   MAX(lag_seconds) AS current_lag,
                   COUNT(*) AS samples
            FROM lag_samples
            GROUP BY application_name
            HAVING COUNT(*) >= 3
        )
        SELECT * FROM lag_trend
        WHERE lag_growth > 60  -- Growing by more than 60 seconds
          AND current_lag > 30 -- And currently > 30 seconds behind
    LOOP
        anomaly_type := 'REPLICATION_LAG_GROWING';
        severity := CASE WHEN v_row.current_lag > 300 THEN 'critical'
             WHEN v_row.current_lag > 60 THEN 'high'
             ELSE 'medium' END;
        description := format('Replica %s: lag growing (+%ss), now %ss behind',
               v_row.application_name, round(v_row.lag_growth::numeric), round(v_row.current_lag::numeric));
        metric_value := format('+%ss growth, %ss current', round(v_row.lag_growth::numeric), round(v_row.current_lag::numeric));
        threshold := '>60s growth and >30s current lag';
        recommendation := 'Check replica capacity, network, and long-running queries on primary.';
        RETURN NEXT;
    END LOOP;

    RETURN;
END;
$$;

-- Generates a comprehensive performance report with metrics and interpretations for a specified time window
-- Aggregates data from compare, anomaly detection, wait events, and lock contention to provide human-readable insights
CREATE OR REPLACE FUNCTION flight_recorder.summary_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    section             TEXT,
    metric              TEXT,
    value               TEXT,
    interpretation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cmp RECORD;
    v_sample_count INTEGER;
    v_anomaly_count INTEGER;
    v_top_wait RECORD;
    v_lock_summary RECORD;
BEGIN
    SELECT * INTO v_cmp FROM flight_recorder.compare(p_start_time, p_end_time);
    SELECT count(*) INTO v_sample_count
    FROM flight_recorder.samples_ring WHERE captured_at BETWEEN p_start_time AND p_end_time;
    SELECT count(*) INTO v_anomaly_count
    FROM flight_recorder.anomaly_report(p_start_time, p_end_time);
    section := 'OVERVIEW';
    metric := 'Time Window';
    value := format('%s to %s', p_start_time, p_end_time);
    interpretation := format('%s seconds elapsed', round(COALESCE(v_cmp.elapsed_seconds, 0), 1));
    RETURN NEXT;
    metric := 'Data Coverage';
    value := format('%s snapshots, %s samples',
                   (SELECT count(*) FROM flight_recorder.snapshots
                    WHERE captured_at BETWEEN p_start_time AND p_end_time),
                   v_sample_count);
    interpretation := CASE
        WHEN v_sample_count = 0 THEN 'WARNING: No sample data in window'
        ELSE 'OK'
    END;
    RETURN NEXT;
    metric := 'Anomalies Detected';
    value := v_anomaly_count::text;
    interpretation := CASE
        WHEN v_anomaly_count = 0 THEN 'No issues detected'
        WHEN v_anomaly_count <= 2 THEN 'Minor issues'
        ELSE 'Multiple issues - review anomaly_report()'
    END;
    RETURN NEXT;
    section := 'CHECKPOINT & WAL';
    metric := 'Checkpoint Occurred';
    value := COALESCE(v_cmp.checkpoint_occurred::text, 'unknown');
    interpretation := CASE
        WHEN v_cmp.checkpoint_occurred THEN
            format('Checkpoint write: %s ms', round(COALESCE(v_cmp.ckpt_write_time_ms, 0)::numeric, 1))
        ELSE 'No checkpoint during window'
    END;
    RETURN NEXT;
    metric := 'WAL Generated';
    value := COALESCE(v_cmp.wal_bytes_pretty, 'N/A');
    interpretation := format('%s MB/sec',
                            round((COALESCE(v_cmp.wal_bytes_delta, 0) / 1048576.0) / NULLIF(v_cmp.elapsed_seconds, 0), 2));
    RETURN NEXT;
    section := 'BUFFERS & I/O';
    metric := 'Buffers Allocated';
    value := COALESCE(v_cmp.bgw_buffers_alloc_delta::text, 'N/A');
    interpretation := 'New buffer allocations';
    RETURN NEXT;
    metric := 'Backend Buffer Writes';
    value := COALESCE(v_cmp.bgw_buffers_backend_delta::text, 'N/A');
    interpretation := CASE
        WHEN COALESCE(v_cmp.bgw_buffers_backend_delta, 0) > 0 THEN 'WARNING: Backends writing directly'
        ELSE 'OK'
    END;
    RETURN NEXT;
    metric := 'Temp File Spills';
    value := format('%s files, %s', COALESCE(v_cmp.temp_files_delta, 0), COALESCE(v_cmp.temp_bytes_pretty, '0 B'));
    interpretation := CASE
        WHEN COALESCE(v_cmp.temp_files_delta, 0) > 0 THEN 'Consider increasing work_mem'
        ELSE 'No temp file usage'
    END;
    RETURN NEXT;
    section := 'WAIT EVENTS';
    FOR v_top_wait IN
        SELECT wait_event_type || ':' || wait_event AS we, total_waiters, pct_of_samples
        FROM flight_recorder.wait_summary(p_start_time, p_end_time)
        LIMIT 5
    LOOP
        metric := v_top_wait.we;
        value := format('%s total waiters (%s%% of samples)',
                       v_top_wait.total_waiters, v_top_wait.pct_of_samples);
        interpretation := CASE
            WHEN v_top_wait.we LIKE 'Lock:%' THEN 'Lock contention'
            WHEN v_top_wait.we LIKE 'LWLock:Buffer%' THEN 'Buffer contention'
            WHEN v_top_wait.we LIKE 'LWLock:WAL%' THEN 'WAL contention'
            WHEN v_top_wait.we LIKE 'IO:%' THEN 'I/O bound'
            WHEN v_top_wait.we = 'Running:CPU' THEN 'CPU active (normal)'
            ELSE 'Review PostgreSQL docs'
        END;
        RETURN NEXT;
    END LOOP;
    section := 'LOCK CONTENTION';
    SELECT
        count(DISTINCT blocked_pid) AS blocked_count,
        max(blocked_duration) AS max_duration
    INTO v_lock_summary
    FROM flight_recorder.lock_samples_ring l
    JOIN flight_recorder.samples_ring s ON s.slot_id = l.slot_id
    WHERE s.captured_at BETWEEN p_start_time AND p_end_time;
    metric := 'Blocked Sessions';
    value := COALESCE(v_lock_summary.blocked_count, 0)::text;
    interpretation := CASE
        WHEN COALESCE(v_lock_summary.blocked_count, 0) = 0 THEN 'No lock contention'
        ELSE format('Max blocked duration: %s', v_lock_summary.max_duration)
    END;
    RETURN NEXT;
    RETURN;
END;
$$;
-- Detects query storms by comparing recent query execution counts to baseline
-- Returns queries with execution spikes classified by type and severity
CREATE OR REPLACE FUNCTION flight_recorder.detect_query_storms(
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
    multiplier NUMERIC
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
        flight_recorder._get_config('storm_lookback_interval', '1 hour')::interval
    );
    v_threshold := COALESCE(
        p_threshold_multiplier,
        flight_recorder._get_config('storm_threshold_multiplier', '3.0')::numeric
    );
    v_baseline_days := COALESCE(
        flight_recorder._get_config('storm_baseline_days', '7')::integer,
        7
    );

    -- Get severity thresholds
    v_low_max := flight_recorder._get_config('storm_severity_low_max', '5.0')::numeric;
    v_medium_max := flight_recorder._get_config('storm_severity_medium_max', '10.0')::numeric;
    v_high_max := flight_recorder._get_config('storm_severity_high_max', '50.0')::numeric;

    RETURN QUERY
    WITH recent_stats AS (
        -- Recent query counts from statement_snapshots
        SELECT
            ss.queryid,
            left(ss.query_preview, 100) AS query_preview,
            SUM(ss.calls) AS total_calls
        FROM flight_recorder.statement_snapshots ss
        JOIN flight_recorder.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at >= now() - v_lookback
        GROUP BY ss.queryid, left(ss.query_preview, 100)
    ),
    baseline_stats AS (
        -- Baseline query counts (same hour of day over baseline period, excluding recent)
        SELECT
            ss.queryid,
            AVG(ss.calls) AS avg_calls,
            COUNT(DISTINCT date_trunc('day', s.captured_at)) AS days_sampled
        FROM flight_recorder.statement_snapshots ss
        JOIN flight_recorder.snapshots s ON s.id = ss.snapshot_id
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
                WHEN r.total_calls > COALESCE(b.avg_calls, 0) * 10
                    THEN 'CACHE_MISS'
                WHEN r.total_calls > COALESCE(b.avg_calls, 1) * v_threshold
                    THEN 'SPIKE'
                ELSE 'NORMAL'
            END AS storm_type,
            r.total_calls::BIGINT AS recent_count,
            COALESCE(b.avg_calls, 0)::BIGINT AS baseline_count,
            CASE
                WHEN COALESCE(b.avg_calls, 0) > 0
                THEN ROUND(r.total_calls::numeric / b.avg_calls, 2)
                ELSE NULL
            END AS multiplier
        FROM recent_stats r
        LEFT JOIN baseline_stats b ON b.queryid = r.queryid
        WHERE r.total_calls > COALESCE(b.avg_calls, 1) * v_threshold
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
        st.multiplier
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
COMMENT ON FUNCTION flight_recorder.detect_query_storms(INTERVAL, NUMERIC) IS 'Detect query storms by comparing recent execution counts to baseline. Classifies as RETRY_STORM, CACHE_MISS, SPIKE, or NORMAL with severity levels (LOW, MEDIUM, HIGH, CRITICAL).';

-- =============================================================================
-- PERFORMANCE REGRESSION DETECTION
-- =============================================================================

-- Diagnose probable causes for a query's performance regression
-- Analyzes pg_stat_statements and snapshots for indicators
CREATE OR REPLACE FUNCTION flight_recorder._diagnose_regression_causes(
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
    FROM flight_recorder.snapshots
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
COMMENT ON FUNCTION flight_recorder._diagnose_regression_causes(BIGINT) IS 'Internal: Analyze a query to suggest probable causes for performance regression.';

-- Detects performance regressions by comparing recent query metrics to baseline
-- Uses buffer metrics by default (configurable via regression_detection_metric)
-- Returns queries with significant regression classified by severity
CREATE OR REPLACE FUNCTION flight_recorder.detect_regressions(
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
    probable_causes TEXT[]
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
        flight_recorder._get_config('regression_lookback_interval', '1 hour')::interval
    );
    v_threshold_pct := COALESCE(
        p_threshold_pct,
        flight_recorder._get_config('regression_threshold_pct', '50.0')::numeric
    );
    v_baseline_days := COALESCE(
        flight_recorder._get_config('regression_baseline_days', '7')::integer,
        7
    );

    -- Get severity thresholds (percentage-based)
    v_low_max := flight_recorder._get_config('regression_severity_low_max', '200.0')::numeric;
    v_medium_max := flight_recorder._get_config('regression_severity_medium_max', '500.0')::numeric;
    v_high_max := flight_recorder._get_config('regression_severity_high_max', '1000.0')::numeric;

    -- Get detection metric (default to buffers)
    v_detection_metric := flight_recorder._get_config('regression_detection_metric', 'buffers');

    RETURN QUERY
    WITH recent_stats AS (
        -- Recent query metrics from statement_snapshots
        SELECT
            ss.queryid,
            left(ss.query_preview, 100) AS query_preview,
            AVG(ss.mean_exec_time) AS avg_mean_time,
            STDDEV(ss.mean_exec_time) AS stddev_mean_time,
            AVG(ss.shared_blks_hit + ss.shared_blks_read + ss.temp_blks_read + ss.temp_blks_written) AS avg_total_buffers,
            STDDEV(ss.shared_blks_hit + ss.shared_blks_read + ss.temp_blks_read + ss.temp_blks_written) AS stddev_total_buffers,
            COUNT(*) AS sample_count
        FROM flight_recorder.statement_snapshots ss
        JOIN flight_recorder.snapshots s ON s.id = ss.snapshot_id
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
            AVG(ss.shared_blks_hit + ss.shared_blks_read + ss.temp_blks_read + ss.temp_blks_written) AS avg_total_buffers,
            STDDEV(ss.shared_blks_hit + ss.shared_blks_read + ss.temp_blks_read + ss.temp_blks_written) AS stddev_total_buffers,
            COUNT(DISTINCT date_trunc('day', s.captured_at)) AS days_sampled
        FROM flight_recorder.statement_snapshots ss
        JOIN flight_recorder.snapshots s ON s.id = ss.snapshot_id
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
            -- Z-score calculation for statistical significance (based on detection metric)
            CASE
                WHEN v_detection_metric = 'time' THEN
                    CASE
                        WHEN COALESCE(b.stddev_mean_time, 0) > 0
                        THEN (r.avg_mean_time - b.avg_mean_time) / b.stddev_mean_time
                        ELSE 0
                    END
                ELSE
                    CASE
                        WHEN COALESCE(b.stddev_total_buffers, 0) > 0
                        THEN (r.avg_total_buffers - b.avg_total_buffers) / b.stddev_total_buffers
                        ELSE 0
                    END
            END AS z_score,
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
        flight_recorder._diagnose_regression_causes(reg.queryid) AS probable_causes
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
COMMENT ON FUNCTION flight_recorder.detect_regressions(INTERVAL, NUMERIC) IS 'Detect performance regressions using buffer metrics (default) or timing. Classifies severity based on percentage change (LOW <200%, MEDIUM <500%, HIGH <1000%, CRITICAL >1000%). Configure via regression_detection_metric.';
-- Generates a health report of flight recorder operations, including collection performance metrics,
-- success rates, and schema size with qualitative assessments
CREATE OR REPLACE FUNCTION flight_recorder.performance_report(p_lookback_interval INTERVAL DEFAULT '24 hours')
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
    FROM flight_recorder.collection_stats
    WHERE started_at > now() - p_lookback_interval;
    SELECT schema_size_mb INTO v_schema_size_mb FROM flight_recorder._check_schema_size();
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
    FROM flight_recorder.collection_stats
    WHERE started_at > now() - p_lookback_interval
      AND sections_total IS NOT NULL;
    RETURN QUERY
    WITH recent AS (
        SELECT duration_ms
        FROM flight_recorder.collection_stats
        WHERE collection_type = 'sample'
          AND success = true
          AND skipped = false
          AND started_at > now() - p_lookback_interval
        ORDER BY started_at DESC
        LIMIT 10
    ),
    baseline AS (
        SELECT duration_ms
        FROM flight_recorder.collection_stats
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

-- Monitors flight recorder system health by checking for circuit breaker trips, schema size limits, collection failures, and stale data
-- Returns alerts with severity levels (CRITICAL/WARNING) and recommendations when thresholds are exceeded
CREATE OR REPLACE FUNCTION flight_recorder.check_alerts(p_lookback_interval INTERVAL DEFAULT '1 hour')
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
        flight_recorder._get_config('alert_enabled', 'false')::boolean,
        false
    );
    IF NOT v_enabled THEN
        RETURN;
    END IF;
    v_cb_threshold := COALESCE(
        flight_recorder._get_config('alert_circuit_breaker_count', '5')::integer,
        5
    );
    SELECT count(*) INTO v_cb_count
    FROM flight_recorder.collection_stats
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
        flight_recorder._get_config('alert_schema_size_mb', '8000')::integer,
        8000
    );
    SELECT schema_size_mb INTO v_schema_size_mb FROM flight_recorder._check_schema_size();
    IF v_schema_size_mb >= v_schema_threshold_mb THEN
        RETURN QUERY SELECT
            'SCHEMA_SIZE_HIGH'::text,
            'WARNING'::text,
            format('Schema size is %s MB (threshold: %s MB)', round(v_schema_size_mb)::text, v_schema_threshold_mb),
            now(),
            'Run flight_recorder.cleanup() to reclaim space.'::text;
    END IF;
    DECLARE
        v_recent_failures INTEGER;
    BEGIN
        SELECT count(*) INTO v_recent_failures
        FROM flight_recorder.collection_stats
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
        SELECT max(captured_at) INTO v_last_sample FROM flight_recorder.samples_ring;
        IF v_last_sample IS NULL OR v_last_sample < now() - interval '15 minutes' THEN
            RETURN QUERY SELECT
                'STALE_DATA'::text,
                'CRITICAL'::text,
                CASE
                    WHEN v_last_sample IS NULL THEN 'No samples collected yet'
                    ELSE format('Last sample was %s ago', age(now(), v_last_sample))
                END,
                now(),
                'Check pg_cron jobs: SELECT * FROM cron.job WHERE jobname LIKE ''flight_recorder_%'''::text;
        END IF;
    END;
END;
$$;

-- Exports flight recorder diagnostic data as human-readable Markdown
-- Produces a report with tables that is legible to both humans and AI
CREATE OR REPLACE FUNCTION flight_recorder.report(
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
    SELECT value INTO v_version FROM flight_recorder.config WHERE key = 'schema_version';
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

    SELECT count(*) INTO v_count FROM flight_recorder.anomaly_report(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '**No anomalies detected.** System appears healthy.' || E'\n\n';
    ELSE
        v_result := v_result || '| Type | Severity | Description | Metric | Recommendation |' || E'\n';
        v_result := v_result || '|------|----------|-------------|--------|----------------|' || E'\n';
        FOR v_row IN SELECT * FROM flight_recorder.anomaly_report(p_start_time, p_end_time) LOOP
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

    SELECT count(*) INTO v_count FROM flight_recorder.wait_summary(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no wait events recorded)' || E'\n\n';
    ELSE
        v_result := v_result || '| Backend | Event Type | Event | Samples | Avg Waiters | Max | % |' || E'\n';
        v_result := v_result || '|---------|------------|-------|---------|-------------|-----|---|' || E'\n';
        FOR v_row IN SELECT * FROM flight_recorder.wait_summary(p_start_time, p_end_time) LOOP
            v_result := v_result || '| ' ||
                COALESCE(v_row.backend_type, '-') || ' | ' ||
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
    FROM flight_recorder.snapshots
    WHERE captured_at BETWEEN p_start_time AND p_end_time;

    IF v_count = 0 THEN
        v_result := v_result || '(no snapshots in range)' || E'\n\n';
    ELSE
        v_result := v_result || '| Captured At | WAL Bytes | Ckpt (Timed) | Ckpt (Req) | Backend Writes |' || E'\n';
        v_result := v_result || '|-------------|-----------|--------------|------------|----------------|' || E'\n';
        FOR v_row IN
            SELECT captured_at, wal_bytes, ckpt_timed, ckpt_requested, bgw_buffers_backend
            FROM flight_recorder.snapshots
            WHERE captured_at BETWEEN p_start_time AND p_end_time
            ORDER BY captured_at
        LOOP
            v_result := v_result || '| ' ||
                to_char(v_row.captured_at, 'YYYY-MM-DD HH24:MI:SS') || ' | ' ||
                COALESCE(flight_recorder._pretty_bytes(v_row.wal_bytes), '-') || ' | ' ||
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

    SELECT count(*) INTO v_count FROM flight_recorder.table_hotspots(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no issues detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Schema | Table | Issue | Severity | Description | Recommendation |' || E'\n';
        v_result := v_result || '|--------|-------|-------|----------|-------------|----------------|' || E'\n';
        FOR v_row IN SELECT * FROM flight_recorder.table_hotspots(p_start_time, p_end_time) LOOP
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

    SELECT count(*) INTO v_count FROM flight_recorder.index_efficiency(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no index activity in range)' || E'\n\n';
    ELSE
        v_result := v_result || '| Schema | Table | Index | Scans | Selectivity | Size | Scans/GB |' || E'\n';
        v_result := v_result || '|--------|-------|-------|-------|-------------|------|----------|' || E'\n';
        FOR v_row IN SELECT * FROM flight_recorder.index_efficiency(p_start_time, p_end_time) LOOP
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
        SELECT count(*) INTO v_count FROM flight_recorder.statement_compare(p_start_time, p_end_time, 100, 25);
        IF v_count = 0 THEN
            v_result := v_result || '(no significant query changes)' || E'\n\n';
        ELSE
            v_result := v_result || '| Query | Calls Δ | Total Time Δ (ms) | Mean (ms) | Temp Writes | Hit % |' || E'\n';
            v_result := v_result || '|-------|---------|-------------------|-----------|-------------|-------|' || E'\n';
            FOR v_row IN
                SELECT * FROM flight_recorder.statement_compare(p_start_time, p_end_time, 100, 25)
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
    -- ==========================================================================
    v_result := v_result || '## Lock Contention' || E'\n\n';

    SELECT count(*) INTO v_count
    FROM flight_recorder.lock_samples_archive
    WHERE captured_at BETWEEN p_start_time AND p_end_time;

    IF v_count = 0 THEN
        v_result := v_result || '(no lock contention recorded)' || E'\n\n';
    ELSE
        v_result := v_result || '| Time | Blocked PID | Blocking PID | Lock Type | Duration | Blocked Query |' || E'\n';
        v_result := v_result || '|------|-------------|--------------|-----------|----------|---------------|' || E'\n';
        FOR v_row IN
            SELECT *
            FROM flight_recorder.lock_samples_archive
            WHERE captured_at BETWEEN p_start_time AND p_end_time
            ORDER BY captured_at DESC
            LIMIT 50
        LOOP
            v_result := v_result || '| ' ||
                to_char(v_row.captured_at, 'HH24:MI:SS') || ' | ' ||
                COALESCE(v_row.blocked_pid::TEXT, '-') || ' | ' ||
                COALESCE(v_row.blocking_pid::TEXT, '-') || ' | ' ||
                COALESCE(v_row.lock_type, '-') || ' | ' ||
                COALESCE(v_row.blocked_duration::TEXT, '-') || ' | ' ||
                COALESCE(left(v_row.blocked_query_preview, 40), '-') || ' |' || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- ==========================================================================
    -- Long-Running Transactions Section
    -- ==========================================================================
    v_result := v_result || '## Long-Running Transactions' || E'\n\n';

    SELECT count(*) INTO v_count
    FROM flight_recorder.activity_samples_archive
    WHERE captured_at BETWEEN p_start_time AND p_end_time
      AND xact_start IS NOT NULL
      AND captured_at - xact_start > interval '5 minutes';

    IF v_count = 0 THEN
        v_result := v_result || '(no long-running transactions detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Time | PID | User | App | Transaction Age | State | Query Preview |' || E'\n';
        v_result := v_result || '|------|-----|------|-----|-----------------|-------|---------------|' || E'\n';
        FOR v_row IN
            SELECT DISTINCT ON (pid, xact_start)
                captured_at,
                pid,
                usename,
                application_name,
                captured_at - xact_start AS xact_age,
                state,
                query_preview
            FROM flight_recorder.activity_samples_archive
            WHERE captured_at BETWEEN p_start_time AND p_end_time
              AND xact_start IS NOT NULL
              AND captured_at - xact_start > interval '5 minutes'
            ORDER BY pid, xact_start, captured_at DESC
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
    FROM flight_recorder.vacuum_progress_snapshots v
    JOIN flight_recorder.snapshots s ON s.id = v.snapshot_id
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
            FROM flight_recorder.vacuum_progress_snapshots v
            JOIN flight_recorder.snapshots s ON s.id = v.snapshot_id
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
    FROM flight_recorder.snapshots
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
            FROM flight_recorder.snapshots
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

    SELECT count(*) INTO v_count FROM flight_recorder.config_changes(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no changes detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Parameter | Old Value | New Value | Old Source | New Source | Changed At |' || E'\n';
        v_result := v_result || '|-----------|-----------|-----------|------------|------------|------------|' || E'\n';
        FOR v_row IN SELECT * FROM flight_recorder.config_changes(p_start_time, p_end_time) LOOP
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

    SELECT count(*) INTO v_count FROM flight_recorder.db_role_config_changes(p_start_time, p_end_time);
    IF v_count = 0 THEN
        v_result := v_result || '(no changes detected)' || E'\n\n';
    ELSE
        v_result := v_result || '| Database | Role | Parameter | Old Value | New Value | Type |' || E'\n';
        v_result := v_result || '|----------|------|-----------|-----------|-----------|------|' || E'\n';
        FOR v_row IN SELECT * FROM flight_recorder.db_role_config_changes(p_start_time, p_end_time) LOOP
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
COMMENT ON FUNCTION flight_recorder.report(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Generate diagnostic report from flight recorder data. Readable by humans and AI systems.';

-- Interval convenience overload: report('1 hour') instead of timestamps
CREATE OR REPLACE FUNCTION flight_recorder.report(
    p_interval INTERVAL
)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT flight_recorder.report(now() - p_interval, now());
$$;
COMMENT ON FUNCTION flight_recorder.report(INTERVAL) IS
'Generate diagnostic report for the specified interval ending now. Usage: SELECT flight_recorder.report(''1 hour'')';
-- Validates system readiness for flight recorder installation by checking resources, connections, and dependencies
-- Returns component status (GO/CAUTION/NO-GO) to determine installation viability
CREATE OR REPLACE FUNCTION flight_recorder.preflight_check()
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
            'Ring buffer uses fixed 120KB memory. Aggregates: ~2-3 GB per week (7-day retention).',
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
            'Automatic scheduling will work. Flight recorder will run automatically every 3 minutes.'::text;
    ELSE
        RETURN QUERY SELECT
            'Scheduling (pg_cron)'::text,
            'CAUTION'::text,
            'pg_cron extension not found',
            'You will need to schedule flight_recorder.sample() and flight_recorder.snapshot() manually via external cron or pg_agent.'::text;
    END IF;
    RETURN QUERY SELECT
        'Safety Mechanisms'::text,
        'GO'::text,
        'Circuit breaker, adaptive mode, timeouts all enabled by default',
        'Flight recorder will auto-reduce overhead under stress.'::text;
END;
$$;
COMMENT ON FUNCTION flight_recorder.preflight_check() IS

'Pre-installation validation checks. Returns component status (GO/CAUTION/NO-GO). For summary, use preflight_check_with_summary().';
-- Executes preflight validation checks and appends a summary row indicating overall system readiness (READY, CAUTION, or NO-GO)
CREATE OR REPLACE FUNCTION flight_recorder.preflight_check_with_summary()
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
    RETURN QUERY SELECT * FROM flight_recorder.preflight_check();
    SELECT
        count(*) FILTER (WHERE c.status = 'NO-GO'),
        count(*) FILTER (WHERE c.status = 'CAUTION')
    INTO v_nogo_count, v_caution_count
    FROM flight_recorder.preflight_check() c;
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
COMMENT ON FUNCTION flight_recorder.preflight_check_with_summary() IS

'Pre-installation validation with summary. Calls preflight_check() twice - once for results, once to count. More expensive but includes summary row.';
-- Generates a comprehensive quarterly health review of the flight_recorder system
-- Assesses collection performance, storage consumption, reliability, circuit breaker activity, and data freshness
CREATE OR REPLACE FUNCTION flight_recorder.quarterly_review()
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
    FROM flight_recorder.collection_stats
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
    SELECT schema_size_mb INTO v_schema_size_mb FROM flight_recorder._check_schema_size();
    SELECT count(*) INTO v_sample_count FROM flight_recorder.samples_ring;
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
    FROM flight_recorder.collection_stats
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
    FROM flight_recorder.collection_stats
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
    SELECT max(captured_at) INTO v_last_sample FROM flight_recorder.samples_ring;
    SELECT max(captured_at) INTO v_last_snapshot FROM flight_recorder.snapshots;
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
            'Collections are stale. Check pg_cron jobs: SELECT * FROM cron.job WHERE jobname LIKE ''flight_recorder_%'';'::text;
    END IF;
    DECLARE
        v_missing_count INTEGER;
        v_inactive_count INTEGER;
        v_missing_jobs TEXT[];
        v_inactive_jobs TEXT[];
    BEGIN
        WITH required_jobs AS (
            SELECT unnest(ARRAY[
                'flight_recorder_sample',
                'flight_recorder_snapshot',
                'flight_recorder_flush',
                'flight_recorder_cleanup'
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
                'CRITICAL: Flight recorder is not collecting data. Run flight_recorder.enable() to restore.'::text;
        ELSE
            RETURN QUERY SELECT
                '6. pg_cron Job Health'::text,
                'CRITICAL'::text,
                format('%s/%s jobs inactive: %s', v_inactive_count, 4, array_to_string(v_inactive_jobs, ', ')),
                'CRITICAL: pg_cron jobs exist but are disabled. Run flight_recorder.enable() to reactivate.'::text;
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
COMMENT ON FUNCTION flight_recorder.quarterly_review() IS

'Quarterly health check for flight recorder. Returns component metrics (EXCELLENT/GOOD/REVIEW NEEDED/ERROR). For summary, use quarterly_review_with_summary().';
-- Quarterly health check with summary. Appends overall health status (HEALTHY or ACTION REQUIRED) based on count of ERROR or REVIEW NEEDED items detected
-- More expensive than quarterly_review() as it calls it twice - once for detailed results, once to count critical issues
CREATE OR REPLACE FUNCTION flight_recorder.quarterly_review_with_summary()
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
    RETURN QUERY SELECT * FROM flight_recorder.quarterly_review();
    SELECT count(*) INTO v_issues_count
    FROM flight_recorder.quarterly_review() qr
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
COMMENT ON FUNCTION flight_recorder.quarterly_review_with_summary() IS

'Quarterly health check with summary. Calls quarterly_review() twice - once for results, once to count. More expensive but includes summary row.';
-- Analyzes database resource capacity metrics (connections, memory, storage, transactions) over a time window
-- Returns utilization status with actionable recommendations
CREATE OR REPLACE FUNCTION flight_recorder.capacity_summary(
    p_time_window INTERVAL DEFAULT interval '24 hours'
)
RETURNS TABLE(
    metric                  TEXT,
    current_usage           TEXT,
    provisioned_capacity    TEXT,
    utilization_pct         NUMERIC,
    headroom_pct            NUMERIC,
    status                  TEXT,
    recommendation          TEXT
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
        flight_recorder._get_config('capacity_thresholds_warning_pct', '60')::integer,
        60
    );
    v_critical_pct := COALESCE(
        flight_recorder._get_config('capacity_thresholds_critical_pct', '80')::integer,
        80
    );
    v_window_start := now() - p_time_window;
    v_window_hours := EXTRACT(EPOCH FROM p_time_window) / 3600.0;
    SELECT count(*) INTO v_sample_count
    FROM flight_recorder.snapshots
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
                   CASE WHEN v_sample_count = 0 THEN '5 minutes' ELSE 'a few more minutes' END)::text;
        RETURN;
    END IF;
    SELECT setting::integer INTO v_max_connections
    FROM pg_settings WHERE name = 'max_connections';
    SELECT COALESCE(connections_total, 0)
    INTO v_current_connections
    FROM flight_recorder.snapshots
    WHERE captured_at >= v_window_start
      AND connections_total IS NOT NULL
    ORDER BY captured_at DESC
    LIMIT 1;
    SELECT
        COALESCE(round(avg(connections_total), 0), 0),
        COALESCE(max(connections_total), 0)
    INTO v_avg_connections, v_peak_connections
    FROM flight_recorder.snapshots
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
        FROM flight_recorder.snapshots s
        JOIN flight_recorder.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM flight_recorder.snapshots WHERE id < s.id
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
        FROM flight_recorder.snapshots s
        JOIN flight_recorder.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM flight_recorder.snapshots WHERE id < s.id
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
                           flight_recorder._pretty_bytes(v_temp_bytes_total),
                           flight_recorder._pretty_bytes(v_temp_bytes_per_hour::bigint));
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
                   flight_recorder._pretty_bytes(v_temp_bytes_per_hour::bigint))
        WHEN v_temp_bytes_per_hour >= 104857600 THEN
            format('WARNING: Moderate temp file spills (%s/hour). Consider increasing work_mem for sort/hash operations.',
                   flight_recorder._pretty_bytes(v_temp_bytes_per_hour::bigint))
        WHEN v_temp_bytes_total = 0 THEN
            'HEALTHY: No temp file spills detected. Queries fitting in work_mem.'
        ELSE
            format('HEALTHY: Minimal temp file spills (%s/hour). Current work_mem adequate.',
                   flight_recorder._pretty_bytes(v_temp_bytes_per_hour::bigint))
    END;
    RETURN NEXT;
    WITH io_deltas AS (
        SELECT
            s.blks_read - prev.blks_read AS read_delta,
            s.blks_hit - prev.blks_hit AS hit_delta
        FROM flight_recorder.snapshots s
        JOIN flight_recorder.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM flight_recorder.snapshots WHERE id < s.id
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
            (SELECT db_size_bytes FROM flight_recorder.snapshots
             WHERE captured_at >= v_window_start AND db_size_bytes IS NOT NULL
             ORDER BY captured_at DESC LIMIT 1),
            0
        ),
        COALESCE(
            (SELECT db_size_bytes FROM flight_recorder.snapshots
             WHERE captured_at >= v_window_start AND db_size_bytes IS NOT NULL
             ORDER BY captured_at ASC LIMIT 1),
            0
        )
    INTO v_current_db_size, v_oldest_db_size;
    IF v_current_db_size > 0 AND v_oldest_db_size > 0 THEN
        v_storage_growth_mb_per_day := ((v_current_db_size - v_oldest_db_size)::numeric / (1024.0 * 1024.0))
                                       / NULLIF(v_window_hours / 24.0, 0);
        metric := 'storage_growth';
        current_usage := format('%s current size, growing %s MB/day',
                               flight_recorder._pretty_bytes(v_current_db_size),
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
    END IF;
    WITH xact_deltas AS (
        SELECT
            (s.xact_commit + s.xact_rollback - prev.xact_commit - prev.xact_rollback) AS xact_delta,
            EXTRACT(EPOCH FROM (s.captured_at - prev.captured_at)) AS interval_seconds
        FROM flight_recorder.snapshots s
        JOIN flight_recorder.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM flight_recorder.snapshots WHERE id < s.id
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
COMMENT ON FUNCTION flight_recorder.capacity_summary(INTERVAL) IS

'Capacity planning summary across all resource dimensions. Analyzes connections, memory (shared_buffers, work_mem), I/O (cache hit ratio), storage growth, and transaction rates over the specified time window. Returns utilization, status (healthy/warning/critical), and actionable recommendations. Part of Phase 1 MVP capacity planning enhancements (FR-2.1).';

-- Generates a human-readable markdown capacity report grouped by severity
-- Calls capacity_summary() and formats results as prose text
CREATE OR REPLACE FUNCTION flight_recorder.capacity_report(
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

    -- Process each metric from capacity_summary
    FOR v_row IN
        SELECT *
        FROM flight_recorder.capacity_summary(p_time_window)
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
        FROM flight_recorder.capacity_summary(p_time_window)
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
COMMENT ON FUNCTION flight_recorder.capacity_report(INTERVAL) IS
'Human-readable capacity report in markdown format. Groups metrics by severity (critical, warning, healthy) with actionable recommendations. Calls capacity_summary() internally for data. Use this for incident reports and documentation.';

CREATE OR REPLACE VIEW flight_recorder.capacity_dashboard AS
WITH
latest_snapshot AS (
    SELECT max(captured_at) AS last_updated
    FROM flight_recorder.snapshots
),
capacity_metrics AS (
    SELECT
        metric,
        utilization_pct,
        headroom_pct,
        status,
        recommendation
    FROM flight_recorder.capacity_summary(interval '24 hours')
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
        recommendation AS storage_recommendation
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
    CASE
        WHEN s.storage_recommendation ~ 'growing [0-9\.]+' THEN
            (regexp_match(s.storage_recommendation, 'growing ([0-9\.]+)'))[1]::numeric
        ELSE NULL
    END AS storage_growth_mb_per_day,
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
COMMENT ON VIEW flight_recorder.capacity_dashboard IS
'At-a-glance capacity planning dashboard. Shows current status (healthy/warning/critical) across all resource dimensions: connections, memory, I/O, storage. Includes utilization percentages, composite memory pressure score, and array of critical issues requiring attention. Based on last 24 hours of data. Part of Phase 1 MVP capacity planning enhancements (FR-3.1).';

-- NOTE: Storm and Regression dashboard views removed in 2.21
-- Use detect_query_storms() and detect_regressions() for on-demand analysis

-- TABLE-LEVEL HOTSPOT TRACKING ANALYSIS FUNCTIONS
-- =============================================================================

-- Compares table activity between two time points
-- Returns delta metrics for DML activity, scans, and maintenance events
CREATE OR REPLACE FUNCTION flight_recorder.table_compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_limit INTEGER DEFAULT 25
)
RETURNS TABLE(
    schemaname              TEXT,
    relname                 TEXT,
    relid                   OID,
    seq_scan_delta          BIGINT,
    seq_tup_read_delta      BIGINT,
    idx_scan_delta          BIGINT,
    idx_tup_fetch_delta     BIGINT,
    n_tup_ins_delta         BIGINT,
    n_tup_upd_delta         BIGINT,
    n_tup_del_delta         BIGINT,
    n_tup_hot_upd_delta     BIGINT,
    dead_tup_pct            NUMERIC,
    vacuum_count_delta      BIGINT,
    autovacuum_count_delta  BIGINT,
    analyze_count_delta     BIGINT,
    autoanalyze_count_delta BIGINT,
    total_activity          BIGINT
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT DISTINCT ON (ts.relid) ts.*
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY ts.relid, s.captured_at DESC
    ),
    end_snap AS (
        SELECT DISTINCT ON (ts.relid) ts.*
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at >= p_end_time
        ORDER BY ts.relid, s.captured_at ASC
    ),
    matched AS (
        SELECT
            COALESCE(e.schemaname, split_part(e.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(e.relname, split_part(e.relid::regclass::text, '.', 2)) AS relname,
            e.relid,
            COALESCE(e.seq_scan, 0) - COALESCE(s.seq_scan, 0) AS seq_scan_delta,
            COALESCE(e.seq_tup_read, 0) - COALESCE(s.seq_tup_read, 0) AS seq_tup_read_delta,
            COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0) AS idx_scan_delta,
            COALESCE(e.idx_tup_fetch, 0) - COALESCE(s.idx_tup_fetch, 0) AS idx_tup_fetch_delta,
            COALESCE(e.n_tup_ins, 0) - COALESCE(s.n_tup_ins, 0) AS n_tup_ins_delta,
            COALESCE(e.n_tup_upd, 0) - COALESCE(s.n_tup_upd, 0) AS n_tup_upd_delta,
            COALESCE(e.n_tup_del, 0) - COALESCE(s.n_tup_del, 0) AS n_tup_del_delta,
            COALESCE(e.n_tup_hot_upd, 0) - COALESCE(s.n_tup_hot_upd, 0) AS n_tup_hot_upd_delta,
            e.n_live_tup,
            e.n_dead_tup,
            COALESCE(e.vacuum_count, 0) - COALESCE(s.vacuum_count, 0) AS vacuum_count_delta,
            COALESCE(e.autovacuum_count, 0) - COALESCE(s.autovacuum_count, 0) AS autovacuum_count_delta,
            COALESCE(e.analyze_count, 0) - COALESCE(s.analyze_count, 0) AS analyze_count_delta,
            COALESCE(e.autoanalyze_count, 0) - COALESCE(s.autoanalyze_count, 0) AS autoanalyze_count_delta
        FROM end_snap e
        LEFT JOIN start_snap s ON s.relid = e.relid
    )
    SELECT
        m.schemaname,
        m.relname,
        m.relid,
        m.seq_scan_delta,
        m.seq_tup_read_delta,
        m.idx_scan_delta,
        m.idx_tup_fetch_delta,
        m.n_tup_ins_delta,
        m.n_tup_upd_delta,
        m.n_tup_del_delta,
        m.n_tup_hot_upd_delta,
        CASE
            WHEN COALESCE(m.n_live_tup, 0) > 0
            THEN round(100.0 * COALESCE(m.n_dead_tup, 0) / (COALESCE(m.n_live_tup, 0) + COALESCE(m.n_dead_tup, 0)), 1)
            ELSE 0
        END AS dead_tup_pct,
        m.vacuum_count_delta,
        m.autovacuum_count_delta,
        m.analyze_count_delta,
        m.autoanalyze_count_delta,
        (m.seq_tup_read_delta + m.idx_tup_fetch_delta +
         m.n_tup_ins_delta + m.n_tup_upd_delta + m.n_tup_del_delta) AS total_activity
    FROM matched m
    WHERE (m.seq_tup_read_delta + m.idx_tup_fetch_delta +
           m.n_tup_ins_delta + m.n_tup_upd_delta + m.n_tup_del_delta) > 0
    ORDER BY total_activity DESC
    LIMIT p_limit
$$;
COMMENT ON FUNCTION flight_recorder.table_compare(TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) IS
'Compare table activity between two time points. Shows DML deltas, scan counts, dead tuple percentage, and maintenance events. Useful for identifying hot tables during incidents.';


-- Identifies table hotspots and potential issues
-- Returns actionable recommendations for tables with problems
CREATE OR REPLACE FUNCTION flight_recorder.table_hotspots(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    schemaname      TEXT,
    relname         TEXT,
    issue_type      TEXT,
    severity        TEXT,
    description     TEXT,
    recommendation  TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_table RECORD;
    v_hot_ratio NUMERIC;
BEGIN
    FOR v_table IN
        SELECT * FROM flight_recorder.table_compare(p_start_time, p_end_time, 100)
    LOOP
        -- High sequential scan activity
        IF v_table.seq_scan_delta > 100 AND v_table.seq_tup_read_delta > 100000 THEN
            schemaname := v_table.schemaname;
            relname := v_table.relname;
            issue_type := 'SEQUENTIAL_SCAN_STORM';
            severity := CASE
                WHEN v_table.seq_tup_read_delta > 10000000 THEN 'high'
                WHEN v_table.seq_tup_read_delta > 1000000 THEN 'medium'
                ELSE 'low'
            END;
            description := format('%s sequential scans reading %s tuples',
                                 v_table.seq_scan_delta,
                                 v_table.seq_tup_read_delta);
            recommendation := 'Consider adding an index or reviewing query WHERE clauses';
            RETURN NEXT;
        END IF;

        -- High dead tuple percentage (bloat)
        IF v_table.dead_tup_pct > 20 THEN
            schemaname := v_table.schemaname;
            relname := v_table.relname;
            issue_type := 'TABLE_BLOAT';
            severity := CASE
                WHEN v_table.dead_tup_pct > 50 THEN 'high'
                WHEN v_table.dead_tup_pct > 30 THEN 'medium'
                ELSE 'low'
            END;
            description := format('%s%% dead tuples', round(v_table.dead_tup_pct));
            recommendation := 'Run VACUUM or check autovacuum settings';
            RETURN NEXT;
        END IF;

        -- Low HOT update ratio (inefficient updates)
        IF v_table.n_tup_upd_delta > 1000 THEN
            v_hot_ratio := CASE
                WHEN v_table.n_tup_upd_delta > 0
                THEN 100.0 * v_table.n_tup_hot_upd_delta / v_table.n_tup_upd_delta
                ELSE 100
            END;

            IF v_hot_ratio < 50 THEN
                schemaname := v_table.schemaname;
                relname := v_table.relname;
                issue_type := 'LOW_HOT_UPDATE_RATIO';
                severity := 'medium';
                description := format('%s updates, only %s%% HOT',
                                     v_table.n_tup_upd_delta,
                                     round(v_hot_ratio, 1));
                recommendation := 'Consider increasing fillfactor or reducing indexed columns';
                RETURN NEXT;
            END IF;
        END IF;

        -- Frequent autovacuum (indicates high churn)
        IF v_table.autovacuum_count_delta > 5 THEN
            schemaname := v_table.schemaname;
            relname := v_table.relname;
            issue_type := 'HIGH_AUTOVACUUM_FREQUENCY';
            severity := 'low';
            description := format('%s autovacuums during period',
                                 v_table.autovacuum_count_delta);
            recommendation := 'High write activity detected; ensure autovacuum keeps up';
            RETURN NEXT;
        END IF;
    END LOOP;
END;
$$;
COMMENT ON FUNCTION flight_recorder.table_hotspots(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Identify table-level hotspots and issues. Returns actionable recommendations for sequential scan storms, table bloat, low HOT update ratios, and frequent autovacuum activity.';


-- =============================================================================
-- INDEX USAGE TRACKING ANALYSIS FUNCTIONS
-- =============================================================================

-- Identifies unused or rarely used indexes
-- Returns indexes that may be candidates for removal
CREATE OR REPLACE FUNCTION flight_recorder.unused_indexes(
    p_lookback_interval INTERVAL DEFAULT '7 days'
)
RETURNS TABLE(
    schemaname      TEXT,
    relname         TEXT,
    indexrelname    TEXT,
    index_size      TEXT,
    last_scan_count BIGINT,
    recommendation  TEXT
)
LANGUAGE sql STABLE AS $$
    WITH latest_snapshot AS (
        SELECT max(id) AS snapshot_id
        FROM flight_recorder.snapshots
        WHERE captured_at > now() - p_lookback_interval
    ),
    earliest_snapshot AS (
        SELECT min(id) AS snapshot_id
        FROM flight_recorder.snapshots
        WHERE captured_at > now() - p_lookback_interval
    ),
    index_usage AS (
        SELECT
            COALESCE(e.schemaname, split_part(e.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(e.relname, split_part(e.relid::regclass::text, '.', 2)) AS relname,
            COALESCE(e.indexrelname, split_part(e.indexrelid::regclass::text, '.', 2)) AS indexrelname,
            e.indexrelid,
            e.index_size_bytes,
            COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0) AS scan_delta
        FROM flight_recorder.index_snapshots e
        CROSS JOIN latest_snapshot ls
        LEFT JOIN flight_recorder.index_snapshots s
            ON s.indexrelid = e.indexrelid
            AND s.snapshot_id = (SELECT snapshot_id FROM earliest_snapshot)
        WHERE e.snapshot_id = ls.snapshot_id
    )
    SELECT
        iu.schemaname,
        iu.relname,
        iu.indexrelname,
        flight_recorder._pretty_bytes(iu.index_size_bytes) AS index_size,
        iu.scan_delta AS last_scan_count,
        CASE
            WHEN iu.scan_delta = 0 THEN 'DROP INDEX (never used in ' || p_lookback_interval::text || ')'
            WHEN iu.scan_delta < 10 THEN 'Consider dropping (rarely used)'
            ELSE 'Keep (actively used)'
        END AS recommendation
    FROM index_usage iu
    WHERE iu.scan_delta < 100  -- Threshold for "rarely used"
        AND iu.indexrelname NOT LIKE '%_pkey'  -- Don't suggest dropping primary keys
    ORDER BY iu.index_size_bytes DESC
$$;
COMMENT ON FUNCTION flight_recorder.unused_indexes(INTERVAL) IS
'Identify unused or rarely used indexes. Returns indexes that may be candidates for removal to save space and improve write performance. Default lookback is 7 days.';


-- Analyzes index efficiency and usage patterns
-- Returns selectivity and scans-per-GB metrics
CREATE OR REPLACE FUNCTION flight_recorder.index_efficiency(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_limit INTEGER DEFAULT 25
)
RETURNS TABLE(
    schemaname          TEXT,
    relname             TEXT,
    indexrelname        TEXT,
    idx_scan_delta      BIGINT,
    idx_tup_read_delta  BIGINT,
    idx_tup_fetch_delta BIGINT,
    selectivity         NUMERIC,
    index_size          TEXT,
    scans_per_gb        NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT DISTINCT ON (i.indexrelid) i.*
        FROM flight_recorder.index_snapshots i
        JOIN flight_recorder.snapshots s ON s.id = i.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY i.indexrelid, s.captured_at DESC
    ),
    end_snap AS (
        SELECT DISTINCT ON (i.indexrelid) i.*
        FROM flight_recorder.index_snapshots i
        JOIN flight_recorder.snapshots s ON s.id = i.snapshot_id
        WHERE s.captured_at >= p_end_time
        ORDER BY i.indexrelid, s.captured_at ASC
    )
    SELECT
        COALESCE(e.schemaname, split_part(e.relid::regclass::text, '.', 1)) AS schemaname,
        COALESCE(e.relname, split_part(e.relid::regclass::text, '.', 2)) AS relname,
        COALESCE(e.indexrelname, split_part(e.indexrelid::regclass::text, '.', 2)) AS indexrelname,
        COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0) AS idx_scan_delta,
        COALESCE(e.idx_tup_read, 0) - COALESCE(s.idx_tup_read, 0) AS idx_tup_read_delta,
        COALESCE(e.idx_tup_fetch, 0) - COALESCE(s.idx_tup_fetch, 0) AS idx_tup_fetch_delta,
        CASE
            WHEN (COALESCE(e.idx_tup_read, 0) - COALESCE(s.idx_tup_read, 0)) > 0
            THEN round(100.0 * (COALESCE(e.idx_tup_fetch, 0) - COALESCE(s.idx_tup_fetch, 0)) /
                             (COALESCE(e.idx_tup_read, 0) - COALESCE(s.idx_tup_read, 0)), 1)
            ELSE NULL
        END AS selectivity,
        flight_recorder._pretty_bytes(e.index_size_bytes) AS index_size,
        CASE
            WHEN COALESCE(e.index_size_bytes, 0) > 0
            THEN round((COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0)) /
                      (e.index_size_bytes / 1073741824.0::numeric), 2)
            ELSE NULL
        END AS scans_per_gb
    FROM end_snap e
    LEFT JOIN start_snap s ON s.indexrelid = e.indexrelid
    WHERE (COALESCE(e.idx_scan, 0) - COALESCE(s.idx_scan, 0)) > 0
    ORDER BY idx_scan_delta DESC
    LIMIT p_limit
$$;
COMMENT ON FUNCTION flight_recorder.index_efficiency(TIMESTAMPTZ, TIMESTAMPTZ, INTEGER) IS
'Analyze index efficiency and usage patterns. Returns selectivity (fetch/read ratio) and scans-per-GB metrics. Low selectivity may indicate poor index choices.';


-- =============================================================================
-- CONFIGURATION SNAPSHOT ANALYSIS FUNCTIONS
-- =============================================================================

-- Detects configuration changes between two time points
-- Returns parameters that changed with old and new values
CREATE OR REPLACE FUNCTION flight_recorder.config_changes(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    parameter_name  TEXT,
    old_value       TEXT,
    new_value       TEXT,
    old_source      TEXT,
    new_source      TEXT,
    changed_at      TIMESTAMPTZ
)
LANGUAGE sql STABLE AS $$
    WITH
    start_configs AS (
        SELECT DISTINCT ON (cs.name) cs.name, cs.setting, cs.unit, cs.source, s.captured_at
        FROM flight_recorder.config_snapshots cs
        JOIN flight_recorder.snapshots s ON s.id = cs.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY cs.name, s.captured_at DESC
    ),
    end_configs AS (
        SELECT DISTINCT ON (cs.name) cs.name, cs.setting, cs.unit, cs.source, s.captured_at
        FROM flight_recorder.config_snapshots cs
        JOIN flight_recorder.snapshots s ON s.id = cs.snapshot_id
        WHERE s.captured_at >= p_end_time
        ORDER BY cs.name, s.captured_at ASC
    )
    SELECT
        COALESCE(e.name, s.name) AS parameter_name,
        s.setting || COALESCE(' ' || s.unit, '') AS old_value,
        e.setting || COALESCE(' ' || e.unit, '') AS new_value,
        s.source AS old_source,
        e.source AS new_source,
        e.captured_at AS changed_at
    FROM end_configs e
    FULL OUTER JOIN start_configs s ON s.name = e.name
    WHERE e.setting IS DISTINCT FROM s.setting
        OR e.source IS DISTINCT FROM s.source
    ORDER BY parameter_name
$$;
COMMENT ON FUNCTION flight_recorder.config_changes(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Detect PostgreSQL configuration changes between two time points. Useful for correlating configuration changes with performance incidents.';


-- Retrieves configuration at a specific point in time
-- Optionally filters by parameter name prefix (category)
CREATE OR REPLACE FUNCTION flight_recorder.config_at(
    p_timestamp TIMESTAMPTZ,
    p_category TEXT DEFAULT NULL
)
RETURNS TABLE(
    parameter_name  TEXT,
    value           TEXT,
    source          TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT ON (cs.name)
        cs.name AS parameter_name,
        cs.setting || COALESCE(' ' || cs.unit, '') AS value,
        cs.source
    FROM flight_recorder.config_snapshots cs
    JOIN flight_recorder.snapshots s ON s.id = cs.snapshot_id
    WHERE s.captured_at <= p_timestamp
        AND (p_category IS NULL OR cs.name LIKE p_category || '%')
    ORDER BY cs.name, s.captured_at DESC
$$;
COMMENT ON FUNCTION flight_recorder.config_at(TIMESTAMPTZ, TEXT) IS
'Retrieve PostgreSQL configuration at a specific point in time. Optionally filter by category prefix (e.g., ''autovacuum'', ''work_mem'').';


-- Performs a health check on current PostgreSQL configuration
-- Returns potential issues and recommendations
CREATE OR REPLACE FUNCTION flight_recorder.config_health_check()
RETURNS TABLE(
    category        TEXT,
    parameter_name  TEXT,
    current_value   TEXT,
    issue           TEXT,
    recommendation  TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_shared_buffers BIGINT;
    v_work_mem BIGINT;
    v_max_connections INTEGER;
BEGIN
    -- Get current values
    SELECT setting::bigint * 8192 INTO v_shared_buffers
    FROM pg_settings WHERE name = 'shared_buffers';

    SELECT setting::bigint * 1024 INTO v_work_mem
    FROM pg_settings WHERE name = 'work_mem';

    SELECT setting::integer INTO v_max_connections
    FROM pg_settings WHERE name = 'max_connections';

    -- Check shared_buffers (should be at least 128 MB for most workloads)
    IF v_shared_buffers < 134217728 THEN  -- < 128 MB
        category := 'memory';
        parameter_name := 'shared_buffers';
        current_value := flight_recorder._pretty_bytes(v_shared_buffers);
        issue := 'Very low shared_buffers';
        recommendation := 'Increase to at least 25% of available RAM';
        RETURN NEXT;
    END IF;

    -- Check work_mem (should be at least 16MB for analytical workloads)
    IF v_work_mem < 16777216 THEN  -- < 16 MB
        category := 'memory';
        parameter_name := 'work_mem';
        current_value := flight_recorder._pretty_bytes(v_work_mem);
        issue := 'Low work_mem may cause disk spills';
        recommendation := 'Consider increasing to 32-64MB, depending on workload';
        RETURN NEXT;
    END IF;

    -- Check max_connections (high values waste RAM)
    IF v_max_connections > 200 THEN
        category := 'connections';
        parameter_name := 'max_connections';
        current_value := v_max_connections::text;
        issue := 'High max_connections wastes memory';
        recommendation := 'Use connection pooling (pgBouncer) instead of high max_connections';
        RETURN NEXT;
    END IF;

    -- Check if statement timeout is set
    IF NOT EXISTS (
        SELECT 1 FROM pg_settings
        WHERE name = 'statement_timeout' AND setting != '0'
    ) THEN
        category := 'safety';
        parameter_name := 'statement_timeout';
        current_value := 'disabled';
        issue := 'No statement timeout protection';
        recommendation := 'Set statement_timeout to prevent runaway queries (e.g., 30s-5min)';
        RETURN NEXT;
    END IF;

    RETURN;
END;
$$;
COMMENT ON FUNCTION flight_recorder.config_health_check() IS
'Perform a health check on current PostgreSQL configuration. Returns potential issues and recommendations for memory, connections, and safety settings.';


-- =============================================================================
-- DATABASE/ROLE CONFIGURATION ANALYSIS FUNCTIONS
-- =============================================================================

-- Retrieves database/role configuration overrides at a specific point in time
-- Optionally filters by database, role, or parameter name prefix
CREATE OR REPLACE FUNCTION flight_recorder.db_role_config_at(
    p_timestamp TIMESTAMPTZ,
    p_database TEXT DEFAULT NULL,
    p_role TEXT DEFAULT NULL,
    p_prefix TEXT DEFAULT NULL
)
RETURNS TABLE(
    database_name   TEXT,
    role_name       TEXT,
    parameter_name  TEXT,
    parameter_value TEXT,
    scope           TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT ON (drc.database_name, drc.role_name, drc.parameter_name)
        NULLIF(drc.database_name, '') AS database_name,
        NULLIF(drc.role_name, '') AS role_name,
        drc.parameter_name,
        drc.parameter_value,
        CASE
            WHEN drc.database_name <> '' AND drc.role_name <> '' THEN 'database+role'
            WHEN drc.database_name <> '' THEN 'database'
            WHEN drc.role_name <> '' THEN 'role'
            ELSE 'unknown'
        END AS scope
    FROM flight_recorder.db_role_config_snapshots drc
    JOIN flight_recorder.snapshots s ON s.id = drc.snapshot_id
    WHERE s.captured_at <= p_timestamp
        AND (p_database IS NULL OR drc.database_name = p_database)
        AND (p_role IS NULL OR drc.role_name = p_role)
        AND (p_prefix IS NULL OR drc.parameter_name LIKE p_prefix || '%')
    ORDER BY drc.database_name, drc.role_name, drc.parameter_name, s.captured_at DESC
$$;
COMMENT ON FUNCTION flight_recorder.db_role_config_at(TIMESTAMPTZ, TEXT, TEXT, TEXT) IS
'Retrieve database/role configuration overrides at a specific point in time. Filter by database, role, or parameter prefix.';


-- Detects database/role configuration changes between two time points
-- Returns parameters that were added, removed, or modified
CREATE OR REPLACE FUNCTION flight_recorder.db_role_config_changes(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    database_name   TEXT,
    role_name       TEXT,
    parameter_name  TEXT,
    old_value       TEXT,
    new_value       TEXT,
    change_type     TEXT
)
LANGUAGE sql STABLE AS $$
    WITH
    start_configs AS (
        SELECT DISTINCT ON (drc.database_name, drc.role_name, drc.parameter_name)
            drc.database_name, drc.role_name, drc.parameter_name, drc.parameter_value
        FROM flight_recorder.db_role_config_snapshots drc
        JOIN flight_recorder.snapshots s ON s.id = drc.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY drc.database_name, drc.role_name, drc.parameter_name, s.captured_at DESC
    ),
    end_configs AS (
        SELECT DISTINCT ON (drc.database_name, drc.role_name, drc.parameter_name)
            drc.database_name, drc.role_name, drc.parameter_name, drc.parameter_value
        FROM flight_recorder.db_role_config_snapshots drc
        JOIN flight_recorder.snapshots s ON s.id = drc.snapshot_id
        WHERE s.captured_at <= p_end_time
        ORDER BY drc.database_name, drc.role_name, drc.parameter_name, s.captured_at DESC
    )
    SELECT
        NULLIF(COALESCE(e.database_name, s.database_name), '') AS database_name,
        NULLIF(COALESCE(e.role_name, s.role_name), '') AS role_name,
        COALESCE(e.parameter_name, s.parameter_name) AS parameter_name,
        s.parameter_value AS old_value,
        e.parameter_value AS new_value,
        CASE
            WHEN s.parameter_name IS NULL THEN 'added'
            WHEN e.parameter_name IS NULL THEN 'removed'
            ELSE 'modified'
        END AS change_type
    FROM end_configs e
    FULL OUTER JOIN start_configs s
        ON s.database_name = e.database_name
        AND s.role_name = e.role_name
        AND s.parameter_name = e.parameter_name
    WHERE e.parameter_value IS DISTINCT FROM s.parameter_value
    ORDER BY database_name NULLS FIRST, role_name NULLS FIRST, parameter_name
$$;
COMMENT ON FUNCTION flight_recorder.db_role_config_changes(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Detect database/role configuration changes between two time points. Returns added, removed, and modified settings.';


-- Provides a summary overview of all database/role configuration overrides
-- Groups by scope (database-only, role-only, or database+role combination)
CREATE OR REPLACE FUNCTION flight_recorder.db_role_config_summary()
RETURNS TABLE(
    scope           TEXT,
    database_name   TEXT,
    role_name       TEXT,
    parameter_count BIGINT,
    parameters      TEXT[]
)
LANGUAGE sql STABLE AS $$
    WITH latest_snapshot AS (
        SELECT id FROM flight_recorder.snapshots ORDER BY captured_at DESC LIMIT 1
    ),
    config_data AS (
        SELECT
            NULLIF(drc.database_name, '') AS database_name,
            NULLIF(drc.role_name, '') AS role_name,
            drc.parameter_name,
            CASE
                WHEN drc.database_name <> '' AND drc.role_name <> '' THEN 'database+role'
                WHEN drc.database_name <> '' THEN 'database'
                WHEN drc.role_name <> '' THEN 'role'
                ELSE 'unknown'
            END AS scope
        FROM flight_recorder.db_role_config_snapshots drc
        WHERE drc.snapshot_id = (SELECT id FROM latest_snapshot)
    )
    SELECT
        scope,
        database_name,
        role_name,
        count(*) AS parameter_count,
        array_agg(parameter_name ORDER BY parameter_name) AS parameters
    FROM config_data
    GROUP BY scope, database_name, role_name
    ORDER BY scope, database_name NULLS FIRST, role_name NULLS FIRST
$$;
COMMENT ON FUNCTION flight_recorder.db_role_config_summary() IS
'Overview of database/role configuration overrides grouped by scope. Shows which databases and roles have custom settings.';


-- =============================================================================
-- TIME-TRAVEL DEBUGGING
-- =============================================================================
-- Enables forensic analysis of "what happened at exactly 10:23:47?"
-- Bridges the gap between sample intervals by interpolating system metrics
-- and surfacing exact-timestamp events from activity samples


-- Main time-travel analysis function
-- Provides interpolated system state at any arbitrary timestamp
-- Input: Target timestamp, context window (default 5 minutes)
-- Output: Interpolated metrics, events, sessions, locks, wait events, confidence, recommendations
CREATE OR REPLACE FUNCTION flight_recorder.what_happened_at(
    p_timestamp TIMESTAMPTZ,
    p_context_window INTERVAL DEFAULT '5 minutes'
)
RETURNS TABLE(
    -- Temporal context
    requested_time TIMESTAMPTZ,
    sample_before TIMESTAMPTZ,
    sample_after TIMESTAMPTZ,
    snapshot_before TIMESTAMPTZ,
    snapshot_after TIMESTAMPTZ,

    -- Interpolated state from snapshots
    est_connections_active NUMERIC,
    est_connections_total NUMERIC,
    est_xact_rate NUMERIC,
    est_blks_hit_ratio NUMERIC,

    -- Exact-timestamp events (from activity samples)
    events JSONB,

    -- Activity analysis (from activity samples ring buffer)
    sessions_active INTEGER,
    long_running_queries INTEGER,
    longest_query_secs NUMERIC,

    -- Lock analysis
    lock_contention_detected BOOLEAN,
    blocked_sessions INTEGER,

    -- Wait events
    top_wait_events JSONB,

    -- Confidence assessment
    confidence TEXT,
    confidence_score NUMERIC,
    data_quality_notes TEXT[],

    -- Actionable recommendations
    recommendations TEXT[]
)
LANGUAGE plpgsql AS $$
DECLARE
    -- Snapshot data
    v_snap_before RECORD;
    v_snap_after RECORD;
    v_snap_gap_secs NUMERIC;

    -- Sample data
    v_sample_before RECORD;
    v_sample_after RECORD;
    v_sample_gap_secs NUMERIC;

    -- Interpolated values
    v_est_active NUMERIC;
    v_est_total NUMERIC;
    v_est_xact_rate NUMERIC;
    v_est_hit_ratio NUMERIC;

    -- Events array
    v_events JSONB := '[]'::jsonb;
    v_event JSONB;

    -- Activity analysis
    v_sessions INTEGER := 0;
    v_long_running INTEGER := 0;
    v_longest_secs NUMERIC := 0;

    -- Lock analysis
    v_lock_detected BOOLEAN := FALSE;
    v_blocked INTEGER := 0;

    -- Wait events
    v_waits JSONB := '[]'::jsonb;

    -- Confidence calculation
    v_confidence_score NUMERIC := 0.5;
    v_confidence_level TEXT := 'low';
    v_notes TEXT[] := ARRAY[]::TEXT[];
    v_recs TEXT[] := ARRAY[]::TEXT[];

    -- Context window bounds
    v_window_start TIMESTAMPTZ;
    v_window_end TIMESTAMPTZ;
BEGIN
    -- Calculate window bounds
    v_window_start := p_timestamp - p_context_window;
    v_window_end := p_timestamp + p_context_window;

    -- ==========================================================================
    -- STEP 1: Find surrounding snapshots
    -- ==========================================================================
    SELECT * INTO v_snap_before
    FROM flight_recorder.snapshots
    WHERE captured_at <= p_timestamp
    ORDER BY captured_at DESC
    LIMIT 1;

    SELECT * INTO v_snap_after
    FROM flight_recorder.snapshots
    WHERE captured_at >= p_timestamp
    ORDER BY captured_at ASC
    LIMIT 1;

    -- Calculate snapshot gap
    IF v_snap_before IS NOT NULL AND v_snap_after IS NOT NULL THEN
        v_snap_gap_secs := EXTRACT(EPOCH FROM (v_snap_after.captured_at - v_snap_before.captured_at));
    END IF;

    -- ==========================================================================
    -- STEP 2: Find surrounding samples (from ring buffer)
    -- ==========================================================================
    SELECT sr.* INTO v_sample_before
    FROM flight_recorder.samples_ring sr
    WHERE sr.captured_at <= p_timestamp
      AND sr.captured_at > '1970-01-01'::timestamptz
    ORDER BY sr.captured_at DESC
    LIMIT 1;

    SELECT sr.* INTO v_sample_after
    FROM flight_recorder.samples_ring sr
    WHERE sr.captured_at >= p_timestamp
      AND sr.captured_at > '1970-01-01'::timestamptz
    ORDER BY sr.captured_at ASC
    LIMIT 1;

    -- Calculate sample gap
    IF v_sample_before IS NOT NULL AND v_sample_after IS NOT NULL THEN
        v_sample_gap_secs := EXTRACT(EPOCH FROM (v_sample_after.captured_at - v_sample_before.captured_at));
    END IF;

    -- ==========================================================================
    -- STEP 3: Interpolate snapshot metrics
    -- ==========================================================================
    IF v_snap_before IS NOT NULL AND v_snap_after IS NOT NULL THEN
        v_est_active := flight_recorder._interpolate_metric(
            v_snap_before.connections_active::NUMERIC,
            v_snap_before.captured_at,
            v_snap_after.connections_active::NUMERIC,
            v_snap_after.captured_at,
            p_timestamp
        );

        v_est_total := flight_recorder._interpolate_metric(
            v_snap_before.connections_total::NUMERIC,
            v_snap_before.captured_at,
            v_snap_after.connections_total::NUMERIC,
            v_snap_after.captured_at,
            p_timestamp
        );

        -- Calculate transaction rate delta
        IF v_snap_gap_secs > 0 AND
           v_snap_before.xact_commit IS NOT NULL AND
           v_snap_after.xact_commit IS NOT NULL THEN
            v_est_xact_rate := round(
                ((v_snap_after.xact_commit - v_snap_before.xact_commit) +
                 (v_snap_after.xact_rollback - v_snap_before.xact_rollback))::NUMERIC / v_snap_gap_secs,
                1
            );
        END IF;

        -- Calculate buffer hit ratio
        IF v_snap_after.blks_hit IS NOT NULL AND
           v_snap_after.blks_read IS NOT NULL AND
           (v_snap_after.blks_hit + v_snap_after.blks_read) > 0 THEN
            v_est_hit_ratio := round(
                v_snap_after.blks_hit::NUMERIC /
                NULLIF(v_snap_after.blks_hit + v_snap_after.blks_read, 0) * 100,
                2
            );
        END IF;
    ELSIF v_snap_before IS NOT NULL THEN
        -- Only have before snapshot - use its values
        v_est_active := v_snap_before.connections_active;
        v_est_total := v_snap_before.connections_total;
        v_notes := array_append(v_notes, 'No snapshot after target time - using last known values');
    ELSIF v_snap_after IS NOT NULL THEN
        -- Only have after snapshot - use its values
        v_est_active := v_snap_after.connections_active;
        v_est_total := v_snap_after.connections_total;
        v_notes := array_append(v_notes, 'No snapshot before target time - using next known values');
    ELSE
        v_notes := array_append(v_notes, 'No snapshots found in range');
    END IF;

    -- ==========================================================================
    -- STEP 4: Collect exact-timestamp events from activity samples
    -- ==========================================================================

    -- Check for checkpoint event near target time
    IF v_snap_before IS NOT NULL AND v_snap_before.checkpoint_time IS NOT NULL THEN
        IF v_snap_before.checkpoint_time BETWEEN v_window_start AND v_window_end THEN
            v_event := jsonb_build_object(
                'type', 'checkpoint',
                'time', v_snap_before.checkpoint_time,
                'offset_secs', EXTRACT(EPOCH FROM (v_snap_before.checkpoint_time - p_timestamp))::INTEGER
            );
            v_events := v_events || v_event;
            v_notes := array_append(v_notes, format('Checkpoint at %s provides anchor',
                to_char(v_snap_before.checkpoint_time, 'HH24:MI:SS')));
        END IF;
    END IF;

    -- Check for archiver activity
    IF v_snap_before IS NOT NULL AND v_snap_before.last_archived_time IS NOT NULL THEN
        IF v_snap_before.last_archived_time BETWEEN v_window_start AND v_window_end THEN
            v_event := jsonb_build_object(
                'type', 'wal_archived',
                'time', v_snap_before.last_archived_time,
                'offset_secs', EXTRACT(EPOCH FROM (v_snap_before.last_archived_time - p_timestamp))::INTEGER,
                'wal_file', v_snap_before.last_archived_wal
            );
            v_events := v_events || v_event;
        END IF;
    END IF;

    -- Check for archiver failure
    IF v_snap_before IS NOT NULL AND v_snap_before.last_failed_time IS NOT NULL THEN
        IF v_snap_before.last_failed_time BETWEEN v_window_start AND v_window_end THEN
            v_event := jsonb_build_object(
                'type', 'archive_failed',
                'time', v_snap_before.last_failed_time,
                'offset_secs', EXTRACT(EPOCH FROM (v_snap_before.last_failed_time - p_timestamp))::INTEGER,
                'wal_file', v_snap_before.last_failed_wal
            );
            v_events := v_events || v_event;
            v_recs := array_append(v_recs, 'Investigate WAL archiving failure');
        END IF;
    END IF;

    -- ==========================================================================
    -- STEP 5: Analyze activity from samples ring buffer
    -- ==========================================================================
    IF v_sample_before IS NOT NULL THEN
        -- Count active sessions
        SELECT COUNT(*), COUNT(*) FILTER (WHERE a.state = 'active')
        INTO v_sessions, v_sessions
        FROM flight_recorder.activity_samples_ring a
        WHERE a.slot_id = v_sample_before.slot_id
          AND a.pid IS NOT NULL;

        -- Find long-running queries (> 60 seconds at sample time)
        SELECT COUNT(*), MAX(EXTRACT(EPOCH FROM (v_sample_before.captured_at - a.query_start)))
        INTO v_long_running, v_longest_secs
        FROM flight_recorder.activity_samples_ring a
        WHERE a.slot_id = v_sample_before.slot_id
          AND a.pid IS NOT NULL
          AND a.state = 'active'
          AND a.query_start IS NOT NULL
          AND a.query_start < v_sample_before.captured_at - interval '60 seconds';

        -- Collect query start events within window
        FOR v_event IN
            SELECT jsonb_build_object(
                'type', 'query_started',
                'time', a.query_start,
                'offset_secs', EXTRACT(EPOCH FROM (a.query_start - p_timestamp))::INTEGER,
                'pid', a.pid,
                'user', a.usename,
                'query_preview', a.query_preview
            )
            FROM flight_recorder.activity_samples_ring a
            WHERE a.slot_id = v_sample_before.slot_id
              AND a.pid IS NOT NULL
              AND a.query_start BETWEEN v_window_start AND v_window_end
            ORDER BY a.query_start
            LIMIT 10
        LOOP
            v_events := v_events || v_event;
        END LOOP;

        -- Collect transaction start events within window
        FOR v_event IN
            SELECT jsonb_build_object(
                'type', 'transaction_started',
                'time', a.xact_start,
                'offset_secs', EXTRACT(EPOCH FROM (a.xact_start - p_timestamp))::INTEGER,
                'pid', a.pid,
                'user', a.usename
            )
            FROM flight_recorder.activity_samples_ring a
            WHERE a.slot_id = v_sample_before.slot_id
              AND a.pid IS NOT NULL
              AND a.xact_start BETWEEN v_window_start AND v_window_end
              AND a.xact_start != a.query_start  -- Avoid duplicates
            ORDER BY a.xact_start
            LIMIT 10
        LOOP
            v_events := v_events || v_event;
        END LOOP;
    END IF;

    -- ==========================================================================
    -- STEP 6: Analyze lock contention
    -- ==========================================================================
    IF v_sample_before IS NOT NULL THEN
        SELECT COUNT(*) > 0, COUNT(*)
        INTO v_lock_detected, v_blocked
        FROM flight_recorder.lock_samples_ring l
        WHERE l.slot_id = v_sample_before.slot_id
          AND l.blocked_pid IS NOT NULL;

        IF v_blocked > 0 THEN
            v_recs := array_append(v_recs, format('Investigate %s blocked sessions', v_blocked));
        END IF;
    END IF;

    -- ==========================================================================
    -- STEP 7: Analyze wait events
    -- ==========================================================================
    IF v_sample_before IS NOT NULL THEN
        SELECT jsonb_agg(w ORDER BY w->>'count' DESC)
        INTO v_waits
        FROM (
            SELECT jsonb_build_object(
                'wait_event_type', ws.wait_event_type,
                'wait_event', ws.wait_event,
                'count', ws.count
            ) AS w
            FROM flight_recorder.wait_samples_ring ws
            WHERE ws.slot_id = v_sample_before.slot_id
              AND ws.wait_event IS NOT NULL
            ORDER BY ws.count DESC NULLS LAST
            LIMIT 5
        ) sub;
    END IF;

    -- ==========================================================================
    -- STEP 8: Calculate confidence score
    -- ==========================================================================
    -- Base score on sample gap
    IF v_sample_gap_secs IS NOT NULL THEN
        IF v_sample_gap_secs < 60 THEN
            v_confidence_score := 0.9;
        ELSIF v_sample_gap_secs < 300 THEN
            v_confidence_score := 0.7 + (0.2 * (300 - v_sample_gap_secs) / 240);
        ELSIF v_sample_gap_secs < 600 THEN
            v_confidence_score := 0.5 + (0.2 * (600 - v_sample_gap_secs) / 300);
        ELSE
            v_confidence_score := 0.3;
        END IF;

        v_notes := array_append(v_notes, format('Sample gap is %s seconds', v_sample_gap_secs::INTEGER));
    ELSE
        v_confidence_score := 0.2;
        v_notes := array_append(v_notes, 'No sample data in ring buffer');
    END IF;

    -- Bonus for exact-timestamp events
    IF jsonb_array_length(v_events) > 0 THEN
        v_confidence_score := LEAST(1.0, v_confidence_score + 0.1);
        v_notes := array_append(v_notes, format('%s exact-timestamp events found', jsonb_array_length(v_events)));
    END IF;

    -- Bonus for target close to sample
    IF v_sample_before IS NOT NULL THEN
        DECLARE
            v_closest_gap NUMERIC;
        BEGIN
            v_closest_gap := LEAST(
                ABS(EXTRACT(EPOCH FROM (p_timestamp - v_sample_before.captured_at))),
                COALESCE(ABS(EXTRACT(EPOCH FROM (p_timestamp - v_sample_after.captured_at))), 999999)
            );
            IF v_closest_gap < 30 THEN
                v_confidence_score := LEAST(1.0, v_confidence_score + 0.05);
            END IF;
        END;
    END IF;

    -- Determine confidence level
    IF v_confidence_score >= 0.8 THEN
        v_confidence_level := 'high';
    ELSIF v_confidence_score >= 0.6 THEN
        v_confidence_level := 'medium';
    ELSIF v_confidence_score >= 0.4 THEN
        v_confidence_level := 'low';
    ELSE
        v_confidence_level := 'very_low';
    END IF;

    -- ==========================================================================
    -- STEP 9: Generate recommendations
    -- ==========================================================================
    IF v_long_running > 0 THEN
        v_recs := array_append(v_recs, format('Review %s long-running queries (longest: %s sec)',
            v_long_running, round(v_longest_secs)));
    END IF;

    IF v_est_hit_ratio IS NOT NULL AND v_est_hit_ratio < 95 THEN
        v_recs := array_append(v_recs, format('Buffer hit ratio low (%s%%) - consider increasing shared_buffers',
            v_est_hit_ratio));
    END IF;

    -- Check for checkpoint impact
    FOR v_event IN SELECT * FROM jsonb_array_elements(v_events)
    LOOP
        IF v_event->>'type' = 'checkpoint' THEN
            v_recs := array_append(v_recs, 'Review checkpoint impact on performance');
        END IF;
    END LOOP;

    IF array_length(v_recs, 1) IS NULL THEN
        v_recs := array_append(v_recs, 'No immediate concerns detected');
    END IF;

    -- ==========================================================================
    -- RETURN RESULTS
    -- ==========================================================================
    RETURN QUERY SELECT
        p_timestamp,
        v_sample_before.captured_at,
        v_sample_after.captured_at,
        v_snap_before.captured_at,
        v_snap_after.captured_at,
        v_est_active,
        v_est_total,
        v_est_xact_rate,
        v_est_hit_ratio,
        COALESCE(v_events, '[]'::jsonb),
        v_sessions,
        COALESCE(v_long_running, 0),
        COALESCE(v_longest_secs, 0),
        v_lock_detected,
        v_blocked,
        COALESCE(v_waits, '[]'::jsonb),
        v_confidence_level,
        round(v_confidence_score, 2),
        v_notes,
        v_recs;
END;
$$;
COMMENT ON FUNCTION flight_recorder.what_happened_at IS
'Time-travel debugging: Forensic analysis of system state at any timestamp. Interpolates between samples to estimate connections, transaction rates, and buffer hit ratio. Surfaces exact-timestamp events (checkpoints, query starts, transaction starts) and analyzes sessions, locks, and wait events. Returns confidence score (0-1) based on data proximity. Use for incident investigation: SELECT * FROM flight_recorder.what_happened_at(''2024-01-15 10:23:47'');';


-- Timeline reconstruction for incident analysis
-- Merges events from multiple sources into a unified, chronological timeline
-- Input: Start and end timestamps for the incident window
-- Output: Ordered timeline of events with type, description, and details
CREATE OR REPLACE FUNCTION flight_recorder.incident_timeline(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    event_time TIMESTAMPTZ,
    event_type TEXT,
    description TEXT,
    details JSONB
)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY
    WITH all_events AS (
        -- Checkpoint events from snapshots
        SELECT DISTINCT
            s.checkpoint_time AS event_time,
            'checkpoint'::TEXT AS event_type,
            format('Checkpoint completed (LSN: %s)', s.checkpoint_lsn::TEXT) AS description,
            jsonb_build_object(
                'checkpoint_lsn', s.checkpoint_lsn::TEXT,
                'buffers_written', s.ckpt_buffers,
                'write_time_ms', round(s.ckpt_write_time::NUMERIC, 1),
                'sync_time_ms', round(s.ckpt_sync_time::NUMERIC, 1)
            ) AS details
        FROM flight_recorder.snapshots s
        WHERE s.checkpoint_time BETWEEN p_start_time AND p_end_time
          AND s.checkpoint_time IS NOT NULL

        UNION ALL

        -- WAL archive events
        SELECT DISTINCT
            s.last_archived_time AS event_time,
            'wal_archived'::TEXT AS event_type,
            format('WAL file archived: %s', s.last_archived_wal) AS description,
            jsonb_build_object(
                'wal_file', s.last_archived_wal,
                'archived_count', s.archived_count
            ) AS details
        FROM flight_recorder.snapshots s
        WHERE s.last_archived_time BETWEEN p_start_time AND p_end_time
          AND s.last_archived_time IS NOT NULL

        UNION ALL

        -- WAL archive failures
        SELECT DISTINCT
            s.last_failed_time AS event_time,
            'archive_failed'::TEXT AS event_type,
            format('WAL archive failed: %s', s.last_failed_wal) AS description,
            jsonb_build_object(
                'wal_file', s.last_failed_wal,
                'failed_count', s.failed_count
            ) AS details
        FROM flight_recorder.snapshots s
        WHERE s.last_failed_time BETWEEN p_start_time AND p_end_time
          AND s.last_failed_time IS NOT NULL

        UNION ALL

        -- Query start events from ring buffer
        SELECT
            a.query_start AS event_time,
            'query_started'::TEXT AS event_type,
            format('Query started by %s (pid %s)', COALESCE(a.usename, 'unknown'), a.pid) AS description,
            jsonb_build_object(
                'pid', a.pid,
                'user', a.usename,
                'application', a.application_name,
                'client_addr', a.client_addr::TEXT,
                'query_preview', a.query_preview
            ) AS details
        FROM flight_recorder.activity_samples_ring a
        JOIN flight_recorder.samples_ring sr ON sr.slot_id = a.slot_id
        WHERE a.query_start BETWEEN p_start_time AND p_end_time
          AND a.query_start IS NOT NULL
          AND a.pid IS NOT NULL
          AND sr.captured_at > '1970-01-01'::timestamptz

        UNION ALL

        -- Transaction start events from ring buffer
        SELECT
            a.xact_start AS event_time,
            'transaction_started'::TEXT AS event_type,
            format('Transaction started by %s (pid %s)', COALESCE(a.usename, 'unknown'), a.pid) AS description,
            jsonb_build_object(
                'pid', a.pid,
                'user', a.usename,
                'application', a.application_name
            ) AS details
        FROM flight_recorder.activity_samples_ring a
        JOIN flight_recorder.samples_ring sr ON sr.slot_id = a.slot_id
        WHERE a.xact_start BETWEEN p_start_time AND p_end_time
          AND a.xact_start IS NOT NULL
          AND a.pid IS NOT NULL
          AND sr.captured_at > '1970-01-01'::timestamptz
          AND (a.xact_start != a.query_start OR a.query_start IS NULL)

        UNION ALL

        -- Backend start events (new connections)
        SELECT
            a.backend_start AS event_time,
            'connection_opened'::TEXT AS event_type,
            format('Connection opened by %s from %s', COALESCE(a.usename, 'unknown'),
                   COALESCE(a.client_addr::TEXT, 'local')) AS description,
            jsonb_build_object(
                'pid', a.pid,
                'user', a.usename,
                'application', a.application_name,
                'client_addr', a.client_addr::TEXT,
                'backend_type', a.backend_type
            ) AS details
        FROM flight_recorder.activity_samples_ring a
        JOIN flight_recorder.samples_ring sr ON sr.slot_id = a.slot_id
        WHERE a.backend_start BETWEEN p_start_time AND p_end_time
          AND a.backend_start IS NOT NULL
          AND a.pid IS NOT NULL
          AND sr.captured_at > '1970-01-01'::timestamptz

        UNION ALL

        -- Lock contention events
        SELECT
            sr.captured_at AS event_time,
            'lock_contention'::TEXT AS event_type,
            format('Session %s blocked by %s on %s lock',
                   l.blocked_pid, l.blocking_pid, l.lock_type) AS description,
            jsonb_build_object(
                'blocked_pid', l.blocked_pid,
                'blocked_user', l.blocked_user,
                'blocked_query', l.blocked_query_preview,
                'blocking_pid', l.blocking_pid,
                'blocking_user', l.blocking_user,
                'blocking_query', l.blocking_query_preview,
                'lock_type', l.lock_type,
                'duration', l.blocked_duration::TEXT
            ) AS details
        FROM flight_recorder.lock_samples_ring l
        JOIN flight_recorder.samples_ring sr ON sr.slot_id = l.slot_id
        WHERE sr.captured_at BETWEEN p_start_time AND p_end_time
          AND l.blocked_pid IS NOT NULL
          AND sr.captured_at > '1970-01-01'::timestamptz

        UNION ALL

        -- Wait event spikes from aggregates
        SELECT
            wa.start_time AS event_time,
            'wait_spike'::TEXT AS event_type,
            format('Wait spike: %s/%s (max %s concurrent)',
                   wa.wait_event_type, wa.wait_event, wa.max_waiters) AS description,
            jsonb_build_object(
                'wait_event_type', wa.wait_event_type,
                'wait_event', wa.wait_event,
                'max_concurrent', wa.max_waiters,
                'avg_concurrent', round(wa.avg_waiters, 1),
                'sample_count', wa.sample_count
            ) AS details
        FROM flight_recorder.wait_event_aggregates wa
        WHERE wa.start_time BETWEEN p_start_time AND p_end_time
          AND wa.max_waiters >= 3  -- Only show significant waits

        UNION ALL

        -- Snapshot captures (system state markers)
        SELECT
            s.captured_at AS event_time,
            'snapshot'::TEXT AS event_type,
            format('System snapshot: %s active connections, %s TPS',
                   s.connections_active,
                   CASE WHEN lag(s.xact_commit) OVER (ORDER BY s.captured_at) IS NOT NULL
                        THEN round((s.xact_commit - lag(s.xact_commit) OVER (ORDER BY s.captured_at))::NUMERIC /
                                   EXTRACT(EPOCH FROM (s.captured_at - lag(s.captured_at) OVER (ORDER BY s.captured_at))), 1)
                        ELSE NULL
                   END) AS description,
            jsonb_build_object(
                'connections_active', s.connections_active,
                'connections_total', s.connections_total,
                'xact_commit', s.xact_commit,
                'blks_hit', s.blks_hit,
                'blks_read', s.blks_read,
                'temp_bytes', s.temp_bytes
            ) AS details
        FROM flight_recorder.snapshots s
        WHERE s.captured_at BETWEEN p_start_time AND p_end_time
    )
    SELECT ae.event_time, ae.event_type, ae.description, ae.details
    FROM all_events ae
    WHERE ae.event_time IS NOT NULL
    ORDER BY ae.event_time;
END;
$$;
COMMENT ON FUNCTION flight_recorder.incident_timeline IS
'Reconstructs a unified timeline for incident analysis by merging events from multiple sources: checkpoints, WAL archiving, query/transaction starts, connection opens, lock contention, wait spikes, and snapshots. Returns chronologically ordered events with type, description, and JSON details. Use for incident review: SELECT * FROM flight_recorder.incident_timeline(now() - interval ''2 hours'', now() - interval ''1 hour'');';


-- Blast Radius Analysis
-- Comprehensive impact assessment of database incidents
-- Answers: "What was the collateral damage from this incident?"
-- Input: Start and end timestamps for the incident window
-- Output: Structured impact assessment including locks, queries, connections, applications
CREATE OR REPLACE FUNCTION flight_recorder.blast_radius(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    -- Time window
    incident_start TIMESTAMPTZ,
    incident_end TIMESTAMPTZ,
    duration_seconds NUMERIC,

    -- Lock impact
    blocked_sessions_total INTEGER,
    blocked_sessions_max_concurrent INTEGER,
    max_block_duration INTERVAL,
    avg_block_duration INTERVAL,
    lock_types JSONB,

    -- Query degradation
    degraded_queries_count INTEGER,
    degraded_queries JSONB,

    -- Connection impact
    connections_before INTEGER,
    connections_during_avg INTEGER,
    connections_during_max INTEGER,
    connection_increase_pct NUMERIC,

    -- Application impact
    affected_applications JSONB,

    -- Wait event impact
    top_wait_events JSONB,

    -- Transaction throughput
    tps_before NUMERIC,
    tps_during NUMERIC,
    tps_change_pct NUMERIC,

    -- Summary
    severity TEXT,
    impact_summary TEXT[],
    recommendations TEXT[]
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_duration INTERVAL;
    v_baseline_start TIMESTAMPTZ;
    v_baseline_end TIMESTAMPTZ;

    -- Lock impact variables
    v_blocked_total INTEGER := 0;
    v_blocked_max_concurrent INTEGER := 0;
    v_max_block_duration INTERVAL;
    v_avg_block_duration INTERVAL;
    v_lock_types JSONB := '[]'::jsonb;

    -- Query degradation variables
    v_degraded_count INTEGER := 0;
    v_degraded_queries JSONB := '[]'::jsonb;

    -- Connection variables
    v_conn_before INTEGER := 0;
    v_conn_during_avg INTEGER := 0;
    v_conn_during_max INTEGER := 0;
    v_conn_increase_pct NUMERIC := 0;

    -- Application impact
    v_affected_apps JSONB := '[]'::jsonb;

    -- Wait events
    v_top_waits JSONB := '[]'::jsonb;

    -- Throughput variables
    v_tps_before NUMERIC := 0;
    v_tps_during NUMERIC := 0;
    v_tps_change_pct NUMERIC := 0;

    -- Severity calculation
    v_severity TEXT := 'low';
    v_impact_summary TEXT[] := ARRAY[]::TEXT[];
    v_recommendations TEXT[] := ARRAY[]::TEXT[];

    -- Severity scores
    v_lock_severity INTEGER := 0;
    v_duration_severity INTEGER := 0;
    v_conn_severity INTEGER := 0;
    v_tps_severity INTEGER := 0;
    v_query_severity INTEGER := 0;
BEGIN
    -- Calculate duration and baseline period
    v_duration := p_end_time - p_start_time;
    v_baseline_start := p_start_time - v_duration;
    v_baseline_end := p_start_time;

    -- =========================================================================
    -- Lock Impact Analysis
    -- =========================================================================

    -- Total blocked sessions and durations from ring buffer
    SELECT
        COUNT(DISTINCT l.blocked_pid),
        MAX(l.blocked_duration),
        AVG(l.blocked_duration)
    INTO v_blocked_total, v_max_block_duration, v_avg_block_duration
    FROM flight_recorder.lock_samples_ring l
    JOIN flight_recorder.samples_ring sr ON sr.slot_id = l.slot_id
    WHERE sr.captured_at BETWEEN p_start_time AND p_end_time
      AND l.blocked_pid IS NOT NULL;

    -- Also check archive for longer incidents
    IF v_blocked_total = 0 OR v_blocked_total IS NULL THEN
        SELECT
            COUNT(DISTINCT blocked_pid),
            MAX(blocked_duration),
            AVG(blocked_duration)
        INTO v_blocked_total, v_max_block_duration, v_avg_block_duration
        FROM flight_recorder.lock_samples_archive
        WHERE captured_at BETWEEN p_start_time AND p_end_time
          AND blocked_pid IS NOT NULL;
    END IF;

    v_blocked_total := COALESCE(v_blocked_total, 0);

    -- Max concurrent blocked sessions (per sample)
    SELECT COALESCE(MAX(blocked_count), 0)
    INTO v_blocked_max_concurrent
    FROM (
        SELECT COUNT(DISTINCT l.blocked_pid) AS blocked_count
        FROM flight_recorder.lock_samples_ring l
        JOIN flight_recorder.samples_ring sr ON sr.slot_id = l.slot_id
        WHERE sr.captured_at BETWEEN p_start_time AND p_end_time
          AND l.blocked_pid IS NOT NULL
        GROUP BY sr.slot_id
    ) per_sample;

    -- Lock types breakdown
    SELECT COALESCE(jsonb_agg(jsonb_build_object('type', lock_type, 'count', cnt) ORDER BY cnt DESC), '[]'::jsonb)
    INTO v_lock_types
    FROM (
        SELECT l.lock_type, COUNT(*) AS cnt
        FROM flight_recorder.lock_samples_ring l
        JOIN flight_recorder.samples_ring sr ON sr.slot_id = l.slot_id
        WHERE sr.captured_at BETWEEN p_start_time AND p_end_time
          AND l.blocked_pid IS NOT NULL
          AND l.lock_type IS NOT NULL
        GROUP BY l.lock_type
        ORDER BY cnt DESC
        LIMIT 10
    ) lt;

    -- =========================================================================
    -- Query Degradation Analysis
    -- =========================================================================

    WITH baseline AS (
        SELECT
            ss.queryid,
            left(ss.query_preview, 80) AS query_preview,
            AVG(ss.mean_exec_time) AS baseline_ms
        FROM flight_recorder.statement_snapshots ss
        JOIN flight_recorder.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at BETWEEN v_baseline_start AND v_baseline_end
          AND ss.mean_exec_time IS NOT NULL
          AND ss.mean_exec_time > 0
        GROUP BY ss.queryid, left(ss.query_preview, 80)
        HAVING COUNT(*) >= 1
    ),
    during AS (
        SELECT
            ss.queryid,
            AVG(ss.mean_exec_time) AS during_ms
        FROM flight_recorder.statement_snapshots ss
        JOIN flight_recorder.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at BETWEEN p_start_time AND p_end_time
          AND ss.mean_exec_time IS NOT NULL
          AND ss.mean_exec_time > 0
        GROUP BY ss.queryid
        HAVING COUNT(*) >= 1
    ),
    degraded AS (
        SELECT
            b.queryid,
            b.query_preview,
            round(b.baseline_ms::numeric, 2) AS baseline_ms,
            round(d.during_ms::numeric, 2) AS during_ms,
            round((100.0 * (d.during_ms - b.baseline_ms) / NULLIF(b.baseline_ms, 0))::numeric, 1) AS slowdown_pct
        FROM baseline b
        JOIN during d ON d.queryid = b.queryid
        WHERE d.during_ms > b.baseline_ms * 1.5  -- 50%+ slower
        ORDER BY (d.during_ms - b.baseline_ms) DESC
        LIMIT 10
    )
    SELECT
        COUNT(*)::integer,
        COALESCE(jsonb_agg(jsonb_build_object(
            'queryid', queryid,
            'query_preview', query_preview,
            'baseline_ms', baseline_ms,
            'during_ms', during_ms,
            'slowdown_pct', slowdown_pct
        )), '[]'::jsonb)
    INTO v_degraded_count, v_degraded_queries
    FROM degraded;

    v_degraded_count := COALESCE(v_degraded_count, 0);

    -- =========================================================================
    -- Connection Impact Analysis
    -- =========================================================================

    -- Baseline connections (average before incident)
    SELECT COALESCE(AVG(connections_total), 0)::integer
    INTO v_conn_before
    FROM flight_recorder.snapshots
    WHERE captured_at BETWEEN v_baseline_start AND v_baseline_end;

    -- During incident connections
    SELECT
        COALESCE(AVG(connections_total), 0)::integer,
        COALESCE(MAX(connections_total), 0)::integer
    INTO v_conn_during_avg, v_conn_during_max
    FROM flight_recorder.snapshots
    WHERE captured_at BETWEEN p_start_time AND p_end_time;

    -- Connection increase percentage
    IF v_conn_before > 0 THEN
        v_conn_increase_pct := round(100.0 * (v_conn_during_avg - v_conn_before) / v_conn_before, 1);
    END IF;

    -- =========================================================================
    -- Application Impact Analysis
    -- =========================================================================

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'app_name', app,
        'blocked_count', blocked_count,
        'max_wait', max_wait
    ) ORDER BY blocked_count DESC), '[]'::jsonb)
    INTO v_affected_apps
    FROM (
        SELECT
            COALESCE(l.blocked_app, 'unknown') AS app,
            COUNT(DISTINCT l.blocked_pid) AS blocked_count,
            MAX(l.blocked_duration) AS max_wait
        FROM flight_recorder.lock_samples_ring l
        JOIN flight_recorder.samples_ring sr ON sr.slot_id = l.slot_id
        WHERE sr.captured_at BETWEEN p_start_time AND p_end_time
          AND l.blocked_pid IS NOT NULL
        GROUP BY COALESCE(l.blocked_app, 'unknown')
        ORDER BY blocked_count DESC
        LIMIT 10
    ) apps;

    -- =========================================================================
    -- Wait Event Analysis
    -- =========================================================================

    WITH baseline_waits AS (
        SELECT
            w.wait_event_type,
            w.wait_event,
            SUM(w.count) AS total_count
        FROM flight_recorder.wait_samples_ring w
        JOIN flight_recorder.samples_ring sr ON sr.slot_id = w.slot_id
        WHERE sr.captured_at BETWEEN v_baseline_start AND v_baseline_end
          AND w.wait_event IS NOT NULL
        GROUP BY w.wait_event_type, w.wait_event
    ),
    during_waits AS (
        SELECT
            w.wait_event_type,
            w.wait_event,
            SUM(w.count) AS total_count
        FROM flight_recorder.wait_samples_ring w
        JOIN flight_recorder.samples_ring sr ON sr.slot_id = w.slot_id
        WHERE sr.captured_at BETWEEN p_start_time AND p_end_time
          AND w.wait_event IS NOT NULL
        GROUP BY w.wait_event_type, w.wait_event
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'wait_type', d.wait_event_type,
        'wait_event', d.wait_event,
        'total_count', d.total_count,
        'pct_increase', CASE
            WHEN COALESCE(b.total_count, 0) > 0
            THEN round(100.0 * (d.total_count - COALESCE(b.total_count, 0)) / b.total_count, 1)
            ELSE NULL
        END
    ) ORDER BY d.total_count DESC), '[]'::jsonb)
    INTO v_top_waits
    FROM during_waits d
    LEFT JOIN baseline_waits b ON b.wait_event_type = d.wait_event_type
                               AND b.wait_event = d.wait_event
    WHERE d.total_count > 0
    LIMIT 10;

    -- =========================================================================
    -- Transaction Throughput Analysis
    -- =========================================================================

    -- Calculate TPS before incident
    WITH baseline_tps AS (
        SELECT
            xact_commit,
            captured_at,
            LAG(xact_commit) OVER (ORDER BY captured_at) AS prev_commit,
            LAG(captured_at) OVER (ORDER BY captured_at) AS prev_time
        FROM flight_recorder.snapshots
        WHERE captured_at BETWEEN v_baseline_start AND v_baseline_end
    )
    SELECT COALESCE(AVG(
        CASE
            WHEN prev_commit IS NOT NULL AND prev_time IS NOT NULL
                 AND EXTRACT(EPOCH FROM (captured_at - prev_time)) > 0
            THEN (xact_commit - prev_commit)::numeric / EXTRACT(EPOCH FROM (captured_at - prev_time))
            ELSE NULL
        END
    ), 0)
    INTO v_tps_before
    FROM baseline_tps;

    -- Calculate TPS during incident
    WITH during_tps AS (
        SELECT
            xact_commit,
            captured_at,
            LAG(xact_commit) OVER (ORDER BY captured_at) AS prev_commit,
            LAG(captured_at) OVER (ORDER BY captured_at) AS prev_time
        FROM flight_recorder.snapshots
        WHERE captured_at BETWEEN p_start_time AND p_end_time
    )
    SELECT COALESCE(AVG(
        CASE
            WHEN prev_commit IS NOT NULL AND prev_time IS NOT NULL
                 AND EXTRACT(EPOCH FROM (captured_at - prev_time)) > 0
            THEN (xact_commit - prev_commit)::numeric / EXTRACT(EPOCH FROM (captured_at - prev_time))
            ELSE NULL
        END
    ), 0)
    INTO v_tps_during
    FROM during_tps;

    -- TPS change percentage
    IF v_tps_before > 0 THEN
        v_tps_change_pct := round(100.0 * (v_tps_during - v_tps_before) / v_tps_before, 1);
    END IF;

    -- =========================================================================
    -- Severity Classification
    -- =========================================================================

    -- Blocked sessions severity: 1-5=low, 6-20=medium, 21-50=high, >50=critical
    v_lock_severity := CASE
        WHEN v_blocked_total > 50 THEN 4
        WHEN v_blocked_total > 20 THEN 3
        WHEN v_blocked_total > 5 THEN 2
        WHEN v_blocked_total > 0 THEN 1
        ELSE 0
    END;

    -- Block duration severity: <10s=low, 10-60s=medium, 1-5min=high, >5min=critical
    v_duration_severity := CASE
        WHEN v_max_block_duration > interval '5 minutes' THEN 4
        WHEN v_max_block_duration > interval '1 minute' THEN 3
        WHEN v_max_block_duration > interval '10 seconds' THEN 2
        WHEN v_max_block_duration IS NOT NULL THEN 1
        ELSE 0
    END;

    -- Connection increase severity: <25%=low, 25-50%=medium, 50-100%=high, >100%=critical
    v_conn_severity := CASE
        WHEN v_conn_increase_pct > 100 THEN 4
        WHEN v_conn_increase_pct > 50 THEN 3
        WHEN v_conn_increase_pct > 25 THEN 2
        WHEN v_conn_increase_pct > 0 THEN 1
        ELSE 0
    END;

    -- TPS decrease severity: <10%=low, 10-25%=medium, 25-50%=high, >50%=critical
    v_tps_severity := CASE
        WHEN v_tps_change_pct < -50 THEN 4
        WHEN v_tps_change_pct < -25 THEN 3
        WHEN v_tps_change_pct < -10 THEN 2
        WHEN v_tps_change_pct < 0 THEN 1
        ELSE 0
    END;

    -- Degraded queries severity: 1-3=low, 4-10=medium, 11-25=high, >25=critical
    v_query_severity := CASE
        WHEN v_degraded_count > 25 THEN 4
        WHEN v_degraded_count > 10 THEN 3
        WHEN v_degraded_count > 3 THEN 2
        WHEN v_degraded_count > 0 THEN 1
        ELSE 0
    END;

    -- Overall severity = highest individual severity
    v_severity := CASE GREATEST(v_lock_severity, v_duration_severity, v_conn_severity, v_tps_severity, v_query_severity)
        WHEN 4 THEN 'critical'
        WHEN 3 THEN 'high'
        WHEN 2 THEN 'medium'
        WHEN 1 THEN 'low'
        ELSE 'low'
    END;

    -- =========================================================================
    -- Impact Summary
    -- =========================================================================

    IF v_blocked_total > 0 THEN
        v_impact_summary := array_append(v_impact_summary,
            format('%s sessions blocked (max %s)',
                   v_blocked_total,
                   COALESCE(to_char(v_max_block_duration, 'MI"m" SS"s"'), 'unknown')));
    END IF;

    IF v_tps_change_pct < -10 THEN
        v_impact_summary := array_append(v_impact_summary,
            format('TPS dropped %s%%', abs(v_tps_change_pct)::integer));
    END IF;

    IF v_degraded_count > 0 THEN
        v_impact_summary := array_append(v_impact_summary,
            format('%s queries degraded >50%%', v_degraded_count));
    END IF;

    IF v_conn_increase_pct > 25 THEN
        v_impact_summary := array_append(v_impact_summary,
            format('Connections increased %s%%', v_conn_increase_pct::integer));
    END IF;

    IF array_length(v_impact_summary, 1) IS NULL THEN
        v_impact_summary := array_append(v_impact_summary, 'No significant impact detected');
    END IF;

    -- =========================================================================
    -- Recommendations
    -- =========================================================================

    IF v_max_block_duration > interval '1 minute' THEN
        v_recommendations := array_append(v_recommendations,
            'Review the blocking query that held locks for extended duration');
    END IF;

    IF v_blocked_total > 10 THEN
        v_recommendations := array_append(v_recommendations,
            'Consider setting lock_timeout to prevent long waits');
    END IF;

    IF v_conn_increase_pct > 50 THEN
        v_recommendations := array_append(v_recommendations,
            format('Investigate connection pool sizing (reached %s connections)', v_conn_during_max));
    END IF;

    IF v_degraded_count > 3 THEN
        v_recommendations := array_append(v_recommendations,
            format('%s queries showed >50%% degradation - review execution plans', v_degraded_count));
    END IF;

    IF v_tps_change_pct < -25 THEN
        v_recommendations := array_append(v_recommendations,
            'Throughput dropped significantly - analyze root cause of slowdown');
    END IF;

    IF array_length(v_recommendations, 1) IS NULL THEN
        v_recommendations := array_append(v_recommendations, 'No specific recommendations');
    END IF;

    -- =========================================================================
    -- Return Results
    -- =========================================================================

    RETURN QUERY SELECT
        p_start_time,
        p_end_time,
        round(EXTRACT(EPOCH FROM v_duration), 0),
        v_blocked_total,
        v_blocked_max_concurrent,
        v_max_block_duration,
        v_avg_block_duration,
        v_lock_types,
        v_degraded_count,
        v_degraded_queries,
        v_conn_before,
        v_conn_during_avg,
        v_conn_during_max,
        v_conn_increase_pct,
        v_affected_apps,
        v_top_waits,
        round(v_tps_before, 1),
        round(v_tps_during, 1),
        v_tps_change_pct,
        v_severity,
        v_impact_summary,
        v_recommendations;
END;
$$;
COMMENT ON FUNCTION flight_recorder.blast_radius IS
'Comprehensive blast radius analysis for incident impact assessment. Analyzes lock impact (blocked sessions, duration, types), query degradation (before vs during), connection spike, affected applications, wait events, and transaction throughput. Returns severity classification (low/medium/high/critical) with impact summary and recommendations. Use for incident postmortems: SELECT * FROM flight_recorder.blast_radius(''2024-01-15 10:23:00'', ''2024-01-15 10:35:00'');';


-- Blast Radius Report
-- Human-readable formatted report for incident postmortems
-- Returns ASCII-art styled report suitable for sharing and documentation
CREATE OR REPLACE FUNCTION flight_recorder.blast_radius_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_data RECORD;
    v_result TEXT := '';
    v_bar TEXT;
    v_max_bar_width INTEGER := 20;
    v_app RECORD;
    v_query RECORD;
    v_wait RECORD;
    v_lock RECORD;
    v_severity_bar TEXT;
BEGIN
    -- Get blast radius data
    SELECT * INTO v_data FROM flight_recorder.blast_radius(p_start_time, p_end_time);

    -- Header
    v_result := v_result || E'══════════════════════════════════════════════════════════════════════\n';
    v_result := v_result || E'                    BLAST RADIUS ANALYSIS REPORT\n';
    v_result := v_result || E'══════════════════════════════════════════════════════════════════════\n';

    -- Time window and severity
    v_result := v_result || format('Time Window: %s → %s (%s)',
        to_char(p_start_time, 'YYYY-MM-DD HH24:MI:SS'),
        to_char(p_end_time, 'HH24:MI:SS'),
        CASE
            WHEN v_data.duration_seconds >= 3600 THEN format('%s hours', round(v_data.duration_seconds / 3600, 1))
            WHEN v_data.duration_seconds >= 60 THEN format('%s minutes', round(v_data.duration_seconds / 60, 0))
            ELSE format('%s seconds', v_data.duration_seconds::integer)
        END
    ) || E'\n';

    -- Severity indicator with visual bar
    v_severity_bar := CASE v_data.severity
        WHEN 'critical' THEN '██████████'
        WHEN 'high' THEN '███████░░░'
        WHEN 'medium' THEN '█████░░░░░'
        ELSE '██░░░░░░░░'
    END;
    v_result := v_result || format('Severity: %s %s', v_severity_bar, upper(v_data.severity)) || E'\n\n';

    -- =========================================================================
    -- Lock Impact Section
    -- =========================================================================
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
    v_result := v_result || E'LOCK IMPACT\n';
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

    IF v_data.blocked_sessions_total > 0 THEN
        v_result := v_result || format('  Total blocked sessions:     %s', v_data.blocked_sessions_total) || E'\n';
        v_result := v_result || format('  Max concurrent blocked:     %s', v_data.blocked_sessions_max_concurrent) || E'\n';
        v_result := v_result || format('  Longest block duration:     %s',
            CASE
                WHEN v_data.max_block_duration >= interval '1 hour'
                THEN format('%sh %sm', EXTRACT(HOUR FROM v_data.max_block_duration)::integer,
                                       EXTRACT(MINUTE FROM v_data.max_block_duration)::integer)
                WHEN v_data.max_block_duration >= interval '1 minute'
                THEN format('%sm %ss', EXTRACT(MINUTE FROM v_data.max_block_duration)::integer,
                                       EXTRACT(SECOND FROM v_data.max_block_duration)::integer)
                ELSE format('%ss', round(EXTRACT(EPOCH FROM v_data.max_block_duration), 1))
            END
        ) || E'\n';
        v_result := v_result || format('  Average block duration:     %s',
            CASE
                WHEN v_data.avg_block_duration >= interval '1 minute'
                THEN format('%sm %ss', EXTRACT(MINUTE FROM v_data.avg_block_duration)::integer,
                                       EXTRACT(SECOND FROM v_data.avg_block_duration)::integer)
                ELSE format('%ss', round(EXTRACT(EPOCH FROM v_data.avg_block_duration), 1))
            END
        ) || E'\n\n';

        -- Lock types with bar chart
        IF jsonb_array_length(v_data.lock_types) > 0 THEN
            v_result := v_result || E'  Lock types:\n';
            FOR v_lock IN SELECT * FROM jsonb_to_recordset(v_data.lock_types) AS x(type text, count integer) LOOP
                v_bar := repeat('█', LEAST(v_lock.count, v_max_bar_width));
                v_result := v_result || format('    %-12s %s %s', v_lock.type, rpad(v_bar, v_max_bar_width), v_lock.count) || E'\n';
            END LOOP;
        END IF;
    ELSE
        v_result := v_result || E'  No lock contention detected.\n';
    END IF;
    v_result := v_result || E'\n';

    -- =========================================================================
    -- Affected Applications Section
    -- =========================================================================
    IF jsonb_array_length(v_data.affected_applications) > 0 THEN
        v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
        v_result := v_result || E'AFFECTED APPLICATIONS\n';
        v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

        FOR v_app IN SELECT * FROM jsonb_to_recordset(v_data.affected_applications)
                     AS x(app_name text, blocked_count integer, max_wait interval) LOOP
            v_bar := repeat('█', LEAST(v_app.blocked_count, v_max_bar_width));
            v_result := v_result || format('  %-16s %s %s blocked',
                left(v_app.app_name, 16), rpad(v_bar, v_max_bar_width), v_app.blocked_count) || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- =========================================================================
    -- Query Degradation Section
    -- =========================================================================
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
    v_result := v_result || format('QUERY DEGRADATION (%s queries slowed >50%%)', v_data.degraded_queries_count) || E'\n';
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

    IF v_data.degraded_queries_count > 0 THEN
        FOR v_query IN SELECT * FROM jsonb_to_recordset(v_data.degraded_queries)
                       AS x(queryid bigint, query_preview text, baseline_ms numeric, during_ms numeric, slowdown_pct numeric)
                       LIMIT 5 LOOP
            v_result := v_result || format('  %s', left(v_query.query_preview, 50)) || E'\n';
            v_result := v_result || format('    %sms → %sms  (+%s%%)',
                v_query.baseline_ms, v_query.during_ms, v_query.slowdown_pct::integer) || E'\n';
        END LOOP;
        IF v_data.degraded_queries_count > 5 THEN
            v_result := v_result || format('  ... and %s more', v_data.degraded_queries_count - 5) || E'\n';
        END IF;
    ELSE
        v_result := v_result || E'  No significant query degradation detected.\n';
    END IF;
    v_result := v_result || E'\n';

    -- =========================================================================
    -- Resource Impact Section
    -- =========================================================================
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
    v_result := v_result || E'RESOURCE IMPACT\n';
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

    v_result := v_result || format('  Connections:  %s → %s avg (%s max)  %s',
        v_data.connections_before,
        v_data.connections_during_avg,
        v_data.connections_during_max,
        CASE
            WHEN v_data.connection_increase_pct > 0 THEN format('+%s%%', v_data.connection_increase_pct::integer)
            WHEN v_data.connection_increase_pct < 0 THEN format('%s%%', v_data.connection_increase_pct::integer)
            ELSE 'unchanged'
        END
    ) || E'\n';

    v_result := v_result || format('  Throughput:   %s TPS → %s TPS    %s',
        round(v_data.tps_before, 0)::integer,
        round(v_data.tps_during, 0)::integer,
        CASE
            WHEN v_data.tps_change_pct > 0 THEN format('+%s%%', v_data.tps_change_pct::integer)
            WHEN v_data.tps_change_pct < 0 THEN format('%s%%', v_data.tps_change_pct::integer)
            ELSE 'unchanged'
        END
    ) || E'\n\n';

    -- =========================================================================
    -- Wait Events Section
    -- =========================================================================
    IF jsonb_array_length(v_data.top_wait_events) > 0 THEN
        v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
        v_result := v_result || E'TOP WAIT EVENTS\n';
        v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

        FOR v_wait IN SELECT * FROM jsonb_to_recordset(v_data.top_wait_events)
                      AS x(wait_type text, wait_event text, total_count integer, pct_increase numeric)
                      LIMIT 5 LOOP
            v_result := v_result || format('  %s:%s  count=%s',
                v_wait.wait_type, v_wait.wait_event, v_wait.total_count);
            IF v_wait.pct_increase IS NOT NULL THEN
                v_result := v_result || format('  (%s%s%%)',
                    CASE WHEN v_wait.pct_increase >= 0 THEN '+' ELSE '' END,
                    v_wait.pct_increase::integer);
            END IF;
            v_result := v_result || E'\n';
        END LOOP;
        v_result := v_result || E'\n';
    END IF;

    -- =========================================================================
    -- Recommendations Section
    -- =========================================================================
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';
    v_result := v_result || E'RECOMMENDATIONS\n';
    v_result := v_result || E'──────────────────────────────────────────────────────────────────────\n';

    FOR i IN 1..array_length(v_data.recommendations, 1) LOOP
        v_result := v_result || format('  • %s', v_data.recommendations[i]) || E'\n';
    END LOOP;
    v_result := v_result || E'\n';

    -- Footer
    v_result := v_result || E'══════════════════════════════════════════════════════════════════════\n';

    RETURN v_result;
END;
$$;
COMMENT ON FUNCTION flight_recorder.blast_radius_report IS
'Human-readable blast radius analysis report with ASCII-art formatting. Suitable for incident postmortems, Slack/email sharing, and documentation. Includes visual severity indicators, bar charts for lock types and affected apps, and actionable recommendations. Use: SELECT flight_recorder.blast_radius_report(''2024-01-15 10:23:00'', ''2024-01-15 10:35:00'');';
