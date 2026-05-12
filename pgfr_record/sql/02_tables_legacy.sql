-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

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
    datminmxid_age              INTEGER,
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
    -- MultiXID wraparound monitoring (additive upgrade path). See:
    --   https://postgres.ai/docs/postgres-howtos/performance-optimization/monitoring/how-to-monitor-transaction-id-wraparound-risks
    -- After migrate_phase3 these names resolve to views, so only ALTER when the
    -- relation is still a heap table (relkind='r'). Post-phase3, the column lives
    -- on snapshots_v2 / table_snapshots_v2 (handled in their own files).
    IF EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record' AND c.relname = 'snapshots' AND c.relkind = 'r'
    ) THEN
        ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS datminmxid_age INTEGER;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record' AND c.relname = 'table_snapshots' AND c.relkind = 'r'
    ) THEN
        ALTER TABLE pgfr_record.table_snapshots ADD COLUMN IF NOT EXISTS relminmxid_age INTEGER;
    END IF;
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
    relminmxid_age      INTEGER,
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
