-- SPDX-License-Identifier: Apache-2.0
-- Copyright 2026 David A. Ventimiglia

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
    num_slots       smallint  not null default 3 check (num_slots >= 3),
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

    -- Column semantics (Issue #99). The view is recreated by the execute
    -- above on every install, which drops prior column comments, so the
    -- comments must be reapplied here rather than as standalone statements.
    comment on column pgfr_record.query_map_all.slot is
        '[dimension] [bigint] Ring buffer slot number (0..num_slots-1) identifying which per-partition query_map_N table this dictionary row comes from.';
    comment on column pgfr_record.query_map_all.id is
        '[dimension] [bigint] Per-slot dictionary id (identity column of query_map_N); this is the qmap_id referenced by the encoded integer[] groups in wait_samples.data and by lock_samples.blocked_qid/blocking_qid.';
    comment on column pgfr_record.query_map_all.query_id is
        '[dimension] [bigint] Query identifier from pg_stat_activity.query_id (compute_query_id / pg_stat_statements hash, PG14+); the dictionary value mapped to (slot, id).';
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
    -- single round-trip: INSERT ... ON CONFLICT DO UPDATE (no-op) RETURNING id
    -- avoids a separate SELECT when the row already exists
    execute format(
        'insert into pgfr_record.query_map_%s (query_id) values ($1) '
        'on conflict (query_id) do update set query_id = excluded.query_id '
        'returning id',
        v_slot
    ) into v_id using p_query_id;
    return v_id;
end;
$$;

comment on function pgfr_record._register_query(int8) is
'Register a query_id in the current slot''s query_map table. '
'Returns the local int4 id (sequence-based, resets on TRUNCATE at rotation). '
'Single round-trip via INSERT ... ON CONFLICT DO UPDATE RETURNING id. '
'Called during sample_ring() to build the query_map ids used in data encoding.';

-- 7. rotate_ring() — N-partition TRUNCATE rotation
-- Advisory lock prevents concurrent rotation from pg_cron overlap.
-- Advances current_slot first, then TRUNCATEs the oldest partition.
--
-- Uses pg_try_advisory_xact_lock (not session-level pg_try_advisory_lock) so
-- the lock is automatically released on transaction end — including on errors.
-- Session-level locks inside exception handlers are not released when the
-- handler's subtransaction rolls back, causing lock leaks on unexpected errors.
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
    -- xact-level: auto-released on commit or rollback — no explicit unlock needed
    if not pg_try_advisory_xact_lock(hashtext('pgfr_rotate_ring')) then
        return 'skipped: another rotation in progress';
    end if;

    select current_slot, num_slots, rotation_period, rotated_at
    into v_old_slot, v_num_slots, v_rotation_period, v_rotated_at
    from pgfr_record.ring_config where singleton;

    -- idempotent: skip if rotated too recently (within 90% of rotation_period)
    if now() - v_rotated_at < v_rotation_period * 0.9 then
        return 'skipped: rotated too recently at ' || v_rotated_at::text;
    end if;

    begin
        set local lock_timeout = '2s';

        v_new_slot      := (v_old_slot + 1) % v_num_slots;
        -- truncate the slot that's now two steps ahead (oldest data)
        v_truncate_slot := (v_new_slot + 1) % v_num_slots;

        -- advance slot FIRST: new inserts go to v_new_slot before we truncate
        update pgfr_record.ring_config
        set current_slot = v_new_slot, rotated_at = now()
        where singleton;

        -- Roll up v_truncate_slot's about-to-be-destroyed data into durable
        -- wait/lock/activity rollup tables (see 11_ring_rollups.sql) before
        -- truncating it. Wrapped so a rollup bug can never block rotation --
        -- ring safety takes priority over rollup completeness.
        begin
            perform pgfr_record._flush_ring_slot_to_rollups(v_truncate_slot);
        exception when others then
            raise warning 'pgfr_record: _flush_ring_slot_to_rollups failed for slot %: %',
                v_truncate_slot, sqlerrm;
        end;

        -- lockstep TRUNCATE — zero bloat, no dead tuples, no GC needed
        execute format('truncate pgfr_record.wait_samples_%s', v_truncate_slot);
        execute format('truncate pgfr_record.lock_samples_%s', v_truncate_slot);
        execute format('truncate pgfr_record.query_map_%s', v_truncate_slot);
        execute format('truncate pgfr_record.activity_samples_%s', v_truncate_slot);
        -- restart identity sequence so ids are compact after rotation
        execute format(
            'alter table pgfr_record.query_map_%s alter column id restart',
            v_truncate_slot
        );

        return format('rotated: slot %s -> %s, truncated slot %s',
                      v_old_slot, v_new_slot, v_truncate_slot);

    exception when lock_not_available then
        -- xact-level advisory lock released automatically on rollback
        return 'failed: lock timeout on truncate, will retry next cycle';
    when others then
        raise;
    end;
end;
$$;

comment on function pgfr_record.rotate_ring() is
'Rotate ring buffer partitions: advance current_slot, roll up the oldest slot into '
'durable rollup tables (_flush_ring_slot_to_rollups(), see 11_ring_rollups.sql), then '
'TRUNCATE that partition and its matching query_map. Dynamic N-partition support '
'(reads num_slots from ring_config). Idempotent within 90% of rotation_period. '
'Advisory lock prevents concurrent rotation. Returns text status: rotated / skipped / failed.';

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
            null::bigint as query_id   -- populated per-session via query_map on PG14+
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
    -- query_id in pg_stat_activity requires PG14+; skip on PG13.
    -- -----------------------------------------------------------------------
    if (select current_setting('server_version_num')::int) >= 140000 then
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
    end if; -- PG14+ query_id guard

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

-- 9. pg_cron wiring — consolidated into pgfr_record.enable() (see 05_functions_ops.sql).
-- install.sql calls enable() as its final step; the scheduling lived here previously.

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

comment on column pgfr_record.recent_waits_v2.captured_at is
    '[dimension] [timestamp] Sampling tick time, reconstructed as pgfr_record.epoch() plus the sample row''s sample_ts offset in seconds.';
comment on column pgfr_record.recent_waits_v2.datid is
    '[dimension] [oid] OID of the database the sampled backends were connected to (0 for backends with no database).';
comment on column pgfr_record.recent_waits_v2.active_count is
    '[point-sample] [count] Number of sampled backends (active or idle in transaction) connected to this database at the sampling instant, across all wait events; repeated on every decoded wait row of the same (tick, database) sample. Sample counts estimate time-in-state when aggregated over ticks, never event counts.';
comment on column pgfr_record.recent_waits_v2.state is
    '[dimension] [text] Backend state label decoded from wait_event_map: active, idle in transaction, or idle in transaction (aborted).';
comment on column pgfr_record.recent_waits_v2.wait_event_type is
    '[dimension] [text] Wait event type decoded from wait_event_map; synthetic CPU* means active with no wait event, IdleTx means idle in transaction.';
comment on column pgfr_record.recent_waits_v2.wait_event is
    '[dimension] [text] Wait event name decoded from wait_event_map; synthetic CPU* and IdleTx label on-CPU and idle-in-transaction backends respectively.';
comment on column pgfr_record.recent_waits_v2.slot is
    '[dimension] [bigint] Ring buffer partition slot number (0..num_slots-1) the sample row currently lives in; the slot is truncated and reused on rotation.';

--------------------------------------------------------------------------------
-- 11. activity_samples: flat per-backend rows, LIST-partitioned by slot
-- Complements wait_samples (encoded integer[]) with raw session detail
-- needed by archive_ring_samples() and flush_ring_to_aggregates().
-- One row per active backend per tick (top 25 by query age, same as old ring).
--------------------------------------------------------------------------------

do $$
declare
    v_n smallint;
    i   smallint;
begin
    select num_slots into v_n from pgfr_record.ring_config where singleton;

    execute $t$
        create table if not exists pgfr_record.activity_samples (
            sample_ts        int4  not null,
            pid              int4  not null,
            usename          text,
            application_name text,
            client_addr      inet,
            backend_type     text,
            state            text,
            wait_event_type  text,
            wait_event       text,
            backend_start    timestamptz,
            xact_start       timestamptz,
            query_start      timestamptz,
            state_change     timestamptz,
            query_preview    text,
            slot             smallint not null
        ) partition by list (slot)
    $t$;

    for i in 0..(v_n - 1) loop
        execute format(
            'create table if not exists pgfr_record.activity_samples_%s '
            'partition of pgfr_record.activity_samples for values in (%s)',
            i, i
        );
        execute format(
            'create index if not exists activity_samples_%s_ts_idx '
            'on pgfr_record.activity_samples_%s (sample_ts)',
            i, i
        );
    end loop;
end;
$$;

comment on table pgfr_record.activity_samples is
'Ring buffer v2: flat per-backend activity samples. One row per active session per tick. '
'Top 25 sessions by query age. Partitioned by LIST(slot); TRUNCATE on rotation. '
'Never DELETEd.';

--------------------------------------------------------------------------------
-- 12. lock_type_map: compact int → text mapping for lock_samples.lock_type
-- Keeps lock_samples rows narrow (smallint vs text).
--------------------------------------------------------------------------------

create table if not exists pgfr_record.lock_type_map (
    id       smallint primary key generated always as identity (start with 1),
    lock_type text not null unique
);

comment on table pgfr_record.lock_type_map is
'Lock type dictionary: maps smallint id -> lock type text. '
'Used to decode lock_samples.lock_type. Shared singleton, never truncated.';

insert into pgfr_record.lock_type_map (lock_type)
values
    ('relation'), ('extend'), ('frozenid'), ('page'), ('tuple'),
    ('transactionid'), ('virtualxid'), ('spectoken'), ('object'),
    ('userlock'), ('advisory'), ('applytransaction')
on conflict (lock_type) do nothing;

--------------------------------------------------------------------------------
-- 13. sample_ring() v2: wait events, active sessions, and lock contention
-- Reads 1-4 encode wait events, read 5 samples activity, read 6 samples
-- blocked/blocking lock pairs.
--------------------------------------------------------------------------------

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
    v_rec               record;
    v_datid_rec         record;
    v_data              integer[];
    v_active_count      smallint;
    v_seen_waits        text[] := '{}';
    v_rows_inserted     int    := 0;
    -- collection_stats instrumentation (replaces the legacy sample()'s
    -- observability; uses collection_type='sample' to stay compatible with
    -- existing safety dashboards and tests).
    v_stat_id           int;
    v_load_shedding_enabled bool;
    v_load_threshold_pct int;
    v_max_connections   int;
    v_active_clients    int;
    v_active_pct        numeric;
    v_enable_locks      bool;
    v_blocked_count     int;
    v_skip_locks_threshold int;
begin
    v_captured_at := clock_timestamp();

    -- Circuit breaker: skip if recent runs averaged over the threshold.
    if pgfr_record._check_circuit_breaker('sample') then
        perform pgfr_record._record_collection_skip(
            'sample',
            'Circuit breaker tripped - recent runs exceeded threshold',
            'circuit_breaker');
        return v_captured_at;
    end if;

    -- Load shedding: skip if active client connections are above the configured
    -- percentage of max_connections. Read config before opening the stats row
    -- so a skip doesn't create an orphan started_at row.
    v_load_shedding_enabled := coalesce(
        pgfr_record._get_config('load_shedding_enabled', 'true')::bool,
        true
    );
    if v_load_shedding_enabled then
        v_load_threshold_pct := coalesce(
            pgfr_record._get_config('load_shedding_active_pct', '70')::int,
            70
        );
        select setting::int into v_max_connections
        from pg_settings where name = 'max_connections';
        select count(*) into v_active_clients
        from pg_stat_activity
        where state = 'active' and backend_type = 'client backend';
        v_active_pct := (v_active_clients::numeric / nullif(v_max_connections, 0)) * 100;
        if v_active_pct >= v_load_threshold_pct then
            perform pgfr_record._record_collection_skip(
                'sample',
                format(
                    'Load shedding: high load (%s active / %s max = %s%% >= %s%% threshold)',
                    v_active_clients, v_max_connections, round(v_active_pct, 1),
                    v_load_threshold_pct
                ),
                'load_shedding'
            );
            return v_captured_at;
        end if;
    end if;

    v_stat_id := pgfr_record._record_collection_start('sample', 4);

    v_sample_ts   := extract(epoch from (v_captured_at - pgfr_record.epoch()))::int4;
    v_slot        := pgfr_record.ring_current_slot();

    v_include_bg    := coalesce(pgfr_record._get_config('include_bg_workers', 'false')::bool, false);
    v_debug_logging := coalesce(pgfr_record._get_config('debug_logging', 'false')::bool, false);

    -- -------------------------------------------------------------------------
    -- read 1: register new wait events; walk pg_stat_activity once.
    -- -------------------------------------------------------------------------
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
            null::bigint as query_id   -- populated per-session via query_map on PG14+
        from pg_stat_activity sa
        where sa.state in ('active', 'idle in transaction', 'idle in transaction (aborted)')
          and (sa.backend_type = 'client backend'
           or (v_include_bg and sa.backend_type in (
                   'autovacuum worker', 'logical replication worker',
                   'parallel worker', 'background worker')))
          and sa.pid <> pg_backend_pid()
    loop
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

    -- -------------------------------------------------------------------------
    -- read 2: register query_ids into current slot's query_map (50k hard cap)
    -- query_id in pg_stat_activity requires PG14+; skip on PG13.
    -- -------------------------------------------------------------------------
    if (select current_setting('server_version_num')::int) >= 140000 then
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
    end if; -- PG14+ query_id guard

    -- -------------------------------------------------------------------------
    -- reads 3+4: per-database wait encoding (unchanged from original)
    -- -------------------------------------------------------------------------
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

    -- -------------------------------------------------------------------------
    -- read 5: activity_samples — top 25 sessions by query age
    -- -------------------------------------------------------------------------
    begin
        execute format(
            'insert into pgfr_record.activity_samples_%s '
            '    (sample_ts, pid, usename, application_name, client_addr, '
            '     backend_type, state, wait_event_type, wait_event, '
            '     backend_start, xact_start, query_start, state_change, '
            '     query_preview, slot) '
            'select '
            '    $1, sa.pid, sa.usename, sa.application_name, sa.client_addr, '
            '    sa.backend_type, sa.state, sa.wait_event_type, sa.wait_event, '
            '    sa.backend_start, sa.xact_start, sa.query_start, sa.state_change, '
            '    left(sa.query, 500), $2::smallint '
            'from pg_stat_activity sa '
            'where sa.state in (''active'', ''idle in transaction'', ''idle in transaction (aborted)'') '
            '  and (sa.backend_type = ''client backend'' '
            '   or ($3 and sa.backend_type in ( '
            '       ''autovacuum worker'', ''logical replication worker'', '
            '       ''parallel worker'', ''background worker''))) '
            '  and sa.pid <> pg_backend_pid() '
            'order by sa.query_start asc nulls last '
            'limit 25',
            v_slot
        ) using v_sample_ts, v_slot, v_include_bg;
    exception when others then
        raise warning 'pgfr_record.sample_ring: activity_samples insert failed [%]: %', sqlstate, sqlerrm;
    end;

    -- -------------------------------------------------------------------------
    -- read 6: lock_samples — one row per blocked/blocking pair.
    -- Gated by enable_locks. Skipped entirely when more backends are waiting
    -- on locks than skip_locks_threshold: pg_blocking_pids() is priced per
    -- waiter and fans out worst during a lock storm, exactly when the 500ms
    -- job timeout is most at risk.
    -- -------------------------------------------------------------------------
    begin
        v_enable_locks := coalesce(pgfr_record._get_config('enable_locks', 'true')::bool, true);
        if v_enable_locks then
            select count(*) into v_blocked_count
            from pg_stat_activity sa
            where sa.wait_event_type = 'Lock'
              and sa.pid <> pg_backend_pid();

            v_skip_locks_threshold := coalesce(
                pgfr_record._get_config('skip_locks_threshold', '50')::int, 50);

            if v_blocked_count > v_skip_locks_threshold then
                if v_debug_logging then
                    raise log 'pgfr_record.sample_ring: lock sampling skipped (% waiters > % threshold)',
                        v_blocked_count, v_skip_locks_threshold;
                end if;
            elsif v_blocked_count > 0 then
                -- Forward compatibility: register any lock type this PG
                -- version exposes that the install-time seed list predates
                -- (lock_type is NOT NULL, so an unmapped type would
                -- otherwise drop the row at the join below).
                insert into pgfr_record.lock_type_map (lock_type)
                select distinct wl.locktype
                from pg_locks wl
                where not wl.granted
                on conflict (lock_type) do nothing;

                -- A backend waits on at most one heavyweight lock, so the
                -- pg_locks join contributes one ungranted row per waiter.
                -- DISTINCT guards against duplicate pids from
                -- pg_blocking_pids(). blocking_pid comes from the array
                -- element (not the blocker's pg_stat_activity row) so a
                -- blocker that vanishes mid-read still yields the pair.
                insert into pgfr_record.lock_samples
                    (sample_ts, blocked_pid, blocked_qid, blocked_duration_s,
                     blocking_pid, blocking_qid, lock_type, locked_relation_oid, slot)
                select distinct
                    v_sample_ts,
                    blocked.pid,
                    bm.id,
                    greatest(0, extract(epoch from clock_timestamp()
                        - coalesce(wl.waitstart, blocked.query_start)))::int4,
                    b.pid,
                    km.id,
                    ltm.id,
                    wl.relation,
                    v_slot
                from pg_stat_activity blocked
                join pg_locks wl
                  on wl.pid = blocked.pid and not wl.granted
                join pgfr_record.lock_type_map ltm
                  on ltm.lock_type = wl.locktype
                cross join lateral unnest(pg_blocking_pids(blocked.pid)) as b(pid)
                left join pg_stat_activity blocker
                  on blocker.pid = b.pid
                left join pgfr_record.query_map_all bm
                  on bm.slot = v_slot and bm.query_id = blocked.query_id
                left join pgfr_record.query_map_all km
                  on km.slot = v_slot and km.query_id = blocker.query_id
                where blocked.wait_event_type = 'Lock'
                  and blocked.pid <> pg_backend_pid();
            end if;
        end if;
    exception when others then
        raise warning 'pgfr_record.sample_ring: lock_samples insert failed [%]: %', sqlstate, sqlerrm;
    end;

    -- Mark collection as successful. We get here even if a section's
    -- EXCEPTION handler fired -- those sections only emit a WARNING and
    -- don't abort the rest of the sample. Counting partial-success runs
    -- as 'success = true' matches the legacy sample()'s contract.
    perform pgfr_record._record_collection_end(v_stat_id, true);

    return v_captured_at;
end;
$$;

comment on function pgfr_record.sample_ring() is
'Ring buffer v2 sampler: INSERT-based replacement for the UPDATE pattern in sample(). '
'Encodes wait events as integer[] arrays: [-wait_id, count, qmap_id, ...] per database. '
'Also inserts flat rows into activity_samples (top 25 sessions by query age) and '
'blocked/blocking pairs into lock_samples via pg_blocking_pids() (gated by '
'enable_locks; skipped when waiters exceed skip_locks_threshold). '
'Dual operation: existing sample() continues to work during migration. '
'Call via pg_cron at 1-minute cadence; use rotate_ring() on a slower schedule.';

--------------------------------------------------------------------------------
-- 14. flush_ring_to_aggregates() v2: reads new ring tables
-- Replaces reads from samples_ring/wait_samples_ring/lock_samples_ring
-- with reads from wait_samples, lock_samples, activity_samples (v2).
-- Decodes wait_samples integer[] via wait_event_map.
-- Uses ring_config to know the current slot; reads all slots (full ring window).
-- Orphan dead code retired alongside the legacy ring:
--   flush_ring_to_aggregates() / archive_ring_samples() v2 versions.
-- Their cron schedules (pgfr_flush, pgfr_archive) were dropped in wave 1;
-- no callers remain. Tables they wrote to (aggregates, archives) are
-- dropped in 02_tables.sql.

DROP FUNCTION IF EXISTS pgfr_record.flush_ring_to_aggregates();
DROP FUNCTION IF EXISTS pgfr_record.archive_ring_samples();

--------------------------------------------------------------------------------
-- End of ring buffer v2 section
--------------------------------------------------------------------------------


-- recent_waits / recent_activity / recent_locks / recent_idle_in_transaction
-- views migrated to v2 storage as part of the legacy-ring retirement.
-- Column shape preserved where v2 stores the data; NULL where v2 dropped
-- columns by design (see comments on each).

DROP VIEW IF EXISTS pgfr_record.recent_waits;
CREATE VIEW pgfr_record.recent_waits AS
WITH retention_cutoff AS (
    SELECT pgfr_record.epoch()
         + (
             extract(epoch FROM now() - pgfr_record.epoch())::int4
             - (num_slots * extract(epoch FROM rotation_period)::int4)
           ) * interval '1 second' AS cutoff
    FROM pgfr_record.ring_config WHERE singleton
),
decoded AS (
    SELECT
        pgfr_record.epoch() + ws.sample_ts * interval '1 second' AS captured_at,
        abs(ws.data[i])::smallint                                AS wait_id,
        ws.data[i + 1]::integer                                  AS waiter_count
    FROM pgfr_record.wait_samples ws,
         retention_cutoff rc,
         generate_subscripts(ws.data, 1) AS i
    WHERE ws.data[i] < 0
      AND (pgfr_record.epoch() + ws.sample_ts * interval '1 second') > rc.cutoff
)
-- backend_type is not stored in v2 wait_samples (the v2 row carries datid +
-- encoded wait groups; per-backend type is no longer kept). Surfaced as NULL.
SELECT
    d.captured_at,
    NULL::text       AS backend_type,
    wem.type         AS wait_event_type,
    wem.event        AS wait_event,
    wem.state        AS state,
    d.waiter_count   AS count
FROM decoded d
JOIN pgfr_record.wait_event_map wem ON wem.id = d.wait_id
ORDER BY d.captured_at DESC, d.waiter_count DESC;

COMMENT ON COLUMN pgfr_record.recent_waits.captured_at IS
    '[dimension] [timestamp] Sampling tick time, reconstructed as pgfr_record.epoch() plus the sample row''s sample_ts offset in seconds; rows older than the ring retention window (num_slots * rotation_period) are filtered out.';
COMMENT ON COLUMN pgfr_record.recent_waits.backend_type IS
    '[dimension] [text] Always NULL: v2 wait_samples does not store per-backend type; the column is kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_waits.wait_event_type IS
    '[dimension] [text] Wait event type decoded from wait_event_map; synthetic CPU* means active with no wait event, IdleTx means idle in transaction.';
COMMENT ON COLUMN pgfr_record.recent_waits.wait_event IS
    '[dimension] [text] Wait event name decoded from wait_event_map; synthetic CPU* and IdleTx label on-CPU and idle-in-transaction backends respectively.';
COMMENT ON COLUMN pgfr_record.recent_waits.state IS
    '[dimension] [text] Backend state label decoded from wait_event_map: active, idle in transaction, or idle in transaction (aborted).';
COMMENT ON COLUMN pgfr_record.recent_waits.count IS
    '[point-sample] [count] Number of sampled backends in one database''s (state, wait_event) group at the sampling instant, decoded from wait_samples.data. Sample counts estimate time-in-state when aggregated over ticks, never event counts.';

DROP VIEW IF EXISTS pgfr_record.recent_activity;
CREATE VIEW pgfr_record.recent_activity AS
WITH retention_cutoff AS (
    SELECT pgfr_record.epoch()
         + (
             extract(epoch FROM now() - pgfr_record.epoch())::int4
             - (num_slots * extract(epoch FROM rotation_period)::int4)
           ) * interval '1 second' AS cutoff
    FROM pgfr_record.ring_config WHERE singleton
)
-- client_addr, backend_start are not stored in v2 activity_samples (v2 drops
-- them as per-backend fields not material to ring-buffer analysis). NULL.
SELECT
    pgfr_record.epoch() + as2.sample_ts * interval '1 second' AS captured_at,
    as2.pid,
    as2.usename,
    as2.application_name,
    NULL::inet                                                AS client_addr,
    as2.backend_type,
    as2.state,
    as2.wait_event_type,
    as2.wait_event,
    NULL::timestamptz                                         AS backend_start,
    as2.xact_start,
    as2.query_start,
    NULL::interval                                            AS session_age,
    (pgfr_record.epoch() + as2.sample_ts * interval '1 second') - as2.xact_start AS xact_age,
    (pgfr_record.epoch() + as2.sample_ts * interval '1 second') - as2.query_start AS running_for,
    as2.query_preview
FROM pgfr_record.activity_samples as2,
     retention_cutoff rc
WHERE (pgfr_record.epoch() + as2.sample_ts * interval '1 second') > rc.cutoff
  AND as2.pid IS NOT NULL
ORDER BY as2.sample_ts DESC, as2.query_start ASC;

COMMENT ON COLUMN pgfr_record.recent_activity.captured_at IS
    '[dimension] [timestamp] Sampling tick time, reconstructed as pgfr_record.epoch() plus the sample row''s sample_ts offset in seconds; rows older than the ring retention window (num_slots * rotation_period) are filtered out.';
COMMENT ON COLUMN pgfr_record.recent_activity.pid IS
    '[dimension] [bigint] Backend process ID of the sampled session; PIDs are reused by the OS, so correlate together with captured_at.';
COMMENT ON COLUMN pgfr_record.recent_activity.usename IS
    '[dimension] [text] Role name the sampled session was authenticated as.';
COMMENT ON COLUMN pgfr_record.recent_activity.application_name IS
    '[dimension] [text] application_name reported by the sampled session.';
COMMENT ON COLUMN pgfr_record.recent_activity.client_addr IS
    '[dimension] [text] Always NULL: client address is not surfaced from v2 activity_samples; the column is kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_activity.backend_type IS
    '[dimension] [text] Backend type from pg_stat_activity; client backend only, unless include_bg_workers is enabled (then also autovacuum, logical replication, parallel, and background workers).';
COMMENT ON COLUMN pgfr_record.recent_activity.state IS
    '[dimension] [text] Session state at the sampling instant: active, idle in transaction, or idle in transaction (aborted); other states are never sampled.';
COMMENT ON COLUMN pgfr_record.recent_activity.wait_event_type IS
    '[dimension] [text] Raw wait event type from pg_stat_activity at the sampling instant; NULL when the backend was not waiting (no CPU*/IdleTx synthesis in this view).';
COMMENT ON COLUMN pgfr_record.recent_activity.wait_event IS
    '[dimension] [text] Raw wait event name from pg_stat_activity at the sampling instant; NULL when the backend was not waiting.';
COMMENT ON COLUMN pgfr_record.recent_activity.backend_start IS
    '[dimension] [timestamp] Always NULL: backend start time is not surfaced from v2 activity_samples; the column is kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_activity.xact_start IS
    '[dimension] [timestamp] Start time of the session''s current transaction as reported by pg_stat_activity at the sampling instant; NULL if no transaction was open.';
COMMENT ON COLUMN pgfr_record.recent_activity.query_start IS
    '[dimension] [timestamp] Start time of the session''s current (or last) query as reported by pg_stat_activity at the sampling instant.';
COMMENT ON COLUMN pgfr_record.recent_activity.session_age IS
    '[point-sample] [duration] Always NULL: would be session age as of the sample instant, but backend_start is not surfaced from v2 activity_samples; kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_activity.xact_age IS
    '[point-sample] [duration] How long the session''s transaction had been open as of the sample instant (captured_at minus xact_start); a per-tick reading, not a completed-transaction duration.';
COMMENT ON COLUMN pgfr_record.recent_activity.running_for IS
    '[point-sample] [duration] How long the current query had been running as of the sample instant (captured_at minus query_start); a per-tick reading, not a completed-query duration.';
COMMENT ON COLUMN pgfr_record.recent_activity.query_preview IS
    '[dimension] [text] First 500 characters of the session''s query text at the sampling instant.';

DROP VIEW IF EXISTS pgfr_record.recent_locks;
CREATE VIEW pgfr_record.recent_locks AS
WITH retention_cutoff AS (
    SELECT pgfr_record.epoch()
         + (
             extract(epoch FROM now() - pgfr_record.epoch())::int4
             - (num_slots * extract(epoch FROM rotation_period)::int4)
           ) * interval '1 second' AS cutoff
    FROM pgfr_record.ring_config WHERE singleton
)
-- v2 lock_samples stores pids and a coded lock_type only. blocked_user,
-- blocked_app, blocking_user, blocking_app, and the two query previews are
-- not retained in v2 — surfaced as NULL.
SELECT
    pgfr_record.epoch() + ls.sample_ts * interval '1 second'   AS captured_at,
    ls.blocked_pid,
    NULL::text                                                  AS blocked_user,
    NULL::text                                                  AS blocked_app,
    ls.blocked_duration_s * interval '1 second'                AS blocked_duration,
    ls.blocking_pid,
    NULL::text                                                  AS blocking_user,
    NULL::text                                                  AS blocking_app,
    coalesce(ltm.lock_type, ls.lock_type::text)                AS lock_type,
    coalesce(
        (ls.locked_relation_oid::regclass)::text,
        'OID:' || ls.locked_relation_oid::text
    )                                                           AS locked_relation,
    NULL::text                                                  AS blocked_query_preview,
    NULL::text                                                  AS blocking_query_preview
FROM pgfr_record.lock_samples ls
CROSS JOIN retention_cutoff rc
LEFT JOIN pgfr_record.lock_type_map ltm ON ltm.id = ls.lock_type
WHERE (pgfr_record.epoch() + ls.sample_ts * interval '1 second') > rc.cutoff
ORDER BY ls.sample_ts DESC, ls.blocked_duration_s DESC NULLS LAST;

COMMENT ON COLUMN pgfr_record.recent_locks.captured_at IS
    '[dimension] [timestamp] Sampling tick time, reconstructed as pgfr_record.epoch() plus the sample row''s sample_ts offset in seconds; rows older than the ring retention window (num_slots * rotation_period) are filtered out.';
COMMENT ON COLUMN pgfr_record.recent_locks.blocked_pid IS
    '[dimension] [bigint] Process ID of the backend that was waiting on a heavyweight lock at the sampling instant.';
COMMENT ON COLUMN pgfr_record.recent_locks.blocked_user IS
    '[dimension] [text] Always NULL: v2 lock_samples does not store the blocked session''s role name; the column is kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_locks.blocked_app IS
    '[dimension] [text] Always NULL: v2 lock_samples does not store the blocked session''s application_name; the column is kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_locks.blocked_duration IS
    '[point-sample] [duration] How long the blocked backend had been waiting as of the sample instant, measured from pg_locks.waitstart (falling back to query_start) at collection time; a per-tick reading, not a completed-wait duration.';
COMMENT ON COLUMN pgfr_record.recent_locks.blocking_pid IS
    '[dimension] [bigint] Process ID of a backend blocking the waiter, from pg_blocking_pids() at the sampling instant; one row per blocked/blocking pair.';
COMMENT ON COLUMN pgfr_record.recent_locks.blocking_user IS
    '[dimension] [text] Always NULL: v2 lock_samples does not store the blocking session''s role name; the column is kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_locks.blocking_app IS
    '[dimension] [text] Always NULL: v2 lock_samples does not store the blocking session''s application_name; the column is kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_locks.lock_type IS
    '[dimension] [text] Heavyweight lock type the waiter was queued on (pg_locks.locktype), decoded from lock_type_map with the raw smallint code as text fallback.';
COMMENT ON COLUMN pgfr_record.recent_locks.locked_relation IS
    '[dimension] [text] Relation the contended lock targets, resolved via regclass at read time, with an OID:<n> text fallback when the relation no longer resolves; NULL for non-relation lock types.';
COMMENT ON COLUMN pgfr_record.recent_locks.blocked_query_preview IS
    '[dimension] [text] Always NULL: v2 lock_samples stores only a query_map id for the blocked query, not its text; the column is kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_locks.blocking_query_preview IS
    '[dimension] [text] Always NULL: v2 lock_samples stores only a query_map id for the blocking query, not its text; the column is kept for legacy view shape compatibility.';

DROP VIEW IF EXISTS pgfr_record.recent_idle_in_transaction;
CREATE VIEW pgfr_record.recent_idle_in_transaction AS
WITH retention_cutoff AS (
    SELECT pgfr_record.epoch()
         + (
             extract(epoch FROM now() - pgfr_record.epoch())::int4
             - (num_slots * extract(epoch FROM rotation_period)::int4)
           ) * interval '1 second' AS cutoff
    FROM pgfr_record.ring_config WHERE singleton
)
SELECT
    pgfr_record.epoch() + as2.sample_ts * interval '1 second' AS captured_at,
    as2.pid,
    as2.usename,
    as2.application_name,
    NULL::inet                                                AS client_addr,
    as2.xact_start,
    (pgfr_record.epoch() + as2.sample_ts * interval '1 second') - as2.xact_start AS idle_duration,
    as2.query_preview
FROM pgfr_record.activity_samples as2,
     retention_cutoff rc
WHERE (pgfr_record.epoch() + as2.sample_ts * interval '1 second') > rc.cutoff
  AND as2.pid IS NOT NULL
  AND as2.state = 'idle in transaction'
ORDER BY as2.xact_start ASC NULLS LAST;

COMMENT ON COLUMN pgfr_record.recent_idle_in_transaction.captured_at IS
    '[dimension] [timestamp] Sampling tick time, reconstructed as pgfr_record.epoch() plus the sample row''s sample_ts offset in seconds; rows older than the ring retention window (num_slots * rotation_period) are filtered out.';
COMMENT ON COLUMN pgfr_record.recent_idle_in_transaction.pid IS
    '[dimension] [bigint] Backend process ID of the session sampled in idle in transaction state; PIDs are reused by the OS, so correlate together with captured_at.';
COMMENT ON COLUMN pgfr_record.recent_idle_in_transaction.usename IS
    '[dimension] [text] Role name the sampled session was authenticated as.';
COMMENT ON COLUMN pgfr_record.recent_idle_in_transaction.application_name IS
    '[dimension] [text] application_name reported by the sampled session.';
COMMENT ON COLUMN pgfr_record.recent_idle_in_transaction.client_addr IS
    '[dimension] [text] Always NULL: client address is not surfaced from v2 activity_samples; the column is kept for legacy view shape compatibility.';
COMMENT ON COLUMN pgfr_record.recent_idle_in_transaction.xact_start IS
    '[dimension] [timestamp] Start time of the open transaction the session was idling in, as reported by pg_stat_activity at the sampling instant.';
COMMENT ON COLUMN pgfr_record.recent_idle_in_transaction.idle_duration IS
    '[point-sample] [duration] How long the transaction had been open as of the sample instant (captured_at minus xact_start); a per-tick reading of open-transaction age, not the time spent idle since the last statement.';
COMMENT ON COLUMN pgfr_record.recent_idle_in_transaction.query_preview IS
    '[dimension] [text] First 500 characters of the last query the idle-in-transaction session executed, as reported by pg_stat_activity at the sampling instant.';

