-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- pgfr_record v2: schema bootstrap.
--
-- pgfr_record appends debounced, dictionary-encoded jsonb samples of
-- PostgreSQL's own stats views and system views into time-partitioned
-- tables, and drops old partitions. Every collector and generator behavior
-- is a pure function of pgfr_record.manifest (see 02_manifest.sql).

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        RAISE EXCEPTION E'\n\npgfr_record requires pg_cron.\n\nInstall pg_cron first:\n  CREATE EXTENSION pg_cron;\n\nSee: https://github.com/citusdata/pg_cron\n';
    END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS pgfr_record;
COMMENT ON SCHEMA pgfr_record IS
    'pg_flight_recorder v2 core: manifest-driven capture of PostgreSQL stats/system views into time-partitioned, dictionary-encoded archive tables. Append-only; retention is partition drop. Start at pgfr_record.manifest.';
