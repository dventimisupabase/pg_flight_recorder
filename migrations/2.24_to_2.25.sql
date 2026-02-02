-- =============================================================================
-- Migration: 2.24 to 2.25
-- =============================================================================
-- Description: Add PGLite support and deprecate relation name columns
--
-- Changes:
--   - Add relation_names table for offline OID-to-name lookup
--   - Add _populate_relation_names() function for export preparation
--   - Add _safe_relname() function for safe OID resolution
--   - Add _get_setting_from_snapshots() for offline config access
--   - Add autovacuum_freeze_max_age to captured config settings
--   - Deprecate schemaname/relname columns in table_snapshots (make nullable)
--   - Deprecate schemaname/relname/indexrelname columns in index_snapshots (make nullable)
--   - Update vacuum_control_report() to use COALESCE for deprecated columns
--
-- Data preservation: All existing data is preserved. Name columns become nullable
--                    but existing values remain. New rows will have NULL names.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- =============================================================================
-- Step 1: Version Guard
-- =============================================================================
DO $$
DECLARE
    v_current TEXT;
    v_expected TEXT := '2.24';
    v_target TEXT := '2.25';
BEGIN
    SELECT value INTO v_current
    FROM flight_recorder.config WHERE key = 'schema_version';

    IF v_current IS NULL THEN
        RAISE EXCEPTION 'schema_version not found. Is Flight Recorder installed?';
    END IF;

    IF v_current != v_expected THEN
        RAISE EXCEPTION 'Migration 2.24→2.25 requires version %, found %', v_expected, v_current;
    END IF;

    RAISE NOTICE 'Migrating from % to %...', v_expected, v_target;
END $$;

-- =============================================================================
-- Step 2: Schema Changes
-- =============================================================================

-- Add relation_names table for offline analysis (PGLite support)
CREATE TABLE IF NOT EXISTS flight_recorder.relation_names (
    oid             OID PRIMARY KEY,
    nspname         TEXT NOT NULL,
    relname         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS relation_names_name_idx
    ON flight_recorder.relation_names(nspname, relname);
COMMENT ON TABLE flight_recorder.relation_names IS 'OID to relation name mappings for offline analysis. Populated at export time, not during collection.';

-- Make name columns nullable in table_snapshots (deprecated)
ALTER TABLE flight_recorder.table_snapshots
    ALTER COLUMN schemaname DROP NOT NULL,
    ALTER COLUMN relname DROP NOT NULL;
COMMENT ON COLUMN flight_recorder.table_snapshots.schemaname IS 'DEPRECATED: derive via relid::regclass or relation_names lookup';
COMMENT ON COLUMN flight_recorder.table_snapshots.relname IS 'DEPRECATED: derive via relid::regclass or relation_names lookup';

-- Make name columns nullable in index_snapshots (deprecated)
ALTER TABLE flight_recorder.index_snapshots
    ALTER COLUMN schemaname DROP NOT NULL,
    ALTER COLUMN relname DROP NOT NULL,
    ALTER COLUMN indexrelname DROP NOT NULL;
COMMENT ON COLUMN flight_recorder.index_snapshots.schemaname IS 'DEPRECATED: derive via relid::regclass or relation_names lookup';
COMMENT ON COLUMN flight_recorder.index_snapshots.relname IS 'DEPRECATED: derive via relid::regclass or relation_names lookup';
COMMENT ON COLUMN flight_recorder.index_snapshots.indexrelname IS 'DEPRECATED: derive via indexrelid::regclass or relation_names lookup';

-- =============================================================================
-- Step 3: Function Updates
-- =============================================================================

-- Populates relation_names table from pg_class for offline analysis
CREATE OR REPLACE FUNCTION flight_recorder._populate_relation_names()
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    TRUNCATE flight_recorder.relation_names;

    INSERT INTO flight_recorder.relation_names (oid, nspname, relname)
    SELECT c.oid, n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND c.relkind IN ('r', 'i', 'S', 'v', 'm', 'p');

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;
COMMENT ON FUNCTION flight_recorder._populate_relation_names IS
'Populates relation_names lookup table for offline analysis. Run before pg_dump when exporting data for PGLite. Returns count of relations captured.';

-- Safe relation name lookup for offline analysis
CREATE OR REPLACE FUNCTION flight_recorder._safe_relname(p_oid OID)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT nspname || '.' || relname FROM flight_recorder.relation_names WHERE oid = p_oid),
        'OID:' || p_oid::text
    )
$$;
COMMENT ON FUNCTION flight_recorder._safe_relname IS
'Resolves OID to relation name using relation_names table. Returns OID:nnn if not found. For offline analysis where pg_class is unavailable.';

-- Get setting from config_snapshots for offline analysis
CREATE OR REPLACE FUNCTION flight_recorder._get_setting_from_snapshots(
    p_name TEXT,
    p_default TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (
            SELECT cs.setting
            FROM flight_recorder.config_snapshots cs
            JOIN flight_recorder.snapshots s ON s.id = cs.snapshot_id
            WHERE cs.name = p_name
            ORDER BY s.captured_at DESC
            LIMIT 1
        ),
        p_default
    )
$$;
COMMENT ON FUNCTION flight_recorder._get_setting_from_snapshots IS
'Retrieves PostgreSQL setting from config_snapshots for offline analysis. Returns most recent captured value or default if not found.';

-- =============================================================================
-- Step 4: Update vacuum_control_report to handle deprecated columns
-- =============================================================================

-- The vacuum_control_report function must use COALESCE with ::regclass fallback
-- since schemaname/relname columns are now nullable
CREATE OR REPLACE FUNCTION flight_recorder.vacuum_control_report(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    schemaname                  TEXT,
    relname                     TEXT,
    relid                       OID,
    operating_mode              TEXT,
    mode_reason                 TEXT,
    diagnostic_classification   TEXT,
    diagnostic_confidence       TEXT,
    current_scale_factor        NUMERIC,
    recommended_scale_factor    NUMERIC,
    change_pct                  NUMERIC,
    should_recommend            BOOLEAN,
    last_recommendation_at      TIMESTAMPTZ,
    alter_table_sql             TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_enabled BOOLEAN;
    v_hysteresis_pct NUMERIC;
    v_rate_limit_minutes INTEGER;
BEGIN
    -- Check if feature is enabled
    v_enabled := COALESCE(
        flight_recorder._get_config('vacuum_control_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Get config values
    v_hysteresis_pct := COALESCE(
        flight_recorder._get_config('vacuum_control_hysteresis_pct', '25')::numeric,
        25
    );
    v_rate_limit_minutes := COALESCE(
        flight_recorder._get_config('vacuum_control_rate_limit_minutes', '60')::integer,
        60
    );

    RETURN QUERY
    WITH latest_snapshots AS (
        SELECT DISTINCT ON (ts.relid)
            ts.relid,
            COALESCE(ts.schemaname, split_part(ts.relid::regclass::text, '.', 1)) AS schemaname,
            COALESCE(ts.relname, split_part(ts.relid::regclass::text, '.', 2)) AS relname,
            ts.n_dead_tup,
            ts.reltuples,
            ts.n_live_tup
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at BETWEEN p_start_time AND p_end_time
        ORDER BY ts.relid, s.captured_at DESC
    ),
    mode_info AS (
        SELECT
            ls.relid,
            (flight_recorder.vacuum_control_mode(ls.relid)).*
        FROM latest_snapshots ls
    ),
    diag_info AS (
        SELECT
            ls.relid,
            (flight_recorder.vacuum_diagnostic(ls.relid)).*
        FROM latest_snapshots ls
    ),
    scale_info AS (
        SELECT
            ls.relid,
            (flight_recorder.compute_recommended_scale_factor(ls.relid)).*
        FROM latest_snapshots ls
    ),
    state_info AS (
        SELECT
            vcs.relid,
            vcs.last_recommendation_at,
            vcs.last_recommended_scale_factor
        FROM flight_recorder.vacuum_control_state vcs
    )
    SELECT
        ls.schemaname,
        ls.relname,
        ls.relid,
        mi.mode AS operating_mode,
        mi.reason AS mode_reason,
        di.classification AS diagnostic_classification,
        di.confidence AS diagnostic_confidence,
        si.current_scale_factor,
        si.recommended_scale_factor,
        si.change_pct,
        -- Should recommend: passes hysteresis AND rate limit
        CASE
            WHEN si.recommended_scale_factor IS NULL THEN false
            WHEN ABS(COALESCE(si.change_pct, 0)) < v_hysteresis_pct THEN false
            WHEN sti.last_recommendation_at IS NOT NULL
                 AND sti.last_recommendation_at > now() - make_interval(mins => v_rate_limit_minutes)
                 THEN false
            ELSE true
        END AS should_recommend,
        sti.last_recommendation_at,
        -- Generate ALTER TABLE SQL
        CASE
            WHEN si.recommended_scale_factor IS NOT NULL
                 AND ABS(COALESCE(si.change_pct, 0)) >= v_hysteresis_pct
            THEN format(
                'ALTER TABLE %I.%I SET (autovacuum_vacuum_scale_factor = %s);',
                ls.schemaname, ls.relname, si.recommended_scale_factor
            )
            ELSE NULL
        END AS alter_table_sql
    FROM latest_snapshots ls
    LEFT JOIN mode_info mi ON mi.relid = ls.relid
    LEFT JOIN diag_info di ON di.relid = ls.relid
    LEFT JOIN scale_info si ON si.relid = ls.relid
    LEFT JOIN state_info sti ON sti.relid = ls.relid
    WHERE mi.mode IS NOT NULL
    ORDER BY
        CASE mi.mode
            WHEN 'safety' THEN 1
            WHEN 'catch_up' THEN 2
            ELSE 3
        END,
        COALESCE(ls.n_dead_tup, 0) DESC;
END;
$$;
COMMENT ON FUNCTION flight_recorder.vacuum_control_report(TIMESTAMPTZ, TIMESTAMPTZ) IS 'Returns vacuum control recommendations for all monitored tables with hysteresis and rate limiting';

-- =============================================================================
-- Step 5: Update Version
-- =============================================================================
UPDATE flight_recorder.config
SET value = '2.25', updated_at = now()
WHERE key = 'schema_version';

COMMIT;

-- =============================================================================
-- Step 6: Post-migration verification
-- =============================================================================
DO $$
DECLARE
    v_version TEXT;
BEGIN
    SELECT value INTO v_version
    FROM flight_recorder.config WHERE key = 'schema_version';

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration Complete ===';
    RAISE NOTICE 'Now at version: %', v_version;
    RAISE NOTICE '';
    RAISE NOTICE 'New features:';
    RAISE NOTICE '  - relation_names table for offline OID resolution';
    RAISE NOTICE '  - _populate_relation_names() for export preparation';
    RAISE NOTICE '  - _safe_relname() for safe OID lookup';
    RAISE NOTICE '  - _get_setting_from_snapshots() for offline config access';
    RAISE NOTICE '';
    RAISE NOTICE 'Updates:';
    RAISE NOTICE '  - vacuum_control_report() uses COALESCE for deprecated columns';
    RAISE NOTICE '';
    RAISE NOTICE 'Deprecations:';
    RAISE NOTICE '  - table_snapshots.schemaname/relname now NULL (use relid)';
    RAISE NOTICE '  - index_snapshots.schemaname/relname/indexrelname now NULL';
    RAISE NOTICE '';
END $$;
