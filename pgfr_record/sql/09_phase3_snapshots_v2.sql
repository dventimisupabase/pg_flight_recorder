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
create or replace function pgfr_record._snapshot_v2(p_snapshot_id bigint)
returns void
language plpgsql as $$
declare
    v_sample_ts         int4;
    v_pg_version        integer;
    v_ckpt_timed        bigint;
    v_ckpt_requested    bigint;
    v_ckpt_write_time   double precision;
    v_ckpt_sync_time    double precision;
    v_ckpt_buffers      bigint;
    v_io_ckpt_reads     bigint;
    v_io_ckpt_read_t    double precision;
    v_io_ckpt_writes    bigint;
    v_io_ckpt_write_t   double precision;
    v_io_ckpt_fsyncs    bigint;
    v_io_ckpt_fsync_t   double precision;
    v_io_av_reads       bigint;
    v_io_av_read_t      double precision;
    v_io_av_writes      bigint;
    v_io_av_write_t     double precision;
    v_io_cli_reads      bigint;
    v_io_cli_read_t     double precision;
    v_io_cli_writes     bigint;
    v_io_cli_write_t    double precision;
    v_io_bgw_reads      bigint;
    v_io_bgw_read_t     double precision;
    v_io_bgw_writes     bigint;
    v_io_bgw_write_t    double precision;
    v_confl_logicalslot bigint := 0;
    v_wal_records       bigint;
    v_wal_fpi           bigint;
    v_wal_bytes         numeric;
    v_wal_write_time    double precision;  -- PG18+ dropped from pg_stat_wal; stays NULL
    v_wal_sync_time     double precision;  -- PG18+ dropped from pg_stat_wal; stays NULL
    v_bgw_backend       bigint;            -- PG15/16 only; removed from pg_stat_bgwriter in PG17
    v_bgw_backend_fsync bigint;            -- same
begin
    v_sample_ts  := extract(epoch from now() - pgfr_record.epoch())::int4;
    v_pg_version := pgfr_record._pg_version();

    -- pg_stat_checkpointer was added in PG17; fall back to pg_stat_bgwriter on PG15/16
    if v_pg_version >= 17 then
        execute $q$
            select num_timed, num_requested, write_time, sync_time, buffers_written
            from pg_stat_checkpointer
        $q$ into v_ckpt_timed, v_ckpt_requested, v_ckpt_write_time, v_ckpt_sync_time, v_ckpt_buffers;
    else
        execute $q$
            select checkpoints_timed, checkpoints_req, checkpoint_write_time,
                   checkpoint_sync_time, buffers_checkpoint,
                   buffers_backend, buffers_backend_fsync
            from pg_stat_bgwriter
        $q$ into v_ckpt_timed, v_ckpt_requested, v_ckpt_write_time,
                 v_ckpt_sync_time, v_ckpt_buffers,
                 v_bgw_backend, v_bgw_backend_fsync;
    end if;

    -- pg_stat_io added in PG16; NULL on PG15
    if v_pg_version >= 16 then
        execute $q$
            select
                sum(reads)      filter (where backend_type = 'checkpointer'),
                sum(read_time)  filter (where backend_type = 'checkpointer'),
                sum(writes)     filter (where backend_type = 'checkpointer'),
                sum(write_time) filter (where backend_type = 'checkpointer'),
                sum(fsyncs)     filter (where backend_type = 'checkpointer'),
                sum(fsync_time) filter (where backend_type = 'checkpointer'),
                sum(reads)      filter (where backend_type = 'autovacuum worker'),
                sum(read_time)  filter (where backend_type = 'autovacuum worker'),
                sum(writes)     filter (where backend_type = 'autovacuum worker'),
                sum(write_time) filter (where backend_type = 'autovacuum worker'),
                sum(reads)      filter (where backend_type = 'client backend'),
                sum(read_time)  filter (where backend_type = 'client backend'),
                sum(writes)     filter (where backend_type = 'client backend'),
                sum(write_time) filter (where backend_type = 'client backend'),
                sum(reads)      filter (where backend_type = 'background writer'),
                sum(read_time)  filter (where backend_type = 'background writer'),
                sum(writes)     filter (where backend_type = 'background writer'),
                sum(write_time) filter (where backend_type = 'background writer')
            from pg_stat_io
        $q$ into
            v_io_ckpt_reads,  v_io_ckpt_read_t,  v_io_ckpt_writes,  v_io_ckpt_write_t,
            v_io_ckpt_fsyncs, v_io_ckpt_fsync_t,
            v_io_av_reads,    v_io_av_read_t,    v_io_av_writes,    v_io_av_write_t,
            v_io_cli_reads,   v_io_cli_read_t,   v_io_cli_writes,   v_io_cli_write_t,
            v_io_bgw_reads,   v_io_bgw_read_t,   v_io_bgw_writes,   v_io_bgw_write_t;
    end if;
    -- PG15: all io_* vars remain NULL

    -- confl_active_logicalslot added in PG17
    if v_pg_version >= 17 then
        execute $q$
            select confl_active_logicalslot
            from pg_stat_database_conflicts
            where datid = (select oid from pg_database where datname = current_database())
        $q$ into v_confl_logicalslot;
        v_confl_logicalslot := coalesce(v_confl_logicalslot, 0);
    end if;

    -- pg_stat_wal dropped wal_write_time / wal_sync_time in PG18. Capture via
    -- version-guarded EXECUTE so the parser never sees the removed columns on
    -- PG18+. CASE-WHEN guards don't work here: column refs are resolved at
    -- parse time, not runtime.
    if v_pg_version >= 18 then
        execute $q$select wal_records, wal_fpi, wal_bytes from pg_stat_wal$q$
            into v_wal_records, v_wal_fpi, v_wal_bytes;
        -- v_wal_write_time, v_wal_sync_time remain NULL
    else
        execute $q$
            select wal_records, wal_fpi, wal_bytes, wal_write_time, wal_sync_time
            from pg_stat_wal
        $q$ into v_wal_records, v_wal_fpi, v_wal_bytes, v_wal_write_time, v_wal_sync_time;
    end if;

    -- ensure today's partition exists (O(1) on happy path)
    perform pgfr_record._ensure_partition('snapshots_v2', current_date,
        'snapshot_id, sample_ts desc');

    insert into pgfr_record.snapshots_v2 (
        snapshot_id, sample_ts, captured_at, pg_version,
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
        db_size_bytes, datfrozenxid_age, datminmxid_age,
        archived_count, last_archived_wal, last_archived_time,
        failed_count, last_failed_wal, last_failed_time, archiver_stats_reset,
        confl_tablespace, confl_lock, confl_snapshot,
        confl_bufferpin, confl_deadlock, confl_active_logicalslot,
        max_catalog_oid, large_object_count
    )
    select
        p_snapshot_id,
        v_sample_ts,
        now(),
        v_pg_version,
        v_wal_records, v_wal_fpi, v_wal_bytes,
        v_wal_write_time, v_wal_sync_time,
        -- checkpoint_lsn and checkpoint_time come from pg_control_checkpoint(),
        -- not pg_stat_checkpointer (which only has counters and timing)
        pgcc.checkpoint_lsn, pgcc.checkpoint_time,
        v_ckpt_timed, v_ckpt_requested,
        v_ckpt_write_time, v_ckpt_sync_time, v_ckpt_buffers,
        bg.buffers_clean, bg.maxwritten_clean, bg.buffers_alloc,
        v_bgw_backend, v_bgw_backend_fsync,
        (select count(*) from pg_stat_activity where state = 'active' and query not like '%autovacuum%')::integer,
        (select count(*) from pg_replication_slots)::integer,
        (select max(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
            from pg_replication_slots where active)::bigint,
        -- io stats from pg_stat_io (PG16+); NULL on PG15
        v_io_ckpt_reads,  v_io_ckpt_read_t,  v_io_ckpt_writes,  v_io_ckpt_write_t,
        v_io_ckpt_fsyncs, v_io_ckpt_fsync_t,
        v_io_av_reads,    v_io_av_read_t,    v_io_av_writes,    v_io_av_write_t,
        v_io_cli_reads,   v_io_cli_read_t,   v_io_cli_writes,   v_io_cli_write_t,
        v_io_bgw_reads,   v_io_bgw_read_t,   v_io_bgw_writes,   v_io_bgw_write_t,
        db.temp_files, db.temp_bytes,
        db.xact_commit, db.xact_rollback, db.blks_read, db.blks_hit,
        (select count(*) filter (where state = 'active') from pg_stat_activity)::integer,
        (select count(*) from pg_stat_activity)::integer,
        current_setting('max_connections')::integer,
        pg_database_size(current_database())::bigint,
        age((select datfrozenxid from pg_database where datname = current_database())),
        mxid_age((select datminmxid from pg_database where datname = current_database())),
        ar.archived_count, ar.last_archived_wal, ar.last_archived_time,
        ar.failed_count, ar.last_failed_wal, ar.last_failed_time, ar.stats_reset,
        cs.confl_tablespace, cs.confl_lock, cs.confl_snapshot,
        cs.confl_bufferpin, cs.confl_deadlock,
        v_confl_logicalslot,
        (select max(oid) from pg_class),
        (select count(*) from pg_largeobject_metadata)
    from pg_control_checkpoint() pgcc
    cross join pg_stat_bgwriter bg
    cross join (select * from pg_stat_database where datname = current_database()) db
    cross join pg_stat_archiver ar
    cross join (select * from pg_stat_database_conflicts where datid =
                    (select oid from pg_database where datname = current_database())) cs;

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
    raise warning 'pgfr_record: _snapshot_v2 failed [%]: %', sqlstate, sqlerrm;
end;
$$;

comment on function pgfr_record._snapshot_v2(bigint) is
'Dual-write counterpart of snapshot(): inserts into snapshots_v2, '
'replication_snapshots_v2, vacuum_progress_snapshots_v2. '
'Called at end of snapshot() for dual operation during Phase 3 migration. '
'Failure is non-fatal: wrapped in EXCEPTION, emits WARNING. '
'Drop once migration to v2-only is complete. See SPEC §3.';

-- ---------------------------------------------------------------------------
-- 6. Wire _snapshot_v2() into the existing snapshot() function
--    Find the end of snapshot() and append the call (idempotent guard).
-- ---------------------------------------------------------------------------
-- Note: snapshot() returns the new snapshot_id — we call _snapshot_v2 at the
-- end of snapshot() by adding a call in its final block.
-- Rather than rewriting the large snapshot() function, we patch it via a
-- trigger on snapshots that dual-writes to snapshots_v2.
create or replace function pgfr_record._snapshot_v2_trigger()
returns trigger
language plpgsql as $$
begin
    perform pgfr_record._snapshot_v2(new.id::bigint);
    return new;
end;
$$;

comment on function pgfr_record._snapshot_v2_trigger() is
'AFTER INSERT trigger on snapshots: dual-writes to snapshots_v2 and aligned '
'child tables. Non-invasive integration with existing snapshot() function. '
'Drop trigger and function once migration to v2-only snapshot() is complete.';

drop trigger if exists snapshot_v2_dual_write on pgfr_record.snapshots;
create trigger snapshot_v2_dual_write
    after insert on pgfr_record.snapshots
    for each row
    execute function pgfr_record._snapshot_v2_trigger();

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
