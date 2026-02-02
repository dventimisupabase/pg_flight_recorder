-- pg-flight-recorder PGLite Export Script
-- Run this on your production database BEFORE pg_dump to prepare data for offline analysis
--
-- Usage:
--   psql -d your_database -f pglite/export.sql
--   pg_dump -d your_database -n flight_recorder --data-only -f flight_recorder_data.sql
--
-- This script:
--   1. Populates the relation_names table with current OID->name mappings
--   2. Reports statistics about the data to be exported

\echo '=== pg-flight-recorder PGLite Export Preparation ==='
\echo ''

-- Populate relation names for offline OID resolution
\echo 'Populating relation_names table...'
SELECT flight_recorder._populate_relation_names() AS relations_captured;

\echo ''
\echo '=== Data Summary ==='

-- Report data volumes
SELECT
    'snapshots' AS table_name,
    count(*) AS row_count,
    pg_size_pretty(pg_relation_size('flight_recorder.snapshots')) AS size,
    min(captured_at)::date AS oldest,
    max(captured_at)::date AS newest
FROM flight_recorder.snapshots
UNION ALL
SELECT
    'table_snapshots',
    count(*),
    pg_size_pretty(pg_relation_size('flight_recorder.table_snapshots')),
    NULL,
    NULL
FROM flight_recorder.table_snapshots
UNION ALL
SELECT
    'index_snapshots',
    count(*),
    pg_size_pretty(pg_relation_size('flight_recorder.index_snapshots')),
    NULL,
    NULL
FROM flight_recorder.index_snapshots
UNION ALL
SELECT
    'statement_snapshots',
    count(*),
    pg_size_pretty(pg_relation_size('flight_recorder.statement_snapshots')),
    NULL,
    NULL
FROM flight_recorder.statement_snapshots
UNION ALL
SELECT
    'config_snapshots',
    count(*),
    pg_size_pretty(pg_relation_size('flight_recorder.config_snapshots')),
    NULL,
    NULL
FROM flight_recorder.config_snapshots
UNION ALL
SELECT
    'wait_samples_archive',
    count(*),
    pg_size_pretty(pg_relation_size('flight_recorder.wait_samples_archive')),
    NULL,
    NULL
FROM flight_recorder.wait_samples_archive
UNION ALL
SELECT
    'activity_samples_archive',
    count(*),
    pg_size_pretty(pg_relation_size('flight_recorder.activity_samples_archive')),
    NULL,
    NULL
FROM flight_recorder.activity_samples_archive
UNION ALL
SELECT
    'lock_samples_archive',
    count(*),
    pg_size_pretty(pg_relation_size('flight_recorder.lock_samples_archive')),
    NULL,
    NULL
FROM flight_recorder.lock_samples_archive
UNION ALL
SELECT
    'relation_names',
    count(*),
    pg_size_pretty(pg_relation_size('flight_recorder.relation_names')),
    NULL,
    NULL
FROM flight_recorder.relation_names
ORDER BY table_name;

\echo ''
\echo '=== Export Commands ==='
\echo ''
\echo 'To export data for PGLite, run:'
\echo ''
\echo '  pg_dump -d YOUR_DATABASE -n flight_recorder --data-only -f flight_recorder_data.sql'
\echo ''
\echo 'Or for a compressed export:'
\echo ''
\echo '  pg_dump -d YOUR_DATABASE -n flight_recorder --data-only | gzip > flight_recorder_data.sql.gz'
\echo ''
