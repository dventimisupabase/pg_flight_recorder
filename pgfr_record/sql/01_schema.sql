-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        RAISE EXCEPTION E'\n\nFlight Recorder requires pg_cron extension.\n\nInstall pg_cron first:\n  CREATE EXTENSION pg_cron;\n\nSee: https://github.com/citusdata/pg_cron\n';
    END IF;
END $$;

-- Check for existing installation and warn about upgrade path
DO $$
DECLARE
    existing_version TEXT;
BEGIN
    SELECT value INTO existing_version
    FROM pgfr_record.config WHERE key = 'schema_version';

    IF existing_version IS NOT NULL THEN
        RAISE NOTICE E'\n=== Existing installation detected (v%) ===', existing_version;
        RAISE NOTICE 'This install script will update functions and views.';
        RAISE NOTICE 'Your data will be preserved.';
        RAISE NOTICE E'===\n';
    END IF;
EXCEPTION
    WHEN undefined_table THEN
        -- Fresh install, continue normally
        NULL;
    WHEN invalid_schema_name THEN
        -- Schema doesn't exist yet, fresh install
        NULL;
END $$;

CREATE SCHEMA IF NOT EXISTS pgfr_record;

-- Stores periodic snapshots of PostgreSQL system performance metrics
-- Captures WAL activity, checkpoint behavior, IO operations, transactions,
-- and resource utilization to enable performance analysis and historical trending
