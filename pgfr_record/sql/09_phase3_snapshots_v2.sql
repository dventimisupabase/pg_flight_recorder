-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Phase 3: daily-partitioned snapshots_v2 and aligned child tables
--
-- The existing plain-heap tables (snapshots, replication_snapshots, …) remain
-- untouched for backwards compatibility. New v2 tables are RANGE-partitioned by
-- sample_ts int4 (seconds since epoch()). No FK constraints: PostgreSQL cannot
-- cascade-delete into partitioned parent tables; we use aligned partition-DROP
-- instead. Orphaned rows are a minor filterable anomaly vs autovacuum death
-- spiral from FK cascade on partition drop. See SPEC Q1.
--
-- Dual-write: snapshot() writes to both old and new tables.
-- Migration: rename old tables to _legacy when ready (see pgfr_record/migrate_phase3.sql).
--------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. snapshots_v2 — daily RANGE partitioned, no SERIAL PK, no FK target
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.snapshots_v2 (
    snapshot_id     bigint      not null,   -- same id as old snapshots.id for cross-ref
    sample_ts       int4        not null,   -- seconds since pgfr_record.epoch()
    captured_at     timestamptz not null,
    pg_version      integer     not null,
    wal_records     bigint,
    wal_fpi         bigint,
    wal_bytes       bigint,
    wal_write_time  double precision,
    wal_sync_time   double precision,
    checkpoint_lsn  pg_lsn,
    checkpoint_time timestamptz,
    ckpt_timed      bigint,
    ckpt_requested  bigint,
    ckpt_write_time double precision,
    ckpt_sync_time  double precision,
    ckpt_buffers    bigint,
    bgw_buffers_clean       bigint,
    bgw_maxwritten_clean    bigint,
    bgw_buffers_alloc       bigint,
    autovacuum_workers      integer,
    slots_count             integer,
    slots_max_retained_wal  bigint,
    io_checkpointer_reads       bigint,
    io_checkpointer_read_time   double precision,
    io_checkpointer_writes      bigint,
    io_checkpointer_write_time  double precision,
    io_checkpointer_fsyncs      bigint,
    io_checkpointer_fsync_time  double precision,
    io_autovacuum_reads         bigint,
    io_autovacuum_read_time     double precision,
    io_autovacuum_writes        bigint,
    io_autovacuum_write_time    double precision,
    io_client_reads             bigint,
    io_client_read_time         double precision,
    io_client_writes            bigint,
    io_client_write_time        double precision,
    io_bgwriter_reads           bigint,
    io_bgwriter_read_time       double precision,
    io_bgwriter_writes          bigint,
    io_bgwriter_write_time      double precision,
    temp_files      bigint,
    temp_bytes      bigint,
    xact_commit     bigint,
    xact_rollback   bigint,
    blks_read       bigint,
    blks_hit        bigint,
    connections_active  integer,
    connections_total   integer,
    connections_max     integer,
    db_size_bytes       bigint,
    datfrozenxid_age    integer,
    datminmxid_age      integer,
    archived_count      bigint,
    last_archived_wal   text,
    last_archived_time  timestamptz,
    failed_count        bigint,
    last_failed_wal     text,
    last_failed_time    timestamptz,
    archiver_stats_reset timestamptz,
    confl_tablespace    bigint,
    confl_lock          bigint,
    confl_snapshot      bigint,
    confl_bufferpin     bigint,
    confl_deadlock      bigint,
    confl_active_logicalslot bigint,
    max_catalog_oid     bigint,
    large_object_count  bigint
) partition by range (sample_ts);

create table if not exists pgfr_record.snapshots_v2_default
    partition of pgfr_record.snapshots_v2 default;

-- Additive upgrade path: ensure MultiXID age column exists on pre-existing installs
alter table pgfr_record.snapshots_v2 add column if not exists datminmxid_age integer;

-- Issue #73 foundation: column parity with the legacy snapshots heap, so the
-- eventual cutover is a mechanical source flip instead of a shape migration.
-- bgw_buffers_backend/_fsync were removed from pg_stat_bgwriter in PG17 but
-- PG15/16 still report them and the legacy heap stores them; the 13
-- xmin-horizon columns were only ever written to the legacy heap.
alter table pgfr_record.snapshots_v2 add column if not exists bgw_buffers_backend bigint;
alter table pgfr_record.snapshots_v2 add column if not exists bgw_buffers_backend_fsync bigint;
alter table pgfr_record.snapshots_v2 add column if not exists activity_xmin xid;
alter table pgfr_record.snapshots_v2 add column if not exists activity_xmin_age bigint;
alter table pgfr_record.snapshots_v2 add column if not exists slot_xmin xid;
alter table pgfr_record.snapshots_v2 add column if not exists slot_xmin_age bigint;
alter table pgfr_record.snapshots_v2 add column if not exists slot_catalog_xmin xid;
alter table pgfr_record.snapshots_v2 add column if not exists slot_catalog_xmin_age bigint;
alter table pgfr_record.snapshots_v2 add column if not exists replication_xmin xid;
alter table pgfr_record.snapshots_v2 add column if not exists replication_xmin_age bigint;
alter table pgfr_record.snapshots_v2 add column if not exists prepared_xmin xid;
alter table pgfr_record.snapshots_v2 add column if not exists prepared_xmin_age bigint;
alter table pgfr_record.snapshots_v2 add column if not exists xmin_data_horizon_age bigint;
alter table pgfr_record.snapshots_v2 add column if not exists xmin_any_horizon_age bigint;
alter table pgfr_record.snapshots_v2 add column if not exists xmin_horizon_detail jsonb;

comment on table pgfr_record.snapshots_v2 is
'Cluster-level snapshot metrics, daily RANGE-partitioned by int4 sample_ts. '
'No FK constraints: child tables use snapshot_id as logical (non-enforced) reference. '
'Retention via truncate_old_partitions() / drop_ancient_partitions() — no DELETE. '
'Column parity with the legacy snapshots heap (Issue #73): bgw_buffers_backend '
'and bgw_buffers_backend_fsync are populated on PG15/16 only (removed from '
'pg_stat_bgwriter in PG17), and the xmin-horizon columns are written back by '
'snapshot()''s xmin section after insert. See SPEC §3, Q1.';

-- ---------------------------------------------------------------------------
-- 2. replication_snapshots_v2 — daily RANGE partitioned, no FK
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.replication_snapshots_v2 (
    snapshot_id         bigint      not null,   -- logical ref to snapshots_v2.snapshot_id
    sample_ts           int4        not null,
    pid                 integer     not null,
    client_addr         inet,
    application_name    text,
    state               text,
    sent_lsn            pg_lsn,
    write_lsn           pg_lsn,
    flush_lsn           pg_lsn,
    replay_lsn          pg_lsn,
    write_lag           interval,
    flush_lag           interval,
    replay_lag          interval,
    sync_state          text,
    reply_time          timestamptz
) partition by range (sample_ts);

create table if not exists pgfr_record.replication_snapshots_v2_default
    partition of pgfr_record.replication_snapshots_v2 default;

-- Issue #73 foundation: parity with the legacy twin's xmin/walsender columns,
-- which snapshot()'s xmin section reads back for horizon attribution.
alter table pgfr_record.replication_snapshots_v2 add column if not exists backend_xmin xid;
alter table pgfr_record.replication_snapshots_v2 add column if not exists backend_xmin_age bigint;
alter table pgfr_record.replication_snapshots_v2 add column if not exists slot_name text;
alter table pgfr_record.replication_snapshots_v2 add column if not exists is_logical_walsender boolean;

comment on table pgfr_record.replication_snapshots_v2 is
'Per-replica replication state, daily RANGE-partitioned by int4 sample_ts. '
'snapshot_id is a logical (non-FK) reference to snapshots_v2. '
'Retention co-aligned with snapshots_v2 partitions.';

-- ---------------------------------------------------------------------------
-- 3. vacuum_progress_snapshots_v2 — daily RANGE partitioned, no FK
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.vacuum_progress_snapshots_v2 (
    snapshot_id         bigint  not null,
    sample_ts           int4    not null,
    pid                 integer not null,
    datname             text,
    relid               oid,
    phase               text,
    heap_blks_total     bigint,
    heap_blks_scanned   bigint,
    heap_blks_vacuumed  bigint,
    index_vacuum_count  bigint,
    max_dead_tuples     bigint,
    num_dead_tuples     bigint
) partition by range (sample_ts);

create table if not exists pgfr_record.vacuum_progress_snapshots_v2_default
    partition of pgfr_record.vacuum_progress_snapshots_v2 default;

-- Issue #73 foundation: parity with the legacy twin (datid/relname), so
-- recent_vacuum_progress and report()'s vacuum section can cut over.
alter table pgfr_record.vacuum_progress_snapshots_v2 add column if not exists datid oid;
alter table pgfr_record.vacuum_progress_snapshots_v2 add column if not exists relname text;

comment on table pgfr_record.vacuum_progress_snapshots_v2 is
'In-progress VACUUM state per snapshot tick, daily RANGE-partitioned by int4 sample_ts. '
'snapshot_id is a logical (non-FK) reference to snapshots_v2. Column parity with the '
'legacy twin (Issue #73); on PG17+ max_dead_tuples carries max_dead_tuple_bytes and '
'num_dead_tuples carries num_dead_item_ids, matching the legacy behavior.';

-- ---------------------------------------------------------------------------
-- 4. Pre-create today's partitions for all three new tables
-- ---------------------------------------------------------------------------
do $$
begin
    perform pgfr_record._ensure_partition('snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');
    perform pgfr_record._ensure_partition('replication_snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');
    perform pgfr_record._ensure_partition('vacuum_progress_snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');
    -- pre-create tomorrow's partitions so cron jobs running at 23:59 don't miss
    perform pgfr_record._ensure_partition('snapshots_v2', current_date + 1,
        'snapshot_id, sample_ts desc');
    perform pgfr_record._ensure_partition('replication_snapshots_v2', current_date + 1,
        'snapshot_id, sample_ts desc');
    perform pgfr_record._ensure_partition('vacuum_progress_snapshots_v2', current_date + 1,
        'snapshot_id, sample_ts desc');
end $$;

-- ---------------------------------------------------------------------------
-- 5. _snapshot_v2() — dual-write wrapper called by snapshot()
--    Inserts into snapshots_v2 and aligned child tables in the same tick.
--    Separate function so it can be tested independently and added to
--    existing snapshot() call chain without restructuring.
-- ---------------------------------------------------------------------------
-- Issue #73 PR 2: the dual-write path is retired. snapshot() now writes
-- snapshots_v2 directly through the pgfr_record.snapshots compat view (see
-- 13_snapshots_cutover.sql), so _snapshot_v2()'s catalog re-read and main
-- insert are superseded; only the replication/vacuum v2 twin collection
-- survives, extracted here and called from snapshot() alongside
-- _collect_consumption_snapshot().
do $$
begin
    set local client_min_messages = warning;
    drop trigger if exists snapshot_v2_dual_write on pgfr_record.snapshots;
    drop function if exists pgfr_record._snapshot_v2_trigger();
    drop function if exists pgfr_record._snapshot_v2(bigint);
end $$;

create or replace function pgfr_record._snapshot_children_v2(p_snapshot_id bigint)
returns void
language plpgsql as $$
declare
    v_sample_ts  int4;
    v_pg_version integer;
begin
    v_sample_ts  := extract(epoch from now() - pgfr_record.epoch())::int4;
    v_pg_version := pgfr_record._pg_version();

    -- replication_snapshots_v2
    perform pgfr_record._ensure_partition('replication_snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');
    insert into pgfr_record.replication_snapshots_v2 (
        snapshot_id, sample_ts,
        pid, client_addr, application_name, state,
        sent_lsn, write_lsn, flush_lsn, replay_lsn,
        write_lag, flush_lag, replay_lag, sync_state, reply_time,
        backend_xmin, backend_xmin_age, slot_name, is_logical_walsender
    )
    select
        p_snapshot_id, v_sample_ts,
        r.pid, r.client_addr, r.application_name, r.state,
        r.sent_lsn, r.write_lsn, r.flush_lsn, r.replay_lsn,
        r.write_lag, r.flush_lag, r.replay_lag, r.sync_state, r.reply_time,
        r.backend_xmin,
        case when r.backend_xmin is not null then age(r.backend_xmin) end,
        sl.slot_name,
        coalesce(sl.slot_type = 'logical', false)
    from pg_stat_replication r
    left join pg_replication_slots sl on sl.active_pid = r.pid;

    -- vacuum_progress_snapshots_v2
    perform pgfr_record._ensure_partition('vacuum_progress_snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');
    -- Mirrors the legacy writer exactly (Issue #73 parity): datid/relname
    -- included, and on PG17+ the renamed dead-tuple counters land in the
    -- legacy column names, same as the legacy twin.
    if v_pg_version >= 17 then
        execute $q$
            insert into pgfr_record.vacuum_progress_snapshots_v2 (
                snapshot_id, sample_ts,
                pid, datid, datname, relid, relname, phase,
                heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
                index_vacuum_count, max_dead_tuples, num_dead_tuples
            )
            select
                $1, $2,
                pv.pid, pv.datid, pd.datname, pv.relid, pc.relname, pv.phase,
                pv.heap_blks_total, pv.heap_blks_scanned, pv.heap_blks_vacuumed,
                pv.index_vacuum_count,
                pv.max_dead_tuple_bytes,  -- renamed in PG17
                pv.num_dead_item_ids      -- renamed in PG17
            from pg_stat_progress_vacuum pv
            left join pg_database pd on pd.oid = pv.datid
            left join pg_class pc on pc.oid = pv.relid
        $q$ using p_snapshot_id, v_sample_ts;
    else
        execute $q$
            insert into pgfr_record.vacuum_progress_snapshots_v2 (
                snapshot_id, sample_ts,
                pid, datid, datname, relid, relname, phase,
                heap_blks_total, heap_blks_scanned, heap_blks_vacuumed,
                index_vacuum_count, max_dead_tuples, num_dead_tuples
            )
            select
                $1, $2,
                pv.pid, pv.datid, pd.datname, pv.relid, pc.relname, pv.phase,
                pv.heap_blks_total, pv.heap_blks_scanned, pv.heap_blks_vacuumed,
                pv.index_vacuum_count,
                pv.max_dead_tuples,
                pv.num_dead_tuples
            from pg_stat_progress_vacuum pv
            left join pg_database pd on pd.oid = pv.datid
            left join pg_class pc on pc.oid = pv.relid
        $q$ using p_snapshot_id, v_sample_ts;
    end if;

exception when others then
    raise warning 'pgfr_record: _snapshot_children_v2 failed [%]: %', sqlstate, sqlerrm;
end;
$$;

comment on function pgfr_record._snapshot_children_v2(bigint) is
'Collects the replication_snapshots_v2 and vacuum_progress_snapshots_v2 twins for one snapshot tick. Called from snapshot() after its main insert (the dual-write trigger that used to drive this is retired, Issue #73). Non-fatal on failure.';

-- ---------------------------------------------------------------------------
-- 6. Wire _snapshot_v2() into the existing snapshot() function
--    Find the end of snapshot() and append the call (idempotent guard).
-- ---------------------------------------------------------------------------
-- Note: snapshot() returns the new snapshot_id — we call _snapshot_v2 at the
-- end of snapshot() by adding a call in its final block.
-- Rather than rewriting the large snapshot() function, we patch it via a
-- trigger on snapshots that dual-writes to snapshots_v2.
-- The AFTER INSERT dual-write trigger and its function are retired
-- (Issue #73 PR 2): fresh installs cut snapshots over to the compat view in
-- the same run (13_snapshots_cutover.sql), and snapshot() drives the v2
-- children and the consumption ledger directly. The standing drops live
-- above, next to _snapshot_children_v2().

-- ---------------------------------------------------------------------------
-- 7. pgfr_precreate_partitions cron scheduling is consolidated into
--    pgfr_record.enable() (see 05_functions_ops.sql). install.sql calls
--    enable() as its final step.
-- ---------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- End of Phase 3
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Phase 3b archive v2 tables (activity_samples_archive_v2, etc.) retired
-- alongside their writers (archive_ring_samples()) and the legacy archive
-- heap tables in 02_tables.sql. No code paths remained that wrote or read
-- the partitioned archive_v2 tables once archive_ring_samples() was dropped.
--------------------------------------------------------------------------------
DO $$
BEGIN
    SET LOCAL client_min_messages = warning;
    DROP TABLE IF EXISTS pgfr_record.activity_samples_archive_v2 CASCADE;
    DROP TABLE IF EXISTS pgfr_record.lock_samples_archive_v2     CASCADE;
    DROP TABLE IF EXISTS pgfr_record.wait_samples_archive_v2     CASCADE;
END $$;


-- ---------------------------------------------------------------------------
-- retention_archive_days: wire GC for archive v2 tables
-- truncate_old_partitions() and drop_ancient_partitions() pick up all
-- pgfr_record RANGE-partitioned tables automatically via _partition_inventory().
-- Add retention_archive_days config key if not present.
-- ---------------------------------------------------------------------------
insert into pgfr_record.config (key, value, updated_at)
values ('retention_archive_days', '7', now())
on conflict (key) do nothing;

comment on column pgfr_record.config.key is
'retention_archive_days: days before archive-tier partitions are TRUNCATEd (default 7). '
'After the archive_v2 retirement this currently has no active subscriber, but the key '
'is retained for future archive-tier tables. '
'truncate_old_partitions() uses retention_snapshots_days for snapshot-tier; '
'drop_ancient_partitions() drops empty shells older than 2× respective retention.';

--------------------------------------------------------------------------------
-- End of Phase 3b
--------------------------------------------------------------------------------
