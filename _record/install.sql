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
CREATE TABLE IF NOT EXISTS pgfr_record.snapshots (
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
CREATE INDEX IF NOT EXISTS snapshots_captured_at_idx ON pgfr_record.snapshots(captured_at);

-- Captures replication metrics from pg_stat_replication for each snapshot
-- Tracks streaming replication connection state, LSN positions, and lag for each replica
-- Each record represents a single replication connection at a point in time
CREATE TABLE IF NOT EXISTS pgfr_record.replication_snapshots (
    snapshot_id             INTEGER REFERENCES pgfr_record.snapshots(id) ON DELETE CASCADE,
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
CREATE TABLE IF NOT EXISTS pgfr_record.vacuum_progress_snapshots (
    snapshot_id         INTEGER REFERENCES pgfr_record.snapshots(id) ON DELETE CASCADE,
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
COMMENT ON TABLE pgfr_record.vacuum_progress_snapshots IS 'Vacuum progress snapshots from pg_stat_progress_vacuum for monitoring long-running vacuums';

-- Stores execution statistics for SQL statements at specific snapshot points
-- Captures query performance metrics (timing, I/O, WAL activity) per query/user/database
-- Linked to snapshots via FK; enables historical analysis and performance trending
CREATE TABLE IF NOT EXISTS pgfr_record.statement_snapshots (
    snapshot_id         INTEGER REFERENCES pgfr_record.snapshots(id) ON DELETE CASCADE,
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
    calls_delta                 BIGINT,
    total_exec_time_delta       DOUBLE PRECISION,
    rows_delta                  BIGINT,
    shared_blks_hit_delta       BIGINT,
    shared_blks_read_delta      BIGINT,
    shared_blks_dirtied_delta   BIGINT,
    shared_blks_written_delta   BIGINT,
    temp_blks_read_delta        BIGINT,
    temp_blks_written_delta     BIGINT,
    blk_read_time_delta         DOUBLE PRECISION,
    blk_write_time_delta        DOUBLE PRECISION,
    wal_records_delta           BIGINT,
    wal_bytes_delta             NUMERIC,
    PRIMARY KEY (snapshot_id, queryid, dbid)
);
CREATE INDEX IF NOT EXISTS statement_snapshots_queryid_idx
    ON pgfr_record.statement_snapshots(queryid);

-- Add delta columns to existing installations (additive-only upgrade)
DO $$
BEGIN
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS calls_delta BIGINT;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS total_exec_time_delta DOUBLE PRECISION;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS rows_delta BIGINT;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS shared_blks_hit_delta BIGINT;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS shared_blks_read_delta BIGINT;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS shared_blks_dirtied_delta BIGINT;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS shared_blks_written_delta BIGINT;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS temp_blks_read_delta BIGINT;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS temp_blks_written_delta BIGINT;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS blk_read_time_delta DOUBLE PRECISION;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS blk_write_time_delta DOUBLE PRECISION;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS wal_records_delta BIGINT;
    ALTER TABLE pgfr_record.statement_snapshots ADD COLUMN IF NOT EXISTS wal_bytes_delta NUMERIC;
END $$;

CREATE UNLOGGED TABLE IF NOT EXISTS pgfr_record.samples_ring (
    slot_id             INTEGER PRIMARY KEY CHECK (slot_id >= 0 AND slot_id < 2880),
    captured_at         TIMESTAMPTZ NOT NULL,
    epoch_seconds       BIGINT NOT NULL
) WITH (fillfactor = 70);
COMMENT ON TABLE pgfr_record.samples_ring IS 'Ring buffer: Master slot tracker (configurable slots via ring_buffer_slots, default 120). Supports up to 2880 slots for extended retention or fine-grained sampling. Fillfactor 70 enables HOT updates. Use configure_ring_autovacuum(false) to disable autovacuum if desired.';

CREATE UNLOGGED TABLE IF NOT EXISTS pgfr_record.wait_samples_ring (
    slot_id             INTEGER REFERENCES pgfr_record.samples_ring(slot_id) ON DELETE CASCADE,
    row_num             INTEGER NOT NULL CHECK (row_num >= 0 AND row_num < 100),
    backend_type        TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    state               TEXT,
    count               INTEGER,
    PRIMARY KEY (slot_id, row_num)
) WITH (fillfactor = 90);
COMMENT ON TABLE pgfr_record.wait_samples_ring IS 'Ring buffer: Wait events (UPDATE-only pattern). Pre-populated rows (slots × 100 rows, default 12,000). Fillfactor 90 enables HOT updates. Use configure_ring_autovacuum(false) to disable autovacuum if desired. NULLs indicate unused slots.';

CREATE UNLOGGED TABLE IF NOT EXISTS pgfr_record.activity_samples_ring (
    slot_id             INTEGER REFERENCES pgfr_record.samples_ring(slot_id) ON DELETE CASCADE,
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
COMMENT ON TABLE pgfr_record.activity_samples_ring IS 'Ring buffer: Active sessions (UPDATE-only pattern). Pre-populated rows (slots × 25 rows, default 3,000). Top 25 active sessions per sample. Fillfactor 90 enables HOT updates. Use configure_ring_autovacuum(false) to disable autovacuum if desired. NULLs indicate unused slots.';

CREATE UNLOGGED TABLE IF NOT EXISTS pgfr_record.lock_samples_ring (
    slot_id                 INTEGER REFERENCES pgfr_record.samples_ring(slot_id) ON DELETE CASCADE,
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
COMMENT ON TABLE pgfr_record.lock_samples_ring IS 'Ring buffer: Lock contention (UPDATE-only pattern). Pre-populated rows (slots × 100 rows, default 12,000). Max 100 blocked/blocking pairs per sample. Fillfactor 90 enables HOT updates. Use configure_ring_autovacuum(false) to disable autovacuum if desired. NULLs indicate unused slots.';

INSERT INTO pgfr_record.samples_ring (slot_id, captured_at, epoch_seconds)
SELECT
    generate_series AS slot_id,
    '1970-01-01'::timestamptz,
    0
FROM generate_series(0, 119)
ON CONFLICT (slot_id) DO NOTHING;
INSERT INTO pgfr_record.wait_samples_ring (slot_id, row_num)
SELECT s.slot_id, r.row_num
FROM generate_series(0, 119) s(slot_id)
CROSS JOIN generate_series(0, 99) r(row_num)
ON CONFLICT (slot_id, row_num) DO NOTHING;
INSERT INTO pgfr_record.activity_samples_ring (slot_id, row_num)
SELECT s.slot_id, r.row_num
FROM generate_series(0, 119) s(slot_id)
CROSS JOIN generate_series(0, 24) r(row_num)
ON CONFLICT (slot_id, row_num) DO NOTHING;
INSERT INTO pgfr_record.lock_samples_ring (slot_id, row_num)
SELECT s.slot_id, r.row_num
FROM generate_series(0, 119) s(slot_id)
CROSS JOIN generate_series(0, 99) r(row_num)
ON CONFLICT (slot_id, row_num) DO NOTHING;
-- Aggregates wait event statistics over 5-minute windows, enabling analysis of wait event patterns
-- Stores metrics like average/max concurrent waiters per event type, state, and backend type
-- Aggregates: durable and survives crashes, with indexes for efficient time-range and event-type queries
CREATE TABLE IF NOT EXISTS pgfr_record.wait_event_aggregates (
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
    ON pgfr_record.wait_event_aggregates(start_time, end_time);
CREATE INDEX IF NOT EXISTS wait_aggregates_event_idx
    ON pgfr_record.wait_event_aggregates(wait_event_type, wait_event);
COMMENT ON TABLE pgfr_record.wait_event_aggregates IS 'Aggregates: Durable wait event summaries (5-min windows, survives crashes)';


-- Stores aggregated lock contention patterns within time windows
-- Tracks which sessions block others, including lock type, affected relation, and duration statistics
-- Enables forensic analysis of lock conflicts and performance bottlenecks across restarts
CREATE TABLE IF NOT EXISTS pgfr_record.lock_aggregates (
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
    ON pgfr_record.lock_aggregates(start_time, end_time);
COMMENT ON TABLE pgfr_record.lock_aggregates IS 'Aggregates: Durable lock pattern summaries (5-min windows, survives crashes)';


-- Aggregates activity samples within 5-minute time windows
-- Stores query preview, occurrence count, and duration metrics (max/avg)
-- Provides durable activity summaries that survive database crashes
CREATE TABLE IF NOT EXISTS pgfr_record.activity_aggregates (
    id                  BIGSERIAL PRIMARY KEY,
    start_time          TIMESTAMPTZ NOT NULL,
    end_time            TIMESTAMPTZ NOT NULL,
    query_preview       TEXT,
    occurrence_count    INTEGER NOT NULL,
    max_duration        INTERVAL,
    avg_duration        INTERVAL
);
CREATE INDEX IF NOT EXISTS activity_aggregates_time_idx
    ON pgfr_record.activity_aggregates(start_time, end_time);
COMMENT ON TABLE pgfr_record.activity_aggregates IS 'Aggregates: Durable activity summaries (5-min windows, survives crashes)';


-- Stores snapshot samples of PostgreSQL backend activity for forensic analysis
-- Captures session details, query state, and wait events at regular intervals (15-min cadence)
-- Indexed by timestamp, sample group, and process ID for efficient historical queries
CREATE TABLE IF NOT EXISTS pgfr_record.activity_samples_archive (
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
    ON pgfr_record.activity_samples_archive(captured_at);
CREATE INDEX IF NOT EXISTS activity_archive_sample_id_idx
    ON pgfr_record.activity_samples_archive(sample_id);
CREATE INDEX IF NOT EXISTS activity_archive_pid_idx
    ON pgfr_record.activity_samples_archive(pid, captured_at);
COMMENT ON TABLE pgfr_record.activity_samples_archive IS 'Raw archives: Activity samples for forensic analysis (15-min cadence, full resolution)';


-- Archives lock contention incidents with complete blocking chains (blocked and blocking process details)
-- Captures at 15-minute intervals for forensic analysis of lock conflicts and deadlock relationships
-- Stores query previews, process info (PID, user, application), lock types, and relation OIDs
CREATE TABLE IF NOT EXISTS pgfr_record.lock_samples_archive (
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
    ON pgfr_record.lock_samples_archive(captured_at);
CREATE INDEX IF NOT EXISTS lock_archive_sample_id_idx
    ON pgfr_record.lock_samples_archive(sample_id);
CREATE INDEX IF NOT EXISTS lock_archive_blocked_pid_idx
    ON pgfr_record.lock_samples_archive(blocked_pid, captured_at);
CREATE INDEX IF NOT EXISTS lock_archive_blocking_pid_idx
    ON pgfr_record.lock_samples_archive(blocking_pid, captured_at);
COMMENT ON TABLE pgfr_record.lock_samples_archive IS 'Raw archives: Lock samples for forensic analysis (15-min cadence, full blocking chains)';


-- Archives raw wait event samples at full resolution for forensic analysis
-- Captures backend type, wait event type/name, and state to enable detailed investigation
-- Linked to parent samples via sample_id; indexed for efficient time-series queries
CREATE TABLE IF NOT EXISTS pgfr_record.wait_samples_archive (
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
    ON pgfr_record.wait_samples_archive(captured_at);
CREATE INDEX IF NOT EXISTS wait_archive_sample_id_idx
    ON pgfr_record.wait_samples_archive(sample_id);
CREATE INDEX IF NOT EXISTS wait_archive_wait_event_idx
    ON pgfr_record.wait_samples_archive(wait_event_type, wait_event, captured_at);
COMMENT ON TABLE pgfr_record.wait_samples_archive IS 'Raw archives: Wait event samples for forensic analysis (15-min cadence, full resolution)';


-- Captures table-level statistics from pg_stat_user_tables for hotspot tracking
-- Tracks sequential/index scans, DML activity, dead tuples, and maintenance events
-- Enables diagnosis of table-level performance issues and bloat detection
CREATE TABLE IF NOT EXISTS pgfr_record.table_snapshots (
    snapshot_id         INTEGER REFERENCES pgfr_record.snapshots(id) ON DELETE CASCADE,
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
    reltuples           BIGINT,
    vacuum_running      BOOLEAN,
    last_vacuum_duration_ms BIGINT,
    -- Size metrics for bloat detection (added in 2.23)
    table_size_bytes    BIGINT,          -- pg_relation_size: heap only
    total_size_bytes    BIGINT,          -- pg_total_relation_size: heap + indexes + TOAST
    indexes_size_bytes  BIGINT,          -- pg_indexes_size: all indexes
    PRIMARY KEY (snapshot_id, relid)
);
CREATE INDEX IF NOT EXISTS table_snapshots_relid_idx
    ON pgfr_record.table_snapshots(relid);
COMMENT ON TABLE pgfr_record.table_snapshots IS 'Table-level statistics snapshots for hotspot tracking and bloat detection. Includes size metrics for extension-free bloat estimation.';




-- Captures index-level statistics from pg_stat_user_indexes
-- Tracks index usage, tuple reads/fetches, and index sizes
-- Enables identification of unused indexes and index efficiency analysis
CREATE TABLE IF NOT EXISTS pgfr_record.index_snapshots (
    snapshot_id         INTEGER REFERENCES pgfr_record.snapshots(id) ON DELETE CASCADE,
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
    ON pgfr_record.index_snapshots(indexrelid);
CREATE INDEX IF NOT EXISTS index_snapshots_relid_idx
    ON pgfr_record.index_snapshots(relid);
COMMENT ON TABLE pgfr_record.index_snapshots IS 'Index-level statistics snapshots for usage tracking and efficiency analysis';


-- Captures PostgreSQL configuration parameters from pg_settings
-- Stores relevant settings to provide configuration context during incident analysis
-- Enables detection of configuration changes over time
CREATE TABLE IF NOT EXISTS pgfr_record.config_snapshots (
    snapshot_id     INTEGER REFERENCES pgfr_record.snapshots(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    setting         TEXT,
    unit            TEXT,
    source          TEXT,
    sourcefile      TEXT,
    PRIMARY KEY (snapshot_id, name)
);
CREATE INDEX IF NOT EXISTS config_snapshots_name_idx
    ON pgfr_record.config_snapshots(name);
COMMENT ON TABLE pgfr_record.config_snapshots IS 'PostgreSQL configuration snapshots for change tracking and incident context';


-- Stores relation OID to name mappings for offline analysis
-- Populated by _populate_relation_names() before data export
-- Enables analysis functions to resolve OIDs without access to pg_class
CREATE TABLE IF NOT EXISTS pgfr_record.relation_names (
    oid             OID PRIMARY KEY,
    nspname         TEXT NOT NULL,
    relname         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS relation_names_name_idx
    ON pgfr_record.relation_names(nspname, relname);
COMMENT ON TABLE pgfr_record.relation_names IS 'OID to relation name mappings for offline analysis. Populated at export time, not during collection.';


-- Captures database-level and role-level configuration overrides from pg_db_role_setting
-- These settings override global GUCs and are often overlooked during incident analysis
-- Complementary to config_snapshots which tracks global settings
CREATE TABLE IF NOT EXISTS pgfr_record.db_role_config_snapshots (
    snapshot_id     INTEGER REFERENCES pgfr_record.snapshots(id) ON DELETE CASCADE,
    database_name   TEXT NOT NULL DEFAULT '',  -- Empty string = applies to all databases (role-level only)
    role_name       TEXT NOT NULL DEFAULT '',  -- Empty string = applies to all roles (database-level only)
    parameter_name  TEXT NOT NULL,
    parameter_value TEXT,
    PRIMARY KEY (snapshot_id, database_name, role_name, parameter_name)
);
CREATE INDEX IF NOT EXISTS db_role_config_snapshots_param_idx
    ON pgfr_record.db_role_config_snapshots(parameter_name);
COMMENT ON TABLE pgfr_record.db_role_config_snapshots IS 'Database and role-level configuration overrides (ALTER DATABASE/ROLE SET) for change tracking';


-- Formats byte values as human-readable strings with appropriate units (GB, MB, KB, B)
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
    ('regression_detection_metric', 'buffers')
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
CREATE OR REPLACE FUNCTION pgfr_record._get_config(p_key TEXT, p_default TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT value FROM pgfr_record.config WHERE key = p_key),
        p_default
    )
$$;

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
            WHEN v_lock_timeout > 500 THEN 'WARNING'
            WHEN v_lock_timeout > 1000 THEN 'CRITICAL'
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
    SELECT EXISTS (
        SELECT 1 FROM cron.job
        WHERE jobname LIKE 'pgfr%'
          AND active = true
    ) INTO v_enabled;
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
CREATE OR REPLACE FUNCTION pgfr_record.sample()
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
        pgfr_record._get_config('sample_interval_seconds', '60')::integer,
        60
    );
    IF v_sample_interval_seconds < 60 THEN
        v_sample_interval_seconds := 60;
    ELSIF v_sample_interval_seconds > 3600 THEN
        v_sample_interval_seconds := 3600;
    END IF;
    v_slot_id := (v_epoch / v_sample_interval_seconds) % pgfr_record._get_ring_buffer_slots();
    v_should_skip := pgfr_record._check_circuit_breaker('sample');
    IF v_should_skip THEN
        PERFORM pgfr_record._record_collection_skip('sample', 'Circuit breaker tripped - last run exceeded threshold');
        RAISE NOTICE 'pgfr_record: Skipping sample collection due to circuit breaker';
        RETURN v_captured_at;
    END IF;
    v_stat_id := pgfr_record._record_collection_start('sample', 3);
    DECLARE
        v_lock_strategy TEXT;
        v_lock_timeout_ms INTEGER;
    BEGIN
        v_lock_strategy := COALESCE(
            pgfr_record._get_config('lock_timeout_strategy', 'fail_fast'),
            'fail_fast'
        );
        v_lock_timeout_ms := CASE v_lock_strategy
            WHEN 'skip_if_locked' THEN 0
            WHEN 'patient' THEN 500
            ELSE 100
        END;
        PERFORM set_config('lock_timeout', v_lock_timeout_ms::text, true);
    END;
    PERFORM set_config('work_mem',
        COALESCE(pgfr_record._get_config('work_mem_kb', '2048'), '2048') || 'kB',
        true);
    DECLARE
        v_load_shedding_enabled BOOLEAN;
        v_load_threshold_pct INTEGER;
        v_max_connections INTEGER;
        v_active_pct NUMERIC;
        v_active_count INTEGER;
        v_stmt_utilization NUMERIC;
        v_stmt_status TEXT;
    BEGIN
        v_load_shedding_enabled := COALESCE(
            pgfr_record._get_config('load_shedding_enabled', 'true')::boolean,
            true
        );
        IF v_load_shedding_enabled THEN
            v_load_threshold_pct := COALESCE(
                pgfr_record._get_config('load_shedding_active_pct', '70')::integer,
                70
            );
            SELECT setting::integer INTO v_max_connections
            FROM pg_settings WHERE name = 'max_connections';
            SELECT count(*) INTO v_active_count
            FROM pg_stat_activity
            WHERE state = 'active' AND backend_type = 'client backend';
            v_active_pct := (v_active_count::numeric / NULLIF(v_max_connections, 0)) * 100;
            IF v_active_pct >= v_load_threshold_pct THEN
                PERFORM pgfr_record._record_collection_skip('sample',
                    format('Load shedding: high load (%s active / %s max = %s%% >= %s%% threshold)',
                           v_active_count, v_max_connections, round(v_active_pct, 1), v_load_threshold_pct));
                PERFORM set_config('statement_timeout', '0', true);
                RETURN v_captured_at;
            END IF;
        END IF;
        IF pgfr_record._has_pg_stat_statements() THEN
            SELECT utilization_pct, status
            INTO v_stmt_utilization, v_stmt_status
            FROM pgfr_record._check_statements_health();
            IF v_stmt_status IN ('WARNING', 'HIGH_CHURN') THEN
                PERFORM pgfr_record._record_collection_skip('sample',
                    format('pg_stat_statements overhead: %s utilization (%s%%), skipping to reduce hash table pressure',
                           v_stmt_status, round(v_stmt_utilization, 1)));
                PERFORM set_config('statement_timeout', '0', true);
                RETURN v_captured_at;
            END IF;
        END IF;
    END;
    v_enable_locks := COALESCE(
        pgfr_record._get_config('enable_locks', 'true')::boolean,
        TRUE
    );
    v_snapshot_based := COALESCE(
        pgfr_record._get_config('snapshot_based_collection', 'true')::boolean,
        true
    );
    INSERT INTO pgfr_record.samples_ring (slot_id, captured_at, epoch_seconds)
    VALUES (v_slot_id, v_captured_at, v_epoch)
    ON CONFLICT (slot_id) DO UPDATE SET
        captured_at = EXCLUDED.captured_at,
        epoch_seconds = EXCLUDED.epoch_seconds;
    UPDATE pgfr_record.wait_samples_ring SET
        backend_type = NULL, wait_event_type = NULL, wait_event = NULL, state = NULL, count = NULL
    WHERE slot_id = v_slot_id;
    UPDATE pgfr_record.activity_samples_ring SET
        pid = NULL, usename = NULL, application_name = NULL, backend_type = NULL,
        state = NULL, wait_event_type = NULL, wait_event = NULL,
        backend_start = NULL, xact_start = NULL,
        query_start = NULL, state_change = NULL, query_preview = NULL
    WHERE slot_id = v_slot_id;
    UPDATE pgfr_record.lock_samples_ring SET
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
        PERFORM pgfr_record._set_section_timeout();
        IF v_snapshot_based THEN
            INSERT INTO pgfr_record.wait_samples_ring (slot_id, row_num, backend_type, wait_event_type, wait_event, state, count)
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
            INSERT INTO pgfr_record.wait_samples_ring (slot_id, row_num, backend_type, wait_event_type, wait_event, state, count)
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
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Wait events collection failed: %', SQLERRM;
    END;
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        IF v_snapshot_based THEN
            INSERT INTO pgfr_record.activity_samples_ring (
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
            INSERT INTO pgfr_record.activity_samples_ring (
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
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Activity samples collection failed: %', SQLERRM;
    END;
    IF v_enable_locks THEN
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        DECLARE
            v_blocked_count INTEGER;
            v_skip_locks_threshold INTEGER;
        BEGIN
            v_skip_locks_threshold := COALESCE(
                pgfr_record._get_config('skip_locks_threshold', '50')::integer,
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
                RAISE NOTICE 'pgfr_record: Skipping lock collection - % blocked sessions exceeds threshold %',
                    v_blocked_count, v_skip_locks_threshold;
            ELSE
                INSERT INTO pgfr_record.lock_samples_ring (
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
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Lock sampling collection failed: %', SQLERRM;
    END;
    END IF;
    PERFORM pgfr_record._record_collection_end(v_stat_id, true, NULL);
    PERFORM set_config('statement_timeout', '0', true);
    RETURN v_captured_at;
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pgfr_record._record_collection_end(v_stat_id, false, SQLERRM);
        PERFORM set_config('statement_timeout', '0', true);
        RAISE WARNING 'pgfr_record: Sample collection failed: %', SQLERRM;
        RETURN v_captured_at;
END;
$$;
COMMENT ON FUNCTION pgfr_record.sample() IS 'Sampled activity: Collect samples into ring buffer (configurable interval, default 60s, 3 sections: waits, activity, locks)';


-- Aggregates: Aggregate wait events, lock conflicts, and query activity from ring buffers into durable aggregate tables
CREATE OR REPLACE FUNCTION pgfr_record.flush_ring_to_aggregates()
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
    FROM pgfr_record.wait_event_aggregates;
    SELECT min(captured_at), max(captured_at), count(*)
    INTO v_start_time, v_end_time, v_total_samples
    FROM pgfr_record.samples_ring
    WHERE captured_at > v_last_flush;
    IF v_start_time IS NULL OR v_total_samples = 0 THEN
        RETURN;
    END IF;
    INSERT INTO pgfr_record.wait_event_aggregates (
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
    FROM pgfr_record.wait_samples_ring w
    JOIN pgfr_record.samples_ring s ON s.slot_id = w.slot_id
    WHERE s.captured_at BETWEEN v_start_time AND v_end_time
      AND w.backend_type IS NOT NULL
    GROUP BY w.backend_type, w.wait_event_type, w.wait_event, w.state;
    INSERT INTO pgfr_record.lock_aggregates (
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
    FROM pgfr_record.lock_samples_ring l
    JOIN pgfr_record.samples_ring s ON s.slot_id = l.slot_id
    WHERE s.captured_at BETWEEN v_start_time AND v_end_time
      AND l.blocked_pid IS NOT NULL
    GROUP BY l.blocked_user, l.blocking_user, l.lock_type, l.locked_relation_oid;
    INSERT INTO pgfr_record.activity_aggregates (
        start_time, end_time, query_preview, occurrence_count, max_duration, avg_duration
    )
    SELECT
        v_start_time,
        v_end_time,
        a.query_preview,
        count(*) AS occurrence_count,
        max(s.captured_at - a.query_start) AS max_duration,
        avg(s.captured_at - a.query_start) AS avg_duration
    FROM pgfr_record.activity_samples_ring a
    JOIN pgfr_record.samples_ring s ON s.slot_id = a.slot_id
    WHERE s.captured_at BETWEEN v_start_time AND v_end_time
      AND a.pid IS NOT NULL
      AND a.query_start IS NOT NULL
    GROUP BY a.query_preview;
    RAISE NOTICE 'pgfr_record: Flushed ring buffer (% to %, % samples)',
        v_start_time, v_end_time, v_total_samples;
END;
$$;
COMMENT ON FUNCTION pgfr_record.flush_ring_to_aggregates() IS 'Aggregates: Flush ring buffer to durable aggregates every 5 minutes';


-- Archives activity, lock, and wait samples from ring buffers to persistent storage for forensic analysis
-- Executes periodically (default every 15 minutes) based on configuration settings
CREATE OR REPLACE FUNCTION pgfr_record.archive_ring_samples()
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
        (SELECT value::boolean FROM pgfr_record.config WHERE key = 'archive_samples_enabled'),
        true
    );
    IF NOT v_enabled THEN
        RETURN;
    END IF;
    v_archive_activity := COALESCE(
        (SELECT value::boolean FROM pgfr_record.config WHERE key = 'archive_activity_samples'),
        true
    );
    v_archive_locks := COALESCE(
        (SELECT value::boolean FROM pgfr_record.config WHERE key = 'archive_lock_samples'),
        true
    );
    v_archive_waits := COALESCE(
        (SELECT value::boolean FROM pgfr_record.config WHERE key = 'archive_wait_samples'),
        true
    );
    v_frequency_minutes := COALESCE(
        (SELECT value::integer FROM pgfr_record.config WHERE key = 'archive_sample_frequency_minutes'),
        15
    );
    SELECT GREATEST(
        COALESCE(MAX(captured_at), '1970-01-01'::timestamptz),
        COALESCE((SELECT MAX(captured_at) FROM pgfr_record.lock_samples_archive), '1970-01-01'::timestamptz),
        COALESCE((SELECT MAX(captured_at) FROM pgfr_record.wait_samples_archive), '1970-01-01'::timestamptz)
    )
    INTO v_last_archive
    FROM pgfr_record.activity_samples_archive;
    v_next_archive_due := v_last_archive + (v_frequency_minutes || ' minutes')::interval;
    IF now() < v_next_archive_due THEN
        RETURN;
    END IF;
    SELECT count(DISTINCT slot_id)
    INTO v_samples_to_archive
    FROM pgfr_record.samples_ring
    WHERE captured_at > v_last_archive;
    IF v_samples_to_archive = 0 THEN
        RETURN;
    END IF;
    IF v_archive_activity THEN
        INSERT INTO pgfr_record.activity_samples_archive (
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
        FROM pgfr_record.activity_samples_ring a
        JOIN pgfr_record.samples_ring s ON s.slot_id = a.slot_id
        WHERE s.captured_at > v_last_archive
          AND a.pid IS NOT NULL;
        GET DIAGNOSTICS v_activity_rows = ROW_COUNT;
    END IF;
    IF v_archive_locks THEN
        INSERT INTO pgfr_record.lock_samples_archive (
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
        FROM pgfr_record.lock_samples_ring l
        JOIN pgfr_record.samples_ring s ON s.slot_id = l.slot_id
        WHERE s.captured_at > v_last_archive
          AND l.blocked_pid IS NOT NULL;
        GET DIAGNOSTICS v_lock_rows = ROW_COUNT;
    END IF;
    IF v_archive_waits THEN
        INSERT INTO pgfr_record.wait_samples_archive (
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
        FROM pgfr_record.wait_samples_ring w
        JOIN pgfr_record.samples_ring s ON s.slot_id = w.slot_id
        WHERE s.captured_at > v_last_archive
          AND w.backend_type IS NOT NULL;
        GET DIAGNOSTICS v_wait_rows = ROW_COUNT;
    END IF;
    RAISE NOTICE 'pgfr_record: Archived raw samples (% samples, % activity rows, % lock rows, % wait rows)',
        v_samples_to_archive, v_activity_rows, v_lock_rows, v_wait_rows;
END;
$$;
COMMENT ON FUNCTION pgfr_record.archive_ring_samples() IS 'Raw archives: Archive raw samples for high-resolution forensic analysis (default: every 15 minutes)';


-- Removes aged aggregate and archived sample data based on configured retention periods
-- Deletes expired records from wait_event_aggregates, lock_aggregates, activity_aggregates, and all *_samples_archive tables
CREATE OR REPLACE FUNCTION pgfr_record.cleanup_aggregates()
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
        (SELECT value || ' days' FROM pgfr_record.config WHERE key = 'aggregate_retention_days')::interval,
        '7 days'::interval
    );
    v_archive_retention := COALESCE(
        (SELECT value || ' days' FROM pgfr_record.config WHERE key = 'archive_retention_days')::interval,
        '7 days'::interval
    );
    DELETE FROM pgfr_record.wait_event_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_waits = ROW_COUNT;
    DELETE FROM pgfr_record.lock_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_locks = ROW_COUNT;
    DELETE FROM pgfr_record.activity_aggregates
    WHERE start_time < now() - v_aggregate_retention;
    GET DIAGNOSTICS v_deleted_queries = ROW_COUNT;
    DELETE FROM pgfr_record.activity_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_activity_archive = ROW_COUNT;
    DELETE FROM pgfr_record.lock_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_lock_archive = ROW_COUNT;
    DELETE FROM pgfr_record.wait_samples_archive
    WHERE captured_at < now() - v_archive_retention;
    GET DIAGNOSTICS v_deleted_wait_archive = ROW_COUNT;
    IF v_deleted_waits > 0 OR v_deleted_locks > 0 OR v_deleted_queries > 0 OR
       v_deleted_activity_archive > 0 OR v_deleted_lock_archive > 0 OR v_deleted_wait_archive > 0 THEN
        RAISE NOTICE 'pgfr_record: Cleaned up % wait aggregates, % lock aggregates, % query aggregates, % activity archives, % lock archives, % wait archives',
            v_deleted_waits, v_deleted_locks, v_deleted_queries, v_deleted_activity_archive, v_deleted_lock_archive, v_deleted_wait_archive;
    END IF;
END;
$$;
COMMENT ON FUNCTION pgfr_record.cleanup_aggregates() IS 'Cleanup: Remove old aggregate and archive data based on retention periods';


-- Collects table-level statistics from pg_stat_user_tables
-- Captures tables based on configurable sampling mode: top_n, all, or threshold
CREATE OR REPLACE FUNCTION pgfr_record._collect_table_stats(p_snapshot_id INTEGER)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
    v_top_n INTEGER;
    v_mode TEXT;
    v_threshold BIGINT;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('table_stats_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    v_top_n := COALESCE(
        pgfr_record._get_config('table_stats_top_n', '50')::integer,
        50
    );

    v_mode := COALESCE(
        pgfr_record._get_config('table_stats_mode', 'top_n'),
        'top_n'
    );

    v_threshold := COALESCE(
        pgfr_record._get_config('table_stats_activity_threshold', '0')::bigint,
        0
    );

    -- Handle different collection modes
    IF v_mode = 'all' THEN
        -- Collect all user tables
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO pgfr_record.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age, reltuples, vacuum_running,
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
            c.reltuples::bigint AS reltuples,
            EXISTS(SELECT 1 FROM pg_stat_progress_vacuum pv WHERE pv.relid = st.relid) AS vacuum_running,
            pg_relation_size(st.relid),
            pg_total_relation_size(st.relid),
            pg_indexes_size(st.relid)
        FROM pg_stat_user_tables st
        LEFT JOIN pg_class c ON c.oid = st.relid;

    ELSIF v_mode = 'threshold' THEN
        -- Collect tables with activity score above threshold
        -- Note: schemaname/relname are deprecated; derive via relation_names or ::regclass
        INSERT INTO pgfr_record.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age, reltuples, vacuum_running,
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
            c.reltuples::bigint AS reltuples,
            EXISTS(SELECT 1 FROM pg_stat_progress_vacuum pv WHERE pv.relid = st.relid) AS vacuum_running,
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
        INSERT INTO pgfr_record.table_snapshots (
            snapshot_id, schemaname, relname, relid,
            seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            n_live_tup, n_dead_tup, n_mod_since_analyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
            relfrozenxid_age, reltuples, vacuum_running,
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
            c.reltuples::bigint AS reltuples,
            EXISTS(SELECT 1 FROM pg_stat_progress_vacuum pv WHERE pv.relid = st.relid) AS vacuum_running,
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
CREATE OR REPLACE FUNCTION pgfr_record._collect_index_stats(p_snapshot_id INTEGER)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('index_stats_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Note: schemaname/relname/indexrelname are deprecated; derive via relation_names or ::regclass
    INSERT INTO pgfr_record.index_snapshots (
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
CREATE OR REPLACE FUNCTION pgfr_record._collect_config_snapshot(p_snapshot_id INTEGER)
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
        pgfr_record._get_config('config_snapshots_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Only insert parameters that have changed since the most recent snapshot
    -- This reduces storage by 99%+ in stable environments while maintaining
    -- full point-in-time query capability via DISTINCT ON (cs.name) pattern
    INSERT INTO pgfr_record.config_snapshots (
        snapshot_id, name, setting, unit, source, sourcefile
    )
    WITH latest_config AS (
        SELECT DISTINCT ON (cs.name)
            cs.name,
            cs.setting,
            cs.unit,
            cs.source,
            cs.sourcefile
        FROM pgfr_record.config_snapshots cs
        JOIN pgfr_record.snapshots s ON s.id = cs.snapshot_id
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
CREATE OR REPLACE FUNCTION pgfr_record._collect_db_role_config_snapshot(p_snapshot_id INTEGER)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_enabled BOOLEAN;
BEGIN
    v_enabled := COALESCE(
        pgfr_record._get_config('db_role_config_snapshots_enabled', 'true')::boolean,
        true
    );

    IF NOT v_enabled THEN
        RETURN;
    END IF;

    -- Only insert database/role config overrides that have changed since the most recent snapshot
    -- This reduces storage significantly in stable environments
    INSERT INTO pgfr_record.db_role_config_snapshots (
        snapshot_id, database_name, role_name, parameter_name, parameter_value
    )
    WITH latest_db_role_config AS (
        SELECT DISTINCT ON (drc.database_name, drc.role_name, drc.parameter_name)
            drc.database_name,
            drc.role_name,
            drc.parameter_name,
            drc.parameter_value
        FROM pgfr_record.db_role_config_snapshots drc
        JOIN pgfr_record.snapshots s ON s.id = drc.snapshot_id
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
CREATE OR REPLACE FUNCTION pgfr_record.snapshot()
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
    v_should_skip := pgfr_record._check_circuit_breaker('snapshot');
    IF v_should_skip THEN
        PERFORM pgfr_record._record_collection_skip('snapshot', 'Circuit breaker tripped - last run exceeded threshold');
        RAISE NOTICE 'pgfr_record: Skipping snapshot collection due to circuit breaker';
        RETURN v_captured_at;
    END IF;
    PERFORM pgfr_record._check_schema_size();
    v_stat_id := pgfr_record._record_collection_start('snapshot', 7);
    DECLARE
        v_lock_strategy TEXT;
        v_lock_timeout_ms INTEGER;
    BEGIN
        v_lock_strategy := COALESCE(
            pgfr_record._get_config('lock_timeout_strategy', 'fail_fast'),
            'fail_fast'
        );
        v_lock_timeout_ms := CASE v_lock_strategy
            WHEN 'skip_if_locked' THEN 0
            WHEN 'patient' THEN 500
            ELSE 100
        END;
        PERFORM set_config('lock_timeout', v_lock_timeout_ms::text, true);
    END;
    PERFORM set_config('work_mem',
        COALESCE(pgfr_record._get_config('work_mem_kb', '2048'), '2048') || 'kB',
        true);
    v_pg_version := pgfr_record._pg_version();
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
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
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: System stats collection failed: %', SQLERRM;
        v_autovacuum_workers := 0;
        v_slots_count := 0;
        v_slots_max_retained := 0;
        v_temp_files := 0;
        v_temp_bytes := 0;
    END;
    IF v_pg_version >= 16 THEN
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
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
        RAISE WARNING 'pgfr_record: pg_stat_io collection failed: %', SQLERRM;
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
        pgfr_record._get_config('capacity_planning_enabled', 'true')::boolean,
        true
    );
    IF v_capacity_enabled THEN
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        IF COALESCE(pgfr_record._get_config('collect_connection_metrics', 'true')::boolean, true) THEN
            SELECT
                xact_commit,
                xact_rollback,
                blks_read,
                blks_hit
            INTO v_xact_commit, v_xact_rollback, v_blks_read, v_blks_hit
            FROM pg_stat_database
            WHERE datname = current_database();
        END IF;
        IF COALESCE(pgfr_record._get_config('collect_connection_metrics', 'true')::boolean, true) THEN
            v_connections_max := current_setting('max_connections')::integer;
            SELECT
                count(*) FILTER (WHERE state NOT IN ('idle')),
                count(*)
            INTO v_connections_active, v_connections_total
            FROM pg_stat_activity;
        END IF;
        IF COALESCE(pgfr_record._get_config('collect_database_size', 'true')::boolean, true) THEN
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
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Capacity planning metrics collection failed: %', SQLERRM;
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
        PERFORM pgfr_record._set_section_timeout();
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
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Archiver stats collection failed: %', SQLERRM;
    END;
    -- Collect database conflict stats (only populated on standby servers)
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
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
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Database conflict stats collection failed: %', SQLERRM;
    END;
    IF v_pg_version >= 18 THEN
        INSERT INTO pgfr_record.snapshots (
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
            -- pg18: pg_stat_wal dropped wal_write_time and wal_sync_time; store null
            w.wal_records, w.wal_fpi, w.wal_bytes::bigint, NULL, NULL,
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
    ELSIF v_pg_version = 17 THEN
        INSERT INTO pgfr_record.snapshots (
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
        INSERT INTO pgfr_record.snapshots (
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
        INSERT INTO pgfr_record.snapshots (
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
        RAISE EXCEPTION 'Unsupported PostgreSQL version: %. Requires 15, 16, 17, or 18.', v_pg_version;
    END IF;
    PERFORM pgfr_record._record_section_success(v_stat_id);
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        INSERT INTO pgfr_record.replication_snapshots (
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
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Replication stats collection failed: %', SQLERRM;
    END;
    IF pgfr_record._has_pg_stat_statements()
       AND pgfr_record._get_config('statements_enabled', 'auto') != 'false'
    THEN
        DECLARE
            v_stmt_status TEXT;
            v_last_statements_collection TIMESTAMPTZ;
            v_statements_interval_minutes INTEGER;
            v_should_collect BOOLEAN := TRUE;
            v_prev_snapshot_id INTEGER;
        BEGIN
            v_statements_interval_minutes := COALESCE(
                pgfr_record._get_config('statements_interval_minutes', '1')::integer,
                1
            );
            SELECT s.id, s.captured_at
              INTO v_prev_snapshot_id, v_last_statements_collection
            FROM pgfr_record.snapshots s
            WHERE EXISTS (
                SELECT 1 FROM pgfr_record.statement_snapshots ss
                WHERE ss.snapshot_id = s.id
            )
            ORDER BY s.captured_at DESC
            LIMIT 1;
            IF v_last_statements_collection IS NOT NULL
               AND v_last_statements_collection > now() - (v_statements_interval_minutes || ' minutes')::interval
            THEN
                v_should_collect := FALSE;
            END IF;
            IF v_should_collect THEN
                PERFORM pgfr_record._set_section_timeout();
                DECLARE
                    v_check_conflicts BOOLEAN;
                    v_pss_conflict BOOLEAN;
                BEGIN
                    v_check_conflicts := COALESCE(
                        pgfr_record._get_config('check_pss_conflicts', 'true')::boolean,
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
                            RAISE NOTICE 'pgfr_record: Skipping pg_stat_statements - concurrent reader detected';
                            v_should_collect := FALSE;
                        END IF;
                    END IF;
                END;
                IF v_should_collect THEN
                    SELECT status INTO v_stmt_status
                    FROM pgfr_record._check_statements_health();
                    IF v_stmt_status = 'HIGH_CHURN' THEN
                        RAISE WARNING 'pgfr_record: Skipping pg_stat_statements collection - high churn detected (>95%% utilization)';
                    ELSE
                -- pg18 renamed blk_read_time -> shared_blk_read_time in pg_stat_statements.
                -- case when cannot reference a nonexistent column even in a dead branch;
                -- use execute with the correct column name chosen at runtime.
                EXECUTE format(
                    $q$
                    WITH current_stmts AS (
                        SELECT
                            s.queryid, s.userid, s.dbid,
                            left(s.query, 500) AS query_preview,
                            s.calls, s.total_exec_time, s.min_exec_time,
                            s.max_exec_time, s.mean_exec_time, s.rows,
                            s.shared_blks_hit, s.shared_blks_read,
                            s.shared_blks_dirtied, s.shared_blks_written,
                            s.temp_blks_read, s.temp_blks_written,
                            s.%I AS blk_read_time,
                            s.%I AS blk_write_time,
                            s.wal_records, s.wal_bytes
                        FROM pg_stat_statements s
                        WHERE s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
                          AND s.calls >= COALESCE(pgfr_record._get_config('statements_min_calls', '1')::integer, 1)
                        ORDER BY CASE
                            WHEN pgfr_record._get_config('statements_ranking_metric', 'buffers') = 'time'
                            THEN s.total_exec_time
                            ELSE s.shared_blks_hit + s.shared_blks_read + s.temp_blks_read + s.temp_blks_written
                        END DESC
                        LIMIT COALESCE(pgfr_record._get_config('statements_top_n', '50')::integer, 50)
                    )
                    INSERT INTO pgfr_record.statement_snapshots (
                        snapshot_id, queryid, userid, dbid, query_preview,
                        calls, total_exec_time, min_exec_time, max_exec_time,
                        mean_exec_time, rows,
                        shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
                        temp_blks_read, temp_blks_written,
                        blk_read_time, blk_write_time,
                        wal_records, wal_bytes,
                        calls_delta, total_exec_time_delta, rows_delta,
                        shared_blks_hit_delta, shared_blks_read_delta,
                        shared_blks_dirtied_delta, shared_blks_written_delta,
                        temp_blks_read_delta, temp_blks_written_delta,
                        blk_read_time_delta, blk_write_time_delta,
                        wal_records_delta, wal_bytes_delta
                    )
                    SELECT
                        $1, c.queryid, c.userid, c.dbid, c.query_preview,
                        c.calls, c.total_exec_time, c.min_exec_time,
                        c.max_exec_time, c.mean_exec_time, c.rows,
                        c.shared_blks_hit, c.shared_blks_read,
                        c.shared_blks_dirtied, c.shared_blks_written,
                        c.temp_blks_read, c.temp_blks_written,
                        c.blk_read_time, c.blk_write_time,
                        c.wal_records, c.wal_bytes,
                        CASE WHEN prev.calls IS NOT NULL AND c.calls >= prev.calls THEN c.calls - prev.calls ELSE NULL END,
                        CASE WHEN prev.total_exec_time IS NOT NULL AND c.total_exec_time >= prev.total_exec_time THEN c.total_exec_time - prev.total_exec_time ELSE NULL END,
                        CASE WHEN prev.rows IS NOT NULL AND c.rows >= prev.rows THEN c.rows - prev.rows ELSE NULL END,
                        CASE WHEN prev.shared_blks_hit IS NOT NULL AND c.shared_blks_hit >= prev.shared_blks_hit THEN c.shared_blks_hit - prev.shared_blks_hit ELSE NULL END,
                        CASE WHEN prev.shared_blks_read IS NOT NULL AND c.shared_blks_read >= prev.shared_blks_read THEN c.shared_blks_read - prev.shared_blks_read ELSE NULL END,
                        CASE WHEN prev.shared_blks_dirtied IS NOT NULL AND c.shared_blks_dirtied >= prev.shared_blks_dirtied THEN c.shared_blks_dirtied - prev.shared_blks_dirtied ELSE NULL END,
                        CASE WHEN prev.shared_blks_written IS NOT NULL AND c.shared_blks_written >= prev.shared_blks_written THEN c.shared_blks_written - prev.shared_blks_written ELSE NULL END,
                        CASE WHEN prev.temp_blks_read IS NOT NULL AND c.temp_blks_read >= prev.temp_blks_read THEN c.temp_blks_read - prev.temp_blks_read ELSE NULL END,
                        CASE WHEN prev.temp_blks_written IS NOT NULL AND c.temp_blks_written >= prev.temp_blks_written THEN c.temp_blks_written - prev.temp_blks_written ELSE NULL END,
                        CASE WHEN prev.blk_read_time IS NOT NULL AND c.blk_read_time >= prev.blk_read_time THEN c.blk_read_time - prev.blk_read_time ELSE NULL END,
                        CASE WHEN prev.blk_write_time IS NOT NULL AND c.blk_write_time >= prev.blk_write_time THEN c.blk_write_time - prev.blk_write_time ELSE NULL END,
                        CASE WHEN prev.wal_records IS NOT NULL AND c.wal_records >= prev.wal_records THEN c.wal_records - prev.wal_records ELSE NULL END,
                        CASE WHEN prev.wal_bytes IS NOT NULL AND c.wal_bytes >= prev.wal_bytes THEN c.wal_bytes - prev.wal_bytes ELSE NULL END
                    FROM current_stmts c
                    LEFT JOIN pgfr_record.statement_snapshots prev
                        ON prev.snapshot_id = $2
                       AND prev.queryid = c.queryid
                       AND prev.dbid = c.dbid
                    $q$,
                    CASE WHEN v_pg_version >= 18 THEN 'shared_blk_read_time'  ELSE 'blk_read_time'  END,
                    CASE WHEN v_pg_version >= 18 THEN 'shared_blk_write_time' ELSE 'blk_write_time' END
                ) USING v_snapshot_id, v_prev_snapshot_id;
                    PERFORM pgfr_record._record_section_success(v_stat_id);
                    END IF;
                END IF;
            END IF;
        EXCEPTION
            WHEN undefined_table THEN NULL;
            WHEN undefined_column THEN NULL;
            WHEN OTHERS THEN
                RAISE WARNING 'pgfr_record: pg_stat_statements collection failed: %', SQLERRM;
        END;
    END IF;
    -- Collect table stats
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        PERFORM pgfr_record._collect_table_stats(v_snapshot_id);
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Table stats collection failed: %', SQLERRM;
    END;
    -- Collect index stats
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        PERFORM pgfr_record._collect_index_stats(v_snapshot_id);
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Index stats collection failed: %', SQLERRM;
    END;
    -- Collect config snapshot
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        PERFORM pgfr_record._collect_config_snapshot(v_snapshot_id);
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Config snapshot collection failed: %', SQLERRM;
    END;
    -- Collect database/role config overrides
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        PERFORM pgfr_record._collect_db_role_config_snapshot(v_snapshot_id);
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Database/role config collection failed: %', SQLERRM;
    END;
    -- Collect vacuum progress
    -- Note: In PG17, max_dead_tuples was renamed to max_dead_tuple_bytes
    --       and num_dead_tuples was renamed to num_dead_item_ids
    BEGIN
        PERFORM pgfr_record._set_section_timeout();
        IF v_pg_version >= 17 THEN
            INSERT INTO pgfr_record.vacuum_progress_snapshots (
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
            INSERT INTO pgfr_record.vacuum_progress_snapshots (
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
        PERFORM pgfr_record._record_section_success(v_stat_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pgfr_record: Vacuum progress collection failed: %', SQLERRM;
    END;
    -- Ensure today's partitions exist for v2 sparse tables (O(1) on happy path)
    -- Wrapped in EXCEPTION blocks: missing parent table (Issue #8 not yet merged) is a
    -- recoverable error during the dual-write migration period.
    begin
        perform pgfr_record._ensure_partition('statement_snapshots_v2', current_date);
    exception when others then
        raise warning 'pgfr_record: _ensure_partition(statement_snapshots_v2) failed [%]: %', sqlstate, sqlerrm;
    end;
    begin
        perform pgfr_record._ensure_partition('table_snapshots_v2', current_date,
            'relid, dbid, sample_ts desc');
    exception when others then
        raise warning 'pgfr_record: _ensure_partition(table_snapshots_v2) failed [%]: %', sqlstate, sqlerrm;
    end;
    begin
        perform pgfr_record._ensure_partition('index_snapshots_v2', current_date,
            'indexrelid, dbid, sample_ts desc');
    exception when others then
        raise warning 'pgfr_record: _ensure_partition(index_snapshots_v2) failed [%]: %', sqlstate, sqlerrm;
    end;
    -- Sparse collectors: each isolated so failure of one does not abort others.
    -- Dual-write: old _collect_*_stats() calls above continue writing to legacy tables
    -- during migration period. Sparse collectors write to v2 partitioned tables.
    begin
        perform pgfr_record._collect_statement_snapshot_sparse(v_snapshot_id::bigint);
    exception when others then
        raise warning 'pgfr_record: sparse statement collector failed [%]: %', sqlstate, sqlerrm;
    end;
    begin
        perform pgfr_record._collect_table_snapshot_sparse(v_snapshot_id::bigint);
    exception when others then
        raise warning 'pgfr_record: sparse table collector failed [%]: %', sqlstate, sqlerrm;
    end;
    begin
        perform pgfr_record._collect_index_snapshot_sparse(v_snapshot_id::bigint);
    exception when others then
        raise warning 'pgfr_record: sparse index collector failed [%]: %', sqlstate, sqlerrm;
    end;
    PERFORM pgfr_record._record_collection_end(v_stat_id, true, NULL);
    PERFORM set_config('statement_timeout', '0', true);
    RETURN v_captured_at;
EXCEPTION
    WHEN OTHERS THEN
        PERFORM pgfr_record._record_collection_end(v_stat_id, false, SQLERRM);
        PERFORM set_config('statement_timeout', '0', true);
        RAISE;
END;
$$;
COMMENT ON FUNCTION pgfr_record.snapshot() IS
'Durable snapshots: Collect comprehensive system metrics (WAL, checkpoints, I/O, connections, table/index stats, replication, statements). Version-aware for PG 15/16/17 differences. '
'Dual-write: calls both legacy _collect_*_stats() and new sparse v2 collectors. '
'Each sparse collector is isolated in its own EXCEPTION block — failure of one does not abort others.';

CREATE OR REPLACE VIEW pgfr_record.deltas AS
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
    pgfr_record._pretty_bytes(s.wal_bytes - prev.wal_bytes) AS wal_bytes_pretty,
    (s.wal_write_time - prev.wal_write_time)::numeric AS wal_write_time_ms,
    (s.wal_sync_time - prev.wal_sync_time)::numeric AS wal_sync_time_ms,
    s.bgw_buffers_clean - prev.bgw_buffers_clean AS bgw_buffers_clean_delta,
    s.bgw_buffers_alloc - prev.bgw_buffers_alloc AS bgw_buffers_alloc_delta,
    s.bgw_buffers_backend - prev.bgw_buffers_backend AS bgw_buffers_backend_delta,
    s.bgw_buffers_backend_fsync - prev.bgw_buffers_backend_fsync AS bgw_buffers_backend_fsync_delta,
    s.autovacuum_workers AS autovacuum_workers_active,
    s.slots_count,
    s.slots_max_retained_wal,
    pgfr_record._pretty_bytes(s.slots_max_retained_wal) AS slots_max_retained_pretty,
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
    pgfr_record._pretty_bytes(s.temp_bytes - prev.temp_bytes) AS temp_bytes_pretty
FROM pgfr_record.snapshots s
JOIN pgfr_record.snapshots prev ON prev.id = (
    SELECT MAX(id) FROM pgfr_record.snapshots WHERE id < s.id
)
ORDER BY s.captured_at DESC;
-- Returns the ring buffer retention interval based on configured sample interval
-- Used by recent_* views and recent_*_current() functions to determine query window
CREATE OR REPLACE FUNCTION pgfr_record._get_ring_retention_interval()
RETURNS INTERVAL
LANGUAGE sql STABLE AS $$
    SELECT ((pgfr_record._get_ring_buffer_slots() * COALESCE(
        pgfr_record._get_config('sample_interval_seconds', '60')::integer,
        60
    ))::text || ' seconds')::interval;
$$;

CREATE OR REPLACE VIEW pgfr_record.recent_waits AS
SELECT
    sr.captured_at,
    w.backend_type,
    w.wait_event_type,
    w.wait_event,
    w.state,
    w.count
FROM pgfr_record.samples_ring sr
JOIN pgfr_record.wait_samples_ring w ON w.slot_id = sr.slot_id
WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
  AND w.backend_type IS NOT NULL
ORDER BY sr.captured_at DESC, w.count DESC;
CREATE OR REPLACE VIEW pgfr_record.recent_activity AS
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
FROM pgfr_record.samples_ring sr
JOIN pgfr_record.activity_samples_ring a ON a.slot_id = sr.slot_id
WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
  AND a.pid IS NOT NULL
ORDER BY sr.captured_at DESC, a.query_start ASC;
CREATE OR REPLACE VIEW pgfr_record.recent_locks AS
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
FROM pgfr_record.samples_ring sr
JOIN pgfr_record.lock_samples_ring l ON l.slot_id = sr.slot_id
WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
  AND l.blocked_pid IS NOT NULL
ORDER BY sr.captured_at DESC, l.blocked_duration DESC;

-- Shows sessions currently idle in transaction, ordered by how long they have been idle
-- Used for quick visibility into problem sessions that may be blocking vacuum or holding locks
CREATE OR REPLACE VIEW pgfr_record.recent_idle_in_transaction AS
SELECT
    sr.captured_at,
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.xact_start,
    sr.captured_at - a.xact_start AS idle_duration,
    a.query_preview
FROM pgfr_record.samples_ring sr
JOIN pgfr_record.activity_samples_ring a ON a.slot_id = sr.slot_id
WHERE sr.captured_at > now() - pgfr_record._get_ring_retention_interval()
  AND a.pid IS NOT NULL
  AND a.state = 'idle in transaction'
ORDER BY a.xact_start ASC NULLS LAST;

COMMENT ON VIEW pgfr_record.recent_idle_in_transaction IS
'Sessions currently idle in transaction, ordered by how long they have been idle';

CREATE OR REPLACE VIEW pgfr_record.recent_replication AS
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
    pgfr_record._pretty_bytes(pg_wal_lsn_diff(r.sent_lsn, r.replay_lsn)::bigint) AS replay_lag_pretty,
    r.write_lag,
    r.flush_lag,
    r.replay_lag
FROM pgfr_record.snapshots sn
JOIN pgfr_record.replication_snapshots r ON r.snapshot_id = sn.id
WHERE sn.captured_at > now() - interval '2 hours'
ORDER BY sn.captured_at DESC, r.application_name;

-- Shows vacuum progress from recent snapshots with percentage calculations
CREATE OR REPLACE VIEW pgfr_record.recent_vacuum_progress AS
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
FROM pgfr_record.snapshots sn
JOIN pgfr_record.vacuum_progress_snapshots v ON v.snapshot_id = sn.id
WHERE sn.captured_at > now() - interval '2 hours'
ORDER BY sn.captured_at DESC, v.pid;
COMMENT ON VIEW pgfr_record.recent_vacuum_progress IS 'Recent vacuum progress with percentage scanned/vacuumed calculations';

-- Shows archiver status with delta calculations between snapshots
CREATE OR REPLACE VIEW pgfr_record.archiver_status AS
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
FROM pgfr_record.snapshots s
JOIN pgfr_record.snapshots prev ON prev.id = (
    SELECT MAX(id) FROM pgfr_record.snapshots WHERE id < s.id
)
WHERE s.captured_at > now() - interval '24 hours'
  AND s.archived_count IS NOT NULL
ORDER BY s.captured_at DESC;
COMMENT ON VIEW pgfr_record.archiver_status IS 'WAL archiver status with delta calculations between snapshots';

-- Switches flight recorder to specified mode (normal/light/emergency) with different overhead and retention trade-offs
-- Validates mode and configures sampling interval and collector enablement accordingly
CREATE OR REPLACE FUNCTION pgfr_record.set_mode(p_mode TEXT)
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
        pgfr_record._get_config('sample_interval_seconds', '60')::integer,
        60
    );
    CASE p_mode
        WHEN 'normal' THEN
            v_enable_locks := TRUE;
            v_enable_progress := TRUE;
            v_sample_interval_seconds := 60;
            v_description := 'Normal mode: 60s sampling, all collectors enabled (2h retention)';
        WHEN 'light' THEN
            v_enable_locks := TRUE;
            v_enable_progress := FALSE;
            v_sample_interval_seconds := 60;
            v_description := 'Light mode: 60s sampling, progress disabled (2h retention, minimal overhead)';
        WHEN 'emergency' THEN
            v_enable_locks := FALSE;
            v_enable_progress := FALSE;
            v_sample_interval_seconds := 300;
            v_description := 'Emergency mode: 300s sampling, locks/progress disabled (10h retention, 60% less overhead)';
    END CASE;
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('mode', p_mode, now())
    ON CONFLICT (key) DO UPDATE SET value = p_mode, updated_at = now();
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('enable_locks', v_enable_locks::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_enable_locks::text, updated_at = now();
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('enable_progress', v_enable_progress::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_enable_progress::text, updated_at = now();
    INSERT INTO pgfr_record.config (key, value, updated_at)
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
        IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_sample') THEN
            PERFORM cron.unschedule('pgfr_sample');
            PERFORM cron.schedule('pgfr_sample', v_cron_expression, 'SET statement_timeout = ''5s''; SELECT pgfr_record.sample()');
        END IF;
    EXCEPTION
        WHEN undefined_table THEN NULL;
        WHEN undefined_function THEN NULL;
    END;
    RETURN v_description;
END;
$$;
COMMENT ON FUNCTION pgfr_record.set_mode(TEXT) IS
'Set operating mode: normal (60s, all collectors), light (60s, no progress tracking), or emergency (300s, minimal collectors). Reschedules the sample cron job if running.';

-- Retrieve the current flight recorder operating mode and its associated configuration
-- Returns mode, sample interval, and feature flags for locks, progress, and statement tracking
CREATE OR REPLACE FUNCTION pgfr_record.get_mode()
RETURNS TABLE(
    mode                TEXT,
    sample_interval     TEXT,
    locks_enabled       BOOLEAN,
    progress_enabled    BOOLEAN,
    statements_enabled  TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        pgfr_record._get_config('mode', 'normal') AS mode,
        CASE pgfr_record._get_config('mode', 'normal')
            WHEN 'normal' THEN '* * * * *'
            WHEN 'light' THEN '* * * * *'
            WHEN 'emergency' THEN '300 seconds'
            ELSE 'unknown'
        END AS sample_interval,
        COALESCE(pgfr_record._get_config('enable_locks', 'true')::boolean, true) AS locks_enabled,
        COALESCE(pgfr_record._get_config('enable_progress', 'true')::boolean, true) AS progress_enabled,
        pgfr_record._get_config('statements_enabled', 'auto') AS statements_enabled
$$;
COMMENT ON FUNCTION pgfr_record.get_mode() IS
'Returns current operating mode and configuration: mode name, sample interval, and feature flags for locks, progress, and statement tracking.';

-- Lists the available monitoring profiles for flight recorder with their configurations, use cases, and overhead levels
CREATE OR REPLACE FUNCTION pgfr_record.list_profiles()
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
         '60s (2h retention)',
         'Low (~0.04% CPU)'),
        ('production_safe',
         'Ultra-conservative for production environments',
         'Production always-on monitoring with maximum safety',
         '300s (10h retention)',
         'Ultra-minimal (~0.008% CPU)'),
        ('development',
         'Balanced for staging and development',
         'Active development, testing, or staging environments',
         '60s (2h retention)',
         'Low (~0.04% CPU)'),
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
COMMENT ON FUNCTION pgfr_record.list_profiles() IS
'Lists available monitoring profiles (default, production_safe, development, troubleshooting, minimal_overhead) with descriptions, use cases, sample intervals, and overhead levels.';

-- Returns ring buffer optimization profiles for different use cases
-- Profiles provide pre-configured ring_buffer_slots, sample_interval, and archive settings
CREATE OR REPLACE FUNCTION pgfr_record.get_optimization_profiles()
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
         120, 60, 15,
         ROUND(120 * 60 / 3600.0, 1),
         'Default: 2h retention, 1min granularity, 0.042% CPU'),
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
COMMENT ON FUNCTION pgfr_record.get_optimization_profiles() IS 'Returns ring buffer optimization profiles for different use cases. Profiles configure ring_buffer_slots, sample_interval_seconds, and archive_sample_frequency_minutes for specific monitoring scenarios.';

-- Applies a ring buffer optimization profile
-- Updates config values and warns if rebuild is needed
CREATE OR REPLACE FUNCTION pgfr_record.apply_optimization_profile(p_profile TEXT)
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
    FROM pgfr_record.get_optimization_profiles()
    WHERE profile_name = p_profile;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown optimization profile: %. Available: standard, fine_grained, ultra_fine, low_overhead, high_retention, forensic', p_profile;
    END IF;

    -- Get current values
    v_old_slots := pgfr_record._get_config('ring_buffer_slots', '120');
    v_old_interval := pgfr_record._get_config('sample_interval_seconds', '60');
    v_old_archive := pgfr_record._get_config('archive_sample_frequency_minutes', '15');

    -- Check if rebuild will be needed
    SELECT COUNT(*) INTO v_current_slots FROM pgfr_record.samples_ring;
    IF v_current_slots != v_profile.slots THEN
        v_rebuild_needed := true;
    END IF;

    -- Update ring_buffer_slots
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('ring_buffer_slots', v_profile.slots::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_profile.slots::text, updated_at = now();

    RETURN QUERY SELECT
        'ring_buffer_slots'::text,
        v_old_slots,
        v_profile.slots::text,
        (v_old_slots IS DISTINCT FROM v_profile.slots::text);

    -- Update sample_interval_seconds
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('sample_interval_seconds', v_profile.sample_interval_seconds::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_profile.sample_interval_seconds::text, updated_at = now();

    RETURN QUERY SELECT
        'sample_interval_seconds'::text,
        v_old_interval,
        v_profile.sample_interval_seconds::text,
        (v_old_interval IS DISTINCT FROM v_profile.sample_interval_seconds::text);

    -- Update archive_sample_frequency_minutes
    INSERT INTO pgfr_record.config (key, value, updated_at)
    VALUES ('archive_sample_frequency_minutes', v_profile.archive_frequency_min::text, now())
    ON CONFLICT (key) DO UPDATE SET value = v_profile.archive_frequency_min::text, updated_at = now();

    RETURN QUERY SELECT
        'archive_sample_frequency_minutes'::text,
        v_old_archive,
        v_profile.archive_frequency_min::text,
        (v_old_archive IS DISTINCT FROM v_profile.archive_frequency_min::text);

    -- Warn if rebuild is needed
    IF v_rebuild_needed THEN
        RAISE WARNING 'Ring buffer slot count changed. Run pgfr_record.rebuild_ring_buffers() to resize. Data in ring buffers will be lost.';
    END IF;

    RAISE NOTICE 'Applied optimization profile: % (%)', p_profile, v_profile.description;
END;
$$;
COMMENT ON FUNCTION pgfr_record.apply_optimization_profile(TEXT) IS 'Applies a ring buffer optimization profile. Updates ring_buffer_slots, sample_interval_seconds, and archive_sample_frequency_minutes. Call rebuild_ring_buffers() after if slot count changed.';

-- Preview the configuration changes from applying a specified profile
-- Compares current settings against profile values to show impact before applying
CREATE OR REPLACE FUNCTION pgfr_record.explain_profile(p_profile_name TEXT)
RETURNS TABLE(
    setting_key         TEXT,
    current_value       TEXT,
    profile_value       TEXT,
    will_change         BOOLEAN,
    description         TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pgfr_record.list_profiles() WHERE profile_name = p_profile_name) THEN
        RAISE EXCEPTION 'Unknown profile: %. Run pgfr_record.list_profiles() to see available profiles.', p_profile_name;
    END IF;
    RETURN QUERY
    SELECT
        ps.key::text AS setting_key,
        c.value::text AS current_value,
        ps.value::text AS profile_value,
        (c.value IS DISTINCT FROM ps.value)::boolean AS will_change,
        ps.description::text AS description
    FROM pgfr_record._profile_settings() ps
    LEFT JOIN pgfr_record.config c ON c.key = ps.key
    WHERE ps.profile = p_profile_name
    ORDER BY will_change DESC, ps.key;
END $$;
COMMENT ON FUNCTION pgfr_record.explain_profile(TEXT) IS
'Preview configuration changes for a profile without applying them. Compares current settings against profile values to show what would change.';

-- Applies a named configuration profile to pgfr_record by upserting configuration settings
-- Returns details of changed settings and adjusts recording mode based on the profile
CREATE OR REPLACE FUNCTION pgfr_record.apply_profile(p_profile_name TEXT)
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
    IF NOT EXISTS (SELECT 1 FROM pgfr_record.list_profiles() WHERE profile_name = p_profile_name) THEN
        RAISE EXCEPTION 'Unknown profile: %. Run pgfr_record.list_profiles() to see available profiles.', p_profile_name;
    END IF;
    RAISE NOTICE 'Applying profile: %', p_profile_name;
    RETURN QUERY
    WITH profile_settings AS (
        SELECT ps.profile, ps.key, ps.value
        FROM pgfr_record._profile_settings() ps
        WHERE ps.profile = p_profile_name
    ),
    updates AS (
        INSERT INTO pgfr_record.config (key, value, updated_at)
        SELECT ps.key, ps.value, now()
        FROM profile_settings ps
        ON CONFLICT (key) DO UPDATE
        SET value = EXCLUDED.value, updated_at = EXCLUDED.updated_at
        WHERE pgfr_record.config.value IS DISTINCT FROM EXCLUDED.value
        RETURNING key, value
    )
    SELECT
        COALESCE(u.key, ps.key)::text AS setting_key,
        c.value::text AS old_value,
        ps.value::text AS new_value,
        (u.key IS NOT NULL)::boolean AS changed
    FROM profile_settings ps
    LEFT JOIN updates u ON u.key = ps.key
    LEFT JOIN pgfr_record.config c ON c.key = ps.key
    ORDER BY changed DESC, setting_key;
    GET DIAGNOSTICS v_changes_made = ROW_COUNT;
    v_mode := CASE p_profile_name
        WHEN 'production_safe' THEN 'emergency'
        WHEN 'minimal_overhead' THEN 'emergency'
        WHEN 'troubleshooting' THEN 'normal'
        ELSE 'normal'
    END;
    PERFORM pgfr_record.set_mode(v_mode);
    RAISE NOTICE 'Profile "%" applied: % settings changed, mode set to %',
        p_profile_name, v_changes_made, v_mode;
END $$;
COMMENT ON FUNCTION pgfr_record.apply_profile(TEXT) IS
'Apply a named configuration profile by upserting all profile settings. Also sets the operating mode (normal or emergency) based on the profile. Returns details of which settings changed.';

-- Identifies the closest matching predefined profile for current configuration and returns match percentage with differences
-- Helps users understand their configuration state relative to available profiles
CREATE OR REPLACE FUNCTION pgfr_record.get_current_profile()
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
    FOR v_profile IN SELECT profile_name FROM pgfr_record.list_profiles() LOOP
        WITH profile_settings AS (
            SELECT setting_key, profile_value
            FROM pgfr_record.explain_profile(v_profile.profile_name)
        ),
        matches AS (
            SELECT
                count(*) FILTER (WHERE NOT will_change) AS matched,
                count(*) AS total,
                array_agg(setting_key) FILTER (WHERE will_change) AS diff_keys
            FROM pgfr_record.explain_profile(v_profile.profile_name)
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
        (SELECT array_agg(setting_key) FROM pgfr_record.explain_profile(v_best_match) WHERE will_change)::text[],
        CASE
            WHEN v_best_pct = 100 THEN 'Configuration matches "' || v_best_match || '" profile perfectly'
            WHEN v_best_pct >= 80 THEN 'Configuration is close to "' || v_best_match || '" profile'
            WHEN v_best_pct >= 50 THEN 'Configuration is partially based on "' || v_best_match || '" profile'
            ELSE 'Configuration appears to be custom (not matching any profile)'
        END::text;
END $$;
COMMENT ON FUNCTION pgfr_record.get_current_profile() IS
'Identifies the closest matching predefined profile for current configuration. Returns profile name, match percentage, differences array, and a recommendation.';

DROP FUNCTION IF EXISTS pgfr_record.cleanup(INTERVAL);

-- Removes old snapshot and sample data based on configured retention periods
-- Cleans up snapshots, statement_snapshots, replication_snapshots tables
CREATE OR REPLACE FUNCTION pgfr_record.cleanup(p_retain_interval INTERVAL DEFAULT NULL)
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
            pgfr_record._get_config('retention_samples_days', '7')::integer,
            7
        );
        v_snapshots_retention_days := COALESCE(
            pgfr_record._get_config('retention_snapshots_days', '30')::integer,
            30
        );
        v_statements_retention_days := COALESCE(
            pgfr_record._get_config('retention_statements_days', '30')::integer,
            30
        );
        v_stats_retention_days := COALESCE(
            pgfr_record._get_config('retention_collection_stats_days', '30')::integer,
            30
        );
        v_samples_cutoff := now() - (v_samples_retention_days || ' days')::interval;
        v_snapshots_cutoff := now() - (v_snapshots_retention_days || ' days')::interval;
        v_statements_cutoff := now() - (v_statements_retention_days || ' days')::interval;
        v_stats_cutoff := now() - (v_stats_retention_days || ' days')::interval;
    END IF;
    v_deleted_samples := 0;
    WITH deleted AS (
        DELETE FROM pgfr_record.snapshots WHERE captured_at < v_snapshots_cutoff RETURNING 1
    )
    SELECT count(*) INTO v_deleted_snapshots FROM deleted;
    WITH deleted AS (
        DELETE FROM pgfr_record.statement_snapshots
        WHERE snapshot_id IN (
            SELECT id FROM pgfr_record.snapshots WHERE captured_at < v_statements_cutoff
        )
        RETURNING 1
    )
    SELECT count(*) INTO v_deleted_statements FROM deleted;
    WITH deleted AS (
        DELETE FROM pgfr_record.collection_stats WHERE started_at < v_stats_cutoff RETURNING 1
    )
    SELECT count(*) INTO v_deleted_stats FROM deleted;
    RETURN QUERY SELECT v_deleted_snapshots, v_deleted_samples, v_deleted_statements, v_deleted_stats;
END;
$$;
COMMENT ON FUNCTION pgfr_record.cleanup(INTERVAL) IS
'Remove old data based on configured retention periods (snapshots, statements, collection_stats). Pass an interval to override per-table retention, or NULL to use configured defaults.';

DROP FUNCTION IF EXISTS pgfr_record.ring_buffer_health();

-- Monitor ring buffer health: XID age, dead tuple bloat, HOT update effectiveness, and autovacuum status
CREATE OR REPLACE FUNCTION pgfr_record.ring_buffer_health()
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
    WHERE n.nspname = 'pgfr_record'
      AND c.relkind = 'r'
      AND c.relname IN ('samples_ring', 'wait_samples_ring', 'activity_samples_ring', 'lock_samples_ring')
    ORDER BY c.relname;
$$;
COMMENT ON FUNCTION pgfr_record.ring_buffer_health() IS

'Monitor ring buffer XID age, dead tuple bloat, and HOT update effectiveness. samples_ring uses UPSERT (1,440x/day) and should achieve >90% HOT update ratio with fillfactor=70. Child tables use DELETE/INSERT so HOT updates are N/A.';
-- Disable Flight Recorder by unscheduling all cron jobs and updating the enabled configuration flag to false
CREATE OR REPLACE FUNCTION pgfr_record.disable()
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_unscheduled INTEGER := 0;
BEGIN
    BEGIN
        PERFORM cron.unschedule('pgfr_snapshot')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_snapshot');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_sample')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_sample');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_cleanup')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_cleanup');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_flush')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_flush');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        PERFORM cron.unschedule('pgfr_archive')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_archive');
        IF FOUND THEN v_unscheduled := v_unscheduled + 1; END IF;
        INSERT INTO pgfr_record.config (key, value, updated_at)
        VALUES ('enabled', 'false', now())
        ON CONFLICT (key) DO UPDATE SET value = 'false', updated_at = now();
        RETURN format('Flight Recorder collection stopped. Unscheduled %s cron jobs. Use pgfr_record.enable() to restart.', v_unscheduled);
    EXCEPTION
        WHEN undefined_table THEN
            RETURN 'pg_cron extension not found. No jobs to unschedule.';
        WHEN undefined_function THEN
            RETURN 'pg_cron extension not found. No jobs to unschedule.';
    END;
END;
$$;
COMMENT ON FUNCTION pgfr_record.disable() IS
'Stop Flight Recorder by unscheduling all pg_cron jobs (sample, snapshot, flush, archive, cleanup) and setting enabled=false. Use enable() to restart.';

-- Configure autovacuum on ring buffer tables
-- Ring buffers use pre-allocated rows with UPDATE-only pattern, achieving high HOT update ratios.
-- With fillfactor 70-90, most updates are HOT (no dead tuples in indexes), but tuple chains still
-- form within pages. Autovacuum collapses these chains. Since ring buffers are fixed-size UNLOGGED
-- tables with bounded bloat, autovacuum is optional - page pruning during UPSERTs provides cleanup.
-- Autovacuum enabled by default; disable for minimal observer effect if desired.
CREATE OR REPLACE FUNCTION pgfr_record.configure_ring_autovacuum(p_enabled BOOLEAN DEFAULT true)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_status TEXT;
BEGIN
    EXECUTE format('ALTER TABLE pgfr_record.samples_ring SET (autovacuum_enabled = %L)', p_enabled);
    EXECUTE format('ALTER TABLE pgfr_record.wait_samples_ring SET (autovacuum_enabled = %L)', p_enabled);
    EXECUTE format('ALTER TABLE pgfr_record.activity_samples_ring SET (autovacuum_enabled = %L)', p_enabled);
    EXECUTE format('ALTER TABLE pgfr_record.lock_samples_ring SET (autovacuum_enabled = %L)', p_enabled);

    IF p_enabled THEN
        v_status := 'Autovacuum ENABLED on ring buffer tables. Autovacuum will periodically collapse HOT chains.';
    ELSE
        v_status := 'Autovacuum DISABLED on ring buffer tables. Page pruning during UPSERTs handles cleanup.';
    END IF;

    RETURN v_status;
END;
$$;

COMMENT ON FUNCTION pgfr_record.configure_ring_autovacuum(BOOLEAN) IS
'Toggle autovacuum on ring buffer tables. Enabled by default (PostgreSQL standard behavior). Ring buffers are fixed-size UNLOGGED tables with bounded bloat, so autovacuum can be disabled to minimize observer effect if desired.';

-- Rebuilds ring buffers to match configured slot count
-- WARNING: This clears all data in ring buffers (archives and aggregates are preserved)
CREATE OR REPLACE FUNCTION pgfr_record.rebuild_ring_buffers(p_slots INTEGER DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    v_target_slots INTEGER;
    v_current_slots INTEGER;
    v_autovacuum_enabled BOOLEAN := true;
BEGIN
    -- Get target slot count from param or config
    v_target_slots := COALESCE(p_slots, pgfr_record._get_ring_buffer_slots());

    -- Validate range
    IF v_target_slots < 72 OR v_target_slots > 2880 THEN
        RAISE EXCEPTION 'Ring buffer slots must be between 72 and 2880. Got: %', v_target_slots;
    END IF;

    -- Get current slot count
    SELECT COUNT(*) INTO v_current_slots FROM pgfr_record.samples_ring;

    -- Check if resize is needed
    IF v_current_slots = v_target_slots THEN
        RETURN format('Ring buffers already sized for %s slots. No rebuild needed.', v_target_slots);
    END IF;

    -- Preserve autovacuum setting
    SELECT COALESCE(
        (SELECT reloptions::text LIKE '%autovacuum_enabled=false%'
         FROM pg_class WHERE relname = 'samples_ring' AND relnamespace = 'pgfr_record'::regnamespace),
        false
    ) INTO v_autovacuum_enabled;
    v_autovacuum_enabled := NOT v_autovacuum_enabled;  -- Invert because we checked for false

    RAISE NOTICE 'Rebuilding ring buffers from % to % slots...', v_current_slots, v_target_slots;

    -- TRUNCATE CASCADE clears all child tables via FK
    TRUNCATE pgfr_record.samples_ring CASCADE;

    -- Rebuild samples_ring
    INSERT INTO pgfr_record.samples_ring (slot_id, captured_at, epoch_seconds)
    SELECT
        generate_series AS slot_id,
        '1970-01-01'::timestamptz,
        0
    FROM generate_series(0, v_target_slots - 1);

    -- Rebuild wait_samples_ring
    INSERT INTO pgfr_record.wait_samples_ring (slot_id, row_num)
    SELECT s.slot_id, r.row_num
    FROM generate_series(0, v_target_slots - 1) s(slot_id)
    CROSS JOIN generate_series(0, 99) r(row_num);

    -- Rebuild activity_samples_ring
    INSERT INTO pgfr_record.activity_samples_ring (slot_id, row_num)
    SELECT s.slot_id, r.row_num
    FROM generate_series(0, v_target_slots - 1) s(slot_id)
    CROSS JOIN generate_series(0, 24) r(row_num);

    -- Rebuild lock_samples_ring
    INSERT INTO pgfr_record.lock_samples_ring (slot_id, row_num)
    SELECT s.slot_id, r.row_num
    FROM generate_series(0, v_target_slots - 1) s(slot_id)
    CROSS JOIN generate_series(0, 99) r(row_num);

    -- Restore autovacuum setting
    IF NOT v_autovacuum_enabled THEN
        PERFORM pgfr_record.configure_ring_autovacuum(false);
    END IF;

    -- Update config if p_slots was provided
    IF p_slots IS NOT NULL THEN
        INSERT INTO pgfr_record.config (key, value, updated_at)
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
COMMENT ON FUNCTION pgfr_record.rebuild_ring_buffers(INTEGER) IS 'Rebuilds ring buffers to match configured slot count (72-2880). WARNING: Clears all ring buffer data. Archives and aggregates are preserved. Pass slot count as parameter or use ring_buffer_slots config.';

-- Enables flight recorder by scheduling periodic cron jobs for collection, archival, and cleanup
-- Requires pg_cron extension; returns status message on success
CREATE OR REPLACE FUNCTION pgfr_record.enable()
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
    v_mode := pgfr_record._get_config('mode', 'normal');
    v_sample_interval_seconds := COALESCE(
        pgfr_record._get_config('sample_interval_seconds', '60')::integer,
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
        PERFORM cron.schedule('pgfr_snapshot', '* * * * *', 'SET statement_timeout = ''10s''; SELECT pgfr_record.snapshot()');
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
        PERFORM cron.schedule('pgfr_sample', v_cron_expression, 'SET statement_timeout = ''5s''; SELECT pgfr_record.sample()');
        v_scheduled := v_scheduled + 1;
        PERFORM cron.schedule('pgfr_flush', '*/5 * * * *', 'SET statement_timeout = ''10s''; SELECT pgfr_record.flush_ring_to_aggregates()');
        v_scheduled := v_scheduled + 1;
        PERFORM cron.schedule('pgfr_archive', '*/15 * * * *', 'SET statement_timeout = ''10s''; SELECT pgfr_record.archive_ring_samples()');
        v_scheduled := v_scheduled + 1;
        PERFORM cron.schedule('pgfr_cleanup', '0 3 * * *',
            'SET statement_timeout = ''60s''; SELECT pgfr_record.cleanup_aggregates(); SELECT * FROM pgfr_record.cleanup(''30 days''::interval);');
        v_scheduled := v_scheduled + 1;
        -- Nightly retention GC (03:00 UTC): truncate expired v2 partitions
        perform cron.schedule('pgfr-truncate-old-partitions', '0 3 * * *',
            'select pgfr_record.truncate_old_partitions()')
        where not exists (
            select 1 from cron.job where jobname = 'pgfr-truncate-old-partitions'
        );
        v_scheduled := v_scheduled + 1;
        -- Monthly catalog cleanup (1st of month, 04:00 UTC): drop ancient empty partitions
        perform cron.schedule('pgfr-drop-ancient-partitions', '0 4 1 * *',
            'select pgfr_record.drop_ancient_partitions()')
        where not exists (
            select 1 from cron.job where jobname = 'pgfr-drop-ancient-partitions'
        );
        v_scheduled := v_scheduled + 1;
        INSERT INTO pgfr_record.config (key, value, updated_at)
        VALUES ('enabled', 'true', now())
        ON CONFLICT (key) DO UPDATE SET value = 'true', updated_at = now();
        -- Emit warnings for suboptimal ring buffer configuration
        DECLARE
            v_check RECORD;
        BEGIN
            FOR v_check IN
                SELECT * FROM pgfr_record.validate_ring_configuration()
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
COMMENT ON FUNCTION pgfr_record.enable() IS
'Start Flight Recorder by scheduling pg_cron jobs for sample collection, snapshots, flush, archival, and cleanup. Requires pg_cron extension. Configures schedules based on current mode and sample interval.';

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
        PERFORM cron.unschedule('pgfr_snapshot')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_snapshot');
        PERFORM cron.unschedule('pgfr_sample')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_sample');
        PERFORM cron.unschedule('pgfr_flush')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_flush');
        PERFORM cron.unschedule('pgfr_cleanup')
        WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pgfr_cleanup');
    EXCEPTION
        WHEN undefined_table THEN NULL;
        WHEN undefined_function THEN NULL;
    END;
    SELECT value::integer INTO v_sample_interval_seconds
    FROM pgfr_record.config
    WHERE key = 'sample_interval_seconds';
    v_sample_interval_seconds := COALESCE(v_sample_interval_seconds, 60);
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
        'pgfr_snapshot',
        '* * * * *',
        'SET statement_timeout = ''10s''; SELECT pgfr_record.snapshot()'
    );
    PERFORM cron.schedule(
        'pgfr_sample',
        '* * * * *',
        'SET statement_timeout = ''5s''; SELECT pgfr_record.sample()'
    );
    v_sample_schedule := 'every 60 seconds (ring buffer)';
    RAISE NOTICE 'Flight Recorder installed. Sampling %', v_sample_schedule;
    PERFORM cron.schedule(
        'pgfr_flush',
        '*/5 * * * *',
        'SET statement_timeout = ''10s''; SELECT pgfr_record.flush_ring_to_aggregates()'
    );
    PERFORM cron.schedule(
        'pgfr_archive',
        '*/15 * * * *',
        'SET statement_timeout = ''10s''; SELECT pgfr_record.archive_ring_samples()'
    );
    PERFORM cron.schedule(
        'pgfr_cleanup',
        '0 3 * * *',
        'SET statement_timeout = ''60s''; SELECT pgfr_record.cleanup_aggregates(); SELECT * FROM pgfr_record.cleanup(''30 days''::interval);'
    );
    -- Nightly retention GC (03:00 UTC): truncate expired partitions
    perform cron.schedule('pgfr-truncate-old-partitions', '0 3 * * *',
        'select pgfr_record.truncate_old_partitions()')
    where not exists (
        select 1 from cron.job where jobname = 'pgfr-truncate-old-partitions'
    );
    -- Monthly catalog cleanup (1st of month, 04:00 UTC): drop ancient empty partitions
    perform cron.schedule('pgfr-drop-ancient-partitions', '0 4 1 * *',
        'select pgfr_record.drop_ancient_partitions()')
    where not exists (
        select 1 from cron.job where jobname = 'pgfr-drop-ancient-partitions'
    );
EXCEPTION
    WHEN undefined_table THEN
        RAISE NOTICE 'pg_cron extension not found. Automatic scheduling disabled. Run pgfr_record.snapshot() and pgfr_record.sample() manually or via external scheduler.';
    WHEN undefined_function THEN
        RAISE NOTICE 'pg_cron extension not found. Automatic scheduling disabled. Run pgfr_record.snapshot() and pgfr_record.sample() manually or via external scheduler.';
END;
$$;

-- Performs comprehensive health check of Flight Recorder system components
-- Reports status, metrics, and recommended actions for critical subsystems
CREATE OR REPLACE FUNCTION pgfr_record.health_check()
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
    v_enabled := pgfr_record._get_config('enabled', 'true');
    IF v_enabled = 'false' THEN
        RETURN QUERY SELECT
            'Flight Recorder System'::text,
            'DISABLED'::text,
            'Collection is disabled'::text,
            'Run pgfr_record.enable() to restart'::text;
        RETURN;
    END IF;
    RETURN QUERY SELECT
        'Flight Recorder System'::text,
        'ENABLED'::text,
        format('Mode: %s', pgfr_record._get_config('mode', 'normal')),
        NULL::text;
    SELECT s.schema_size_mb, s.critical_threshold_mb, s.status
    INTO v_schema_size_mb, v_schema_critical_mb, v_enabled
    FROM pgfr_record._check_schema_size() s;
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
    FROM pgfr_record.collection_stats
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
    SELECT max(captured_at) INTO v_last_sample FROM pgfr_record.samples_ring;
    SELECT max(captured_at) INTO v_last_snapshot FROM pgfr_record.snapshots;
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
    SELECT count(*) INTO v_sample_count FROM pgfr_record.samples_ring;
    SELECT count(*) INTO v_snapshot_count FROM pgfr_record.snapshots;
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
    FROM pgfr_record._check_statements_health() h;
    DECLARE
        v_job_count INTEGER;
        v_active_jobs INTEGER;
        v_missing_jobs TEXT[];
        v_inactive_jobs TEXT[];
    BEGIN
        WITH required_jobs AS (
            SELECT unnest(ARRAY[
                'pgfr_sample',
                'pgfr_snapshot',
                'pgfr_flush',
                'pgfr_cleanup'
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
                    'Run pgfr_record.enable() to restore missing/inactive jobs'
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
COMMENT ON FUNCTION pgfr_record.health_check() IS
'Comprehensive system health check reporting status, metrics, and recommended actions for: system state, schema size, circuit breaker, sample/snapshot collection, pg_stat_statements, pg_cron jobs, and data volume.';

-- Exports all data before an upgrade, saving to a file for backup
-- Returns summary of what was exported and the recommended restore command
CREATE OR REPLACE FUNCTION pgfr_record.export_for_upgrade()
RETURNS TABLE(
    data_type TEXT,
    row_count BIGINT,
    date_range TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_version TEXT;
BEGIN
    SELECT value INTO v_version FROM pgfr_record.config WHERE key = 'schema_version';

    RAISE NOTICE '';
    RAISE NOTICE '=== Flight Recorder Export for Upgrade ===';
    RAISE NOTICE 'Current version: %', COALESCE(v_version, 'unknown');
    RAISE NOTICE '';
    RAISE NOTICE 'To export all data, run:';
    RAISE NOTICE '  psql -At -c "SELECT pgfr_record.report(now() - interval ''30 days'', now())" > backup.md';
    RAISE NOTICE '';
    RAISE NOTICE 'Or for specific tables:';
    RAISE NOTICE '  pg_dump -t pgfr_record.snapshots -t pgfr_record.statement_snapshots ... > backup.sql';
    RAISE NOTICE '';

    -- Return summary of data that would be exported
    RETURN QUERY
    SELECT 'snapshots'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.snapshots;

    RETURN QUERY
    SELECT 'statement_snapshots'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.statement_snapshots;

    RETURN QUERY
    SELECT 'table_snapshots'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.table_snapshots;

    RETURN QUERY
    SELECT 'index_snapshots'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.index_snapshots;

    RETURN QUERY
    SELECT 'activity_samples_archive'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.activity_samples_archive;

    RETURN QUERY
    SELECT 'lock_samples_archive'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.lock_samples_archive;

    RETURN QUERY
    SELECT 'wait_samples_archive'::TEXT, count(*)::BIGINT,
           min(captured_at)::TEXT || ' to ' || max(captured_at)::TEXT
    FROM pgfr_record.wait_samples_archive;

    RETURN QUERY
    SELECT 'wait_event_aggregates'::TEXT, count(*)::BIGINT,
           min(window_start)::TEXT || ' to ' || max(window_end)::TEXT
    FROM pgfr_record.wait_event_aggregates;

    RETURN QUERY
    SELECT 'activity_aggregates'::TEXT, count(*)::BIGINT,
           min(window_start)::TEXT || ' to ' || max(window_end)::TEXT
    FROM pgfr_record.activity_aggregates;

    RETURN QUERY
    SELECT 'lock_aggregates'::TEXT, count(*)::BIGINT,
           min(window_start)::TEXT || ' to ' || max(window_end)::TEXT
    FROM pgfr_record.lock_aggregates;

    RETURN QUERY
    SELECT 'config'::TEXT, count(*)::BIGINT,
           'current settings'::TEXT
    FROM pgfr_record.config;
END;
$$;
COMMENT ON FUNCTION pgfr_record.export_for_upgrade() IS
'Returns summary of all stored data (snapshots, statements, archives, aggregates, config) with row counts and date ranges. Use before pg_dump to assess export scope.';

-- Analyzes current metrics (schema size, sample duration, retention settings) and returns configuration optimization recommendations
-- Provides actionable SQL commands for performance, storage, and automation tuning
CREATE OR REPLACE FUNCTION pgfr_record.config_recommendations()
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
    v_mode := pgfr_record._get_config('mode', 'normal');
    SELECT schema_size_mb INTO v_schema_size_mb FROM pgfr_record._check_schema_size();
    SELECT count(*) INTO v_sample_count FROM pgfr_record.samples_ring;
    SELECT count(*) INTO v_snapshot_count FROM pgfr_record.snapshots;
    SELECT avg(duration_ms) INTO v_avg_sample_ms
    FROM pgfr_record.collection_stats
    WHERE collection_type = 'sample'
      AND success = true
      AND skipped = false
      AND started_at > now() - interval '24 hours';
    v_retention_samples := pgfr_record._get_config('retention_samples_days', '7')::integer;
    v_retention_snapshots := pgfr_record._get_config('retention_snapshots_days', '30')::integer;
    IF v_avg_sample_ms > 1000 AND v_mode = 'normal' THEN
        RETURN QUERY SELECT
            'Performance'::text,
            'Switch to light mode'::text,
            format('Average sample duration is %s ms, which may impact system performance', round(v_avg_sample_ms)),
            'SELECT pgfr_record.set_mode(''light'');'::text;
    END IF;
    IF v_schema_size_mb > 5000 THEN
        RETURN QUERY SELECT
            'Storage'::text,
            'Run cleanup to reclaim space'::text,
            format('Schema size is %s MB', round(v_schema_size_mb)::text),
            'SELECT * FROM pgfr_record.cleanup();'::text;
    END IF;
    IF v_sample_count > 50000 AND v_retention_samples > 7 THEN
        RETURN QUERY SELECT
            'Storage'::text,
            'Reduce sample retention period'::text,
            format('High sample count (%s) with %s day retention', v_sample_count, v_retention_samples),
            format('UPDATE pgfr_record.config SET value = ''3'' WHERE key = ''retention_samples_days'';')::text;
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
COMMENT ON FUNCTION pgfr_record.config_recommendations() IS
'Analyzes current system metrics (schema size, sample duration, retention) and returns actionable tuning recommendations with SQL commands for performance, storage, and automation.';



-- =============================================================================
-- Phase 1: Core Partition Infrastructure (Issue #2)
-- Implements §7.1 and §7.2 of blueprints/SPEC.md
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. pgfr_record.epoch()
--    Fixed installation epoch for int4 sample_ts offsets.
--    WARNING: must never change after installation — all sample_ts values are
--    seconds offset from this point. Changing it corrupts all timestamps.
--    See §7.1 and Q6 in SPEC.md.
-- -----------------------------------------------------------------------------
create or replace function pgfr_record.epoch()
returns timestamptz
immutable
language sql
as $$
    select '2026-01-01 00:00:00+00'::timestamptz;
$$;

comment on function pgfr_record.epoch() is
'Fixed installation epoch (2026-01-01 UTC) for int4 sample_ts offsets. '
'NEVER change this after installation — all stored timestamps are seconds '
'relative to this point. Overflow horizon: ~2094. '
'See blueprints/SPEC.md §7.1 and Q6.';

-- -----------------------------------------------------------------------------
-- 2. pgfr_record._ensure_partition(p_table text, p_date date)
--    Idempotent daily partition creator.
--    O(1) happy path: returns immediately if partition already exists.
--    Creates partition with UTC-enforced bounds + B-tree + BRIN indexes.
--    Safe to call from snapshot() on every tick as a runtime safety net.
--
--    WARNING: p_table must have columns (queryid, dbid, userid, toplevel, sample_ts)
--    — the B-tree index is hardcoded to these columns. Calls for tables without
--    these columns will fail with 'column does not exist'.
-- -----------------------------------------------------------------------------
create or replace function pgfr_record._ensure_partition(
    p_table text,
    p_date  date
)
returns void
language plpgsql
as $$
declare
    v_partition_name text;
    v_bound_start    int4;
    v_bound_end      int4;
    v_date_start_ts  timestamptz;
    v_date_end_ts    timestamptz;
begin
    -- Column contract: p_table must have (queryid, dbid, userid, toplevel, sample_ts).
    -- The B-tree index below is hardcoded to these columns; missing columns cause
    -- 'column does not exist' errors. Verify your table schema before calling.

    -- Derive partition name from date (YYYY_MM_DD suffix)
    v_partition_name := p_table || '_' || to_char(p_date, 'YYYY_MM_DD');

    -- O(1) happy path: check pg_class, return immediately if partition exists.
    -- No DDL, no lock acquisition on the common code path.
    if exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = v_partition_name
    ) then
        return;
    end if;

    -- Compute UTC-enforced int4 bounds.
    -- Always use explicit +00 to prevent session timezone drift (pg_cron risk).
    -- Format: 'YYYY-MM-DD 00:00:00+00'::timestamptz to be unambiguous.
    v_date_start_ts := (to_char(p_date,     'YYYY-MM-DD') || ' 00:00:00+00')::timestamptz;
    v_date_end_ts   := (to_char(p_date + 1, 'YYYY-MM-DD') || ' 00:00:00+00')::timestamptz;

    v_bound_start := extract(epoch from (v_date_start_ts - pgfr_record.epoch()))::int4;
    v_bound_end   := extract(epoch from (v_date_end_ts   - pgfr_record.epoch()))::int4;

    -- Create the partition
    execute format(
        'create table if not exists pgfr_record.%I
         partition of pgfr_record.%I
         for values from (%s) to (%s)',
        v_partition_name,
        p_table,
        v_bound_start,
        v_bound_end
    );

    -- B-tree index: supports point-in-time reconstruction and sparse insert lookback.
    -- Access pattern: filter on (queryid, dbid, userid, toplevel), order by sample_ts DESC.
    -- Requires columns: queryid, dbid, userid, toplevel, sample_ts (see column contract above).
    execute format(
        'create index if not exists %I
         on pgfr_record.%I (queryid, dbid, userid, toplevel, sample_ts desc)',
        v_partition_name || '_btree_idx',
        v_partition_name
    );

    -- BRIN index: for pure time-range aggregate queries ("last hour").
    -- pages_per_range=8 chosen for sparse workloads (50-200 rows/tick).
    -- Within-day insert order guarantees high correlation for BRIN effectiveness.
    execute format(
        'create index if not exists %I
         on pgfr_record.%I
         using brin (sample_ts) with (pages_per_range = 8)',
        v_partition_name || '_brin_idx',
        v_partition_name
    );

end;
$$;

comment on function pgfr_record._ensure_partition(text, date) is
'Idempotent daily partition creator for pgfr_record partitioned tables. '
'O(1) happy path via pg_class existence check — returns immediately if partition exists. '
'UTC-enforced bounds prevent session timezone drift. '
'Creates B-tree index (queryid, dbid, userid, toplevel, sample_ts DESC) for point-in-time reads '
'and BRIN index (sample_ts, pages_per_range=8) for time-range aggregates. '
'Safe to call from snapshot() on every tick. See blueprints/SPEC.md §7.2. '
'WARNING: p_table must have columns (queryid, dbid, userid, toplevel, sample_ts) — '
'the B-tree index is hardcoded to these columns. Calls for tables without these columns '
'will fail with ''column does not exist''.';

-- -----------------------------------------------------------------------------
-- 3. pgfr_record._partition_inventory()
--    Catalog-based partition introspection. Used by truncate/drop GC functions
--    and the partition_gc_health view.
--
--    Runtime assertions at entry:
--      - RANGE partitioning only
--      - Single partition key column
--      - int4 (atttypid = 23) key type
--    Raises exception on violation — silent corruption is worse than loud failure.
--
--    is_empty: uses pg_relation_size(oid) = 0 ONLY.
--              Never reltuples — lags until next ANALYZE, unreliable post-TRUNCATE.
--
--    Bound parsing: defensive regex on pg_get_expr() output via LATERAL join.
--                   pg_get_expr format is not guaranteed stable across PG versions.
--                   Fails loudly on unexpected format (strict assertion).
--                   LATERAL join evaluates regexp_match once per row (not 5×).
-- -----------------------------------------------------------------------------
create or replace function pgfr_record._partition_inventory()
returns table (
    parent_table   text,
    partition_name text,
    bound_start    int4,
    bound_end      int4,
    is_expired     boolean,
    is_ancient     boolean,
    is_empty       boolean
)
language plpgsql
stable
as $$
declare
    v_partstrat      char;
    v_partnatts      int2;
    v_atttypid       oid;
    v_retention_days int;
    v_cutoff_ts      timestamptz;
    v_cutoff         int4;
    v_ancient_cutoff int4;
    v_parent_oid     oid;
    v_parent_name    text;
begin
    -- -------------------------------------------------------------------------
    -- Runtime assertions: verify all pgfr_record partitioned tables conform.
    -- We assert once per parent, fail loudly on first violation.
    -- -------------------------------------------------------------------------
    for v_parent_oid, v_parent_name in
        select pt.partrelid, pc.relname
        from pg_catalog.pg_partitioned_table pt
        join pg_catalog.pg_class pc on pc.oid = pt.partrelid
        join pg_catalog.pg_namespace pn on pn.oid = pc.relnamespace
        where pn.nspname = 'pgfr_record'
    loop
        select pt.partstrat, pt.partnatts
          into v_partstrat, v_partnatts
        from pg_catalog.pg_partitioned_table pt
        where pt.partrelid = v_parent_oid;

        -- Assert RANGE partitioning
        if v_partstrat <> 'r' then
            raise exception
                '_partition_inventory(): table pgfr_record.% uses partitioning strategy "%" — '
                'only RANGE (r) is supported. Fix the table or exclude it from pgfr_record schema.',
                v_parent_name, v_partstrat;
        end if;

        -- Assert single partition key column
        if v_partnatts <> 1 then
            raise exception
                '_partition_inventory(): table pgfr_record.% has % partition key columns — '
                'only single-column RANGE partitioning on int4 is supported.',
                v_parent_name, v_partnatts;
        end if;

        -- Assert int4 (oid=23) partition key type
        select pa.atttypid into v_atttypid
        from pg_catalog.pg_partitioned_table pt
        join pg_catalog.pg_attribute pa
          on pa.attrelid = pt.partrelid
         and pa.attnum   = pt.partattrs[0]
        where pt.partrelid = v_parent_oid;

        if v_atttypid <> 23 then  -- 23 = int4
            raise exception
                '_partition_inventory(): table pgfr_record.% partition key type OID is % — '
                'expected int4 (OID 23). Only int4 partition keys are supported.',
                v_parent_name, v_atttypid;
        end if;
    end loop;

    -- -------------------------------------------------------------------------
    -- Compute retention cutoffs
    -- -------------------------------------------------------------------------
    v_retention_days := coalesce(
        pgfr_record._get_config('retention_snapshots_days', '30')::int,
        30
    );

    -- Cutoff for is_expired: upper bound < now - retention_days (UTC)
    v_cutoff_ts := date_trunc('day', now() at time zone 'UTC') at time zone 'UTC'
                   - (v_retention_days || ' days')::interval;
    v_cutoff    := extract(epoch from (v_cutoff_ts - pgfr_record.epoch()))::int4;

    -- Cutoff for is_ancient: upper bound < now - 2× retention_days (UTC)
    v_ancient_cutoff := extract(epoch from
        (v_cutoff_ts - (v_retention_days || ' days')::interval - pgfr_record.epoch())
    )::int4;

    -- -------------------------------------------------------------------------
    -- Main catalog query with defensive bound parsing via LATERAL join.
    -- regexp_match is called once per row (not 5×) — evaluated in the LATERAL
    -- subquery and referenced by column alias in the SELECT list.
    -- -------------------------------------------------------------------------
    return query
    select
        parent.relname::text                              as parent_table,
        child.relname::text                               as partition_name,
        -- Lower int4 bound from LATERAL-parsed regex result.
        -- Expected format: "FOR VALUES FROM (NNN) TO (MMM)"
        parsed.bounds[1]::int4                            as bound_start,
        -- Upper int4 bound (second capture group)
        parsed.bounds[2]::int4                            as bound_end,
        -- is_expired: partition upper bound falls before retention cutoff
        (parsed.bounds[2]::int4 < v_cutoff)              as is_expired,
        -- is_ancient: partition upper bound falls before 2× retention cutoff
        (parsed.bounds[2]::int4 < v_ancient_cutoff)      as is_ancient,
        -- is_empty: authoritative — pg_relation_size = 0.
        -- Never reltuples: lags until ANALYZE, unreliable post-TRUNCATE.
        (pg_catalog.pg_relation_size(child.oid) = 0)     as is_empty
    from pg_catalog.pg_inherits i
    join pg_catalog.pg_class child   on child.oid  = i.inhrelid
    join pg_catalog.pg_class parent  on parent.oid = i.inhparent
    join pg_catalog.pg_namespace n   on n.oid      = child.relnamespace
    -- LATERAL: evaluate regexp_match once per row; result reused for all 5 references above.
    -- Defensive regex on pg_get_expr() output — pg_get_expr format not guaranteed stable.
    cross join lateral (
        select regexp_match(
            pg_catalog.pg_get_expr(child.relpartbound, child.oid),
            E'FOR VALUES FROM \\(([-]?\\d+)\\) TO \\(([-]?\\d+)\\)'
        ) as bounds
    ) as parsed
    where n.nspname = 'pgfr_record'
      -- Only RANGE partitions (skip non-partition children if any)
      and child.relkind = 'r'
      -- Exclude children with unparseable bounds (assertion loop above catches parent violations).
      -- Any child that doesn't match the regex is excluded here; schema violations on
      -- the parent are caught by the assertion loop above.
      and parsed.bounds is not null
    order by parent.relname, child.relname;

    -- Post-query check: if any child had unparseable bounds, the assertion loop
    -- above would have already raised. Unparseable children are filtered above.
    -- This is belt-and-suspenders: loudly fail on schema violations.
end;
$$;

comment on function pgfr_record._partition_inventory() is
'Catalog-based partition introspection for pgfr_record schema. '
'Runtime assertions: verifies RANGE partitioning, single column, int4 key type — raises exception on violation. '
'is_empty uses pg_relation_size(oid)=0 ONLY (authoritative after TRUNCATE; never reltuples which lags). '
'LATERAL join evaluates regexp_match once per row (not 5×) for bound parsing efficiency. '
'Defensive regex parsing of pg_get_expr() output — fails loudly on unexpected format. '
'Assumes single-column RANGE partitioning on int4 throughout. '
'Used by truncate_old_partitions(), drop_ancient_partitions(), and partition_gc_health view. '
'See blueprints/SPEC.md §7.2.';

-- -----------------------------------------------------------------------------
-- 4. pgfr_record.truncate_old_partitions()
--    Nightly GC: TRUNCATE partitions that are expired AND non-empty.
--    lock_timeout = 50ms (aggressive — FIFO queue stalls all readers on contention).
--    Loops ALL eligible partitions; skips locked ones (continues to next).
--    Storage reclaimed immediately. Partition definition remains for planner pruning.
-- -----------------------------------------------------------------------------
create or replace function pgfr_record.truncate_old_partitions()
returns void
language plpgsql
as $$
declare
    v_rec             record;
    v_truncated_count int := 0;
    v_skipped_count   int := 0;
begin
    for v_rec in
        select parent_table, partition_name
        from pgfr_record._partition_inventory()
        where is_expired and not is_empty
        order by parent_table, partition_name
    loop
        begin
            -- 50ms timeout: FIFO queue means waiting longer stalls all readers.
            -- If we miss this window, we retry next hour — lag is not permanent.
            set local lock_timeout = '50ms';
            execute format('truncate pgfr_record.%I', v_rec.partition_name);
            v_truncated_count := v_truncated_count + 1;
            raise notice 'pgfr_record: Truncated expired partition pgfr_record.%', v_rec.partition_name;
        exception
            when lock_not_available then
                -- Skip this partition and continue to next — do NOT abort.
                -- Best-effort retention: never stall the collection loop.
                v_skipped_count := v_skipped_count + 1;
                raise notice 'pgfr_record: Skipped pgfr_record.% (lock_timeout exceeded, will retry next run)',
                    v_rec.partition_name;
            when others then
                -- Unexpected error: log and continue to next partition.
                v_skipped_count := v_skipped_count + 1;
                raise warning 'pgfr_record: Failed to truncate pgfr_record.%: %',
                    v_rec.partition_name, sqlerrm;
        end;
    end loop;

    if v_truncated_count > 0 or v_skipped_count > 0 then
        raise notice 'pgfr_record: truncate_old_partitions() complete: % truncated, % skipped',
            v_truncated_count, v_skipped_count;
    end if;
end;
$$;

comment on function pgfr_record.truncate_old_partitions() is
'Nightly GC: TRUNCATE expired (is_expired AND NOT is_empty) partitions from _partition_inventory(). '
'lock_timeout=50ms — aggressive to avoid FIFO queue stalls on ACCESS EXCLUSIVE. '
'Loops ALL eligible partitions; skips locked ones (continues, does not abort). '
'Retention is best-effort under persistent lock contention — never stalls collection. '
'Partition definitions remain attached for planner pruning. '
'Run nightly via pg_cron. See blueprints/SPEC.md §7.2.';

-- -----------------------------------------------------------------------------
-- 5. pgfr_record.drop_ancient_partitions()
--    Monthly slow-path GC: DROP empty partitions older than 2× retention.
--    Targets only is_ancient AND is_empty — safe, no concurrent readers.
--    lock_timeout = 2s (plain DROP TABLE, no DETACH needed — table is empty).
--    Keeps total partition count permanently bounded.
-- -----------------------------------------------------------------------------
create or replace function pgfr_record.drop_ancient_partitions()
returns void
language plpgsql
as $$
declare
    v_rec           record;
    v_dropped_count int := 0;
    v_skipped_count int := 0;
begin
    -- Target: is_ancient (>2× retention window) AND is_empty (already truncated).
    -- Empty partitions have no concurrent readers — plain DROP TABLE suffices.
    -- No DETACH CONCURRENTLY needed: empty table, no live data, no user sessions touching it.
    for v_rec in
        select parent_table, partition_name
        from pgfr_record._partition_inventory()
        where is_ancient and is_empty
        order by parent_table, partition_name
    loop
        begin
            -- 2s timeout: empty partition DROP is fast (catalog change only).
            -- Longer than truncate_old_partitions (50ms) because this is monthly
            -- and the table is empty — contention is unlikely, worth waiting briefly.
            set local lock_timeout = '2s';
            execute format('drop table if exists pgfr_record.%I', v_rec.partition_name);
            v_dropped_count := v_dropped_count + 1;
            raise notice 'pgfr_record: Dropped ancient empty partition pgfr_record.%', v_rec.partition_name;
        exception
            when lock_not_available then
                -- Skip and try next monthly run.
                v_skipped_count := v_skipped_count + 1;
                raise notice 'pgfr_record: Skipped drop of pgfr_record.% (lock_timeout exceeded, will retry next run)',
                    v_rec.partition_name;
            when others then
                v_skipped_count := v_skipped_count + 1;
                raise warning 'pgfr_record: Failed to drop pgfr_record.%: %',
                    v_rec.partition_name, sqlerrm;
        end;
    end loop;

    if v_dropped_count > 0 or v_skipped_count > 0 then
        raise notice 'pgfr_record: drop_ancient_partitions() complete: % dropped, % skipped',
            v_dropped_count, v_skipped_count;
    end if;
end;
$$;

comment on function pgfr_record.drop_ancient_partitions() is
'Monthly slow-path GC: DROP empty partitions older than 2× retention_snapshots_days. '
'Targets is_ancient AND is_empty from _partition_inventory() — safe, no concurrent readers. '
'lock_timeout=2s (plain DROP TABLE; no DETACH needed for empty partitions). '
'Keeps catalog partition count permanently bounded (without this, TRUNCATE-based retention '
'accumulates partition definitions indefinitely). '
'Default cadence: monthly via pg_cron (configurable). See blueprints/SPEC.md §7.2.';

-- -----------------------------------------------------------------------------
-- 6. pgfr_record.partition_gc_health (view)
--    Operator visibility into partition GC state.
--    Shows pending truncations, recently truncated, and ancient partitions
--    awaiting the monthly slow-path DROP — grouped by parent_table.
-- -----------------------------------------------------------------------------
create or replace view pgfr_record.partition_gc_health as
select
    parent_table,
    count(*)                                                              as total_partitions,
    count(*) filter (where is_expired and not is_empty)                  as pending_truncation,
    count(*) filter (where is_expired and is_empty and not is_ancient)   as truncated_recent,
    count(*) filter (where is_ancient and is_empty)                      as pending_drop,
    max(bound_end)  filter (where is_expired and not is_empty)           as oldest_pending_truncation
from pgfr_record._partition_inventory()
group by parent_table;

comment on view pgfr_record.partition_gc_health is
'Operator visibility into partition GC state per parent_table. '
'pending_truncation: expired partitions still holding data (need truncate_old_partitions()). '
'truncated_recent: expired but empty — awaiting monthly drop_ancient_partitions(). '
'pending_drop: ancient (>2× retention) empty partitions ready for DROP. '
'oldest_pending_truncation: max bound_end of non-empty expired partitions (as int4 offset from epoch()). '
'See blueprints/SPEC.md §7.2.';

-- =============================================================================
-- End Phase 1: Core Partition Infrastructure
-- =============================================================================

SELECT pgfr_record.snapshot();
SELECT pgfr_record.sample();
DO $$
DECLARE
    v_sample_schedule TEXT;
BEGIN
    SELECT schedule INTO v_sample_schedule
    FROM cron.job WHERE jobname = 'pgfr_sample';
    RAISE NOTICE '';
    RAISE NOTICE 'Flight Recorder installed successfully.';
    RAISE NOTICE '';
    RAISE NOTICE 'Collection schedule:';
    RAISE NOTICE '  - Snapshots: every minute (WAL, checkpoints, I/O stats) - DURABLE';
    RAISE NOTICE '  - Samples: every 60 seconds (ring buffer, 120 slots, 2-hour retention)';
    RAISE NOTICE '  - Flush: every 5 minutes (ring buffer → durable aggregates)';
    RAISE NOTICE '  - Cleanup: daily at 3 AM (aggregates: 7 days, snapshots: 30 days)';
    RAISE NOTICE '';
    RAISE NOTICE 'Quick start:';
    RAISE NOTICE '  1. Flight Recorder collects automatically in the background';
    RAISE NOTICE '';
    RAISE NOTICE '  2. Query any time window to diagnose performance:';
    RAISE NOTICE '     SELECT * FROM pgfr_analyze.compare(''2024-12-16 14:00'', ''2024-12-16 15:00'');';
    RAISE NOTICE '     SELECT * FROM pgfr_analyze.wait_summary(''2024-12-16 14:00'', ''2024-12-16 15:00'');';
    RAISE NOTICE '';
    RAISE NOTICE '  3. Check capacity and right-sizing:';
    RAISE NOTICE '     SELECT * FROM pgfr_analyze.capacity_dashboard;';
    RAISE NOTICE '     SELECT * FROM pgfr_analyze.capacity_summary(interval ''7 days'');';
    RAISE NOTICE '';
    RAISE NOTICE 'Views for recent activity:';
    RAISE NOTICE '  - pgfr_record.deltas            (snapshot deltas incl. temp files)';
    RAISE NOTICE '  - pgfr_record.recent_waits      (wait events, last 2 hours from ring buffer)';
    RAISE NOTICE '  - pgfr_record.recent_activity   (active sessions, last 2 hours from ring buffer)';
    RAISE NOTICE '  - pgfr_record.recent_locks      (lock contention, last 2 hours from ring buffer)';
    RAISE NOTICE '  - pgfr_record.recent_replication (replication lag, last 2 hours)';
    RAISE NOTICE '';
    RAISE NOTICE 'For autovacuum control functions (vacuum diagnostics, scale factor tuning, bloat analysis):';
    RAISE NOTICE '  psql --single-transaction -f _control/install.sql';
    RAISE NOTICE '';
    RAISE NOTICE 'For analysis & reporting functions (anomaly detection, capacity planning, etc.):';
    RAISE NOTICE '  psql --single-transaction -f _analyze/install.sql';
    RAISE NOTICE '';
END;
$$;
-- =============================================================================
-- Phase 1: Sparse statement_snapshots collector
-- SPEC §5.2 — storage-overhaul-spec branch
-- PG14+ minimum (requires pg_stat_statements_info, toplevel column)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 2. statement_snapshots_v2  — partitioned by range (sample_ts int4)
--    Dual-write: old statement_snapshots stays untouched (see SPEC Q2)
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.statement_snapshots_v2 (
    snapshot_id             bigint          not null,  -- BIGINT per SPEC Q5; accepts INT serial values safely
    sample_ts               INT4            not null,  -- seconds since pgfr_record.epoch()
    queryid                 bigint          not null,
    userid                  oid             not null,
    dbid                    oid             not null,
    toplevel                boolean         not null,  -- PG14+; part of PGSS uniqueness key
    query_preview           text,
    calls                   bigint,
    total_exec_time         DOUBLE PRECISION,
    min_exec_time           DOUBLE PRECISION,
    max_exec_time           DOUBLE PRECISION,
    mean_exec_time          DOUBLE PRECISION,
    rows                    bigint,
    shared_blks_hit         bigint,
    shared_blks_read        bigint,
    shared_blks_dirtied     bigint,
    shared_blks_written     bigint,
    temp_blks_read          bigint,
    temp_blks_written       bigint,
    blk_read_time           DOUBLE PRECISION,
    blk_write_time          DOUBLE PRECISION,
    wal_records             bigint,
    wal_bytes               numeric,
    pgss_dealloc_warning    boolean         not null default false  -- cluster-level PGSS eviction event
) partition by range (sample_ts);

comment on table pgfr_record.statement_snapshots_v2 is
'Sparse PGSS history partitioned by int4 sample_ts (seconds since pgfr_record.epoch()). '
'Dual-write: old statement_snapshots retained. Missing row = no change since last stored row. '
'Readers reconstruct full state via DISTINCT ON ... ORDER BY sample_ts DESC. '
'See SPEC §5.2.';

comment on column pgfr_record.statement_snapshots_v2.pgss_dealloc_warning is
'TRUE when pg_stat_statements_info.dealloc increased since last tick. '
'This is a CLUSTER-WIDE signal: evictions on any database set this flag. '
'Do NOT interpret as "data for this database is missing" — say "cluster-level PGSS evictions".';

-- ---------------------------------------------------------------------------
-- 3. statement_last_state — UNLOGGED HOT-optimized side table
-- ---------------------------------------------------------------------------
create unlogged table if not exists pgfr_record.statement_last_state (
    queryid     bigint  not null,
    dbid        oid     not null,
    userid      oid     not null,
    toplevel    boolean not null,  -- PG14+; part of PGSS uniqueness key
    calls       bigint  not null,
    sample_ts   INT4    not null,
    primary key (queryid, dbid, userid, toplevel)
) with (
    fillfactor = 70,                        -- leave room for HOT updates
    autovacuum_vacuum_scale_factor  = 0.01, -- vacuum after 1% dead tuples
    autovacuum_analyze_scale_factor = 0.01
);

comment on table pgfr_record.statement_last_state is
'HOT-sensitive: do NOT index mutable columns (calls, sample_ts). '
'HOT updates require changed columns to be unindexed. '
'See: https://github.com/NikolayS/pg-flight-recorder/blueprints/SPEC.md §5.2';

-- ---------------------------------------------------------------------------
-- 4. _rebuild_statement_last_state()
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._rebuild_statement_last_state()
returns void
language plpgsql as $$
begin
    truncate pgfr_record.statement_last_state;
    insert into pgfr_record.statement_last_state (queryid, dbid, userid, toplevel, calls, sample_ts)
    select
        queryid,
        dbid,
        userid,
        toplevel,
        calls,
        extract(EPOCH from now() - pgfr_record.epoch())::INT4
    from pg_stat_statements;
    analyze pgfr_record.statement_last_state;
end;
$$;
comment on function pgfr_record._rebuild_statement_last_state() is
'Full rebuild of statement_last_state from pg_stat_statements. '
'Called on crash recovery (UNLOGGED table empty) or clean-restart desync '
'(PGSS stats_reset newer than max(sample_ts) in last_state). '
'Caller must hold pg_try_advisory_xact_lock before calling. '
'ANALYZE is called immediately to lock in planner statistics post-TRUNCATE.';

-- ---------------------------------------------------------------------------
-- 5. _collect_statement_snapshot_sparse() — the core sparse collector
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._collect_statement_snapshot_sparse(p_snapshot_id bigint)
returns void
language plpgsql as $$
declare
    v_sample_ts         INT4;
    v_pg_version        INTEGER;
    v_pgss_reset        TIMESTAMPTZ;
    v_last_sample_ts    INT4;
    v_last_dealloc      bigint;
    v_curr_dealloc      bigint;
    v_dealloc_warning   boolean := false;
    v_last_state_day    INT4;
    v_today_start_ts    INT4;
    v_at_boundary       boolean := false;
    v_locked            boolean;
    v_rows_inserted     INT;
begin
    -- Ensure partition exists for today (O(1) on happy path)
    perform pgfr_record._ensure_partition('statement_snapshots_v2', CURRENT_DATE);

    v_sample_ts   := extract(EPOCH from now() - pgfr_record.epoch())::INT4;
    v_pg_version  := pgfr_record._pg_version();

    -- -----------------------------------------------------------------------
    -- PGSS collection section — wrapped in BEGIN/EXCEPTION so failure here
    -- does not abort other collection sections (SPEC §5.2)
    -- -----------------------------------------------------------------------
    begin

        -- -------------------------------------------------------------------
        -- Step 1: Check clean-restart desync (SPEC §5.2)
        --         pg_stat_statements_info.stats_reset is PG14+ (always present
        --         per §2 minimum version requirement)
        -- -------------------------------------------------------------------
        select stats_reset into v_pgss_reset from pg_stat_statements_info;
        select MAX(sample_ts) into v_last_sample_ts from pgfr_record.statement_last_state;

        -- -------------------------------------------------------------------
        -- Step 2: Check PGSS dealloc counter (cluster-wide, not per-db)
        -- -------------------------------------------------------------------
        select dealloc into v_curr_dealloc from pg_stat_statements_info;
        select value::bigint into v_last_dealloc
        from pgfr_record.config
        where key = 'pgss_last_dealloc';

        if v_last_dealloc is not null and v_curr_dealloc > v_last_dealloc then
            v_dealloc_warning := true;
        end if;
        -- Store current dealloc for next tick comparison
        insert into pgfr_record.config (key, value, updated_at)
        values ('pgss_last_dealloc', v_curr_dealloc::text, now())
        on conflict (key) do update set value = EXCLUDED.value, updated_at = EXCLUDED.updated_at;

        -- -------------------------------------------------------------------
        -- Step 3: Decide if rebuild is needed
        --         Conditions:
        --           (a) last_state is empty (crash recovery — UNLOGGED truncated)
        --           (b) PGSS stats_reset is newer than our last sample_ts
        --               (clean restart with pg_stat_statements.save=off, or
        --                explicit pg_stat_statements_reset())
        -- -------------------------------------------------------------------
        if v_last_sample_ts is null
           or (v_pgss_reset is not null
               and v_pgss_reset > (pgfr_record.epoch() + v_last_sample_ts * interval '1 second'))
        then
            -- Advisory lock prevents two concurrent callers from both rebuilding.
            -- Lock held for entire transaction (intentional per SPEC §5.2).
            v_locked := pg_try_advisory_xact_lock(7382961::integer, hashtext('pgfr_last_state_rebuild')::integer);
            if not v_locked then
                -- Another session is rebuilding; skip this tick
                insert into pgfr_record.config (key, value, updated_at)
                values ('pgss_rebuild_skip_count',
                        (coalesce((select value from pgfr_record.config where key = 'pgss_rebuild_skip_count'), '0')::bigint + 1)::text,
                        now())
                on conflict (key) do update
                    set value = (coalesce(pgfr_record.config.value, '0')::bigint + 1)::text,
                        updated_at = EXCLUDED.updated_at;
                return;
            end if;
            perform pgfr_record._rebuild_statement_last_state();
            -- After rebuild, re-read last_sample_ts for boundary check below
            select MAX(sample_ts) into v_last_sample_ts from pgfr_record.statement_last_state;
        end if;

        -- -------------------------------------------------------------------
        -- Step 4: Daily partition boundary — TRUNCATE + rebuild last_state
        --         This keeps the side table aligned with current PGSS contents
        --         and prevents stale entries from accumulating (SPEC §5.2).
        -- -------------------------------------------------------------------
        v_today_start_ts := extract(EPOCH from (CURRENT_DATE::TIMESTAMPTZ at TIME zone 'UTC') - pgfr_record.epoch())::INT4;

        -- If the most recent last_state entry is from before today, we are at
        -- the first tick of a new day partition.
        if v_last_sample_ts is not null and v_last_sample_ts < v_today_start_ts then
            v_at_boundary := true;
            -- Acquire rebuild lock (if not already held from above)
            v_locked := pg_try_advisory_xact_lock(7382961::integer, hashtext('pgfr_last_state_rebuild')::integer);
            if not v_locked then
                insert into pgfr_record.config (key, value, updated_at)
                values ('pgss_rebuild_skip_count',
                        (coalesce((select value from pgfr_record.config where key = 'pgss_rebuild_skip_count'), '0')::bigint + 1)::text,
                        now())
                on conflict (key) do update
                    set value = (coalesce(pgfr_record.config.value, '0')::bigint + 1)::text,
                        updated_at = EXCLUDED.updated_at;
                return;
            end if;
            perform pgfr_record._rebuild_statement_last_state();
            select MAX(sample_ts) into v_last_sample_ts from pgfr_record.statement_last_state;
        end if;

        -- -------------------------------------------------------------------
        -- Step 5: Hash join PGSS against last_state; insert only changed rows
        --         Insert condition: new queryid OR calls increased OR calls dropped
        --         (calls drop = pg_stat_statements_reset() partial/full reset)
        -- -------------------------------------------------------------------
        -- pg18 renamed blk_read_time -> shared_blk_read_time in pg_stat_statements.
        -- case when cannot reference a nonexistent column even in a dead branch,
        -- so use execute with the correct column name chosen at runtime.
        execute format(
            $q$
            insert into pgfr_record.statement_snapshots_v2 (
                snapshot_id, sample_ts, queryid, userid, dbid, toplevel,
                query_preview, calls, total_exec_time, min_exec_time,
                max_exec_time, mean_exec_time, rows,
                shared_blks_hit, shared_blks_read, shared_blks_dirtied,
                shared_blks_written, temp_blks_read, temp_blks_written,
                blk_read_time, blk_write_time,
                wal_records, wal_bytes, pgss_dealloc_warning
            )
            select
                $1, $2,
                pss.queryid, pss.userid, pss.dbid, pss.toplevel,
                left(pss.query, 500),
                pss.calls, pss.total_exec_time, pss.min_exec_time,
                pss.max_exec_time, pss.mean_exec_time, pss.rows,
                pss.shared_blks_hit, pss.shared_blks_read,
                pss.shared_blks_dirtied, pss.shared_blks_written,
                pss.temp_blks_read, pss.temp_blks_written,
                pss.%I, pss.%I,
                pss.wal_records, pss.wal_bytes,
                $3
            from pg_stat_statements pss
            left join pgfr_record.statement_last_state ls
                using (queryid, dbid, userid, toplevel)
            where
                ls.queryid is null
                or pss.calls > ls.calls
                or pss.calls < ls.calls
            $q$,
            case when v_pg_version >= 18 then 'shared_blk_read_time'  else 'blk_read_time'  end,
            case when v_pg_version >= 18 then 'shared_blk_write_time' else 'blk_write_time' end
        ) using p_snapshot_id, v_sample_ts, v_dealloc_warning;

        get diagnostics v_rows_inserted = ROW_COUNT;

        -- -------------------------------------------------------------------
        -- Step 6: Upsert last_state for all rows we just saw in PGSS
        --         Must use ON CONFLICT DO UPDATE (not DELETE+INSERT) to preserve
        --         HOT eligibility. Only calls and sample_ts change — never key
        --         columns — so HOT is always eligible (SPEC §5.2).
        -- -------------------------------------------------------------------
        if v_at_boundary then
            -- At boundary we already did a full rebuild; no incremental upsert needed
            -- (rebuild already reflects current PGSS state)
            null;
        else
            insert into pgfr_record.statement_last_state (queryid, dbid, userid, toplevel, calls, sample_ts)
            select
                pss.queryid,
                pss.dbid,
                pss.userid,
                pss.toplevel,
                pss.calls,
                v_sample_ts
            from pg_stat_statements pss
            on conflict (queryid, dbid, userid, toplevel) do update
                set calls     = EXCLUDED.calls,
                    sample_ts = EXCLUDED.sample_ts;
        end if;

    exception
        when undefined_table then
            -- pg_stat_statements not loaded; do NOT truncate last_state (SPEC §5.2)
            raise warning 'pgfr_record: pg_stat_statements unavailable (extension not loaded): %', sqlerrm;
        when others then
            -- Any other failure must not abort other collection sections
            raise warning 'pgfr_record: PGSS sparse collection failed [%]: %', sqlstate, sqlerrm;
    end;
end;
$$;
comment on function pgfr_record._collect_statement_snapshot_sparse(bigint) is
'Sparse PGSS collector per SPEC §5.2. '
'Inserts rows into statement_snapshots_v2 only when calls changed. '
'Maintains statement_last_state as HOT-update-friendly side table. '
'Handles: crash recovery (UNLOGGED empty), clean-restart desync (stats_reset check), '
'daily partition boundary (TRUNCATE+rebuild), advisory lock (skip if rebuild in flight), '
'PGSS dealloc tracking (cluster-wide, not per-db). '
'Wrapped in EXCEPTION block — failure does not abort other collection sections.';

-- Register config keys for sparse collector observability
-- Initialize pgss_last_dealloc to current dealloc value to avoid false-positive
-- dealloc warnings on first run (pre-existing evictions are not our fault).
insert into pgfr_record.config (key, value, updated_at)
select 'pgss_last_dealloc', dealloc::text, now()
from pg_stat_statements_info
on conflict (key) do nothing;

insert into pgfr_record.config (key, value) values
    ('pgss_rebuild_skip_count', '0')
on conflict (key) do nothing;

-- =============================================================================
-- Phase 1: Sparse table_snapshots and index_snapshots collectors (Issue #8)
-- SPEC §5.3 — storage-overhaul-spec branch
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. table_snapshots_v2 — partitioned by range (sample_ts int4)
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.table_snapshots_v2 (
    snapshot_id         bigint not null,
    sample_ts           int4 not null,   -- seconds since pgfr_record.epoch()
    relid               oid not null,
    dbid                oid not null,    -- pg_database.oid
    seq_scan            bigint,
    seq_tup_read        bigint,
    idx_scan            bigint,
    idx_tup_fetch       bigint,
    n_tup_ins           bigint,
    n_tup_upd           bigint,
    n_tup_del           bigint,
    n_tup_hot_upd       bigint,
    n_live_tup          bigint,
    n_dead_tup          bigint,
    n_mod_since_analyze bigint,
    vacuum_count        bigint,
    autovacuum_count    bigint,
    analyze_count       bigint,
    autoanalyze_count   bigint,
    last_vacuum         timestamptz,
    last_autovacuum     timestamptz,
    last_analyze        timestamptz,
    last_autoanalyze    timestamptz,
    relfrozenxid_age    integer,
    reltuples           bigint,
    vacuum_running      boolean,
    table_size_bytes    bigint,
    total_size_bytes    bigint,
    indexes_size_bytes  bigint
) partition by range (sample_ts);

comment on table pgfr_record.table_snapshots_v2 is
'Sparse table-level stats history partitioned by int4 sample_ts (seconds since pgfr_record.epoch()). '
'Missing row = no change since last stored row. '
'Readers reconstruct full state via DISTINCT ON (relid, dbid) ORDER BY sample_ts DESC. '
'Top-N filter applied (table_stats_top_n config key, default 50). '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 2. table_last_state — UNLOGGED HOT-optimized side table
-- ---------------------------------------------------------------------------
create unlogged table if not exists pgfr_record.table_last_state (
    relid               oid not null,
    dbid                oid not null,
    sample_ts           int4 not null,
    seq_scan            bigint,
    idx_scan            bigint,
    n_tup_ins           bigint,
    n_tup_upd           bigint,
    n_tup_del           bigint,
    n_live_tup          bigint,
    n_dead_tup          bigint,
    n_mod_since_analyze bigint,
    primary key (relid, dbid)
) with (fillfactor = 70);

comment on table pgfr_record.table_last_state is
'HOT-sensitive: do NOT index mutable columns (seq_scan, idx_scan, n_tup_ins, etc.). '
'HOT updates require changed columns to be unindexed. '
'Only the PK index on (relid, dbid) is allowed. '
'UNLOGGED: truncated on crash — collector rebuilds automatically. '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 3. _rebuild_table_last_state()
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._rebuild_table_last_state()
returns void
language plpgsql as $$
declare
    v_dbid oid;
begin
    select oid into v_dbid from pg_database where datname = current_database();

    truncate pgfr_record.table_last_state;

    insert into pgfr_record.table_last_state (
        relid, dbid, sample_ts,
        seq_scan, idx_scan,
        n_tup_ins, n_tup_upd, n_tup_del,
        n_live_tup, n_dead_tup, n_mod_since_analyze
    )
    select
        st.relid,
        v_dbid,
        extract(epoch from now() - pgfr_record.epoch())::int4,
        st.seq_scan,
        st.idx_scan,
        st.n_tup_ins,
        st.n_tup_upd,
        st.n_tup_del,
        st.n_live_tup,
        st.n_dead_tup,
        st.n_mod_since_analyze
    from pg_stat_user_tables st;

    analyze pgfr_record.table_last_state;
end;
$$;

comment on function pgfr_record._rebuild_table_last_state() is
'Full rebuild of table_last_state from pg_stat_user_tables. '
'Called on crash recovery (UNLOGGED table empty after restart). '
'ANALYZE is called immediately to lock in planner statistics post-TRUNCATE. '
'Ghost rows (from dropped tables) are cleared on each rebuild — they do not '
'cause incorrect sparse inserts since the collector only joins against live '
'pg_stat_user_tables entries. '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 4. _collect_table_snapshot_sparse(p_snapshot_id bigint)
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._collect_table_snapshot_sparse(p_snapshot_id bigint)
returns void
language plpgsql as $$
declare
    v_sample_ts  int4;
    v_top_n      integer;
    v_dbid       oid;
    v_last_count bigint;
begin
    -- ensure partition exists for today (O(1) on happy path)
    perform pgfr_record._ensure_partition('table_snapshots_v2', current_date,
        'relid, dbid, sample_ts desc');

    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;
    v_top_n     := coalesce(pgfr_record._get_config('table_stats_top_n', '50')::integer, 50);

    select oid into v_dbid from pg_database where datname = current_database();

    begin
        -- crash recovery: if UNLOGGED table was truncated on restart, rebuild it
        select count(*) into v_last_count from pgfr_record.table_last_state;
        if v_last_count = 0 then
            perform pgfr_record._rebuild_table_last_state();
        end if;

        -- single statement: sparse insert + upsert last_state via writeable CTE.
        -- The top-N subquery is materialized once and shared across both branches.
        -- Changed = any of the 8 tracked activity metrics differs from last_state.
        with top_n as (
            -- select top-N tables by cumulative activity score
            select relid
            from (
                select
                    st.relid,
                    coalesce(st.seq_scan, 0)
                    + coalesce(st.idx_scan, 0)
                    + coalesce(st.n_tup_ins, 0)
                    + coalesce(st.n_tup_upd, 0)
                    + coalesce(st.n_tup_del, 0) as activity_score
                from pg_stat_user_tables st
                order by activity_score desc
                limit v_top_n
            ) ranked
        ),
        current_stats as (
            select
                st.relid,
                v_dbid::oid                                                 as dbid,
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
                age(c.relfrozenxid)::integer                                as relfrozenxid_age,
                c.reltuples::bigint                                         as reltuples,
                exists(
                    select 1 from pg_stat_progress_vacuum pv
                    where pv.relid = st.relid
                )                                                           as vacuum_running,
                pg_relation_size(st.relid)                                  as table_size_bytes,
                pg_total_relation_size(st.relid)                            as total_size_bytes,
                pg_indexes_size(st.relid)                                   as indexes_size_bytes
            from pg_stat_user_tables st
            join top_n t on t.relid = st.relid
            left join pg_class c on c.oid = st.relid
        ),
        changed as (
            -- rows where any tracked metric differs from last recorded state
            select cs.*
            from current_stats cs
            left join pgfr_record.table_last_state ls
                   on ls.relid = cs.relid
                  and ls.dbid  = cs.dbid
            where ls.relid is null   -- never seen before
               or coalesce(cs.seq_scan, 0)            is distinct from coalesce(ls.seq_scan, 0)
               or coalesce(cs.idx_scan, 0)            is distinct from coalesce(ls.idx_scan, 0)
               or coalesce(cs.n_tup_ins, 0)           is distinct from coalesce(ls.n_tup_ins, 0)
               or coalesce(cs.n_tup_upd, 0)           is distinct from coalesce(ls.n_tup_upd, 0)
               or coalesce(cs.n_tup_del, 0)           is distinct from coalesce(ls.n_tup_del, 0)
               or coalesce(cs.n_live_tup, 0)          is distinct from coalesce(ls.n_live_tup, 0)
               or coalesce(cs.n_dead_tup, 0)          is distinct from coalesce(ls.n_dead_tup, 0)
               or coalesce(cs.n_mod_since_analyze, 0) is distinct from coalesce(ls.n_mod_since_analyze, 0)
        ),
        sparse_insert as (
            -- insert changed rows into the partitioned snapshot table
            insert into pgfr_record.table_snapshots_v2 (
                snapshot_id, sample_ts, relid, dbid,
                seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
                n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
                n_live_tup, n_dead_tup, n_mod_since_analyze,
                vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
                last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
                relfrozenxid_age, reltuples, vacuum_running,
                table_size_bytes, total_size_bytes, indexes_size_bytes
            )
            select
                p_snapshot_id, v_sample_ts,
                ch.relid, ch.dbid,
                ch.seq_scan, ch.seq_tup_read, ch.idx_scan, ch.idx_tup_fetch,
                ch.n_tup_ins, ch.n_tup_upd, ch.n_tup_del, ch.n_tup_hot_upd,
                ch.n_live_tup, ch.n_dead_tup, ch.n_mod_since_analyze,
                ch.vacuum_count, ch.autovacuum_count, ch.analyze_count, ch.autoanalyze_count,
                ch.last_vacuum, ch.last_autovacuum, ch.last_analyze, ch.last_autoanalyze,
                ch.relfrozenxid_age, ch.reltuples, ch.vacuum_running,
                ch.table_size_bytes, ch.total_size_bytes, ch.indexes_size_bytes
            from changed ch
            returning relid, dbid
        )
        -- upsert last_state from current_stats for all top-N tables
        -- (not just changed ones — keep last_state fresh for all tracked tables)
        insert into pgfr_record.table_last_state (
            relid, dbid, sample_ts,
            seq_scan, idx_scan,
            n_tup_ins, n_tup_upd, n_tup_del,
            n_live_tup, n_dead_tup, n_mod_since_analyze
        )
        select
            cs.relid, cs.dbid, v_sample_ts,
            cs.seq_scan, cs.idx_scan,
            cs.n_tup_ins, cs.n_tup_upd, cs.n_tup_del,
            cs.n_live_tup, cs.n_dead_tup, cs.n_mod_since_analyze
        from current_stats cs
        on conflict (relid, dbid) do update
            set sample_ts           = excluded.sample_ts,
                seq_scan            = excluded.seq_scan,
                idx_scan            = excluded.idx_scan,
                n_tup_ins           = excluded.n_tup_ins,
                n_tup_upd           = excluded.n_tup_upd,
                n_tup_del           = excluded.n_tup_del,
                n_live_tup          = excluded.n_live_tup,
                n_dead_tup          = excluded.n_dead_tup,
                n_mod_since_analyze = excluded.n_mod_since_analyze;

    exception
        when others then
            raise warning 'pgfr_record: table sparse collection failed [%]: %', sqlstate, sqlerrm;
    end;
end;
$$;

comment on function pgfr_record._collect_table_snapshot_sparse(bigint) is
'Sparse table stats collector per Issue #8. '
'Inserts rows into table_snapshots_v2 only when tracked metrics changed. '
'Applies top-N filter (table_stats_top_n config key, default 50). '
'Maintains table_last_state as HOT-update-friendly side table. '
'Crash recovery: detects empty UNLOGGED table and rebuilds. '
'Wrapped in EXCEPTION block — failure does not abort other collection sections.';

-- ---------------------------------------------------------------------------
-- 5. index_snapshots_v2 — partitioned by range (sample_ts int4)
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.index_snapshots_v2 (
    snapshot_id         bigint not null,
    sample_ts           int4 not null,
    relid               oid not null,
    indexrelid          oid not null,
    dbid                oid not null,
    idx_scan            bigint,
    idx_tup_read        bigint,
    idx_tup_fetch       bigint,
    index_size_bytes    bigint
) partition by range (sample_ts);

comment on table pgfr_record.index_snapshots_v2 is
'Sparse index-level stats history partitioned by int4 sample_ts (seconds since pgfr_record.epoch()). '
'Missing row = no change since last stored row. '
'Readers reconstruct full state via DISTINCT ON (indexrelid, dbid) ORDER BY sample_ts DESC. '
'All indexes collected (no top-N filter). '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 6. index_last_state — UNLOGGED HOT-optimized side table
-- ---------------------------------------------------------------------------
create unlogged table if not exists pgfr_record.index_last_state (
    indexrelid          oid not null,
    dbid                oid not null,
    sample_ts           int4 not null,
    idx_scan            bigint,
    idx_tup_read        bigint,
    idx_tup_fetch       bigint,
    primary key (indexrelid, dbid)
) with (fillfactor = 70);

comment on table pgfr_record.index_last_state is
'HOT-sensitive: do NOT index mutable columns (idx_scan, idx_tup_read, idx_tup_fetch, sample_ts). '
'HOT updates require changed columns to be unindexed. '
'Only the PK index on (indexrelid, dbid) is allowed. '
'UNLOGGED: truncated on crash — collector rebuilds automatically. '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 7. _rebuild_index_last_state()
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._rebuild_index_last_state()
returns void
language plpgsql as $$
declare
    v_dbid oid;
begin
    select oid into v_dbid from pg_database where datname = current_database();

    truncate pgfr_record.index_last_state;

    insert into pgfr_record.index_last_state (
        indexrelid, dbid, sample_ts,
        idx_scan, idx_tup_read, idx_tup_fetch
    )
    select
        i.indexrelid,
        v_dbid,
        extract(epoch from now() - pgfr_record.epoch())::int4,
        i.idx_scan,
        i.idx_tup_read,
        i.idx_tup_fetch
    from pg_stat_user_indexes i;

    analyze pgfr_record.index_last_state;
end;
$$;

comment on function pgfr_record._rebuild_index_last_state() is
'Full rebuild of index_last_state from pg_stat_user_indexes. '
'Called on crash recovery (UNLOGGED table empty after restart). '
'ANALYZE is called immediately to lock in planner statistics post-TRUNCATE. '
'Ghost rows (from dropped indexes) are cleared on each rebuild — they do not '
'cause incorrect sparse inserts since the collector only joins against live '
'pg_stat_user_indexes entries. '
'Note: no top-N filter — all indexes are collected. On schemas with thousands '
'of indexes, the pg_relation_size() calls may add meaningful overhead. '
'See Issue #8.';

-- ---------------------------------------------------------------------------
-- 8. _collect_index_snapshot_sparse(p_snapshot_id bigint)
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._collect_index_snapshot_sparse(p_snapshot_id bigint)
returns void
language plpgsql as $$
declare
    v_sample_ts  int4;
    v_dbid       oid;
    v_last_count bigint;
begin
    -- ensure partition exists for today (O(1) on happy path)
    perform pgfr_record._ensure_partition('index_snapshots_v2', current_date,
        'indexrelid, dbid, sample_ts desc');

    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;

    select oid into v_dbid from pg_database where datname = current_database();

    begin
        -- crash recovery: if UNLOGGED table was truncated on restart, rebuild it
        select count(*) into v_last_count from pgfr_record.index_last_state;
        if v_last_count = 0 then
            perform pgfr_record._rebuild_index_last_state();
        end if;

        -- sparse insert: only rows where tracked metrics changed vs last_state
        -- no top-N filter for indexes (collect all)
        with current_stats as (
            select
                i.relid,
                i.indexrelid,
                v_dbid                          as dbid,
                i.idx_scan,
                i.idx_tup_read,
                i.idx_tup_fetch,
                pg_relation_size(i.indexrelid)  as index_size_bytes
            from pg_stat_user_indexes i
        )
        insert into pgfr_record.index_snapshots_v2 (
            snapshot_id, sample_ts,
            relid, indexrelid, dbid,
            idx_scan, idx_tup_read, idx_tup_fetch,
            index_size_bytes
        )
        select
            p_snapshot_id,
            v_sample_ts,
            cs.relid, cs.indexrelid, cs.dbid,
            cs.idx_scan, cs.idx_tup_read, cs.idx_tup_fetch,
            cs.index_size_bytes
        from current_stats cs
        left join pgfr_record.index_last_state ls
               on ls.indexrelid = cs.indexrelid
              and ls.dbid       = cs.dbid
        where ls.indexrelid is null   -- never seen before
           or coalesce(cs.idx_scan, 0)      is distinct from coalesce(ls.idx_scan, 0)
           or coalesce(cs.idx_tup_read, 0)  is distinct from coalesce(ls.idx_tup_read, 0)
           or coalesce(cs.idx_tup_fetch, 0) is distinct from coalesce(ls.idx_tup_fetch, 0);

        -- upsert last_state (only mutable columns → HOT eligible)
        insert into pgfr_record.index_last_state (
            indexrelid, dbid, sample_ts,
            idx_scan, idx_tup_read, idx_tup_fetch
        )
        select
            i.indexrelid,
            v_dbid,
            v_sample_ts,
            i.idx_scan,
            i.idx_tup_read,
            i.idx_tup_fetch
        from pg_stat_user_indexes i
        on conflict (indexrelid, dbid) do update
            set sample_ts    = excluded.sample_ts,
                idx_scan     = excluded.idx_scan,
                idx_tup_read = excluded.idx_tup_read,
                idx_tup_fetch = excluded.idx_tup_fetch;

    exception
        when others then
            raise warning 'pgfr_record: index sparse collection failed [%]: %', sqlstate, sqlerrm;
    end;
end;
$$;

comment on function pgfr_record._collect_index_snapshot_sparse(bigint) is
'Sparse index stats collector per Issue #8. '
'Inserts rows into index_snapshots_v2 only when idx_scan, idx_tup_read, or idx_tup_fetch changed. '
'No top-N filter — all indexes are collected. '
'Maintains index_last_state as HOT-update-friendly side table. '
'Crash recovery: detects empty UNLOGGED table and rebuilds. '
'Wrapped in EXCEPTION block — failure does not abort other collection sections.';

-- End Phase 1: Sparse table_snapshots and index_snapshots collectors (Issue #8)

-- ---------------------------------------------------------------------------
-- _ensure_partition(p_table text, p_date date, p_btree_cols text)
-- Overload for tables with non-standard B-tree index columns.
-- p_btree_cols: comma-separated column list for the B-tree index, e.g.
--   'relid, dbid, sample_ts desc'
--   'indexrelid, dbid, sample_ts desc'
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._ensure_partition(
    p_table       text,
    p_date        date,
    p_btree_cols  text
)
returns void
language plpgsql
as $$
declare
    v_partition_name text;
    v_bound_start    int4;
    v_bound_end      int4;
    v_date_start_ts  timestamptz;
    v_date_end_ts    timestamptz;
begin
    v_partition_name := p_table || '_' || to_char(p_date, 'YYYY_MM_DD');

    -- O(1) happy path
    if exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = v_partition_name
    ) then
        return;
    end if;

    v_date_start_ts := (to_char(p_date,     'YYYY-MM-DD') || ' 00:00:00+00')::timestamptz;
    v_date_end_ts   := (to_char(p_date + 1, 'YYYY-MM-DD') || ' 00:00:00+00')::timestamptz;

    v_bound_start := extract(epoch from (v_date_start_ts - pgfr_record.epoch()))::int4;
    v_bound_end   := extract(epoch from (v_date_end_ts   - pgfr_record.epoch()))::int4;

    execute format(
        'create table if not exists pgfr_record.%I
         partition of pgfr_record.%I
         for values from (%s) to (%s)',
        v_partition_name,
        p_table,
        v_bound_start,
        v_bound_end
    );

    -- B-tree index with caller-supplied column list
    execute format(
        'create index if not exists %I
         on pgfr_record.%I (%s)',
        v_partition_name || '_btree_idx',
        v_partition_name,
        p_btree_cols
    );

    -- BRIN index on sample_ts
    execute format(
        'create index if not exists %I
         on pgfr_record.%I
         using brin (sample_ts) with (pages_per_range = 8)',
        v_partition_name || '_brin_idx',
        v_partition_name
    );
end;
$$;

comment on function pgfr_record._ensure_partition(text, date, text) is
'Overload of _ensure_partition for tables with non-standard B-tree index columns. '
'p_btree_cols: raw SQL column list for the B-tree index (e.g. ''relid, dbid, sample_ts desc''). '
'SECURITY: p_btree_cols is injected via %s (not %I) — must only be called with '
'compile-time string literals, never from user input or config values. '
'Otherwise identical to _ensure_partition(text, date). See Issue #8.';

--------------------------------------------------------------------------------
-- RING BUFFER v2: N-partition TRUNCATE-based rotation
-- Follows pg_ash design (ash-install.sql). Replaces the UPDATE-based ring buffer
-- (samples_ring / wait_samples_ring / lock_samples_ring) with a LOGGED, partitioned,
-- INSERT-only design. Dual operation during migration — legacy tables preserved.
--
-- Key differences from pg_ash:
--   - N configurable partitions (default 3, min 3) vs hardcoded 3
--   - Separate wait_samples and lock_samples tables (not a single ash.sample)
--   - pgfr_record namespace, snake_case identifiers throughout
--------------------------------------------------------------------------------

-- 1. New config entries (ring_buffer_partitions, ring_rotation_period)
insert into pgfr_record.config (key, value) values
    ('ring_buffer_partitions', '3'),
    ('ring_rotation_period',   '2 hours')
on conflict (key) do nothing;

comment on table pgfr_record.config is
'Key-value configuration store for pgfr_record. '
'ring_buffer_partitions: number of ring buffer partitions (min 3, default 3). '
'ring_rotation_period: how often to rotate ring partitions (default 2 hours).';

-- 2. Ring config singleton — num_slots and rotation_period set from config at install time
create table if not exists pgfr_record.ring_config (
    singleton       bool primary key default true check (singleton),
    current_slot    smallint  not null default 0,
    num_slots       smallint  not null default 3,
    rotation_period interval  not null default '2 hours',
    rotated_at      timestamptz not null default clock_timestamp()
);

comment on table pgfr_record.ring_config is
'Ring buffer rotation state singleton. '
'current_slot: partition currently being written (0..num_slots-1). '
'num_slots: number of partitions, set at install time from ring_buffer_partitions config. '
'rotation_period: how often to advance the slot. '
'rotated_at: timestamp of last rotation.';

insert into pgfr_record.ring_config (singleton, num_slots, rotation_period)
select
    true,
    greatest(3, coalesce(pgfr_record._get_config('ring_buffer_partitions', '3')::smallint, 3)),
    coalesce(pgfr_record._get_config('ring_rotation_period', '2 hours')::interval, '2 hours')
on conflict do nothing;

-- 3. Wait event dictionary — shared singleton, never truncated
-- Maps (state, type, event) → compact smallint id.
-- Bounded by the number of distinct PG wait events (~600 max).
create table if not exists pgfr_record.wait_event_map (
    id    smallint primary key generated always as identity (start with 1),
    state text not null,
    type  text not null,
    event text not null,
    unique (state, type, event)
);

comment on table pgfr_record.wait_event_map is
'Wait event dictionary: maps (state, type, event) → smallint id. '
'Shared singleton — never truncated. Max ~600 entries (bounded by PG wait events). '
'Used to compress wait event data in the encoded integer[] arrays of wait_samples.';

-- 4. Dynamic partition creation for wait_samples, lock_samples, query_map_N
do $$
declare
    v_n smallint;
    i   smallint;
begin
    select num_slots into v_n from pgfr_record.ring_config where singleton;

    -- wait_samples parent: LOGGED, partitioned by LIST(slot)
    -- Stores encoded integer[] per-database wait event snapshots.
    -- Encoding: [-wait_id, count, qid, qid, ..., -next_wait_id, count, ...]
    execute $t$
        create table if not exists pgfr_record.wait_samples (
            sample_ts    int4     not null,
            datid        oid      not null,
            active_count smallint not null,
            data         integer[] not null
                         check (data[1] < 0 and array_length(data, 1) >= 3),
            slot         smallint not null
        ) partition by list (slot)
    $t$;

    -- lock_samples parent: LOGGED, partitioned by LIST(slot)
    execute $t$
        create table if not exists pgfr_record.lock_samples (
            sample_ts           int4     not null,
            blocked_pid         int4     not null,
            blocked_qid         int4,
            blocked_duration_s  int4,
            blocking_pid        int4     not null,
            blocking_qid        int4,
            lock_type           smallint not null,
            locked_relation_oid oid,
            slot                smallint not null
        ) partition by list (slot)
    $t$;

    -- create N partitions + query_maps
    for i in 0..(v_n - 1) loop
        -- wait_samples_N
        execute format(
            'create table if not exists pgfr_record.wait_samples_%s '
            'partition of pgfr_record.wait_samples for values in (%s)',
            i, i
        );
        execute format(
            'create index if not exists wait_samples_%s_ts_idx '
            'on pgfr_record.wait_samples_%s (sample_ts)',
            i, i
        );

        -- lock_samples_N
        execute format(
            'create table if not exists pgfr_record.lock_samples_%s '
            'partition of pgfr_record.lock_samples for values in (%s)',
            i, i
        );
        execute format(
            'create index if not exists lock_samples_%s_ts_idx '
            'on pgfr_record.lock_samples_%s (sample_ts)',
            i, i
        );

        -- query_map_N: per-partition query_id dictionary, TRUNCATE with partition on rotation
        execute format(
            'create table if not exists pgfr_record.query_map_%s ('
            '    id       int4 primary key generated always as identity (start with 1),'
            '    query_id int8 not null unique'
            ')',
            i
        );
    end loop;
end;
$$;

comment on table pgfr_record.wait_samples is
'Ring buffer v2: encoded wait event samples. One row per (database, wait group) per tick. '
'data integer[] encoding: [-wait_id, count, query_map_id, ...] groups, repeated per wait event. '
'Partitioned by LIST(slot); TRUNCATE replaces old slot on rotation. Never DELETEd.';

comment on table pgfr_record.lock_samples is
'Ring buffer v2: lock contention samples. One row per blocked/blocking pair per tick. '
'Partitioned by LIST(slot); TRUNCATE replaces old slot on rotation.';

-- 5. query_map_all view — union of all N per-partition query dictionaries
-- Must be created after the DO block (N is dynamic).
-- Recreate on each install to pick up num_slots changes.
do $$
declare
    v_n     smallint;
    v_parts text[] := array[]::text[];
    i       smallint;
    v_sql   text;
begin
    select num_slots into v_n from pgfr_record.ring_config where singleton;
    for i in 0..(v_n - 1) loop
        v_parts := v_parts || format(
            'select %s::smallint as slot, id, query_id from pgfr_record.query_map_%s',
            i, i
        );
    end loop;
    v_sql := 'create or replace view pgfr_record.query_map_all as '
             || array_to_string(v_parts, ' union all ');
    execute v_sql;
end;
$$;

comment on view pgfr_record.query_map_all is
'Union of all per-partition query_map tables. '
'Planner eliminates non-matching partitions when slot is a constant in reader queries. '
'Recreated on each install to reflect num_slots.';

-- 6. Helper functions

-- Current slot (stable — reads ring_config singleton)
create or replace function pgfr_record.ring_current_slot()
returns smallint
language sql stable parallel safe
as $$
    select current_slot from pgfr_record.ring_config where singleton
$$;

comment on function pgfr_record.ring_current_slot() is
'Returns the current ring buffer slot (0..num_slots-1). '
'Stable within a transaction. Use this in INSERT statements to target the correct partition.';

-- Register wait event (upsert, returns id) — race-safe, same pattern as ash._register_wait()
create or replace function pgfr_record._register_wait(p_state text, p_type text, p_event text)
returns smallint
language plpgsql
as $$
declare
    v_id smallint;
begin
    -- fast path: already registered
    select id into v_id
    from pgfr_record.wait_event_map
    where state = p_state and type = p_type and event = p_event;
    if v_id is not null then
        return v_id;
    end if;

    -- insert, ignore race
    insert into pgfr_record.wait_event_map (state, type, event)
    values (p_state, p_type, p_event)
    on conflict (state, type, event) do nothing
    returning id into v_id;

    if v_id is not null then
        return v_id;
    end if;

    -- race condition: another session inserted first
    select id into v_id
    from pgfr_record.wait_event_map
    where state = p_state and type = p_type and event = p_event;
    return v_id;
end;
$$;

comment on function pgfr_record._register_wait(text, text, text) is
'Upsert (state, type, event) into wait_event_map and return its smallint id. '
'Race-safe: three-step insert with concurrent-insert fallback. '
'Called once per distinct wait event per sample tick.';

-- Register query_id in current slot''s query_map (dynamic dispatch)
create or replace function pgfr_record._register_query(p_query_id int8)
returns int4
language plpgsql
as $$
declare
    v_slot smallint;
    v_id   int4;
begin
    v_slot := pgfr_record.ring_current_slot();
    execute format(
        'insert into pgfr_record.query_map_%s (query_id) values ($1) '
        'on conflict (query_id) do nothing',
        v_slot
    ) using p_query_id;
    execute format(
        'select id from pgfr_record.query_map_%s where query_id = $1',
        v_slot
    ) into v_id using p_query_id;
    return v_id;
end;
$$;

comment on function pgfr_record._register_query(int8) is
'Register a query_id in the current slot''s query_map table. '
'Returns the local int4 id (sequence-based, resets on TRUNCATE at rotation). '
'Called during sample_ring() to build the query_map ids used in data encoding.';

-- 7. rotate_ring() — N-partition TRUNCATE rotation
-- Advisory lock prevents concurrent rotation from pg_cron overlap.
-- Advances current_slot first, then TRUNCATEs the oldest partition.
create or replace function pgfr_record.rotate_ring()
returns text
language plpgsql
as $$
declare
    v_old_slot        smallint;
    v_new_slot        smallint;
    v_truncate_slot   smallint;
    v_num_slots       smallint;
    v_rotation_period interval;
    v_rotated_at      timestamptz;
begin
    if not pg_try_advisory_lock(hashtext('pgfr_rotate_ring')) then
        return 'skipped: another rotation in progress';
    end if;

    begin
        select current_slot, num_slots, rotation_period, rotated_at
        into v_old_slot, v_num_slots, v_rotation_period, v_rotated_at
        from pgfr_record.ring_config where singleton;

        -- idempotent: skip if rotated too recently (within 90% of rotation_period)
        if now() - v_rotated_at < v_rotation_period * 0.9 then
            perform pg_advisory_unlock(hashtext('pgfr_rotate_ring'));
            return 'skipped: rotated too recently at ' || v_rotated_at::text;
        end if;

        set local lock_timeout = '2s';

        v_new_slot      := (v_old_slot + 1) % v_num_slots;
        -- truncate the slot that's now two steps ahead (oldest data)
        v_truncate_slot := (v_new_slot + 1) % v_num_slots;

        -- advance slot FIRST: new inserts go to v_new_slot before we truncate
        update pgfr_record.ring_config
        set current_slot = v_new_slot, rotated_at = now()
        where singleton;

        -- lockstep TRUNCATE — zero bloat, no dead tuples, no GC needed
        execute format('truncate pgfr_record.wait_samples_%s', v_truncate_slot);
        execute format('truncate pgfr_record.lock_samples_%s', v_truncate_slot);
        execute format('truncate pgfr_record.query_map_%s', v_truncate_slot);
        -- restart identity sequence so ids are compact after rotation
        execute format(
            'alter table pgfr_record.query_map_%s alter column id restart',
            v_truncate_slot
        );

        perform pg_advisory_unlock(hashtext('pgfr_rotate_ring'));
        return format('rotated: slot %s -> %s, truncated slot %s',
                      v_old_slot, v_new_slot, v_truncate_slot);

    exception when lock_not_available then
        perform pg_advisory_unlock(hashtext('pgfr_rotate_ring'));
        return 'failed: lock timeout on truncate, will retry next cycle';
    when others then
        perform pg_advisory_unlock(hashtext('pgfr_rotate_ring'));
        raise;
    end;
end;
$$;

comment on function pgfr_record.rotate_ring() is
'Rotate ring buffer partitions: advance current_slot, TRUNCATE the oldest partition '
'and its matching query_map. Dynamic N-partition support (reads num_slots from ring_config). '
'Idempotent within 90% of rotation_period. Advisory lock prevents concurrent rotation. '
'Returns text status: rotated / skipped / failed.';

-- 8. sample_ring() — INSERT-based sampler (replaces UPDATE pattern)
-- Implements the same integer[] encoding as ash.take_sample():
--   [-wait_id, count, qmap_id, qmap_id, ...]  — one group per (datid, wait_event)
-- Keeps existing pgfr_record.sample() intact for dual operation during migration.
create or replace function pgfr_record.sample_ring()
returns timestamptz
language plpgsql
as $$
declare
    v_slot              smallint;
    v_sample_ts         int4;
    v_captured_at       timestamptz;
    v_include_bg        bool;
    v_debug_logging     bool;
    v_current_slot      smallint;
    v_rec               record;
    v_datid_rec         record;
    v_data              integer[];
    v_active_count      smallint;
    v_seen_waits        text[] := '{}';
    v_rows_inserted     int    := 0;
begin
    v_captured_at := clock_timestamp();
    v_sample_ts   := extract(epoch from (v_captured_at - pgfr_record.epoch()))::int4;
    v_slot        := pgfr_record.ring_current_slot();

    -- config (reuse existing config helpers)
    v_include_bg    := coalesce(pgfr_record._get_config('include_bg_workers', 'false')::bool, false);
    v_debug_logging := coalesce(pgfr_record._get_config('debug_logging', 'false')::bool, false);

    -- -----------------------------------------------------------------------
    -- Read 1: register new wait events; walk pg_stat_activity once.
    -- CPU* = active backend with no wait event (genuine CPU or uninstrumented).
    -- IdleTx = idle in transaction (may hold locks).
    -- -----------------------------------------------------------------------
    for v_rec in
        select
            sa.pid,
            sa.state,
            coalesce(sa.wait_event_type,
                case
                    when sa.state = 'active'                   then 'CPU*'
                    when sa.state like 'idle in transaction%'  then 'IdleTx'
                end
            ) as wait_type,
            coalesce(sa.wait_event,
                case
                    when sa.state = 'active'                   then 'CPU*'
                    when sa.state like 'idle in transaction%'  then 'IdleTx'
                end
            ) as wait_event,
            sa.backend_type,
            sa.query_id
        from pg_stat_activity sa
        where sa.state in ('active', 'idle in transaction', 'idle in transaction (aborted)')
          and (sa.backend_type = 'client backend'
           or (v_include_bg and sa.backend_type in (
                   'autovacuum worker', 'logical replication worker',
                   'parallel worker', 'background worker')))
          and sa.pid <> pg_backend_pid()
    loop
        -- dedup in memory; avoid per-row catalog lookup
        if not (v_rec.state || '|' || v_rec.wait_type || '|' || v_rec.wait_event = any(v_seen_waits)) then
            v_seen_waits := v_seen_waits
                || (v_rec.state || '|' || v_rec.wait_type || '|' || v_rec.wait_event);
            if not exists (
                select from pgfr_record.wait_event_map
                where state = v_rec.state and type = v_rec.wait_type and event = v_rec.wait_event
            ) then
                perform pgfr_record._register_wait(v_rec.state, v_rec.wait_type, v_rec.wait_event);
            end if;
        end if;

        if v_debug_logging then
            raise log 'pgfr_record.sample_ring: pid=% state=% wait_type=% wait_event=% backend_type=% query_id=%',
                v_rec.pid, v_rec.state, v_rec.wait_type, v_rec.wait_event,
                v_rec.backend_type, coalesce(v_rec.query_id::text, '(null)');
        end if;
    end loop;

    -- -----------------------------------------------------------------------
    -- Read 2: register query_ids into current slot's query_map
    -- 50k hard cap per partition to prevent unbounded growth (PG14/15 volatile
    -- SQL comments can flood query_map; PG16+ normalises comments).
    -- -----------------------------------------------------------------------
    execute format(
        'insert into pgfr_record.query_map_%s (query_id) '
        'select distinct sa.query_id '
        'from pg_stat_activity sa '
        'where sa.query_id is not null '
        '  and sa.state in (''active'', ''idle in transaction'', ''idle in transaction (aborted)'') '
        '  and (sa.backend_type = ''client backend'' '
        '   or ($1 and sa.backend_type in ('
        '       ''autovacuum worker'', ''logical replication worker'', '
        '       ''parallel worker'', ''background worker''))) '
        '  and sa.pid <> pg_backend_pid() '
        '  and (select reltuples from pg_class '
        '       where oid = ''pgfr_record.query_map_%s''::regclass) < 50000 '
        'on conflict (query_id) do nothing',
        v_slot, v_slot
    ) using v_include_bg;

    -- -----------------------------------------------------------------------
    -- Reads 3+4: per-database encoding — same CTE pattern as ash.take_sample()
    -- Snapshot pg_stat_activity, group by (datid, wait_event), encode integer[].
    -- Format: [-wait_id, count, qmap_id, qmap_id, ..., -next_wait_id, ...]
    -- -----------------------------------------------------------------------
    for v_datid_rec in
        select distinct coalesce(sa.datid, 0::oid) as datid
        from pg_stat_activity sa
        where sa.state in ('active', 'idle in transaction', 'idle in transaction (aborted)')
          and (sa.backend_type = 'client backend'
           or (v_include_bg and sa.backend_type in (
                   'autovacuum worker', 'logical replication worker',
                   'parallel worker', 'background worker')))
          and sa.pid <> pg_backend_pid()
    loop
        begin
            -- single query: snapshot → group by wait → encode → flatten
            -- mirrors ash.take_sample() CTE exactly, adapted to pgfr_record
            execute format(
                'with snapshot as ( '
                '    select '
                '        wm.id as wait_id, '
                '        coalesce(m.id, 0) as map_id '
                '    from pg_stat_activity sa '
                '    join pgfr_record.wait_event_map wm '
                '         on wm.state = sa.state '
                '        and wm.type = coalesce(sa.wait_event_type, '
                '            case when sa.state = ''active'' then ''CPU*'' '
                '                 when sa.state like ''idle in transaction%%'' then ''IdleTx'' end) '
                '        and wm.event = coalesce(sa.wait_event, '
                '            case when sa.state = ''active'' then ''CPU*'' '
                '                 when sa.state like ''idle in transaction%%'' then ''IdleTx'' end) '
                '    left join pgfr_record.query_map_all m '
                '           on m.slot = %s::smallint and m.query_id = sa.query_id '
                '    where sa.state in (''active'', ''idle in transaction'', ''idle in transaction (aborted)'') '
                '      and (sa.backend_type = ''client backend'' '
                '       or ($1 and sa.backend_type in ( '
                '           ''autovacuum worker'', ''logical replication worker'', '
                '           ''parallel worker'', ''background worker''))) '
                '      and sa.pid <> pg_backend_pid() '
                '      and coalesce(sa.datid, 0::oid) = $2 '
                '), '
                'groups as ( '
                '    select '
                '        row_number() over (order by s.wait_id) as gnum, '
                '        array[(-s.wait_id)::integer, count(*)::integer] '
                '            || array_agg(s.map_id::integer) as group_arr '
                '    from snapshot s '
                '    group by s.wait_id '
                '), '
                'flat as ( '
                '    select array_agg(el order by g.gnum, u.ord) as data '
                '    from groups g, '
                '         lateral unnest(g.group_arr) with ordinality as u(el, ord) '
                '), '
                'backend_count as ( '
                '    select count(*)::smallint as cnt from snapshot '
                ') '
                'select f.data, bc.cnt from flat f, backend_count bc',
                v_slot
            ) into v_data, v_active_count using v_include_bg, v_datid_rec.datid;

            if v_data is not null and array_length(v_data, 1) >= 3 then
                insert into pgfr_record.wait_samples (sample_ts, datid, active_count, data, slot)
                values (v_sample_ts, v_datid_rec.datid, v_active_count, v_data, v_slot);
                v_rows_inserted := v_rows_inserted + 1;
            end if;

        exception when others then
            raise warning 'pgfr_record.sample_ring: error encoding sample for datid % [%]: %',
                v_datid_rec.datid, sqlstate, sqlerrm;
        end;
    end loop;

    return v_captured_at;
end;
$$;

comment on function pgfr_record.sample_ring() is
'Ring buffer v2 sampler: INSERT-based replacement for the UPDATE pattern in sample(). '
'Encodes wait events as integer[] arrays: [-wait_id, count, qmap_id, ...] per database. '
'Follows the ash.take_sample() encoding exactly. '
'Dual operation: existing sample() continues to work during migration. '
'Call via pg_cron; use rotate_ring() separately on a slower schedule.';

-- 9. pg_cron wiring for ring rotation
do $$
begin
    if exists (select from pg_extension where extname = 'pg_cron') then
        -- ring sampler (every minute, same cadence as sample())
        perform cron.schedule('pgfr-sample-ring', '* * * * *',
            'set statement_timeout = ''500ms''; select pgfr_record.sample_ring()')
        where not exists (select 1 from cron.job where jobname = 'pgfr-sample-ring');

        -- ring rotation (every 2 hours)
        perform cron.schedule('pgfr-rotate-ring', '0 */2 * * *',
            'select pgfr_record.rotate_ring()')
        where not exists (select 1 from cron.job where jobname = 'pgfr-rotate-ring');

        -- clear nodename so pg_cron uses unix socket (not TCP)
        update cron.job set nodename = ''
        where jobname in ('pgfr-sample-ring', 'pgfr-rotate-ring')
          and nodename <> '';
    end if;
exception when others then
    null; -- pg_cron not installed or accessible, skip silently
end $$;

-- 10. Reader view: recent_waits_v2
-- Decodes the integer[] format to human-readable wait events.
-- Finds all negative elements (wait_event_id markers) in each data array
-- and joins to wait_event_map. For full per-backend decode see ash.decode_sample().
create or replace view pgfr_record.recent_waits_v2 as
select
    pgfr_record.epoch() + s.sample_ts * interval '1 second' as captured_at,
    s.datid,
    s.active_count,
    wem.state,
    wem.type  as wait_event_type,
    wem.event as wait_event,
    s.slot
from pgfr_record.wait_samples s
cross join lateral (
    select abs(s.data[i])::smallint as wid
    from generate_subscripts(s.data, 1) as i
    where s.data[i] < 0
) ids
join pgfr_record.wait_event_map wem on wem.id = ids.wid;

comment on view pgfr_record.recent_waits_v2 is
'Ring buffer v2 reader: decodes wait_samples integer[] encoding to readable rows. '
'One row per (sample, database, wait_event). '
'For count and query_id resolution, use ash.decode_sample()-style decoding.';

--------------------------------------------------------------------------------
-- End of ring buffer v2 section
--------------------------------------------------------------------------------
