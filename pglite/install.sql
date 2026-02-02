-- pg-flight-recorder Analysis-Only Install Script for PGLite
--
-- This script creates the schema for OFFLINE ANALYSIS of flight_recorder data.
-- It does NOT include data collection functions (sample, snapshot, etc.)
--
-- Usage:
--   1. Run this script to create schema in PGLite
--   2. Import data exported from production using pglite/export.sql
--   3. Use analysis functions (report, anomaly_report, what_happened_at, etc.)
--
-- Differences from full install.sql:
--   - No pg_cron dependency
--   - No collection functions
--   - Views use relation_names table instead of ::regclass casts
--   - Settings retrieved from config_snapshots instead of pg_settings

BEGIN;

-- Schema
CREATE SCHEMA IF NOT EXISTS flight_recorder;

--------------------------------------------------------------------------------
-- TABLES (for data import)
--------------------------------------------------------------------------------

-- Primary snapshot table - system-wide metrics captured at each snapshot interval
CREATE TABLE IF NOT EXISTS flight_recorder.snapshots (
    id                      SERIAL PRIMARY KEY,
    captured_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    pg_version              INTEGER,
    -- Checkpoint metrics
    checkpoint_time         TIMESTAMPTZ,
    ckpt_timed              BIGINT,
    ckpt_requested          BIGINT,
    ckpt_write_time         DOUBLE PRECISION,
    ckpt_sync_time          DOUBLE PRECISION,
    ckpt_buffers            BIGINT,
    -- WAL metrics
    wal_records             BIGINT,
    wal_fpi                 BIGINT,
    wal_bytes               NUMERIC,
    wal_buffers_full        BIGINT,
    wal_write_time          DOUBLE PRECISION,
    wal_sync_time           DOUBLE PRECISION,
    -- Background writer
    bgw_buffers_checkpoint  BIGINT,
    bgw_buffers_clean       BIGINT,
    bgw_buffers_backend     BIGINT,
    bgw_buffers_backend_fsync BIGINT,
    bgw_buffers_alloc       BIGINT,
    -- Transaction stats
    xact_commit             BIGINT,
    xact_rollback           BIGINT,
    -- Connection stats
    connections_total       INTEGER,
    connections_active      INTEGER,
    connections_idle        INTEGER,
    connections_idle_in_xact INTEGER,
    -- Autovacuum
    autovacuum_workers      INTEGER,
    -- Replication slots
    slots_count             INTEGER,
    slots_max_retained_wal  BIGINT,
    -- Temp files
    temp_files              BIGINT,
    temp_bytes              BIGINT,
    -- I/O stats (PG16+)
    io_checkpointer_reads   BIGINT,
    io_checkpointer_read_time DOUBLE PRECISION,
    io_checkpointer_writes  BIGINT,
    io_checkpointer_write_time DOUBLE PRECISION,
    io_checkpointer_fsyncs  BIGINT,
    io_checkpointer_fsync_time DOUBLE PRECISION,
    io_autovacuum_reads     BIGINT,
    io_autovacuum_read_time DOUBLE PRECISION,
    io_autovacuum_writes    BIGINT,
    io_autovacuum_write_time DOUBLE PRECISION,
    io_client_reads         BIGINT,
    io_client_read_time     DOUBLE PRECISION,
    io_client_writes        BIGINT,
    io_client_write_time    DOUBLE PRECISION,
    io_bgwriter_reads       BIGINT,
    io_bgwriter_read_time   DOUBLE PRECISION,
    io_bgwriter_writes      BIGINT,
    io_bgwriter_write_time  DOUBLE PRECISION
);
CREATE INDEX IF NOT EXISTS snapshots_captured_at_idx ON flight_recorder.snapshots(captured_at DESC);

-- Statement-level statistics from pg_stat_statements
CREATE TABLE IF NOT EXISTS flight_recorder.statement_snapshots (
    snapshot_id             INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    queryid                 BIGINT NOT NULL,
    query                   TEXT,
    calls                   BIGINT,
    total_exec_time         DOUBLE PRECISION,
    mean_exec_time          DOUBLE PRECISION,
    min_exec_time           DOUBLE PRECISION,
    max_exec_time           DOUBLE PRECISION,
    stddev_exec_time        DOUBLE PRECISION,
    rows                    BIGINT,
    shared_blks_hit         BIGINT,
    shared_blks_read        BIGINT,
    shared_blks_written     BIGINT,
    temp_blks_read          BIGINT,
    temp_blks_written       BIGINT,
    blk_read_time           DOUBLE PRECISION,
    blk_write_time          DOUBLE PRECISION,
    wal_records             BIGINT,
    wal_fpi                 BIGINT,
    wal_bytes               NUMERIC,
    PRIMARY KEY (snapshot_id, queryid)
);

-- Table-level statistics
CREATE TABLE IF NOT EXISTS flight_recorder.table_snapshots (
    snapshot_id         INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    schemaname          TEXT,             -- DEPRECATED: derive via relid or relation_names
    relname             TEXT,             -- DEPRECATED: derive via relid or relation_names
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
    table_size_bytes    BIGINT,
    total_size_bytes    BIGINT,
    indexes_size_bytes  BIGINT,
    PRIMARY KEY (snapshot_id, relid)
);
CREATE INDEX IF NOT EXISTS table_snapshots_relid_idx ON flight_recorder.table_snapshots(relid);

-- Index-level statistics
CREATE TABLE IF NOT EXISTS flight_recorder.index_snapshots (
    snapshot_id         INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    schemaname          TEXT,             -- DEPRECATED: derive via relid or relation_names
    relname             TEXT,             -- DEPRECATED: derive via relid or relation_names
    indexrelname        TEXT,             -- DEPRECATED: derive via indexrelid or relation_names
    relid               OID NOT NULL,
    indexrelid          OID NOT NULL,
    idx_scan            BIGINT,
    idx_tup_read        BIGINT,
    idx_tup_fetch       BIGINT,
    index_size_bytes    BIGINT,
    PRIMARY KEY (snapshot_id, indexrelid)
);
CREATE INDEX IF NOT EXISTS index_snapshots_indexrelid_idx ON flight_recorder.index_snapshots(indexrelid);
CREATE INDEX IF NOT EXISTS index_snapshots_relid_idx ON flight_recorder.index_snapshots(relid);

-- Configuration snapshots
CREATE TABLE IF NOT EXISTS flight_recorder.config_snapshots (
    snapshot_id     INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    setting         TEXT,
    unit            TEXT,
    source          TEXT,
    sourcefile      TEXT,
    PRIMARY KEY (snapshot_id, name)
);
CREATE INDEX IF NOT EXISTS config_snapshots_name_idx ON flight_recorder.config_snapshots(name);

-- Relation names lookup (populated at export time)
CREATE TABLE IF NOT EXISTS flight_recorder.relation_names (
    oid             OID PRIMARY KEY,
    nspname         TEXT NOT NULL,
    relname         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS relation_names_name_idx ON flight_recorder.relation_names(nspname, relname);

-- Database/role config snapshots
CREATE TABLE IF NOT EXISTS flight_recorder.db_role_config_snapshots (
    snapshot_id     INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    database_name   TEXT NOT NULL DEFAULT '',
    role_name       TEXT NOT NULL DEFAULT '',
    parameter_name  TEXT NOT NULL,
    parameter_value TEXT,
    PRIMARY KEY (snapshot_id, database_name, role_name, parameter_name)
);
CREATE INDEX IF NOT EXISTS db_role_config_snapshots_param_idx ON flight_recorder.db_role_config_snapshots(parameter_name);

-- Replication snapshots
CREATE TABLE IF NOT EXISTS flight_recorder.replication_snapshots (
    snapshot_id         INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    client_addr         INET,
    application_name    TEXT,
    state               TEXT,
    sent_lsn            PG_LSN,
    write_lsn           PG_LSN,
    flush_lsn           PG_LSN,
    replay_lsn          PG_LSN,
    write_lag           INTERVAL,
    flush_lag           INTERVAL,
    replay_lag          INTERVAL,
    sync_state          TEXT,
    PRIMARY KEY (snapshot_id, COALESCE(client_addr::text, ''), COALESCE(application_name, ''))
);

-- Vacuum progress snapshots
CREATE TABLE IF NOT EXISTS flight_recorder.vacuum_progress_snapshots (
    snapshot_id             INTEGER REFERENCES flight_recorder.snapshots(id) ON DELETE CASCADE,
    relid                   OID NOT NULL,
    phase                   TEXT,
    heap_blks_total         BIGINT,
    heap_blks_scanned       BIGINT,
    heap_blks_vacuumed      BIGINT,
    index_vacuum_count      BIGINT,
    max_dead_tuples         BIGINT,
    num_dead_tuples         BIGINT,
    PRIMARY KEY (snapshot_id, relid)
);

-- Ring buffer master table
CREATE TABLE IF NOT EXISTS flight_recorder.samples_ring (
    slot_id         INTEGER PRIMARY KEY,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT '1970-01-01'::timestamptz,
    epoch_seconds   BIGINT NOT NULL DEFAULT 0
);

-- Wait event samples ring buffer
CREATE TABLE IF NOT EXISTS flight_recorder.wait_samples_ring (
    slot_id             INTEGER REFERENCES flight_recorder.samples_ring(slot_id) ON DELETE CASCADE,
    row_num             INTEGER NOT NULL CHECK (row_num >= 0 AND row_num < 100),
    wait_event_type     TEXT,
    wait_event          TEXT,
    sample_count        INTEGER,
    pids                INTEGER[],
    PRIMARY KEY (slot_id, row_num)
);

-- Activity samples ring buffer
CREATE TABLE IF NOT EXISTS flight_recorder.activity_samples_ring (
    slot_id             INTEGER REFERENCES flight_recorder.samples_ring(slot_id) ON DELETE CASCADE,
    row_num             INTEGER NOT NULL CHECK (row_num >= 0 AND row_num < 100),
    pid                 INTEGER,
    usename             TEXT,
    application_name    TEXT,
    client_addr         INET,
    state               TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    xact_start          TIMESTAMPTZ,
    query_start         TIMESTAMPTZ,
    query_preview       TEXT,
    backend_type        TEXT,
    PRIMARY KEY (slot_id, row_num)
);

-- Lock samples ring buffer
CREATE TABLE IF NOT EXISTS flight_recorder.lock_samples_ring (
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
);

-- Archive tables (durable copies of ring buffer data)
CREATE TABLE IF NOT EXISTS flight_recorder.wait_samples_archive (
    archived_at         TIMESTAMPTZ NOT NULL,
    captured_at         TIMESTAMPTZ NOT NULL,
    wait_event_type     TEXT,
    wait_event          TEXT,
    sample_count        INTEGER,
    pids                INTEGER[]
);
CREATE INDEX IF NOT EXISTS wait_samples_archive_captured_idx ON flight_recorder.wait_samples_archive(captured_at DESC);

CREATE TABLE IF NOT EXISTS flight_recorder.activity_samples_archive (
    archived_at         TIMESTAMPTZ NOT NULL,
    captured_at         TIMESTAMPTZ NOT NULL,
    pid                 INTEGER,
    usename             TEXT,
    application_name    TEXT,
    client_addr         INET,
    state               TEXT,
    wait_event_type     TEXT,
    wait_event          TEXT,
    xact_start          TIMESTAMPTZ,
    query_start         TIMESTAMPTZ,
    query_preview       TEXT,
    backend_type        TEXT
);
CREATE INDEX IF NOT EXISTS activity_samples_archive_captured_idx ON flight_recorder.activity_samples_archive(captured_at DESC);

CREATE TABLE IF NOT EXISTS flight_recorder.lock_samples_archive (
    archived_at             TIMESTAMPTZ NOT NULL,
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
CREATE INDEX IF NOT EXISTS lock_samples_archive_captured_idx ON flight_recorder.lock_samples_archive(captured_at DESC);

-- Aggregate tables
CREATE TABLE IF NOT EXISTS flight_recorder.wait_event_aggregates (
    aggregated_at       TIMESTAMPTZ NOT NULL,
    period_start        TIMESTAMPTZ NOT NULL,
    period_end          TIMESTAMPTZ NOT NULL,
    wait_event_type     TEXT,
    wait_event          TEXT,
    total_samples       BIGINT,
    avg_per_sample      NUMERIC,
    max_per_sample      INTEGER,
    unique_pids         INTEGER
);
CREATE INDEX IF NOT EXISTS wait_event_aggregates_period_idx ON flight_recorder.wait_event_aggregates(period_start DESC);

CREATE TABLE IF NOT EXISTS flight_recorder.activity_aggregates (
    aggregated_at       TIMESTAMPTZ NOT NULL,
    period_start        TIMESTAMPTZ NOT NULL,
    period_end          TIMESTAMPTZ NOT NULL,
    state               TEXT,
    wait_event_type     TEXT,
    total_samples       BIGINT,
    unique_pids         INTEGER,
    unique_users        INTEGER,
    unique_apps         INTEGER
);
CREATE INDEX IF NOT EXISTS activity_aggregates_period_idx ON flight_recorder.activity_aggregates(period_start DESC);

CREATE TABLE IF NOT EXISTS flight_recorder.lock_aggregates (
    aggregated_at       TIMESTAMPTZ NOT NULL,
    period_start        TIMESTAMPTZ NOT NULL,
    period_end          TIMESTAMPTZ NOT NULL,
    lock_type           TEXT,
    total_blocked       BIGINT,
    total_blocking      BIGINT,
    avg_duration        INTERVAL,
    max_duration        INTERVAL,
    unique_relations    INTEGER
);
CREATE INDEX IF NOT EXISTS lock_aggregates_period_idx ON flight_recorder.lock_aggregates(period_start DESC);

-- Config table (for runtime settings)
CREATE TABLE IF NOT EXISTS flight_recorder.config (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Collection stats (metadata about collection jobs)
CREATE TABLE IF NOT EXISTS flight_recorder.collection_stats (
    id              SERIAL PRIMARY KEY,
    collection_type TEXT NOT NULL,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at        TIMESTAMPTZ,
    duration_ms     NUMERIC,
    rows_affected   INTEGER,
    skipped         BOOLEAN DEFAULT false,
    skip_reason     TEXT,
    error_message   TEXT
);
CREATE INDEX IF NOT EXISTS collection_stats_started_idx ON flight_recorder.collection_stats(started_at DESC);

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------

-- Format bytes as human-readable string
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

-- Linear interpolation for time-travel debugging
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
    IF p_value_before IS NULL OR p_value_after IS NULL THEN
        RETURN COALESCE(p_value_before, p_value_after);
    END IF;
    IF p_time_before IS NULL OR p_time_after IS NULL OR p_time_before = p_time_after THEN
        RETURN p_value_before;
    END IF;
    v_time_span := EXTRACT(EPOCH FROM (p_time_after - p_time_before));
    IF v_time_span = 0 THEN
        RETURN p_value_before;
    END IF;
    v_offset := EXTRACT(EPOCH FROM (p_target_time - p_time_before));
    v_ratio := v_offset / v_time_span;
    v_ratio := GREATEST(0, LEAST(1, v_ratio));
    RETURN round(p_value_before + v_ratio * (p_value_after - p_value_before), 4);
END;
$$;

-- Safe relation name lookup (for offline analysis)
CREATE OR REPLACE FUNCTION flight_recorder._safe_relname(p_oid OID)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT nspname || '.' || relname FROM flight_recorder.relation_names WHERE oid = p_oid),
        'OID:' || p_oid::text
    )
$$;

-- Get setting from config_snapshots (for offline analysis)
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

-- Get config value
CREATE OR REPLACE FUNCTION flight_recorder._get_config(p_key TEXT, p_default TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT value FROM flight_recorder.config WHERE key = p_key),
        p_default
    )
$$;

-- Get ring buffer retention interval
CREATE OR REPLACE FUNCTION flight_recorder._get_ring_retention_interval()
RETURNS INTERVAL
LANGUAGE sql STABLE AS $$
    SELECT (
        COALESCE(flight_recorder._get_config('ring_buffer_slots', '120')::integer, 120)
        * COALESCE(flight_recorder._get_config('sample_interval', '180')::integer, 180)
    )::text || ' seconds'::text
$$;

--------------------------------------------------------------------------------
-- VIEWS (modified for offline analysis)
--------------------------------------------------------------------------------

-- Snapshot deltas view
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
    flight_recorder._pretty_bytes((s.wal_bytes - prev.wal_bytes)::bigint) AS wal_bytes_pretty,
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
    flight_recorder._pretty_bytes((s.temp_bytes - prev.temp_bytes)::bigint) AS temp_bytes_pretty
FROM flight_recorder.snapshots s
JOIN flight_recorder.snapshots prev ON prev.id = (
    SELECT MAX(id) FROM flight_recorder.snapshots WHERE id < s.id
)
ORDER BY s.captured_at DESC;

-- Recent waits from ring buffer
CREATE OR REPLACE VIEW flight_recorder.recent_waits AS
SELECT
    sr.captured_at,
    w.wait_event_type,
    w.wait_event,
    w.sample_count,
    w.pids
FROM flight_recorder.samples_ring sr
JOIN flight_recorder.wait_samples_ring w ON w.slot_id = sr.slot_id
WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
  AND w.wait_event IS NOT NULL
ORDER BY sr.captured_at DESC, w.sample_count DESC;

-- Recent activity from ring buffer
CREATE OR REPLACE VIEW flight_recorder.recent_activity AS
SELECT
    sr.captured_at,
    a.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.state,
    a.wait_event_type,
    a.wait_event,
    a.xact_start,
    a.query_start,
    a.query_preview,
    a.backend_type
FROM flight_recorder.samples_ring sr
JOIN flight_recorder.activity_samples_ring a ON a.slot_id = sr.slot_id
WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
  AND a.pid IS NOT NULL
ORDER BY sr.captured_at DESC;

-- Recent locks from ring buffer (uses _safe_relname for offline compatibility)
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
    flight_recorder._safe_relname(l.locked_relation_oid) AS locked_relation,
    l.blocked_query_preview,
    l.blocking_query_preview
FROM flight_recorder.samples_ring sr
JOIN flight_recorder.lock_samples_ring l ON l.slot_id = sr.slot_id
WHERE sr.captured_at > now() - flight_recorder._get_ring_retention_interval()
  AND l.blocked_pid IS NOT NULL
ORDER BY sr.captured_at DESC, l.blocked_duration DESC;

-- Recent idle in transaction
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

-- Recent replication status
CREATE OR REPLACE VIEW flight_recorder.recent_replication AS
SELECT
    s.captured_at,
    r.client_addr,
    r.application_name,
    r.state,
    r.sent_lsn,
    r.write_lsn,
    r.flush_lsn,
    r.replay_lsn,
    r.write_lag,
    r.flush_lag,
    r.replay_lag,
    r.sync_state
FROM flight_recorder.snapshots s
JOIN flight_recorder.replication_snapshots r ON r.snapshot_id = s.id
WHERE s.captured_at > now() - '24 hours'::interval
ORDER BY s.captured_at DESC, r.application_name;

-- Recent vacuum progress (uses _safe_relname)
CREATE OR REPLACE VIEW flight_recorder.recent_vacuum_progress AS
SELECT
    s.captured_at,
    flight_recorder._safe_relname(v.relid) AS relation,
    v.phase,
    v.heap_blks_total,
    v.heap_blks_scanned,
    v.heap_blks_vacuumed,
    CASE WHEN v.heap_blks_total > 0
         THEN round(100.0 * v.heap_blks_vacuumed / v.heap_blks_total, 1)
         ELSE 0
    END AS pct_complete,
    v.index_vacuum_count,
    v.num_dead_tuples,
    v.max_dead_tuples
FROM flight_recorder.snapshots s
JOIN flight_recorder.vacuum_progress_snapshots v ON v.snapshot_id = s.id
WHERE s.captured_at > now() - '24 hours'::interval
ORDER BY s.captured_at DESC;

--------------------------------------------------------------------------------
-- CORE ANALYSIS FUNCTIONS
--------------------------------------------------------------------------------

-- Compare two snapshots
CREATE OR REPLACE FUNCTION flight_recorder.compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    start_snapshot_id       INTEGER,
    end_snapshot_id         INTEGER,
    start_time              TIMESTAMPTZ,
    end_time                TIMESTAMPTZ,
    interval_seconds        NUMERIC,
    checkpoint_occurred     BOOLEAN,
    ckpt_timed_delta        BIGINT,
    ckpt_requested_delta    BIGINT,
    ckpt_write_time_ms      NUMERIC,
    ckpt_sync_time_ms       NUMERIC,
    ckpt_buffers_delta      BIGINT,
    wal_bytes_delta         NUMERIC,
    wal_bytes_pretty        TEXT,
    bgw_buffers_backend_delta    BIGINT,
    bgw_buffers_backend_fsync_delta BIGINT,
    temp_files_delta        BIGINT,
    temp_bytes_delta        NUMERIC,
    temp_bytes_pretty       TEXT,
    xact_commit_delta       BIGINT,
    xact_rollback_delta     BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_start RECORD;
    v_end RECORD;
BEGIN
    SELECT * INTO v_start FROM flight_recorder.snapshots
    WHERE captured_at <= p_start_time ORDER BY captured_at DESC LIMIT 1;

    SELECT * INTO v_end FROM flight_recorder.snapshots
    WHERE captured_at <= p_end_time ORDER BY captured_at DESC LIMIT 1;

    IF v_start IS NULL OR v_end IS NULL THEN
        RETURN;
    END IF;

    start_snapshot_id := v_start.id;
    end_snapshot_id := v_end.id;
    start_time := v_start.captured_at;
    end_time := v_end.captured_at;
    interval_seconds := EXTRACT(EPOCH FROM (v_end.captured_at - v_start.captured_at));
    checkpoint_occurred := v_end.checkpoint_time IS DISTINCT FROM v_start.checkpoint_time;
    ckpt_timed_delta := v_end.ckpt_timed - v_start.ckpt_timed;
    ckpt_requested_delta := v_end.ckpt_requested - v_start.ckpt_requested;
    ckpt_write_time_ms := (v_end.ckpt_write_time - v_start.ckpt_write_time)::numeric;
    ckpt_sync_time_ms := (v_end.ckpt_sync_time - v_start.ckpt_sync_time)::numeric;
    ckpt_buffers_delta := v_end.ckpt_buffers - v_start.ckpt_buffers;
    wal_bytes_delta := v_end.wal_bytes - v_start.wal_bytes;
    wal_bytes_pretty := flight_recorder._pretty_bytes((v_end.wal_bytes - v_start.wal_bytes)::bigint);
    bgw_buffers_backend_delta := v_end.bgw_buffers_backend - v_start.bgw_buffers_backend;
    bgw_buffers_backend_fsync_delta := v_end.bgw_buffers_backend_fsync - v_start.bgw_buffers_backend_fsync;
    temp_files_delta := v_end.temp_files - v_start.temp_files;
    temp_bytes_delta := v_end.temp_bytes - v_start.temp_bytes;
    temp_bytes_pretty := flight_recorder._pretty_bytes((v_end.temp_bytes - v_start.temp_bytes)::bigint);
    xact_commit_delta := v_end.xact_commit - v_start.xact_commit;
    xact_rollback_delta := v_end.xact_rollback - v_start.xact_rollback;

    RETURN NEXT;
END;
$$;

-- Wait event summary for a time range
CREATE OR REPLACE FUNCTION flight_recorder.wait_summary(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    wait_event_type     TEXT,
    wait_event          TEXT,
    total_samples       BIGINT,
    pct_of_total        NUMERIC
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_total BIGINT;
BEGIN
    -- Try ring buffer first
    SELECT COALESCE(SUM(w.sample_count), 0) INTO v_total
    FROM flight_recorder.samples_ring sr
    JOIN flight_recorder.wait_samples_ring w ON w.slot_id = sr.slot_id
    WHERE sr.captured_at BETWEEN p_start_time AND p_end_time
      AND w.wait_event IS NOT NULL;

    IF v_total > 0 THEN
        RETURN QUERY
        SELECT
            w.wait_event_type,
            w.wait_event,
            SUM(w.sample_count)::bigint AS total_samples,
            ROUND(100.0 * SUM(w.sample_count) / v_total, 2) AS pct_of_total
        FROM flight_recorder.samples_ring sr
        JOIN flight_recorder.wait_samples_ring w ON w.slot_id = sr.slot_id
        WHERE sr.captured_at BETWEEN p_start_time AND p_end_time
          AND w.wait_event IS NOT NULL
        GROUP BY w.wait_event_type, w.wait_event
        ORDER BY total_samples DESC;
    ELSE
        -- Fall back to archives
        SELECT COALESCE(SUM(sample_count), 0) INTO v_total
        FROM flight_recorder.wait_samples_archive
        WHERE captured_at BETWEEN p_start_time AND p_end_time;

        RETURN QUERY
        SELECT
            wa.wait_event_type,
            wa.wait_event,
            SUM(wa.sample_count)::bigint AS total_samples,
            CASE WHEN v_total > 0 THEN ROUND(100.0 * SUM(wa.sample_count) / v_total, 2) ELSE 0 END AS pct_of_total
        FROM flight_recorder.wait_samples_archive wa
        WHERE wa.captured_at BETWEEN p_start_time AND p_end_time
        GROUP BY wa.wait_event_type, wa.wait_event
        ORDER BY total_samples DESC;
    END IF;
END;
$$;

-- Statement comparison between two time periods
CREATE OR REPLACE FUNCTION flight_recorder.statement_compare(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS TABLE(
    queryid             BIGINT,
    query_preview       TEXT,
    calls_delta         BIGINT,
    total_time_delta_ms NUMERIC,
    mean_time_before_ms NUMERIC,
    mean_time_after_ms  NUMERIC,
    mean_time_change_pct NUMERIC,
    rows_delta          BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_start_snapshot_id INTEGER;
    v_end_snapshot_id INTEGER;
BEGIN
    SELECT id INTO v_start_snapshot_id FROM flight_recorder.snapshots
    WHERE captured_at <= p_start_time ORDER BY captured_at DESC LIMIT 1;

    SELECT id INTO v_end_snapshot_id FROM flight_recorder.snapshots
    WHERE captured_at <= p_end_time ORDER BY captured_at DESC LIMIT 1;

    IF v_start_snapshot_id IS NULL OR v_end_snapshot_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        COALESCE(e.queryid, s.queryid) AS queryid,
        LEFT(COALESCE(e.query, s.query), 100) AS query_preview,
        COALESCE(e.calls, 0) - COALESCE(s.calls, 0) AS calls_delta,
        ROUND((COALESCE(e.total_exec_time, 0) - COALESCE(s.total_exec_time, 0))::numeric, 2) AS total_time_delta_ms,
        ROUND(s.mean_exec_time::numeric, 2) AS mean_time_before_ms,
        ROUND(e.mean_exec_time::numeric, 2) AS mean_time_after_ms,
        CASE WHEN s.mean_exec_time > 0
             THEN ROUND(100.0 * (e.mean_exec_time - s.mean_exec_time) / s.mean_exec_time, 1)
             ELSE NULL
        END AS mean_time_change_pct,
        COALESCE(e.rows, 0) - COALESCE(s.rows, 0) AS rows_delta
    FROM flight_recorder.statement_snapshots s
    FULL OUTER JOIN flight_recorder.statement_snapshots e
        ON e.queryid = s.queryid AND e.snapshot_id = v_end_snapshot_id
    WHERE s.snapshot_id = v_start_snapshot_id OR e.snapshot_id = v_end_snapshot_id
    ORDER BY total_time_delta_ms DESC NULLS LAST;
END;
$$;

-- Anomaly detection for a time range (uses config_snapshots for settings)
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
    -- Get autovacuum_freeze_max_age from config_snapshots (offline compatible)
    v_freeze_max_age := COALESCE(
        flight_recorder._get_setting_from_snapshots('autovacuum_freeze_max_age', '200000000')::bigint,
        200000000
    );
    v_warning_threshold := (v_freeze_max_age * 0.5)::bigint;
    v_critical_threshold := (v_freeze_max_age * 0.8)::bigint;

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

    -- Check for lock contention
    SELECT count(DISTINCT blocked_pid), max(blocked_duration)
    INTO v_lock_count, v_max_block_duration
    FROM flight_recorder.lock_samples_ring l
    JOIN flight_recorder.samples_ring s ON s.slot_id = l.slot_id
    WHERE s.captured_at BETWEEN p_start_time AND p_end_time;

    IF v_lock_count > 0 THEN
        anomaly_type := 'LOCK_CONTENTION';
        severity := CASE
            WHEN v_max_block_duration > '30 seconds'::interval THEN 'high'
            WHEN v_max_block_duration > '5 seconds'::interval THEN 'medium'
            ELSE 'low'
        END;
        description := 'Lock contention detected between sessions';
        metric_value := format('%s blocked sessions, max wait: %s',
                              v_lock_count, v_max_block_duration);
        threshold := 'Any blocking locks';
        recommendation := 'Review blocking queries; consider shorter transactions or lock timeouts';
        RETURN NEXT;
    END IF;

    -- Check XID age from table_snapshots
    FOR v_table_xid_rec IN
        SELECT ts.schemaname, ts.relname, ts.relfrozenxid_age
        FROM flight_recorder.table_snapshots ts
        JOIN flight_recorder.snapshots s ON s.id = ts.snapshot_id
        WHERE s.captured_at BETWEEN p_start_time AND p_end_time
          AND ts.relfrozenxid_age > v_warning_threshold
        ORDER BY ts.relfrozenxid_age DESC
        LIMIT 5
    LOOP
        anomaly_type := 'XID_WRAPAROUND_RISK';
        severity := CASE
            WHEN v_table_xid_rec.relfrozenxid_age > v_critical_threshold THEN 'critical'
            ELSE 'high'
        END;
        description := format('Table %s.%s approaching XID wraparound',
                             v_table_xid_rec.schemaname, v_table_xid_rec.relname);
        metric_value := format('relfrozenxid age: %s', v_table_xid_rec.relfrozenxid_age);
        threshold := format('> %s (50%% of freeze_max_age)', v_warning_threshold);
        recommendation := 'Run VACUUM FREEZE on affected tables immediately';
        RETURN NEXT;
    END LOOP;
END;
$$;

-- Config at a point in time
CREATE OR REPLACE FUNCTION flight_recorder.config_at(p_timestamp TIMESTAMPTZ)
RETURNS TABLE(
    name        TEXT,
    setting     TEXT,
    unit        TEXT,
    source      TEXT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_snapshot_id INTEGER;
BEGIN
    SELECT id INTO v_snapshot_id FROM flight_recorder.snapshots
    WHERE captured_at <= p_timestamp ORDER BY captured_at DESC LIMIT 1;

    RETURN QUERY
    SELECT DISTINCT ON (cs.name)
        cs.name,
        cs.setting,
        cs.unit,
        cs.source
    FROM flight_recorder.config_snapshots cs
    JOIN flight_recorder.snapshots s ON s.id = cs.snapshot_id
    WHERE s.id <= v_snapshot_id
    ORDER BY cs.name, s.id DESC;
END;
$$;

-- Config changes over time
CREATE OR REPLACE FUNCTION flight_recorder.config_changes(
    p_start_time TIMESTAMPTZ DEFAULT now() - '7 days'::interval,
    p_end_time TIMESTAMPTZ DEFAULT now()
)
RETURNS TABLE(
    changed_at      TIMESTAMPTZ,
    name            TEXT,
    old_setting     TEXT,
    new_setting     TEXT,
    source          TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    WITH config_history AS (
        SELECT
            s.captured_at,
            cs.name,
            cs.setting,
            cs.source,
            LAG(cs.setting) OVER (PARTITION BY cs.name ORDER BY s.captured_at) AS prev_setting
        FROM flight_recorder.config_snapshots cs
        JOIN flight_recorder.snapshots s ON s.id = cs.snapshot_id
        WHERE s.captured_at BETWEEN p_start_time AND p_end_time
    )
    SELECT
        ch.captured_at AS changed_at,
        ch.name,
        ch.prev_setting AS old_setting,
        ch.setting AS new_setting,
        ch.source
    FROM config_history ch
    WHERE ch.setting IS DISTINCT FROM ch.prev_setting
      AND ch.prev_setting IS NOT NULL
    ORDER BY ch.captured_at DESC;
END;
$$;

-- Table hotspots
CREATE OR REPLACE FUNCTION flight_recorder.table_hotspots(
    p_lookback INTERVAL DEFAULT '24 hours'::interval,
    p_limit INTEGER DEFAULT 20
)
RETURNS TABLE(
    schemaname          TEXT,
    relname             TEXT,
    seq_scan_delta      BIGINT,
    idx_scan_delta      BIGINT,
    n_tup_ins_delta     BIGINT,
    n_tup_upd_delta     BIGINT,
    n_tup_del_delta     BIGINT,
    n_dead_tup          BIGINT,
    total_activity      BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_start_id INTEGER;
    v_end_id INTEGER;
BEGIN
    SELECT id INTO v_start_id FROM flight_recorder.snapshots
    WHERE captured_at <= now() - p_lookback ORDER BY captured_at DESC LIMIT 1;

    SELECT id INTO v_end_id FROM flight_recorder.snapshots
    ORDER BY captured_at DESC LIMIT 1;

    RETURN QUERY
    SELECT
        COALESCE(e.schemaname, split_part(flight_recorder._safe_relname(e.relid), '.', 1)) AS schemaname,
        COALESCE(e.relname, split_part(flight_recorder._safe_relname(e.relid), '.', 2)) AS relname,
        COALESCE(e.seq_scan - s.seq_scan, e.seq_scan) AS seq_scan_delta,
        COALESCE(e.idx_scan - s.idx_scan, e.idx_scan) AS idx_scan_delta,
        COALESCE(e.n_tup_ins - s.n_tup_ins, e.n_tup_ins) AS n_tup_ins_delta,
        COALESCE(e.n_tup_upd - s.n_tup_upd, e.n_tup_upd) AS n_tup_upd_delta,
        COALESCE(e.n_tup_del - s.n_tup_del, e.n_tup_del) AS n_tup_del_delta,
        e.n_dead_tup,
        COALESCE(e.seq_scan - s.seq_scan, e.seq_scan) +
        COALESCE(e.idx_scan - s.idx_scan, e.idx_scan) +
        COALESCE(e.n_tup_ins - s.n_tup_ins, e.n_tup_ins) +
        COALESCE(e.n_tup_upd - s.n_tup_upd, e.n_tup_upd) +
        COALESCE(e.n_tup_del - s.n_tup_del, e.n_tup_del) AS total_activity
    FROM flight_recorder.table_snapshots e
    LEFT JOIN flight_recorder.table_snapshots s ON s.relid = e.relid AND s.snapshot_id = v_start_id
    WHERE e.snapshot_id = v_end_id
    ORDER BY total_activity DESC
    LIMIT p_limit;
END;
$$;

-- Unused indexes
CREATE OR REPLACE FUNCTION flight_recorder.unused_indexes(
    p_lookback INTERVAL DEFAULT '7 days'::interval,
    p_min_size_bytes BIGINT DEFAULT 1048576
)
RETURNS TABLE(
    schemaname      TEXT,
    relname         TEXT,
    indexrelname    TEXT,
    idx_scan        BIGINT,
    index_size      TEXT
)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT ON (i.indexrelid)
        COALESCE(i.schemaname, split_part(flight_recorder._safe_relname(i.relid), '.', 1)) AS schemaname,
        COALESCE(i.relname, split_part(flight_recorder._safe_relname(i.relid), '.', 2)) AS relname,
        COALESCE(i.indexrelname, split_part(flight_recorder._safe_relname(i.indexrelid), '.', 2)) AS indexrelname,
        i.idx_scan,
        flight_recorder._pretty_bytes(i.index_size_bytes) AS index_size
    FROM flight_recorder.index_snapshots i
    JOIN flight_recorder.snapshots s ON s.id = i.snapshot_id
    WHERE s.captured_at > now() - p_lookback
      AND i.idx_scan = 0
      AND i.index_size_bytes >= p_min_size_bytes
      AND COALESCE(i.indexrelname, flight_recorder._safe_relname(i.indexrelid)) NOT LIKE '%_pkey'
    ORDER BY i.indexrelid, i.index_size_bytes DESC;
END;
$$;

COMMIT;

-- Success message
DO $$
BEGIN
    RAISE NOTICE 'pg-flight-recorder analysis-only schema installed successfully.';
    RAISE NOTICE 'Import your data with: psql -f flight_recorder_data.sql';
    RAISE NOTICE 'Then use: SELECT * FROM flight_recorder.anomaly_report(start, end);';
END;
$$;
