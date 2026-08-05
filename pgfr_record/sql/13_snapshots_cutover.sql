-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

--------------------------------------------------------------------------------
-- Snapshots cutover (Issue #73, PR 2 of 3).
--
-- pgfr_record.snapshots stops being a heap table and becomes a compatibility
-- view over snapshots_v2, which is now the single write target. Readers keep
-- their captured_at/id shape unchanged; the dual-write trigger, its double
-- catalog read, and the doubled storage are gone.
--
-- The one-time conversion (guarded on snapshots still being a table):
--   1. backfill any legacy rows that predate the dual-write trigger into
--      snapshots_v2 (per-day partitions ensured first),
--   2. drop the FK constraints referencing snapshots(id): a view cannot be an
--      FK target, and a table partitioned by sample_ts cannot host the unique
--      index on snapshot_id the FKs would need (cleanup() reaps the child
--      heaps explicitly instead, see 05_functions_ops.sql),
--   3. decouple the id sequence from the heap (so the final PR's drop cannot
--      cascade it away) and rename the heap to snapshots_legacy (kept until
--      PR 3 as a rollback anchor).
--
-- The steady-state objects (recreated on every install):
--   - the view, built dynamically from snapshots_v2's columns (snapshot_id
--     exposed as id) so future additive v2 columns flow through,
--   - an INSTEAD OF INSERT trigger that assigns id from the legacy sequence,
--     derives sample_ts from captured_at, ensures the day's partition, and
--     routes the row into snapshots_v2. UPDATE and DELETE need no trigger:
--     the single-table view is auto-updatable, so snapshot()'s xmin
--     write-back and cleanup()'s DELETE route through unchanged.
--
-- Post-cutover, id uniqueness is by convention (the sequence is the only
-- live id source); the partitioned base cannot enforce it. Historical ids
-- are preserved: the backfill carries legacy ids, and the sequence continues
-- the same series.
--------------------------------------------------------------------------------

do $$
declare
    v_rec      record;
    v_d        date;
    v_cols     text;
    v_src_cols text;
begin
    -- One-time conversion: only while the legacy heap is the live relation.
    if not exists (
        select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record' and c.relname = 'snapshots' and c.relkind = 'r'
    ) then
        return;
    end if;

    set local client_min_messages = warning;

    -- Belt and braces: 09_phase3_snapshots_v2.sql already drops the
    -- dual-write trigger, but nothing may fire between here and the rename.
    drop trigger if exists snapshot_v2_dual_write on pgfr_record.snapshots;

    -- 1. Backfill rows that predate the dual-write trigger. Partitions first
    --    so historical days route properly instead of piling into the
    --    default partition.
    for v_d in
        select distinct captured_at::date from pgfr_record.snapshots order by 1
    loop
        perform pgfr_record._ensure_partition('snapshots_v2', v_d, 'snapshot_id, sample_ts desc');
    end loop;

    select string_agg(quote_ident(a.attname), ', ' order by a.attnum),
           string_agg('s.' || quote_ident(a.attname), ', ' order by a.attnum)
    into v_cols, v_src_cols
    from pg_attribute a
    where a.attrelid = 'pgfr_record.snapshots'::regclass
      and a.attnum > 0 and not a.attisdropped
      and a.attname <> 'id'
      and exists (
          select 1 from pg_attribute b
          where b.attrelid = 'pgfr_record.snapshots_v2'::regclass
            and b.attnum > 0 and not b.attisdropped
            and b.attname = a.attname);

    execute format(
        'insert into pgfr_record.snapshots_v2 (snapshot_id, sample_ts, %s) '
        'select s.id, extract(epoch from s.captured_at - pgfr_record.epoch())::int4, %s '
        'from pgfr_record.snapshots s '
        'where not exists (select 1 from pgfr_record.snapshots_v2 v where v.snapshot_id = s.id)',
        v_cols, v_src_cols);

    -- 2. Drop every FK referencing snapshots(id).
    for v_rec in
        select conrelid::regclass::text as tbl, conname
        from pg_constraint
        where confrelid = 'pgfr_record.snapshots'::regclass and contype = 'f'
    loop
        execute format('alter table %s drop constraint %I', v_rec.tbl, v_rec.conname);
    end loop;

    -- 3. Keep the id series alive independently of the heap, then retire it.
    alter sequence pgfr_record.snapshots_id_seq owned by none;
    alter table pgfr_record.snapshots rename to snapshots_legacy;
end $$;

-- ---------------------------------------------------------------------------
-- The compat view, rebuilt from snapshots_v2's live column list on every
-- install so additive v2 columns appear automatically (CREATE OR REPLACE VIEW
-- only ever appends columns, which is exactly what additive evolution does).
-- ---------------------------------------------------------------------------
do $$
declare
    v_cols text;
begin
    select string_agg(quote_ident(attname), ', ' order by attnum)
    into v_cols
    from pg_attribute
    where attrelid = 'pgfr_record.snapshots_v2'::regclass
      and attnum > 0 and not attisdropped
      and attname <> 'snapshot_id';

    -- id is cast back to the legacy SERIAL type: every consumer (and the
    -- dependent views' column types) predates the cutover, and CREATE OR
    -- REPLACE VIEW cannot change an existing column's type.
    execute format(
        'create or replace view pgfr_record.snapshots as '
        'select snapshot_id::integer as id, %s from pgfr_record.snapshots_v2',
        v_cols);
end $$;

-- ---------------------------------------------------------------------------
-- Rebind dependent views. Views bind their sources by OID, so anything
-- defined before this file (deltas, archiver_status, recent_replication,
-- recent_vacuum_progress) silently followed the heap through its rename and
-- would read the frozen snapshots_legacy forever. Recreate each such view
-- from its own deparsed definition, textually repointed at the compat view.
-- Idempotent: once rebound, the definition no longer mentions the legacy
-- name and the loop skips it.
-- ---------------------------------------------------------------------------
do $$
declare
    v_rec record;
begin
    for v_rec in
        select c.oid, c.relname
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'pgfr_record'
          and c.relkind = 'v'
          and c.relname <> 'snapshots'
          and pg_get_viewdef(c.oid) like '%snapshots_legacy%'
    loop
        -- The deparser qualifies unaliased references with the bare relation
        -- name (e.g. max(snapshots_legacy.id)), so the replace must cover
        -- both the schema-qualified and bare forms; the single broad replace
        -- handles both, and no view definition contains the string in a
        -- literal.
        execute format('create or replace view pgfr_record.%I as %s',
            v_rec.relname,
            replace(pg_get_viewdef(v_rec.oid), 'snapshots_legacy', 'snapshots'));
        raise notice 'pgfr_record: rebound view %.% from snapshots_legacy to the compat view',
            'pgfr_record', v_rec.relname;
    end loop;
end $$;

comment on view pgfr_record.snapshots is
'Compatibility view over snapshots_v2 (Issue #73 cutover): snapshot_id exposed as id, every other column passed through. INSERT routes via an INSTEAD OF trigger (id from the legacy sequence, sample_ts derived from captured_at, day partition ensured); UPDATE and DELETE route via auto-update. id uniqueness is by convention post-cutover: the sequence is the only live id source, since the partitioned base cannot host a unique index on snapshot_id alone.';

-- ---------------------------------------------------------------------------
-- INSERT routing.
-- ---------------------------------------------------------------------------
create or replace function pgfr_record._snapshots_view_insert()
returns trigger
language plpgsql as $$
begin
    new.id := coalesce(new.id, nextval('pgfr_record.snapshots_id_seq'));
    new.captured_at := coalesce(new.captured_at, now());
    new.sample_ts := coalesce(new.sample_ts,
        extract(epoch from new.captured_at - pgfr_record.epoch())::int4);
    perform pgfr_record._ensure_partition('snapshots_v2',
        (pgfr_record.epoch() + new.sample_ts * interval '1 second')::date,
        'snapshot_id, sample_ts desc');
    -- Route NEW into the base table by name: jsonb_populate_record maps the
    -- view's row (with id renamed back to snapshot_id) onto snapshots_v2's
    -- row type, so column drift between view and base is impossible.
    insert into pgfr_record.snapshots_v2
    select r.* from jsonb_populate_record(
        null::pgfr_record.snapshots_v2,
        (to_jsonb(new) - 'id') || jsonb_build_object('snapshot_id', new.id)
    ) r;
    return new;
end;
$$;

comment on function pgfr_record._snapshots_view_insert() is
'INSTEAD OF INSERT handler for the snapshots compat view: assigns id from the legacy sequence, derives sample_ts from captured_at, ensures the day partition, and routes the row into snapshots_v2 by column name.';

drop trigger if exists snapshots_view_insert on pgfr_record.snapshots;
create trigger snapshots_view_insert
    instead of insert on pgfr_record.snapshots
    for each row execute function pgfr_record._snapshots_view_insert();

-- ---------------------------------------------------------------------------
-- Column-level semantic annotations (Issue #99 grammar, see STATISTICS.md).
-- These live here, not in 02_tables.sql, because the view is recreated above
-- on every install and COMMENT ON COLUMN does not survive the recreate.
-- These are RAW per-tick snapshot rows: cumulative counters are stored as
-- gauge endpoints (the value of the counter at the tick), not deltas;
-- difference consecutive rows, or use pgfr_record.deltas, for activity.
-- ---------------------------------------------------------------------------
comment on column pgfr_record.snapshots.id is '[dimension] [bigint] Snapshot (tick) identity, assigned from the legacy snapshots_id_seq sequence by the view''s INSTEAD OF INSERT trigger; alias of snapshots_v2.snapshot_id. Unique by convention post-cutover: the sequence is the only live id source.';
comment on column pgfr_record.snapshots.sample_ts is '[dimension] [epoch-seconds] Capture time as whole seconds since the recorder epoch (pgfr_record.epoch()); derived from captured_at at insert and used as the partition key of snapshots_v2.';
comment on column pgfr_record.snapshots.captured_at is '[dimension] [timestamp] Wall-clock time the per-minute snapshot() tick captured this row; every gauge and counter endpoint in the row was read at this instant.';
comment on column pgfr_record.snapshots.pg_version is '[dimension] [bigint] PostgreSQL major version that produced this row; determines which pg_stat_* sources fed the counters and which columns are NULL on this version.';
comment on column pgfr_record.snapshots.wal_records is '[gauge] [count] Cumulative WAL records generated since statistics reset (pg_stat_wal.wal_records), as read at snapshot time; a raw counter endpoint, difference consecutive rows (or use the deltas view) for per-interval activity.';
comment on column pgfr_record.snapshots.wal_fpi is '[gauge] [count] Cumulative WAL full-page images generated since statistics reset (pg_stat_wal.wal_fpi), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.wal_bytes is '[gauge] [bytes] Cumulative WAL bytes generated since statistics reset (pg_stat_wal.wal_bytes), as read at snapshot time; a raw counter endpoint, difference consecutive rows (or use the deltas view) for per-interval activity.';
comment on column pgfr_record.snapshots.wal_write_time is '[gauge] [milliseconds] Cumulative time spent writing WAL buffers to disk since statistics reset (pg_stat_wal.wal_write_time), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG18+, where the source column was removed.';
comment on column pgfr_record.snapshots.wal_sync_time is '[gauge] [milliseconds] Cumulative time spent syncing WAL files to disk since statistics reset (pg_stat_wal.wal_sync_time), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG18+, where the source column was removed.';
comment on column pgfr_record.snapshots.checkpoint_lsn is '[gauge] [lsn] Redo LSN of the most recent completed checkpoint, from pg_control_checkpoint().redo_lsn as read at snapshot time; exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.checkpoint_time is '[dimension] [timestamp] Time of the most recent completed checkpoint, from pg_control_checkpoint().checkpoint_time as read at snapshot time; a change between consecutive rows means at least one checkpoint completed in the interval.';
comment on column pgfr_record.snapshots.ckpt_timed is '[gauge] [count] Cumulative scheduled (timed) checkpoints since statistics reset (pg_stat_checkpointer.num_timed on PG17+, pg_stat_bgwriter.checkpoints_timed on PG15/16), as read at snapshot time; a raw counter endpoint, difference consecutive rows (or use the deltas view) for per-interval activity.';
comment on column pgfr_record.snapshots.ckpt_requested is '[gauge] [count] Cumulative requested (forced) checkpoints since statistics reset (pg_stat_checkpointer.num_requested on PG17+, pg_stat_bgwriter.checkpoints_req on PG15/16), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.ckpt_write_time is '[gauge] [milliseconds] Cumulative checkpoint write-phase time since statistics reset (pg_stat_checkpointer.write_time on PG17+, pg_stat_bgwriter.checkpoint_write_time on PG15/16), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time.';
comment on column pgfr_record.snapshots.ckpt_sync_time is '[gauge] [milliseconds] Cumulative checkpoint sync-phase time since statistics reset (pg_stat_checkpointer.sync_time on PG17+, pg_stat_bgwriter.checkpoint_sync_time on PG15/16), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time.';
comment on column pgfr_record.snapshots.ckpt_buffers is '[gauge] [blocks] Cumulative buffers written by checkpoints since statistics reset (pg_stat_checkpointer.buffers_written on PG17+, pg_stat_bgwriter.buffers_checkpoint on PG15/16), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.bgw_buffers_clean is '[gauge] [blocks] Cumulative buffers written by the background writer since statistics reset (pg_stat_bgwriter.buffers_clean), as read at snapshot time; a raw counter endpoint, difference consecutive rows (or use the deltas view) for per-interval activity.';
comment on column pgfr_record.snapshots.bgw_maxwritten_clean is '[gauge] [count] Cumulative times the background writer stopped a cleaning scan for having written too many buffers, since statistics reset (pg_stat_bgwriter.maxwritten_clean), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.bgw_buffers_alloc is '[gauge] [blocks] Cumulative buffers allocated since statistics reset (pg_stat_bgwriter.buffers_alloc), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.autovacuum_workers is '[gauge] [count] Autovacuum worker backends running at the snapshot instant (pg_stat_activity rows with backend_type autovacuum worker); exact at that instant, undefined between ticks. 0 (not NULL) when the system-stats section failed.';
comment on column pgfr_record.snapshots.slots_count is '[gauge] [count] Replication slots existing (rows in pg_replication_slots) at the snapshot instant; exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.slots_max_retained_wal is '[gauge] [bytes] Largest WAL retention across replication slots at the snapshot instant: max of pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) over pg_replication_slots, 0 when no slots exist.';
comment on column pgfr_record.snapshots.io_checkpointer_reads is '[gauge] [count] Cumulative pg_stat_io read operations by the checkpointer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows (or use the deltas view) for per-interval activity. NULL on PG15, where pg_stat_io does not exist.';
comment on column pgfr_record.snapshots.io_checkpointer_read_time is '[gauge] [milliseconds] Cumulative pg_stat_io read time by the checkpointer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG15.';
comment on column pgfr_record.snapshots.io_checkpointer_writes is '[gauge] [count] Cumulative pg_stat_io write operations by the checkpointer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. NULL on PG15.';
comment on column pgfr_record.snapshots.io_checkpointer_write_time is '[gauge] [milliseconds] Cumulative pg_stat_io write time by the checkpointer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG15.';
comment on column pgfr_record.snapshots.io_checkpointer_fsyncs is '[gauge] [count] Cumulative pg_stat_io fsync calls by the checkpointer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. NULL on PG15.';
comment on column pgfr_record.snapshots.io_checkpointer_fsync_time is '[gauge] [milliseconds] Cumulative pg_stat_io fsync time by the checkpointer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG15.';
comment on column pgfr_record.snapshots.io_autovacuum_reads is '[gauge] [count] Cumulative pg_stat_io read operations by autovacuum workers since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. NULL on PG15.';
comment on column pgfr_record.snapshots.io_autovacuum_read_time is '[gauge] [milliseconds] Cumulative pg_stat_io read time by autovacuum workers since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG15.';
comment on column pgfr_record.snapshots.io_autovacuum_writes is '[gauge] [count] Cumulative pg_stat_io write operations by autovacuum workers since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. NULL on PG15.';
comment on column pgfr_record.snapshots.io_autovacuum_write_time is '[gauge] [milliseconds] Cumulative pg_stat_io write time by autovacuum workers since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG15.';
comment on column pgfr_record.snapshots.io_client_reads is '[gauge] [count] Cumulative pg_stat_io read operations by client backends since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. NULL on PG15.';
comment on column pgfr_record.snapshots.io_client_read_time is '[gauge] [milliseconds] Cumulative pg_stat_io read time by client backends since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG15.';
comment on column pgfr_record.snapshots.io_client_writes is '[gauge] [count] Cumulative pg_stat_io write operations by client backends since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. NULL on PG15.';
comment on column pgfr_record.snapshots.io_client_write_time is '[gauge] [milliseconds] Cumulative pg_stat_io write time by client backends since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG15.';
comment on column pgfr_record.snapshots.io_bgwriter_reads is '[gauge] [count] Cumulative pg_stat_io read operations by the background writer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. NULL on PG15.';
comment on column pgfr_record.snapshots.io_bgwriter_read_time is '[gauge] [milliseconds] Cumulative pg_stat_io read time by the background writer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG15.';
comment on column pgfr_record.snapshots.io_bgwriter_writes is '[gauge] [count] Cumulative pg_stat_io write operations by the background writer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. NULL on PG15.';
comment on column pgfr_record.snapshots.io_bgwriter_write_time is '[gauge] [milliseconds] Cumulative pg_stat_io write time by the background writer since statistics reset, summed over all IO contexts and objects, as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval time. NULL on PG15.';
comment on column pgfr_record.snapshots.temp_files is '[gauge] [count] Cumulative temporary files created by the current database since statistics reset (pg_stat_database.temp_files), as read at snapshot time; a raw counter endpoint, difference consecutive rows (or use the deltas view) for per-interval activity.';
comment on column pgfr_record.snapshots.temp_bytes is '[gauge] [bytes] Cumulative bytes written to temporary files by the current database since statistics reset (pg_stat_database.temp_bytes), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.xact_commit is '[gauge] [count] Cumulative transactions committed in the current database since statistics reset (pg_stat_database.xact_commit), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.xact_rollback is '[gauge] [count] Cumulative transactions rolled back in the current database since statistics reset (pg_stat_database.xact_rollback), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.blks_read is '[gauge] [blocks] Cumulative disk blocks read in the current database since statistics reset (pg_stat_database.blks_read), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.blks_hit is '[gauge] [blocks] Cumulative buffer cache hits in the current database since statistics reset (pg_stat_database.blks_hit), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity.';
comment on column pgfr_record.snapshots.connections_active is '[gauge] [count] Backends in a non-idle state at the snapshot instant (pg_stat_activity rows with state not idle, all backend types); exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.connections_total is '[gauge] [count] Total backends (rows in pg_stat_activity) at the snapshot instant; exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.connections_max is '[gauge] [count] The max_connections setting as read at snapshot time; the capacity ceiling that connections_total is measured against.';
comment on column pgfr_record.snapshots.db_size_bytes is '[gauge] [bytes] Estimated on-disk size at snapshot time: sum of pg_class.relpages times block_size over tables, TOAST tables, indexes, and materialized views with relpages > 0. Based on planner-maintained relpages, so it lags reality until VACUUM or ANALYZE refreshes them.';
comment on column pgfr_record.snapshots.datfrozenxid_age is '[gauge] [xid-age] Age of the current database''s datfrozenxid at the snapshot instant (age(datfrozenxid) from pg_database); the transaction-id wraparound headroom consumed so far.';
comment on column pgfr_record.snapshots.datminmxid_age is '[gauge] [xid-age] Age of the current database''s datminmxid at the snapshot instant (mxid_age(datminmxid) from pg_database); the multixact wraparound headroom consumed so far.';
comment on column pgfr_record.snapshots.archived_count is '[gauge] [count] Cumulative number of WAL files successfully archived since archiver stats were last reset (pg_stat_archiver.archived_count), as read at snapshot time; a raw counter endpoint, difference consecutive rows (or use the archiver_status view) for per-interval activity. NULL when archive_mode is off (collection skipped).';
comment on column pgfr_record.snapshots.last_archived_wal is '[dimension] [text] Name of the most recent WAL file successfully archived, from pg_stat_archiver as of the snapshot; NULL when archive_mode is off.';
comment on column pgfr_record.snapshots.last_archived_time is '[dimension] [timestamp] Time of the most recent successful archive operation, from pg_stat_archiver as of the snapshot; NULL when archive_mode is off.';
comment on column pgfr_record.snapshots.failed_count is '[gauge] [count] Cumulative number of failed WAL archive attempts since archiver stats were last reset (pg_stat_archiver.failed_count), as read at snapshot time; a raw counter endpoint, difference consecutive rows (or use the archiver_status view) for per-interval failures. NULL when archive_mode is off.';
comment on column pgfr_record.snapshots.last_failed_wal is '[dimension] [text] Name of the WAL file involved in the most recent failed archive attempt, from pg_stat_archiver as of the snapshot; NULL when archive_mode is off.';
comment on column pgfr_record.snapshots.last_failed_time is '[dimension] [timestamp] Time of the most recent failed archive attempt, from pg_stat_archiver as of the snapshot; NULL when archive_mode is off.';
comment on column pgfr_record.snapshots.archiver_stats_reset is '[dimension] [timestamp] When pg_stat_archiver statistics were last reset, as of the snapshot; archiver counter differences spanning a reset are unreliable. NULL when archive_mode is off.';
comment on column pgfr_record.snapshots.confl_tablespace is '[gauge] [count] Cumulative queries canceled in the current database due to dropped tablespaces since statistics reset (pg_stat_database_conflicts.confl_tablespace), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. Populated only on standby servers; NULL on primaries.';
comment on column pgfr_record.snapshots.confl_lock is '[gauge] [count] Cumulative queries canceled in the current database due to lock timeouts during recovery conflict resolution since statistics reset (pg_stat_database_conflicts.confl_lock), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. Populated only on standby servers; NULL on primaries.';
comment on column pgfr_record.snapshots.confl_snapshot is '[gauge] [count] Cumulative queries canceled in the current database due to old snapshots since statistics reset (pg_stat_database_conflicts.confl_snapshot), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. Populated only on standby servers; NULL on primaries.';
comment on column pgfr_record.snapshots.confl_bufferpin is '[gauge] [count] Cumulative queries canceled in the current database due to pinned buffers since statistics reset (pg_stat_database_conflicts.confl_bufferpin), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. Populated only on standby servers; NULL on primaries.';
comment on column pgfr_record.snapshots.confl_deadlock is '[gauge] [count] Cumulative queries canceled in the current database due to deadlocks since statistics reset (pg_stat_database_conflicts.confl_deadlock), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. Populated only on standby servers; NULL on primaries.';
comment on column pgfr_record.snapshots.confl_active_logicalslot is '[gauge] [count] Cumulative queries canceled in the current database due to logical slot invalidation since statistics reset (pg_stat_database_conflicts.confl_active_logicalslot), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. Populated only on standby servers; NULL on primaries and on PG15, where the source column does not exist.';
comment on column pgfr_record.snapshots.max_catalog_oid is '[gauge] [oid] Highest OID currently assigned in pg_class at the snapshot instant (max(oid)); an OID-exhaustion indicator, exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.large_object_count is '[gauge] [count] Number of large objects (rows in pg_largeobject_metadata) at the snapshot instant; exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.bgw_buffers_backend is '[gauge] [blocks] Cumulative buffers written directly by backends since statistics reset (pg_stat_bgwriter.buffers_backend), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. Recorded on PG15/16; NULL on PG17+, where the source column was removed (use io_client_writes instead).';
comment on column pgfr_record.snapshots.bgw_buffers_backend_fsync is '[gauge] [count] Cumulative fsync calls executed by backends themselves since statistics reset (pg_stat_bgwriter.buffers_backend_fsync), as read at snapshot time; a raw counter endpoint, difference consecutive rows for per-interval activity. Recorded on PG15/16; NULL on PG17+, where the source column was removed.';
comment on column pgfr_record.snapshots.activity_xmin is '[dimension] [xid] Identity of the oldest backend_xmin across pg_stat_activity at the snapshot instant (self and parallel workers excluded, autovacuum workers included); the transaction id pinning the activity horizon. Written back by snapshot()''s xmin section; NULL when no backend holds an xmin.';
comment on column pgfr_record.snapshots.activity_xmin_age is '[gauge] [xid-age] Age of activity_xmin at the snapshot instant (age(backend_xmin) of the oldest holder); how far the oldest in-progress backend snapshot holds back the xmin horizon. Exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.slot_xmin is '[dimension] [xid] Identity of the oldest xmin across pg_replication_slots at the snapshot instant; the transaction id the most-lagging slot pins for data rows. NULL when no slot holds an xmin.';
comment on column pgfr_record.snapshots.slot_xmin_age is '[gauge] [xid-age] Age of slot_xmin at the snapshot instant (age(xmin) of the oldest-pinning slot); exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.slot_catalog_xmin is '[dimension] [xid] Identity of the oldest catalog_xmin across pg_replication_slots at the snapshot instant, captured separately from slot_xmin (a logical slot can pin catalog rows without pinning data rows). NULL when no slot holds a catalog_xmin.';
comment on column pgfr_record.snapshots.slot_catalog_xmin_age is '[gauge] [xid-age] Age of slot_catalog_xmin at the snapshot instant (age(catalog_xmin) of the oldest-pinning slot); pins catalog rows only. Exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.replication_xmin is '[dimension] [xid] Identity of the oldest backend_xmin among physical walsenders at the snapshot instant, from the replication_snapshots rows written for this snapshot (logical walsenders excluded; their xmin mirrors the slot and is attributed to the slot source). NULL when no physical walsender holds an xmin.';
comment on column pgfr_record.snapshots.replication_xmin_age is '[gauge] [xid-age] Age of replication_xmin at the snapshot instant (backend_xmin_age of the oldest physical walsender); exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.prepared_xmin is '[dimension] [xid] Identity of the oldest prepared transaction in pg_prepared_xacts at the snapshot instant; a forgotten prepared transaction pins the horizon indefinitely. NULL when no prepared transactions exist.';
comment on column pgfr_record.snapshots.prepared_xmin_age is '[gauge] [xid-age] Age of prepared_xmin at the snapshot instant (age(transaction) of the oldest prepared transaction); exact at that instant, undefined between ticks.';
comment on column pgfr_record.snapshots.xmin_data_horizon_age is '[gauge] [xid-age] Oldest data-pinning horizon age at the snapshot instant: greatest of activity_xmin_age, slot_xmin_age, prepared_xmin_age, and replication_xmin_age (NULLs ignored); how far dead-tuple cleanup is held back. NULL when no source holds an xmin.';
comment on column pgfr_record.snapshots.xmin_any_horizon_age is '[gauge] [xid-age] Oldest horizon age of any kind at the snapshot instant: greatest of xmin_data_horizon_age and slot_catalog_xmin_age; includes catalog-only pins. NULL when no source holds any xmin.';
comment on column pgfr_record.snapshots.xmin_horizon_detail is '[derived] [json] Dominant-holder attribution computed from the per-source xmin ages: an object with source (slot, prepared, activity, replication, or slot_catalog, tie-broken in that priority order), age (equals xmin_any_horizon_age), and holder (per-source detail such as pid, slot_name, or gid). NULL when no source holds any xmin.';
