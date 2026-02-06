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
    RAISE NOTICE 'For analysis & reporting functions (anomaly detection, capacity planning, etc.):';
    RAISE NOTICE '  psql -f reporting.sql';
    RAISE NOTICE '';
END;
$$;
COMMIT;
