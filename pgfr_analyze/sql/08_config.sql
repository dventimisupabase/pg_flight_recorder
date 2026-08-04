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
'Detect PostgreSQL configuration changes between two time points. Useful for correlating configuration changes with performance incidents.

Output columns:
  parameter_name: [dimension] [text] PostgreSQL parameter name as recorded in config_snapshots; present whenever the start-side and end-side recorded values differ.
  old_value: [dimension] [text] Recorded setting (with unit suffix when the snapshot stored one) from the latest config snapshot at or before p_start_time; NULL when the parameter was not recorded at the start (it appeared later).
  new_value: [dimension] [text] Recorded setting (with unit suffix when the snapshot stored one) from the earliest config snapshot at or after p_end_time; NULL when the parameter is absent at the end (it was removed).
  old_source: [dimension] [text] pg_settings source of the old value as recorded at the start-side snapshot.
  new_source: [dimension] [text] pg_settings source of the new value as recorded at the end-side snapshot.
  changed_at: [dimension] [timestamp] captured_at of the end-side snapshot where the new value was observed, not the moment of the change itself; the actual change happened somewhere between the two snapshots, so resolution is the snapshot cadence.';


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
'Retrieve PostgreSQL configuration at a specific point in time. Optionally filter by category prefix (e.g., ''autovacuum'', ''work_mem'').

Output columns:
  parameter_name: [dimension] [text] PostgreSQL parameter name; one row per parameter that had been recorded in config_snapshots at or before p_timestamp.
  value: [dimension] [text] Recorded setting (with unit suffix when the snapshot stored one) from the latest config snapshot at or before p_timestamp: the last known value, carried forward without interpolation.
  source: [dimension] [text] pg_settings source of the setting as recorded at that same snapshot.';


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
'Perform a health check on current PostgreSQL configuration. Returns potential issues and recommendations for memory, connections, and safety settings.

Output columns:
  category: [dimension] [text] Check category label: memory, connections, or safety.
  parameter_name: [dimension] [text] PostgreSQL parameter the check flagged.
  current_value: [dimension] [text] Live pg_settings value at call time (not from recorded snapshots), pretty-printed for byte-valued parameters.
  issue: [derived] [text] Description of the configuration concern, produced by comparing the live pg_settings value against a fixed built-in threshold.
  recommendation: [derived] [text] Suggested remediation text for the flagged issue.';


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
'Retrieve database/role configuration overrides at a specific point in time. Filter by database, role, or parameter prefix.

Output columns:
  database_name: [dimension] [text] Database the override applies to, as recorded in db_role_config_snapshots; NULL for role-only overrides.
  role_name: [dimension] [text] Role the override applies to, as recorded in db_role_config_snapshots; NULL for database-only overrides.
  parameter_name: [dimension] [text] Name of the overridden parameter.
  parameter_value: [dimension] [text] Recorded override value from the latest snapshot at or before p_timestamp: the last known value, carried forward without interpolation.
  scope: [dimension] [text] Override scope label computed from which identifiers are set: database, role, database+role, or unknown.';


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
'Detect database/role configuration changes between two time points. Returns added, removed, and modified settings.

Output columns:
  database_name: [dimension] [text] Database the override applies to; NULL for role-only overrides.
  role_name: [dimension] [text] Role the override applies to; NULL for database-only overrides.
  parameter_name: [dimension] [text] Name of the overridden parameter whose recorded value differs between the two time points.
  old_value: [dimension] [text] Recorded override value from the latest snapshot at or before p_start_time; NULL when the override was added after the start.
  new_value: [dimension] [text] Recorded override value from the latest snapshot at or before p_end_time; NULL when the override was removed by the end.
  change_type: [derived] [text] Classification of the change (added, removed, or modified) computed by comparing the start-side and end-side recorded values; resolution is the snapshot cadence.';


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
'Overview of database/role configuration overrides grouped by scope. Shows which databases and roles have custom settings.

Output columns:
  scope: [dimension] [text] Override scope label computed from which identifiers are set: database, role, database+role, or unknown.
  database_name: [dimension] [text] Database the overrides apply to; NULL for role-only overrides.
  role_name: [dimension] [text] Role the overrides apply to; NULL for database-only overrides.
  parameter_count: [gauge] [count] Number of override parameters recorded for this scope grouping in the single most recent snapshot; exact as of that snapshot instant, undefined between ticks.
  parameters: [dimension] [text] Alphabetically sorted array of the overridden parameter names in this scope grouping at the most recent snapshot.';


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
