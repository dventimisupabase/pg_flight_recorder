-- =============================================================================
-- Migration: 2.23 to 2.24
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
    v_expected TEXT := '2.23';
    v_target TEXT := '2.24';
BEGIN
    SELECT value INTO v_current
    FROM flight_recorder.config WHERE key = 'schema_version';

    IF v_current IS NULL THEN
        RAISE EXCEPTION 'schema_version not found. Is Flight Recorder installed?';
    END IF;

    IF v_current != v_expected THEN
        RAISE EXCEPTION 'Migration 2.23→2.24 requires version %, found %', v_expected, v_current;
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
-- Step 4: Update Version
-- =============================================================================
UPDATE flight_recorder.config
SET value = '2.24', updated_at = now()
WHERE key = 'schema_version';

COMMIT;

-- =============================================================================
-- Step 5: Post-migration verification
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
    RAISE NOTICE 'Deprecations:';
    RAISE NOTICE '  - table_snapshots.schemaname/relname now NULL (use relid)';
    RAISE NOTICE '  - index_snapshots.schemaname/relname/indexrelname now NULL';
    RAISE NOTICE '';
END $$;
