-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

-- migrate_phase3.sql — pg_flight_recorder Phase 3 migration
--
-- Migrates from legacy heap tables to daily-partitioned v2 tables.
-- Run AFTER install.sql has applied Phase 3 schema (v2 tables exist).
--
-- What this does:
--   1. Verifies v2 tables exist and dual-write has been running
--   2. Renames legacy tables to _legacy suffix (keeps data intact)
--   3. Creates backwards-compatible views: old name → v2 table
--   4. Replaces pgfr_cleanup cron (DELETE-based) with partition GC
--   5. Disables dual-write triggers (no longer needed)
--
-- What this does NOT do:
--   - Copy historical data from legacy to v2 (keep _legacy tables for that)
--   - Drop _legacy tables (do that manually after verifying v2 data)
--
-- Rollback: run migrate_phase3_rollback.sql (renames _legacy back, drops views)
--
-- Prerequisites:
--   - install.sql Phase 3 applied (snapshots_v2 etc. exist)
--   - At least one snapshot() call has run after Phase 3 install
--     (verify: SELECT count(*) FROM pgfr_record.snapshots_v2 > 0)
--
-- Run as superuser:
--   psql -U postgres -d <db> -f pgfr_record/migrate_phase3.sql

\set ON_ERROR_STOP 1
set client_min_messages to notice;

begin;

-- ---------------------------------------------------------------------------
-- Step 0: Pre-flight checks
-- ---------------------------------------------------------------------------
do $$
declare
    v_v2_count   bigint;
    v_missing    text[];
begin
    raise notice 'migrate_phase3: starting pre-flight checks';

    -- Verify v2 tables exist. (activity_samples_archive_v2,
    -- lock_samples_archive_v2, wait_samples_archive_v2 were retired
    -- alongside the legacy ring; this preflight no longer checks for them.)
    select array_agg(t) into v_missing
    from unnest(array[
        'snapshots_v2',
        'replication_snapshots_v2',
        'vacuum_progress_snapshots_v2',
        'statement_snapshots_v2',
        'table_snapshots_v2',
        'index_snapshots_v2'
    ]) as t
    where not exists (
        select 1 from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relname = t
          and c.relkind = 'p'
    );

    if v_missing is not null then
        raise exception
            'migrate_phase3: v2 tables missing: %. Run install.sql Phase 3 first.',
            v_missing;
    end if;

    -- Verify dual-write has produced data in snapshots_v2
    select count(*) into v_v2_count from pgfr_record.snapshots_v2;
    if v_v2_count = 0 then
        raise exception
            'migrate_phase3: snapshots_v2 is empty. '
            'Run SELECT pgfr_record.snapshot() at least once after Phase 3 install, then retry.';
    end if;

    raise notice 'migrate_phase3: pre-flight passed (snapshots_v2 has % rows)', v_v2_count;
end $$;

-- ---------------------------------------------------------------------------
-- Step 1: Rename legacy tables to _legacy
--         Keeps all historical data intact; _legacy tables are never dropped here
-- ---------------------------------------------------------------------------
set local lock_timeout = '2s';  -- match migrate_phase1.sql; fail fast rather than hang

do $$
declare
    v_tbl text;
    v_tables text[] := array[
        'snapshots',
        'replication_snapshots',
        'vacuum_progress_snapshots',
        'statement_snapshots',
        'table_snapshots',
        'index_snapshots'
        -- activity_samples_archive / lock_samples_archive / wait_samples_archive
        -- retired alongside the legacy ring; no rename needed.
    ];
begin
    foreach v_tbl in array v_tables loop
        if exists (
            select 1 from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'pgfr_record'
              and c.relname = v_tbl
              and c.relkind = 'r'
        ) then
            execute format(
                'alter table pgfr_record.%I rename to %I',
                v_tbl, v_tbl || '_legacy'
            );
            raise notice 'migrate_phase3: renamed % → %_legacy', v_tbl, v_tbl;
        elsif exists (
            select 1 from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'pgfr_record'
              and c.relname = v_tbl || '_legacy'
        ) then
            raise notice 'migrate_phase3: % already renamed (skipping)', v_tbl;
        else
            raise notice 'migrate_phase3: % not found (skipping)', v_tbl;
        end if;
    end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Step 2: Create backwards-compatible views
--         Queries against old table names continue to work via UNION ALL
--         of legacy data + v2 data, ordered by captured_at / sample_ts.
--
--         Views are read-only — inserts go via snapshot() / sparse collectors.
-- ---------------------------------------------------------------------------

-- snapshots: merge legacy (timestamptz pk) + v2 (int4 sample_ts)
create or replace view pgfr_record.snapshots as
select
    snapshot_id                                             as id,
    captured_at,
    pg_version,
    wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
    checkpoint_lsn, checkpoint_time,
    ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
    bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
    null::bigint    as bgw_buffers_backend,
    null::bigint    as bgw_buffers_backend_fsync,
    autovacuum_workers, slots_count, slots_max_retained_wal,
    io_checkpointer_reads, io_checkpointer_read_time,
    io_checkpointer_writes, io_checkpointer_write_time,
    io_checkpointer_fsyncs, io_checkpointer_fsync_time,
    io_autovacuum_reads, io_autovacuum_read_time,
    io_autovacuum_writes, io_autovacuum_write_time,
    io_client_reads, io_client_read_time,
    io_client_writes, io_client_write_time,
    io_bgwriter_reads, io_bgwriter_read_time,
    io_bgwriter_writes, io_bgwriter_write_time,
    temp_files, temp_bytes,
    xact_commit, xact_rollback, blks_read, blks_hit,
    connections_active, connections_total, connections_max,
    db_size_bytes, datfrozenxid_age, datminmxid_age,
    archived_count, last_archived_wal, last_archived_time,
    failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
    confl_tablespace, confl_lock, confl_snapshot,
    confl_bufferpin, confl_deadlock, confl_active_logicalslot,
    max_catalog_oid, large_object_count
from pgfr_record.snapshots_v2
union all
select
    id::bigint,
    captured_at,
    pg_version,
    wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
    checkpoint_lsn, checkpoint_time,
    ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
    bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
    bgw_buffers_backend, bgw_buffers_backend_fsync,
    autovacuum_workers, slots_count, slots_max_retained_wal,
    io_checkpointer_reads, io_checkpointer_read_time,
    io_checkpointer_writes, io_checkpointer_write_time,
    io_checkpointer_fsyncs, io_checkpointer_fsync_time,
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
    null::integer                as datminmxid_age,
    archived_count, last_archived_wal, last_archived_time,
    failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
    confl_tablespace, confl_lock, confl_snapshot,
    confl_bufferpin, confl_deadlock, confl_active_logicalslot,
    max_catalog_oid, large_object_count
from pgfr_record.snapshots_legacy;

comment on view pgfr_record.snapshots is
'Backwards-compatible view: UNION ALL of snapshots_v2 (current) and snapshots_legacy (historical). '
'bgw_buffers_backend / bgw_buffers_backend_fsync: NULL for v2 rows (dropped in PG17). '
'Read-only. For new data, query snapshots_v2 directly for partition pruning.';

-- replication_snapshots
-- legacy table lacks: reply_time; column order differs from v2
create or replace view pgfr_record.replication_snapshots as
select
    snapshot_id,
    sample_ts,
    pid, client_addr, application_name, state,
    sent_lsn, write_lsn, flush_lsn, replay_lsn,
    write_lag, flush_lag, replay_lag, sync_state, reply_time
from pgfr_record.replication_snapshots_v2
union all
select
    snapshot_id,
    null::integer       as sample_ts,
    pid, client_addr, application_name, state,
    sent_lsn, write_lsn, flush_lsn, replay_lsn,
    write_lag, flush_lag, replay_lag, sync_state,
    null::timestamptz   as reply_time
from pgfr_record.replication_snapshots_legacy;

comment on view pgfr_record.replication_snapshots is
'Backwards-compatible view: UNION ALL of replication_snapshots_v2 and _legacy. Read-only.';

-- vacuum_progress_snapshots
-- legacy has datid, relname extra; v2 lacks datid/relname
create or replace view pgfr_record.vacuum_progress_snapshots as
select
    snapshot_id,
    sample_ts,
    pid,
    null::oid   as datid,
    datname,
    relid,
    null::text  as relname,
    phase,
    heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
    index_vacuum_count, max_dead_tuples, num_dead_tuples
from pgfr_record.vacuum_progress_snapshots_v2
union all
select
    snapshot_id,
    null::integer as sample_ts,
    pid,
    datid, datname, relid, relname, phase,
    heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
    index_vacuum_count, max_dead_tuples, num_dead_tuples
from pgfr_record.vacuum_progress_snapshots_legacy;

comment on view pgfr_record.vacuum_progress_snapshots is
'Backwards-compatible view: UNION ALL of vacuum_progress_snapshots_v2 and _legacy. Read-only. '
'Note: relname is null for v2 rows (derive via relid::regclass). Filter on relid for cross-version queries.';

-- statement_snapshots — v2 has sparse columns; legacy has delta columns not in v2
-- expose minimal common set useful for cross-version queries
create or replace view pgfr_record.statement_snapshots as
select
    snapshot_id,
    sample_ts,
    queryid,
    userid,
    dbid,
    null::boolean               as toplevel,
    query_preview               as query,
    query_preview,
    calls,
    total_exec_time,
    null::double precision      as min_exec_time,
    null::double precision      as max_exec_time,
    mean_exec_time,
    rows,
    shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
    temp_blks_read, temp_blks_written,
    blk_read_time, blk_write_time,
    wal_records, wal_bytes,
    null::double precision      as exec_time,
    pgss_dealloc_warning        as dealloc_warning
from pgfr_record.statement_snapshots_v2
union all
select
    snapshot_id,
    null::integer               as sample_ts,
    queryid,
    userid,
    dbid,
    null::boolean               as toplevel,
    query_preview               as query,
    query_preview,
    calls,
    total_exec_time,
    min_exec_time,
    max_exec_time,
    mean_exec_time,
    rows,
    shared_blks_hit, shared_blks_read,
    null::bigint                as shared_blks_dirtied,
    null::bigint                as shared_blks_written,
    temp_blks_read, temp_blks_written,
    blk_read_time, blk_write_time,
    wal_records, wal_bytes,
    null::double precision      as exec_time,
    null::boolean               as dealloc_warning
from pgfr_record.statement_snapshots_legacy;

comment on view pgfr_record.statement_snapshots is
'Backwards-compatible view: UNION ALL of statement_snapshots_v2 and _legacy. '
'min_exec_time / max_exec_time: NULL for v2 rows (not stored in sparse collector). '
'exec_time: NULL for v2 rows. Read-only.';

-- Archive views + INSTEAD OF INSERT triggers retired alongside the
-- archive tables (legacy and *_archive_v2). They migrated INSERTs from
-- the legacy heap names to the v2 partitioned versions; with both gone
-- there is nothing to route.


-- ---------------------------------------------------------------------------
-- Step 3: Replace pgfr_cleanup cron (DELETE-based) with partition GC
-- ---------------------------------------------------------------------------
do $$
begin
    -- Remove old DELETE-based cleanup job
    perform cron.unschedule('pgfr_cleanup')
    where exists (select 1 from cron.job where jobname = 'pgfr_cleanup');

    -- Add partition GC jobs (nightly truncate + monthly drop).
    -- Job names use underscores per #59. enable() handles the rename migration
    -- from any prior hyphenated names; this script just ensures the new names
    -- exist if migrate_phase3 is run before enable().
    if not exists (select 1 from cron.job where jobname = 'pgfr_truncate_partitions') then
        perform cron.schedule(
            'pgfr_truncate_partitions',
            '0 3 * * *',
            'select pgfr_record.truncate_old_partitions()'
        );
    end if;

    if not exists (select 1 from cron.job where jobname = 'pgfr_drop_ancient_partitions') then
        perform cron.schedule(
            'pgfr_drop_ancient_partitions',
            '0 4 1 * *',
            'select pgfr_record.drop_ancient_partitions()'
        );
    end if;

    raise notice 'migrate_phase3: cron jobs updated (pgfr_cleanup removed, partition GC added)';
end $$;

-- ---------------------------------------------------------------------------
-- Step 4: Disable dual-write trigger (snapshots table now a view — trigger gone)
--         The trigger was on the old heap table; after rename it's on snapshots_legacy.
--         Drop it from the legacy table — no longer needed.
-- ---------------------------------------------------------------------------
drop trigger if exists snapshot_v2_dual_write on pgfr_record.snapshots_legacy;

-- ---------------------------------------------------------------------------
-- INSTEAD OF INSERT trigger on snapshots view
-- Routes snapshot() inserts (which target the old table name) into snapshots_v2
-- Returns the snapshot_id so snapshot() RETURNING id still works
-- ---------------------------------------------------------------------------
-- snapshot() inserts into pgfr_record.snapshots by name. After migration that's
-- now a view — inserts fail. Fix: add a dedicated sequence for snapshot_id and
-- create an INSTEAD OF INSERT trigger that routes to snapshots_v2.
-- This avoids rewriting the 800-line snapshot() function.

create sequence if not exists pgfr_record.snapshots_v2_snapshot_id_seq;

create or replace function pgfr_record._snapshots_view_insert()
returns trigger
language plpgsql as $$
declare
    v_sample_ts int4;
    v_id        bigint;
begin
    v_sample_ts := extract(epoch from new.captured_at - pgfr_record.epoch())::int4;

    perform pgfr_record._ensure_partition('snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');

    v_id := nextval('pgfr_record.snapshots_v2_snapshot_id_seq');

    -- default pg_version when caller omits it (e.g. bare INSERT INTO snapshots (captured_at))
    if new.pg_version is null then
        new.pg_version := pgfr_record._pg_version();
    end if;

    insert into pgfr_record.snapshots_v2 (
        snapshot_id, sample_ts, captured_at, pg_version,
        wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time,
        checkpoint_lsn, checkpoint_time,
        ckpt_timed, ckpt_requested, ckpt_write_time, ckpt_sync_time, ckpt_buffers,
        bgw_buffers_clean, bgw_maxwritten_clean, bgw_buffers_alloc,
        autovacuum_workers, slots_count, slots_max_retained_wal,
        io_checkpointer_reads, io_checkpointer_read_time,
        io_checkpointer_writes, io_checkpointer_write_time,
        io_checkpointer_fsyncs, io_checkpointer_fsync_time,
        io_autovacuum_reads, io_autovacuum_read_time,
        io_autovacuum_writes, io_autovacuum_write_time,
        io_client_reads, io_client_read_time,
        io_client_writes, io_client_write_time,
        io_bgwriter_reads, io_bgwriter_read_time,
        io_bgwriter_writes, io_bgwriter_write_time,
        temp_files, temp_bytes,
        xact_commit, xact_rollback, blks_read, blks_hit,
        connections_active, connections_total, connections_max,
        db_size_bytes, datfrozenxid_age, datminmxid_age,
        archived_count, last_archived_wal, last_archived_time,
        failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
        confl_tablespace, confl_lock, confl_snapshot,
        confl_bufferpin, confl_deadlock, confl_active_logicalslot,
        max_catalog_oid, large_object_count
    ) values (
        v_id, v_sample_ts, new.captured_at, new.pg_version,
        new.wal_records, new.wal_fpi, new.wal_bytes, new.wal_write_time, new.wal_sync_time,
        new.checkpoint_lsn, new.checkpoint_time,
        new.ckpt_timed, new.ckpt_requested, new.ckpt_write_time, new.ckpt_sync_time, new.ckpt_buffers,
        new.bgw_buffers_clean, new.bgw_maxwritten_clean, new.bgw_buffers_alloc,
        new.autovacuum_workers, new.slots_count, new.slots_max_retained_wal,
        new.io_checkpointer_reads, new.io_checkpointer_read_time,
        new.io_checkpointer_writes, new.io_checkpointer_write_time,
        new.io_checkpointer_fsyncs, new.io_checkpointer_fsync_time,
        new.io_autovacuum_reads, new.io_autovacuum_read_time,
        new.io_autovacuum_writes, new.io_autovacuum_write_time,
        new.io_client_reads, new.io_client_read_time,
        new.io_client_writes, new.io_client_write_time,
        new.io_bgwriter_reads, new.io_bgwriter_read_time,
        new.io_bgwriter_writes, new.io_bgwriter_write_time,
        new.temp_files, new.temp_bytes,
        new.xact_commit, new.xact_rollback, new.blks_read, new.blks_hit,
        new.connections_active, new.connections_total, new.connections_max,
        new.db_size_bytes, new.datfrozenxid_age, new.datminmxid_age,
        new.archived_count, new.last_archived_wal, new.last_archived_time,
        new.failed_count, new.last_failed_wal, new.last_failed_time, new.archiver_stats_reset,
        new.confl_tablespace, new.confl_lock, new.confl_snapshot,
        new.confl_bufferpin, new.confl_deadlock, new.confl_active_logicalslot,
        new.max_catalog_oid, new.large_object_count
    );

    -- make NEW.id available to RETURNING clause in snapshot()
    new.id := v_id;
    return new;
end;
$$;

drop trigger if exists snapshots_view_insert on pgfr_record.snapshots;
create trigger snapshots_view_insert
    instead of insert on pgfr_record.snapshots
    for each row
    execute function pgfr_record._snapshots_view_insert();


-- table_snapshots — compatible with legacy collector INSERT column set
create or replace view pgfr_record.table_snapshots as
select
    snapshot_id,
    null::text          as schemaname,
    null::text          as relname,
    relid,
    seq_scan,
    null::bigint        as seq_tup_read,
    idx_scan,
    null::bigint        as idx_tup_fetch,
    n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
    n_live_tup, n_dead_tup,
    null::bigint        as n_mod_since_analyze,
    null::bigint        as vacuum_count,
    null::bigint        as autovacuum_count,
    null::bigint        as analyze_count,
    null::bigint        as autoanalyze_count,
    null::timestamptz   as last_vacuum,
    null::timestamptz   as last_autovacuum,
    null::timestamptz   as last_analyze,
    null::timestamptz   as last_autoanalyze,
    null::integer       as relfrozenxid_age,
    null::integer       as relminmxid_age,
    null::bigint        as reltuples,
    null::boolean       as vacuum_running,
    null::bigint        as last_vacuum_duration_ms,
    table_size_bytes,
    null::bigint        as total_size_bytes,
    null::bigint        as indexes_size_bytes
from pgfr_record.table_snapshots_v2
union all
select
    snapshot_id,
    schemaname, relname, relid,
    seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
    n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
    n_live_tup, n_dead_tup, n_mod_since_analyze,
    vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
    last_vacuum, last_autovacuum, last_analyze, last_autoanalyze,
    relfrozenxid_age,
    null::integer       as relminmxid_age,
    reltuples, vacuum_running, last_vacuum_duration_ms,
    table_size_bytes, total_size_bytes,
    null::bigint        as indexes_size_bytes
from pgfr_record.table_snapshots_legacy;

comment on view pgfr_record.table_snapshots is
'Backwards-compatible view: UNION ALL of table_snapshots_v2 and _legacy. Read-only.';

-- index_snapshots
-- legacy table has no idx_blks_read/hit; index_snapshots_v2 has no schemaname/relname/indexrelname
create or replace view pgfr_record.index_snapshots as
select
    snapshot_id,
    null::text          as schemaname,
    null::text          as relname,
    null::text          as indexrelname,
    relid,
    indexrelid,
    idx_scan, idx_tup_read, idx_tup_fetch,
    index_size_bytes
from pgfr_record.index_snapshots_v2
union all
select
    snapshot_id,
    schemaname, relname, indexrelname, relid, indexrelid,
    idx_scan, idx_tup_read, idx_tup_fetch,
    index_size_bytes
from pgfr_record.index_snapshots_legacy;

comment on view pgfr_record.index_snapshots is
'Backwards-compatible view: UNION ALL of index_snapshots_v2 and _legacy. Read-only.';

-- ---------------------------------------------------------------------------
-- Step 5: INSTEAD OF INSERT triggers for remaining views
--         replication_snapshots, vacuum_progress_snapshots,
--         table_snapshots, index_snapshots
-- ---------------------------------------------------------------------------

-- replication_snapshots → replication_snapshots_v2
create or replace function pgfr_record._replication_snapshots_view_insert()
returns trigger language plpgsql as $$
declare
    v_sample_ts int4;
begin
    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;
    perform pgfr_record._ensure_partition('replication_snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');
    insert into pgfr_record.replication_snapshots_v2 (
        snapshot_id, sample_ts,
        pid, client_addr, application_name, state,
        sent_lsn, write_lsn, flush_lsn, replay_lsn,
        write_lag, flush_lag, replay_lag, sync_state, reply_time
    ) values (
        new.snapshot_id, v_sample_ts,
        new.pid, new.client_addr, new.application_name, new.state,
        new.sent_lsn, new.write_lsn, new.flush_lsn, new.replay_lsn,
        new.write_lag, new.flush_lag, new.replay_lag, new.sync_state,
        null::timestamptz
    );
    return new;
end $$;

drop trigger if exists replication_snapshots_view_insert on pgfr_record.replication_snapshots;
create trigger replication_snapshots_view_insert
    instead of insert on pgfr_record.replication_snapshots
    for each row
    execute function pgfr_record._replication_snapshots_view_insert();

-- vacuum_progress_snapshots → vacuum_progress_snapshots_v2
create or replace function pgfr_record._vacuum_progress_view_insert()
returns trigger language plpgsql as $$
declare
    v_sample_ts int4;
begin
    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;
    perform pgfr_record._ensure_partition('vacuum_progress_snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');
    insert into pgfr_record.vacuum_progress_snapshots_v2 (
        snapshot_id, sample_ts,
        pid, datname, relid, phase,
        heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
        index_vacuum_count, max_dead_tuples, num_dead_tuples
    ) values (
        new.snapshot_id, v_sample_ts,
        new.pid, new.datname, new.relid, new.phase,
        new.heap_blks_total, new.heap_blks_scanned, new.heap_blks_vacuumed,
        new.index_vacuum_count, new.max_dead_tuples, new.num_dead_tuples
    );
    return new;
end $$;

drop trigger if exists vacuum_progress_view_insert on pgfr_record.vacuum_progress_snapshots;
create trigger vacuum_progress_view_insert
    instead of insert on pgfr_record.vacuum_progress_snapshots
    for each row
    execute function pgfr_record._vacuum_progress_view_insert();

-- table_snapshots → table_snapshots_v2
create or replace function pgfr_record._table_snapshots_view_insert()
returns trigger language plpgsql as $$
declare
    v_sample_ts int4;
begin
    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;
    perform pgfr_record._ensure_partition('table_snapshots_v2', current_date,
        'relid, dbid, sample_ts desc');
    insert into pgfr_record.table_snapshots_v2 (
        snapshot_id, sample_ts, relid, dbid,
        n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
        seq_scan, idx_scan, n_live_tup, n_dead_tup, table_size_bytes
    ) values (
        new.snapshot_id, v_sample_ts,
        new.relid,
        (select oid from pg_database where datname = current_database()),
        new.n_tup_ins, new.n_tup_upd, new.n_tup_del, new.n_tup_hot_upd,
        new.seq_scan, new.idx_scan, new.n_live_tup, new.n_dead_tup,
        new.table_size_bytes
    );
    return new;
end $$;

drop trigger if exists table_snapshots_view_insert on pgfr_record.table_snapshots;
create trigger table_snapshots_view_insert
    instead of insert on pgfr_record.table_snapshots
    for each row
    execute function pgfr_record._table_snapshots_view_insert();

-- index_snapshots → index_snapshots_v2
create or replace function pgfr_record._index_snapshots_view_insert()
returns trigger language plpgsql as $$
declare
    v_sample_ts int4;
begin
    v_sample_ts := extract(epoch from now() - pgfr_record.epoch())::int4;
    perform pgfr_record._ensure_partition('index_snapshots_v2', current_date,
        'indexrelid, dbid, sample_ts desc');
    insert into pgfr_record.index_snapshots_v2 (
        snapshot_id, sample_ts, relid, indexrelid, dbid,
        idx_scan, idx_tup_read, idx_tup_fetch, index_size_bytes
    ) values (
        new.snapshot_id, v_sample_ts,
        new.relid, new.indexrelid,
        (select oid from pg_database where datname = current_database()),
        new.idx_scan, new.idx_tup_read, new.idx_tup_fetch,
        new.index_size_bytes
    );
    return new;
end $$;

drop trigger if exists index_snapshots_view_insert on pgfr_record.index_snapshots;
create trigger index_snapshots_view_insert
    instead of insert on pgfr_record.index_snapshots
    for each row
    execute function pgfr_record._index_snapshots_view_insert();

do $$
begin
    raise notice 'migrate_phase3: complete. Legacy tables preserved with _legacy suffix.';
    raise notice 'migrate_phase3: verify v2 data, then drop _legacy tables when ready.';
    raise notice 'migrate_phase3: rollback available via migrate_phase3_rollback.sql';
end $$;

commit;
