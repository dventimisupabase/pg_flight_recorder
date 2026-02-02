\set ON_ERROR_STOP on
BEGIN;
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
    FROM flight_recorder.config WHERE key = 'schema_version';

    IF existing_version IS NOT NULL THEN
        RAISE NOTICE E'\n=== Existing installation detected (v%) ===', existing_version;
        RAISE NOTICE 'This install script will update functions and views.';
        RAISE NOTICE 'Your data will be preserved.';
        RAISE NOTICE 'For schema changes, use: psql -f migrations/upgrade.sql';
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

CREATE SCHEMA IF NOT EXISTS flight_recorder;

-- Stores periodic snapshots of PostgreSQL system performance metrics
-- Captures WAL activity, checkpoint behavior, IO operations, transactions,
-- and resource utilization to enable performance analysis and historical trending
CREATE TABLE IF NOT EXISTS flight_recorder.snapshots (
    id              SERIAL PRIMARY KEY,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    pg_version      INTEGER NOT NULL,
    wal_records     BIGINT,
    wal_fpi         BIGINT,
    wal_bytes       BIGINT,
    wal_write_time  DOUBLE PRECISION,
    wal_sync_time   DOUBLE PRECISION,
    checkpoint_lsn  PG_LSN,
    checkpoint_time TIMESTAMPTZ,
    ckpt_timed      BIGINT,
    ckpt_requested  BIGINT,
    ckpt_write_time DOUBLE PRECISION,
    ckpt_sync_time  DOUBLE PRECISION,
    ckpt_buffers    BIGINT,
    bgw_buffers_clean       BIGINT,
    bgw_maxwritten_clean    BIGINT,
    bgw_buffers_alloc       BIGINT,
    bgw_buffers_backend     BIGINT,
    bgw_buffers_backend_fsync BIGINT,
    autovacuum_workers      INTEGER,
    slots_count             INTEGER,
    slots_max_retained_wal  BIGINT,
    io_checkpointer_reads       BIGINT,
    io_checkpointer_read_time   DOUBLE PRECISION,
    io_checkpointer_writes      BIGINT,
    io_checkpointer_write_time  DOUBLE PRECISION,
    io_checkpointer_fsyncs      BIGINT,
    io_checkpointer_fsync_time  DOUBLE PRECISION,
    io_autovacuum_reads         BIGINT,
    io_autovacuum_read_time     DOUBLE PRECISION,
    io_autovacuum_writes        BIGINT,
    io_autovacuum_write_time    DOUBLE PRECISION,
    io_client_reads             BIGINT,
    io_client_read_time         DOUBLE PRECISION,
    io_client_writes            BIGINT,
    io_client_write_time        DOUBLE PRECISION,
    io_bgwriter_reads           BIGINT,
    io_bgwriter_read_time       DOUBLE PRECISION,
    io_bgwriter_writes          BIGINT,
    io_bgwriter_write_time      DOUBLE PRECISION,
    temp_files                  BIGINT,
    temp_bytes                  BIGINT,
    xact_commit                 BIGINT,
    xact_rollback               BIGINT,
    blks_read                   BIGINT,
    blks_hit                    BIGINT,
    connections_active          INTEGER,
    connections_total           INTEGER,
    connections_max             INTEGER,
    db_size_bytes               BIGINT,
    datfrozenxid_age            INTEGER,
    archived_count              BIGINT,
    last_archived_wal           TEXT,
    last_archived_time          TIMESTAMPTZ,
    failed_count                BIGINT,
    last_failed_wal             TEXT,
    last_failed_time            TIMESTAMPTZ,
    archiver_stats_reset        TIMESTAMPTZ,
    confl_tablespace            BIGINT,
    confl_lock                  BIGINT,
    confl_snapshot              BIGINT,
    confl_bufferpin             BIGINT,
    confl_deadlock              BIGINT,
    confl_active_logicalslot    BIGINT,
    max_catalog_oid             BIGINT,
    large_object_count          BIGINT
);
CREATE INDEX IF NOT EXISTS snapshots_captured_at_idx ON flight_recorder.snapshots(captured_at);

-- Captures replication metrics from pg_stat_replication for each snapshot
-- Tracks streaming replication connection state, LSN positions, and lag for each replica
-- Each record represents a single replication connection at a point in time
CREATE TABLE IF NOT EXISTS flight_recorder.replication_snapshots (
    snapshot_id             INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    pid                     INTEGER NOT NULL,
    client_addr             INET,
    application_name        TEXT,
    state                   TEXT,
    sync_state              TEXT,
    sent_lsn                PG_LSN,
    write_lsn               PG_LSN,
    flush_lsn               PG_LSN,
    replay_lsn              PG_LSN,
    write_lag               INTERVAL,
    flush_lag               INTERVAL,
    replay_lag              INTERVAL,
    PRIMARY KEY (snapshot_id, pid)
);

-- Captures vacuum progress from pg_stat_progress_vacuum for each snapshot
-- Tracks vacuum phase, blocks scanned/vacuumed, dead tuple counts
-- Each record represents a single vacuum operation at a point in time
CREATE TABLE IF NOT EXISTS flight_recorder.vacuum_progress_snapshots (
    snapshot_id         INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    pid                 INTEGER NOT NULL,
    datid               OID,
    datname             TEXT,
    relid               OID,
    relname             TEXT,
    phase               TEXT,
    heap_blks_total     BIGINT,
    heap_blks_scanned   BIGINT,
    heap_blks_vacuumed  BIGINT,
    index_vacuum_count  BIGINT,
    max_dead_tuples     BIGINT,
    num_dead_tuples     BIGINT,
    PRIMARY KEY (snapshot_id, pid)
);
COMMENT ON TABLE flight_recorder.vacuum_progress_snapshots IS 'Vacuum progress snapshots from pg_stat_progress_vacuum for monitoring long-running vacuums';

-- Stores execution statistics for SQL statements at specific snapshot points
-- Captures query performance metrics (timing, I/O, WAL activity) per query/user/database
-- Linked to snapshots via FK; enables historical analysis and performance trending
CREATE TABLE IF NOT EXISTS flight_recorder.statement_snapshots (
    snapshot_id         INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    queryid             BIGINT NOT NULL,
    userid              OID,
    dbid                OID,
    query_preview       TEXT,
    calls               BIGINT,
    total_exec_time     DOUBLE PRECISION,
    min_exec_time       DOUBLE PRECISION,
    max_exec_time       DOUBLE PRECISION,
    mean_exec_time      DOUBLE PRECISION,
    rows                BIGINT,
    shared_blks_hit     BIGINT,
    shared_blks_read    BIGINT,
    shared_blks_dirtied BIGINT,
    shared_blks_written BIGINT,
    temp_blks_read      BIGINT,
    temp_blks_written   BIGINT,
    blk_read_time       DOUBLE PRECISION,
    blk_write_time      DOUBLE PRECISION,
    wal_records         BIGINT,
    wal_bytes           NUMERIC,
    PRIMARY KEY (snapshot_id, queryid, dbid)
);
CREATE INDEX IF NOT EXISTS statement_snapshots_queryid_idx
    ON flight_recorder.statement_snapshots(queryid);
CREATE UNLOGGED TABLE IF NOT EXISTS flight_recorder.samples_ring (
    slot_id             INTEGER PRIMARY KEY CHECK (slot_id >= 0 AND slot_id < 2880),
    captured_at         TIMESTAMPTZ NOT NULL,
    epoch_seconds       BIGINT NOT NULL
) WITH (fillfactor = 70);
COMMENT ON TABLE flight_recorder.samples_ring IS 'Ring buffer: Master slot tracker (configurable slots via ring_buffer_slots, default 120). Supports up to 2880 slots for extended retention or fine-grained sampling. Fillfactor 70 enables HOT updates. Use configure_ring_autovacuum(false) to disable autovacuum if desired.';

CREATE UNLOGGED TABLE IF NOT EXISTS flight_recorder.wait_samples_ring (
    slot_id             INTEGER REFERENCES flight_recorder.samples_ring(slot_id) ON DELETE CASCADE,
    row_num             INTEGER NOT NULL CHECK (row_num >= 0 AND row_num < 100),
    backend_type        TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    state               TEXT,
    count               INTEGER,
    PRIMARY KEY (slot_id, row_num)
) WITH (fillfactor = 90);
COMMENT ON TABLE flight_recorder.wait_samples_ring IS 'Ring buffer: Wait events (UPDATE-only pattern). Pre-populated rows (slots × 100 rows, default 12,000). Fillfactor 90 enables HOT updates. Use configure_ring_autovacuum(false) to disable autovacuum if desired. NULLs indicate unused slots.';

CREATE UNLOGGED TABLE IF NOT EXISTS flight_recorder.activity_samples_ring (
    slot_id             INTEGER REFERENCES flight_recorder.samples_ring(slot_id) ON DELETE CASCADE,
    row_num             INTEGER NOT NULL CHECK (row_num >= 0 AND row_num < 25),
    pid                 INTEGER,
    usename             TEXT,
    application_name    TEXT,
    client_addr         INET,
    backend_type        TEXT,
    state               TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    backend_start       TIMESTAMPTZ,
    xact_start          TIMESTAMPTZ,
    query_start         TIMESTAMPTZ,
    state_change        TIMESTAMPTZ,
    query_preview       TEXT,
    PRIMARY KEY (slot_id, row_num)
) WITH (fillfactor = 90);
COMMENT ON TABLE flight_recorder.activity_samples_ring IS 'Ring buffer: Active sessions (UPDATE-only pattern). Pre-populated rows (slots × 25 rows, default 3,000). Top 25 active sessions per sample. Fillfactor 90 enables HOT updates. Use configure_ring_autovacuum(false) to disable autovacuum if desired. NULLs indicate unused slots.';

CREATE UNLOGGED TABLE IF NOT EXISTS flight_recorder.lock_samples_ring (
    slot_id                 INTEGER REFERENCES flight_recorder.samples_ring(slot_id) ON DELETE CASCADE,
    row_num                 INTEGER NOT NULL CHECK (row_num >= 0 AND row_num < 100),
    blocked_pid             INTEGER,
    blocked_user            TEXT,
    blocked_app             TEXT,
    blocked_query_preview   TEXT,
    blocked_duration        INTERVAL,
    blocking_pid            INTEGER,
    blocking_user           TEXT,
    blocking_app            TEXT,
    blocking_query_preview  TEXT,
    lock_type               TEXT,
    locked_relation_oid     OID,
    PRIMARY KEY (slot_id, row_num)
) WITH (fillfactor = 90);
COMMENT ON TABLE flight_recorder.lock_samples_ring IS 'Ring buffer: Lock contention (UPDATE-only pattern). Pre-populated rows (slots × 100 rows, default 12,000). Max 100 blocked/blocking pairs per sample. Fillfactor 90 enables HOT updates. Use configure_ring_autovacuum(false) to disable autovacuum if desired. NULLs indicate unused slots.';

INSERT INTO flight_recorder.samples_ring (slot_id, captured_at, epoch_seconds)
SELECT
    generate_series AS slot_id,
    '1970-01-01'::timestamptz,
    0
FROM generate_series(0, 119)
ON CONFLICT (slot_id) DO NOTHING;
INSERT INTO flight_recorder.wait_samples_ring (slot_id, row_num)
SELECT s.slot_id, r.row_num
FROM generate_series(0, 119) s(slot_id)
CROSS JOIN generate_series(0, 99) r(row_num)
ON CONFLICT (slot_id, row_num) DO NOTHING;
INSERT INTO flight_recorder.activity_samples_ring (slot_id, row_num)
SELECT s.slot_id, r.row_num
FROM generate_series(0, 119) s(slot_id)
CROSS JOIN generate_series(0, 24) r(row_num)
ON CONFLICT (slot_id, row_num) DO NOTHING;
INSERT INTO flight_recorder.lock_samples_ring (slot_id, row_num)
SELECT s.slot_id, r.row_num
FROM generate_series(0, 119) s(slot_id)
CROSS JOIN generate_series(0, 99) r(row_num)
ON CONFLICT (slot_id, row_num) DO NOTHING;
-- Aggregates wait event statistics over 5-minute windows, enabling analysis of wait event patterns
-- Stores metrics like average/max concurrent waiters per event type, state, and backend type
-- Aggregates: durable and survives crashes, with indexes for efficient time-range and event-type queries
CREATE TABLE IF NOT EXISTS flight_recorder.wait_event_aggregates (
    id              BIGSERIAL PRIMARY KEY,
    start_time      TIMESTAMPTZ NOT NULL,
    end_time        TIMESTAMPTZ NOT NULL,
    backend_type    TEXT NOT NULL,
    wait_event_type TEXT NOT NULL,
    wait_event      TEXT NOT NULL,
    state           TEXT NOT NULL,
    sample_count    INTEGER NOT NULL,
    total_waiters   BIGINT NOT NULL,
    avg_waiters     NUMERIC NOT NULL,
    max_waiters     INTEGER NOT NULL,
    pct_of_samples  NUMERIC
);
CREATE INDEX IF NOT EXISTS wait_aggregates_time_idx
    ON flight_recorder.wait_event_aggregates(start_time, end_time);
CREATE INDEX IF NOT EXISTS wait_aggregates_event_idx
    ON flight_recorder.wait_event_aggregates(wait_event_type, wait_event);
COMMENT ON TABLE flight_recorder.wait_event_aggregates IS 'Aggregates: Durable wait event summaries (5-min windows, survives crashes)';


-- Stores aggregated lock contention patterns within time windows
-- Tracks which sessions block others, including lock type, affected relation, and duration statistics
-- Enables forensic analysis of lock conflicts and performance bottlenecks across restarts
CREATE TABLE IF NOT EXISTS flight_recorder.lock_aggregates (
    id                  BIGSERIAL PRIMARY KEY,
    start_time          TIMESTAMPTZ NOT NULL,
    end_time            TIMESTAMPTZ NOT NULL,
    blocked_user        TEXT,
    blocking_user       TEXT,
    lock_type           TEXT,
    locked_relation_oid OID,
    occurrence_count    INTEGER NOT NULL,
    max_duration        INTERVAL,
    avg_duration        INTERVAL,
    sample_query        TEXT
);
CREATE INDEX IF NOT EXISTS lock_aggregates_time_idx
    ON flight_recorder.lock_aggregates(start_time, end_time);
COMMENT ON TABLE flight_recorder.lock_aggregates IS 'Aggregates: Durable lock pattern summaries (5-min windows, survives crashes)';


-- Aggregates activity samples within 5-minute time windows
-- Stores query preview, occurrence count, and duration metrics (max/avg)
-- Provides durable activity summaries that survive database crashes
CREATE TABLE IF NOT EXISTS flight_recorder.activity_aggregates (
    id                  BIGSERIAL PRIMARY KEY,
    start_time          TIMESTAMPTZ NOT NULL,
    end_time            TIMESTAMPTZ NOT NULL,
    query_preview       TEXT,
    occurrence_count    INTEGER NOT NULL,
    max_duration        INTERVAL,
    avg_duration        INTERVAL
);
CREATE INDEX IF NOT EXISTS activity_aggregates_time_idx
    ON flight_recorder.activity_aggregates(start_time, end_time);
COMMENT ON TABLE flight_recorder.activity_aggregates IS 'Aggregates: Durable activity summaries (5-min windows, survives crashes)';


-- Stores snapshot samples of PostgreSQL backend activity for forensic analysis
-- Captures session details, query state, and wait events at regular intervals (15-min cadence)
-- Indexed by timestamp, sample group, and process ID for efficient historical queries
CREATE TABLE IF NOT EXISTS flight_recorder.activity_samples_archive (
    id                  BIGSERIAL PRIMARY KEY,
    sample_id           BIGINT NOT NULL,
    captured_at         TIMESTAMPTZ NOT NULL,
    pid                 INTEGER,
    usename             TEXT,
    application_name    TEXT,
    client_addr         INET,
    backend_type        TEXT,
    state               TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    backend_start       TIMESTAMPTZ,
    xact_start          TIMESTAMPTZ,
    query_start         TIMESTAMPTZ,
    state_change        TIMESTAMPTZ,
    query_preview       TEXT
);
CREATE INDEX IF NOT EXISTS activity_archive_captured_at_idx
    ON flight_recorder.activity_samples_archive(captured_at);
CREATE INDEX IF NOT EXISTS activity_archive_sample_id_idx
    ON flight_recorder.activity_samples_archive(sample_id);
CREATE INDEX IF NOT EXISTS activity_archive_pid_idx
    ON flight_recorder.activity_samples_archive(pid, captured_at);
COMMENT ON TABLE flight_recorder.activity_samples_archive IS 'Raw archives: Activity samples for forensic analysis (15-min cadence, full resolution)';


-- Archives lock contention incidents with complete blocking chains (blocked and blocking process details)
-- Captures at 15-minute intervals for forensic analysis of lock conflicts and deadlock relationships
-- Stores query previews, process info (PID, user, application), lock types, and relation OIDs
CREATE TABLE IF NOT EXISTS flight_recorder.lock_samples_archive (
    id                      BIGSERIAL PRIMARY KEY,
    sample_id               BIGINT NOT NULL,
    captured_at             TIMESTAMPTZ NOT NULL,
    blocked_pid             INTEGER,
    blocked_user            TEXT,
    blocked_app             TEXT,
    blocked_query_preview   TEXT,
    blocked_duration        INTERVAL,
    blocking_pid            INTEGER,
    blocking_user           TEXT,
    blocking_app            TEXT,
    blocking_query_preview  TEXT,
    lock_type               TEXT,
    locked_relation_oid     OID
);
CREATE INDEX IF NOT EXISTS lock_archive_captured_at_idx
    ON flight_recorder.lock_samples_archive(captured_at);
CREATE INDEX IF NOT EXISTS lock_archive_sample_id_idx
    ON flight_recorder.lock_samples_archive(sample_id);
CREATE INDEX IF NOT EXISTS lock_archive_blocked_pid_idx
    ON flight_recorder.lock_samples_archive(blocked_pid, captured_at);
CREATE INDEX IF NOT EXISTS lock_archive_blocking_pid_idx
    ON flight_recorder.lock_samples_archive(blocking_pid, captured_at);
COMMENT ON TABLE flight_recorder.lock_samples_archive IS 'Raw archives: Lock samples for forensic analysis (15-min cadence, full blocking chains)';


-- Archives raw wait event samples at full resolution for forensic analysis
-- Captures backend type, wait event type/name, and state to enable detailed investigation
-- Linked to parent samples via sample_id; indexed for efficient time-series queries
CREATE TABLE IF NOT EXISTS flight_recorder.wait_samples_archive (
    id                  BIGSERIAL PRIMARY KEY,
    sample_id           BIGINT NOT NULL,
    captured_at         TIMESTAMPTZ NOT NULL,
    backend_type        TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    state               TEXT,
    count               INTEGER
);
CREATE INDEX IF NOT EXISTS wait_archive_captured_at_idx
    ON flight_recorder.wait_samples_archive(captured_at);
CREATE INDEX IF NOT EXISTS wait_archive_sample_id_idx
    ON flight_recorder.wait_samples_archive(sample_id);
CREATE INDEX IF NOT EXISTS wait_archive_wait_event_idx
    ON flight_recorder.wait_samples_archive(wait_event_type, wait_event, captured_at);
COMMENT ON TABLE flight_recorder.wait_samples_archive IS 'Raw archives: Wait event samples for forensic analysis (15-min cadence, full resolution)';


-- Captures table-level statistics from pg_stat_user_tables for hotspot tracking
-- Tracks sequential/index scans, DML activity, dead tuples, and maintenance events
-- Enables diagnosis of table-level performance issues and bloat detection
CREATE TABLE IF NOT EXISTS flight_recorder.table_snapshots (
    snapshot_id         INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    schemaname          TEXT,             -- DEPRECATED: derive via relid::regclass or relation_names
    relname             TEXT,             -- DEPRECATED: derive via relid::regclass or relation_names
    relid               OID NOT NULL,
    seq_scan            BIGINT,
    seq_tup_read        BIGINT,
    idx_scan            BIGINT,
    idx_tup_fetch       BIGINT,
    n_tup_ins           BIGINT,
    n_tup_upd           BIGINT,
    n_tup_del           BIGINT,
    n_tup_hot_upd       BIGINT,
    n_live_tup          BIGINT,
    n_dead_tup          BIGINT,
    n_mod_since_analyze BIGINT,
    vacuum_count        BIGINT,
    autovacuum_count    BIGINT,
    analyze_count       BIGINT,
    autoanalyze_count   BIGINT,
    last_vacuum         TIMESTAMPTZ,
    last_autovacuum     TIMESTAMPTZ,
    last_analyze        TIMESTAMPTZ,
    last_autoanalyze    TIMESTAMPTZ,
    relfrozenxid_age    INTEGER,
    -- Size metrics for bloat detection (added in 2.23)
    table_size_bytes    BIGINT,          -- pg_relation_size: heap only
    total_size_bytes    BIGINT,          -- pg_total_relation_size: heap + indexes + TOAST
    indexes_size_bytes  BIGINT,          -- pg_indexes_size: all indexes
    PRIMARY KEY (snapshot_id, relid)
);
CREATE INDEX IF NOT EXISTS table_snapshots_relid_idx
    ON flight_recorder.table_snapshots(relid);
COMMENT ON TABLE flight_recorder.table_snapshots IS 'Table-level statistics snapshots for hotspot tracking and bloat detection. Includes size metrics for extension-free bloat estimation.';


-- Captures index-level statistics from pg_stat_user_indexes
-- Tracks index usage, tuple reads/fetches, and index sizes
-- Enables identification of unused indexes and index efficiency analysis
CREATE TABLE IF NOT EXISTS flight_recorder.index_snapshots (
    snapshot_id         INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    schemaname          TEXT,             -- DEPRECATED: derive via relid::regclass or relation_names
    relname             TEXT,             -- DEPRECATED: derive via relid::regclass or relation_names
    indexrelname        TEXT,             -- DEPRECATED: derive via indexrelid::regclass or relation_names
    relid               OID NOT NULL,
    indexrelid          OID NOT NULL,
    idx_scan            BIGINT,
    idx_tup_read        BIGINT,
    idx_tup_fetch       BIGINT,
    index_size_bytes    BIGINT,
    PRIMARY KEY (snapshot_id, indexrelid)
);
CREATE INDEX IF NOT EXISTS index_snapshots_indexrelid_idx
    ON flight_recorder.index_snapshots(indexrelid);
CREATE INDEX IF NOT EXISTS index_snapshots_relid_idx
    ON flight_recorder.index_snapshots(relid);
COMMENT ON TABLE flight_recorder.index_snapshots IS 'Index-level statistics snapshots for usage tracking and efficiency analysis';


-- Captures PostgreSQL configuration parameters from pg_settings
-- Stores relevant settings to provide configuration context during incident analysis
-- Enables detection of configuration changes over time
CREATE TABLE IF NOT EXISTS flight_recorder.config_snapshots (
    snapshot_id     INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    setting         TEXT,
    unit            TEXT,
    source          TEXT,
    sourcefile      TEXT,
    PRIMARY KEY (snapshot_id, name)
);
CREATE INDEX IF NOT EXISTS config_snapshots_name_idx
    ON flight_recorder.config_snapshots(name);
COMMENT ON TABLE flight_recorder.config_snapshots IS 'PostgreSQL configuration snapshots for change tracking and incident context';


-- Stores relation OID to name mappings for offline analysis (e.g., PGLite)
-- Populated by _populate_relation_names() before data export
-- Enables analysis functions to resolve OIDs without access to pg_class
CREATE TABLE IF NOT EXISTS flight_recorder.relation_names (
    oid             OID PRIMARY KEY,
    nspname         TEXT NOT NULL,
    relname         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS relation_names_name_idx
    ON flight_recorder.relation_names(nspname, relname);
COMMENT ON TABLE flight_recorder.relation_names IS 'OID to relation name mappings for offline analysis. Populated at export time, not during collection.';


-- Captures database-level and role-level configuration overrides from pg_db_role_setting
-- These settings override global GUCs and are often overlooked during incident analysis
-- Complementary to config_snapshots which tracks global settings
CREATE TABLE IF NOT EXISTS flight_recorder.db_role_config_snapshots (
    snapshot_id     INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    database_name   TEXT NOT NULL DEFAULT '',  -- Empty string = applies to all databases (role-level only)
    role_name       TEXT NOT NULL DEFAULT '',  -- Empty string = applies to all roles (database-level only)
    parameter_name  TEXT NOT NULL,
    parameter_value TEXT,
    PRIMARY KEY (snapshot_id, database_name, role_name, parameter_name)
);
CREATE INDEX IF NOT EXISTS db_role_config_snapshots_param_idx
    ON flight_recorder.db_role_config_snapshots(parameter_name);
COMMENT ON TABLE flight_recorder.db_role_config_snapshots IS 'Database and role-level configuration overrides (ALTER DATABASE/ROLE SET) for change tracking';


-- Formats byte values as human-readable strings with appropriate units (GB, MB, KB, B)
CREATE OR REPLACE FUNCTION flight_recorder._pretty_bytes(bytes BIGINT)
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
CREATE OR REPLACE FUNCTION flight_recorder._interpolate_metric(
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
COMMENT ON FUNCTION flight_recorder._interpolate_metric IS
'Linear interpolation helper for time-travel debugging. Calculates estimated metric value at a target timestamp between two known data points. Returns rounded value (4 decimal places). Handles edge cases: NULL inputs, same timestamps, and clamps ratio to [0,1] to prevent extrapolation.';


-- Populates relation_names table from pg_class for offline analysis
-- Run this before exporting data for use with PGLite or other offline analysis tools
-- This is an EXPORT-TIME operation, not a collection-time operation
CREATE OR REPLACE FUNCTION flight_recorder._populate_relation_names()
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Truncate and repopulate to ensure consistency
    TRUNCATE flight_recorder.relation_names;

    INSERT INTO flight_recorder.relation_names (oid, nspname, relname)
    SELECT c.oid, n.nspname, c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND c.relkind IN ('r', 'i', 'S', 'v', 'm', 'p');  -- tables, indexes, sequences, views, matviews, partitioned

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;
COMMENT ON FUNCTION flight_recorder._populate_relation_names IS
'Populates relation_names lookup table for offline analysis. Run before pg_dump when exporting data for PGLite. Returns count of relations captured.';


-- Resolves OID to schema-qualified relation name using relation_names lookup table
-- Falls back to OID string if not found (for offline analysis compatibility)
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


-- Retrieves a PostgreSQL setting from config_snapshots history
-- For offline analysis where pg_settings is unavailable
-- Returns most recent captured value, or default if not found
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


-- Returns the PostgreSQL major version number
-- Extracts major version by dividing server_version_num by 10000
CREATE OR REPLACE FUNCTION flight_recorder._pg_version()
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT current_setting('server_version_num')::integer / 10000
$$;

-- Configuration key-value store for flight_recorder extension
-- Manages tuning parameters, thresholds, timeouts, and feature flags
-- Tracks when each setting was last modified via updated_at timestamp
CREATE TABLE IF NOT EXISTS flight_recorder.config (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Single source of truth for profile settings
-- Profiles define behavioral presets for different environments
CREATE OR REPLACE FUNCTION flight_recorder._profile_settings()
RETURNS TABLE(
    profile     TEXT,
    key         TEXT,
    value       TEXT,
    description TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT * FROM (VALUES
        ('default', 'sample_interval_seconds', '180', 'Sample every 3 minutes'),
        ('default', 'adaptive_sampling', 'true', 'Skip collection when system idle'),
        ('default', 'load_shedding_enabled', 'true', 'Skip during high load (>70% connections)'),
        ('default', 'load_throttle_enabled', 'true', 'Skip during I/O pressure'),
        ('default', 'circuit_breaker_enabled', 'true', 'Auto-skip if collections run slow'),
        ('default', 'enable_locks', 'true', 'Collect lock contention data'),
        ('default', 'enable_progress', 'true', 'Collect operation progress'),
        ('default', 'snapshot_based_collection', 'true', 'Use snapshot-based collection (67% fewer locks)'),
        ('default', 'retention_snapshots_days', '30', 'Keep 30 days of snapshot data'),
        ('default', 'aggregate_retention_days', '7', 'Keep 7 days of aggregate data'),
        ('default', 'table_stats_enabled', 'true', 'Collect table statistics'),
        ('default', 'index_stats_enabled', 'true', 'Collect index statistics'),
        ('default', 'config_snapshots_enabled', 'true', 'Collect config snapshots'),
        ('default', 'db_role_config_snapshots_enabled', 'true', 'Collect database/role config overrides'),
        ('default', 'retention_samples_days', '7', 'Keep raw samples 7 days'),
        ('default', 'retention_statements_days', '30', 'Keep statement snapshots 30 days'),
        ('default', 'retention_collection_stats_days', '30', 'Keep collection stats 30 days'),
        ('default', 'section_timeout_ms', '250', 'Per-section timeout 250ms'),
        ('default', 'statement_timeout_ms', '1000', 'Statement timeout 1 second'),
        ('default', 'work_mem_kb', '2048', 'work_mem 2MB for collection queries'),
        ('default', 'skip_locks_threshold', '50', 'Skip lock collection if > 50 blocked'),
        ('default', 'skip_activity_conn_threshold', '100', 'Skip activity if > 100 active'),
        ('default', 'load_throttle_xact_threshold', '1000', 'Skip if > 1000 xact/sec'),
        ('default', 'load_throttle_blk_threshold', '10000', 'Skip if > 10000 blk/sec'),
        ('default', 'statements_interval_minutes', '15', 'Collect statements every 15 minutes'),
        ('default', 'statements_min_calls', '1', 'Include queries with >= 1 call'),
        ('default', 'table_stats_top_n', '50', 'Track top 50 tables'),
        ('default', 'collection_jitter_enabled', 'true', 'Add jitter to prevent thundering herd'),
        ('default', 'auto_mode_enabled', 'true', 'Enable automatic mode switching'),
        ('default', 'auto_mode_connections_threshold', '60', 'Emergency mode at 60% connections'),
        ('production_safe', 'sample_interval_seconds', '300', 'Sample every 5 minutes (40% less overhead)'),
        ('production_safe', 'adaptive_sampling', 'true', 'Skip when idle'),
        ('production_safe', 'load_shedding_enabled', 'true', 'Skip during high load'),
        ('production_safe', 'load_shedding_active_pct', '60', 'More aggressive load shedding (60% vs 70%)'),
        ('production_safe', 'load_throttle_enabled', 'true', 'Skip during I/O pressure'),
        ('production_safe', 'circuit_breaker_enabled', 'true', 'Auto-skip if slow'),
        ('production_safe', 'circuit_breaker_threshold_ms', '800', 'Stricter circuit breaker (800ms vs 1000ms)'),
        ('production_safe', 'enable_locks', 'false', 'Disable lock collection (reduce overhead)'),
        ('production_safe', 'enable_progress', 'false', 'Disable progress tracking'),
        ('production_safe', 'snapshot_based_collection', 'true', 'Snapshot-based collection'),
        ('production_safe', 'lock_timeout_ms', '50', 'Faster lock timeout (50ms vs 100ms)'),
        ('production_safe', 'retention_snapshots_days', '30', 'Keep 30 days'),
        ('production_safe', 'aggregate_retention_days', '7', 'Keep 7 days'),
        ('production_safe', 'table_stats_enabled', 'true', 'Collect table statistics'),
        ('production_safe', 'index_stats_enabled', 'true', 'Collect index statistics'),
        ('production_safe', 'config_snapshots_enabled', 'true', 'Collect config snapshots'),
        ('production_safe', 'db_role_config_snapshots_enabled', 'true', 'Collect database/role config overrides'),
        ('production_safe', 'retention_samples_days', '7', 'Keep raw samples 7 days'),
        ('production_safe', 'retention_statements_days', '30', 'Keep statement snapshots 30 days'),
        ('production_safe', 'retention_collection_stats_days', '30', 'Keep collection stats 30 days'),
        ('production_safe', 'section_timeout_ms', '200', 'Faster per-section timeout'),
        ('production_safe', 'statement_timeout_ms', '800', 'Faster statement timeout'),
        ('production_safe', 'work_mem_kb', '1024', 'Lower work_mem to reduce overhead'),
        ('production_safe', 'skip_locks_threshold', '30', 'More aggressive lock skip'),
        ('production_safe', 'skip_activity_conn_threshold', '50', 'More aggressive activity skip'),
        ('production_safe', 'load_throttle_xact_threshold', '500', 'Lower xact threshold'),
        ('production_safe', 'load_throttle_blk_threshold', '5000', 'Lower I/O threshold'),
        ('production_safe', 'statements_interval_minutes', '30', 'Less frequent statement collection'),
        ('production_safe', 'statements_min_calls', '5', 'Only queries with >= 5 calls'),
        ('production_safe', 'table_stats_top_n', '30', 'Track fewer tables'),
        ('production_safe', 'collection_jitter_enabled', 'true', 'Add jitter to prevent thundering herd'),
        ('production_safe', 'auto_mode_enabled', 'true', 'Enable automatic mode switching'),
        ('production_safe', 'auto_mode_connections_threshold', '50', 'Earlier emergency mode'),
        ('development', 'sample_interval_seconds', '180', 'Sample every 3 minutes'),
        ('development', 'adaptive_sampling', 'false', 'Always collect (never skip when idle)'),
        ('development', 'load_shedding_enabled', 'true', 'Skip during high load'),
        ('development', 'load_throttle_enabled', 'true', 'Skip during I/O pressure'),
        ('development', 'circuit_breaker_enabled', 'true', 'Auto-skip if slow'),
        ('development', 'enable_locks', 'true', 'Collect lock data'),
        ('development', 'enable_progress', 'true', 'Collect progress data'),
        ('development', 'snapshot_based_collection', 'true', 'Snapshot-based collection'),
        ('development', 'retention_snapshots_days', '7', 'Keep 7 days (less than production)'),
        ('development', 'aggregate_retention_days', '3', 'Keep 3 days'),
        ('development', 'table_stats_enabled', 'true', 'Collect table statistics'),
        ('development', 'index_stats_enabled', 'true', 'Collect index statistics'),
        ('development', 'config_snapshots_enabled', 'true', 'Collect config snapshots'),
        ('development', 'db_role_config_snapshots_enabled', 'true', 'Collect database/role config overrides'),
        ('development', 'retention_samples_days', '3', 'Keep raw samples 3 days'),
        ('development', 'retention_statements_days', '7', 'Keep statement snapshots 7 days'),
        ('development', 'retention_collection_stats_days', '7', 'Keep collection stats 7 days'),
        ('development', 'section_timeout_ms', '250', 'Standard per-section timeout'),
        ('development', 'statement_timeout_ms', '1000', 'Standard statement timeout'),
        ('development', 'work_mem_kb', '2048', 'Standard work_mem'),
        ('development', 'skip_locks_threshold', '50', 'Standard lock skip threshold'),
        ('development', 'skip_activity_conn_threshold', '100', 'Standard activity skip threshold'),
        ('development', 'load_throttle_xact_threshold', '1000', 'Standard xact threshold'),
        ('development', 'load_throttle_blk_threshold', '10000', 'Standard I/O threshold'),
        ('development', 'statements_interval_minutes', '15', 'Collect statements every 15 minutes'),
        ('development', 'statements_min_calls', '1', 'Include all queries'),
        ('development', 'table_stats_top_n', '50', 'Track top 50 tables'),
        ('development', 'collection_jitter_enabled', 'true', 'Add jitter'),
        ('development', 'auto_mode_enabled', 'true', 'Enable automatic mode switching'),
        ('development', 'auto_mode_connections_threshold', '60', 'Standard emergency threshold'),
        ('troubleshooting', 'sample_interval_seconds', '60', 'Sample every minute (detailed data)'),
        ('troubleshooting', 'adaptive_sampling', 'false', 'Never skip - always collect'),
        ('troubleshooting', 'load_shedding_enabled', 'false', 'Collect even under load'),
        ('troubleshooting', 'load_throttle_enabled', 'false', 'Collect even during I/O pressure'),
        ('troubleshooting', 'circuit_breaker_enabled', 'true', 'Keep circuit breaker enabled'),
        ('troubleshooting', 'circuit_breaker_threshold_ms', '2000', 'More lenient threshold - 2 seconds'),
        ('troubleshooting', 'enable_locks', 'true', 'Collect all lock data'),
        ('troubleshooting', 'enable_progress', 'true', 'Collect all progress data'),
        ('troubleshooting', 'snapshot_based_collection', 'true', 'Snapshot-based collection'),
        ('troubleshooting', 'statements_top_n', '50', 'Collect top 50 queries (vs 20)'),
        ('troubleshooting', 'retention_snapshots_days', '7', 'Keep 7 days'),
        ('troubleshooting', 'aggregate_retention_days', '3', 'Keep 3 days'),
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
        ('troubleshooting', 'retention_samples_days', '7', 'Keep raw samples 7 days'),
        ('troubleshooting', 'retention_statements_days', '7', 'Keep statement snapshots 7 days'),
        ('troubleshooting', 'retention_collection_stats_days', '7', 'Keep collection stats 7 days'),
        ('troubleshooting', 'section_timeout_ms', '500', 'Longer per-section timeout for detailed collection'),
        ('troubleshooting', 'statement_timeout_ms', '2000', 'Longer statement timeout'),
        ('troubleshooting', 'work_mem_kb', '4096', 'More work_mem for complex queries'),
        ('troubleshooting', 'skip_locks_threshold', '100', 'Higher threshold - collect more'),
        ('troubleshooting', 'skip_activity_conn_threshold', '200', 'Higher threshold - collect more'),
        ('troubleshooting', 'load_throttle_xact_threshold', '2000', 'Higher threshold - collect under load'),
        ('troubleshooting', 'load_throttle_blk_threshold', '20000', 'Higher threshold - collect under I/O'),
        ('troubleshooting', 'statements_interval_minutes', '5', 'More frequent statement collection'),
        ('troubleshooting', 'statements_min_calls', '1', 'Include all queries'),
        ('troubleshooting', 'table_stats_top_n', '100', 'Track more tables'),
        ('troubleshooting', 'collection_jitter_enabled', 'false', 'No jitter for consistent timing'),
        ('troubleshooting', 'auto_mode_enabled', 'false', 'Stay in normal mode for debugging'),
        ('troubleshooting', 'auto_mode_connections_threshold', '80', 'Higher emergency threshold'),
        ('minimal_overhead', 'sample_interval_seconds', '300', 'Sample every 5 minutes'),
        ('minimal_overhead', 'adaptive_sampling', 'true', 'Skip when idle'),
        ('minimal_overhead', 'adaptive_sampling_idle_threshold', '10', 'Higher idle threshold (10 vs 5)'),
        ('minimal_overhead', 'load_shedding_enabled', 'true', 'Skip during high load'),
        ('minimal_overhead', 'load_shedding_active_pct', '50', 'Very aggressive (50%)'),
        ('minimal_overhead', 'load_throttle_enabled', 'true', 'Skip during I/O pressure'),
        ('minimal_overhead', 'circuit_breaker_enabled', 'true', 'Auto-skip if slow'),
        ('minimal_overhead', 'circuit_breaker_threshold_ms', '500', 'Very strict (500ms)'),
        ('minimal_overhead', 'enable_locks', 'false', 'Disable locks'),
        ('minimal_overhead', 'enable_progress', 'false', 'Disable progress'),
        ('minimal_overhead', 'snapshot_based_collection', 'true', 'Snapshot-based collection'),
        ('minimal_overhead', 'statements_enabled', 'false', 'Disable pg_stat_statements collection'),
        ('minimal_overhead', 'retention_snapshots_days', '7', 'Keep 7 days'),
        ('minimal_overhead', 'aggregate_retention_days', '3', 'Keep 3 days'),
        ('minimal_overhead', 'table_stats_enabled', 'false', 'Disable table statistics (reduce overhead)'),
        ('minimal_overhead', 'index_stats_enabled', 'false', 'Disable index statistics (reduce overhead)'),
        ('minimal_overhead', 'config_snapshots_enabled', 'true', 'Collect config snapshots (low overhead)'),
        ('minimal_overhead', 'db_role_config_snapshots_enabled', 'true', 'Collect database/role config overrides'),
        ('minimal_overhead', 'retention_samples_days', '3', 'Keep raw samples 3 days'),
        ('minimal_overhead', 'retention_statements_days', '7', 'Keep statement snapshots 7 days'),
        ('minimal_overhead', 'retention_collection_stats_days', '7', 'Keep collection stats 7 days'),
        ('minimal_overhead', 'section_timeout_ms', '100', 'Very fast per-section timeout'),
        ('minimal_overhead', 'statement_timeout_ms', '500', 'Very fast statement timeout'),
        ('minimal_overhead', 'work_mem_kb', '1024', 'Minimal work_mem'),
        ('minimal_overhead', 'skip_locks_threshold', '20', 'Very aggressive lock skip'),
        ('minimal_overhead', 'skip_activity_conn_threshold', '30', 'Very aggressive activity skip'),
        ('minimal_overhead', 'load_throttle_xact_threshold', '300', 'Very low xact threshold'),
        ('minimal_overhead', 'load_throttle_blk_threshold', '3000', 'Very low I/O threshold'),
        ('minimal_overhead', 'statements_interval_minutes', '30', 'Infrequent statement collection'),
        ('minimal_overhead', 'statements_min_calls', '10', 'Only hot queries'),
        ('minimal_overhead', 'table_stats_top_n', '20', 'Track fewer tables'),
        ('minimal_overhead', 'collection_jitter_enabled', 'false', 'No jitter (minimize complexity)'),
        ('minimal_overhead', 'auto_mode_enabled', 'true', 'Enable automatic mode switching'),
        ('minimal_overhead', 'auto_mode_connections_threshold', '40', 'Very early emergency mode')
    ) AS t(profile, key, value, description);
$$;

-- Non-profile settings (system defaults that profiles don't manage)
INSERT INTO flight_recorder.config (key, value) VALUES
    ('schema_version', '2.23'),
    ('mode', 'normal'),
    ('statements_enabled', 'auto'),
    ('statements_top_n', '20'),
    ('circuit_breaker_threshold_ms', '1000'),
    ('circuit_breaker_window_minutes', '15'),
    ('lock_timeout_ms', '100'),
    ('schema_size_warning_mb', '5000'),
    ('schema_size_critical_mb', '10000'),
    ('schema_size_check_enabled', 'true'),
    ('auto_mode_trips_threshold', '1'),
    ('alert_enabled', 'false'),
    ('alert_circuit_breaker_count', '5'),
    ('alert_schema_size_mb', '8000'),
    ('lock_timeout_strategy', 'fail_fast'),
    ('check_ddl_before_collection', 'true'),
    ('check_replica_lag', 'true'),
    ('replica_lag_threshold', '10 seconds'),
    ('check_checkpoint_backup', 'true'),
    ('check_pss_conflicts', 'true'),
    ('schema_size_use_percentage', 'true'),
    ('schema_size_percentage', '5.0'),
    ('schema_size_min_mb', '1000'),
    ('schema_size_max_mb', '10000'),
    ('adaptive_sampling_idle_threshold', '5'),
    ('load_shedding_active_pct', '70'),
    ('collection_jitter_max_seconds', '10'),
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
    ('ring_buffer_slots', '120'),
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
    ('regression_detection_metric', 'buffers')
ON CONFLICT (key) DO NOTHING;

-- Profile-managed defaults (from 'default' profile)
INSERT INTO flight_recorder.config (key, value)
SELECT ps.key, ps.value
FROM flight_recorder._profile_settings() ps
WHERE ps.profile = 'default'
ON CONFLICT (key) DO NOTHING;

CREATE UNLOGGED TABLE IF NOT EXISTS flight_recorder.collection_stats (
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
    ON flight_recorder.collection_stats(collection_type, started_at DESC);

-- Checks if circuit breaker conditions are met (excessive errors or collection failures)
-- Returns TRUE if circuit breaker is tripped and collection should be skipped
CREATE OR REPLACE FUNCTION flight_recorder._check_circuit_breaker(p_collection_type TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_threshold_ms INTEGER;
    v_avg_duration_ms NUMERIC;
    v_window_minutes INTEGER;
BEGIN
    v_enabled := COALESCE(
        flight_recorder._get_config('circuit_breaker_enabled', 'true')::boolean,
        true
    );
    IF NOT v_enabled THEN
        RETURN false;
    END IF;
    v_threshold_ms := COALESCE(
        flight_recorder._get_config('circuit_breaker_threshold_ms', '1000')::integer,
        1000
    );
    v_window_minutes := COALESCE(
        flight_recorder._get_config('circuit_breaker_window_minutes', '15')::integer,
        15
    );
    SELECT avg(duration_ms) INTO v_avg_duration_ms
    FROM (
        SELECT duration_ms
        FROM flight_recorder.collection_stats
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
CREATE OR REPLACE FUNCTION flight_recorder._record_collection_start(
    p_collection_type TEXT,
    p_sections_total INTEGER DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE sql AS $$
    INSERT INTO flight_recorder.collection_stats (collection_type, started_at, sections_total)
    VALUES (p_collection_type, now(), p_sections_total)
    RETURNING id
$$;

-- Records collection completion with timing and success/failure status
-- Updates collection_stats with end time, duration, and error details if applicable
CREATE OR REPLACE FUNCTION flight_recorder._record_collection_end(
    p_stat_id INTEGER,
    p_success BOOLEAN,
    p_error_message TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE sql AS $$
    UPDATE flight_recorder.collection_stats
    SET completed_at = now(),
        duration_ms = EXTRACT(EPOCH FROM (now() - started_at)) * 1000,
        success = p_success,
        error_message = p_error_message
    WHERE id = p_stat_id
$$;

-- Records a skipped collection event with the reason for skipping
CREATE OR REPLACE FUNCTION flight_recorder._record_collection_skip(
    p_collection_type TEXT,
    p_reason TEXT
)
RETURNS VOID
LANGUAGE sql AS $$
    INSERT INTO flight_recorder.collection_stats (
        collection_type, started_at, completed_at, skipped, skipped_reason
    )
    VALUES (p_collection_type, now(), now(), true, p_reason)
$$;

-- Increments the sections_succeeded counter to record successful section completion
CREATE OR REPLACE FUNCTION flight_recorder._record_section_success(p_stat_id INTEGER)
RETURNS VOID
LANGUAGE sql AS $$
    UPDATE flight_recorder.collection_stats
    SET sections_succeeded = COALESCE(sections_succeeded, 0) + 1
    WHERE id = p_stat_id
$$;

-- Retrieves configuration values by key from the config table with optional fallback
-- Returns the provided default value if the key does not exist
CREATE OR REPLACE FUNCTION flight_recorder._get_config(p_key TEXT, p_default TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT value FROM flight_recorder.config WHERE key = p_key),
        p_default
    )
$$;

-- Returns the configured ring buffer slot count, clamped to valid range (72-2880)
-- Default is 120 slots for backwards compatibility
CREATE OR REPLACE FUNCTION flight_recorder._get_ring_buffer_slots()
RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT GREATEST(72, LEAST(2880,
        COALESCE(flight_recorder._get_config('ring_buffer_slots', '120')::integer, 120)
    ))
$$;
COMMENT ON FUNCTION flight_recorder._get_ring_buffer_slots() IS 'Returns configured ring buffer slot count (72-2880 range). Default 120 for backwards compatibility. Use ring_buffer_slots config to change.';

-- Sets statement timeout for section recording based on configuration, defaulting to 250ms
CREATE OR REPLACE FUNCTION flight_recorder._set_section_timeout()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_timeout_ms INTEGER;
BEGIN
    v_timeout_ms := COALESCE(
        flight_recorder._get_config('section_timeout_ms', '250')::integer,
        250
    );
    PERFORM set_config('statement_timeout', v_timeout_ms::text, true);
END;
$$;

-- Evaluates system metrics (active connections, circuit breaker activity) and automatically
-- adjusts the flight recorder mode between normal, light, and emergency states
CREATE OR REPLACE FUNCTION flight_recorder._check_and_adjust_mode()
RETURNS TABLE(
    previous_mode TEXT,
    new_mode TEXT,
    reason TEXT,
    action_taken BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_current_mode TEXT;
    v_connections_threshold INTEGER;
    v_trips_threshold INTEGER;
    v_active_connections INTEGER;
    v_recent_trips INTEGER;
    v_max_connections INTEGER;
    v_connection_pct NUMERIC;
    v_suggested_mode TEXT;
    v_reason TEXT;
BEGIN
    v_enabled := COALESCE(
        flight_recorder._get_config('auto_mode_enabled', 'false')::boolean,
        false
    );
    IF NOT v_enabled THEN
        RETURN;
    END IF;
    v_current_mode := flight_recorder._get_config('mode', 'normal');
    v_connections_threshold := COALESCE(
        flight_recorder._get_config('auto_mode_connections_threshold', '60')::integer,
        60
    );
    v_trips_threshold := COALESCE(
        flight_recorder._get_config('auto_mode_trips_threshold', '1')::integer,
        1
    );
    SELECT count(*) FILTER (WHERE state = 'active')
    INTO v_active_connections
    FROM pg_stat_activity
    WHERE backend_type = 'client backend';
    SELECT setting::integer
    INTO v_max_connections
    FROM pg_settings
    WHERE name = 'max_connections';
    v_connection_pct := (v_active_connections::numeric / NULLIF(v_max_connections, 0)) * 100;
    SELECT count(*)
    INTO v_recent_trips
    FROM flight_recorder.collection_stats
    WHERE skipped = true
      AND started_at > now() - interval '10 minutes'
      AND skipped_reason LIKE '%Circuit breaker%';
    v_suggested_mode := v_current_mode;
    IF v_recent_trips >= v_trips_threshold THEN
        v_suggested_mode := 'emergency';
        v_reason := format('Circuit breaker tripped %s times in last 10 minutes (threshold: %s)',
                          v_recent_trips, v_trips_threshold);
    ELSIF v_connection_pct >= v_connections_threshold THEN
        IF v_current_mode = 'normal' THEN
            v_suggested_mode := 'light';
            v_reason := format('Active connections at %s%% of max (threshold: %s%%)',
                              round(v_connection_pct, 1)::text, v_connections_threshold);
        END IF;
    ELSE
        IF v_current_mode = 'emergency' AND v_recent_trips = 0 THEN
            v_suggested_mode := 'light';
            v_reason := 'System recovered: no recent circuit breaker trips';
        ELSIF v_current_mode = 'light' AND v_connection_pct < (v_connections_threshold * 0.7) THEN
            v_suggested_mode := 'normal';
            v_reason := format('System load reduced: connections at %s%% (threshold: %s%%)',
                              round(v_connection_pct, 1)::text, v_connections_threshold);
        END IF;
    END IF;
    IF v_suggested_mode != v_current_mode THEN
        PERFORM flight_recorder.set_mode(v_suggested_mode);
        RAISE NOTICE 'pg-flight-recorder: Auto-mode switched from % to %: %',
                     v_current_mode, v_suggested_mode, v_reason;
        RETURN QUERY SELECT v_current_mode, v_suggested_mode, v_reason, true;
    END IF;
    RETURN;
END;
$$;

-- Validates flight_recorder configuration parameters and system health
-- Returns diagnostic checks with status levels (OK, WARNING, CRITICAL) for configuration values, thresholds, and recent operational errors
CREATE OR REPLACE FUNCTION flight_recorder.validate_config()
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
    v_section_timeout := flight_recorder._get_config('section_timeout_ms', '250')::integer;
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
        flight_recorder._get_config('circuit_breaker_enabled', 'true')::boolean,
        true
    );
    RETURN QUERY SELECT
        'circuit_breaker_enabled'::text,
        CASE WHEN v_circuit_breaker_enabled THEN 'OK' ELSE 'CRITICAL' END::text,
        format('Current: %s. Circuit breaker provides automatic protection under load',
               v_circuit_breaker_enabled);
    v_lock_timeout := flight_recorder._get_config('lock_timeout_ms', '100')::integer;
    RETURN QUERY SELECT
        'lock_timeout_ms'::text,
        CASE
            WHEN v_lock_timeout > 500 THEN 'WARNING'
            WHEN v_lock_timeout > 1000 THEN 'CRITICAL'
            ELSE 'OK'
        END::text,
        format('Current: %s ms. Recommended: <= 100ms to fail fast on catalog lock contention',
               v_lock_timeout);
    SELECT schema_size_mb INTO v_schema_size_mb
    FROM flight_recorder._check_schema_size();
    RETURN QUERY SELECT
        'schema_size'::text,
        CASE
            WHEN v_schema_size_mb > 10000 THEN 'CRITICAL'
            WHEN v_schema_size_mb > 5000 THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('flight_recorder schema: %s MB (warning: 5000 MB, critical: 10000 MB, auto-disable at critical)',
               round(v_schema_size_mb, 0));
    RETURN QUERY SELECT
        'skip_thresholds'::text,
        CASE
            WHEN flight_recorder._get_config('skip_activity_conn_threshold')::integer > 200
                OR flight_recorder._get_config('skip_locks_threshold')::integer > 100
            THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('Activity threshold: %s, Locks threshold: %s. Recommended: 100/50 for early protection',
               flight_recorder._get_config('skip_activity_conn_threshold'),
               flight_recorder._get_config('skip_locks_threshold'));
    DECLARE
        v_recent_failures INTEGER;
    BEGIN
        SELECT count(*) INTO v_recent_failures
        FROM flight_recorder.collection_stats
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
        FROM flight_recorder.collection_stats
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

-- Validates ring buffer configuration and returns diagnostic checks
-- Checks retention, batching efficiency, CPU overhead, and memory usage
CREATE OR REPLACE FUNCTION flight_recorder.validate_ring_configuration()
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
    v_slots := flight_recorder._get_ring_buffer_slots();
    v_sample_interval := COALESCE(
        flight_recorder._get_config('sample_interval_seconds', '180')::integer,
        180
    );
    v_archive_interval := COALESCE(
        flight_recorder._get_config('archive_sample_frequency_minutes', '15')::integer,
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
            WHEN v_retention_hours < 2 THEN 'ERROR'
            WHEN v_retention_hours < 4 THEN 'WARNING'
            ELSE 'OK'
        END::text,
        format('%s hours retention (%s slots × %ss interval)',
               ROUND(v_retention_hours, 1), v_slots, v_sample_interval)::text,
        CASE
            WHEN v_retention_hours < 4 THEN
                format('Consider increasing ring_buffer_slots to %s for 6-hour retention',
                    CEIL((6 * 3600.0 / v_sample_interval))::integer)
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
COMMENT ON FUNCTION flight_recorder.validate_ring_configuration() IS 'Validates ring buffer configuration and returns diagnostic checks for retention, batching efficiency, CPU overhead, and memory usage.';

-- Check if the pg_stat_statements extension is installed
-- Returns TRUE if available, FALSE otherwise
CREATE OR REPLACE FUNCTION flight_recorder._has_pg_stat_statements()
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements'
    )
$$;

-- Monitors pg_stat_statements table health by checking current statement count against configured max capacity
-- Returns utilization percentage and status (OK, WARNING, HIGH_CHURN) to detect statement table churn
CREATE OR REPLACE FUNCTION flight_recorder._check_statements_health()
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
    IF NOT flight_recorder._has_pg_stat_statements() THEN
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

-- Monitor flight_recorder schema size and automatically manage collection state (cleanup, disable, re-enable) to prevent unbounded growth
-- Returns current size, thresholds, status, and actions taken based on configurable warning/critical thresholds
CREATE OR REPLACE FUNCTION flight_recorder._check_schema_size()
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
        flight_recorder._get_config('schema_size_check_enabled', 'true')::boolean,
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
            flight_recorder._get_config('schema_size_use_percentage', 'true')::boolean,
            true
        );
        IF v_use_percentage THEN
            SELECT round((sum(relpages::bigint * current_setting('block_size')::bigint) / 1024.0 / 1024.0), 2)
            INTO v_db_size_mb
            FROM pg_class
            WHERE relkind IN ('r', 't', 'i', 'm')
              AND relpages > 0;
            v_percentage := COALESCE(
                flight_recorder._get_config('schema_size_percentage', '5.0')::numeric,
                5.0
            );
            v_min_mb := COALESCE(
                flight_recorder._get_config('schema_size_min_mb', '1000')::integer,
                1000
            );
            v_max_mb := COALESCE(
                flight_recorder._get_config('schema_size_max_mb', '10000')::integer,
                10000
            );
            v_critical_mb := GREATEST(v_min_mb, LEAST(v_max_mb, (v_db_size_mb * v_percentage / 100.0)::integer));
            v_warning_mb := (v_critical_mb * 0.5)::integer;
        ELSE
            v_warning_mb := COALESCE(
                flight_recorder._get_config('schema_size_warning_mb', '5000')::integer,
                5000
            );
            v_critical_mb := COALESCE(
                flight_recorder._get_config('schema_size_critical_mb', '10000')::integer,
                10000
            );
        END IF;
    END;
    SELECT COALESCE(sum(pg_total_relation_size(c.oid)), 0)
    INTO v_size_bytes
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'flight_recorder'
      AND c.relkind IN ('r', 'i', 't');
    v_size_mb := round(v_size_bytes / 1024.0 / 1024.0, 2);
    SELECT EXISTS (
        SELECT 1 FROM cron.job
        WHERE jobname LIKE 'flight_recorder%'
          AND active = true
    ) INTO v_enabled;
    IF v_size_mb >= v_critical_mb AND v_enabled THEN
        BEGIN
            PERFORM flight_recorder.cleanup('3 days'::interval);
            v_cleanup_performed := true;
            v_action := 'Aggressive cleanup (3 days retention)';
            SELECT COALESCE(sum(pg_total_relation_size(c.oid)), 0)
            INTO v_size_bytes
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'flight_recorder'
              AND c.relkind IN ('r', 'i', 't');
            v_size_mb := round(v_size_bytes / 1024.0 / 1024.0, 2);
            IF v_size_mb >= v_critical_mb THEN
                PERFORM flight_recorder.disable();
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
            PERFORM flight_recorder.enable();
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
                PERFORM flight_recorder.cleanup('5 days'::interval);
                v_action := 'Proactive cleanup at 5GB (5 days retention)';
                SELECT COALESCE(sum(pg_total_relation_size(c.oid)), 0)
                INTO v_size_bytes
                FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'flight_recorder'
                  AND c.relkind IN ('r', 'i', 't');
                v_size_mb := round(v_size_bytes / 1024.0 / 1024.0, 2);
                v_action := v_action || format(' (reduced to %s MB)', v_size_mb);
            EXCEPTION WHEN OTHERS THEN
                v_action := format('Attempted cleanup but failed: %s', SQLERRM);
            END;
        END IF;
        RAISE WARNING 'pg-flight-recorder: Schema size (% MB) in warning range (% - % MB). %',
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

-- Checks for exclusive DDL locks on critical system catalog tables
-- Returns true if locks detected to indicate potential lock contention
CREATE OR REPLACE FUNCTION flight_recorder._check_catalog_ddl_locks()
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    v_ddl_lock_exists BOOLEAN;
BEGIN
    SELECT EXISTS(
        SELECT 1
        FROM pg_locks l
        JOIN pg_class c ON c.oid = l.relation
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE l.mode = 'AccessExclusiveLock'
          AND l.granted = true
          AND n.nspname IN ('pg_catalog', 'information_schema')
          AND c.relname IN (
              'pg_stat_activity',
              'pg_locks',
              'pg_stat_database',
              'pg_stat_statements'
          )
    ) INTO v_ddl_lock_exists;
    RETURN v_ddl_lock_exists;
EXCEPTION WHEN OTHERS THEN
    RETURN false;
END;
$$;
COMMENT ON FUNCTION flight_recorder._check_catalog_ddl_locks() IS 'Pre-check for DDL locks on system catalogs to avoid lock contention';


-- Evaluates replica lag, active checkpoints, and backups to determine collection eligibility
-- Returns skip reason message or NULL if collection can proceed
CREATE OR REPLACE FUNCTION flight_recorder._should_skip_collection()
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_replica_lag_check BOOLEAN;
    v_checkpoint_check BOOLEAN;
    v_replica_lag INTERVAL;
    v_replica_lag_threshold INTERVAL;
    v_checkpoint_in_progress BOOLEAN;
    v_backup_running BOOLEAN;
BEGIN
    v_replica_lag_check := COALESCE(
        flight_recorder._get_config('check_replica_lag', 'true')::boolean,
        true
    );
    IF v_replica_lag_check AND pg_is_in_recovery() THEN
        v_replica_lag_threshold := COALESCE(
            flight_recorder._get_config('replica_lag_threshold', '10 seconds')::interval,
            '10 seconds'::interval
        );
        BEGIN
            SELECT age(now(), pg_last_xact_replay_timestamp())
            INTO v_replica_lag;
            IF v_replica_lag > v_replica_lag_threshold THEN
                RETURN format('Replica lag %s exceeds threshold %s',
                    v_replica_lag::text, v_replica_lag_threshold::text);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END IF;
    v_checkpoint_check := COALESCE(
        flight_recorder._get_config('check_checkpoint_backup', 'true')::boolean,
        true
    );
    IF v_checkpoint_check THEN
        BEGIN
            SELECT EXISTS(
                SELECT 1 FROM pg_stat_bgwriter
                WHERE checkpoints_req > 0
                  AND stats_reset > now() - interval '1 minute'
            ) INTO v_checkpoint_in_progress;
            IF v_checkpoint_in_progress THEN
                RETURN 'Active checkpoint detected (recent requested checkpoint)';
            END IF;
            SELECT EXISTS(
                SELECT 1 FROM pg_stat_activity
                WHERE (backend_type = 'walsender' AND state = 'active')
                   OR query ILIKE '%pg_dump%'
                   OR query ILIKE '%pg_basebackup%'
                   OR application_name ILIKE '%backup%'
            ) INTO v_backup_running;
            IF v_backup_running THEN
                RETURN 'Backup in progress (pg_dump/pg_basebackup/walsender detected)';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END IF;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;
COMMENT ON FUNCTION flight_recorder._should_skip_collection() IS 'Pre-flight checks for replication lag, checkpoints, and backups';


-- Sampled activity: Collect performance samples (wait events, active sessions, locks) into ring buffers
-- Applies load shedding, circuit breaker, and pre-flight checks before collection
CREATE OR REPLACE FUNCTION flight_recorder.sample()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql AS $$
DECLARE
    v_captured_at TIMESTAMPTZ := now();
    v_epoch BIGINT := extract(epoch from v_captured_at)::bigint;
    v_slot_id INTEGER;
    v_sample_interval_seconds INTEGER;
    v_enable_locks BOOLEAN;
    v_snapshot_based BOOLEAN;
    v_blocked_count INTEGER;
    v_skip_locks_threshold INTEGER;
    v_stat_id INTEGER;
    v_should_skip BOOLEAN;
BEGIN
    v_sample_interval_seconds := COALESCE(
        flight_recorder._get_config('sample_interval_seconds', '60')::integer,
        60
    );
    IF v_sample_interval_seconds < 60 THEN
        v_sample_interval_seconds := 60;
    ELSIF v_sample_interval_seconds > 3600 THEN
        v_sample_interval_seconds := 3600;
    END IF;
    v_slot_id := (v_epoch / v_sample_interval_seconds) % flight_recorder._get_ring_buffer_slots();
    DECLARE
        v_jitter_enabled BOOLEAN;
        v_jitter_max INTEGER;
        v_jitter_seconds NUMERIC;
    BEGIN
        v_jitter_enabled := COALESCE(
            flight_recorder._get_config('collection_jitter_enabled', 'true')::boolean,
            true
        );
        v_jitter_max := COALESCE(
            flight_recorder._get_config('collection_jitter_max_seconds', '10')::integer,
            10
        );
        IF v_jitter_enabled AND v_jitter_max > 0 THEN
            v_jitter_seconds := random() * v_jitter_max;
            PERFORM pg_sleep(v_jitter_seconds);
        END IF;
    END;
    PERFORM flight_recorder._check_and_adjust_mode();
    v_should_skip := flight_recorder._check_circuit_breaker('sample');
    IF v_should_skip THEN
        PERFORM flight_recorder._record_collection_skip('sample', 'Circuit breaker tripped - last run exceeded threshold');
        RAISE NOTICE 'pg-flight-recorder: Skipping sample collection due to circuit breaker';
        RETURN v_captured_at;
    END IF;
    DECLARE
        v_skip_reason TEXT;
    BEGIN
        v_skip_reason := flight_recorder._should_skip_collection();
        IF v_skip_reason IS NOT NULL THEN
            PERFORM flight_recorder._record_collection_skip('sample', v_skip_reason);
            RAISE NOTICE 'pg-flight-recorder: Skipping sample - %', v_skip_reason;
            RETURN v_captured_at;
        END IF;
    END;
    DECLARE
        v_running_count INTEGER;
        v_running_pid INTEGER;
    BEGIN
        SELECT count(*), min(pid) INTO v_running_count, v_running_pid
        FROM pg_stat_activity
        WHERE query ~ 'SELECT\s+flight_recorder\.sample\(\)'
          AND state = 'active'
          AND pid != pg_backend_pid()
          AND backend_type = 'client backend';
        IF v_running_count > 0 THEN
            PERFORM flight_recorder._record_collection_skip('sample',
                format('Job deduplication: %s sample job(s) already running (PID: %s)',
                       v_running_count, v_running_pid));
            RAISE NOTICE 'pg-flight-recorder: Skipping sample - another job already running (PID: %)', v_running_pid;
            RETURN v_captured_at;
        END IF;
    END;
    v_stat_id := flight_recorder._record_collection_start('sample', 3);
    DECLARE
        v_check_ddl BOOLEAN;
        v_lock_strategy TEXT;
        v_ddl_lock_exists BOOLEAN;
        v_lock_timeout_ms INTEGER;
    BEGIN
        v_check_ddl := COALESCE(
            flight_recorder._get_config('check_ddl_before_collection', 'true')::boolean,
            true
        );
        v_lock_strategy := COALESCE(
            flight_recorder._get_config('lock_timeout_strategy', 'fail_fast'),
            'fail_fast'
        );
        IF v_check_ddl AND v_lock_strategy = 'skip_if_locked' THEN
            v_ddl_lock_exists := flight_recorder._check_catalog_ddl_locks();
            IF v_ddl_lock_exists THEN
                PERFORM flight_recorder._record_collection_skip('sample',
                    'DDL lock detected on system catalogs (skip_if_locked strategy)');
                RAISE NOTICE 'pg-flight-recorder: Skipping sample - DDL lock detected on catalogs';
                RETURN v_captured_at;
            END IF;
        END IF;
        v_lock_timeout_ms := CASE v_lock_strategy
            WHEN 'skip_if_locked' THEN 0
            WHEN 'patient' THEN 500
            ELSE 100
        END;
        PERFORM set_config('lock_timeout', v_lock_timeout_ms::text, true);
    END;
    PERFORM set_config('work_mem',
        COALESCE(flight_recorder._get_config('work_mem_kb', '2048'), '2048') || 'kB',
        true);
    DECLARE
        v_load_shedding_enabled BOOLEAN;
        v_load_threshold_pct INTEGER;
        v_max_connections INTEGER;
        v_active_pct NUMERIC;
        v_adaptive_sampling BOOLEAN;
        v_idle_threshold INTEGER;
        v_active_count INTEGER;
        v_load_throttle_enabled BOOLEAN;
        v_xact_threshold INTEGER;
        v_blk_threshold INTEGER;
        v_xact_rate NUMERIC;
        v_blk_rate NUMERIC;
        v_xact_commit BIGINT;
        v_xact_rollback BIGINT;
        v_blks_read BIGINT;
        v_blks_hit BIGINT;
        v_db_uptime INTERVAL;
        v_stmt_utilization NUMERIC;
        v_stmt_status TEXT;
    BEGIN
        v_load_shedding_enabled := COALESCE(
            flight_recorder._get_config('load_shedding_enabled', 'true')::boolean,
            true
        );
        IF v_load_shedding_enabled THEN
            v_load_threshold_pct := COALESCE(
                flight_recorder._get_config('load_shedding_active_pct', '70')::integer,
                70
            );
            SELECT setting::integer INTO v_max_connections
            FROM pg_settings WHERE name = 'max_connections';
            SELECT count(*) INTO v_active_count
            FROM pg_stat_activity
            WHERE state = 'active' AND backend_type = 'client backend';
            v_active_pct := (v_active_count::numeric / NULLIF(v_max_connections, 0)) * 100;
            IF v_active_pct >= v_load_threshold_pct THEN
                PERFORM flight_recorder._record_collection_skip('sample',
                    format('Load shedding: high load (%s active / %s max = %s%% >= %s%% threshold)',
                           v_active_count, v_max_connections, round(v_active_pct, 1), v_load_threshold_pct));
                PERFORM set_config('statement_timeout', '0', true);
                RETURN v_captured_at;
            END IF;
        END IF;
        v_load_throttle_enabled := COALESCE(
                flight_recorder._get_config('load_throttle_enabled', 'true')::boolean,
                true
            );
            IF v_load_throttle_enabled THEN
                v_xact_threshold := COALESCE(
                    flight_recorder._get_config('load_throttle_xact_threshold', '1000')::integer,
                    1000
                );
                v_blk_threshold := COALESCE(
                    flight_recorder._get_config('load_throttle_blk_threshold', '10000')::integer,
                    10000
                );
                SELECT 
                    xact_commit, 
                    xact_rollback,
                    blks_read,
                    blks_hit,
                    now() - stats_reset
                INTO v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit, v_db_uptime
                FROM pg_stat_database
                WHERE datname = current_database();
                IF v_db_uptime > interval '10 seconds' THEN
                    v_xact_rate := (v_xact_commit + v_xact_rollback) / EXTRACT(EPOCH FROM v_db_uptime);
                    v_blk_rate := (v_blks_read + v_blks_hit) / EXTRACT(EPOCH FROM v_db_uptime);
                    IF v_xact_rate > v_xact_threshold THEN
                        PERFORM flight_recorder._record_collection_skip('sample',
                            format('Load throttling: high transaction rate (%s txn/sec > %s threshold)',
                                   round(v_xact_rate, 1), v_xact_threshold));
                        PERFORM set_config('statement_timeout', '0', true);
                        RETURN v_captured_at;
                    END IF;
                    IF v_blk_rate > v_blk_threshold THEN
                        PERFORM flight_recorder._record_collection_skip('sample',
                            format('Load throttling: high I/O rate (%s blocks/sec > %s threshold)',
                                   round(v_blk_rate, 1), v_blk_threshold));
                        PERFORM set_config('statement_timeout', '0', true);
                        RETURN v_captured_at;
                    END IF;
                END IF;
            END IF;
        IF flight_recorder._has_pg_stat_statements() THEN
            SELECT utilization_pct, status
            INTO v_stmt_utilization, v_stmt_status
            FROM flight_recorder._check_statements_health();
            IF v_stmt_status IN ('WARNING', 'HIGH_CHURN') THEN
                PERFORM flight_recorder._record_collection_skip('sample',
                    format('pg_stat_statements overhead: %s utilization (%s%%), skipping to reduce hash table pressure',
                           v_stmt_status, round(v_stmt_utilization, 1)));
                PERFORM set_config('statement_timeout', '0', true);
                RETURN v_captured_at;
            END IF;
        END IF;
        v_adaptive_sampling := COALESCE(
            flight_recorder._get_config('adaptive_sampling', 'false')::boolean,
            false
        );
        IF v_adaptive_sampling THEN
            v_idle_threshold := COALESCE(
                flight_recorder._get_config('adaptive_sampling_idle_threshold', '5')::integer,
                5
            );
            IF v_active_count IS NULL THEN
                SELECT count(*) INTO v_active_count
                FROM pg_stat_activity
                WHERE state = 'active' AND backend_type = 'client backend';
            END IF;
            IF v_active_count < v_idle_threshold THEN
                PERFORM flight_recorder._record_collection_skip('sample',
                    format('Adaptive sampling: system idle (%s active connections < %s threshold)',
                           v_active_count, v_idle_threshold));
                PERFORM set_config('statement_timeout', '0', true);
                RETURN v_captured_at;
            END IF;
        END IF;
    END;
    v_enable_locks := COALESCE(
        flight_recorder._get_config('enable_locks', 'true')::boolean,
        TRUE
    );
    v_snapshot_based := COALESCE(
        flight_recorder._get_config('snapshot_based_collection', 'true')::boolean,
        true
    );
    INSERT INTO flight_recorder.samples_ring (slot_id, captured_at, epoch_seconds)
    VALUES (v_slot_id, v_captured_at, v_epoch)
    ON CONFLICT (slot_id) DO UPDATE SET
        captured_at = EXCLUDED.captured_at,
        epoch_seconds = EXCLUDED.epoch_seconds;
    UPDATE flight_recorder.wait_samples_ring SET
        backend_type = NULL, wait_event_type = NULL, wait_event = NULL, state = NULL, count = NULL
    WHERE slot_id = v_slot_id;
    UPDATE flight_recorder.activity_samples_ring SET
        pid = NULL, usename = NULL, application_name = NULL, backend_type = NULL,
        state = NULL, wait_event_type = NULL, wait_event = NULL,
        backend_start = NULL, xact_start = NULL,
        query_start = NULL, state_change = NULL, query_preview = NULL
    WHERE slot_id = v_slot_id;
    UPDATE flight_recorder.lock_samples_ring SET
        blocked_pid = NULL, blocked_user = NULL, blocked_app = NULL,
        blocked_query_preview = NULL, blocked_duration = NULL, blocking_pid = NULL,
        blocking_user = NULL, blocking_app = NULL, blocking_query_preview = NULL,
        lock_type = NULL, locked_relation_oid = NULL
    WHERE slot_id = v_slot_id;
    IF v_snapshot_based THEN
        CREATE TEMP TABLE IF NOT EXISTS _fr_psa_snapshot (
            LIKE pg_stat_activity
        ) ON COMMIT DROP;
        TRUNCATE _fr_psa_snapshot;
        INSERT INTO _fr_psa_snapshot
        SELECT * FROM pg_stat_activity WHERE pid != pg_backend_pid();
    END IF;
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        IF v_snapshot_based THEN
            INSERT INTO flight_recorder.wait_samples_ring (slot_id, row_num, backend_type, wait_event_type, wait_event, state, count)
            SELECT
                v_slot_id,
                (ROW_NUMBER() OVER () - 1)::integer AS row_num,
                COALESCE(backend_type, 'unknown'),
                COALESCE(wait_event_type, 'Running'),
                COALESCE(wait_event, 'CPU'),
                COALESCE(state, 'unknown'),
                count(*)::integer
            FROM _fr_psa_snapshot
            GROUP BY backend_type, wait_event_type, wait_event, state
            LIMIT 100
            ON CONFLICT (slot_id, row_num) DO UPDATE SET
                backend_type = EXCLUDED.backend_type,
                wait_event_type = EXCLUDED.wait_event_type,
                wait_event = EXCLUDED.wait_event,
                state = EXCLUDED.state,
                count = EXCLUDED.count;
        ELSE
            INSERT INTO flight_recorder.wait_samples_ring (slot_id, row_num, backend_type, wait_event_type, wait_event, state, count)
            SELECT
                v_slot_id,
                (ROW_NUMBER() OVER () - 1)::integer AS row_num,
                COALESCE(backend_type, 'unknown'),
                COALESCE(wait_event_type, 'Running'),
                COALESCE(wait_event, 'CPU'),
                COALESCE(state, 'unknown'),
                count(*)::integer
            FROM pg_stat_activity
            WHERE pid != pg_backend_pid()
            GROUP BY backend_type, wait_event_type, wait_event, state
            LIMIT 100
            ON CONFLICT (slot_id, row_num) DO UPDATE SET
                backend_type = EXCLUDED.backend_type,
                wait_event_type = EXCLUDED.wait_event_type,
                wait_event = EXCLUDED.wait_event,
                state = EXCLUDED.state,
                count = EXCLUDED.count;
        END IF;
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Wait events collection failed: %', SQLERRM;
    END;
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        IF v_snapshot_based THEN
            INSERT INTO flight_recorder.activity_samples_ring (
                slot_id, row_num, pid, usename, application_name, client_addr, backend_type,
                state, wait_event_type, wait_event, backend_start, xact_start,
                query_start, state_change, query_preview
            )
            SELECT
                v_slot_id,
                (ROW_NUMBER() OVER (ORDER BY query_start ASC NULLS LAST) - 1)::integer AS row_num,
                pid,
                usename,
                application_name,
                client_addr,
                backend_type,
                state,
                wait_event_type,
                wait_event,
                backend_start,
                xact_start,
                query_start,
                state_change,
                left(query, 200)
            FROM _fr_psa_snapshot
            WHERE state != 'idle'
            LIMIT 25
            ON CONFLICT (slot_id, row_num) DO UPDATE SET
                pid = EXCLUDED.pid,
                usename = EXCLUDED.usename,
                application_name = EXCLUDED.application_name,
                client_addr = EXCLUDED.client_addr,
                backend_type = EXCLUDED.backend_type,
                state = EXCLUDED.state,
                wait_event_type = EXCLUDED.wait_event_type,
                wait_event = EXCLUDED.wait_event,
                backend_start = EXCLUDED.backend_start,
                xact_start = EXCLUDED.xact_start,
                query_start = EXCLUDED.query_start,
                state_change = EXCLUDED.state_change,
                query_preview = EXCLUDED.query_preview;
        ELSE
            INSERT INTO flight_recorder.activity_samples_ring (
                slot_id, row_num, pid, usename, application_name, client_addr, backend_type,
                state, wait_event_type, wait_event, backend_start, xact_start,
                query_start, state_change, query_preview
            )
            SELECT
                v_slot_id,
                (ROW_NUMBER() OVER (ORDER BY query_start ASC NULLS LAST) - 1)::integer AS row_num,
                pid,
                usename,
                application_name,
                client_addr,
                backend_type,
                state,
                wait_event_type,
                wait_event,
                backend_start,
                xact_start,
                query_start,
                state_change,
                left(query, 200)
            FROM pg_stat_activity
            WHERE state != 'idle' AND pid != pg_backend_pid()
            LIMIT 25
            ON CONFLICT (slot_id, row_num) DO UPDATE SET
                pid = EXCLUDED.pid,
                usename = EXCLUDED.usename,
                application_name = EXCLUDED.application_name,
                client_addr = EXCLUDED.client_addr,
                backend_type = EXCLUDED.backend_type,
                state = EXCLUDED.state,
                wait_event_type = EXCLUDED.wait_event_type,
                wait_event = EXCLUDED.wait_event,
                backend_start = EXCLUDED.backend_start,
                xact_start = EXCLUDED.xact_start,
                query_start = EXCLUDED.query_start,
                state_change = EXCLUDED.state_change,
                query_preview = EXCLUDED.query_preview;
        END IF;
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Activity samples collection failed: %', SQLERRM;
    END;
    IF v_enable_locks THEN
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        DECLARE
            v_blocked_count INTEGER;
            v_skip_locks_threshold INTEGER;
        BEGIN
            v_skip_locks_threshold := COALESCE(
                flight_recorder._get_config('skip_locks_threshold', '50')::integer,
                50
            );
            IF v_snapshot_based THEN
                CREATE TEMP TABLE _fr_blocked_sessions ON COMMIT DROP AS
                SELECT
                    pid,
                    usename,
                    application_name,
                    query,
                    query_start,
                    wait_event_type,
                    wait_event,
                    pg_blocking_pids(pid) AS blocking_pids
                FROM _fr_psa_snapshot
                WHERE cardinality(pg_blocking_pids(pid)) > 0;
            ELSE
                CREATE TEMP TABLE _fr_blocked_sessions ON COMMIT DROP AS
                SELECT
                    pid,
                    usename,
                    application_name,
                    query,
                    query_start,
                    wait_event_type,
                    wait_event,
                    pg_blocking_pids(pid) AS blocking_pids
                FROM pg_stat_activity
                WHERE pid != pg_backend_pid()
                  AND cardinality(pg_blocking_pids(pid)) > 0;
            END IF;
            SELECT count(*) INTO v_blocked_count FROM _fr_blocked_sessions;
            IF v_blocked_count > v_skip_locks_threshold THEN
                RAISE NOTICE 'pg-flight-recorder: Skipping lock collection - % blocked sessions exceeds threshold %',
                    v_blocked_count, v_skip_locks_threshold;
            ELSE
                INSERT INTO flight_recorder.lock_samples_ring (
                    slot_id, row_num, blocked_pid, blocked_user, blocked_app,
                    blocked_query_preview, blocked_duration, blocking_pid, blocking_user,
                    blocking_app, blocking_query_preview, lock_type, locked_relation_oid
                )
                SELECT
                    v_slot_id,
                    (ROW_NUMBER() OVER (ORDER BY bs.pid, blocking_pid) - 1)::integer AS row_num,
                    bs.pid,
                    bs.usename,
                    bs.application_name,
                    left(bs.query, 200),
                    v_captured_at - bs.query_start,
                    blocking_pid,
                    blocking.usename,
                    blocking.application_name,
                    left(blocking.query, 200),
                    CASE
                        WHEN bs.wait_event_type = 'Lock' THEN bs.wait_event
                        ELSE 'unknown'
                    END,
                    CASE
                        WHEN bs.wait_event IN ('relation', 'extend', 'page', 'tuple') THEN
                            (SELECT l.relation
                             FROM pg_locks l
                             WHERE l.pid = bs.pid AND NOT l.granted
                             LIMIT 1)
                        ELSE NULL
                    END
                FROM (
                    SELECT DISTINCT ON (bs.pid, blocking_pid)
                        bs.*,
                        blocking_pid
                    FROM _fr_blocked_sessions bs
                    CROSS JOIN LATERAL unnest(bs.blocking_pids) AS blocking_pid
                    ORDER BY bs.pid, blocking_pid
                    LIMIT 100
                ) bs
                JOIN _fr_psa_snapshot blocking ON blocking.pid = bs.blocking_pid
                ON CONFLICT (slot_id, row_num) DO UPDATE SET
                    blocked_pid = EXCLUDED.blocked_pid,
                    blocked_user = EXCLUDED.blocked_user,
                    blocked_app = EXCLUDED.blocked_app,
                    blocked_query_preview = EXCLUDED.blocked_query_preview,
                    blocked_duration = EXCLUDED.blocked_duration,
                    blocking_pid = EXCLUDED.blocking_pid,
                    blocking_user = EXCLUDED.blocking_user,
                    blocking_app = EXCLUDED.blocking_app,
                    blocking_query_preview = EXCLUDED.blocking_query_preview,
                    lock_type = EXCLUDED.lock_type,
                    locked_relation_oid = EXCLUDED.locked_relation_oid;
            END IF;
        END;
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Lock sampling collection failed: %', SQLERRM;
    END;
    END IF;
    PERFORM flight_recorder._record_collection_end(v_stat_id, true, NULL);
    PERFORM set_config('statement_timeout', '0', true);
    RETURN v_captured_at;
EXCEPTION
    WHEN OTHERS THEN
        PERFORM flight_recorder._record_collection_end(v_stat_id, false, SQLERRM);
        PERFORM set_config('statement_timeout', '0', true);
        RAISE WARNING 'pg-flight-recorder: Sample collection failed: %', SQLERRM;
        RETURN v_captured_at;
END;
$$;
COMMENT ON FUNCTION flight_recorder.sample() IS 'Sampled activity: Collect samples into ring buffer (60s intervals, 3 sections: waits, activity, locks)';


-- Aggregates: Aggregate wait events, lock conflicts, and query activity from ring buffers into durable aggregate tables
CREATE OR REPLACE FUNCTION flight_recorder.flush_ring_to_aggregates()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_total_samples INTEGER;
    v_last_flush TIMESTAMPTZ;
BEGIN
    SELECT COALESCE(max(end_time), '1970-01-01')
    INTO v_last_flush
    FROM flight_recorder.wait_event_aggregates;
    SELECT min(captured_at), max(captured_at), count(*)
    INTO v_start_time, v_end_time, v_total_samples
    FROM flight_recorder.samples_ring
    WHERE captured_at > v_last_flush;
    IF v_start_time IS NULL OR v_total_samples = 0 THEN
        RETURN;
    END IF;
    INSERT INTO flight_recorder.wait_event_aggregates (
        start_time, end_time, backend_type, wait_event_type, wait_event, state,
        sample_count, total_waiters, avg_waiters, max_waiters, pct_of_samples
    )
    SELECT
        v_start_time,
        v_end_time,
        w.backend_type,
        w.wait_event_type,
        w.wait_event,
        w.state,
        count(DISTINCT w.slot_id) AS sample_count,
        sum(w.count) AS total_waiters,
        round(avg(w.count), 2) AS avg_waiters,
        max(w.count) AS max_waiters,
        round(100.0 * count(DISTINCT w.slot_id) / NULLIF(v_total_samples, 0), 1) AS pct_of_samples
    FROM flight_recorder.wait_samples_ring w
    JOIN flight_recorder.samples_ring s ON s.slot_id = w.slot_id
    WHERE s.captured_at BETWEEN v_start_time AND v_end_time
      AND w.backend_type IS NOT NULL
    GROUP BY w.backend_type, w.wait_event_type, w.wait_event, w.state;
    INSERT INTO flight_recorder.lock_aggregates (
        start_time, end_time, blocked_user, blocking_user, lock_type,
        locked_relation_oid, occurrence_count, max_duration, avg_duration, sample_query
    )
    SELECT
        v_start_time,
        v_end_time,
        l.blocked_user,
        l.blocking_user,
        l.lock_type,
        l.locked_relation_oid,
        count(*) AS occurrence_count,
        max(l.blocked_duration) AS max_duration,
        avg(l.blocked_duration) AS avg_duration,
        min(l.blocked_query_preview) AS sample_query
    FROM flight_recorder.lock_samples_ring l
    JOIN flight_recorder.samples_ring s ON s.slot_id = l.slot_id
    WHERE s.captured_at BETWEEN v_start_time AND v_end_time
      AND l.blocked_pid IS NOT NULL
    GROUP BY l.blocked_user, l.blocking_user, l.lock_type, l.locked_relation_oid;
    INSERT INTO flight_recorder.activity_aggregates (
        start_time, end_time, query_preview, occurrence_count, max_duration, avg_duration
    )
    SELECT
        v_start_time,
        v_end_time,
        a.query_preview,
        count(*) AS occurrence_count,
        max(s.captured_at - a.query_start) AS max_duration,
        avg(s.captured_at - a.query_start) AS avg_duration
    FROM flight_recorder.activity_samples_ring a
    JOIN flight_recorder.samples_ring s ON s.slot_id = a.slot_id
    WHERE s.captured_at BETWEEN v_start_time AND v_end_time
      AND a.pid IS NOT NULL
      AND a.query_start IS NOT NULL
    GROUP BY a.query_preview;
    RAISE NOTICE 'pg-flight-recorder: Flushed ring buffer (% to %, % samples)',
        v_start_time, v_end_time, v_total_samples;
END;
$$;
COMMENT ON FUNCTION flight_recorder.flush_ring_to_aggregates() IS 'Aggregates: Flush ring buffer to durable aggregates every 5 minutes';


-- Archives activity, lock, and wait samples from ring buffers to persistent storage for forensic analysis
-- Executes periodically (default every 15 minutes) based on configuration settings
CREATE OR REPLACE FUNCTION flight_recorder.archive_ring_samples()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_archive_activity BOOLEAN;
    v_archive_locks BOOLEAN;
    v_archive_waits BOOLEAN;
    v_frequency_minutes INTEGER;
    v_last_archive TIMESTAMPTZ;
    v_next_archive_due TIMESTAMPTZ;
    v_samples_to_archive INTEGER;
    v_activity_rows INTEGER := 0;
    v_lock_rows INTEGER := 0;
    v_wait_rows INTEGER := 0;
BEGIN
    v_enabled := COALESCE(
        (SELECT value::boolean FROM flight_recorder.config WHERE key = 'archive_samples_enabled'),
        true
    );
    IF NOT v_enabled THEN
        RETURN;
    END IF;
    v_archive_activity := COALESCE(
        (SELECT value::boolean FROM flight_recorder.config WHERE key = 'archive_activity_samples'),
        true
    );
    v_archive_locks := COALESCE(
        (SELECT value::boolean FROM flight_recorder.config WHERE key = 'archive_lock_samples'),
        true
    );
    v_archive_waits := COALESCE(
        (SELECT value::boolean FROM flight_recorder.config WHERE key = 'archive_wait_samples'),
        true
    );
    v_frequency_minutes := COALESCE(
        (SELECT value::integer FROM flight_recorder.config WHERE key = 'archive_sample_frequency_minutes'),
        15
    );
    SELECT GREATEST(
        COALESCE(MAX(captured_at), '1970-01-01'::timestamptz),
        COALESCE((SELECT MAX(captured_at) FROM flight_recorder.lock_samples_archive), '1970-01-01'::timestamptz),
        COALESCE((SELECT MAX(captured_at) FROM flight_recorder.wait_samples_archive), '1970-01-01'::timestamptz)
    )
    INTO v_last_archive
    FROM flight_recorder.activity_samples_archive;
    v_next_archive_due := v_last_archive + (v_frequency_minutes || ' minutes')::interval;
    IF now() < v_next_archive_due THEN
        RETURN;
    END IF;
    SELECT count(DISTINCT slot_id)
    INTO v_samples_to_archive
    FROM flight_recorder.samples_ring
    WHERE captured_at > v_last_archive;
    IF v_samples_to_archive = 0 THEN
        RETURN;
    END IF;
    IF v_archive_activity THEN
        INSERT INTO flight_recorder.activity_samples_archive (
            sample_id, captured_at, pid, usename, application_name, client_addr, backend_type,
            state, wait_event_type, wait_event, backend_start, xact_start,
            query_start, state_change, query_preview
        )
        SELECT
            s.epoch_seconds AS sample_id,
            s.captured_at,
            a.pid,
            a.usename,
            a.application_name,
            a.client_addr,
            a.backend_type,
            a.state,
            a.wait_event_type,
            a.wait_event,
            a.backend_start,
            a.xact_start,
            a.query_start,
            a.state_change,
            a.query_preview
        FROM flight_recorder.activity_samples_ring a
        JOIN flight_recorder.samples_ring s ON s.slot_id = a.slot_id
        WHERE s.captured_at > v_last_archive
          AND a.pid IS NOT NULL;
        GET DIAGNOSTICS v_activity_rows = ROW_COUNT;
    END IF;
    IF v_archive_locks THEN
        INSERT INTO flight_recorder.lock_samples_archive (
            sample_id, captured_at, blocked_pid, blocked_user, blocked_app,
            blocked_query_preview, blocked_duration, blocking_pid, blocking_user,
            blocking_app, blocking_query_preview, lock_type, locked_relation_oid
        )
        SELECT
            s.epoch_seconds AS sample_id,
            s.captured_at,
            l.blocked_pid,
            l.blocked_user,
            l.blocked_app,
            l.blocked_query_preview,
            l.blocked_duration,
            l.blocking_pid,
            l.blocking_user,
            l.blocking_app,
            l.blocking_query_preview,
            l.lock_type,
            l.locked_relation_oid
        FROM flight_recorder.lock_samples_ring l
        JOIN flight_recorder.samples_ring s ON s.slot_id = l.slot_id
        WHERE s.captured_at > v_last_archive
          AND l.blocked_pid IS NOT NULL;
        GET DIAGNOSTICS v_lock_rows = ROW_COUNT;
    END IF;
    IF v_archive_waits THEN
        INSERT INTO flight_recorder.wait_samples_archive (
            sample_id, captured_at, backend_type, wait_event_type, wait_event, state, count
        )
        SELECT
            s.epoch_seconds AS sample_id,
            s.captured_at,
            w.backend_type,
            w.wait_event_type,
            w.wait_event,
            w.state,
            w.count
        FROM flight_recorder.wait_samples_ring w
        JOIN flight_recorder.samples_ring s ON s.slot_id = w.slot_id
        WHERE s.captured_at > v_last_archive
          AND w.backend_type IS NOT NULL;
        GET DIAGNOSTICS v_wait_rows = ROW_COUNT;
    END IF;
    RAISE NOTICE 'pg-flight-recorder: Archived raw samples (% samples, % activity rows, % lock rows, % wait rows)',
        v_samples_to_archive, v_activity_rows, v_lock_rows, v_wait_rows;
END;
$$;
COMMENT ON FUNCTION flight_recorder.archive_ring_samples() IS 'Raw archives: Archive raw samples for high-resolution forensic analysis (default: every 15 minutes)';


-- Removes aged aggregate and archived sample data based on configured retention periods
-- Deletes expired records from wait_event_aggregates, lock_aggregates, activity_aggregates, and all *_samples_archive tables
CREATE OR REPLACE FUNCTION flight_recorder.cleanup_aggregates()
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    v_aggregate_retention interval;
    v_archive_retention interval;
    v_deleted_waits INTEGER;
    v_deleted_locks INTEGER;
    v_deleted_queries INTEGER;
    v_deleted_activity_archive INTEGER;
    v_deleted_lock_archive INTEGER;
    v_deleted_wait_archive INTEGER;
BEGIN
    v_aggregate_retention := COALESCE(
        (SELECT value || ' days' FROM flight_recorder.config WHERE key = 'aggregate_retention_days')::interval,
        '7 days'::interval
    );
    v_archive_retention := COALESCE(
        (SELECT value || ' days' FROM flight_recorder.config WHERE key = 'archive_retention_days')::interval,
        '7 days'::interval
    );
    DELETE FROM flight_recorder.wait_event_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_waits = ROW_COUNT;
    DELETE FROM flight_recorder.lock_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_locks = ROW_COUNT;
    DELETE FROM flight_recorder.activity_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_queries = ROW_COUNT;
    DELETE FROM flight_recorder.activity_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_activity_archive = ROW_COUNT;
    DELETE FROM flight_recorder.lock_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_lock_archive = ROW_COUNT;
    DELETE FROM flight_recorder.wait_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_wait_archive = ROW_COUNT;
    IF v_deleted_waits > 0 OR v_deleted_locks > 0 OR v_deleted_queries > 0 OR
       v_deleted_activity_archive > 0 OR v_deleted_lock_archive > 0 OR v_deleted_wait_archive > 0 THEN
        RAISE NOTICE 'pg-flight-recorder: Cleaned up % wait aggregates, % lock aggregates, % query aggregates, % activity archives, % lock archives, % wait archives',
            v_deleted_waits, v_deleted_locks, v_deleted_queries, v_deleted_activity_archive, v_deleted_lock_archive, v_deleted_wait_archive;
    END IF;
END;
$$;
COMMENT ON FUNCTION flight_recorder.cleanup_aggregates() IS 'Cleanup: Remove old aggregate and archive data based on retention periods';


-- Collects table-level statistics from pg_stat_user_tables
-- Captures tables based on configurable sampling mode: top_n, all, or threshold
CREATE OR REPLACE FUNCTION flight_recorder._collect_table_stats(p_snapshot_id INTEGER)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_top_n INTEGER;
    v_mode TEXT;
    v_threshold BIGINT;
BEGIN
    v_enabled := COALESCE(
        flight_recorder._get_config('table_stats_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    v_top_n := COALESCE(
        flight_recorder._get_config('table_stats_top_n', '50')::integer,
        50
    );

    v_mode := COALESCE(
        flight_recorder._get_config('table_stats_mode', 'top_n'),
        'top_n'
    );

    v_threshold := COALESCE(
        flight_recorder._get_config('table_stats_activity_threshold', '0')::bigint,
        0
    );

    -- Handle different collection modes
    IF v_mode = 'all' THEN
        -- Collect all user tables
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO flight_recorder.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age,
            table_size_bytes, total_size_bytes, indexes_size_bytes
        )
        SELECT
            p_snapshot_id,
            NULL,  -- schemaname deprecated: derive via relid
            NULL,  -- relname deprecated: derive via relid
            st.relid,
            st.seq_scan,
            st.seq_tup_read,
            st.idx_scan,
            st.idx_tup_fetch,
            st.n_tup_ins,
            st.n_tup_upd,
            st.n_tup_del,
            st.n_tup_hot_upd,
            st.n_live_tup,
            st.n_dead_tup,
            st.n_mod_since_analyze,
            st.vacuum_count,
            st.autovacuum_count,
            st.analyze_count,
            st.autoanalyze_count,
            st.last_vacuum,
            st.last_autovacuum,
            st.last_analyze,
            st.last_autoanalyze,
            age(c.relfrozenxid)::integer AS relfrozenxid_age,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid;

    ELSIF v_mode = 'threshold' THEN
        -- Collect tables with activity score above threshold
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO flight_recorder.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age,
            table_size_bytes, total_size_bytes, indexes_size_bytes
        )
        SELECT
            p_snapshot_id,
            NULL,  -- schemaname deprecated: derive via relid
            NULL,  -- relname deprecated: derive via relid
            st.relid,
            st.seq_scan,
            st.seq_tup_read,
            st.idx_scan,
            st.idx_tup_fetch,
            st.n_tup_ins,
            st.n_tup_upd,
            st.n_tup_del,
            st.n_tup_hot_upd,
            st.n_live_tup,
            st.n_dead_tup,
            st.n_mod_since_analyze,
            st.vacuum_count,
            st.autovacuum_count,
            st.analyze_count,
            st.autoanalyze_count,
            st.last_vacuum,
            st.last_autovacuum,
            st.last_analyze,
            st.last_autoanalyze,
            age(c.relfrozenxid)::integer AS relfrozenxid_age,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid
        WHERE (COALESCE(st.seq_tup_read, 0) + COALESCE(st.idx_tup_fetch, 0) +
               COALESCE(st.n_tup_ins, 0) + COALESCE(st.n_tup_upd, 0) + COALESCE(st.n_tup_del, 0)) >= v_threshold;

    ELSE
        -- Default: top_n mode (also handles invalid mode values)
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO flight_recorder.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age,
            table_size_bytes, total_size_bytes, indexes_size_bytes
        )
        SELECT
            p_snapshot_id,
            NULL,  -- schemaname deprecated: derive via relid
            NULL,  -- relname deprecated: derive via relid
            st.relid,
            st.seq_scan,
            st.seq_tup_read,
            st.idx_scan,
            st.idx_tup_fetch,
            st.n_tup_ins,
            st.n_tup_upd,
            st.n_tup_del,
            st.n_tup_hot_upd,
            st.n_live_tup,
            st.n_dead_tup,
            st.n_mod_since_analyze,
            st.vacuum_count,
            st.autovacuum_count,
            st.analyze_count,
            st.autoanalyze_count,
            st.last_vacuum,
            st.last_autovacuum,
            st.last_analyze,
            st.last_autoanalyze,
            age(c.relfrozenxid)::integer AS relfrozenxid_age,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid
        ORDER BY (COALESCE(st.seq_tup_read, 0) + COALESCE(st.idx_tup_fetch, 0) +
                  COALESCE(st.n_tup_ins, 0) + COALESCE(st.n_tup_upd, 0) + COALESCE(st.n_tup_del, 0)) DESC
        LIMIT v_top_n;
    END IF;
END;
$$;


-- Collects index-level statistics from pg_stat_user_indexes
-- Captures all user indexes with their usage metrics and sizes
CREATE OR REPLACE FUNCTION flight_recorder._collect_index_stats(p_snapshot_id INTEGER)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
BEGIN
    v_enabled := COALESCE(
        flight_recorder._get_config('index_stats_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Note: schemaname/relname/indexrelname are deprecated; derive via relation_names or ::regclass
    INSERT INTO flight_recorder.index_snapshots (
        snapshot_id, schemaname, relname, indexrelname, relid, indexrelid,
        idx_scan, idx_tup_read, idx_tup_fetch, index_size_bytes
    )
    SELECT
        p_snapshot_id,
        NULL,  -- schemaname deprecated: derive via relid
        NULL,  -- relname deprecated: derive via relid
        NULL,  -- indexrelname deprecated: derive via indexrelid
        i.relid,
        i.indexrelid,
        i.idx_scan,
        i.idx_tup_read,
        i.idx_tup_fetch,
        pg_relation_size(i.indexrelid) AS index_size_bytes
    FROM pg_stat_user_indexes i;
END;
$$;


-- Collects PostgreSQL configuration snapshot from pg_settings
-- Captures relevant settings for incident analysis and change tracking
CREATE OR REPLACE FUNCTION flight_recorder._collect_config_snapshot(p_snapshot_id INTEGER)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_relevant_params TEXT[] := ARRAY[
        -- Memory
        'shared_buffers',
        'work_mem',
        'maintenance_work_mem',
        'effective_cache_size',
        'temp_buffers',
        -- Connections
        'max_connections',
        'superuser_reserved_connections',
        -- Query Planning
        'random_page_cost',
        'seq_page_cost',
        'effective_io_concurrency',
        'default_statistics_target',
        'enable_seqscan',
        'enable_indexscan',
        'enable_bitmapscan',
        'enable_hashjoin',
        'enable_mergejoin',
        'enable_nestloop',
        -- Parallelism
        'max_parallel_workers',
        'max_parallel_workers_per_gather',
        'max_worker_processes',
        'parallel_setup_cost',
        'parallel_tuple_cost',
        -- WAL
        'wal_level',
        'max_wal_size',
        'min_wal_size',
        'wal_buffers',
        'checkpoint_timeout',
        'checkpoint_completion_target',
        'checkpoint_warning',
        -- Autovacuum
        'autovacuum',
        'autovacuum_max_workers',
        'autovacuum_naptime',
        'autovacuum_vacuum_threshold',
        'autovacuum_vacuum_scale_factor',
        'autovacuum_analyze_threshold',
        'autovacuum_analyze_scale_factor',
        'autovacuum_vacuum_cost_delay',
        'autovacuum_vacuum_cost_limit',
        'autovacuum_freeze_max_age',
        -- Logging
        'log_min_duration_statement',
        'log_lock_waits',
        'log_temp_files',
        'log_autovacuum_min_duration',
        -- Statement Behavior
        'statement_timeout',
        'lock_timeout',
        'idle_in_transaction_session_timeout',
        -- Resource Limits
        'temp_file_limit',
        'max_prepared_transactions',
        'max_locks_per_transaction',
        -- Extensions
        'shared_preload_libraries',
        'pg_stat_statements.track',
        'pg_stat_statements.max'
    ];
BEGIN
    v_enabled := COALESCE(
        flight_recorder._get_config('config_snapshots_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Only insert parameters that have changed since the most recent snapshot
    -- This reduces storage by 99%+ in stable environments while maintaining
    -- full point-in-time query capability via DISTINCT ON (cs.name) pattern
    INSERT INTO flight_recorder.config_snapshots (
        snapshot_id, name, setting, unit, source, sourcefile
    )
    WITH latest_config AS (
        SELECT DISTINCT ON (cs.name)
            cs.name,
            cs.setting,
            cs.unit,
            cs.source,
            cs.sourcefile
        FROM flight_recorder.config_snapshots cs
        JOIN flight_recorder.snapshots s ON s.id = cs.snapshot_id
        WHERE s.id < p_snapshot_id  -- Previous snapshots only
        ORDER BY cs.name, s.id DESC
    )
    SELECT
        p_snapshot_id,
        pg.name,
        pg.setting,
        pg.unit,
        pg.source,
        pg.sourcefile
    FROM pg_settings pg
    WHERE pg.name = ANY(v_relevant_params)
    AND (
        -- No previous snapshot exists (first run)
        NOT EXISTS (SELECT 1 FROM latest_config)
        OR
        -- Parameter didn't exist in previous snapshot (new parameter tracked)
        NOT EXISTS (SELECT 1 FROM latest_config lc WHERE lc.name = pg.name)
        OR
        -- Parameter value changed
        EXISTS (
            SELECT 1 FROM latest_config lc
            WHERE lc.name = pg.name
            AND (
                lc.setting IS DISTINCT FROM pg.setting
                OR lc.source IS DISTINCT FROM pg.source
                OR lc.sourcefile IS DISTINCT FROM pg.sourcefile
            )
        )
    );
END;
$$;


-- Collects database-level and role-level configuration overrides from pg_db_role_setting
-- These overrides (ALTER DATABASE/ROLE SET) can significantly impact performance but are easily overlooked
CREATE OR REPLACE FUNCTION flight_recorder._collect_db_role_config_snapshot(p_snapshot_id INTEGER)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
BEGIN
    v_enabled := COALESCE(
        flight_recorder._get_config('db_role_config_snapshots_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Only insert database/role config overrides that have changed since the most recent snapshot
    -- This reduces storage significantly in stable environments
    INSERT INTO flight_recorder.db_role_config_snapshots (
        snapshot_id, database_name, role_name, parameter_name, parameter_value
    )
    WITH latest_db_role_config AS (
        SELECT DISTINCT ON (drc.database_name, drc.role_name, drc.parameter_name)
            drc.database_name,
            drc.role_name,
            drc.parameter_name,
            drc.parameter_value
        FROM flight_recorder.db_role_config_snapshots drc
        JOIN flight_recorder.snapshots s ON s.id = drc.snapshot_id
        WHERE s.id < p_snapshot_id  -- Previous snapshots only
        ORDER BY drc.database_name, drc.role_name, drc.parameter_name, s.id DESC
    ),
    current_config AS (
        SELECT
            p_snapshot_id AS snapshot_id,
            COALESCE(d.datname, '') AS database_name,
            COALESCE(r.rolname, '') AS role_name,
            split_part(setting, '=', 1) AS parameter_name,
            split_part(setting, '=', 2) AS parameter_value
        FROM pg_db_role_setting drs
        CROSS JOIN LATERAL unnest(drs.setconfig) AS setting
        LEFT JOIN pg_database d ON d.oid = drs.setdatabase
        LEFT JOIN pg_roles r ON r.oid = drs.setrole
        WHERE drs.setconfig IS NOT NULL
    )
    SELECT
        cc.snapshot_id,
        cc.database_name,
        cc.role_name,
        cc.parameter_name,
        cc.parameter_value
    FROM current_config cc
    WHERE (
        -- No previous snapshot exists (first run)
        NOT EXISTS (SELECT 1 FROM latest_db_role_config)
        OR
        -- Override didn't exist in previous snapshot (new override)
        NOT EXISTS (
            SELECT 1 FROM latest_db_role_config lc
            WHERE lc.database_name = cc.database_name
            AND lc.role_name = cc.role_name
            AND lc.parameter_name = cc.parameter_name
        )
        OR
        -- Override value changed
        EXISTS (
            SELECT 1 FROM latest_db_role_config lc
            WHERE lc.database_name = cc.database_name
            AND lc.role_name = cc.role_name
            AND lc.parameter_name = cc.parameter_name
            AND lc.parameter_value IS DISTINCT FROM cc.parameter_value
        )
    )
    UNION ALL
    -- Capture removed overrides as NULL value to track deletions
    SELECT
        p_snapshot_id,
        lc.database_name,
        lc.role_name,
        lc.parameter_name,
        NULL AS parameter_value
    FROM latest_db_role_config lc
    WHERE NOT EXISTS (
        SELECT 1 FROM current_config cc
        WHERE cc.database_name = lc.database_name
        AND cc.role_name = lc.role_name
        AND cc.parameter_name = lc.parameter_name
    );
END;
$$;


-- Snapshots: Collect comprehensive snapshot of PostgreSQL system metrics (WAL, checkpoints, I/O, replication, statements)
-- Returns the captured timestamp for downstream processing and analysis
CREATE OR REPLACE FUNCTION flight_recorder.snapshot()
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql AS $$
DECLARE
    v_pg_version INTEGER;
    v_captured_at TIMESTAMPTZ := now();
    v_snapshot_id INTEGER;
    v_autovacuum_workers INTEGER;
    v_slots_count INTEGER;
    v_slots_max_retained BIGINT;
    v_temp_files BIGINT;
    v_temp_bytes BIGINT;
    v_io_ckpt_reads BIGINT;
    v_io_ckpt_read_time DOUBLE PRECISION;
    v_io_ckpt_writes BIGINT;
    v_io_ckpt_write_time DOUBLE PRECISION;
    v_io_ckpt_fsyncs BIGINT;
    v_io_ckpt_fsync_time DOUBLE PRECISION;
    v_io_av_reads BIGINT;
    v_io_av_read_time DOUBLE PRECISION;
    v_io_av_writes BIGINT;
    v_io_av_write_time DOUBLE PRECISION;
    v_io_client_reads BIGINT;
    v_io_client_read_time DOUBLE PRECISION;
    v_io_client_writes BIGINT;
    v_io_client_write_time DOUBLE PRECISION;
    v_io_bgw_reads BIGINT;
    v_io_bgw_read_time DOUBLE PRECISION;
    v_io_bgw_writes BIGINT;
    v_io_bgw_write_time DOUBLE PRECISION;
    v_stat_id INTEGER;
    v_should_skip BOOLEAN;
    v_checkpoint_info RECORD;
    v_xact_commit BIGINT;
    v_xact_rollback BIGINT;
    v_blks_read BIGINT;
    v_blks_hit BIGINT;
    v_connections_active INTEGER;
    v_connections_total INTEGER;
    v_connections_max INTEGER;
    v_db_size_bytes BIGINT;
    v_capacity_enabled BOOLEAN;
    v_datfrozenxid_age INTEGER;
    v_archived_count BIGINT;
    v_last_archived_wal TEXT;
    v_last_archived_time TIMESTAMPTZ;
    v_failed_count BIGINT;
    v_last_failed_wal TEXT;
    v_last_failed_time TIMESTAMPTZ;
    v_archiver_stats_reset TIMESTAMPTZ;
    v_archive_mode TEXT;
    v_confl_tablespace BIGINT;
    v_confl_lock BIGINT;
    v_confl_snapshot BIGINT;
    v_confl_bufferpin BIGINT;
    v_confl_deadlock BIGINT;
    v_confl_active_logicalslot BIGINT;
    v_is_standby BOOLEAN;
    v_max_catalog_oid BIGINT;
    v_large_object_count BIGINT;
BEGIN
    v_should_skip := flight_recorder._check_circuit_breaker('snapshot');
    IF v_should_skip THEN
        PERFORM flight_recorder._record_collection_skip('snapshot', 'Circuit breaker tripped - last run exceeded threshold');
        RAISE NOTICE 'pg-flight-recorder: Skipping snapshot collection due to circuit breaker';
        RETURN v_captured_at;
    END IF;
    DECLARE
        v_skip_reason TEXT;
    BEGIN
        v_skip_reason := flight_recorder._should_skip_collection();
        IF v_skip_reason IS NOT NULL THEN
            PERFORM flight_recorder._record_collection_skip('snapshot', v_skip_reason);
            RAISE NOTICE 'pg-flight-recorder: Skipping snapshot - %', v_skip_reason;
            RETURN v_captured_at;
        END IF;
    END;
    DECLARE
        v_running_count INTEGER;
        v_running_pid INTEGER;
    BEGIN
        SELECT count(*), min(pid) INTO v_running_count, v_running_pid
        FROM pg_stat_activity
        WHERE query ~ 'SELECT\s+flight_recorder\.snapshot\(\)'
          AND state = 'active'
          AND pid != pg_backend_pid()
          AND backend_type = 'client backend';
        IF v_running_count > 0 THEN
            PERFORM flight_recorder._record_collection_skip('snapshot',
                format('Job deduplication: %s snapshot job(s) already running (PID: %s)',
                       v_running_count, v_running_pid));
            RAISE NOTICE 'pg-flight-recorder: Skipping snapshot - another job already running (PID: %)', v_running_pid;
            RETURN v_captured_at;
        END IF;
    END;
    PERFORM flight_recorder._check_schema_size();
    v_stat_id := flight_recorder._record_collection_start('snapshot', 7);
    DECLARE
        v_check_ddl BOOLEAN;
        v_lock_strategy TEXT;
        v_ddl_lock_exists BOOLEAN;
        v_lock_timeout_ms INTEGER;
    BEGIN
        v_check_ddl := COALESCE(
            flight_recorder._get_config('check_ddl_before_collection', 'true')::boolean,
            true
        );
        v_lock_strategy := COALESCE(
            flight_recorder._get_config('lock_timeout_strategy', 'fail_fast'),
            'fail_fast'
        );
        IF v_check_ddl AND v_lock_strategy = 'skip_if_locked' THEN
            v_ddl_lock_exists := flight_recorder._check_catalog_ddl_locks();
            IF v_ddl_lock_exists THEN
                PERFORM flight_recorder._record_collection_skip('snapshot',
                    'DDL lock detected on system catalogs (skip_if_locked strategy)');
                RAISE NOTICE 'pg-flight-recorder: Skipping snapshot - DDL lock detected on catalogs';
                RETURN v_captured_at;
            END IF;
        END IF;
        v_lock_timeout_ms := CASE v_lock_strategy
            WHEN 'skip_if_locked' THEN 0
            WHEN 'patient' THEN 500
            ELSE 100
        END;
        PERFORM set_config('lock_timeout', v_lock_timeout_ms::text, true);
    END;
    PERFORM set_config('work_mem',
        COALESCE(flight_recorder._get_config('work_mem_kb', '2048'), '2048') || 'kB',
        true);
    v_pg_version := flight_recorder._pg_version();
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        SELECT count(*)::integer INTO v_autovacuum_workers
        FROM pg_stat_activity
        WHERE backend_type = 'autovacuum worker';
        SELECT
            count(*)::integer,
            COALESCE(max(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)), 0)
        INTO v_slots_count, v_slots_max_retained
        FROM pg_replication_slots;
        SELECT COALESCE(temp_files, 0), COALESCE(temp_bytes, 0)
        INTO v_temp_files, v_temp_bytes
        FROM pg_stat_database
        WHERE datname = current_database();
        v_checkpoint_info := pg_control_checkpoint();
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: System stats collection failed: %', SQLERRM;
        v_autovacuum_workers := 0;
        v_slots_count := 0;
        v_slots_max_retained := 0;
        v_temp_files := 0;
        v_temp_bytes := 0;
    END;
    IF v_pg_version >= 16 THEN
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        SELECT
            COALESCE(sum(reads) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(read_time) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(writes) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(write_time) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(fsyncs) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(fsync_time) FILTER (WHERE backend_type = 'checkpointer'), 0),
            COALESCE(sum(reads) FILTER (WHERE backend_type = 'autovacuum worker'), 0),
            COALESCE(sum(read_time) FILTER (WHERE backend_type = 'autovacuum worker'), 0),
            COALESCE(sum(writes) FILTER (WHERE backend_type = 'autovacuum worker'), 0),
            COALESCE(sum(write_time) FILTER (WHERE backend_type = 'autovacuum worker'), 0),
            COALESCE(sum(reads) FILTER (WHERE backend_type = 'client backend'), 0),
            COALESCE(sum(read_time) FILTER (WHERE backend_type = 'client backend'), 0),
            COALESCE(sum(writes) FILTER (WHERE backend_type = 'client backend'), 0),
            COALESCE(sum(write_time) FILTER (WHERE backend_type = 'client backend'), 0),
            COALESCE(sum(reads) FILTER (WHERE backend_type = 'background writer'), 0),
            COALESCE(sum(read_time) FILTER (WHERE backend_type = 'background writer'), 0),
            COALESCE(sum(writes) FILTER (WHERE backend_type = 'background writer'), 0),
            COALESCE(sum(write_time) FILTER (WHERE backend_type = 'background writer'), 0)
        INTO
            v_io_ckpt_reads, v_io_ckpt_read_time, v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time,
            v_io_av_reads, v_io_av_read_time, v_io_av_writes, v_io_av_write_time,
            v_io_client_reads, v_io_client_read_time, v_io_client_writes, v_io_client_write_time,
            v_io_bgw_reads, v_io_bgw_read_time, v_io_bgw_writes, v_io_bgw_write_time
        FROM pg_stat_io;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: pg_stat_io collection failed: %', SQLERRM;
        v_io_ckpt_reads := 0;
        v_io_ckpt_read_time := 0;
        v_io_ckpt_writes := 0;
        v_io_ckpt_write_time := 0;
        v_io_ckpt_fsyncs := 0;
        v_io_ckpt_fsync_time := 0;
        v_io_av_reads := 0;
        v_io_av_read_time := 0;
        v_io_av_writes := 0;
        v_io_av_write_time := 0;
        v_io_client_reads := 0;
        v_io_client_read_time := 0;
        v_io_client_writes := 0;
        v_io_client_write_time := 0;
        v_io_bgw_reads := 0;
        v_io_bgw_read_time := 0;
        v_io_bgw_writes := 0;
        v_io_bgw_write_time := 0;
    END;
    END IF;
    v_capacity_enabled := COALESCE(
        flight_recorder._get_config('capacity_planning_enabled', 'true')::boolean,
        true
    );
    IF v_capacity_enabled THEN
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        IF COALESCE(flight_recorder._get_config('collect_connection_metrics', 'true')::boolean, true) THEN
            SELECT
                xact_commit,
                xact_rollback,
                blks_read,
                blks_hit
            INTO v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit
            FROM pg_stat_database
            WHERE datname = current_database();
        END IF;
        IF COALESCE(flight_recorder._get_config('collect_connection_metrics', 'true')::boolean, true) THEN
            v_connections_max := current_setting('max_connections')::integer;
            SELECT
                count(*) FILTER (WHERE state NOT IN ('idle')),
                count(*)
            INTO v_connections_active, v_connections_total
            FROM pg_stat_activity;
        END IF;
        IF COALESCE(flight_recorder._get_config('collect_database_size', 'true')::boolean, true) THEN
            SELECT sum(relpages::bigint * current_setting('block_size')::bigint)
            INTO v_db_size_bytes
            FROM pg_class
            WHERE relkind IN ('r', 't', 'i', 'm')
              AND relpages > 0;
        END IF;
        SELECT age(datfrozenxid)::integer
        INTO v_datfrozenxid_age
        FROM pg_database
        WHERE datname = current_database();
        -- Collect OID exhaustion metrics
        SELECT max(oid)::bigint INTO v_max_catalog_oid FROM pg_class;
        SELECT count(*)::bigint INTO v_large_object_count FROM pg_largeobject_metadata;
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Capacity planning metrics collection failed: %', SQLERRM;
        v_xact_commit := NULL;
        v_xact_rollback := NULL;
        v_blks_read := NULL;
        v_blks_hit := NULL;
        v_connections_active := NULL;
        v_connections_total := NULL;
        v_connections_max := NULL;
        v_db_size_bytes := NULL;
        v_datfrozenxid_age := NULL;
        v_max_catalog_oid := NULL;
        v_large_object_count := NULL;
    END;
    END IF;
    -- Collect archiver stats (conditional on archive_mode != 'off')
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        v_archive_mode := current_setting('archive_mode', true);
        IF v_archive_mode IS NOT NULL AND v_archive_mode != 'off' THEN
            SELECT
                archived_count,
                last_archived_wal,
                last_archived_time,
                failed_count,
                last_failed_wal,
                last_failed_time,
                stats_reset
            INTO
                v_archived_count,
                v_last_archived_wal,
                v_last_archived_time,
                v_failed_count,
                v_last_failed_wal,
                v_last_failed_time,
                v_archiver_stats_reset
            FROM pg_stat_archiver;
        END IF;
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Archiver stats collection failed: %', SQLERRM;
    END;
    -- Collect database conflict stats (only populated on standby servers)
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        v_is_standby := pg_is_in_recovery();
        IF v_is_standby THEN
            IF v_pg_version >= 16 THEN
                SELECT
                    confl_tablespace,
                    confl_lock,
                    confl_snapshot,
                    confl_bufferpin,
                    confl_deadlock,
                    confl_active_logicalslot
                INTO
                    v_confl_tablespace,
                    v_confl_lock,
                    v_confl_snapshot,
                    v_confl_bufferpin,
                    v_confl_deadlock,
                    v_confl_active_logicalslot
                FROM pg_stat_database_conflicts
                WHERE datname = current_database();
            ELSE
                SELECT
                    confl_tablespace,
                    confl_lock,
                    confl_snapshot,
                    confl_bufferpin,
                    confl_deadlock
                INTO
                    v_confl_tablespace,
                    v_confl_lock,
                    v_confl_snapshot,
                    v_confl_bufferpin,
                    v_confl_deadlock
                FROM pg_stat_database_conflicts
                WHERE datname = current_database();
            END IF;
        END IF;
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Database conflict stats collection failed: %', SQLERRM;
    END;
    IF v_pg_version = 17 THEN
        INSERT INTO flight_recorder.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            io_checkpointer_reads, io_checkpointer_read_time,
            io_checkpointer_writes, io_checkpointer_write_time, io_checkpointer_fsyncs, io_checkpointer_fsync_time,
            io_autovacuum_reads, io_autovacuum_read_time,
            io_autovacuum_writes, io_autovacuum_write_time,
            io_client_reads, io_client_read_time,
            io_client_writes, io_client_write_time,
            io_bgwriter_reads, io_bgwriter_read_time,
            io_bgwriter_writes, io_bgwriter_write_time,
            temp_files, temp_bytes,
            xact_commit, xact_rollback, blks_read, blks_hit,
            connections_active, connections_total, connections_max,
            db_size_bytes, datfrozenxid_age,
            archived_count, last_archived_wal, last_archived_time,
            failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
            confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock, confl_active_logicalslot,
            max_catalog_oid, large_object_count
        )
        SELECT
            v_captured_at, v_pg_version,
            w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_write_time, w.wal_sync_time,
            v_checkpoint_info.redo_lsn,
            v_checkpoint_info.checkpoint_time,
            c.num_timed, c.num_requested, c.write_time, c.sync_time, c.buffers_written,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            NULL, NULL,
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_io_ckpt_reads, v_io_ckpt_read_time,
            v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time,
            v_io_av_reads, v_io_av_read_time,
            v_io_av_writes, v_io_av_write_time,
            v_io_client_reads, v_io_client_read_time,
            v_io_client_writes, v_io_client_write_time,
            v_io_bgw_reads, v_io_bgw_read_time,
            v_io_bgw_writes, v_io_bgw_write_time,
            v_temp_files, v_temp_bytes,
            v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit,
            v_connections_active, v_connections_total, v_connections_max,
            v_db_size_bytes, v_datfrozenxid_age,
            v_archived_count, v_last_archived_wal, v_last_archived_time,
            v_failed_count, v_last_failed_wal, v_last_failed_time, v_archiver_stats_reset,
            v_confl_tablespace, v_confl_lock, v_confl_snapshot, v_confl_bufferpin, v_confl_deadlock, v_confl_active_logicalslot,
            v_max_catalog_oid, v_large_object_count
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_checkpointer c
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;
    ELSIF v_pg_version = 16 THEN
        INSERT INTO flight_recorder.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            io_checkpointer_reads, io_checkpointer_read_time,
            io_checkpointer_writes, io_checkpointer_write_time, io_checkpointer_fsyncs, io_checkpointer_fsync_time,
            io_autovacuum_reads, io_autovacuum_read_time,
            io_autovacuum_writes, io_autovacuum_write_time,
            io_client_reads, io_client_read_time,
            io_client_writes, io_client_write_time,
            io_bgwriter_reads, io_bgwriter_read_time,
            io_bgwriter_writes, io_bgwriter_write_time,
            temp_files, temp_bytes,
            xact_commit, xact_rollback, blks_read, blks_hit,
            connections_active, connections_total, connections_max,
            db_size_bytes, datfrozenxid_age,
            archived_count, last_archived_wal, last_archived_time,
            failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
            confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock, confl_active_logicalslot,
            max_catalog_oid, large_object_count
        )
        SELECT
            v_captured_at, v_pg_version,
            w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_write_time, w.wal_sync_time,
            v_checkpoint_info.redo_lsn,
            v_checkpoint_info.checkpoint_time,
            b.checkpoints_timed, b.checkpoints_req, b.checkpoint_write_time, b.checkpoint_sync_time, b.buffers_checkpoint,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            b.buffers_backend, b.buffers_backend_fsync,
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_io_ckpt_reads, v_io_ckpt_read_time,
            v_io_ckpt_writes, v_io_ckpt_write_time, v_io_ckpt_fsyncs, v_io_ckpt_fsync_time,
            v_io_av_reads, v_io_av_read_time,
            v_io_av_writes, v_io_av_write_time,
            v_io_client_reads, v_io_client_read_time,
            v_io_client_writes, v_io_client_write_time,
            v_io_bgw_reads, v_io_bgw_read_time,
            v_io_bgw_writes, v_io_bgw_write_time,
            v_temp_files, v_temp_bytes,
            v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit,
            v_connections_active, v_connections_total, v_connections_max,
            v_db_size_bytes, v_datfrozenxid_age,
            v_archived_count, v_last_archived_wal, v_last_archived_time,
            v_failed_count, v_last_failed_wal, v_last_failed_time, v_archiver_stats_reset,
            v_confl_tablespace, v_confl_lock, v_confl_snapshot, v_confl_bufferpin, v_confl_deadlock, v_confl_active_logicalslot,
            v_max_catalog_oid, v_large_object_count
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;
    ELSIF v_pg_version = 15 THEN
        INSERT INTO flight_recorder.snapshots (
            captured_at, pg_version,
            wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
            checkpoint_lsn, checkpoint_time,
            ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
            bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
            bgw_buffers_backend, bgw_buffers_backend_fsync,
            autovacuum_workers, slots_count, slots_max_retained_wal,
            temp_files, temp_bytes,
            xact_commit, xact_rollback, blks_read, blks_hit,
            connections_active, connections_total, connections_max,
            db_size_bytes, datfrozenxid_age,
            archived_count, last_archived_wal, last_archived_time,
            failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
            confl_tablespace, confl_lock, confl_snapshot, confl_bufferpin, confl_deadlock,
            max_catalog_oid, large_object_count
        )
        SELECT
            v_captured_at, v_pg_version,
            w.wal_records, w.wal_fpi, w.wal_bytes, w.wal_write_time, w.wal_sync_time,
            v_checkpoint_info.redo_lsn,
            v_checkpoint_info.checkpoint_time,
            b.checkpoints_timed, b.checkpoints_req, b.checkpoint_write_time, b.checkpoint_sync_time, b.buffers_checkpoint,
            b.buffers_clean, b.maxwritten_clean, b.buffers_alloc,
            b.buffers_backend, b.buffers_backend_fsync,
            v_autovacuum_workers, v_slots_count, v_slots_max_retained,
            v_temp_files, v_temp_bytes,
            v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit,
            v_connections_active, v_connections_total, v_connections_max,
            v_db_size_bytes, v_datfrozenxid_age,
            v_archived_count, v_last_archived_wal, v_last_archived_time,
            v_failed_count, v_last_failed_wal, v_last_failed_time, v_archiver_stats_reset,
            v_confl_tablespace, v_confl_lock, v_confl_snapshot, v_confl_bufferpin, v_confl_deadlock,
            v_max_catalog_oid, v_large_object_count
        FROM pg_stat_wal w
        CROSS JOIN pg_stat_bgwriter b
        RETURNING id INTO v_snapshot_id;
    ELSE
        RAISE EXCEPTION 'Unsupported PostgreSQL version: %. Requires 15, 16, or 17.', v_pg_version;
    END IF;
    PERFORM flight_recorder._record_section_success(v_stat_id);
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        INSERT INTO flight_recorder.replication_snapshots (
            snapshot_id, pid, client_addr, application_name, state, sync_state,
            sent_lsn, write_lsn, flush_lsn, replay_lsn,
            write_lag, flush_lag, replay_lag
        )
        SELECT
            v_snapshot_id,
            pid,
            client_addr,
            application_name,
            state,
            sync_state,
            sent_lsn,
            write_lsn,
            flush_lsn,
            replay_lsn,
            write_lag,
            flush_lag,
            replay_lag
        FROM pg_stat_replication;
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Replication stats collection failed: %', SQLERRM;
    END;
    IF flight_recorder._has_pg_stat_statements()
       AND flight_recorder._get_config('statements_enabled', 'auto') != 'false'
    THEN
        DECLARE
            v_stmt_status TEXT;
            v_last_statements_collection TIMESTAMPTZ;
            v_statements_interval_minutes INTEGER;
            v_should_collect BOOLEAN := TRUE;
        BEGIN
            v_statements_interval_minutes := COALESCE(
                flight_recorder._get_config('statements_interval_minutes', '15')::integer,
                15
            );
            SELECT max(s.captured_at) INTO v_last_statements_collection
            FROM flight_recorder.snapshots s
            WHERE EXISTS (
                SELECT 1 FROM flight_recorder.statement_snapshots ss
                WHERE ss.snapshot_id = s.id
            );
            IF v_last_statements_collection IS NOT NULL
               AND v_last_statements_collection > now() - (v_statements_interval_minutes || ' minutes')::interval
            THEN
                v_should_collect := FALSE;
            END IF;
            IF v_should_collect THEN
                PERFORM flight_recorder._set_section_timeout();
                DECLARE
                    v_check_conflicts BOOLEAN;
                    v_pss_conflict BOOLEAN;
                BEGIN
                    v_check_conflicts := COALESCE(
                        flight_recorder._get_config('check_pss_conflicts', 'true')::boolean,
                        true
                    );
                    IF v_check_conflicts THEN
                        SELECT EXISTS(
                            SELECT 1 FROM pg_stat_activity
                            WHERE query ILIKE '%pg_stat_statements%'
                              AND state = 'active'
                              AND pid != pg_backend_pid()
                              AND backend_type = 'client backend'
                        ) INTO v_pss_conflict;
                        IF v_pss_conflict THEN
                            RAISE NOTICE 'pg-flight-recorder: Skipping pg_stat_statements - concurrent reader detected';
                            v_should_collect := FALSE;
                        END IF;
                    END IF;
                END;
                IF v_should_collect THEN
                    SELECT status INTO v_stmt_status
                    FROM flight_recorder._check_statements_health();
                    IF v_stmt_status = 'HIGH_CHURN' THEN
                        RAISE WARNING 'pg-flight-recorder: Skipping pg_stat_statements collection - high churn detected (>95%% utilization)';
                    ELSE
                INSERT INTO flight_recorder.statement_snapshots (
                snapshot_id, queryid, userid, dbid, query_preview,
                calls, total_exec_time, min_exec_time, max_exec_time,
                mean_exec_time, rows,
                shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
                temp_blks_read, temp_blks_written,
                blk_read_time, blk_write_time,
                wal_records, wal_bytes
            )
            SELECT
                v_snapshot_id,
                s.queryid,
                s.userid,
                s.dbid,
                left(s.query, 500),
                s.calls,
                s.total_exec_time,
                s.min_exec_time,
                s.max_exec_time,
                s.mean_exec_time,
                s.rows,
                s.shared_blks_hit,
                s.shared_blks_read,
                s.shared_blks_dirtied,
                s.shared_blks_written,
                s.temp_blks_read,
                s.temp_blks_written,
                s.blk_read_time,
                s.blk_write_time,
                s.wal_records,
                s.wal_bytes
            FROM pg_stat_statements s
            WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
              AND s.calls >= COALESCE(flight_recorder._get_config('statements_min_calls', '1')::integer, 1)
            ORDER BY CASE
                WHEN flight_recorder._get_config('statements_ranking_metric', 'buffers') = 'time'
                THEN s.total_exec_time
                ELSE s.shared_blks_hit + s.shared_blks_read + s.temp_blks_read + s.temp_blks_written
            END DESC
            LIMIT COALESCE(flight_recorder._get_config('statements_top_n', '20')::integer, 20);
                    PERFORM flight_recorder._record_section_success(v_stat_id);
                    END IF;
                END IF;
            END IF;
        EXCEPTION
            WHEN undefined_table THEN NULL;
            WHEN undefined_column THEN NULL;
            WHEN OTHERS THEN
                RAISE WARNING 'pg-flight-recorder: pg_stat_statements collection failed: %', SQLERRM;
        END;
    END IF;
    -- Collect table stats
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        PERFORM flight_recorder._collect_table_stats(v_snapshot_id);
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Table stats collection failed: %', SQLERRM;
    END;
    -- Collect index stats
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        PERFORM flight_recorder._collect_index_stats(v_snapshot_id);
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Index stats collection failed: %', SQLERRM;
    END;
    -- Collect config snapshot
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        PERFORM flight_recorder._collect_config_snapshot(v_snapshot_id);
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Config snapshot collection failed: %', SQLERRM;
    END;
    -- Collect database/role config overrides
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        PERFORM flight_recorder._collect_db_role_config_snapshot(v_snapshot_id);
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Database/role config collection failed: %', SQLERRM;
    END;
    -- Collect vacuum progress
    -- Note: In PG17, max_dead_tuples was renamed to max_dead_tuple_bytes
    --       and num_dead_tuples was renamed to num_dead_item_ids
    BEGIN
        PERFORM flight_recorder._set_section_timeout();
        IF v_pg_version >= 17 THEN
            INSERT INTO flight_recorder.vacuum_progress_snapshots (
                snapshot_id, pid, datid, datname, relid, relname, phase,
                heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
                index_vacuum_count, max_dead_tuples, num_dead_tuples
            )
            SELECT
                v_snapshot_id,
                p.pid,
                p.datid,
                d.datname,
                p.relid,
                c.relname,
                p.phase,
                p.heap_blks_total,
                p.heap_blks_scanned,
                p.heap_blks_vacuumed,
                p.index_vacuum_count,
                p.max_dead_tuple_bytes,  -- Renamed in PG17
                p.num_dead_item_ids      -- Renamed in PG17
            FROM pg_stat_progress_vacuum p
            LEFT JOIN pg_database d ON d.oid = p.datid
            LEFT JOIN pg_class c ON c.oid = p.relid;
        ELSE
            INSERT INTO flight_recorder.vacuum_progress_snapshots (
                snapshot_id, pid, datid, datname, relid, relname, phase,
                heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
                index_vacuum_count, max_dead_tuples, num_dead_tuples
            )
            SELECT
                v_snapshot_id,
                p.pid,
                p.datid,
                d.datname,
                p.relid,
                c.relname,
                p.phase,
                p.heap_blks_total,
                p.heap_blks_scanned,
                p.heap_blks_vacuumed,
                p.index_vacuum_count,
                p.max_dead_tuples,
                p.num_dead_tuples
            FROM pg_stat_progress_vacuum p
            LEFT JOIN pg_database d ON d.oid = p.datid
            LEFT JOIN pg_class c ON c.oid = p.relid;
        END IF;
        PERFORM flight_recorder._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg-flight-recorder: Vacuum progress collection failed: %', SQLERRM;
    END;
    PERFORM flight_recorder._record_collection_end(v_stat_id, true, NULL);
    PERFORM set_config('statement_timeout', '0', true);
    RETURN v_captured_at;
EXCEPTION
    WHEN OTHERS THEN
        PERFORM flight_recorder._record_collection_end(v_stat_id, false, SQLERRM);
        PERFORM set_config('statement_timeout', '0', true);
        RAISE;
END;
$$;
CREATE OR REPLACE VIEW flight_recorder.deltas AS
SELECT
    s.id,
    s.captured_at,
    s.pg_version,
    EXTRACT(EPOCH FROM (s.captured_at - prev.captured_at))::numeric AS interval_seconds,
    (s.checkpoint_time IS DISTINCT FROM prev.checkpoint_time) AS checkpoint_occurred,
    s.ckpt_timed - prev.ckpt_timed AS ckpt_timed_delta,
    s.ckpt_requested - prev.ckpt_requested AS ckpt_requested_delta,
    (s.ckpt_write_time - prev.ckpt_write_time)::numeric AS ckpt_write_time_ms,
    (s.ckpt_sync_time - prev.ckpt_sync_time)::numeric AS ckpt_sync_time_ms,
    s.ckpt_buffers - prev.ckpt_buffers AS ckpt_buffers_delta,
    s.wal_bytes - prev.wal_bytes AS wal_bytes_delta,
    flight_recorder._pretty_bytes(s.wal_bytes - prev.wal_bytes) AS wal_bytes_pretty,
    (s.wal_write_time - prev.wal_write_time)::numeric AS wal_write_time_ms,
    (s.wal_sync_time - prev.wal_sync_time)::numeric AS wal_sync_time_ms,
    s.bgw_buffers_clean - prev.bgw_buffers_clean AS bgw_buffers_clean_delta,
    s.bgw_buffers_alloc - prev.bgw_buffers_alloc AS bgw_buffers_alloc_delta,
    s.bgw_buffers_backend - prev.bgw_buffers_backend AS bgw_buffers_backend_delta,
    s.bgw_buffers_backend_fsync - prev.bgw_buffers_backend_fsync AS bgw_buffers_backend_fsync_delta,
    s.autovacuum_workers AS autovacuum_workers_active,
    s.slots_count,
    s.slots_max_retained_wal,
    flight_recorder._pretty_bytes(s.slots_max_retained_wal) AS slots_max_retained_pretty,
    s.io_checkpointer_reads - prev.io_checkpointer_reads AS io_ckpt_reads_delta,
    (s.io_checkpointer_read_time - prev.io_checkpointer_read_time)::numeric AS io_ckpt_read_time_ms,
    s.io_checkpointer_writes - prev.io_checkpointer_writes AS io_ckpt_writes_delta,
    (s.io_checkpointer_write_time - prev.io_checkpointer_write_time)::numeric AS io_ckpt_write_time_ms,
    s.io_checkpointer_fsyncs - prev.io_checkpointer_fsyncs AS io_ckpt_fsyncs_delta,
    (s.io_checkpointer_fsync_time - prev.io_checkpointer_fsync_time)::numeric AS io_ckpt_fsync_time_ms,
    s.io_autovacuum_reads - prev.io_autovacuum_reads AS io_autovacuum_reads_delta,
    (s.io_autovacuum_read_time - prev.io_autovacuum_read_time)::numeric AS io_autovacuum_read_time_ms,
    s.io_autovacuum_writes - prev.io_autovacuum_writes AS io_autovacuum_writes_delta,
    (s.io_autovacuum_write_time - prev.io_autovacuum_write_time)::numeric AS io_autovacuum_write_time_ms,
    s.io_client_reads - prev.io_client_reads AS io_client_reads_delta,
    (s.io_client_read_time - prev.io_client_read_time)::numeric AS io_client_read_time_ms,
    s.io_client_writes - prev.io_client_writes AS io_client_writes_delta,
    (s.io_client_write_time - prev.io_client_write_time)::numeric AS io_client_write_time_ms,
    s.io_bgwriter_reads - prev.io_bgwriter_reads AS io_bgwriter_reads_delta,
    (s.io_bgwriter_read_time - prev.io_bgwriter_read_time)::numeric AS io_bgwriter_read_time_ms,
    s.io_bgwriter_writes - prev.io_bgwriter_writes AS io_bgwriter_writes_delta,
    (s.io_bgwriter_write_time - prev.io_bgwriter_write_time)::numeric AS io_bgwriter_write_time_ms,
    s.temp_files - prev.temp_files AS temp_files_delta,
    s.temp_bytes - prev.temp_bytes AS temp_bytes_delta,
    flight_recorder._pretty_bytes(s.temp_bytes - prev.temp_bytes) AS temp_bytes_pretty
FROM flight_recorder.snapshots s
JOIN flight_recorder.snapshots prev ON prev.id = (
    SELECT MAX(id) FROM flight_recorder.snapshots WHERE id < s.id
)
ORDER BY s.captured_at DESC;
-- Compares database metrics between two time points, returning checkpoint, WAL, buffer, and IO activity deltas
CREATE OR REPLACE FUNCTION flight_recorder.compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    start_snapshot_at       TIMESTAMPTZ,
    end_snapshot_at         TIMESTAMPTZ,
    elapsed_seconds         NUMERIC,
    checkpoint_occurred     BOOLEAN,
    ckpt_timed_delta        BIGINT,
    ckpt_requested_delta    BIGINT,
    ckpt_write_time_ms      NUMERIC,
    ckpt_sync_time_ms       NUMERIC,
    ckpt_buffers_delta      BIGINT,
    wal_bytes_delta         BIGINT,
    wal_bytes_pretty        TEXT,
    wal_write_time_ms       NUMERIC,
    wal_sync_time_ms        NUMERIC,
    bgw_buffers_clean_delta       BIGINT,
    bgw_buffers_alloc_delta       BIGINT,
    bgw_buffers_backend_delta     BIGINT,
    bgw_buffers_backend_fsync_delta BIGINT,
    slots_count             INTEGER,
    slots_max_retained_wal  BIGINT,
    slots_max_retained_pretty TEXT,
    io_ckpt_reads_delta           BIGINT,
    io_ckpt_read_time_ms          NUMERIC,
    io_ckpt_writes_delta          BIGINT,
    io_ckpt_write_time_ms         NUMERIC,
    io_ckpt_fsyncs_delta          BIGINT,
    io_ckpt_fsync_time_ms         NUMERIC,
    io_autovacuum_reads_delta     BIGINT,
    io_autovacuum_read_time_ms    NUMERIC,
    io_autovacuum_writes_delta    BIGINT,
    io_autovacuum_write_time_ms   NUMERIC,
    io_client_reads_delta         BIGINT,
    io_client_read_time_ms        NUMERIC,
    io_client_writes_delta        BIGINT,
    io_client_write_time_ms       NUMERIC,
    io_bgwriter_reads_delta       BIGINT,
    io_bgwriter_read_time_ms      NUMERIC,
    io_bgwriter_writes_delta      BIGINT,
    io_bgwriter_write_time_ms     NUMERIC,
    temp_files_delta              BIGINT,
    temp_bytes_delta              BIGINT,
    temp_bytes_pretty             TEXT
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT * FROM flight_recorder.snapshots
        WHERE captured_at <= p_start_time
        ORDER BY captured_at DESC
        LIMIT 1
    ),
    end_snap AS (
        SELECT * FROM flight_recorder.snapshots
        WHERE captured_at >= p_end_time
        ORDER BY captured_at ASC
        LIMIT 1
    )
    SELECT
        s.captured_at,
        e.captured_at,
        EXTRACT(EPOCH FROM (e.captured_at - s.captured_at))::numeric,
        (s.checkpoint_time IS DISTINCT FROM e.checkpoint_time),
        e.ckpt_timed - s.ckpt_timed,
        e.ckpt_requested - s.ckpt_requested,
        (e.ckpt_write_time - s.ckpt_write_time)::numeric,
        (e.ckpt_sync_time - s.ckpt_sync_time)::numeric,
        e.ckpt_buffers - s.ckpt_buffers,
        e.wal_bytes - s.wal_bytes,
        flight_recorder._pretty_bytes(e.wal_bytes - s.wal_bytes),
        (e.wal_write_time - s.wal_write_time)::numeric,
        (e.wal_sync_time - s.wal_sync_time)::numeric,
        e.bgw_buffers_clean - s.bgw_buffers_clean,
        e.bgw_buffers_alloc - s.bgw_buffers_alloc,
        e.bgw_buffers_backend - s.bgw_buffers_backend,
        e.bgw_buffers_backend_fsync - s.bgw_buffers_backend_fsync,
        e.slots_count,
        e.slots_max_retained_wal,
        flight_recorder._pretty_bytes(e.slots_max_retained_wal),
        e.io_checkpointer_reads - s.io_checkpointer_reads,
        (e.io_checkpointer_read_time - s.io_checkpointer_read_time)::numeric,
        e.io_checkpointer_writes - s.io_checkpointer_writes,
        (e.io_checkpointer_write_time - s.io_checkpointer_write_time)::numeric,
        e.io_checkpointer_fsyncs - s.io_checkpointer_fsyncs,
        (e.io_checkpointer_fsync_time - s.io_checkpointer_fsync_time)::numeric,
        e.io_autovacuum_reads - s.io_autovacuum_reads,
        (e.io_autovacuum_read_time - s.io_autovacuum_read_time)::numeric,
        e.io_autovacuum_writes - s.io_autovacuum_writes,
        (e.io_autovacuum_write_time - s.io_autovacuum_write_time)::numeric,
        e.io_client_reads - s.io_client_reads,
        (e.io_client_read_time - s.io_client_read_time)::numeric,
        e.io_client_writes - s.io_client_writes,
        (e.io_client_write_time - s.io_client_write_time)::numeric,
        e.io_bgwriter_reads - s.io_bgwriter_reads,
        (e.io_bgwriter_read_time - s.io_bgwriter_read_time)::numeric,
        e.io_bgwriter_writes - s.io_bgwriter_writes,
        (e.io_bgwriter_write_time - s.io_bgwriter_write_time)::numeric,
        e.temp_files - s.temp_files,
        e.temp_bytes - s.temp_bytes,
        flight_recorder._pretty_bytes(e.temp_bytes - s.temp_bytes)
    FROM start_snap s, end_snap e
$$;

-- Returns the ring buffer retention interval based on configured sample interval
-- Used by recent_* views and recent_*_current() functions to determine query window
CREATE OR REPLACE FUNCTION flight_recorder._get_ring_retention_interval()
RETURNS INTERVAL
LANGUAGE sql STABLE AS $$
    SELECT ((120 * COALESCE(
        flight_recorder._get_config('sample_interval_seconds', '60')::integer,
        60
    ))::text || ' seconds')::interval;
$$;

CREATE OR REPLACE VIEW flight_recorder.recent_waits AS
SELECT
    sr.captured_at,
    w.backend_type,
    w.wait_event_type,
    w.wait_event,
    w.state,
    w.count
FROM flight_recorder.samples_ring sr
JOIN flight_recorder.wait_samples_ring w ON w.slot_id = sr.slot_id
WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
  AND w.backend_type IS NOT NULL
ORDER BY sr.captured_at DESC, w.count DESC;
CREATE OR REPLACE VIEW flight_recorder.recent_activity AS
SELECT
    sr.captured_at,
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.backend_type,
    a.state,
    a.wait_event_type,
    a.wait_event,
    a.backend_start,
    a.xact_start,
    a.query_start,
    sr.captured_at - a.backend_start AS session_age,
    sr.captured_at - a.xact_start AS xact_age,
    sr.captured_at - a.query_start AS running_for,
    a.query_preview
FROM flight_recorder.samples_ring sr
JOIN flight_recorder.activity_samples_ring a ON a.slot_id = sr.slot_id
WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
  AND a.pid IS NOT NULL
ORDER BY sr.captured_at DESC, a.query_start ASC;
CREATE OR REPLACE VIEW flight_recorder.recent_locks AS
SELECT
    sr.captured_at,
    l.blocked_pid,
    l.blocked_user,
    l.blocked_app,
    l.blocked_duration,
    l.blocking_pid,
    l.blocking_user,
    l.blocking_app,
    l.lock_type,
    COALESCE(l.locked_relation_oid::regclass::text, 'OID:' || l.locked_relation_oid::text) AS locked_relation,
    l.blocked_query_preview,
    l.blocking_query_preview
FROM flight_recorder.samples_ring sr
JOIN flight_recorder.lock_samples_ring l ON l.slot_id = sr.slot_id
WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
  AND l.blocked_pid IS NOT NULL
ORDER BY sr.captured_at DESC, l.blocked_duration DESC;

-- Shows sessions currently idle in transaction, ordered by how long they have been idle
-- Used for quick visibility into problem sessions that may be blocking vacuum or holding locks
CREATE OR REPLACE VIEW flight_recorder.recent_idle_in_transaction AS
SELECT
    sr.captured_at,
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.xact_start,
    sr.captured_at - a.xact_start AS idle_duration,
    a.query_preview
FROM flight_recorder.samples_ring sr
JOIN flight_recorder.activity_samples_ring a ON a.slot_id = sr.slot_id
WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
  AND a.pid IS NOT NULL
  AND a.state = 'idle in transaction'
ORDER BY a.xact_start ASC NULLS LAST;

COMMENT ON VIEW flight_recorder.recent_idle_in_transaction IS
'Sessions currently idle in transaction, ordered by how long they have been idle';

-- Retrieves recent wait event samples from the flight recorder ring buffer
-- Filters by configured retention interval and orders by capture time and occurrence count
CREATE OR REPLACE FUNCTION flight_recorder.recent_waits_current()
RETURNS TABLE (
    captured_at TIMESTAMPTZ,
    backend_type TEXT,
    wait_event_type TEXT,
    wait_event TEXT,
    state TEXT,
    count INTEGER
)
LANGUAGE sql STABLE AS $$
    SELECT
        sr.captured_at,
        w.backend_type,
        w.wait_event_type,
        w.wait_event,
        w.state,
        w.count
    FROM flight_recorder.samples_ring sr
    JOIN flight_recorder.wait_samples_ring w ON w.slot_id = sr.slot_id
    WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
      AND w.backend_type IS NOT NULL
    ORDER BY sr.captured_at DESC, w.count DESC;
$$;
-- Retrieves recent backend session activity with query duration and wait event details
-- Queries the activity ring buffer for sessions within the configured retention window
CREATE OR REPLACE FUNCTION flight_recorder.recent_activity_current()
RETURNS TABLE (
    captured_at TIMESTAMPTZ,
    pid INTEGER,
    usename TEXT,
    application_name TEXT,
    backend_type TEXT,
    state TEXT,
    wait_event_type TEXT,
    wait_event TEXT,
    query_start TIMESTAMPTZ,
    running_for INTERVAL,
    query_preview TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        sr.captured_at,
        a.pid,
        a.usename,
        a.application_name,
        a.backend_type,
        a.state,
        a.wait_event_type,
        a.wait_event,
        a.query_start,
        sr.captured_at - a.query_start AS running_for,
        a.query_preview
    FROM flight_recorder.samples_ring sr
    JOIN flight_recorder.activity_samples_ring a ON a.slot_id = sr.slot_id
    WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
      AND a.pid IS NOT NULL
    ORDER BY sr.captured_at DESC, a.query_start ASC;
$$;
-- Returns recent lock contention events showing which processes are blocked and their blocking processes
-- Filters data within the configured retention window from ring buffer samples
CREATE OR REPLACE FUNCTION flight_recorder.recent_locks_current()
RETURNS TABLE (
    captured_at TIMESTAMPTZ,
    blocked_pid INTEGER,
    blocked_user TEXT,
    blocked_app TEXT,
    blocked_duration INTERVAL,
    blocking_pid INTEGER,
    blocking_user TEXT,
    blocking_app TEXT,
    lock_type TEXT,
    locked_relation TEXT,
    blocked_query_preview TEXT,
    blocking_query_preview TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        sr.captured_at,
        l.blocked_pid,
        l.blocked_user,
        l.blocked_app,
        l.blocked_duration,
        l.blocking_pid,
        l.blocking_user,
        l.blocking_app,
        l.lock_type,
        COALESCE(l.locked_relation_oid::regclass::text, 'OID:' || l.locked_relation_oid::text) AS locked_relation,
        l.blocked_query_preview,
        l.blocking_query_preview
    FROM flight_recorder.samples_ring sr
    JOIN flight_recorder.lock_samples_ring l ON l.slot_id = sr.slot_id
    WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
      AND l.blocked_pid IS NOT NULL
    ORDER BY sr.captured_at DESC, l.blocked_duration DESC;
$$;
CREATE OR REPLACE VIEW flight_recorder.recent_replication AS
SELECT
    sn.captured_at,
    r.pid,
    r.client_addr,
    r.application_name,
    r.state,
    r.sync_state,
    r.sent_lsn,
    r.write_lsn,
    r.flush_lsn,
    r.replay_lsn,
    pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn)::bigint AS replay_lag_bytes,
    flight_recorder._pretty_bytes(pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn)::bigint) AS replay_lag_pretty,
    r.write_lag,
    r.flush_lag,
    r.replay_lag
FROM flight_recorder.snapshots sn
JOIN flight_recorder.replication_snapshots r ON r.snapshot_id = sn.id
WHERE sn.captured_at > now() - interval '2 hours'
ORDER BY sn.captured_at DESC, r.application_name;

-- Shows vacuum progress from recent snapshots with percentage calculations
CREATE OR REPLACE VIEW flight_recorder.recent_vacuum_progress AS
SELECT
    sn.captured_at,
    v.pid,
    v.datname,
    v.relname,
    v.phase,
    v.heap_blks_total,
    v.heap_blks_scanned,
    v.heap_blks_vacuumed,
    CASE WHEN v.heap_blks_total > 0
        THEN round(100.0 * v.heap_blks_scanned / v.heap_blks_total, 1)
        ELSE NULL
    END AS pct_scanned,
    CASE WHEN v.heap_blks_total > 0
        THEN round(100.0 * v.heap_blks_vacuumed / v.heap_blks_total, 1)
        ELSE NULL
    END AS pct_vacuumed,
    v.index_vacuum_count,
    v.max_dead_tuples,
    v.num_dead_tuples
FROM flight_recorder.snapshots sn
JOIN flight_recorder.vacuum_progress_snapshots v ON v.snapshot_id = sn.id
WHERE sn.captured_at > now() - interval '2 hours'
ORDER BY sn.captured_at DESC, v.pid;
COMMENT ON VIEW flight_recorder.recent_vacuum_progress IS 'Recent vacuum progress with percentage scanned/vacuumed calculations';

-- Shows archiver status with delta calculations between snapshots
CREATE OR REPLACE VIEW flight_recorder.archiver_status AS
SELECT
    s.id AS snapshot_id,
    s.captured_at,
    s.archived_count,
    s.last_archived_wal,
    s.last_archived_time,
    s.failed_count,
    s.last_failed_wal,
    s.last_failed_time,
    s.archiver_stats_reset,
    s.archived_count - prev.archived_count AS archived_delta,
    s.failed_count - prev.failed_count AS failed_delta
FROM flight_recorder.snapshots s
JOIN flight_recorder.snapshots prev ON prev.id = (
    SELECT MAX(id) FROM flight_recorder.snapshots WHERE id < s.id
)
WHERE s.captured_at > now() - interval '24 hours'
  AND s.archived_count IS NOT NULL
ORDER BY s.captured_at DESC;
COMMENT ON VIEW flight_recorder.archiver_status IS 'WAL archiver status with delta calculations between snapshots';

-- Summarizes wait events within a time range, grouped by backend type and wait event
-- Returns statistics including sample count, total/avg/max waiters, and percentage of samples
CREATE OR REPLACE FUNCTION flight_recorder.wait_summary(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    backend_type        TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    sample_count        BIGINT,
    total_waiters       BIGINT,
    avg_waiters         NUMERIC,
    max_waiters         INTEGER,
    pct_of_samples      NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH sample_range AS (
        SELECT slot_id, captured_at
        FROM flight_recorder.samples_ring
        WHERE captured_at BETWEEN p_start_time AND p_end_time
    ),
    total_samples AS (
        SELECT count(*) AS cnt FROM sample_range
    )
    SELECT
        w.backend_type,
        w.wait_event_type,
        w.wait_event,
        count(DISTINCT w.slot_id) AS sample_count,
        sum(w.count) AS total_waiters,
        round(avg(w.count), 2) AS avg_waiters,
        max(w.count) AS max_waiters,
        round(100.0 * count(DISTINCT w.slot_id) / NULLIF(t.cnt, 0), 1) AS pct_of_samples
    FROM flight_recorder.wait_samples_ring w
    JOIN sample_range sr ON sr.slot_id = w.slot_id
    CROSS JOIN total_samples t
    WHERE w.state NOT IN ('idle', 'idle in transaction')
    GROUP BY w.backend_type, w.wait_event_type, w.wait_event, t.cnt
    ORDER BY total_waiters DESC, sample_count DESC;
$$;

-- Compares statement execution metrics between two snapshots, calculating performance deltas
-- Identifies queries with significant changes in execution time and resource consumption
CREATE OR REPLACE FUNCTION flight_recorder.statement_compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ,
    p_min_delta_ms DOUBLE PRECISION DEFAULT 100,
    p_limit INTEGER DEFAULT 25
)
RETURNS TABLE(
    queryid                     BIGINT,
    query_preview               TEXT,
    calls_start                 BIGINT,
    calls_end                   BIGINT,
    calls_delta                 BIGINT,
    total_exec_time_start_ms    DOUBLE PRECISION,
    total_exec_time_end_ms      DOUBLE PRECISION,
    total_exec_time_delta_ms    DOUBLE PRECISION,
    mean_exec_time_start_ms     DOUBLE PRECISION,
    mean_exec_time_end_ms       DOUBLE PRECISION,
    rows_delta                  BIGINT,
    shared_blks_hit_delta       BIGINT,
    shared_blks_read_delta      BIGINT,
    shared_blks_written_delta   BIGINT,
    temp_blks_read_delta        BIGINT,
    temp_blks_written_delta     BIGINT,
    wal_bytes_delta             NUMERIC,
    hit_ratio_pct               NUMERIC,
    time_per_call_ms            DOUBLE PRECISION
)
LANGUAGE sql STABLE AS $$
    WITH
    start_snap AS (
        SELECT ss.*, s.captured_at
        FROM flight_recorder.statement_snapshots ss
        JOIN flight_recorder.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at <= p_start_time
        ORDER BY s.captured_at DESC
        LIMIT 1000
    ),
    end_snap AS (
        SELECT ss.*, s.captured_at
        FROM flight_recorder.statement_snapshots ss
        JOIN flight_recorder.snapshots s ON s.id = ss.snapshot_id
        WHERE s.captured_at >= p_end_time
        ORDER BY s.captured_at ASC
        LIMIT 1000
    ),
    matched AS (
        SELECT
            e.queryid,
            COALESCE(e.query_preview, s.query_preview) AS query_preview,
            s.calls AS calls_start,
            e.calls AS calls_end,
            s.total_exec_time AS total_exec_time_start,
            e.total_exec_time AS total_exec_time_end,
            s.mean_exec_time AS mean_exec_time_start,
            e.mean_exec_time AS mean_exec_time_end,
            s.rows AS rows_start,
            e.rows AS rows_end,
            s.shared_blks_hit AS shared_blks_hit_start,
            e.shared_blks_hit AS shared_blks_hit_end,
            s.shared_blks_read AS shared_blks_read_start,
            e.shared_blks_read AS shared_blks_read_end,
            s.shared_blks_written AS shared_blks_written_start,
            e.shared_blks_written AS shared_blks_written_end,
            s.temp_blks_read AS temp_blks_read_start,
            e.temp_blks_read AS temp_blks_read_end,
            s.temp_blks_written AS temp_blks_written_start,
            e.temp_blks_written AS temp_blks_written_end,
            s.wal_bytes AS wal_bytes_start,
            e.wal_bytes AS wal_bytes_end
        FROM end_snap e
        LEFT JOIN start_snap s ON s.queryid = e.queryid AND s.dbid = e.dbid
    )
    SELECT
        m.queryid,
        m.query_preview,
        COALESCE(m.calls_start, 0),
        m.calls_end,
        m.calls_end - COALESCE(m.calls_start, 0),
        COALESCE(m.total_exec_time_start, 0),
        m.total_exec_time_end,
        m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0),
        m.mean_exec_time_start,
        m.mean_exec_time_end,
        m.rows_end - COALESCE(m.rows_start, 0),
        m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0),
        m.shared_blks_read_end - COALESCE(m.shared_blks_read_start, 0),
        m.shared_blks_written_end - COALESCE(m.shared_blks_written_start, 0),
        m.temp_blks_read_end - COALESCE(m.temp_blks_read_start, 0),
        m.temp_blks_written_end - COALESCE(m.temp_blks_written_start, 0),
        m.wal_bytes_end - COALESCE(m.wal_bytes_start, 0),
        CASE
            WHEN (m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0) +
                  m.shared_blks_read_end - COALESCE(m.shared_blks_read_start, 0)) > 0
            THEN round(
                100.0 * (m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0)) /
                (m.shared_blks_hit_end - COALESCE(m.shared_blks_hit_start, 0) +
                 m.shared_blks_read_end - COALESCE(m.shared_blks_read_start, 0)), 1
            )
            ELSE NULL
        END,
        CASE
            WHEN (m.calls_end - COALESCE(m.calls_start, 0)) > 0
            THEN (m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0)) /
                 (m.calls_end - COALESCE(m.calls_start, 0))
            ELSE NULL
        END
    FROM matched m
    WHERE (m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0)) >= p_min_delta_ms
    ORDER BY (m.total_exec_time_end - COALESCE(m.total_exec_time_start, 0)) DESC
    LIMIT p_limit
$$;

-- Retrieves active session details at a specific point in time
-- Shows query text, wait events, and session state from archived activity samples
CREATE OR REPLACE FUNCTION flight_recorder.activity_at(p_timestamp TIMESTAMPTZ)
RETURNS TABLE(
    sample_captured_at      TIMESTAMPTZ,
    sample_offset_seconds   NUMERIC,
    active_sessions         INTEGER,
    waiting_sessions        INTEGER,
    idle_in_transaction     INTEGER,
    top_wait_event_1        TEXT,
    top_wait_count_1        INTEGER,
    top_wait_event_2        TEXT,
    top_wait_count_2        INTEGER,
    top_wait_event_3        TEXT,
    top_wait_count_3        INTEGER,
    blocked_pids            INTEGER,
    longest_blocked_duration INTERVAL,
    vacuums_running         INTEGER,
    copies_running          INTEGER,
    indexes_building        INTEGER,
    analyzes_running        INTEGER,
    snapshot_captured_at    TIMESTAMPTZ,
    snapshot_offset_seconds NUMERIC,
    autovacuum_workers      INTEGER,
    checkpoint_occurred     BOOLEAN
)
LANGUAGE sql STABLE AS $$
    WITH
    nearest_sample AS (
        SELECT slot_id, captured_at,
               ABS(EXTRACT(EPOCH FROM (captured_at - p_timestamp))) AS offset_secs
        FROM flight_recorder.samples_ring
        ORDER BY ABS(EXTRACT(EPOCH FROM (captured_at - p_timestamp)))
        LIMIT 1
    ),
    nearest_snapshot AS (
        SELECT s.id, s.captured_at, s.autovacuum_workers,
               (s.checkpoint_time IS DISTINCT FROM prev.checkpoint_time) AS checkpoint_occurred,
               ABS(EXTRACT(EPOCH FROM (s.captured_at - p_timestamp))) AS offset_secs
        FROM flight_recorder.snapshots s
        LEFT JOIN flight_recorder.snapshots prev ON prev.id = (
            SELECT MAX(id) FROM flight_recorder.snapshots WHERE id < s.id
        )
        ORDER BY ABS(EXTRACT(EPOCH FROM (s.captured_at - p_timestamp)))
        LIMIT 1
    ),
    sample_waits AS (
        SELECT
            wait_event_type || ':' || wait_event AS wait_event,
            count
        FROM flight_recorder.wait_samples_ring w
        JOIN nearest_sample ns ON ns.slot_id = w.slot_id
        WHERE w.state NOT IN ('idle', 'idle in transaction')
        ORDER BY count DESC
        LIMIT 3
    ),
    wait_array AS (
        SELECT array_agg(wait_event ORDER BY count DESC) AS events,
               array_agg(count ORDER BY count DESC) AS counts
        FROM sample_waits
    ),
    sample_activity AS (
        SELECT
            count(*) FILTER (WHERE state = 'active') AS active_sessions,
            count(*) FILTER (WHERE wait_event IS NOT NULL) AS waiting_sessions,
            count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction
        FROM flight_recorder.activity_samples_ring a
        JOIN nearest_sample ns ON ns.slot_id = a.slot_id
    ),
    sample_locks AS (
        SELECT
            count(DISTINCT blocked_pid) AS blocked_pids,
            max(blocked_duration) AS longest_blocked
        FROM flight_recorder.lock_samples_ring l
        JOIN nearest_sample ns ON ns.slot_id = l.slot_id
    ),
    sample_progress AS (
        SELECT
            0 AS vacuums,
            0 AS copies,
            0 AS indexes,
            0 AS analyzes
    )
    SELECT
        ns.captured_at,
        ns.offset_secs::numeric,
        COALESCE(sa.active_sessions, 0)::integer,
        COALESCE(sa.waiting_sessions, 0)::integer,
        COALESCE(sa.idle_in_transaction, 0)::integer,
        wa.events[1],
        wa.counts[1],
        wa.events[2],
        wa.counts[2],
        wa.events[3],
        wa.counts[3],
        COALESCE(sl.blocked_pids, 0)::integer,
        sl.longest_blocked,
        COALESCE(sp.vacuums, 0)::integer,
        COALESCE(sp.copies, 0)::integer,
        COALESCE(sp.indexes, 0)::integer,
        COALESCE(sp.analyzes, 0)::integer,
        sn.captured_at,
        sn.offset_secs::numeric,
        sn.autovacuum_workers,
        sn.checkpoint_occurred
    FROM nearest_sample ns
    CROSS JOIN nearest_snapshot sn
    CROSS JOIN sample_activity sa
    CROSS JOIN sample_locks sl
    CROSS JOIN sample_progress sp
    CROSS JOIN wait_array wa
$$;

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

-- Switches flight recorder to specified mode (normal/light/emergency) with different overhead and retention trade-offs
-- Validates mode and configures sampling interval and collector enablement accordingly
CREATE OR REPLACE FUNCTION flight_recorder.set_mode(p_mode TEXT)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_enable_locks BOOLEAN;
    v_enable_progress BOOLEAN;
    v_description TEXT;
    v_sample_interval_seconds INTEGER;
    v_sample_interval_minutes INTEGER;
    v_cron_expression TEXT;
    v_current_interval INTEGER;
BEGIN
    IF p_mode NOT IN ('normal', 'light', 'emergency') THEN
        RAISE EXCEPTION 'Invalid mode: %. Must be normal, light, or emergency.', p_mode;
    END IF;
    v_current_interval := COALESCE(
        flight_recorder._get_config('sample_interval_seconds', '60')::integer,
        60
    );
    CASE p_mode
        WHEN 'normal' THEN
            v_enable_locks := TRUE;
            v_enable_progress := TRUE;
            v_sample_interval_seconds := 120;
            v_description := 'Normal mode: 120s sampling, all collectors enabled (4h retention)';
        WHEN 'light' THEN
            v_enable_locks := TRUE;
            v_enable_progress := FALSE;
            v_sample_interval_seconds := 120;
            v_description := 'Light mode: 120s sampling, progress disabled (4h retention, minimal overhead)';
        WHEN 'emergency' THEN
            v_enable_locks := FALSE;
            v_enable_progress := FALSE;
            v_sample_interval_seconds := 300;
            v_description := 'Emergency mode: 300s sampling, locks/progress disabled (10h retention, 60% less overhead)';
    END CASE;
    INSERT INTO flight_recorder.config (key, value, updated_at)
    VALUES ('mode', p_mode, now())
    ON CONFLICT (key) DO UPDATE SET value = p_mode, updated_at = now();
    INSERT INTO flight_recorder.config (key, value, updated_at)
    VALUES ('enable_locks', v_enable_locks::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_enable_locks::text, updated_at = now();
    INSERT INTO flight_recorder.config (key, value, updated_at)
    VALUES ('enable_progress', v_enable_progress::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_enable_progress::text, updated_at = now();
    INSERT INTO flight_recorder.config (key, value, updated_at)
    VALUES ('sample_interval_seconds', v_sample_interval_seconds::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_sample_interval_seconds::text, updated_at = now();
    BEGIN
        IF v_sample_interval_seconds < 60 THEN
            v_cron_expression := '* * * * *';
        ELSIF v_sample_interval_seconds = 60 THEN
            v_cron_expression := '* * * * *';
        ELSE
            v_sample_interval_minutes := CEILING(v_sample_interval_seconds::numeric / 60.0)::integer;
            v_cron_expression := format('*/%s * * * *', v_sample_interval_minutes);
        END IF;
        -- Only reschedule if the job exists (i.e., collection is enabled)
        IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_sample') THEN
            PERFORM cron.unschedule('flight_recorder_sample');
            PERFORM cron.schedule('flight_recorder_sample', v_cron_expression, 'SELECT flight_recorder.sample()');
        END IF;
    EXCEPTION
        WHEN undefined_table THEN NULL;
        WHEN undefined_function THEN NULL;
    END;
    RETURN v_description;
END;
$$;

-- Retrieve the current flight recorder operating mode and its associated configuration
-- Returns mode, sample interval, and feature flags for locks, progress, and statement tracking
CREATE OR REPLACE FUNCTION flight_recorder.get_mode()
RETURNS TABLE(
    mode                TEXT,
    sample_interval     TEXT,
    locks_enabled       BOOLEAN,
    progress_enabled    BOOLEAN,
    statements_enabled  TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        flight_recorder._get_config('mode', 'normal') AS mode,
        CASE flight_recorder._get_config('mode', 'normal')
            WHEN 'normal' THEN '* * * * *'
            WHEN 'light' THEN '* * * * *'
            WHEN 'emergency' THEN '120 seconds'
            ELSE 'unknown'
        END AS sample_interval,
        COALESCE(flight_recorder._get_config('enable_locks', 'true')::boolean, true) AS locks_enabled,
        COALESCE(flight_recorder._get_config('enable_progress', 'true')::boolean, true) AS progress_enabled,
        flight_recorder._get_config('statements_enabled', 'auto') AS statements_enabled
$$;

-- Lists the available monitoring profiles for flight recorder with their configurations, use cases, and overhead levels
CREATE OR REPLACE FUNCTION flight_recorder.list_profiles()
RETURNS TABLE(
    profile_name        TEXT,
    description         TEXT,
    use_case            TEXT,
    sample_interval     TEXT,
    overhead_level      TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT * FROM (VALUES
        ('default',
         'Balanced configuration for most users',
         'General purpose monitoring - staging, development, or production',
         '180s (6h retention)',
         'Minimal (~0.013% CPU)'),
        ('production_safe',
         'Ultra-conservative for production environments',
         'Production always-on monitoring with maximum safety',
         '300s (10h retention)',
         'Ultra-minimal (~0.008% CPU)'),
        ('development',
         'Balanced for staging and development',
         'Active development, testing, or staging environments',
         '180s (6h retention)',
         'Minimal (~0.013% CPU)'),
        ('troubleshooting',
         'Aggressive collection during incidents',
         'Active incident response - detailed data collection',
         '60s (2h retention)',
         'Low (~0.04% CPU)'),
        ('minimal_overhead',
         'Absolute minimum footprint',
         'Resource-constrained systems, replicas, or minimal monitoring',
         '300s (10h retention)',
         'Ultra-minimal (~0.008% CPU)')
    ) AS t(profile_name, description, use_case, sample_interval, overhead_level)
$$;

-- Returns ring buffer optimization profiles for different use cases
-- Profiles provide pre-configured ring_buffer_slots, sample_interval, and archive settings
CREATE OR REPLACE FUNCTION flight_recorder.get_optimization_profiles()
RETURNS TABLE(
    profile_name            TEXT,
    slots                   INTEGER,
    sample_interval_seconds INTEGER,
    archive_frequency_min   INTEGER,
    retention_hours         NUMERIC,
    description             TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT * FROM (VALUES
        ('standard',
         120, 180, 15,
         ROUND(120 * 180 / 3600.0, 1),
         'Default: 6h retention, 3min granularity, 0.014% CPU'),
        ('fine_grained',
         360, 60, 15,
         ROUND(360 * 60 / 3600.0, 1),
         'Fine: 6h retention, 1min granularity, 0.042% CPU'),
        ('ultra_fine',
         720, 30, 10,
         ROUND(720 * 30 / 3600.0, 1),
         'Ultra-fine: 6h retention, 30s granularity, 0.083% CPU'),
        ('low_overhead',
         72, 300, 30,
         ROUND(72 * 300 / 3600.0, 1),
         'Low overhead: 6h retention, 5min granularity, 0.008% CPU'),
        ('high_retention',
         240, 180, 30,
         ROUND(240 * 180 / 3600.0, 1),
         'High retention: 12h retention, 3min granularity, 0.014% CPU'),
        ('forensic',
         1440, 15, 5,
         ROUND(1440 * 15 / 3600.0, 1),
         'Forensic: 6h retention, 15s granularity, 0.167% CPU (temporary use only)')
    ) AS t(profile_name, slots, sample_interval_seconds, archive_frequency_min, retention_hours, description)
$$;
COMMENT ON FUNCTION flight_recorder.get_optimization_profiles() IS 'Returns ring buffer optimization profiles for different use cases. Profiles configure ring_buffer_slots, sample_interval_seconds, and archive_sample_frequency_minutes for specific monitoring scenarios.';

-- Applies a ring buffer optimization profile
-- Updates config values and warns if rebuild is needed
CREATE OR REPLACE FUNCTION flight_recorder.apply_optimization_profile(p_profile TEXT)
RETURNS TABLE(
    setting_key     TEXT,
    old_value       TEXT,
    new_value       TEXT,
    changed         BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_profile RECORD;
    v_old_slots TEXT;
    v_old_interval TEXT;
    v_old_archive TEXT;
    v_current_slots INTEGER;
    v_rebuild_needed BOOLEAN := false;
BEGIN
    -- Validate profile exists
    SELECT * INTO v_profile
    FROM flight_recorder.get_optimization_profiles()
    WHERE profile_name = p_profile;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown optimization profile: %. Available: standard, fine_grained, ultra_fine, low_overhead, high_retention, forensic', p_profile;
    END IF;

    -- Get current values
    v_old_slots := flight_recorder._get_config('ring_buffer_slots', '120');
    v_old_interval := flight_recorder._get_config('sample_interval_seconds', '180');
    v_old_archive := flight_recorder._get_config('archive_sample_frequency_minutes', '15');

    -- Check if rebuild will be needed
    SELECT COUNT(*) INTO v_current_slots FROM flight_recorder.samples_ring;
    IF v_current_slots != v_profile.slots THEN
        v_rebuild_needed := true;
    END IF;

    -- Update ring_buffer_slots
    INSERT INTO flight_recorder.config (key, value, updated_at)
    VALUES ('ring_buffer_slots', v_profile.slots::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_profile.slots::text, updated_at = now();

    RETURN QUERY SELECT
        'ring_buffer_slots'::text,
        v_old_slots,
        v_profile.slots::text,
        (v_old_slots IS DISTINCT FROM v_profile.slots::text);

    -- Update sample_interval_seconds
    INSERT INTO flight_recorder.config (key, value, updated_at)
    VALUES ('sample_interval_seconds', v_profile.sample_interval_seconds::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_profile.sample_interval_seconds::text, updated_at = now();

    RETURN QUERY SELECT
        'sample_interval_seconds'::text,
        v_old_interval,
        v_profile.sample_interval_seconds::text,
        (v_old_interval IS DISTINCT FROM v_profile.sample_interval_seconds::text);

    -- Update archive_sample_frequency_minutes
    INSERT INTO flight_recorder.config (key, value, updated_at)
    VALUES ('archive_sample_frequency_minutes', v_profile.archive_frequency_min::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_profile.archive_frequency_min::text, updated_at = now();

    RETURN QUERY SELECT
        'archive_sample_frequency_minutes'::text,
        v_old_archive,
        v_profile.archive_frequency_min::text,
        (v_old_archive IS DISTINCT FROM v_profile.archive_frequency_min::text);

    -- Warn if rebuild is needed
    IF v_rebuild_needed THEN
        RAISE WARNING 'Ring buffer slot count changed. Run flight_recorder.rebuild_ring_buffers() to resize. Data in ring buffers will be lost.';
    END IF;

    RAISE NOTICE 'Applied optimization profile: % (%)', p_profile, v_profile.description;
END;
$$;
COMMENT ON FUNCTION flight_recorder.apply_optimization_profile(TEXT) IS 'Applies a ring buffer optimization profile. Updates ring_buffer_slots, sample_interval_seconds, and archive_sample_frequency_minutes. Call rebuild_ring_buffers() after if slot count changed.';

-- Preview the configuration changes from applying a specified profile
-- Compares current settings against profile values to show impact before applying
CREATE OR REPLACE FUNCTION flight_recorder.explain_profile(p_profile_name TEXT)
RETURNS TABLE(
    setting_key         TEXT,
    current_value       TEXT,
    profile_value       TEXT,
    will_change         BOOLEAN,
    description         TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM flight_recorder.list_profiles() WHERE profile_name = p_profile_name) THEN
        RAISE EXCEPTION 'Unknown profile: %. Run flight_recorder.list_profiles() to see available profiles.', p_profile_name;
    END IF;
    RETURN QUERY
    SELECT
        ps.key::text AS setting_key,
        c.value::text AS current_value,
        ps.value::text AS profile_value,
        (c.value IS DISTINCT FROM ps.value)::boolean AS will_change,
        ps.description::text AS description
    FROM flight_recorder._profile_settings() ps
    LEFT JOIN flight_recorder.config c ON c.key = ps.key
    WHERE ps.profile = p_profile_name
    ORDER BY will_change DESC, ps.key;
END $$;

-- Applies a named configuration profile to flight_recorder by upserting configuration settings
-- Returns details of changed settings and adjusts recording mode based on the profile
CREATE OR REPLACE FUNCTION flight_recorder.apply_profile(p_profile_name TEXT)
RETURNS TABLE(
    setting_key     TEXT,
    old_value       TEXT,
    new_value       TEXT,
    changed         BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_mode TEXT;
    v_changes_made INTEGER := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM flight_recorder.list_profiles() WHERE profile_name = p_profile_name) THEN
        RAISE EXCEPTION 'Unknown profile: %. Run flight_recorder.list_profiles() to see available profiles.', p_profile_name;
    END IF;
    RAISE NOTICE 'Applying profile: %', p_profile_name;
    RETURN QUERY
    WITH profile_settings AS (
        SELECT ps.profile, ps.key, ps.value
        FROM flight_recorder._profile_settings() ps
        WHERE ps.profile = p_profile_name
    ),
    updates AS (
        INSERT INTO flight_recorder.config (key, value, updated_at)
        SELECT ps.key, ps.value, now()
        FROM profile_settings ps
        ON CONFLICT (key) DO UPDATE
        SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at
        WHERE flight_recorder.config.value IS DISTINCT FROM EXCLUDED.value
        RETURNING key, value
    )
    SELECT
        COALESCE(u.key, ps.key)::text AS setting_key,
        c.value::text AS old_value,
        ps.value::text AS new_value,
        (u.key IS NOT NULL)::boolean AS changed
    FROM profile_settings ps
    LEFT JOIN updates u ON u.key = ps.key
    LEFT JOIN flight_recorder.config c ON c.key = ps.key
    ORDER BY changed DESC, setting_key;
    GET DIAGNOSTICS v_changes_made = ROW_COUNT;
    v_mode := CASE p_profile_name
        WHEN 'production_safe' THEN 'emergency'
        WHEN 'minimal_overhead' THEN 'emergency'
        WHEN 'troubleshooting' THEN 'normal'
        ELSE 'normal'
    END;
    PERFORM flight_recorder.set_mode(v_mode);
    RAISE NOTICE 'Profile "%" applied: % settings changed, mode set to %',
        p_profile_name, v_changes_made, v_mode;
END $$;

-- Identifies the closest matching predefined profile for current configuration and returns match percentage with differences
-- Helps users understand their configuration state relative to available profiles
CREATE OR REPLACE FUNCTION flight_recorder.get_current_profile()
RETURNS TABLE(
    closest_profile     TEXT,
    match_percentage    NUMERIC,
    differences         TEXT[],
    recommendation      TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_profile RECORD;
    v_best_match TEXT;
    v_best_pct NUMERIC := 0;
    v_current_pct NUMERIC;
    v_diffs TEXT[];
BEGIN
    FOR v_profile IN SELECT profile_name FROM flight_recorder.list_profiles() LOOP
        WITH profile_settings AS (
            SELECT setting_key, profile_value
            FROM flight_recorder.explain_profile(v_profile.profile_name)
        ),
        matches AS (
            SELECT
                count(*) FILTER (WHERE NOT will_change) AS matched,
                count(*) AS total,
                array_agg(setting_key) FILTER (WHERE will_change) AS diff_keys
            FROM flight_recorder.explain_profile(v_profile.profile_name)
        )
        SELECT
            (matched::numeric / NULLIF(total, 0) * 100)::numeric(5,1),
            diff_keys
        INTO v_current_pct, v_diffs
        FROM matches;
        IF v_current_pct > v_best_pct THEN
            v_best_pct := v_current_pct;
            v_best_match := v_profile.profile_name;
        END IF;
    END LOOP;
    RETURN QUERY
    SELECT
        COALESCE(v_best_match, 'custom')::text,
        COALESCE(v_best_pct, 0)::numeric,
        (SELECT array_agg(setting_key) FROM flight_recorder.explain_profile(v_best_match) WHERE will_change)::text[],
        CASE
            WHEN v_best_pct = 100 THEN 'Configuration matches "' || v_best_match || '" profile perfectly'
            WHEN v_best_pct >= 80 THEN 'Configuration is close to "' || v_best_match || '" profile'
            WHEN v_best_pct >= 50 THEN 'Configuration is partially based on "' || v_best_match || '" profile'
            ELSE 'Configuration appears to be custom (not matching any profile)'
        END::text;
END $$;
DROP FUNCTION IF EXISTS flight_recorder.cleanup(INTERVAL);

-- Removes old snapshot and sample data based on configured retention periods
-- Cleans up snapshots, statement_snapshots, replication_snapshots tables
CREATE OR REPLACE FUNCTION flight_recorder.cleanup(p_retain_interval INTERVAL DEFAULT NULL)
RETURNS TABLE(
    deleted_snapshots   BIGINT,
    deleted_samples     BIGINT,
    deleted_statements  BIGINT,
    deleted_stats       BIGINT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_deleted_snapshots BIGINT;
    v_deleted_samples BIGINT;
    v_deleted_statements BIGINT;
    v_deleted_stats BIGINT;
    v_samples_retention_days INTEGER;
    v_snapshots_retention_days INTEGER;
    v_statements_retention_days INTEGER;
    v_stats_retention_days INTEGER;
    v_samples_cutoff TIMESTAMPTZ;
    v_snapshots_cutoff TIMESTAMPTZ;
    v_statements_cutoff TIMESTAMPTZ;
    v_stats_cutoff TIMESTAMPTZ;
BEGIN
    IF p_retain_interval IS NOT NULL THEN
        v_samples_cutoff := now() - p_retain_interval;
        v_snapshots_cutoff := now() - p_retain_interval;
        v_statements_cutoff := now() - p_retain_interval;
        v_stats_cutoff := now() - p_retain_interval;
    ELSE
        v_samples_retention_days := COALESCE(
            flight_recorder._get_config('retention_samples_days', '7')::integer,
            7
        );
        v_snapshots_retention_days := COALESCE(
            flight_recorder._get_config('retention_snapshots_days', '30')::integer,
            30
        );
        v_statements_retention_days := COALESCE(
            flight_recorder._get_config('retention_statements_days', '30')::integer,
            30
        );
        v_stats_retention_days := COALESCE(
            flight_recorder._get_config('retention_collection_stats_days', '30')::integer,
            30
        );
        v_samples_cutoff := now() - (v_samples_retention_days || ' days')::interval;
        v_snapshots_cutoff := now() - (v_snapshots_retention_days || ' days')::interval;
        v_statements_cutoff := now() - (v_statements_retention_days || ' days')::interval;
        v_stats_cutoff := now() - (v_stats_retention_days || ' days')::interval;
    END IF;
    v_deleted_samples := 0;
    WITH deleted AS (
        DELETE FROM flight_recorder.snapshots WHERE captured_at < v_snapshots_cutoff RETURNING 1
    )
    SELECT count(*) INTO v_deleted_snapshots FROM deleted;
    WITH deleted AS (
        DELETE FROM flight_recorder.statement_snapshots
        WHERE snapshot_id IN (
            SELECT id FROM flight_recorder.snapshots WHERE captured_at < v_statements_cutoff
        )
        RETURNING 1
    )
    SELECT count(*) INTO v_deleted_statements FROM deleted;
    WITH deleted AS (
        DELETE FROM flight_recorder.collection_stats WHERE started_at < v_stats_cutoff RETURNING 1
    )
    SELECT count(*) INTO v_deleted_stats FROM deleted;
    RETURN QUERY SELECT v_deleted_snapshots, v_deleted_samples, v_deleted_statements, v_deleted_stats;
END;
$$;
DROP FUNCTION IF EXISTS flight_recorder.ring_buffer_health();

-- Monitor ring buffer health: XID age, dead tuple bloat, HOT update effectiveness, and autovacuum status
CREATE OR REPLACE FUNCTION flight_recorder.ring_buffer_health()
RETURNS TABLE(
    table_name              TEXT,
    row_count               BIGINT,
    dead_tuples             BIGINT,
    dead_tuple_pct          NUMERIC,
    xid_age                 INTEGER,
    total_updates           BIGINT,
    hot_updates             BIGINT,
    hot_update_pct          NUMERIC,
    last_vacuum             TIMESTAMPTZ,
    last_autovacuum         TIMESTAMPTZ,
    autovacuum_threshold    BIGINT,
    needs_vacuum            BOOLEAN,
    status                  TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        c.relname::text,
        s.n_live_tup,
        s.n_dead_tup,
        CASE
            WHEN s.n_live_tup > 0 THEN round(100.0 * s.n_dead_tup / NULLIF(s.n_live_tup, 0), 1)
            ELSE 0
        END,
        age(c.relfrozenxid)::integer,
        s.n_tup_upd,
        s.n_tup_hot_upd,
        CASE
            WHEN s.n_tup_upd > 0 THEN round(100.0 * s.n_tup_hot_upd / NULLIF(s.n_tup_upd, 0), 1)
            ELSE 0
        END,
        s.last_vacuum,
        s.last_autovacuum,
        (50 + (0.2 * s.n_live_tup)::bigint),
        s.n_dead_tup > (50 + (0.2 * s.n_live_tup)::bigint),
        CASE
            WHEN age(c.relfrozenxid) > 200000000 THEN 'CRITICAL: XID wraparound risk'
            WHEN age(c.relfrozenxid) > 100000000 THEN 'WARNING: High XID age'
            WHEN c.relname = 'samples_ring' AND s.n_tup_upd > 100 AND (100.0 * s.n_tup_hot_upd / NULLIF(s.n_tup_upd, 0)) < 50 THEN 'WARNING: Low HOT update ratio'
            WHEN s.n_dead_tup > (50 + (0.2 * s.n_live_tup)::bigint) THEN 'INFO: Autovacuum pending'
            ELSE 'OK'
        END::text
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE n.nspname = 'flight_recorder'
      AND c.relkind = 'r'
      AND c.relname IN ('samples_ring', 'wait_samples_ring', 'activity_samples_ring', 'lock_samples_ring')
    ORDER BY c.relname;
$$;
COMMENT ON FUNCTION flight_recorder.ring_buffer_health() IS

'Monitor ring buffer XID age, dead tuple bloat, and HOT update effectiveness. samples_ring uses UPSERT (1,440x/day) and should achieve >90% HOT update ratio with fillfactor=70. Child tables use DELETE/INSERT so HOT updates are N/A.';
-- Disable Flight Recorder by unscheduling all cron jobs and updating the enabled configuration flag to false
CREATE OR REPLACE FUNCTION flight_recorder.disable()
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_unscheduled INTEGER := 0;
BEGIN
    BEGIN
        PERFORM cron.unschedule('flight_recorder_snapshot')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_snapshot');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('flight_recorder_sample')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_sample');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('flight_recorder_cleanup')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_cleanup');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('flight_recorder_flush')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_flush');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('flight_recorder_archive')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_archive');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        INSERT INTO flight_recorder.config (key, value, updated_at)
        VALUES ('enabled', 'false', now())
        ON CONFLICT (key) DO UPDATE SET value = 'false', updated_at = now();
        RETURN format('Flight Recorder collection stopped. Unscheduled %s cron jobs. Use flight_recorder.enable() to restart.', v_unscheduled);
    EXCEPTION
        WHEN undefined_table THEN
            RETURN 'pg_cron extension not found. No jobs to unschedule.';
        WHEN undefined_function THEN
            RETURN 'pg_cron extension not found. No jobs to unschedule.';
    END;
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

-- Configure autovacuum on ring buffer tables
-- Ring buffers use pre-allocated rows with UPDATE-only pattern, achieving high HOT update ratios.
-- With fillfactor 70-90, most updates are HOT (no dead tuples in indexes), but tuple chains still
-- form within pages. Autovacuum collapses these chains. Since ring buffers are fixed-size UNLOGGED
-- tables with bounded bloat, autovacuum is optional - page pruning during UPSERTs provides cleanup.
-- Autovacuum enabled by default; disable for minimal observer effect if desired.
CREATE OR REPLACE FUNCTION flight_recorder.configure_ring_autovacuum(p_enabled BOOLEAN DEFAULT true)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    EXECUTE format('ALTER TABLE flight_recorder.samples_ring SET (autovacuum_enabled = %L)', p_enabled);
    EXECUTE format('ALTER TABLE flight_recorder.wait_samples_ring SET (autovacuum_enabled = %L)', p_enabled);
    EXECUTE format('ALTER TABLE flight_recorder.activity_samples_ring SET (autovacuum_enabled = %L)', p_enabled);
    EXECUTE format('ALTER TABLE flight_recorder.lock_samples_ring SET (autovacuum_enabled = %L)', p_enabled);

    IF p_enabled THEN
        v_status := 'Autovacuum ENABLED on ring buffer tables. Autovacuum will periodically collapse HOT chains.';
    ELSE
        v_status := 'Autovacuum DISABLED on ring buffer tables. Page pruning during UPSERTs handles cleanup.';
    END IF;

    RETURN v_status;
END;
$$;

COMMENT ON FUNCTION flight_recorder.configure_ring_autovacuum(BOOLEAN) IS
'Toggle autovacuum on ring buffer tables. Enabled by default (PostgreSQL standard behavior). Ring buffers are fixed-size UNLOGGED tables with bounded bloat, so autovacuum can be disabled to minimize observer effect if desired.';

-- Rebuilds ring buffers to match configured slot count
-- WARNING: This clears all data in ring buffers (archives and aggregates are preserved)
CREATE OR REPLACE FUNCTION flight_recorder.rebuild_ring_buffers(p_slots INTEGER DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_target_slots INTEGER;
    v_current_slots INTEGER;
    v_autovacuum_enabled BOOLEAN := true;
BEGIN
    -- Get target slot count from param or config
    v_target_slots := COALESCE(p_slots, flight_recorder._get_ring_buffer_slots());

    -- Validate range
    IF v_target_slots < 72 OR v_target_slots > 2880 THEN
        RAISE EXCEPTION 'Ring buffer slots must be between 72 and 2880. Got: %', v_target_slots;
    END IF;

    -- Get current slot count
    SELECT COUNT(*) INTO v_current_slots FROM flight_recorder.samples_ring;

    -- Check if resize is needed
    IF v_current_slots = v_target_slots THEN
        RETURN format('Ring buffers already sized for %s slots. No rebuild needed.', v_target_slots);
    END IF;

    -- Preserve autovacuum setting
    SELECT COALESCE(
        (SELECT reloptions::text LIKE '%autovacuum_enabled=false%'
         FROM pg_class WHERE relname = 'samples_ring' AND relnamespace = 'flight_recorder'::regnamespace),
        false
    ) INTO v_autovacuum_enabled;
    v_autovacuum_enabled := NOT v_autovacuum_enabled;  -- Invert because we checked for false

    RAISE NOTICE 'Rebuilding ring buffers from % to % slots...', v_current_slots, v_target_slots;

    -- TRUNCATE CASCADE clears all child tables via FK
    TRUNCATE flight_recorder.samples_ring CASCADE;

    -- Rebuild samples_ring
    INSERT INTO flight_recorder.samples_ring (slot_id, captured_at, epoch_seconds)
    SELECT
        generate_series AS slot_id,
        '1970-01-01'::timestamptz,
        0
    FROM generate_series(0, v_target_slots - 1);

    -- Rebuild wait_samples_ring
    INSERT INTO flight_recorder.wait_samples_ring (slot_id, row_num)
    SELECT s.slot_id, r.row_num
    FROM generate_series(0, v_target_slots - 1) s(slot_id)
    CROSS JOIN generate_series(0, 99) r(row_num);

    -- Rebuild activity_samples_ring
    INSERT INTO flight_recorder.activity_samples_ring (slot_id, row_num)
    SELECT s.slot_id, r.row_num
    FROM generate_series(0, v_target_slots - 1) s(slot_id)
    CROSS JOIN generate_series(0, 24) r(row_num);

    -- Rebuild lock_samples_ring
    INSERT INTO flight_recorder.lock_samples_ring (slot_id, row_num)
    SELECT s.slot_id, r.row_num
    FROM generate_series(0, v_target_slots - 1) s(slot_id)
    CROSS JOIN generate_series(0, 99) r(row_num);

    -- Restore autovacuum setting
    IF NOT v_autovacuum_enabled THEN
        PERFORM flight_recorder.configure_ring_autovacuum(false);
    END IF;

    -- Update config if p_slots was provided
    IF p_slots IS NOT NULL THEN
        INSERT INTO flight_recorder.config (key, value, updated_at)
        VALUES ('ring_buffer_slots', p_slots::text, now())
        ON CONFLICT (key) DO UPDATE SET value = p_slots::text, updated_at = now();
    END IF;

    RETURN format('Ring buffers rebuilt: %s → %s slots. Tables: samples_ring (%s), wait_samples_ring (%s), activity_samples_ring (%s), lock_samples_ring (%s)',
        v_current_slots, v_target_slots,
        v_target_slots,
        v_target_slots * 100,
        v_target_slots * 25,
        v_target_slots * 100);
END;
$$;
COMMENT ON FUNCTION flight_recorder.rebuild_ring_buffers(INTEGER) IS 'Rebuilds ring buffers to match configured slot count (72-2880). WARNING: Clears all ring buffer data. Archives and aggregates are preserved. Pass slot count as parameter or use ring_buffer_slots config.';

-- Enables flight recorder by scheduling periodic cron jobs for collection, archival, and cleanup
-- Requires pg_cron extension; returns status message on success
CREATE OR REPLACE FUNCTION flight_recorder.enable()
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_mode TEXT;
    v_pgcron_version TEXT;
    v_supports_subsecond BOOLEAN := FALSE;
    v_sample_schedule TEXT;
    v_scheduled INTEGER := 0;
    v_sample_interval_seconds INTEGER;
    v_sample_interval_minutes INTEGER;
    v_cron_expression TEXT;
BEGIN
    v_mode := flight_recorder._get_config('mode', 'normal');
    v_sample_interval_seconds := COALESCE(
        flight_recorder._get_config('sample_interval_seconds', '60')::integer,
        60
    );
    BEGIN
        SELECT extversion INTO v_pgcron_version FROM pg_extension WHERE extname = 'pg_cron';
        IF v_pgcron_version IS NULL THEN
            RETURN 'pg_cron extension not found. Cannot schedule automatic collection.';
        END IF;
        v_pgcron_version := split_part(v_pgcron_version, '-', 1);
        v_supports_subsecond := (
            split_part(v_pgcron_version, '.', 1)::int > 1 OR
            (split_part(v_pgcron_version, '.', 1)::int = 1 AND
             split_part(v_pgcron_version, '.', 2)::int > 4) OR
            (split_part(v_pgcron_version, '.', 1)::int = 1 AND
             split_part(v_pgcron_version, '.', 2)::int = 4 AND
             COALESCE(NULLIF(split_part(v_pgcron_version, '.', 3), '')::int, 0) >= 1)
        );
        PERFORM cron.schedule('flight_recorder_snapshot', '*/5 * * * *', 'SELECT flight_recorder.snapshot()');
        v_scheduled := v_scheduled + 1;
        IF v_sample_interval_seconds <= 60 THEN
            v_cron_expression := '* * * * *';
            v_sample_schedule := 'every 60 seconds';
        ELSIF v_sample_interval_seconds % 60 = 0 THEN
            v_sample_interval_minutes := v_sample_interval_seconds / 60;
            v_cron_expression := format('*/%s * * * *', v_sample_interval_minutes);
            v_sample_schedule := format('every %s seconds', v_sample_interval_seconds);
        ELSE
            v_sample_interval_minutes := CEILING(v_sample_interval_seconds::numeric / 60.0)::integer;
            v_cron_expression := format('*/%s * * * *', v_sample_interval_minutes);
            v_sample_schedule := format('approximately every %s seconds', v_sample_interval_seconds);
        END IF;
        PERFORM cron.schedule('flight_recorder_sample', v_cron_expression, 'SELECT flight_recorder.sample()');
        v_scheduled := v_scheduled + 1;
        PERFORM cron.schedule('flight_recorder_flush', '*/5 * * * *', 'SELECT flight_recorder.flush_ring_to_aggregates()');
        v_scheduled := v_scheduled + 1;
        PERFORM cron.schedule('flight_recorder_archive', '*/15 * * * *', 'SELECT flight_recorder.archive_ring_samples()');
        v_scheduled := v_scheduled + 1;
        PERFORM cron.schedule('flight_recorder_cleanup', '0 3 * * *',
            'SELECT flight_recorder.cleanup_aggregates(); SELECT * FROM flight_recorder.cleanup(''30 days''::interval);');
        v_scheduled := v_scheduled + 1;
        INSERT INTO flight_recorder.config (key, value, updated_at)
        VALUES ('enabled', 'true', now())
        ON CONFLICT (key) DO UPDATE SET value = 'true', updated_at = now();
        -- Emit warnings for suboptimal ring buffer configuration
        DECLARE
            v_check RECORD;
        BEGIN
            FOR v_check IN
                SELECT * FROM flight_recorder.validate_ring_configuration()
                WHERE status IN ('WARNING', 'ERROR')
            LOOP
                RAISE WARNING '% [%]: % - %', v_check.check_name, v_check.status, v_check.message, v_check.recommendation;
            END LOOP;
        EXCEPTION WHEN OTHERS THEN
            -- Don't fail enable() if validation has issues
            NULL;
        END;
        RETURN format('Flight Recorder collection restarted. Scheduled %s cron jobs in %s mode (sample: %s).',
                     v_scheduled, v_mode, v_sample_schedule);
    EXCEPTION
        WHEN undefined_table THEN
            RETURN 'pg_cron extension not found. Cannot schedule automatic collection.';
        WHEN undefined_function THEN
            RETURN 'pg_cron extension not found. Cannot schedule automatic collection.';
    END;
END;
$$;
DO $$
DECLARE
    v_pgcron_version TEXT;
    v_major INT;
    v_minor INT;
    v_patch INT;
    v_supports_subsecond BOOLEAN := FALSE;
    v_sample_schedule TEXT;
    v_sample_interval_seconds INTEGER;
    v_sample_interval_minutes INTEGER;
    v_cron_expression TEXT;
BEGIN
    BEGIN
        PERFORM cron.unschedule('flight_recorder_snapshot')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_snapshot');
        PERFORM cron.unschedule('flight_recorder_sample')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_sample');
        PERFORM cron.unschedule('flight_recorder_flush')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_flush');
        PERFORM cron.unschedule('flight_recorder_cleanup')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'flight_recorder_cleanup');
    EXCEPTION
        WHEN undefined_table THEN NULL;
        WHEN undefined_function THEN NULL;
    END;
    SELECT value::integer INTO v_sample_interval_seconds
    FROM flight_recorder.config
    WHERE key = 'sample_interval_seconds';
    v_sample_interval_seconds := COALESCE(v_sample_interval_seconds, 120);
    SELECT extversion INTO v_pgcron_version
    FROM pg_extension WHERE extname = 'pg_cron';
    IF v_pgcron_version IS NOT NULL THEN
        v_pgcron_version := split_part(v_pgcron_version, '-', 1);
        v_major := COALESCE(split_part(v_pgcron_version, '.', 1)::int, 0);
        v_minor := COALESCE(NULLIF(split_part(v_pgcron_version, '.', 2), '')::int, 0);
        v_patch := COALESCE(NULLIF(split_part(v_pgcron_version, '.', 3), '')::int, 0);
        v_supports_subsecond := (v_major > 1)
            OR (v_major = 1 AND v_minor > 4)
            OR (v_major = 1 AND v_minor = 4 AND v_patch >= 1);
    END IF;
    PERFORM cron.schedule(
        'flight_recorder_snapshot',
        '*/5 * * * *',
        'SELECT flight_recorder.snapshot()'
    );
    PERFORM cron.schedule(
        'flight_recorder_sample',
        '*/2 * * * *',
        'SELECT flight_recorder.sample()'
    );
    v_sample_schedule := 'every 120 seconds (ring buffer)';
    RAISE NOTICE 'Flight Recorder installed. Sampling %', v_sample_schedule;
    PERFORM cron.schedule(
        'flight_recorder_flush',
        '*/5 * * * *',
        'SELECT flight_recorder.flush_ring_to_aggregates()'
    );
    PERFORM cron.schedule(
        'flight_recorder_archive',
        '*/15 * * * *',
        'SELECT flight_recorder.archive_ring_samples()'
    );
    PERFORM cron.schedule(
        'flight_recorder_cleanup',
        '0 3 * * *',
        'SELECT flight_recorder.cleanup_aggregates(); SELECT * FROM flight_recorder.cleanup(''30 days''::interval);'
    );
EXCEPTION
    WHEN undefined_table THEN
        RAISE NOTICE 'pg_cron extension not found. Automatic scheduling disabled. Run flight_recorder.snapshot() and flight_recorder.sample() manually or via external scheduler.';
    WHEN undefined_function THEN
        RAISE NOTICE 'pg_cron extension not found. Automatic scheduling disabled. Run flight_recorder.snapshot() and flight_recorder.sample() manually or via external scheduler.';
END;
$$;

-- Performs comprehensive health check of Flight Recorder system components
-- Reports status, metrics, and recommended actions for critical subsystems
CREATE OR REPLACE FUNCTION flight_recorder.health_check()
RETURNS TABLE(
    component TEXT,
    status TEXT,
    details TEXT,
    action_required TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled TEXT;
    v_schema_size_mb NUMERIC;
    v_schema_critical_mb INTEGER;
    v_recent_trips INTEGER;
    v_last_sample TIMESTAMPTZ;
    v_last_snapshot TIMESTAMPTZ;
    v_sample_count INTEGER;
    v_snapshot_count INTEGER;
BEGIN
    v_enabled := flight_recorder._get_config('enabled', 'true');
    IF v_enabled = 'false' THEN
        RETURN QUERY SELECT
            'Flight Recorder System'::text,
            'DISABLED'::text,
            'Collection is disabled'::text,
            'Run flight_recorder.enable() to restart'::text;
        RETURN;
    END IF;
    RETURN QUERY SELECT
        'Flight Recorder System'::text,
        'ENABLED'::text,
        format('Mode: %s', flight_recorder._get_config('mode', 'normal')),
        NULL::text;
    SELECT s.schema_size_mb, s.critical_threshold_mb, s.status
    INTO v_schema_size_mb, v_schema_critical_mb, v_enabled
    FROM flight_recorder._check_schema_size() s;
    RETURN QUERY SELECT
        'Schema Size'::text,
        v_enabled::text,
        format('%s MB / %s MB (%s%%)',
               round(v_schema_size_mb, 2)::text,
               v_schema_critical_mb::text,
               round((v_schema_size_mb / NULLIF(v_schema_critical_mb, 0)) * 100, 1)::text),
        CASE
            WHEN v_enabled = 'CRITICAL' THEN 'Run cleanup() immediately'
            WHEN v_enabled = 'WARNING' THEN 'Schedule cleanup() soon'
            ELSE NULL
        END::text;
    SELECT count(*)
    INTO v_recent_trips
    FROM flight_recorder.collection_stats
    WHERE skipped = true
      AND started_at > now() - interval '1 hour'
      AND skipped_reason LIKE '%Circuit breaker%';
    RETURN QUERY SELECT
        'Circuit Breaker'::text,
        CASE
            WHEN v_recent_trips = 0 THEN 'OK'
            WHEN v_recent_trips < 3 THEN 'WARNING'
            ELSE 'CRITICAL'
        END::text,
        format('%s trips in last hour', v_recent_trips),
        CASE
            WHEN v_recent_trips >= 3 THEN 'System under stress - consider emergency mode'
            ELSE NULL
        END::text;
    SELECT max(captured_at) INTO v_last_sample FROM flight_recorder.samples_ring;
    SELECT max(captured_at) INTO v_last_snapshot FROM flight_recorder.snapshots;
    RETURN QUERY SELECT
        'Sample Collection'::text,
        CASE
            WHEN v_last_sample IS NULL THEN 'ERROR'
            WHEN v_last_sample > now() - interval '5 minutes' THEN 'OK'
            WHEN v_last_sample > now() - interval '15 minutes' THEN 'WARNING'
            ELSE 'CRITICAL'
        END::text,
        CASE
            WHEN v_last_sample IS NULL THEN 'No samples collected'
            ELSE format('Last: %s ago', age(now(), v_last_sample))
        END,
        CASE
            WHEN v_last_sample IS NULL OR v_last_sample < now() - interval '15 minutes'
            THEN 'Check pg_cron jobs'
            ELSE NULL
        END::text;
    RETURN QUERY SELECT
        'Snapshot Collection'::text,
        CASE
            WHEN v_last_snapshot IS NULL THEN 'ERROR'
            WHEN v_last_snapshot > now() - interval '10 minutes' THEN 'OK'
            WHEN v_last_snapshot > now() - interval '30 minutes' THEN 'WARNING'
            ELSE 'CRITICAL'
        END::text,
        CASE
            WHEN v_last_snapshot IS NULL THEN 'No snapshots collected'
            ELSE format('Last: %s ago', age(now(), v_last_snapshot))
        END,
        CASE
            WHEN v_last_snapshot IS NULL OR v_last_snapshot < now() - interval '30 minutes'
            THEN 'Check pg_cron jobs'
            ELSE NULL
        END::text;
    SELECT count(*) INTO v_sample_count FROM flight_recorder.samples_ring;
    SELECT count(*) INTO v_snapshot_count FROM flight_recorder.snapshots;
    RETURN QUERY SELECT
        'Data Volume'::text,
        'INFO'::text,
        format('Samples: %s, Snapshots: %s', v_sample_count, v_snapshot_count),
        NULL::text;
    RETURN QUERY SELECT
        'pg_stat_statements'::text,
        CASE h.status
            WHEN 'DISABLED' THEN 'N/A'
            WHEN 'OK' THEN 'Healthy'
            WHEN 'WARNING' THEN 'Warning'
            WHEN 'HIGH_CHURN' THEN 'Degraded'
            ELSE 'Unknown'
        END::text,
        CASE
            WHEN h.status = 'DISABLED' THEN 'Extension not available'
            ELSE format('Utilization: %s%% (%s/%s statements)',
                       h.utilization_pct::text,
                       h.current_statements::text,
                       h.max_statements::text)
        END,
        CASE
            WHEN h.status = 'HIGH_CHURN' THEN 'Increase pg_stat_statements.max'
            WHEN h.status = 'WARNING' THEN 'Monitor for increased churn'
            ELSE NULL
        END::text
    FROM flight_recorder._check_statements_health() h;
    DECLARE
        v_job_count INTEGER;
        v_active_jobs INTEGER;
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
            count(*) FILTER (WHERE j.jobid IS NOT NULL AND j.active),
            array_agg(r.job_name) FILTER (WHERE j.jobid IS NULL),
            array_agg(r.job_name) FILTER (WHERE j.jobid IS NOT NULL AND NOT j.active)
        INTO v_job_count, v_active_jobs, v_missing_jobs, v_inactive_jobs
        FROM required_jobs r
        LEFT JOIN cron.job j ON j.jobname = r.job_name;
        RETURN QUERY SELECT
            'pg_cron Jobs'::text,
            CASE
                WHEN v_job_count > 0 THEN 'CRITICAL'
                WHEN v_active_jobs < 4 THEN 'CRITICAL'
                WHEN v_active_jobs = 4 THEN 'OK'
                ELSE 'UNKNOWN'
            END::text,
            CASE
                WHEN v_job_count > 0 THEN
                    format('%s/%s jobs missing: %s', v_job_count, 4, array_to_string(v_missing_jobs, ', '))
                WHEN v_active_jobs < 4 THEN
                    format('%s/%s jobs inactive: %s', 4 - v_active_jobs, 4, array_to_string(v_inactive_jobs, ', '))
                ELSE '4/4 jobs active and running'
            END,
            CASE
                WHEN v_job_count > 0 OR v_active_jobs < 4 THEN
                    'Run flight_recorder.enable() to restore missing/inactive jobs'
                ELSE NULL
            END::text;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT
            'pg_cron Jobs'::text,
            'ERROR'::text,
            format('Failed to check pg_cron jobs: %s', SQLERRM),
            'Verify pg_cron extension is installed and accessible'::text;
    END;
END;
$$;

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
                COALESCE(to_char(v_row.wal_bytes, 'FM999,999,999,999'), '-') || ' | ' ||
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

-- Exports all data before an upgrade, saving to a file for backup
-- Returns summary of what was exported and the recommended restore command
CREATE OR REPLACE FUNCTION flight_recorder.export_for_upgrade()
RETURNS TABLE(
    data_type TEXT,
    row_count BIGINT,
    date_range TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_version TEXT;
BEGIN
    SELECT value INTO v_version FROM flight_recorder.config WHERE key = 'schema_version';

    RAISE NOTICE '';
    RAISE NOTICE '=== Flight Recorder Export for Upgrade ===';
    RAISE NOTICE 'Current version: %', COALESCE(v_version, 'unknown');
    RAISE NOTICE '';
    RAISE NOTICE 'To export all data, run:';
    RAISE NOTICE '  psql -At -c "SELECT flight_recorder.report(now() - interval ''30 days'', now())" > backup.md';
    RAISE NOTICE '';
    RAISE NOTICE 'Or for specific tables:';
    RAISE NOTICE '  pg_dump -t flight_recorder.snapshots -t flight_recorder.statement_snapshots ... > backup.sql';
    RAISE NOTICE '';

    -- Return summary of data that would be exported
    RETURN QUERY
    SELECT 'snapshots'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM flight_recorder.snapshots;

    RETURN QUERY
    SELECT 'statement_snapshots'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM flight_recorder.statement_snapshots;

    RETURN QUERY
    SELECT 'table_snapshots'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM flight_recorder.table_snapshots;

    RETURN QUERY
    SELECT 'index_snapshots'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM flight_recorder.index_snapshots;

    RETURN QUERY
    SELECT 'activity_samples_archive'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM flight_recorder.activity_samples_archive;

    RETURN QUERY
    SELECT 'lock_samples_archive'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM flight_recorder.lock_samples_archive;

    RETURN QUERY
    SELECT 'wait_samples_archive'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM flight_recorder.wait_samples_archive;

    RETURN QUERY
    SELECT 'wait_event_aggregates'::TEXT, count(*)::BIGINT,
           min(window_start)::TEXT || ' to ' || max(window_end)::TEXT
    FROM flight_recorder.wait_event_aggregates;

    RETURN QUERY
    SELECT 'activity_aggregates'::TEXT, count(*)::BIGINT,
           min(window_start)::TEXT || ' to ' || max(window_end)::TEXT
    FROM flight_recorder.activity_aggregates;

    RETURN QUERY
    SELECT 'lock_aggregates'::TEXT, count(*)::BIGINT,
           min(window_start)::TEXT || ' to ' || max(window_end)::TEXT
    FROM flight_recorder.lock_aggregates;

    RETURN QUERY
    SELECT 'config'::TEXT, count(*)::BIGINT,
           'current settings'::TEXT
    FROM flight_recorder.config;
END;
$$;

-- Analyzes current metrics (schema size, sample duration, retention settings) and returns configuration optimization recommendations
-- Provides actionable SQL commands for performance, storage, and automation tuning
CREATE OR REPLACE FUNCTION flight_recorder.config_recommendations()
RETURNS TABLE(
    category TEXT,
    recommendation TEXT,
    reason TEXT,
    sql_command TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_mode TEXT;
    v_schema_size_mb NUMERIC;
    v_avg_sample_ms NUMERIC;
    v_sample_count INTEGER;
    v_snapshot_count INTEGER;
    v_retention_samples INTEGER;
    v_retention_snapshots INTEGER;
BEGIN
    v_mode := flight_recorder._get_config('mode', 'normal');
    SELECT schema_size_mb INTO v_schema_size_mb FROM flight_recorder._check_schema_size();
    SELECT count(*) INTO v_sample_count FROM flight_recorder.samples_ring;
    SELECT count(*) INTO v_snapshot_count FROM flight_recorder.snapshots;
    SELECT avg(duration_ms) INTO v_avg_sample_ms
    FROM flight_recorder.collection_stats
    WHERE collection_type = 'sample'
      AND success = true
      AND skipped = false
      AND started_at > now() - interval '24 hours';
    v_retention_samples := flight_recorder._get_config('retention_samples_days', '7')::integer;
    v_retention_snapshots := flight_recorder._get_config('retention_snapshots_days', '30')::integer;
    IF v_avg_sample_ms > 1000 AND v_mode = 'normal' THEN
        RETURN QUERY SELECT
            'Performance'::text,
            'Switch to light mode'::text,
            format('Average sample duration is %s ms, which may impact system performance', round(v_avg_sample_ms)),
            'SELECT flight_recorder.set_mode(''light'');'::text;
    END IF;
    IF v_schema_size_mb > 5000 THEN
        RETURN QUERY SELECT
            'Storage'::text,
            'Run cleanup to reclaim space'::text,
            format('Schema size is %s MB', round(v_schema_size_mb)::text),
            'SELECT * FROM flight_recorder.cleanup();'::text;
    END IF;
    IF v_sample_count > 50000 AND v_retention_samples > 7 THEN
        RETURN QUERY SELECT
            'Storage'::text,
            'Reduce sample retention period'::text,
            format('High sample count (%s) with %s day retention', v_sample_count, v_retention_samples),
            format('UPDATE flight_recorder.config SET value = ''3'' WHERE key = ''retention_samples_days'';')::text;
    END IF;
    IF v_avg_sample_ms > 500 AND flight_recorder._get_config('auto_mode_enabled', 'false') = 'false' THEN
        RETURN QUERY SELECT
            'Automation'::text,
            'Enable automatic mode switching'::text,
            'Sample duration varies significantly - auto-mode can help reduce overhead during peaks'::text,
            'UPDATE flight_recorder.config SET value = ''true'' WHERE key = ''auto_mode_enabled'';'::text;
    END IF;
    IF NOT FOUND THEN
        RETURN QUERY SELECT
            'System Health'::text,
            'Configuration looks optimal'::text,
            'No configuration changes recommended at this time'::text,
            NULL::text;
    END IF;
END;
$$;

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


SELECT flight_recorder.snapshot();
SELECT flight_recorder.sample();
DO $$
DECLARE
    v_sample_schedule TEXT;
BEGIN
    SELECT schedule INTO v_sample_schedule
    FROM cron.job WHERE jobname = 'flight_recorder_sample';
    RAISE NOTICE '';
    RAISE NOTICE 'Flight Recorder installed successfully.';
    RAISE NOTICE '';
    RAISE NOTICE 'Collection schedule:';
    RAISE NOTICE '  - Snapshots: every 5 minutes (WAL, checkpoints, I/O stats) - DURABLE';
    RAISE NOTICE '  - Samples: every 120 seconds (ring buffer, 120 slots, 4-hour retention)';
    RAISE NOTICE '  - Flush: every 5 minutes (ring buffer → durable aggregates)';
    RAISE NOTICE '  - Cleanup: daily at 3 AM (aggregates: 7 days, snapshots: 30 days)';
    RAISE NOTICE '';
    RAISE NOTICE 'Quick start:';
    RAISE NOTICE '  1. Flight Recorder collects automatically in the background';
    RAISE NOTICE '';
    RAISE NOTICE '  2. Query any time window to diagnose performance:';
    RAISE NOTICE '     SELECT * FROM flight_recorder.compare(''2024-12-16 14:00'', ''2024-12-16 15:00'');';
    RAISE NOTICE '     SELECT * FROM flight_recorder.wait_summary(''2024-12-16 14:00'', ''2024-12-16 15:00'');';
    RAISE NOTICE '';
    RAISE NOTICE '  3. Check capacity and right-sizing:';
    RAISE NOTICE '     SELECT * FROM flight_recorder.capacity_dashboard;';
    RAISE NOTICE '     SELECT * FROM flight_recorder.capacity_summary(interval ''7 days'');';
    RAISE NOTICE '';
    RAISE NOTICE 'Views for recent activity:';
    RAISE NOTICE '  - flight_recorder.deltas            (snapshot deltas incl. temp files)';
    RAISE NOTICE '  - flight_recorder.recent_waits      (wait events, last 2 hours from ring buffer)';
    RAISE NOTICE '  - flight_recorder.recent_activity   (active sessions, last 2 hours from ring buffer)';
    RAISE NOTICE '  - flight_recorder.recent_locks      (lock contention, last 2 hours from ring buffer)';
    RAISE NOTICE '  - flight_recorder.recent_replication (replication lag, last 2 hours)';
    RAISE NOTICE '';
END;
$$;
COMMIT;
