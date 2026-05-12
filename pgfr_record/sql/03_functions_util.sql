-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

CREATE OR REPLACE FUNCTION pgfr_record._pretty_bytes(bytes BIGINT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN bytes IS NULL THEN NULL
        WHEN bytes >= 1073741824 THEN round(bytes / 1073741824.0, 2)::text || ' GB'
        WHEN bytes >= 1048576    THEN round(bytes / 1048576.0, 2)::text || ' MB'
        WHEN bytes >= 1024       THEN round(bytes / 1024.0, 2)::text || ' KB'
        ELSE bytes::text || ' B'
    END
$$;


-- Linear interpolation helper for time-travel debugging
-- Calculates estimated value at target time between two known data points
-- Input: Values and timestamps at two points, target timestamp
-- Output: Linearly interpolated value at target time
CREATE OR REPLACE FUNCTION pgfr_record._interpolate_metric(
    p_value_before NUMERIC,
    p_time_before TIMESTAMPTZ,
    p_value_after NUMERIC,
    p_time_after TIMESTAMPTZ,
    p_target_time TIMESTAMPTZ
)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_time_span NUMERIC;
    v_offset NUMERIC;
    v_ratio NUMERIC;
BEGIN
    -- Handle NULL inputs
    IF p_value_before IS NULL OR p_value_after IS NULL OR
       p_time_before IS NULL OR p_time_after IS NULL OR
       p_target_time IS NULL THEN
        RETURN NULL;
    END IF;

    -- Handle same timestamp (no interpolation needed)
    IF p_time_before = p_time_after THEN
        RETURN p_value_before;
    END IF;

    -- Calculate time span in seconds
    v_time_span := EXTRACT(EPOCH FROM (p_time_after - p_time_before));

    -- Handle zero time span (shouldn't happen but be safe)
    IF v_time_span = 0 THEN
        RETURN p_value_before;
    END IF;

    -- Calculate offset from before timestamp
    v_offset := EXTRACT(EPOCH FROM (p_target_time - p_time_before));

    -- Calculate interpolation ratio
    v_ratio := v_offset / v_time_span;

    -- Clamp ratio to [0, 1] to avoid extrapolation
    v_ratio := GREATEST(0, LEAST(1, v_ratio));

    -- Linear interpolation: before + ratio * (after - before)
    RETURN round(p_value_before + v_ratio * (p_value_after - p_value_before), 4);
END;
$$;
COMMENT ON FUNCTION pgfr_record._interpolate_metric IS
'Linear interpolation helper for time-travel debugging. Calculates estimated metric value at a target timestamp between two known data points. Returns rounded value (4 decimal places). Handles edge cases: NULL inputs, same timestamps, and clamps ratio to [0,1] to prevent extrapolation.';


-- Populates relation_names table from pg_class for offline analysis
-- Run this before exporting data for offline analysis tools
-- This is an EXPORT-TIME operation, not a collection-time operation
CREATE OR REPLACE FUNCTION pgfr_record._populate_relation_names()
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Truncate and repopulate to ensure consistency
    TRUNCATE pgfr_record.relation_names;

    INSERT INTO pgfr_record.relation_names (oid, nspname, relname)
    SELECT c.oid, n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND c.relkind IN ('r', 'i', 'S', 'v', 'm', 'p');  -- tables, indexes, sequences, views, matviews, partitioned

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;
COMMENT ON FUNCTION pgfr_record._populate_relation_names IS
'Populates relation_names lookup table for offline analysis. Run before pg_dump when exporting data. Returns count of relations captured.';


-- Resolves OID to schema-qualified relation name using relation_names lookup table
-- Falls back to OID string if not found (for offline analysis compatibility)
CREATE OR REPLACE FUNCTION pgfr_record._safe_relname(p_oid OID)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT nspname || '.' || relname FROM pgfr_record.relation_names WHERE oid = p_oid),
        'OID:' || p_oid::text
    )
$$;
COMMENT ON FUNCTION pgfr_record._safe_relname IS
'Resolves OID to relation name using relation_names table. Returns OID:nnn if not found. For offline analysis where pg_class is unavailable.';


-- Retrieves a PostgreSQL setting from config_snapshots history
-- For offline analysis where pg_settings is unavailable
-- Returns most recent captured value, or default if not found
CREATE OR REPLACE FUNCTION pgfr_record._get_setting_from_snapshots(
    p_name TEXT,
    p_default TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (
            SELECT cs.setting
            FROM pgfr_record.config_snapshots cs
            JOIN pgfr_record.snapshots s ON s.id = cs.snapshot_id
            WHERE cs.name = p_name
            ORDER BY s.captured_at DESC
            LIMIT 1
        ),
        p_default
    )
$$;
COMMENT ON FUNCTION pgfr_record._get_setting_from_snapshots IS
'Retrieves PostgreSQL setting from config_snapshots for offline analysis. Returns most recent captured value or default if not found.';


-- Returns the PostgreSQL major version number
-- Extracts major version by dividing server_version_num by 10000
CREATE OR REPLACE FUNCTION pgfr_record._pg_version()
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT current_setting('server_version_num')::integer / 10000
$$;

-- Configuration key-value store for pgfr_record extension
-- Manages tuning parameters, thresholds, timeouts, and feature flags
-- Tracks when each setting was last modified via updated_at timestamp
CREATE TABLE IF NOT EXISTS pgfr_record.config (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Single source of truth for profile settings
-- Profiles define behavioral presets for different environments
CREATE OR REPLACE FUNCTION pgfr_record._profile_settings()
RETURNS TABLE(
    profile     TEXT,
    key         TEXT,
    value       TEXT,
    description TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT * FROM (VALUES
        ('default', 'sample_interval_seconds', '60', 'Sample every minute'),
        ('default', 'load_shedding_enabled', 'true', 'Skip during high load (>70% connections)'),
        ('default', 'circuit_breaker_enabled', 'true', 'Auto-skip if collections run slow'),
        ('default', 'enable_locks', 'true', 'Collect lock contention data'),
        ('default', 'enable_progress', 'true', 'Collect operation progress'),
        ('default', 'snapshot_based_collection', 'true', 'Use snapshot-based collection (67% fewer locks)'),
        ('default', 'retention_snapshots_days', '30', 'Keep 30 days of snapshot data'),
        ('default', 'retention_archive_days', '7', 'Keep 7 days of aggregate data'),
        ('default', 'table_stats_enabled', 'true', 'Collect table statistics'),
        ('default', 'index_stats_enabled', 'true', 'Collect index statistics'),
        ('default', 'config_snapshots_enabled', 'true', 'Collect config snapshots'),
        ('default', 'db_role_config_snapshots_enabled', 'true', 'Collect database/role config overrides'),
        ('default', 'retention_statements_days', '30', 'Keep statement snapshots 30 days'),
        ('default', 'retention_collection_stats_days', '30', 'Keep collection stats 30 days'),
        ('default', 'section_timeout_ms', '250', 'Per-section timeout 250ms'),
        ('default', 'statement_timeout_ms', '1000', 'Statement timeout 1 second'),
        ('default', 'work_mem_kb', '2048', 'work_mem 2MB for collection queries'),
        ('default', 'skip_locks_threshold', '50', 'Skip lock collection if > 50 blocked'),
        ('default', 'skip_activity_conn_threshold', '100', 'Skip activity if > 100 active'),
        ('default', 'statements_interval_minutes', '1', 'Collect statements every minute'),
        ('default', 'statements_min_calls', '1', 'Include queries with >= 1 call'),
        ('default', 'statements_top_n', '50', 'Collect top 50 queries'),
        ('default', 'table_stats_top_n', '50', 'Track top 50 tables'),
        ('production_safe', 'sample_interval_seconds', '300', 'Sample every 5 minutes (40% less overhead)'),
        ('production_safe', 'load_shedding_enabled', 'true', 'Skip during high load'),
        ('production_safe', 'load_shedding_active_pct', '60', 'More aggressive load shedding (60% vs 70%)'),
        ('production_safe', 'circuit_breaker_enabled', 'true', 'Auto-skip if slow'),
        ('production_safe', 'circuit_breaker_threshold_ms', '800', 'Stricter circuit breaker (800ms vs 1000ms)'),
        ('production_safe', 'enable_locks', 'false', 'Disable lock collection (reduce overhead)'),
        ('production_safe', 'enable_progress', 'false', 'Disable progress tracking'),
        ('production_safe', 'snapshot_based_collection', 'true', 'Snapshot-based collection'),
        ('production_safe', 'lock_timeout_ms', '50', 'Faster lock timeout (50ms vs 100ms)'),
        ('production_safe', 'retention_snapshots_days', '30', 'Keep 30 days'),
        ('production_safe', 'retention_archive_days', '7', 'Keep 7 days'),
        ('production_safe', 'table_stats_enabled', 'true', 'Collect table statistics'),
        ('production_safe', 'index_stats_enabled', 'true', 'Collect index statistics'),
        ('production_safe', 'config_snapshots_enabled', 'true', 'Collect config snapshots'),
        ('production_safe', 'db_role_config_snapshots_enabled', 'true', 'Collect database/role config overrides'),
        ('production_safe', 'retention_statements_days', '30', 'Keep statement snapshots 30 days'),
        ('production_safe', 'retention_collection_stats_days', '30', 'Keep collection stats 30 days'),
        ('production_safe', 'section_timeout_ms', '200', 'Faster per-section timeout'),
        ('production_safe', 'statement_timeout_ms', '800', 'Faster statement timeout'),
        ('production_safe', 'work_mem_kb', '1024', 'Lower work_mem to reduce overhead'),
        ('production_safe', 'skip_locks_threshold', '30', 'More aggressive lock skip'),
        ('production_safe', 'skip_activity_conn_threshold', '50', 'More aggressive activity skip'),
        ('production_safe', 'statements_interval_minutes', '15', 'Less frequent statement collection'),
        ('production_safe', 'statements_min_calls', '5', 'Only queries with >= 5 calls'),
        ('production_safe', 'statements_top_n', '30', 'Collect top 30 queries'),
        ('production_safe', 'table_stats_top_n', '30', 'Track fewer tables'),
        ('development', 'sample_interval_seconds', '60', 'Sample every minute'),
        ('development', 'load_shedding_enabled', 'true', 'Skip during high load'),
        ('development', 'circuit_breaker_enabled', 'true', 'Auto-skip if slow'),
        ('development', 'enable_locks', 'true', 'Collect lock data'),
        ('development', 'enable_progress', 'true', 'Collect progress data'),
        ('development', 'snapshot_based_collection', 'true', 'Snapshot-based collection'),
        ('development', 'retention_snapshots_days', '7', 'Keep 7 days (less than production)'),
        ('development', 'retention_archive_days', '3', 'Keep 3 days'),
        ('development', 'table_stats_enabled', 'true', 'Collect table statistics'),
        ('development', 'index_stats_enabled', 'true', 'Collect index statistics'),
        ('development', 'config_snapshots_enabled', 'true', 'Collect config snapshots'),
        ('development', 'db_role_config_snapshots_enabled', 'true', 'Collect database/role config overrides'),
        ('development', 'retention_statements_days', '7', 'Keep statement snapshots 7 days'),
        ('development', 'retention_collection_stats_days', '7', 'Keep collection stats 7 days'),
        ('development', 'section_timeout_ms', '250', 'Standard per-section timeout'),
        ('development', 'statement_timeout_ms', '1000', 'Standard statement timeout'),
        ('development', 'work_mem_kb', '2048', 'Standard work_mem'),
        ('development', 'skip_locks_threshold', '50', 'Standard lock skip threshold'),
        ('development', 'skip_activity_conn_threshold', '100', 'Standard activity skip threshold'),
        ('development', 'statements_interval_minutes', '1', 'Collect statements every minute'),
        ('development', 'statements_min_calls', '1', 'Include all queries'),
        ('development', 'statements_top_n', '50', 'Collect top 50 queries'),
        ('development', 'table_stats_top_n', '50', 'Track top 50 tables'),
        ('troubleshooting', 'sample_interval_seconds', '60', 'Sample every minute (detailed data)'),
        ('troubleshooting', 'load_shedding_enabled', 'false', 'Collect even under load'),
        ('troubleshooting', 'circuit_breaker_enabled', 'true', 'Keep circuit breaker enabled'),
        ('troubleshooting', 'circuit_breaker_threshold_ms', '2000', 'More lenient threshold - 2 seconds'),
        ('troubleshooting', 'enable_locks', 'true', 'Collect all lock data'),
        ('troubleshooting', 'enable_progress', 'true', 'Collect all progress data'),
        ('troubleshooting', 'snapshot_based_collection', 'true', 'Snapshot-based collection'),
        ('troubleshooting', 'statements_top_n', '100', 'Collect top 100 queries'),
        ('troubleshooting', 'retention_snapshots_days', '7', 'Keep 7 days'),
        ('troubleshooting', 'retention_archive_days', '3', 'Keep 3 days'),
        ('troubleshooting', 'table_stats_enabled', 'true', 'Collect table statistics'),
        ('troubleshooting', 'index_stats_enabled', 'true', 'Collect index statistics'),
        ('troubleshooting', 'config_snapshots_enabled', 'true', 'Collect config snapshots'),
        ('troubleshooting', 'db_role_config_snapshots_enabled', 'true', 'Collect database/role config overrides'),
        ('troubleshooting', 'storm_threshold_multiplier', '2.0', 'More sensitive (2x vs 3x baseline)'),
        ('troubleshooting', 'regression_threshold_pct', '25.0', 'More sensitive (25% vs 50%)'),
        ('troubleshooting', 'storm_baseline_days', '3', 'Shorter baseline for faster detection'),
        ('troubleshooting', 'storm_lookback_interval', '30 minutes', 'Shorter lookback window'),
        ('troubleshooting', 'regression_baseline_days', '3', 'Shorter baseline for faster detection'),
        ('troubleshooting', 'regression_lookback_interval', '30 minutes', 'Shorter lookback window'),
        ('troubleshooting', 'retention_statements_days', '7', 'Keep statement snapshots 7 days'),
        ('troubleshooting', 'retention_collection_stats_days', '7', 'Keep collection stats 7 days'),
        ('troubleshooting', 'section_timeout_ms', '500', 'Longer per-section timeout for detailed collection'),
        ('troubleshooting', 'statement_timeout_ms', '2000', 'Longer statement timeout'),
        ('troubleshooting', 'work_mem_kb', '4096', 'More work_mem for complex queries'),
        ('troubleshooting', 'skip_locks_threshold', '100', 'Higher threshold - collect more'),
        ('troubleshooting', 'skip_activity_conn_threshold', '200', 'Higher threshold - collect more'),
        ('troubleshooting', 'statements_interval_minutes', '2', 'More frequent statement collection'),
        ('troubleshooting', 'statements_min_calls', '1', 'Include all queries'),
        ('troubleshooting', 'table_stats_top_n', '100', 'Track more tables'),
        ('minimal_overhead', 'sample_interval_seconds', '300', 'Sample every 5 minutes'),
        ('minimal_overhead', 'load_shedding_enabled', 'true', 'Skip during high load'),
        ('minimal_overhead', 'load_shedding_active_pct', '50', 'Very aggressive (50%)'),
        ('minimal_overhead', 'circuit_breaker_enabled', 'true', 'Auto-skip if slow'),
        ('minimal_overhead', 'circuit_breaker_threshold_ms', '500', 'Very strict (500ms)'),
        ('minimal_overhead', 'enable_locks', 'false', 'Disable locks'),
        ('minimal_overhead', 'enable_progress', 'false', 'Disable progress'),
        ('minimal_overhead', 'snapshot_based_collection', 'true', 'Snapshot-based collection'),
        ('minimal_overhead', 'statements_enabled', 'false', 'Disable pg_stat_statements collection'),
        ('minimal_overhead', 'retention_snapshots_days', '7', 'Keep 7 days'),
        ('minimal_overhead', 'retention_archive_days', '3', 'Keep 3 days'),
        ('minimal_overhead', 'table_stats_enabled', 'false', 'Disable table statistics (reduce overhead)'),
        ('minimal_overhead', 'index_stats_enabled', 'false', 'Disable index statistics (reduce overhead)'),
        ('minimal_overhead', 'config_snapshots_enabled', 'true', 'Collect config snapshots (low overhead)'),
        ('minimal_overhead', 'db_role_config_snapshots_enabled', 'true', 'Collect database/role config overrides'),
        ('minimal_overhead', 'retention_statements_days', '7', 'Keep statement snapshots 7 days'),
        ('minimal_overhead', 'retention_collection_stats_days', '7', 'Keep collection stats 7 days'),
        ('minimal_overhead', 'section_timeout_ms', '100', 'Very fast per-section timeout'),
        ('minimal_overhead', 'statement_timeout_ms', '500', 'Very fast statement timeout'),
        ('minimal_overhead', 'work_mem_kb', '1024', 'Minimal work_mem'),
        ('minimal_overhead', 'skip_locks_threshold', '20', 'Very aggressive lock skip'),
        ('minimal_overhead', 'skip_activity_conn_threshold', '30', 'Very aggressive activity skip'),
        ('minimal_overhead', 'statements_interval_minutes', '15', 'Infrequent statement collection'),
        ('minimal_overhead', 'statements_min_calls', '10', 'Only hot queries'),
        ('minimal_overhead', 'statements_top_n', '20', 'Collect top 20 queries'),
        ('minimal_overhead', 'table_stats_top_n', '20', 'Track fewer tables')
    ) AS t(profile, key, value, description);
$$;

-- Non-profile settings (system defaults that profiles don't manage)
INSERT INTO pgfr_record.config (key, value) VALUES
    ('schema_version', '2.28'),
    ('mode', 'normal'),
    ('statements_enabled', 'auto'),
    ('statements_top_n', '50'),
    ('circuit_breaker_threshold_ms', '1000'),
    ('circuit_breaker_window_minutes', '15'),
    ('lock_timeout_ms', '100'),
    ('schema_size_warning_mb', '5000'),
    ('schema_size_critical_mb', '10000'),
    ('schema_size_check_enabled', 'true'),
    ('alert_enabled', 'false'),
    ('alert_circuit_breaker_count', '5'),
    ('alert_schema_size_mb', '8000'),
    ('lock_timeout_strategy', 'fail_fast'),

    ('check_pss_conflicts', 'true'),
    ('schema_size_use_percentage', 'true'),
    ('schema_size_percentage', '5.0'),
    ('schema_size_min_mb', '1000'),
    ('schema_size_max_mb', '10000'),
    ('load_shedding_active_pct', '70'),
    ('archive_samples_enabled', 'true'),
    ('archive_sample_frequency_minutes', '15'),
    ('archive_retention_days', '7'),
    ('archive_activity_samples', 'true'),
    ('archive_lock_samples', 'true'),
    ('archive_wait_samples', 'true'),
    ('capacity_planning_enabled', 'true'),
    ('capacity_thresholds_warning_pct', '60'),
    ('capacity_thresholds_critical_pct', '80'),
    ('collect_database_size', 'true'),
    ('collect_connection_metrics', 'true'),
    ('table_stats_mode', 'top_n'),
    ('table_stats_activity_threshold', '0'),
    ('index_stats_enabled', 'true'),
    ('config_snapshots_enabled', 'true'),
    ('db_role_config_snapshots_enabled', 'true'),
    ('ring_buffer_slots', '120'),
    ('vacuum_control_enabled', 'true'),
    ('vacuum_control_dead_tuple_budget_pct', '5'),
    ('vacuum_control_min_scale_factor', '0.001'),
    ('vacuum_control_max_scale_factor', '0.2'),
    ('vacuum_control_hysteresis_pct', '25'),
    ('vacuum_control_rate_limit_minutes', '60'),
    ('vacuum_control_catchup_budget_hours', '4'),
    ('storm_threshold_multiplier', '3.0'),
    ('storm_lookback_interval', '1 hour'),
    ('storm_baseline_days', '7'),
    ('storm_severity_low_max', '5.0'),
    ('storm_severity_medium_max', '10.0'),
    ('storm_severity_high_max', '50.0'),
    ('regression_threshold_pct', '50.0'),
    ('regression_lookback_interval', '1 hour'),
    ('regression_baseline_days', '7'),
    ('regression_severity_low_max', '200.0'),
    ('regression_severity_medium_max', '500.0'),
    ('regression_severity_high_max', '1000.0'),
    ('statements_ranking_metric', 'buffers'),
    ('regression_detection_metric', 'buffers'),
    -- Wraparound anomaly thresholds as fractions of autovacuum_*_freeze_max_age.
    -- Defaults match the postgres-howto guidance (0.5 warn, 0.8 crit) but can
    -- be tuned downward for busy clusters where 50% is too late to warn.
    ('xid_warning_ratio',   '0.5'),
    ('xid_critical_ratio',  '0.8'),
    ('mxid_warning_ratio',  '0.5'),
    ('mxid_critical_ratio', '0.8')
ON CONFLICT (key) DO NOTHING;

-- Profile-managed defaults (from 'default' profile)
INSERT INTO pgfr_record.config (key, value)
SELECT ps.key, ps.value
FROM pgfr_record._profile_settings() ps
WHERE ps.profile = 'default'
ON CONFLICT (key) DO NOTHING;

CREATE UNLOGGED TABLE IF NOT EXISTS pgfr_record.collection_stats (
    id              SERIAL PRIMARY KEY,
    collection_type TEXT NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL,
    completed_at    TIMESTAMPTZ,
    duration_ms     INTEGER,
    success         BOOLEAN DEFAULT true,
    error_message   TEXT,
    skipped         BOOLEAN DEFAULT false,
    skipped_reason  TEXT,
    sections_total  INTEGER,
    sections_succeeded INTEGER
);
CREATE INDEX IF NOT EXISTS collection_stats_type_started_idx
    ON pgfr_record.collection_stats(collection_type, started_at DESC);

-- Checks if circuit breaker conditions are met (excessive errors or collection failures)
-- Returns TRUE if circuit breaker is tripped and collection should be skipped
CREATE OR REPLACE FUNCTION pgfr_record._check_circuit_breaker(p_collection_type TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_threshold_ms INTEGER;
    v_avg_duration_ms NUMERIC;
    v_window_minutes INTEGER;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('circuit_breaker_enabled', 'true')::boolean,
        true
    );
    IF NOT v_enabled THEN
        RETURN false;
    END IF;
    v_threshold_ms := COALESCE(
        pgfr_record._get_config('circuit_breaker_threshold_ms', '1000')::integer,
        1000
    );
    v_window_minutes := COALESCE(
        pgfr_record._get_config('circuit_breaker_window_minutes', '15')::integer,
        15
    );
    SELECT avg(duration_ms) INTO v_avg_duration_ms
    FROM (
        SELECT duration_ms
        FROM pgfr_record.collection_stats
        WHERE collection_type = p_collection_type
          AND success = true
          AND skipped = false
          AND started_at > now() - (v_window_minutes || ' minutes')::interval
        ORDER BY started_at DESC
        LIMIT 3
    ) recent;
    IF v_avg_duration_ms IS NOT NULL
       AND v_avg_duration_ms > v_threshold_ms THEN
        RETURN true;
    END IF;
    RETURN false;
END;
$$;

-- Records the start of a collection operation and creates a tracking entry in collection_stats
-- Returns the ID of the new record to track subsequent collection progress
CREATE OR REPLACE FUNCTION pgfr_record._record_collection_start(
    p_collection_type TEXT,
    p_sections_total INTEGER DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE sql AS $$
    INSERT INTO pgfr_record.collection_stats (collection_type, started_at, sections_total)
    VALUES (p_collection_type, now(), p_sections_total)
    RETURNING id
$$;

-- Records collection completion with timing and success/failure status
-- Updates collection_stats with end time, duration, and error details if applicable
CREATE OR REPLACE FUNCTION pgfr_record._record_collection_end(
    p_stat_id INTEGER,
    p_success BOOLEAN,
    p_error_message TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE sql AS $$
    UPDATE pgfr_record.collection_stats
    SET completed_at = now(),
        duration_ms = EXTRACT(EPOCH FROM (now() - started_at)) * 1000,
        success = p_success,
        error_message = p_error_message
    WHERE id = p_stat_id
$$;

-- Records a skipped collection event with the reason for skipping
CREATE OR REPLACE FUNCTION pgfr_record._record_collection_skip(
    p_collection_type TEXT,
    p_reason TEXT
)
RETURNS VOID
LANGUAGE sql AS $$
    INSERT INTO pgfr_record.collection_stats (
        collection_type, started_at, completed_at, skipped, skipped_reason
    )
    VALUES (p_collection_type, now(), now(), true, p_reason)
$$;

-- Increments the sections_succeeded counter to record successful section completion
CREATE OR REPLACE FUNCTION pgfr_record._record_section_success(p_stat_id INTEGER)
RETURNS VOID
LANGUAGE sql AS $$
    UPDATE pgfr_record.collection_stats
    SET sections_succeeded = COALESCE(sections_succeeded, 0) + 1
    WHERE id = p_stat_id
$$;

-- Retrieves configuration values by key from the config table with optional fallback
-- Returns the provided default value if the key does not exist
-- Deprecated config key aliases → canonical keys.
-- _get_config() resolves these transparently (reads canonical key if old key absent).
-- install() / migrate_config_keys() renames them in the config table on first run.
CREATE OR REPLACE FUNCTION pgfr_record._resolve_config_key(p_key text)
returns text language sql immutable as $$
    select case p_key
        when 'retention_samples_days'   then 'retention_archive_days'
        when 'aggregate_retention_days' then 'retention_archive_days'
        else p_key
    end
$$;
comment on function pgfr_record._resolve_config_key(text) is
'Maps deprecated config key aliases to canonical keys. Add new aliases here as keys are renamed.';

-- Reverse alias map: canonical key → deprecated keys that may hold its value.
-- Used by _get_config() to find a value stored under an old key name.
create or replace function pgfr_record._alias_keys_for(p_canonical text)
returns text[] language sql immutable as $$
    select case p_canonical
        when 'retention_archive_days' then array['retention_samples_days', 'aggregate_retention_days']
        else array[]::text[]
    end
$$;
comment on function pgfr_record._alias_keys_for(text) is
'Returns deprecated key names that map to a given canonical key. Complement of _resolve_config_key().';

create or replace function pgfr_record._get_config(p_key text, p_default text default null)
returns text language plpgsql stable as $$
declare
    v_val   text;
    v_alias text;
begin
    -- 1. exact key match
    select value into v_val from pgfr_record.config where key = p_key;
    if found then return v_val; end if;

    -- 2. canonical → alias fallback (e.g. 'retention_archive_days' stored as old key)
    foreach v_alias in array pgfr_record._alias_keys_for(p_key) loop
        select value into v_val from pgfr_record.config where key = v_alias;
        if found then return v_val; end if;
    end loop;

    -- 3. old key → canonical fallback (e.g. caller uses 'retention_samples_days')
    if pgfr_record._resolve_config_key(p_key) <> p_key then
        select value into v_val from pgfr_record.config
        where key = pgfr_record._resolve_config_key(p_key);
        if found then return v_val; end if;
    end if;

    return p_default;
end $$;
comment on function pgfr_record._get_config(text, text) is
'Reads config value by key. Deprecated key aliases are transparently resolved to canonical keys via _resolve_config_key().';

-- Migrates old config key names to canonical names in the live config table.
-- Safe to run multiple times (idempotent). Called automatically by install().
create or replace function pgfr_record.migrate_config_keys()
returns table(old_key text, new_key text, action text)
language plpgsql as $$
declare
    v_alias text[];
    v_aliases text[][] := array[
        ['retention_samples_days',   'retention_archive_days'],
        ['aggregate_retention_days', 'retention_archive_days']
    ];
begin
    foreach v_alias slice 1 in array v_aliases loop
        if exists (select 1 from pgfr_record.config where key = v_alias[1]) then
            if exists (select 1 from pgfr_record.config where key = v_alias[2]) then
                -- canonical key already present: remove the old alias row
                delete from pgfr_record.config where key = v_alias[1];
                return query select v_alias[1], v_alias[2], 'deleted (canonical exists)'::text;
            else
                -- canonical key absent: rename
                update pgfr_record.config set key = v_alias[2] where key = v_alias[1];
                return query select v_alias[1], v_alias[2], 'renamed to canonical'::text;
            end if;
        else
            return query select v_alias[1], v_alias[2], 'not present (skipped)'::text;
        end if;
    end loop;
end $$;
comment on function pgfr_record.migrate_config_keys() is
'Renames deprecated config key aliases to canonical names in pgfr_record.config. Idempotent.';

-- Returns the configured ring buffer slot count, clamped to valid range (72-2880)
-- Default is 120 slots for backwards compatibility
CREATE OR REPLACE FUNCTION pgfr_record._get_ring_buffer_slots()
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT GREATEST(72, LEAST(2880,
        COALESCE(pgfr_record._get_config('ring_buffer_slots', '120')::integer, 120)
    ))
$$;
COMMENT ON FUNCTION pgfr_record._get_ring_buffer_slots() IS 'Returns configured ring buffer slot count (72-2880 range). Default 120 for backwards compatibility. Use ring_buffer_slots config to change.';

-- Sets statement timeout for section recording based on configuration, defaulting to 250ms
CREATE OR REPLACE FUNCTION pgfr_record._set_section_timeout()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_timeout_ms INTEGER;
BEGIN
    v_timeout_ms := COALESCE(
        pgfr_record._get_config('section_timeout_ms', '250')::integer,
        250
    );
    PERFORM set_config('statement_timeout', v_timeout_ms::text, true);
END;
$$;

-- Validates pgfr_record configuration parameters and system health
-- Returns diagnostic checks with status levels (OK, WARNING, CRITICAL) for configuration values, thresholds, and recent operational errors
CREATE OR REPLACE FUNCTION pgfr_record.validate_config()
RETURNS TABLE(
    check_name TEXT,
    status TEXT,
    message TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_section_timeout INTEGER;
    v_lock_timeout INTEGER;
    v_circuit_breaker_enabled BOOLEAN;
    v_schema_size_mb NUMERIC;
BEGIN
    v_section_timeout := pgfr_record._get_config('section_timeout_ms', '250')::integer;
    RETURN QUERY SELECT
        'section_timeout_ms'::text,
        CASE
            WHEN v_section_timeout > 1000 THEN 'CRITICAL'
            WHEN v_section_timeout > 500 THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('Current: %s ms. Recommended: <= 250ms for minimal overhead. Worst-case CPU: %s%% (4 sections × %sms / 60s)',
               v_section_timeout,
               round((v_section_timeout * 4.0 / 60000.0) * 100, 1),
               v_section_timeout);
    v_circuit_breaker_enabled := COALESCE(
        pgfr_record._get_config('circuit_breaker_enabled', 'true')::boolean,
        true
    );
    RETURN QUERY SELECT
        'circuit_breaker_enabled'::text,
        CASE WHEN v_circuit_breaker_enabled THEN 'OK' ELSE 'CRITICAL' END::text,
        format('Current: %s. Circuit breaker provides automatic protection under load',
               v_circuit_breaker_enabled);
    v_lock_timeout := pgfr_record._get_config('lock_timeout_ms', '100')::integer;
    RETURN QUERY SELECT
        'lock_timeout_ms'::text,
        CASE
            WHEN v_lock_timeout > 1000 THEN 'CRITICAL'
            WHEN v_lock_timeout > 500  THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('Current: %s ms. Recommended: <= 100ms to fail fast on catalog lock contention',
               v_lock_timeout);
    SELECT schema_size_mb INTO v_schema_size_mb
    FROM pgfr_record._check_schema_size();
    RETURN QUERY SELECT
        'schema_size'::text,
        CASE
            WHEN v_schema_size_mb > 10000 THEN 'CRITICAL'
            WHEN v_schema_size_mb > 5000 THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('pgfr_record schema: %s MB (warning: 5000 MB, critical: 10000 MB, auto-disable at critical)',
               round(v_schema_size_mb, 0));
    RETURN QUERY SELECT
        'skip_thresholds'::text,
        CASE
            WHEN pgfr_record._get_config('skip_activity_conn_threshold')::integer > 200
                OR pgfr_record._get_config('skip_locks_threshold')::integer > 100
            THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('Activity threshold: %s, Locks threshold: %s. Recommended: 100/50 for early protection',
               pgfr_record._get_config('skip_activity_conn_threshold'),
               pgfr_record._get_config('skip_locks_threshold'));
    DECLARE
        v_recent_failures INTEGER;
    BEGIN
        SELECT count(*) INTO v_recent_failures
        FROM pgfr_record.collection_stats
        WHERE success = false
          AND started_at > now() - interval '1 hour';
        RETURN QUERY SELECT
            'recent_failures'::text,
            CASE
                WHEN v_recent_failures > 10 THEN 'CRITICAL'
                WHEN v_recent_failures > 3 THEN 'WARNING'
                ELSE 'OK'
            END::text,
            format('%s collection failures in last hour. Check collection_stats for error_message details',
                   v_recent_failures);
    END;
    DECLARE
        v_lock_timeouts INTEGER;
    BEGIN
        SELECT count(*) INTO v_lock_timeouts
        FROM pgfr_record.collection_stats
        WHERE error_message LIKE '%lock_timeout%'
          AND started_at > now() - interval '1 hour';
        RETURN QUERY SELECT
            'lock_timeout_errors'::text,
            CASE
                WHEN v_lock_timeouts > 5 THEN 'CRITICAL'
                WHEN v_lock_timeouts > 2 THEN 'WARNING'
                ELSE 'OK'
            END::text,
            format('%s lock timeout errors in last hour. Consider increasing lock_timeout_ms or using emergency mode during high-load periods',
                   v_lock_timeouts);
    END;
END;
$$;
COMMENT ON FUNCTION pgfr_record.validate_config() IS
'Validates Flight Recorder configuration and reports on critical settings: section_timeout_ms, circuit_breaker, lock_timeout_ms, schema_size, skip_thresholds, and recent collection failures.';

-- Validates ring buffer configuration and returns diagnostic checks
-- Checks retention, batching efficiency, CPU overhead, and memory usage
CREATE OR REPLACE FUNCTION pgfr_record.validate_ring_configuration()
RETURNS TABLE(
    check_name TEXT,
    status TEXT,
    message TEXT,
    recommendation TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_slots INTEGER;
    v_sample_interval INTEGER;
    v_archive_interval INTEGER;
    v_retention_hours NUMERIC;
    v_samples_per_archive NUMERIC;
    v_memory_mb NUMERIC;
    v_cpu_pct NUMERIC;
BEGIN
    -- Get current configuration
    v_slots := pgfr_record._get_ring_buffer_slots();
    v_sample_interval := COALESCE(
        pgfr_record._get_config('sample_interval_seconds', '60')::integer,
        60
    );
    v_archive_interval := COALESCE(
        pgfr_record._get_config('archive_sample_frequency_minutes', '15')::integer,
        15
    );

    -- Calculate derived metrics
    v_retention_hours := (v_slots * v_sample_interval) / 3600.0;
    v_samples_per_archive := (v_archive_interval * 60.0) / v_sample_interval;
    v_memory_mb := v_slots * 0.09 * 1.5;  -- slots × 90KB × 1.5 overhead factor
    v_cpu_pct := (25.0 / v_sample_interval) * 100.0 / 1000.0;  -- 25ms per collection

    -- Check 1: Ring buffer retention
    RETURN QUERY SELECT
        'ring_buffer_retention'::text,
        CASE
            WHEN v_retention_hours < 1 THEN 'ERROR'
            WHEN v_retention_hours < 2 THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('%s hours retention (%s slots × %ss interval)',
               ROUND(v_retention_hours, 1), v_slots, v_sample_interval)::text,
        CASE
            WHEN v_retention_hours < 2 THEN
                format('Consider increasing ring_buffer_slots to %s for 2-hour retention',
                    CEIL((2 * 3600.0 / v_sample_interval))::integer)
            ELSE 'Retention is adequate for most incident investigations'
        END::text;

    -- Check 2: Batching efficiency (samples per archive)
    RETURN QUERY SELECT
        'batching_efficiency'::text,
        CASE
            WHEN v_samples_per_archive < 3 THEN 'WARNING'
            WHEN v_samples_per_archive > 15 THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('%s:1 samples per archive (%s min archive / %ss sample)',
               ROUND(v_samples_per_archive, 1), v_archive_interval, v_sample_interval)::text,
        CASE
            WHEN v_samples_per_archive < 3 THEN
                'Archive frequency too high relative to sampling—consider less frequent archiving'
            WHEN v_samples_per_archive > 15 THEN
                'Large data loss window on crash—consider more frequent archiving'
            ELSE 'Batching ratio is optimal (3-15 samples per archive)'
        END::text;

    -- Check 3: CPU overhead
    RETURN QUERY SELECT
        'cpu_overhead'::text,
        CASE
            WHEN v_cpu_pct > 0.1 THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('%s%% sustained CPU overhead (~25ms per collection every %ss)',
               ROUND(v_cpu_pct, 3), v_sample_interval)::text,
        CASE
            WHEN v_cpu_pct > 0.1 THEN
                'High sampling frequency—consider increasing sample_interval_seconds for production'
            ELSE 'CPU overhead is negligible'
        END::text;

    -- Check 4: Memory usage
    RETURN QUERY SELECT
        'memory_usage'::text,
        CASE
            WHEN v_memory_mb > 200 THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('~%s MB estimated ring buffer memory (%s slots)',
               ROUND(v_memory_mb, 0), v_slots)::text,
        CASE
            WHEN v_memory_mb > 200 THEN
                'Large ring buffer—ensure adequate shared_buffers headroom'
            ELSE 'Memory usage is within normal bounds'
        END::text;
END;
$$;
COMMENT ON FUNCTION pgfr_record.validate_ring_configuration() IS 'Validates ring buffer configuration and returns diagnostic checks for retention, batching efficiency, CPU overhead, and memory usage.';

-- Check if the pg_stat_statements extension is installed
-- Returns TRUE if available, FALSE otherwise
CREATE OR REPLACE FUNCTION pgfr_record._has_pg_stat_statements()
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'
    )
$$;

-- Monitors pg_stat_statements table health by checking current statement count against configured max capacity
-- Returns utilization percentage and status (OK, WARNING, HIGH_CHURN) to detect statement table churn
CREATE OR REPLACE FUNCTION pgfr_record._check_statements_health()
RETURNS TABLE(
    current_statements BIGINT,
    max_statements INTEGER,
    utilization_pct NUMERIC,
    dealloc_count BIGINT,
    status TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_current BIGINT;
    v_max INTEGER;
    v_dealloc BIGINT;
BEGIN
    IF NOT pgfr_record._has_pg_stat_statements() THEN
        RETURN QUERY SELECT 0::bigint, 0::integer, 0::numeric, 0::bigint, 'DISABLED'::text;
        RETURN;
    END IF;
    BEGIN
        v_max := current_setting('pg_stat_statements.max')::integer;
    EXCEPTION WHEN OTHERS THEN
        v_max := 5000;
    END;
    IF EXISTS (SELECT 1 FROM pg_views WHERE viewname = 'pg_stat_statements_info') THEN
        BEGIN
            SELECT
                (SELECT count(*) FROM pg_stat_statements),
                (SELECT dealloc FROM pg_stat_statements_info LIMIT 1)
            INTO v_current, v_dealloc;
        EXCEPTION WHEN OTHERS THEN
            SELECT count(*) INTO v_current FROM pg_stat_statements;
            v_dealloc := NULL;
        END;
    ELSE
        SELECT count(*) INTO v_current FROM pg_stat_statements;
        v_dealloc := NULL;
    END IF;
    RETURN QUERY SELECT
        v_current,
        v_max,
        ROUND(100.0 * v_current / NULLIF(v_max, 0), 1),
        v_dealloc,
        CASE
            WHEN v_current::numeric / NULLIF(v_max, 0) > 0.95 THEN 'HIGH_CHURN'
            WHEN v_current::numeric / NULLIF(v_max, 0) > 0.80 THEN 'WARNING'
            ELSE 'OK'
        END;
END;
$$;

-- Monitor pgfr_record schema size and automatically manage collection state (cleanup, disable, re-enable) to prevent unbounded growth
-- Returns current size, thresholds, status, and actions taken based on configurable warning/critical thresholds
CREATE OR REPLACE FUNCTION pgfr_record._check_schema_size()
RETURNS TABLE(
    schema_size_mb NUMERIC,
    warning_threshold_mb INTEGER,
    critical_threshold_mb INTEGER,
    status TEXT,
    action_taken TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_size_bytes BIGINT;
    v_size_mb NUMERIC;
    v_warning_mb INTEGER;
    v_critical_mb INTEGER;
    v_check_enabled BOOLEAN;
    v_enabled BOOLEAN;
    v_cleanup_performed BOOLEAN := false;
    v_action TEXT := '';
BEGIN
    v_check_enabled := COALESCE(
        pgfr_record._get_config('schema_size_check_enabled', 'true')::boolean,
        true
    );
    IF NOT v_check_enabled THEN
        RETURN QUERY SELECT 0::numeric, 0, 0, 'disabled'::text, 'none'::text;
        RETURN;
    END IF;
    DECLARE
        v_use_percentage BOOLEAN;
        v_db_size_mb NUMERIC;
        v_percentage NUMERIC;
        v_min_mb INTEGER;
        v_max_mb INTEGER;
    BEGIN
        v_use_percentage := COALESCE(
            pgfr_record._get_config('schema_size_use_percentage', 'true')::boolean,
            true
        );
        IF v_use_percentage THEN
            SELECT round((sum(relpages::bigint * current_setting('block_size')::bigint) / 1024.0 / 1024.0), 2)
            INTO v_db_size_mb
            FROM pg_class
            WHERE relkind IN ('r', 't', 'i', 'm')
              AND relpages > 0;
            v_percentage := COALESCE(
                pgfr_record._get_config('schema_size_percentage', '5.0')::numeric,
                5.0
            );
            v_min_mb := COALESCE(
                pgfr_record._get_config('schema_size_min_mb', '1000')::integer,
                1000
            );
            v_max_mb := COALESCE(
                pgfr_record._get_config('schema_size_max_mb', '10000')::integer,
                10000
            );
            v_critical_mb := GREATEST(v_min_mb, LEAST(v_max_mb, (v_db_size_mb * v_percentage / 100.0)::integer));
            v_warning_mb := (v_critical_mb * 0.5)::integer;
        ELSE
            v_warning_mb := COALESCE(
                pgfr_record._get_config('schema_size_warning_mb', '5000')::integer,
                5000
            );
            v_critical_mb := COALESCE(
                pgfr_record._get_config('schema_size_critical_mb', '10000')::integer,
                10000
            );
        END IF;
    END;
    SELECT COALESCE(sum(pg_total_relation_size(c.oid)), 0)
    INTO v_size_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgfr_record'
      AND c.relkind IN ('r', 'i', 't');
    v_size_mb := round(v_size_bytes / 1024.0 / 1024.0, 2);
    -- pg_cron may not be installed in this database; treat as enabled if not found
    BEGIN
        SELECT EXISTS (
            SELECT 1 FROM cron.job
            WHERE jobname LIKE 'pgfr%'
              AND active = true
        ) INTO v_enabled;
    EXCEPTION
        WHEN undefined_table OR undefined_function THEN
            v_enabled := false;
    END;
    IF v_size_mb >= v_critical_mb AND v_enabled THEN
        BEGIN
            PERFORM pgfr_record.cleanup('3 days'::interval);
            v_cleanup_performed := true;
            v_action := 'Aggressive cleanup (3 days retention)';
            SELECT COALESCE(sum(pg_total_relation_size(c.oid)), 0)
            INTO v_size_bytes
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'pgfr_record'
              AND c.relkind IN ('r', 'i', 't');
            v_size_mb := round(v_size_bytes / 1024.0 / 1024.0, 2);
            IF v_size_mb >= v_critical_mb THEN
                PERFORM pgfr_record.disable();
                v_action := v_action || '; Collection disabled (still > 10GB after cleanup)';
                RETURN QUERY SELECT
                    v_size_mb,
                    v_warning_mb,
                    v_critical_mb,
                    'CRITICAL'::TEXT,
                    v_action;
                RETURN;
            ELSE
                v_action := v_action || format('; Cleanup succeeded (%s MB remaining)', v_size_mb);
                RETURN QUERY SELECT
                    v_size_mb,
                    v_warning_mb,
                    v_critical_mb,
                    'RECOVERED'::TEXT,
                    v_action;
                RETURN;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                v_size_mb,
                v_warning_mb,
                v_critical_mb,
                'CRITICAL'::TEXT,
                format('Failed to cleanup/disable: %s', SQLERRM)::TEXT;
            RETURN;
        END;
    END IF;
    IF NOT v_enabled AND v_size_mb < (v_critical_mb * 0.8) THEN
        BEGIN
            PERFORM pgfr_record.enable();
            v_action := format('Auto-recovery: collection re-enabled (size dropped to %s MB, below 8GB threshold)', v_size_mb);
            RETURN QUERY SELECT
                v_size_mb,
                v_warning_mb,
                v_critical_mb,
                'RECOVERED'::TEXT,
                v_action;
            RETURN;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                v_size_mb,
                v_warning_mb,
                v_critical_mb,
                'ERROR'::TEXT,
                format('Failed to auto-recover: %s', SQLERRM)::TEXT;
            RETURN;
        END;
    END IF;
    IF v_size_mb >= v_warning_mb AND v_size_mb < v_critical_mb THEN
        IF NOT v_cleanup_performed THEN
            BEGIN
                PERFORM pgfr_record.cleanup('5 days'::interval);
                v_action := 'Proactive cleanup at 5GB (5 days retention)';
                SELECT COALESCE(sum(pg_total_relation_size(c.oid)), 0)
                INTO v_size_bytes
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'pgfr_record'
                  AND c.relkind IN ('r', 'i', 't');
                v_size_mb := round(v_size_bytes / 1024.0 / 1024.0, 2);
                v_action := v_action || format(' (reduced to %s MB)', v_size_mb);
            EXCEPTION WHEN OTHERS THEN
                v_action := format('Attempted cleanup but failed: %s', SQLERRM);
            END;
        END IF;
        RAISE WARNING 'pgfr_record: Schema size (% MB) in warning range (% - % MB). %',
            v_size_mb, v_warning_mb, v_critical_mb, v_action;
        RETURN QUERY SELECT
            v_size_mb,
            v_warning_mb,
            v_critical_mb,
            'WARNING'::TEXT,
            v_action;
        RETURN;
    END IF;
    RETURN QUERY SELECT
        v_size_mb,
        v_warning_mb,
        v_critical_mb,
        'OK'::TEXT,
        'None'::TEXT;
END;
$$;

-- Evaluates active backups to determine collection eligibility
-- Returns skip reason message or NULL if collection can proceed
-- Sampled activity: Collect performance samples (wait events, active sessions, locks) into ring buffers
-- Applies load shedding and circuit breaker before collection
