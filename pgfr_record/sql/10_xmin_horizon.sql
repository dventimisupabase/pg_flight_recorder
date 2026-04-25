--------------------------------------------------------------------------------
-- Phase: xmin horizon monitoring — holder sidecar tables
--
-- Three daily RANGE-partitioned sidecars matching XMIN_HORIZON.md §4.3:
--   - xmin_activity_holders   (pg_stat_activity.backend_xmin holders)
--   - xmin_slot_holders       (pg_replication_slots xmin / catalog_xmin holders)
--   - xmin_prepared_holders   (pg_prepared_xacts holders)
--
-- All sidecars partition by RANGE(sample_ts INTEGER) — seconds since
-- pgfr_record.epoch(). The PK includes sample_ts first (required for RANGE
-- partition keys). No FK to snapshots(id): partition-aligned GC handles
-- retention; orphans are a benign filterable anomaly.
--
-- Per-partition B-tree indexes are created via the 3-arg _ensure_partition
-- overload (07_sparse_collectors.sql) at partition creation time. Parent-
-- level partitioned indexes are also declared so schema-level pgTAP
-- has_index assertions resolve against the parent (and so future partitions
-- inherit them automatically).
--
-- Collector code is added later (Milestone 3); only DDL lives in this file.
-- See blueprints/XMIN_HORIZON.md §4.3.1 / §4.3.2 / §4.3.3 / §4.3.5.
--------------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. xmin_activity_holders — pg_stat_activity.backend_xmin holders
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.xmin_activity_holders (
    sample_ts         integer     not null,
    snapshot_id       integer     not null,
    pid               integer     not null,
    datid             oid,
    datname           text,
    usesysid          oid,
    usename           text,
    application_name  text,
    client_addr       inet,
    backend_type      text,
    state             text,
    backend_start     timestamptz,
    xact_start        timestamptz,
    xact_age_seconds  bigint,
    query_start       timestamptz,
    query_age_seconds bigint,
    state_change      timestamptz,
    wait_event_type   text,
    wait_event        text,
    backend_xid       xid,
    backend_xid_age   bigint,
    backend_xmin      xid    not null,
    backend_xmin_age  bigint not null,
    queryid           bigint,
    query_preview     text,
    primary key (sample_ts, snapshot_id, pid)
) partition by range (sample_ts);

create table if not exists pgfr_record.xmin_activity_holders_default
    partition of pgfr_record.xmin_activity_holders default;

-- Parent-level partitioned index — applies to all current/future partitions
-- and resolves schema-level has_index assertions against the parent.
create index if not exists xmin_activity_holders_ts_age_idx
    on pgfr_record.xmin_activity_holders (sample_ts desc, backend_xmin_age desc);

comment on table pgfr_record.xmin_activity_holders is
'Backends holding the xmin horizon via pg_stat_activity.backend_xmin. '
'Top xmin_holders_top_n per snapshot, ordered by (backend_xmin_age DESC, pid ASC) '
'for stable intra-source tie-breaking. Self-pin excluded via pid <> pg_backend_pid(). '
'Parallel workers excluded at write time (pg_stat_activity.leader_pid IS NULL filter); '
'leader appears once with its own backend_xmin, workers are derivable via live lookup.';

-- ---------------------------------------------------------------------------
-- 2. xmin_slot_holders — pg_replication_slots xmin/catalog_xmin holders
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.xmin_slot_holders (
    sample_ts            integer not null,
    snapshot_id          integer not null,
    slot_name            text    not null,
    slot_type            text,
    database             text,
    plugin               text,
    active               boolean,
    active_pid           integer,
    xmin                 xid,
    xmin_age             bigint,
    catalog_xmin         xid,
    catalog_xmin_age     bigint,
    restart_lsn          pg_lsn,
    confirmed_flush_lsn  pg_lsn,
    wal_status           text,
    safe_wal_size        bigint,
    conflicting          boolean,
    invalidation_reason  text,
    primary key (sample_ts, snapshot_id, slot_name)
) partition by range (sample_ts);

create table if not exists pgfr_record.xmin_slot_holders_default
    partition of pgfr_record.xmin_slot_holders default;

create index if not exists xmin_slot_holders_ts_idx
    on pgfr_record.xmin_slot_holders (sample_ts desc);

comment on table pgfr_record.xmin_slot_holders is
'Replication slots holding the xmin horizon (physical slots via xmin, '
'logical slots via xmin and/or catalog_xmin). DROP REPLICATION SLOT target set. '
'Ordered for intra-source tie-breaking by (greatest(xmin_age, catalog_xmin_age) DESC, slot_name ASC). '
'conflicting / invalidation_reason populated conditionally on PG version.';

-- ---------------------------------------------------------------------------
-- 3. xmin_prepared_holders — pg_prepared_xacts holders
-- ---------------------------------------------------------------------------
create table if not exists pgfr_record.xmin_prepared_holders (
    sample_ts         integer not null,
    snapshot_id       integer not null,
    gid               text    not null,
    prepared_xmin     xid,
    prepared_xmin_age bigint,
    prepared_at       timestamptz,
    owner             text,
    database          text,
    primary key (sample_ts, snapshot_id, gid)
) partition by range (sample_ts);

create table if not exists pgfr_record.xmin_prepared_holders_default
    partition of pgfr_record.xmin_prepared_holders default;

create index if not exists xmin_prepared_holders_ts_age_idx
    on pgfr_record.xmin_prepared_holders (sample_ts desc, prepared_xmin_age desc);

comment on table pgfr_record.xmin_prepared_holders is
'Prepared transactions holding the xmin horizon. ROLLBACK PREPARED target set. '
'Ordered for intra-source tie-breaking by (prepared_xmin_age DESC, gid ASC). '
'Always-collected: floor and cap configured independently (xmin_prepared_min_age, '
'xmin_prepared_holders_top_n) because prepared xacts are rare, tiny, and high-signal. '
'If xmin_prepared_truncated_count > 0 persists, bump xmin_prepared_holders_top_n — '
'the sidecar becomes lossy precisely when attribution matters most.';

-- ---------------------------------------------------------------------------
-- 4. Pre-create today + tomorrow partitions for all three xmin holder tables.
--    The 3-arg _ensure_partition overload (07_sparse_collectors.sql) creates
--    per-partition B-tree + BRIN indexes; the parent-level partitioned indexes
--    above also propagate to each new partition automatically.
-- ---------------------------------------------------------------------------
do $$
begin
    perform pgfr_record._ensure_partition('xmin_activity_holders', current_date,
        'backend_xmin_age desc, sample_ts desc');
    perform pgfr_record._ensure_partition('xmin_slot_holders', current_date,
        'slot_name, sample_ts desc');
    perform pgfr_record._ensure_partition('xmin_prepared_holders', current_date,
        'gid, sample_ts desc');
    -- pre-create tomorrow's partitions so cron jobs running at 23:59 don't miss
    perform pgfr_record._ensure_partition('xmin_activity_holders', current_date + 1,
        'backend_xmin_age desc, sample_ts desc');
    perform pgfr_record._ensure_partition('xmin_slot_holders', current_date + 1,
        'slot_name, sample_ts desc');
    perform pgfr_record._ensure_partition('xmin_prepared_holders', current_date + 1,
        'gid, sample_ts desc');
exception when others then
    raise warning 'pgfr_record: xmin holder partition pre-create failed [%]: %', sqlstate, sqlerrm;
end $$;

--------------------------------------------------------------------------------
-- End of xmin holder sidecar DDL
--------------------------------------------------------------------------------
