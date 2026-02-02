-- =============================================================================
-- pg-flight-recorder upgrade framework
-- =============================================================================
-- Detects current version and runs necessary migrations.
-- Run with: psql -f migrations/upgrade.sql
-- =============================================================================

\set ON_ERROR_STOP on

-- Detect current version and validate installation
DO $$
DECLARE
    v_current_version TEXT;
    v_target_version TEXT := '2.23';  -- Update this when adding migrations
BEGIN
    -- Check if flight_recorder schema exists
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'flight_recorder') THEN
        RAISE EXCEPTION E'\n\nFlight Recorder is not installed.\nRun: psql -f install.sql\n';
    END IF;

    -- Check if config table exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_tables
        WHERE schemaname = 'flight_recorder' AND tablename = 'config'
    ) THEN
        RAISE EXCEPTION E'\n\nFlight Recorder config table not found.\nThis installation may be corrupted. Consider reinstalling.\n';
    END IF;

    -- Get current version
    SELECT value INTO v_current_version
    FROM flight_recorder.config WHERE key = 'schema_version';

    IF v_current_version IS NULL THEN
        -- Pre-versioning installation detected
        RAISE NOTICE E'\n=== Pre-versioning installation detected ===';
        RAISE NOTICE 'Adding schema_version tracking...';
        INSERT INTO flight_recorder.config (key, value) VALUES ('schema_version', '1.0')
        ON CONFLICT (key) DO UPDATE SET value = '1.0', updated_at = now();
        v_current_version := '1.0';
    END IF;

    RAISE NOTICE E'\n=== Flight Recorder Upgrade ===';
    RAISE NOTICE 'Current version: %', v_current_version;
    RAISE NOTICE 'Target version:  %', v_target_version;

    IF v_current_version = v_target_version THEN
        RAISE NOTICE 'Already at target version. No migration needed.';
        RAISE NOTICE E'===\n';
        RETURN;
    END IF;

    RAISE NOTICE 'Migrations will be applied...';
    RAISE NOTICE E'===\n';
END $$;

-- =============================================================================
-- Migration chain
-- =============================================================================
-- Each migration file is responsible for:
-- 1. Checking its required source version
-- 2. Making schema changes (preserving data!)
-- 3. Updating the schema_version
--
-- Add new migrations here as they're created:
-- \i migrations/1.0_to_1.1.sql
-- \i migrations/1.1_to_2.0.sql
-- =============================================================================

-- Migration from 2.0 to 2.1: Add I/O read timing columns
\i migrations/2.0_to_2.1.sql

-- Migration from 2.1 to 2.2: Add configurable ring buffer slots
\i migrations/2.1_to_2.2.sql

-- Migration from 2.2 to 2.3: Add XID wraparound metrics
\i migrations/2.2_to_2.3.sql

-- Migration from 2.3 to 2.4: Add client_addr to activity sampling
\i migrations/2.3_to_2.4.sql

-- Migration from 2.4 to 2.5: Targeted statistics enhancements
\i migrations/2.4_to_2.5.sql

-- Migration from 2.5 to 2.6: Low-hanging fruit anomaly detection enhancements
\i migrations/2.5_to_2.6.sql

-- Migration from 2.6 to 2.7: Autovacuum observer enhancements
\i migrations/2.6_to_2.7.sql

-- Migration from 2.7 to 2.8
\i migrations/2.7_to_2.8.sql

-- Migration from 2.8 to 2.9
\i migrations/2.8_to_2.9.sql

-- Migration from 2.9 to 2.10
\i migrations/2.9_to_2.10.sql

-- Migration from 2.10 to 2.11
\i migrations/2.10_to_2.11.sql

-- Migration from 2.11 to 2.12
\i migrations/2.11_to_2.12.sql

-- Migration from 2.12 to 2.13
\i migrations/2.12_to_2.13.sql

-- Migration from 2.13 to 2.14
\i migrations/2.13_to_2.14.sql

-- Migration from 2.14 to 2.15
\i migrations/2.14_to_2.15.sql

-- Migration from 2.15 to 2.16
\i migrations/2.15_to_2.16.sql

-- Migration from 2.16 to 2.17: Buffer-based performance metrics
\i migrations/2.16_to_2.17.sql

-- Migration from 2.17 to 2.18: Enhanced SQLite export (kept for version continuity)
\i migrations/2.17_to_2.18.sql

-- Migration from 2.18 to 2.19: Remove SQLite export function
\i migrations/2.18_to_2.19.sql

-- Migration from 2.19 to 2.20: Remove canary queries feature
\i migrations/2.19_to_2.20.sql

-- Migration from 2.20 to 2.21: Remove auto-detect wrappers
\i migrations/2.20_to_2.21.sql

-- Migration from 2.21 to 2.22: Remove visual timeline, forecasting, and high_ddl profile
\i migrations/2.21_to_2.22.sql

-- Migration from 2.22 to 2.23: Add table size tracking for bloat detection
\i migrations/2.22_to_2.23.sql

-- Migration from 2.23 to 2.24: Vacuum Control Enhancements
\i migrations/2.23_to_2.24.sql

-- =============================================================================
-- Post-upgrade verification
-- =============================================================================
DO $$
DECLARE
    v_final_version TEXT;
BEGIN
    SELECT value INTO v_final_version
    FROM flight_recorder.config WHERE key = 'schema_version';

    RAISE NOTICE E'\n=== Upgrade Complete ===';
    RAISE NOTICE 'Final version: %', v_final_version;
    RAISE NOTICE E'===\n';
END $$;
