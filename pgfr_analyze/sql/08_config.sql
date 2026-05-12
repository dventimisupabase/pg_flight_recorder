-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

CREATE OR REPLACE FUNCTION pgfr_analyze.config_changes(
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
        FROM pgfr_record.config_snapshots cs
        JOIN pgfr_record.snapshots s ON s.id = cs.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY cs.name, s.captured_at DESC
    ),
    end_configs AS (
        SELECT DISTINCT ON (cs.name) cs.name, cs.setting, cs.unit, cs.source, s.captured_at
        FROM pgfr_record.config_snapshots cs
        JOIN pgfr_record.snapshots s ON s.id = cs.snapshot_id
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
COMMENT ON FUNCTION pgfr_analyze.config_changes(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Detect PostgreSQL configuration changes between two time points. Useful for correlating configuration changes with performance incidents.';


-- Retrieves configuration at a specific point in time
-- Optionally filters by parameter name prefix (category)
CREATE OR REPLACE FUNCTION pgfr_analyze.config_at(
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
    FROM pgfr_record.config_snapshots cs
    JOIN pgfr_record.snapshots s ON s.id = cs.snapshot_id
    WHERE s.captured_at <= p_timestamp
        AND (p_category IS NULL OR cs.name LIKE p_category || '%')
    ORDER BY cs.name, s.captured_at DESC
$$;
COMMENT ON FUNCTION pgfr_analyze.config_at(TIMESTAMPTZ, TEXT) IS
'Retrieve PostgreSQL configuration at a specific point in time. Optionally filter by category prefix (e.g., ''autovacuum'', ''work_mem'').';


-- Performs a health check on current PostgreSQL configuration
-- Returns potential issues and recommendations
CREATE OR REPLACE FUNCTION pgfr_analyze.config_health_check()
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
        current_value := pgfr_record._pretty_bytes(v_shared_buffers);
        issue := 'Very low shared_buffers';
        recommendation := 'Increase to at least 25% of available RAM';
        RETURN NEXT;
    END IF;

    -- Check work_mem (should be at least 16MB for analytical workloads)
    IF v_work_mem < 16777216 THEN  -- < 16 MB
        category := 'memory';
        parameter_name := 'work_mem';
        current_value := pgfr_record._pretty_bytes(v_work_mem);
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
COMMENT ON FUNCTION pgfr_analyze.config_health_check() IS
'Perform a health check on current PostgreSQL configuration. Returns potential issues and recommendations for memory, connections, and safety settings.';


-- =============================================================================
-- DATABASE/ROLE CONFIGURATION ANALYSIS FUNCTIONS
-- =============================================================================

-- Retrieves database/role configuration overrides at a specific point in time
-- Optionally filters by database, role, or parameter name prefix
CREATE OR REPLACE FUNCTION pgfr_analyze.db_role_config_at(
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
    FROM pgfr_record.db_role_config_snapshots drc
    JOIN pgfr_record.snapshots s ON s.id = drc.snapshot_id
    WHERE s.captured_at <= p_timestamp
        AND (p_database IS NULL OR drc.database_name = p_database)
        AND (p_role IS NULL OR drc.role_name = p_role)
        AND (p_prefix IS NULL OR drc.parameter_name LIKE p_prefix || '%')
    ORDER BY drc.database_name, drc.role_name, drc.parameter_name, s.captured_at DESC
$$;
COMMENT ON FUNCTION pgfr_analyze.db_role_config_at(TIMESTAMPTZ, TEXT, TEXT, TEXT) IS
'Retrieve database/role configuration overrides at a specific point in time. Filter by database, role, or parameter prefix.';


-- Detects database/role configuration changes between two time points
-- Returns parameters that were added, removed, or modified
CREATE OR REPLACE FUNCTION pgfr_analyze.db_role_config_changes(
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
        FROM pgfr_record.db_role_config_snapshots drc
        JOIN pgfr_record.snapshots s ON s.id = drc.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY drc.database_name, drc.role_name, drc.parameter_name, s.captured_at DESC
    ),
    end_configs AS (
        SELECT DISTINCT ON (drc.database_name, drc.role_name, drc.parameter_name)
            drc.database_name, drc.role_name, drc.parameter_name, drc.parameter_value
        FROM pgfr_record.db_role_config_snapshots drc
        JOIN pgfr_record.snapshots s ON s.id = drc.snapshot_id
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
COMMENT ON FUNCTION pgfr_analyze.db_role_config_changes(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Detect database/role configuration changes between two time points. Returns added, removed, and modified settings.';


-- Provides a summary overview of all database/role configuration overrides
-- Groups by scope (database-only, role-only, or database+role combination)
CREATE OR REPLACE FUNCTION pgfr_analyze.db_role_config_summary()
RETURNS TABLE(
    scope           TEXT,
    database_name   TEXT,
    role_name       TEXT,
    parameter_count BIGINT,
    parameters      TEXT[]
)
LANGUAGE sql STABLE AS $$
    WITH latest_snapshot AS (
        SELECT id FROM pgfr_record.snapshots ORDER BY captured_at DESC LIMIT 1
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
        FROM pgfr_record.db_role_config_snapshots drc
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
COMMENT ON FUNCTION pgfr_analyze.db_role_config_summary() IS
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
