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
-- Post-cutover (Issue #73), snapshots is a view; the index lives on the
-- retired heap (snapshots_legacy) until the final PR drops it. CREATE INDEX
-- IF NOT EXISTS validates the target relation before the name check, so it
-- must be guarded, not just IF-NOT-EXISTS'd.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record' AND c.relname = 'snapshots' AND c.relkind = 'r'
    ) THEN
        CREATE INDEX IF NOT EXISTS snapshots_captured_at_idx ON pgfr_record.snapshots(captured_at);
    END IF;
END $$;

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

-- Add delta columns to existing installations (additive-only upgrade).
-- set local client_min_messages = warning silences the "column already exists,
-- skipping" notices on fresh installs (the columns were created above).
DO $$
BEGIN
    SET LOCAL client_min_messages = warning;
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

-- Add xmin horizon monitoring columns to snapshots (additive-only upgrade).
-- Five typed source xmins (activity / slot / slot_catalog / replication / prepared)
-- with per-source ages, two aggregate ages, and one JSONB column with the
-- dominant holder's source-specific details. See REFERENCE.md "xmin horizon
-- monitoring" and blueprints/XMIN_HORIZON.md.
DO $$
BEGIN
    SET LOCAL client_min_messages = warning;
    -- Post-cutover (Issue #73), pgfr_record.snapshots is a view over
    -- snapshots_v2 (which carries these columns natively); only ALTER while
    -- the legacy heap is still the live relation.
    IF NOT EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'pgfr_record' AND c.relname = 'snapshots' AND c.relkind = 'r'
    ) THEN
        RETURN;
    END IF;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS activity_xmin XID;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS activity_xmin_age BIGINT;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS slot_xmin XID;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS slot_xmin_age BIGINT;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS slot_catalog_xmin XID;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS slot_catalog_xmin_age BIGINT;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS replication_xmin XID;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS replication_xmin_age BIGINT;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS prepared_xmin XID;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS prepared_xmin_age BIGINT;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS xmin_data_horizon_age BIGINT;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS xmin_any_horizon_age BIGINT;
    ALTER TABLE pgfr_record.snapshots ADD COLUMN IF NOT EXISTS xmin_horizon_detail JSONB;
END $$;

-- Add xmin / walsender columns to replication_snapshots.
-- backend_xmin tracks per-walsender xmin holdback; slot_name joins from
-- pg_replication_slots.active_pid; is_logical_walsender is COALESCE-wrapped
-- by the collector so it's genuinely binary, never three-valued.
DO $$
BEGIN
    SET LOCAL client_min_messages = warning;
    ALTER TABLE pgfr_record.replication_snapshots ADD COLUMN IF NOT EXISTS backend_xmin XID;
    ALTER TABLE pgfr_record.replication_snapshots ADD COLUMN IF NOT EXISTS backend_xmin_age BIGINT;
    ALTER TABLE pgfr_record.replication_snapshots ADD COLUMN IF NOT EXISTS slot_name TEXT;
    ALTER TABLE pgfr_record.replication_snapshots ADD COLUMN IF NOT EXISTS is_logical_walsender BOOLEAN NOT NULL DEFAULT false;
END $$;

-- Legacy 120-slot ring buffer tables (samples_ring + 3 child tables)
-- retired. Their writers, readers, and ring-infra functions were removed
-- in the legacy-ring retirement; the v2 path in 08_ring_buffer_v2.sql is
-- the canonical sampler now. DROP at install time covers existing
-- installs being upgraded; set local silences the "table does not exist,
-- skipping" notices on fresh installs.
DO $$
BEGIN
    SET LOCAL client_min_messages = warning;
    DROP TABLE IF EXISTS pgfr_record.wait_samples_ring_legacy     CASCADE;
    DROP TABLE IF EXISTS pgfr_record.activity_samples_ring_legacy CASCADE;
    DROP TABLE IF EXISTS pgfr_record.lock_samples_ring_legacy     CASCADE;
    DROP TABLE IF EXISTS pgfr_record.samples_ring_legacy          CASCADE;
    DROP TABLE IF EXISTS pgfr_record.wait_samples_ring     CASCADE;
    DROP TABLE IF EXISTS pgfr_record.activity_samples_ring CASCADE;
    DROP TABLE IF EXISTS pgfr_record.lock_samples_ring     CASCADE;
    DROP TABLE IF EXISTS pgfr_record.samples_ring          CASCADE;
END $$;
-- (The DROPs above also cover the original pre-rename names — an installation
-- that ran a pre-rename pgfr_record had samples_ring etc. without the
-- _legacy suffix.)
-- Aggregate + archive tables retired alongside their writers
-- (flush_ring_to_aggregates(), archive_ring_samples()) and their reader
-- (cleanup_aggregates()). These tables had no writers after wave 1
-- removed the pgfr_flush / pgfr_archive cron jobs and no readers in
-- source code. DROP at install covers existing installs being upgraded;
-- SET LOCAL silences the "does not exist, skipping" notice on fresh.
DO $$
BEGIN
    SET LOCAL client_min_messages = warning;
    DROP TABLE IF EXISTS pgfr_record.wait_event_aggregates       CASCADE;
    DROP TABLE IF EXISTS pgfr_record.lock_aggregates             CASCADE;
    DROP TABLE IF EXISTS pgfr_record.activity_aggregates         CASCADE;
    DROP TABLE IF EXISTS pgfr_record.activity_samples_archive    CASCADE;
    DROP TABLE IF EXISTS pgfr_record.lock_samples_archive        CASCADE;
    DROP TABLE IF EXISTS pgfr_record.wait_samples_archive        CASCADE;
END $$;


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
